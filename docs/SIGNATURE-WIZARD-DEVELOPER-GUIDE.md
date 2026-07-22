# DocuSign Signature Wizard + Investor Portal — Developer Guide

**Use case:** DPEG staff prepare a document (e.g. a PPM) on an Investment record in Salesforce,
place merge/entry/signature fields on it visually, and send it for signature to the investors of
that investment. Each investing entity gets ONE shared DocuSign envelope with sequential routing.
Investors sign **inside a web portal** (embedded signing) instead of via DocuSign email.
All statuses flow back to Salesforce.

Built July 2026 on org alias `plaid` with the **DocuSign eSignature for Salesforce** managed
package (`dfsle`) and its **Apex Toolkit**. Portal is Django 5 + SQLite (POC).

---

## 1. High-level architecture

```
┌────────────────────────── SALESFORCE ──────────────────────────┐
│  Investment record page (FlexiPage tab "Add Signature Request")│
│    LWC wizard (4 steps)                                        │
│      └─> SignatureRequestController (@AuraEnabled facade)      │
│            └─> SignatureRequestService (logic + dfsle calls)   │
│                  └─> SignatureRequestSender (Queueable chain)  │
│                        └─> dfsle.EnvelopeService.sendEnvelope  │──┐
│  Tracking: Master_Document__c ← Document_Copy__c (per person)  │  │
│  Status sync: trigger on dfsle__EnvelopeStatus__c + on-demand  │  │
│  Portal API: PortalDocumentApi (@RestResource /portal/v1/*)    │  │
└──────────────▲─────────────────────────────────────────────────┘  │
               │ REST (list documents, refresh statuses)            │ envelopes
               │                                                    ▼
┌──────────────┴──────────┐        embedded signing      ┌──────────────────┐
│  DJANGO INVESTOR PORTAL │ ───────────────────────────▶ │     DOCUSIGN     │
│  login = SF ContactId   │  JWT + createRecipientView   │  (demo account)  │
│  pdf.js viewer/download │ ◀─────────────────────────── │  stores the PDFs │
└─────────────────────────┘        PDF bytes             └──────────────────┘
```

**Division of labor**
- **Salesforce** = orchestrator + tracker. Builds envelopes, stores who must sign what, mirrors statuses.
- **DocuSign** = vault + routing engine. Stores documents, enforces signing order, collects signatures.
- **Portal** = investor-facing delivery. Reads "what to sign" from Salesforce, gets the signing
  ceremony + PDFs directly from DocuSign.

---

## 2. Data model

### Business schema (pre-existing)
```
Investment__c ← position__c → Investing_Entity__c ← Associated_Contact__c → Contact
```
- `Associated_Contact__c` (junction) fields: `Contact__c`, `Investing_Entity__c`,
  `Primary__c`, `Required_Signer__c`. **This junction drives all signing roles.**
- `Investing_Entity__c.Entity_Type__c` picklist drives per-field visibility filters.
- Business rules:
  - Primary ⇒ always treated as required signer (forced in code).
  - ONE envelope per investing entity per send.
  - Required non-primary signers sign FIRST (routing 1), primary signs LAST (routing 2)
    and fills ALL placed input fields. Contact merge fields resolve against the PRIMARY.
  - Contacts that are neither primary nor required signer = CarbonCopy viewers (no signing).

### Tracking objects (built for this feature)
- **`Master_Document__c`** — one per wizard send. Lookup → Investment (required, Restrict delete).
  Stores document identity (`Content_Version_Id__c`, `Template_Id__c`, `Source_Type__c`),
  the full wizard payload JSON (`Request_Payload__c`, used for resends), and metric numbers
  `Sent/Opened/Completed/Failed_Count__c` (recalculated in Apex — NOT rollups, object is a lookup child).
- **`Document_Copy__c`** — master-detail under Master_Document (relationship `Copies`), **one row per
  recipient** of a shared envelope. Key fields: `Contact__c`, `Investing_Entity__c`,
  `DocuSign_Envelope_Id__c` (Text 36, externalId — recipients of one entity SHARE this value),
  `Envelope_Link__c` (durable web-app URL), `Status__c`, `Sent/Opened/Completed_At__c`,
  `Is_Primary__c`, `Is_Required_Signer__c`, `Recipient_Role__c`, `Routing_Order__c`, `Error_Message__c`.
  - Why per-recipient rows when the envelope is shared: (a) show each signer's own progress,
    (b) the portal needs a row per investor login to find "their" documents.

Metadata gotchas hit: MD child object needs `enableSharing/enableBulkApi/enableStreamingApi`
all-equal; required lookups need `<deleteConstraint>`; FlexiPage `<mode>Replace</mode>` is only
valid with `<parentFlexiPage>`; org-default record page activation = `actionOverrides`
(View/Flexipage/Large) on the CustomObject.

---

## 3. Salesforce side

### 3.1 Record page tab
- `flexipages/Investment_Record_Page.flexipage-meta.xml` — tabs **Details / Add Signature Request / Related**.
  The signature tab hosts `addSignatureRequest` (wizard) + `sigreqMasterDocuments` (tracking card).
- Activated org-default via actionOverride in `objects/Investment__c/Investment__c.object-meta.xml`.
- `flexipages/Master_Document_Record_Page.flexipage-meta.xml` — "Copies & Status" tab with
  `masterDocumentCopies` LWC.

### 3.2 LWC wizard (4 steps, container owns all state)
| Component | Responsibility |
|---|---|
| `addSignatureRequest` | Container: step state, document + fields + selection state, calls `send` |
| `sigreqDocumentStep` | Step 1: pick source — Salesforce Files (PDF), DocuSign template, or upload |
| `sigreqFieldsStep` + `sigreqPdfCanvas` + `sigreqFieldPalette` | Step 2: pdf.js preview, drag-drop field placement, right-click menu (Specify Entity Types / Copy / Delete) |
| `sigreqEntityTypesModal` | Entity-type visibility filter per placed field (ALL categories, not just merge) |
| `sigreqProspectsStep` | Step 3: datatable of Associated_Contacts (key = associationId), all pre-selected |
| `sigreqConfirmStep` | Step 4: summary, per-recipient role labels, envelope count = distinct entities |
| `sigreqUtils` | shared helpers (reduceError, clientId gen, palette constants) |
| `sigreqMasterDocuments` / `masterDocumentCopies` | tracking UI (metrics badges, refresh, view, reset & resend) |

**pdf.js under Lightning Web Security** (the hard part):
- Static resource `pdfjs` = pdf.js **3.11.174 legacy UMD** build (4.x ESM worker breaks under LWS).
- Worker: same-origin `workerSrc`; fallback = loadScript the worker file → fake worker.
- Bytes: `fetch('/sfc/servlet.shepherd/version/download/' + contentVersionId)`; Apex base64
  fallback capped at 2 MB (6 MB sync heap ÷ base64 expansion).
- **Coordinates:** pdf.js points (72 dpi, top-left origin) are EXACTLY DocuSign absolute tab units.
  Formula: `points = (clientXY − overlayRect.corner) × pagePointsDim / overlayRect.dim`.
  Render at fixed scale 1.5; chip CSS position = points × scale.
- Canvas emits `docmeta` {pageCount, lastPageWidth, lastPageHeight} after load — the server needs
  the last page's size to place auto signing blocks.

### 3.3 Apex classes
| Class | Role |
|---|---|
| `SignatureRequestModels` | DTOs only (SendRequest, PlacedField, Prospect, CopyRow, SendOutcome…) |
| `SignatureRequestController` | Thin `@AuraEnabled` facade, `auraError()` helper (AuraHandledException + setMessage so tests see the message) |
| `SignatureRequestService` | All logic: describe-driven merge palette, prospect loading, recipient grouping, tab building, envelope building. **All dfsle calls behind the `gateway` seam** |
| `SignatureRequestSender` | Self-chaining Queueable, `Database.AllowsCallouts`, ONE envelope per link |
| `SignatureRequestTracking` | Master/copy creation, status sync (envelope + per-recipient), metrics, reset & resend |
| `PortalDocumentApi` | `@RestResource(/portal/v1/*)` for the investor portal |
| `EnvelopeStatusSync` (trigger) | on `dfsle__EnvelopeStatus__c` after insert/update → syncStatuses |

**The gateway seam (testability):** dfsle statics cannot be mocked. `SignatureRequestService`
defines an `EnvelopeGateway` interface + `DfsleGateway` impl and a `@TestVisible static gateway`.
Tests inject `SignatureRequestServiceTest.FakeGateway` (public @IsTest class shared by all test
classes, with call counters + `new dfsle.Envelope(null×12)` fakes).

### 3.4 Building the envelope (per entity)
`SignatureRequestService.buildEntityEnvelope(req, ctx, grp, templateRole)`:
1. `dfsle.EnvelopeService.getEmptyEnvelope(new dfsle.Entity(investmentId))` — source = Investment,
   so packaged status records attach there.
2. Document: `dfsle.Document.fromFile(ContentVersion)` or `fromTemplate(dfsle.UUID.parse(id), name)`.
3. Recipients (sequential routing):
   - Required secondaries → `Recipient.fromSource(name, email, phone, role, new dfsle.Entity(contactId))`
     `.withRoutingOrder(1)` + their auto signing block tabs.
   - Primary → routing 2 (or 1 if no secondaries) + ALL placed field tabs + their auto block.
   - Viewers → `.withType('CarbonCopy')`, routing 1.
4. Tabs from placed fields (`buildTabSpecs`): entity-type filter applies to EVERY category —
   skip a field when `field.entityTypes` is non-empty and the entity's type isn't in it.
   - MERGE → `TextTab.withValue(resolved).withReadOnly(true)` (values resolved from the entity's
     latest position / entity / investment / PRIMARY contact via describe-validated dynamic SOQL,
     `AccessLevel.USER_MODE`).
   - ENTRY → `TextTab().withRequired(true|false)` / `CheckboxTab`.
   - RECIPIENT → `SignHereTab` / `DateSignedTab` / `FullNameTab` / `EmailAddressTab`.
   - Every tab: `.withDataLabel(uniqueClientId)` — **same data labels sync values across tabs!** —
     and `.withPosition(new dfsle.Tab.Position(1, page, x, y, w, h))`.
5. **Auto signing blocks** (`buildAutoSignSpecs`): generic SignHere + FullName + DateSigned rows
   stacked bottom-up on the LAST page, one block per required signer:
   `y = lastPageHeight − 30 − 64 × (totalSlots − slotIndex)`. Skipped for templates (no page meta).

**Send pipeline:** `sendEnvelope` does callouts AND DML internally → never loop it in one
transaction. `SignatureRequestSender` chain state = request + remaining ENTITY ids + outcomes;
each `execute()` sends one entity's envelope, records the outcome
(`SignatureRequestTracking.createCopiesForOutcome` — one copy per recipient), then enqueues the
next link. `finish()` raises a Custom Notification (`Signature_Request_Result`).

**Apex Toolkit gotchas (cost hours — memorize):**
- Cannot chain a method on a namespaced static call: `dfsle.X.y(...).z()` → "Variable does not
  exist: dfsle". Assign to a variable first.
- dfsle objects are NOT JSON-serializable ("Type cannot be serialized") — use direct property
  access (`envelope.docuSignId`, `envelope.id`, `template.name`), never JSON introspection.
- Verified the installed API surface via Tooling API `ApexClass.SymbolTable` (the docs site is an
  unreadable JS SPA).

### 3.5 Status tracking (two paths + per-recipient)
1. **Push:** the packaged DocuSign Connect integration writes `dfsle__EnvelopeStatus__c` records →
   trigger `EnvelopeStatusSync` → `SignatureRequestTracking.syncStatuses`.
2. **Pull:** "Refresh Statuses" / portal refresh → `gateway.pollStatuses(investmentId, 200)`
   (= `dfsle.StatusService.getStatus(new Set<Id>{investmentId}, 200)`) then sync from the
   status records (query by `dfsle__SourceId__c` with BOTH 18 and 15-char id).
3. `syncStatuses` mirrors envelope-level status onto all copies of that envelope id
   (case-insensitive match), THEN overrides per copy from **`dfsle__RecipientStatus__c`**
   (child of EnvelopeStatus; match by contact email, lowercased). This is what lets the
   routing-1 signer show **Completed** while the envelope is still in progress — and what
   unblocks the primary's "waiting" state in the portal.
- `Opened` = status in {delivered, signed, completed, declined}. Reset copies are excluded
  from sync and metrics.

### 3.6 Reset & resend
`SignatureRequestTracking.resetAndResend(copyId)`: void the envelope via
`dfsle.StatusService.voidEnvelope` (skip when completed/declined/voided/failed) → mark ALL
sibling copies of that entity's envelope `Status='Reset'` → re-enqueue the Sender for just that
entity using the JSON payload stored on the master. Reset cascades the whole entity envelope
because the envelope is shared.

### 3.7 Portal REST API (`PortalDocumentApi`)
- `GET /services/apexrest/portal/v1/documents?contactId=003...` (or `email=`) →
  `{contactId, contactName, documents:[{copyId, documentName, masterDocumentId, investmentName,
  envelopeId, envelopeLink, status, sentAt, completedAt, isPrimary, isRequiredSigner,
  routingOrder, entityName, waitingOnName}]}`.
  - `waitingOnName` is computed server-side: a sibling copy on the same envelope with LOWER
    routing order whose status is not signed/completed → that person's name. Null = your turn.
  - Excludes `Status='Reset'` rows. 400/404/500 as JSON `{error}`.
- `POST /services/apexrest/portal/v1/refresh` `{masterDocumentId}` → poll + sync + return copies.
- Routing inside the class: parse `RestContext.request.requestURI` after `/portal/v1/`.
- Remember to add the class to the permission set. Test with `RestContext.request/response` stubs.

---

## 4. DocuSign account/environment setup (the #1 trap)

**DocuSign has two separate worlds** and everything must live in the SAME one:

| | Demo/Developer | Production |
|---|---|---|
| Web app | apps-**d**.docusign.com | apps.docusign.com |
| OAuth server | account-**d**.docusign.com | account.docusign.com |
| API base | demo.docusign.net/restapi | na4.docusign.net/restapi (shard varies) |
| Integration keys | create + use freely | only via **Go-Live promotion** of a demo key |

Lessons learned the hard way:
- The org's dfsle connection was initially a **production trial** (trials DON'T support API
  integrations — go-live is refused: "These accounts don't support API integrations").
  Fix: reconnect Salesforce to the **demo** account so the portal's demo integration key works.
- Find which account Salesforce is connected to with anonymous Apex:
  `dfsle.AccountService.getDocuSignUrl()` — the returned URL contains `accountId=<GUID>` and the
  API host. Don't guess.
- Reconnect flow: DocuSign Apps Launcher → Log Out → Connect wizard → the ENVIRONMENT is chosen
  by where you log in (demo login page = account-d) → pick the demo account in "Select Account".
- The `Envelope_Link__c` base host must match the environment
  (`SignatureRequestTracking.envelopeLinkBase`).

**Integration key setup (demo Admin → Integrations → Apps and Keys):**
1. Create app ("Private custom integration"). Copy **Integration Key**.
2. Generate RSA keypair → save the **private key** (shown once).
3. Add redirect URI (e.g. `http://localhost:8000/callback`) — required or consent fails with
   "There are no redirect URIs registered".
4. Note **User ID** (API username GUID) and **API Account ID** (GUID) from the page header.
5. One-time JWT consent: open
   `https://account-d.docusign.com/oauth/auth?response_type=code&scope=signature%20impersonation&client_id=<IK>&redirect_uri=<uri>`
   → Accept. (Go-live later requires 20+ successful demo API calls on the key.)

---

## 5. Investor portal (Django)

Location: `investor-portal/` at repo root. Stack: Django 5, SQLite, `docusign-esign`,
`requests`, `python-dotenv`. Run: venv → `python manage.py runserver 8001`.

### 5.1 Identity model
`InvestorProfile` = OneToOne(User) + `contact_id` (SF ContactId) + `sf_email`.
**The ContactId is the join key between portal logins and Salesforce data.**
Seed command `seed_investors` creates the POC users.

### 5.2 Service layer
- `services/salesforce.py` — POC auth = `sf org display -o plaid --json` subprocess (reuses the
  dev machine's CLI session; cached 25 min; retry-once on 401). Production swap: Connected-App
  JWT — only `get_sf_session()` changes. Wraps the two Apex REST endpoints.
- `services/docusign_client.py` — JWT grant via `ApiClient.request_jwt_user_token`
  (token cached ~50 min; catches `consent_required` and surfaces the consent URL).
  - `ensure_embedded_recipient(envelopeId, email, name, contactId)`: list recipients → find
    signer by email → **if no `clientUserId`, update the recipient with
    `clientUserId = ContactId`** (this converts an email recipient to an embedded one and stops
    further DocuSign emails to them) → guards "already signed".
  - `create_signing_url(...)`: `EnvelopeViews:createRecipient` with matching
    name/email/clientUserId + `authentication_method="none"` (portal login IS the auth) →
    single-use ~5-minute ceremony URL. Generate at click time, never store.
  - `get_recipient_status(envelopeId, email)`: recipient's own status (poll target).
  - `get_envelope_pdf(envelopeId)`: **raw `requests` GET
    `/v2.1/accounts/{acct}/envelopes/{id}/documents/combined`** — the SDK's `get_document`
    crashes with UnicodeDecodeError on real PDFs.

### 5.3 Views / UX flow
- **Dashboard** (`/`): pulls documents by ContactId → three sections: *Needs your signature*
  (with NEW badge), *In progress* (incl. "Waiting for <name>"), *Completed*.
  - `canSign` = is signer (primary or required) AND envelope exists AND status not final AND
    not waiting on an earlier signer. Viewers never get a Sign button.
  - **Self-heal:** if any doc looks pending, the dashboard calls the refresh endpoint first and
    re-fetches — so it's correct even if a signing session ended without the callback firing.
- **Sign** (`/sign/<copyId>/`): re-fetches from SF (authorization = the copy must belong to the
  logged-in contact), guards viewer/waiting cases, gets ceremony URL, renders it in an
  **iframe** (X_FRAME_OPTIONS=SAMEORIGIN so our own callback may be framed).
- **Ceremony-end detection:** Chrome's local-network protection BLOCKS DocuSign (public site)
  redirecting the iframe to `localhost` → the page **polls `/sign/<id>/status` every 4 s**
  (envelope id kept in session) and navigates itself to `/callback?event=...` on
  completed/declined. The callback also busts out of the iframe (`window.top.location`).
- **Callback** (`/callback`): on `signing_complete` → POST the SF refresh endpoint → result page.
- **Viewer** (`/document/<copyId>/`): in-portal pdf.js (CDN 3.11.174) renders the PDF page by
  page. The bytes come from `/document/<id>/data` as **base64 inside JSON** — download managers
  (IDM) intercept `application/pdf` fetches and hand the page an empty body; they ignore JSON.
  `/document/<id>/file?download=1` = explicit download (attachment).
  After completion the same endpoints serve the SIGNED pdf (DocuSign "combined" document).

### 5.4 `.env`
```
DS_INTEGRATION_KEY=...      DS_USER_ID=<api user GUID>   DS_ACCOUNT_ID=<account GUID>
DS_PRIVATE_KEY_PATH=private.key
DS_AUTH_SERVER=account-d.docusign.com
DS_BASE_PATH=https://demo.docusign.net/restapi
SF_ORG_ALIAS=plaid          PORTAL_BASE_URL=http://localhost:8001
```

---

## 6. End-to-end sequences

### Send (DPEG staff)
1. Wizard step 1–4 → `send(requestJson)`.
2. Controller: parse/validate → group selected associations by entity → skip entities whose
   primary isn't selected (warning) → `createMaster` (stores payload) → enqueue Sender.
3. Sender link per entity: build envelope (tabs + auto blocks + routing) → `sendEnvelope(env, true)`
   → read DocuSign id (direct property access; backstop = newest `dfsle__EnvelopeStatus__c` for
   the investment) → create one `Document_Copy__c` per recipient sharing the envelope id.
4. Bell notification "X envelope(s) sent, Y failed".

### Sign (investor, in portal)
1. Login → dashboard lists their copies (by ContactId) with computed `waitingOnName`.
2. Click Sign → SF re-check → DocuSign: ensure `clientUserId` → recipient view URL → iframe.
3. Investor signs (required secondary first; DocuSign enforces the order — the primary's
   createRecipientView is refused until routing 1 completed; the portal pre-empts this with
   the waiting label).
4. Page polls recipient status → navigates to callback → callback hits SF refresh →
   copies update (per-recipient), master metrics recalc.
5. Envelope completes when the primary (last routing) signs → everyone can View/Download the
   signed PDF in the portal; DPEG sees Completed on the master document page.

---

## 7. Gotcha index (read before building anything similar)

| # | Gotcha | Fix |
|---|---|---|
| 1 | `dfsle.X.y(...).z()` compile error | assign to variable, then call method |
| 2 | dfsle types not JSON-serializable | direct property access |
| 3 | `sendEnvelope` = callout + DML | one envelope per Queueable link |
| 4 | Duplicate tab dataLabels sync values | unique clientId per tab |
| 5 | pdf.js 4.x breaks under LWS | 3.11.174 legacy UMD + worker fallback |
| 6 | FlexiPage `<mode>Replace</mode>` rejected | only valid with parentFlexiPage — remove |
| 7 | MD child object deploy errors | sharing/bulk/streaming flags all-equal; deleteConstraint on required lookups |
| 8 | Envelope status polls return nothing | query `dfsle__SourceId__c` with 18 AND 15-char id |
| 9 | window.open after await = popup-blocked | open 'about:blank' synchronously, set href later |
| 10 | DocuSign demo vs production mix-up | verify with `dfsle.AccountService.getDocuSignUrl()`; ALL pieces in one environment |
| 11 | Production trial refuses go-live | API keys need demo env or a paid production account |
| 12 | JWT consent "no redirect URIs registered" | add redirect URI on the app FIRST, then consent |
| 13 | SDK `get_document` UnicodeDecodeError | raw REST GET for PDF bytes |
| 14 | IDM/download managers swallow PDF fetches | serve viewer bytes as base64 JSON |
| 15 | Chrome blocks public→localhost iframe redirect | poll recipient status from the parent page; don't rely on return_url |
| 16 | Envelope status ≠ recipient status | sync `dfsle__RecipientStatus__c` per copy (match by email) |
| 17 | Dashboard stale after out-of-band signing | self-heal refresh on load when pending docs exist |
| 18 | Embedded recipients get no email | that's the point — `clientUserId` set = portal-only delivery |

---

## 8. Production checklist (what to change from the POC)

- [ ] Paid DocuSign production account; promote the integration key (Go-Live, needs 20+ demo calls);
      reconnect dfsle to production; flip `.env` hosts + `envelopeLinkBase`.
- [ ] Replace `sf org display` auth with a **Connected-App JWT** flow (only `get_sf_session()` changes).
- [ ] **DocuSign Connect webhook** → portal endpoint for instant status push (drop dashboard
      self-heal polling; keep it as fallback).
- [ ] Real investor auth (SSO/passwords/reset), HTTPS, real DB instead of SQLite, secret management
      (never commit `.env`/`private.key` — both are gitignored).
- [ ] Optionally send signers as `dfsle.Recipient.newEmbeddedSigner(name, email, sourceId)` from
      the start (verified to exist in the toolkit) so no DocuSign email goes out at all —
      currently the portal converts recipients on first Sign click instead.
- [ ] Consider `frame_ancestors`/`message_origins` (DocuSign focused view) instead of the classic
      recipient view iframe.

## 9. Rebuilding a similar use case — order of work

1. **Verify the schema chain** from the anchor object to the people who sign (who is primary?
   who must sign? junction object?). Everything derives from data, not hardcoding.
2. **Verify the installed toolkit API** via Tooling `SymbolTable` — don't trust docs/memory.
3. **Verify the DocuSign environment** (`AccountService.getDocuSignUrl()`) before anything else.
4. Build the **tracking objects** first (master + per-recipient copies) — everything hangs off them.
5. Build the **service layer with a gateway seam**, then the Queueable sender, then the controller.
6. Build the **wizard LWCs** (spike pdf.js under LWS before committing to the canvas step).
7. Add the **status sync** (trigger + poll + per-recipient) and the tracking UI.
8. Expose the **portal REST API**, then build the portal (auth mapping → dashboard → embedded
   signing → viewer), expecting gotchas #13–15.
9. Test end-to-end with a multi-signer entity AND a single-signer entity AND a viewer.
