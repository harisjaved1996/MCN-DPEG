"""Salesforce access for the portal.

POC auth: reuses the Salesforce CLI's session for the org alias (runs on the
same dev machine as `sf`). Production would swap get_sf_session() for a
Connected-App JWT flow; everything else stays the same.
"""

import json
import subprocess
import time

import requests
from django.conf import settings

_session_cache = {"token": None, "instance_url": None, "fetched_at": 0.0}
_SESSION_TTL_SECONDS = 25 * 60


class SalesforceError(Exception):
    pass


def get_sf_session(force=False):
    now = time.time()
    if (
        not force
        and _session_cache["token"]
        and now - _session_cache["fetched_at"] < _SESSION_TTL_SECONDS
    ):
        return _session_cache["token"], _session_cache["instance_url"]

    try:
        result = subprocess.run(
            f'sf org display -o {settings.SF_ORG_ALIAS} --json',
            shell=True, capture_output=True, text=True, timeout=60,
        )
        payload = json.loads(result.stdout)
    except Exception as exc:
        raise SalesforceError(f"Could not get a Salesforce session via sf CLI: {exc}") from exc

    if payload.get("status") != 0:
        raise SalesforceError(f"sf org display failed: {payload.get('message', 'unknown error')}")

    _session_cache["token"] = payload["result"]["accessToken"]
    _session_cache["instance_url"] = payload["result"]["instanceUrl"].rstrip("/")
    _session_cache["fetched_at"] = now
    return _session_cache["token"], _session_cache["instance_url"]


def _call(method, path, *, params=None, json_body=None, retry=True):
    token, instance_url = get_sf_session()
    response = requests.request(
        method,
        f"{instance_url}{path}",
        params=params,
        json=json_body,
        headers={"Authorization": f"Bearer {token}"},
        timeout=60,
    )
    if response.status_code == 401 and retry:
        get_sf_session(force=True)
        return _call(method, path, params=params, json_body=json_body, retry=False)
    if response.status_code >= 400:
        try:
            detail = response.json().get("error", response.text)
        except Exception:
            detail = response.text
        raise SalesforceError(f"Salesforce API error ({response.status_code}): {detail}")
    return response.json()


def get_documents(contact_id):
    """Signature documents for one investor (PortalDocumentApi GET)."""
    return _call("GET", "/services/apexrest/portal/v1/documents", params={"contactId": contact_id})


def refresh_master(master_document_id):
    """Ask Salesforce to poll DocuSign and sync copy statuses (PortalDocumentApi POST)."""
    return _call(
        "POST",
        "/services/apexrest/portal/v1/refresh",
        json_body={"masterDocumentId": master_document_id},
    )
