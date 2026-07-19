"""DocuSign embedded-signing client (JWT grant).

Flow per "Sign now" click:
  1. ensure_embedded_recipient(): find the recipient on the envelope by email;
     if it has no clientUserId yet, set clientUserId = Salesforce ContactId
     (converts the email recipient to an embedded one — no more emails).
  2. create_signing_url(): EnvelopeViews:createRecipient -> one-time ceremony
     URL (valid ~5 minutes) the portal redirects the investor to.
"""

import time

from django.conf import settings
from docusign_esign import (
    ApiClient,
    EnvelopesApi,
    RecipientViewRequest,
    Recipients,
    Signer,
)
from docusign_esign.client.api_exception import ApiException

_token_cache = {"token": None, "expires_at": 0.0}

JWT_SCOPES = ["signature", "impersonation"]


class DocuSignError(Exception):
    pass


class NotYourTurn(DocuSignError):
    """Raised when DocuSign refuses the view because of routing order."""


def _config():
    cfg = settings.DOCUSIGN
    missing = [k for k in ("INTEGRATION_KEY", "USER_ID", "ACCOUNT_ID") if not cfg.get(k)]
    if missing:
        raise DocuSignError(
            "DocuSign is not configured yet. Fill these in investor-portal/.env: "
            + ", ".join(f"DS_{m}" for m in missing)
        )
    return cfg


def consent_url():
    cfg = settings.DOCUSIGN
    return (
        f"https://{cfg['AUTH_SERVER']}/oauth/auth?response_type=code"
        f"&scope=signature%20impersonation&client_id={cfg['INTEGRATION_KEY']}"
        f"&redirect_uri={settings.PORTAL_BASE_URL}/callback"
    )


def _api_client():
    cfg = _config()
    client = ApiClient()
    client.host = cfg["BASE_PATH"]

    now = time.time()
    if not _token_cache["token"] or now >= _token_cache["expires_at"]:
        try:
            with open(cfg["PRIVATE_KEY_PATH"], "rb") as key_file:
                private_key = key_file.read()
        except OSError as exc:
            raise DocuSignError(
                f"Could not read the RSA private key at {cfg['PRIVATE_KEY_PATH']}: {exc}"
            ) from exc
        try:
            token = client.request_jwt_user_token(
                client_id=cfg["INTEGRATION_KEY"],
                user_id=cfg["USER_ID"],
                oauth_host_name=cfg["AUTH_SERVER"],
                private_key_bytes=private_key,
                expires_in=3600,
                scopes=JWT_SCOPES,
            )
        except ApiException as exc:
            if "consent_required" in str(exc.body):
                raise DocuSignError(
                    "One-time consent required. Open this URL in a browser, log in as the "
                    f"DocuSign API user, and click Accept: {consent_url()}"
                ) from exc
            raise DocuSignError(f"DocuSign JWT auth failed: {exc}") from exc
        _token_cache["token"] = token.access_token
        _token_cache["expires_at"] = now + 50 * 60

    client.set_default_header("Authorization", f"Bearer {_token_cache['token']}")
    return client


def ensure_embedded_recipient(envelope_id, email, name, contact_id):
    """Returns the matching signer, converting it to embedded if needed."""
    cfg = _config()
    api = EnvelopesApi(_api_client())
    try:
        recipients = api.list_recipients(cfg["ACCOUNT_ID"], envelope_id)
    except ApiException as exc:
        raise DocuSignError(f"Could not load envelope recipients: {_reason(exc)}") from exc

    signer = None
    for candidate in recipients.signers or []:
        if (candidate.email or "").lower() == email.lower():
            signer = candidate
            break
    if signer is None:
        raise DocuSignError(
            f"No signer with email {email} found on envelope {envelope_id}."
        )

    if (signer.status or "").lower() in ("completed", "signed"):
        raise DocuSignError("This document is already signed by you.")

    if not signer.client_user_id:
        update = Signer(
            recipient_id=signer.recipient_id,
            name=signer.name,
            email=signer.email,
            routing_order=signer.routing_order,
            client_user_id=contact_id,
        )
        try:
            api.update_recipients(
                cfg["ACCOUNT_ID"], envelope_id, recipients=Recipients(signers=[update])
            )
        except ApiException as exc:
            raise DocuSignError(
                f"Could not enable portal signing for this recipient: {_reason(exc)}"
            ) from exc
        signer.client_user_id = contact_id

    return signer


def create_signing_url(envelope_id, signer, return_url):
    cfg = _config()
    api = EnvelopesApi(_api_client())
    view_request = RecipientViewRequest(
        user_name=signer.name,
        email=signer.email,
        client_user_id=signer.client_user_id,
        recipient_id=signer.recipient_id,
        authentication_method="none",
        return_url=return_url,
    )
    try:
        view = api.create_recipient_view(
            cfg["ACCOUNT_ID"], envelope_id, recipient_view_request=view_request
        )
    except ApiException as exc:
        reason = _reason(exc)
        if "RECIPIENT_NOT_IN_SEQUENCE" in reason or "not in sequence" in reason.lower():
            raise NotYourTurn(
                "It is not your turn yet — an earlier signer has not finished."
            ) from exc
        raise DocuSignError(f"Could not start the signing session: {reason}") from exc
    return view.url


def get_recipient_status(envelope_id, email):
    """Current status of the signer matching this email (lowercased)."""
    cfg = _config()
    api = EnvelopesApi(_api_client())
    try:
        recipients = api.list_recipients(cfg["ACCOUNT_ID"], envelope_id)
    except ApiException as exc:
        raise DocuSignError(f"Could not check signing status: {_reason(exc)}") from exc
    for candidate in recipients.signers or []:
        if (candidate.email or "").lower() == email.lower():
            return (candidate.status or "").lower()
    return "unknown"


def get_envelope_pdf(envelope_id):
    """Current PDF of the envelope (signed version once recipients sign).

    Plain HTTP instead of the SDK's get_document: the SDK tries to UTF-8
    decode the binary body and crashes on real PDFs.
    """
    import requests

    cfg = _config()
    _api_client()  # ensures a fresh JWT in the token cache
    url = (
        f"{cfg['BASE_PATH']}/v2.1/accounts/{cfg['ACCOUNT_ID']}"
        f"/envelopes/{envelope_id}/documents/combined"
    )
    response = requests.get(
        url,
        headers={"Authorization": f"Bearer {_token_cache['token']}"},
        timeout=60,
    )
    if response.status_code >= 400:
        raise DocuSignError(
            f"Could not download the document ({response.status_code}): {response.text[:300]}"
        )
    return response.content


def _reason(exc):
    body = exc.body
    if isinstance(body, bytes):
        body = body.decode("utf-8", errors="replace")
    return str(body or exc)
