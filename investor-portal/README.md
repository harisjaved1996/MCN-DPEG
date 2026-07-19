# DPEG Investor Portal (POC)

Proof of concept: investors sign DocuSign envelopes **inside the portal**
(embedded signing) instead of via email. Documents and statuses come live from
Salesforce (`PortalDocumentApi` Apex REST); signing sessions come from the
DocuSign eSignature REST API (JWT grant).

## Setup

```powershell
cd investor-portal
python -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python manage.py migrate
python manage.py seed_investors     # haris1996 / haris637, password Invest@123
copy .env.example .env              # then fill in the DocuSign values
python manage.py runserver
```

Open http://localhost:8000 and log in.

## DocuSign app (one-time, demo account)

1. DocuSign eSignature **Admin** (admindemo.docusign.com) -> Integrations -> **Apps & Keys**.
2. **Add App / Integration Key**. Copy the Integration Key -> `DS_INTEGRATION_KEY`.
3. In the app: **Generate RSA** keypair. Save the private key text to `investor-portal/private.key`.
4. Add redirect URI: `http://localhost:8000/callback`.
5. From the Apps & Keys page header copy **User ID** -> `DS_USER_ID` and **API Account ID** -> `DS_ACCOUNT_ID`.
6. First run will print a **consent URL** if consent is missing — open it, log in, Accept.

## Salesforce auth (POC)

`signing/services/salesforce.py` reuses the local `sf` CLI session for org
alias `plaid` (`sf org display --json`). For production, replace
`get_sf_session()` with a Connected-App JWT flow; nothing else changes.

## How signing works

1. Dashboard pulls the investor's `Document_Copy__c` rows from Salesforce
   (`GET /services/apexrest/portal/v1/documents?contactId=...`).
2. "Sign now" finds the recipient on the DocuSign envelope; if it has no
   `clientUserId` yet it is converted to an embedded recipient
   (`clientUserId = ContactId`) — from then on DocuSign sends no emails to them.
3. The portal requests a one-time recipient-view URL and redirects the browser
   into the signing ceremony.
4. DocuSign redirects back to `/callback?event=signing_complete`, and the portal
   tells Salesforce to poll + sync statuses
   (`POST /services/apexrest/portal/v1/refresh`).

Routing order is enforced by DocuSign: the primary investor sees
"Waiting for <co-signer>" until required secondaries have signed.
