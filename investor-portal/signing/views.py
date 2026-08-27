import mimetypes

from django.conf import settings
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.http import HttpResponse
from django.shortcuts import redirect, render
from urllib.parse import urlencode

from .services import docusign_client, salesforce

FINAL_STATUSES = {"completed", "signed", "declined", "voided", "failed"}


def _profile(request):
    return getattr(request.user, "investor_profile", None)


def _filename_for(doc):
    """Title with its file extension appended, unless the Title already has it."""
    name = doc.get("title") or "document"
    ext = (doc.get("fileExtension") or "").lstrip(".")
    if ext and not name.lower().endswith("." + ext.lower()):
        name += "." + ext
    return name


def _annotate(doc):
    status = (doc.get("status") or "").lower()
    doc["isDone"] = status in ("completed", "signed")
    doc["isFailed"] = status in ("failed", "declined", "voided")
    # Viewers (neither primary nor required signer) receive a copy but never sign.
    doc["isSigner"] = bool(doc.get("isPrimary") or doc.get("isRequiredSigner"))
    doc["canSign"] = (
        doc["isSigner"]
        and bool(doc.get("envelopeId"))
        and status not in FINAL_STATUSES
        and not doc.get("waitingOnName")
    )
    # Newly arrived = sent to the investor but not acted on yet.
    doc["isNew"] = status in ("sent", "delivered") and doc["canSign"]
    doc["canView"] = bool(doc.get("envelopeId"))
    return doc


@login_required
def dashboard(request):
    profile = _profile(request)
    if profile is None:
        messages.error(request, "Your login is not linked to a Salesforce contact.")
        return render(request, "signing/dashboard.html", {"documents": []})

    documents, error = [], None
    try:
        payload = salesforce.get_documents(profile.contact_id)
        documents = [_annotate(d) for d in payload.get("documents", [])]

        # Self-heal: if any of this investor's documents look pending, ask
        # Salesforce to poll DocuSign and sync before we render — the investor
        # may have signed without the callback page ever loading.
        pending_masters = {
            d["masterDocumentId"]
            for d in documents
            if d.get("masterDocumentId") and d.get("envelopeId")
            and not d["isDone"] and not d["isFailed"]
        }
        if pending_masters:
            for master_id in list(pending_masters)[:5]:
                try:
                    salesforce.refresh_master(master_id)
                except salesforce.SalesforceError:
                    pass
            payload = salesforce.get_documents(profile.contact_id)
            documents = [_annotate(d) for d in payload.get("documents", [])]
    except salesforce.SalesforceError as exc:
        error = str(exc)

    to_sign = [d for d in documents if d["canSign"]]
    waiting = [d for d in documents if not d["canSign"] and not d["isDone"]]
    completed = [d for d in documents if d["isDone"]]

    # Plain files dropped on an Investment record (Notes & Attachments / Files) —
    # visible to every investor in that investment, independent of DocuSign.
    investment_documents = []
    try:
        inv_payload = salesforce.get_investment_documents(profile.contact_id)
        investment_documents = inv_payload.get("documents", [])
        for d in investment_documents:
            d["displayName"] = _filename_for(d)
    except salesforce.SalesforceError as exc:
        if error is None:
            error = str(exc)

    return render(
        request,
        "signing/dashboard.html",
        {
            "to_sign": to_sign,
            "waiting": waiting,
            "completed": completed,
            "has_any": bool(documents),
            "investment_documents": investment_documents,
            "error": error,
            "profile": profile,
        },
    )


@login_required
def sign(request, copy_id):
    profile = _profile(request)
    if profile is None:
        messages.error(request, "Your login is not linked to a Salesforce contact.")
        return redirect("dashboard")

    # Re-fetch from Salesforce so the copy is verified to belong to this investor.
    try:
        payload = salesforce.get_documents(profile.contact_id)
    except salesforce.SalesforceError as exc:
        messages.error(request, str(exc))
        return redirect("dashboard")

    doc = next((d for d in payload.get("documents", []) if d.get("copyId") == copy_id), None)
    if doc is None:
        messages.error(request, "That document was not found for your account.")
        return redirect("dashboard")
    if not doc.get("envelopeId"):
        messages.error(request, "This document has no DocuSign envelope (send failed).")
        return redirect("dashboard")
    if not (doc.get("isPrimary") or doc.get("isRequiredSigner")):
        messages.info(request, "You receive a copy of this document — no signature is required from you.")
        return redirect("dashboard")
    if doc.get("waitingOnName"):
        messages.info(request, f"Waiting for {doc['waitingOnName']} to sign first.")
        return redirect("dashboard")

    return_url = settings.PORTAL_BASE_URL + "/callback?" + urlencode(
        {"copy": copy_id, "master": doc.get("masterDocumentId") or ""}
    )
    try:
        signer = docusign_client.ensure_embedded_recipient(
            envelope_id=doc["envelopeId"],
            email=profile.sf_email,
            name=payload.get("contactName") or request.user.get_full_name(),
            contact_id=profile.contact_id,
        )
        ceremony_url = docusign_client.create_signing_url(
            doc["envelopeId"], signer, return_url
        )
    except docusign_client.NotYourTurn as exc:
        messages.info(request, str(exc))
        return redirect("dashboard")
    except docusign_client.DocuSignError as exc:
        messages.error(request, str(exc))
        return redirect("dashboard")

    # The ceremony renders in an iframe on this page — signing happens
    # without ever leaving the portal. Chrome blocks DocuSign's redirect back
    # to localhost (public->local network), so the page polls sign_status and
    # navigates itself once the signature lands.
    request.session[f"signing_{copy_id}"] = {
        "envelope_id": doc["envelopeId"],
        "master_id": doc.get("masterDocumentId") or "",
    }
    return render(request, "signing/sign.html", {"doc": doc, "ceremony_url": ceremony_url})


@login_required
def sign_status(request, copy_id):
    """Polled by the signing page: has this investor finished signing yet?"""
    from django.http import JsonResponse

    profile = _profile(request)
    session_key = f"signing_{copy_id}"
    ctx = request.session.get(session_key)
    if profile is None or not ctx:
        return JsonResponse({"error": "no active signing session"}, status=404)
    try:
        status = docusign_client.get_recipient_status(ctx["envelope_id"], profile.sf_email)
    except docusign_client.DocuSignError as exc:
        return JsonResponse({"status": "unknown", "detail": str(exc)})
    return JsonResponse({"status": status, "master": ctx.get("master_id", "")})


def _find_doc(request, copy_id):
    """Loads the copy row for the logged-in investor, or None + redirect target."""
    profile = _profile(request)
    if profile is None:
        messages.error(request, "Your login is not linked to a Salesforce contact.")
        return None
    try:
        payload = salesforce.get_documents(profile.contact_id)
    except salesforce.SalesforceError as exc:
        messages.error(request, str(exc))
        return None
    doc = next((d for d in payload.get("documents", []) if d.get("copyId") == copy_id), None)
    if doc is None or not doc.get("envelopeId"):
        messages.error(request, "That document was not found for your account.")
        return None
    return doc


@login_required
def document(request, copy_id):
    """In-portal PDF viewer page (pdf.js) with a download option."""
    doc = _find_doc(request, copy_id)
    if doc is None:
        return redirect("dashboard")
    return render(request, "signing/viewer.html", {"doc": doc})


@login_required
def document_file(request, copy_id):
    """Raw envelope PDF bytes (signed version once completed)."""
    doc = _find_doc(request, copy_id)
    if doc is None:
        return redirect("dashboard")

    try:
        pdf_bytes = docusign_client.get_envelope_pdf(doc["envelopeId"])
    except docusign_client.DocuSignError as exc:
        messages.error(request, str(exc))
        return redirect("dashboard")

    filename = (doc.get("documentName") or "document").replace('"', "") or "document"
    if not filename.lower().endswith(".pdf"):
        filename += ".pdf"
    disposition = "attachment" if request.GET.get("download") else "inline"
    response = HttpResponse(pdf_bytes, content_type="application/pdf")
    response["Content-Disposition"] = f'{disposition}; filename="{filename}"'
    return response


@login_required
def document_data(request, copy_id):
    """PDF as base64 JSON for the in-portal viewer.

    Download managers (IDM etc.) intercept application/pdf responses and hand
    the page an empty body; they ignore JSON, so the viewer fetches this.
    """
    import base64

    from django.http import JsonResponse

    doc = _find_doc(request, copy_id)
    if doc is None:
        return JsonResponse({"error": "Document not found."}, status=404)
    try:
        pdf_bytes = docusign_client.get_envelope_pdf(doc["envelopeId"])
    except docusign_client.DocuSignError as exc:
        return JsonResponse({"error": str(exc)}, status=502)
    return JsonResponse({"b64": base64.b64encode(pdf_bytes).decode("ascii")})


def _find_investment_doc(request, content_version_id):
    """Loads a general Investment file for the logged-in investor, or None.

    Re-fetches from Salesforce (scoped to this contact's investments) so a
    contact can't guess another investor's contentVersionId and pull their file.
    """
    profile = _profile(request)
    if profile is None:
        messages.error(request, "Your login is not linked to a Salesforce contact.")
        return None
    try:
        payload = salesforce.get_investment_documents(profile.contact_id)
    except salesforce.SalesforceError as exc:
        messages.error(request, str(exc))
        return None
    doc = next(
        (d for d in payload.get("documents", []) if d.get("contentVersionId") == content_version_id),
        None,
    )
    if doc is None:
        messages.error(request, "That document was not found for your account.")
        return None
    return doc


@login_required
def investment_document(request, content_version_id):
    """In-portal viewer page for a file uploaded directly on an Investment record."""
    doc = _find_investment_doc(request, content_version_id)
    if doc is None:
        return redirect("dashboard")
    doc["displayName"] = _filename_for(doc)
    is_pdf = (doc.get("fileType") or "").upper() == "PDF"
    return render(request, "signing/investment_document.html", {"doc": doc, "is_pdf": is_pdf})


@login_required
def investment_document_file(request, content_version_id):
    """Raw file bytes — inline for viewing, or as an attachment when ?download=1."""
    doc = _find_investment_doc(request, content_version_id)
    if doc is None:
        return redirect("dashboard")
    try:
        file_bytes = salesforce.get_content_version_data(content_version_id)
    except salesforce.SalesforceError as exc:
        messages.error(request, str(exc))
        return redirect("dashboard")

    filename = _filename_for(doc)
    content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
    disposition = "attachment" if request.GET.get("download") else "inline"
    response = HttpResponse(file_bytes, content_type=content_type)
    response["Content-Disposition"] = f'{disposition}; filename="{filename}"'
    return response


@login_required
def investment_document_data(request, content_version_id):
    """PDF bytes as base64 JSON, for the in-portal pdf.js viewer (see document_data)."""
    import base64

    from django.http import JsonResponse

    doc = _find_investment_doc(request, content_version_id)
    if doc is None:
        return JsonResponse({"error": "Document not found."}, status=404)
    try:
        file_bytes = salesforce.get_content_version_data(content_version_id)
    except salesforce.SalesforceError as exc:
        return JsonResponse({"error": str(exc)}, status=502)
    return JsonResponse({"b64": base64.b64encode(file_bytes).decode("ascii")})


@login_required
def callback(request):
    event = request.GET.get("event", "")
    master_id = request.GET.get("master", "")

    refreshed = False
    if event == "signing_complete" and master_id:
        try:
            salesforce.refresh_master(master_id)
            refreshed = True
        except salesforce.SalesforceError:
            pass  # statuses will still arrive via the packaged status sync

    headline, detail = {
        "signing_complete": (
            "Thank you — your signature is complete!",
            "Salesforce has been updated with your signing status.",
        ),
        "decline": ("You declined to sign.", "The sender has been notified."),
        "cancel": ("Signing was cancelled.", "You can sign later from your dashboard."),
        "ttl_expired": (
            "The signing session expired.",
            "Please click Sign now again to start a fresh session.",
        ),
    }.get(event, ("Signing session ended.", f"Event: {event or 'unknown'}"))

    return render(
        request,
        "signing/callback.html",
        {"headline": headline, "detail": detail, "event": event, "refreshed": refreshed},
    )
