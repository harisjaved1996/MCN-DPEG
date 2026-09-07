// Loads/refreshes the Lightning (SFX) EmailTemplate RECORDS in the IR_Email_Templates_Lightning
// folder via direct DML (NOT Metadata API deploy). EmailTemplate is a real sObject, so per an
// explicit user decision these records are captured and reproduced as DATA, the same way
// scripts/load-task-group-defs.apex and scripts/load-transaction-task-defs.apex reproduce Custom
// Metadata records as data instead of relying on a file-based deploy. Idempotent: upserts each
// template by DeveloperName, safe to re-run.
//
// Loads TWO templates, both into the SAME folder (IR_Email_Templates_Lightning):
//   1. IR Lead Notification Email  (DeveloperName IR_Lead_Notification_Email)      -- added 2026-08-15
//   2. Investor Welcome Email      (DeveloperName Investor_Welcome_Email_LTN)      -- added 2026-08-16
//
// Source of truth / companion files (human-readable, diffable copies of what this script writes):
//   scripts/email-templates/IR_Lead_Notification_Email.html / .json
//   scripts/email-templates/Investor_Welcome_Email.html / .json
// Apex has no filesystem access at runtime, so this script embeds its own copy of each body (as
// base64, decoded below) and the scalar values directly, matching the existing CMDT loader
// precedent. If either .html file changes, regenerate its base64 blob and keep the matching .json
// file's values in sync with the literals used here.
//
// ============================================================================================
// MEASURED 2026-08-15/16 (do not re-derive these without re-testing; each was empirically
// confirmed against DPEG-IR-Implementation, not merely read off the describe):
//
// 1. Markup CANNOT be set via DML for either template, in this org or ANY org. The describe
//    reports Markup as createable=true/updateable=true (FLS/CRUD says yes), but an actual DML
//    update attempt was REJECTED by a platform business rule:
//        FIELD_INTEGRITY_EXCEPTION, Markup can only be specified for template of type Visualforce
//    Both templates' TemplateType is 'custom' (SFX/Lightning Builder), not 'visualforce' - so this
//    is a hard, permanent platform restriction tied to TemplateType, not a permission gap. No
//    profile/permission-set change and no different org can make this writable for an SFX
//    template. Markup is therefore intentionally never set by this script.
//
// 2. IsBuilderContent CANNOT be set via DML at all (describe: createable=false, updateable=false).
//    A disposable insert+delete probe (UiType='SFX', TemplateType='custom', no Markup) produced
//    IsBuilderContent=FALSE on a fresh record - NOT true. A template loaded by this script into a
//    new org will read IsBuilderContent=false until a human opens and saves it once through
//    Setup's Email Template Builder UI - that state is not reproducible by any API-based load.
//    This is NOT expected to affect what a template actually sends - HtmlValue is the field
//    Flow's "Send Email" / Messaging email actions render from (confirmed separately against this
//    org) - but a user opening a loaded record in Setup may see it offered as a plain editable
//    template rather than opening directly into a populated Builder canvas.
//
// 3. EmailTemplate.DeveloperName is unique ORG-WIDE, not merely per-folder. MEASURED via a
//    Savepoint-wrapped DML probe: inserting a second template with the DeveloperName of the
//    pre-existing CLASSIC (Aloha) template 'Investor_Welcome_Email' - even into a different
//    folder - was rejected with DUPLICATE_DEVELOPER_NAME. This is why the Lightning welcome
//    template below uses the distinct DeveloperName 'Investor_Welcome_Email_LTN' while keeping
//    the identical Name/label 'Investor Welcome Email' (Name has no such uniqueness constraint).
//
// CONSEQUENCE: this script fully reproduces each template's FUNCTIONAL send content (HtmlValue +
// every scalar field) in a portable, org-independent way. It does NOT and CANNOT reproduce a
// live-editable Builder canvas (Markup) for a Lightning/SFX template - that is a platform
// limitation, not a gap in this script.
// ============================================================================================

// --- STEP 1: resolve the shared folder by DeveloperName, once, for both templates. NEVER
// hardcode a Folder Id - that is the whole point of loading this as portable data instead of
// retrieved metadata. ---
List<Folder> folders = [
    SELECT Id
    FROM Folder
    WHERE DeveloperName = 'IR_Email_Templates_Lightning' AND Type = 'EmailTemplate'
    LIMIT 1
];
if (folders.isEmpty()) {
    throw new System.StringException(
        'Cannot load Lightning email templates: no Email folder with DeveloperName ' +
        '\'IR_Email_Templates_Lightning\' exists in this org. Deploy the folder metadata first ' +
        '(force-app/main/default/email/IR_Email_Templates_Lightning.emailFolder-meta.xml), then ' +
        're-run this script.'
    );
}
Id folderId = folders[0].Id;

// ============================================================================================
// TEMPLATE 1: IR Lead Notification Email
// ============================================================================================

// --- STEP 2: decode the body. Base64 avoids Apex single-quote escaping issues from the
// apostrophes in the body's own HTML comment (action's, sender's, lead's, template's, Flow's). ---
String bodyBase64_1 =
    'PCFET0NUWVBFIGh0bWw+CjxodG1sPgo8aGVhZD4KICAgIDxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KICAgIDx0aXRsZT5OZXcgSW52ZXN0b3IgT25ib2FyZGluZyBMZWFkPC90aXRsZT4KPC9oZWFkPgo8Ym9keSBzdHlsZT0ibWFyZ2luOjA7IHBhZGRpbmc6MDsgYmFja2dyb3VuZC1jb2xvcjojZjRmNWY3OyBmb250LWZhbWlseTpBcmlhbCwgSGVsdmV0aWNhLCBzYW5zLXNlcmlmOyI+CiAgICA8dGFibGUgcm9sZT0icHJlc2VudGF0aW9uIiB3aWR0aD0iMTAwJSIgY2VsbHBhZGRpbmc9IjAiIGNlbGxzcGFjaW5nPSIwIiBzdHlsZT0iYmFja2dyb3VuZC1jb2xvcjojZjRmNWY3OyBwYWRkaW5nOjMycHggMDsiPgogICAgICAgIDx0cj4KICAgICAgICAgICAgPHRkIGFsaWduPSJjZW50ZXIiPgogICAgICAgICAgICAgICAgPHRhYmxlIHJvbGU9InByZXNlbnRhdGlvbiIgd2lkdGg9IjYwMCIgY2VsbHBhZGRpbmc9IjAiIGNlbGxzcGFjaW5nPSIwIiBzdHlsZT0iYmFja2dyb3VuZC1jb2xvcjojZmZmZmZmOyBib3JkZXItcmFkaXVzOjhweDsgb3ZlcmZsb3c6aGlkZGVuOyBib3gtc2hhZG93OjAgMXB4IDNweCByZ2JhKDAsMCwwLDAuMTIpOyI+CiAgICAgICAgICAgICAgICAgICAgPHRyPgogICAgICAgICAgICAgICAgICAgICAgICA8dGQgc3R5bGU9ImJhY2tncm91bmQtY29sb3I6I0I4NUQwRDsgcGFkZGluZzoyNHB4IDMycHg7Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJjb2xvcjojZmZmZmZmOyBmb250LXNpemU6MjBweDsgZm9udC13ZWlnaHQ6Ym9sZDsgbGV0dGVyLXNwYWNpbmc6MC4zcHg7Ij5EUEVHIEludmVzdG9yIFJlbGF0aW9uczwvc3Bhbj4KICAgICAgICAgICAgICAgICAgICAgICAgPC90ZD4KICAgICAgICAgICAgICAgICAgICA8L3RyPgogICAgICAgICAgICAgICAgICAgIDx0cj4KICAgICAgICAgICAgICAgICAgICAgICAgPHRkIHN0eWxlPSJwYWRkaW5nOjMycHg7Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxwIHN0eWxlPSJtYXJnaW4tdG9wOjA7IGZvbnQtc2l6ZToxNnB4OyBjb2xvcjojMWExYTFhOyI+SGkge3t7UmVjaXBpZW50LkZpcnN0TmFtZX19fSw8L3A+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPHAgc3R5bGU9ImZvbnQtc2l6ZToxNXB4OyBsaW5lLWhlaWdodDoxLjY7IGNvbG9yOiMzMzMzMzM7Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBBIG5ldyA8c3Ryb25nPkludmVzdG9yIE9uYm9hcmRpbmcgbGVhZDwvc3Ryb25nPiBoYXMgYXJyaXZlZCBpbiB0aGUKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8c3Ryb25nPkludmVzdG9yIE9uYm9hcmRpbmcgUXVldWU8L3N0cm9uZz4gYW5kIGlzIHdhaXRpbmcgdG8gYmUgcGlja2VkIHVwLgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9wPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBERUxJQkVSQVRFIC0gTk8gTEVBRCBNRVJHRSBGSUVMRFMgQVBQRUFSIElOIFRISVMgQk9EWS4gRE8gTk9UIEFERCBUSEVNLgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1lYXN1cmVkIGFnYWluc3QgdGhpcyBvcmc6IHRoaXMgdGVtcGxhdGUgaXMgc2VudCB2aWEgdGhlIEZsb3cgIlNlbmQgRW1haWwiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgY29yZSBhY3Rpb24gKGVtYWlsU2ltcGxlKSB3aXRoIHJlY2lwaWVudElkIHNldCB0byBhIHF1ZXVlLW1lbWJlciBVc2VyLiBUaGF0CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYWN0aW9uJ3MgV2hhdElkIChyZWxhdGVkUmVjb3JkSWQpIGlzIE5PVCBBVkFJTEFCTEUgd2hlbiByZWNpcGllbnRJZCBpcyBhCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVXNlciAtIFNhbGVzZm9yY2UgcmV0dXJucyBIVFRQIDQwMCAiV2hhdElkIGlzIG5vdCBhdmFpbGFibGUgZm9yIHNlbmRpbmcKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBlbWFpbHMgdG8gVXNlcklkcyIgaWYgcmVsYXRlZFJlY29yZElkIGlzIGFsc28gc3VwcGxpZWQuIEV2ZXJ5IG90aGVyIHRlc3RlZAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNvbWJpbmF0aW9uIGVpdGhlciBmYWlscyB0byBzYXZlIHRoZSB0ZW1wbGF0ZSwgcmVuZGVycyB0aGUgc2VuZGVyJ3Mgb3duIGRhdGEKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBpbnN0ZWFkIG9mIHRoZSBsZWFkJ3MsIG9yIHNlbmRzIHRoZSBub3RpZmljYXRpb24gVE8gdGhlIExlYWQgaW5zdGVhZCBvZiB0aGUKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBxdWV1ZSBtZW1iZXIuIFJlbGF0ZWRFbnRpdHlUeXBlIGlzIHNldCB0byBMZWFkIG9uIHRoaXMgdGVtcGxhdGUncyBtZXRhZGF0YQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBlciByZXF1aXJlbWVudCwgYnV0IHRoZSBzZW5kIHBhdGggZGVsaWJlcmF0ZWx5IG5ldmVyIHN1cHBsaWVzIGEKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICByZWxhdGVkUmVjb3JkSWQsIHNvIGEgbWVyZ2UgdG9rZW4gbmFtaW5nIGEgTGVhZCBmaWVsZCAoTGVhZCBkb3QgTmFtZSwgTGVhZAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGRvdCBFbWFpbCwgZXRjLCB3cml0dGVuIHdpdGggdGhlIHNhbWUgdHJpcGxlLWJyYWNlIGhhbmRsZWJhcnMgc3R5bGUgdXNlZCBmb3IKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB0aGUgUmVjaXBpZW50IHRva2VuIGFib3ZlKSB3b3VsZCByZW5kZXIgYmxhbmsgYXQgYmVzdCBhbmQgYnJlYWsgdGhlIHNlbmQgYXQKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB3b3JzdCAtIGl0IG1heSBhbHNvIGZhaWwgdG8gc2F2ZSBhdCBhbGwsIHNpbmNlIHRoZSBwbGF0Zm9ybSB2YWxpZGF0ZXMgbWVyZ2UKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB0b2tlbnMgYWdhaW5zdCB0aGUgdGVtcGxhdGUncyBjb25maWd1cmVkIG1lcmdlIGNvbnRleHQuIElmIGxlYWQgZGV0YWlsIGlzCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZXZlciBuZWVkZWQgaW4gdGhpcyBlbWFpbCwgaXQgcmVxdWlyZXMgYSBkaWZmZXJlbnQgZGVsaXZlcnkgbWVjaGFuaXNtIChmb3IKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBleGFtcGxlIGFuIGFzc2lnbm1lbnQtcnVsZS1kcml2ZW4gY2xhc3NpYyB0ZW1wbGF0ZSwgd2hpY2ggcmVzb2x2ZXMgdGhlIExlYWQKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBhcyB0aGUgbWVyZ2UgY29udGV4dCBkaXJlY3RseSksIG5vdCBhIGNoYW5nZSB0byB0aGlzIHRlbXBsYXRlLiBTZWUKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBJUl9MZWFkX05vdGlmaWNhdGlvbl9GbG93J3MgZGVzY3JpcHRpb24gZm9yIHRoZSBmdWxsIHNldCBvZiBtZWFzdXJlbWVudHMuCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxwIHN0eWxlPSJmb250LXNpemU6MTVweDsgbGluZS1oZWlnaHQ6MS42OyBjb2xvcjojMzMzMzMzOyI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUGxlYXNlIHRha2UgYSBtb21lbnQgdG8gb3BlbiB0aGUgcXVldWUsIHJldmlldyB0aGUgbGVhZCwgYW5kIGNsYWltIGl0IHNvIHdlIGNhbgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGtlZXAgdGhlIG9uYm9hcmRpbmcgZXhwZXJpZW5jZSBtb3ZpbmcgcXVpY2tseSBmb3Igb3VyIGludmVzdG9yLgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9wPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDx0YWJsZSByb2xlPSJwcmVzZW50YXRpb24iIGNlbGxwYWRkaW5nPSIwIiBjZWxsc3BhY2luZz0iMCIgc3R5bGU9Im1hcmdpbjoyOHB4IDA7Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8dHI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDx0ZCBzdHlsZT0iYmFja2dyb3VuZC1jb2xvcjojRkRGMUU3OyBib3JkZXI6MXB4IHNvbGlkICNCODVEMEQ7IGJvcmRlci1yYWRpdXM6NnB4OyBwYWRkaW5nOjE2cHggMjBweDsiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPHNwYW4gc3R5bGU9ImZvbnQtc2l6ZToxNXB4OyBmb250LXdlaWdodDpib2xkOyBjb2xvcjojQjg1RDBEOyI+QWN0aW9uIG5lZWRlZDo8L3NwYW4+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8c3BhbiBzdHlsZT0iZm9udC1zaXplOjE1cHg7IGNvbG9yOiMzMzMzMzM7Ij4gT3BlbiB0aGUgPHN0cm9uZz5JbnZlc3RvciBPbmJvYXJkaW5nIFF1ZXVlPC9zdHJvbmc+IGxpc3QgdmlldyBpbiBTYWxlc2ZvcmNlIHRvIHJldmlldyBhbmQgY2xhaW0gdGhpcyBsZWFkLjwvc3Bhbj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L3RkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvdHI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L3RhYmxlPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxwIHN0eWxlPSJmb250LXNpemU6MTVweDsgbGluZS1oZWlnaHQ6MS42OyBjb2xvcjojMzMzMzMzOyI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGhhbmsgeW91IGZvciBoZWxwaW5nIHVzIGdpdmUgZXZlcnkgaW52ZXN0b3IgYSBncmVhdCBmaXJzdCBleHBlcmllbmNlLgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9wPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxwIHN0eWxlPSJmb250LXNpemU6MTVweDsgY29sb3I6IzMzMzMzMzsgbWFyZ2luLWJvdHRvbTowOyI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmVzdCByZWdhcmRzLDxicj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBJbnZlc3RvciBSZWxhdGlvbnMgVGVhbQogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9wPgogICAgICAgICAgICAgICAgICAgICAgICA8L3RkPgogICAgICAgICAgICAgICAgICAgIDwvdHI+CiAgICAgICAgICAgICAgICAgICAgPHRyPgogICAgICAgICAgICAgICAgICAgICAgICA8dGQgc3R5bGU9ImJhY2tncm91bmQtY29sb3I6I2Y0ZjVmNzsgcGFkZGluZzoxNnB4IDMycHg7IHRleHQtYWxpZ246Y2VudGVyOyI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8c3BhbiBzdHlsZT0iZm9udC1zaXplOjEycHg7IGNvbG9yOiM4YThhOGE7Ij5EUEVHICZtaWRkb3Q7IEludmVzdG9yIFJlbGF0aW9uczwvc3Bhbj4KICAgICAgICAgICAgICAgICAgICAgICAgPC90ZD4KICAgICAgICAgICAgICAgICAgICA8L3RyPgogICAgICAgICAgICAgICAgPC90YWJsZT4KICAgICAgICAgICAgPC90ZD4KICAgICAgICA8L3RyPgogICAgPC90YWJsZT4KPC9ib2R5Pgo8L2h0bWw+Cg==';
String htmlBody_1 = EncodingUtil.base64Decode(bodyBase64_1).toString();

// --- STEP 3: scalar fields (kept in sync with scripts/email-templates/IR_Lead_Notification_Email.json). ---
String devName_1 = 'IR_Lead_Notification_Email';
String recordName_1 = 'IR Lead Notification Email';
String subject_1 = 'New Investor Onboarding lead in the IR queue';
String uiType_1 = 'SFX';
String templateType_1 = 'custom';
String relatedEntityType_1 = 'Lead';
String templateStyle_1 = 'none'; // insert-only: describe-measured updateable=false
String encoding_1 = 'UTF-8';
Boolean isActive_1 = true;
String description_1 = 'Lightning (SFX) notification email sent to Investor Onboarding Queue members ' +
    'when a new Investor Onboarding lead arrives in the queue. Sent by IR_Lead_Notification_Flow ' +
    'to each active queue member individually (recipientId = the member User). ' +
    'RelatedEntityType is set to Lead per requirement, but no Lead merge fields are used in the ' +
    'body -- see the body\'s own HTML comment and IR_Lead_Notification_Flow\'s description for ' +
    'why (measured: an emailSimple send to a User recipientId cannot also carry a Lead ' +
    'relatedRecordId in this org).';

// --- STEP 4: idempotent upsert-by-DeveloperName. ---
List<EmailTemplate> existing_1 = [
    SELECT Id
    FROM EmailTemplate
    WHERE DeveloperName = :devName_1
    LIMIT 1
];

if (existing_1.isEmpty()) {
    EmailTemplate t1 = new EmailTemplate(
        Name = recordName_1,
        DeveloperName = devName_1,
        FolderId = folderId,
        Subject = subject_1,
        HtmlValue = htmlBody_1,
        UiType = uiType_1,
        TemplateType = templateType_1,
        RelatedEntityType = relatedEntityType_1,
        TemplateStyle = templateStyle_1,
        Encoding = encoding_1,
        IsActive = isActive_1,
        Description = description_1
    );
    insert t1;
    System.debug(LoggingLevel.INFO, 'Inserted new EmailTemplate ' + devName_1 + ': ' + t1.Id);
} else {
    Id existingId_1 = existing_1[0].Id;
    EmailTemplate t1 = new EmailTemplate(
        Id = existingId_1,
        Subject = subject_1,
        HtmlValue = htmlBody_1,
        UiType = uiType_1,
        RelatedEntityType = relatedEntityType_1,
        Encoding = encoding_1,
        IsActive = isActive_1,
        Description = description_1
        // TemplateStyle, TemplateType, DeveloperName, FolderId deliberately omitted on update:
        // TemplateStyle is not updateable once set (measured); the other three are structural
        // identity/location fields that a body/content refresh should never silently move.
    );
    update t1;
    System.debug(LoggingLevel.INFO, 'Updated existing EmailTemplate ' + devName_1 + ': ' + existingId_1);
}

// ============================================================================================
// TEMPLATE 2: Investor Welcome Email (Lightning/SFX) - added 2026-08-16
// Replaces the CLASSIC (Aloha) 'Investor Welcome Email' template as the one Investor_Welcome_Flow
// sends. The classic template (DeveloperName Investor_Welcome_Email, IR_Email_Templates folder) is
// left untouched and unreferenced -- not modified or deleted by this script.
// ============================================================================================

// --- STEP 5: decode the body. ---
String bodyBase64_2 =
    'PCFET0NUWVBFIGh0bWw+CjxodG1sPgo8aGVhZD4KPG1ldGEgY2hhcnNldD0iVVRGLTgiPgo8bWV0YSBuYW1lPSJ2aWV3cG9ydCIgY29udGVudD0id2lkdGg9ZGV2aWNlLXdpZHRoLCBpbml0aWFsLXNjYWxlPTEuMCI+CjxtZXRhIGh0dHAtZXF1aXY9IlgtVUEtQ29tcGF0aWJsZSIgY29udGVudD0iSUU9ZWRnZSI+Cjx0aXRsZT5XZWxjb21lIHRvIERQRUcgSW52ZXN0b3IgUmVsYXRpb25zPC90aXRsZT4KPC9oZWFkPgo8IS0tIFJlY29yZC1iYXNlZCwgbm90IG1ldGFkYXRhLWJhc2VkOiBsb2FkZWQgYnkgc2NyaXB0cy9sb2FkLWxpZ2h0bmluZy1lbWFpbC10ZW1wbGF0ZXMuYXBleAogICAgIChURU1QTEFURSAyIGJhc2U2NCBibG9iKS4gRWRpdCB0aGlzIGZpbGUsIHJlZ2VuZXJhdGUgdGhhdCBibG9iLCByZS1ydW4gdGhlIGxvYWRlci4KICAgICBMYXlvdXQgaXMgZGVsaWJlcmF0ZWx5IHRhYmxlLWJhc2VkIHdpdGggaW5saW5lIHN0eWxlcyBvbmx5LCBhbmQgY2FycmllcyBubyBleHRlcm5hbCBhc3NldHMuCiAgICAgSW5kZW50YXRpb24gaXMga2VwdCB0aWdodCBvbiBwdXJwb3NlOiB0aGlzIHdob2xlIGZpbGUgaXMgYmFzZTY0LWVtYmVkZGVkIGludG8gYW4gYW5vbnltb3VzCiAgICAgQXBleCBzY3JpcHQgdGhhdCBoYXMgYSB+MzIsMDAwLWNoYXJhY3RlciBjZWlsaW5nLiBTZWUgSW52ZXN0b3JfV2VsY29tZV9FbWFpbC5qc29uIC0+CiAgICAgX2h0bWxfYXV0aG9yaW5nX2NvbnN0cmFpbnRzIGJlZm9yZSByZXN0eWxpbmcgYW55dGhpbmcuIC0tPgo8Ym9keSBzdHlsZT0ibWFyZ2luOjA7IHBhZGRpbmc6MDsgYmFja2dyb3VuZC1jb2xvcjojZWVmMGY0OyBmb250LWZhbWlseTonU2Vnb2UgVUknLCBSb2JvdG8sICdIZWx2ZXRpY2EgTmV1ZScsIEhlbHZldGljYSwgQXJpYWwsIHNhbnMtc2VyaWY7IC13ZWJraXQtZm9udC1zbW9vdGhpbmc6YW50aWFsaWFzZWQ7Ij4KCjxkaXYgc3R5bGU9ImRpc3BsYXk6bm9uZTsgZm9udC1zaXplOjA7IGxpbmUtaGVpZ2h0OjA7IG1heC1oZWlnaHQ6MDsgbWF4LXdpZHRoOjA7IG9wYWNpdHk6MDsgb3ZlcmZsb3c6aGlkZGVuOyBtc28taGlkZTphbGw7Ij4KV2VsY29tZSB0byBEUEVHICZtZGFzaDsgaGVyZSBpcyB3aGF0IGhhcHBlbnMgbmV4dCBpbiB5b3VyIGludmVzdG9yIG9uYm9hcmRpbmcuCjwvZGl2PgoKPHRhYmxlIHJvbGU9InByZXNlbnRhdGlvbiIgd2lkdGg9IjEwMCUiIGNlbGxwYWRkaW5nPSIwIiBjZWxsc3BhY2luZz0iMCIgYm9yZGVyPSIwIiBzdHlsZT0iYmFja2dyb3VuZC1jb2xvcjojZWVmMGY0OyBwYWRkaW5nOjMycHggMTJweDsiPgo8dHI+Cjx0ZCBhbGlnbj0iY2VudGVyIj4KCjx0YWJsZSByb2xlPSJwcmVzZW50YXRpb24iIHdpZHRoPSI2MDAiIGNlbGxwYWRkaW5nPSIwIiBjZWxsc3BhY2luZz0iMCIgYm9yZGVyPSIwIiBzdHlsZT0id2lkdGg6MTAwJTsgbWF4LXdpZHRoOjYwMHB4OyBiYWNrZ3JvdW5kLWNvbG9yOiNmZmZmZmY7IGJvcmRlci1yYWRpdXM6MTJweDsgb3ZlcmZsb3c6aGlkZGVuOyBib3gtc2hhZG93OjAgMnB4IDhweCByZ2JhKDE2LDI0LDQwLDAuMDgpOyI+Cgo8dHI+Cjx0ZCBzdHlsZT0iYmFja2dyb3VuZC1jb2xvcjojQjg1RDBEOyBwYWRkaW5nOjI4cHggMzZweCAyNHB4IDM2cHg7Ij4KPHRhYmxlIHJvbGU9InByZXNlbnRhdGlvbiIgd2lkdGg9IjEwMCUiIGNlbGxwYWRkaW5nPSIwIiBjZWxsc3BhY2luZz0iMCIgYm9yZGVyPSIwIj4KPHRyPgo8dGQgc3R5bGU9ImZvbnQtc2l6ZToxM3B4OyBmb250LXdlaWdodDpib2xkOyBsZXR0ZXItc3BhY2luZzoxLjZweDsgY29sb3I6I0Y2RDlCRjsgdGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlOyI+RGhhbmFuaSBQcml2YXRlIEVxdWl0eSBHcm91cDwvdGQ+CjwvdHI+Cjx0cj4KPHRkIHN0eWxlPSJwYWRkaW5nLXRvcDo2cHg7IGZvbnQtc2l6ZToyNnB4OyBmb250LXdlaWdodDpib2xkOyBjb2xvcjojZmZmZmZmOyBsZXR0ZXItc3BhY2luZzotMC4ycHg7Ij5JbnZlc3RvciBSZWxhdGlvbnM8L3RkPgo8L3RyPgo8L3RhYmxlPgo8L3RkPgo8L3RyPgoKPHRyPgo8dGQgc3R5bGU9ImhlaWdodDo0cHg7IGxpbmUtaGVpZ2h0OjRweDsgZm9udC1zaXplOjA7IGJhY2tncm91bmQtY29sb3I6I0Q5ODMyNDsiPiZuYnNwOzwvdGQ+CjwvdHI+Cgo8dHI+Cjx0ZCBzdHlsZT0icGFkZGluZzozNnB4IDM2cHggOHB4IDM2cHg7Ij4KPHAgc3R5bGU9Im1hcmdpbjowIDAgNnB4IDA7IGZvbnQtc2l6ZToxNXB4OyBjb2xvcjojQjg1RDBEOyBmb250LXdlaWdodDpib2xkOyI+SGkge3t7UmVjaXBpZW50LkZpcnN0TmFtZX19fSw8L3A+CjxwIHN0eWxlPSJtYXJnaW46MCAwIDIwcHggMDsgZm9udC1zaXplOjI0cHg7IGxpbmUtaGVpZ2h0OjEuMzsgY29sb3I6IzEwMTgyODsgZm9udC13ZWlnaHQ6Ym9sZDsgbGV0dGVyLXNwYWNpbmc6LTAuM3B4OyI+V2VsY29tZSBhYm9hcmQuIFdlIGFyZSBnbGFkIHlvdSBhcmUgaGVyZS48L3A+CjxwIHN0eWxlPSJtYXJnaW46MDsgZm9udC1zaXplOjE1cHg7IGxpbmUtaGVpZ2h0OjEuNzsgY29sb3I6IzQ3NTQ2NzsiPlRoYW5rIHlvdSBmb3Igam9pbmluZyB0aGUgRFBFRyA8c3Ryb25nIHN0eWxlPSJjb2xvcjojMTAxODI4OyI+SW52ZXN0b3IgUmVsYXRpb25zPC9zdHJvbmc+IHByb2dyYW1tZS4gV2UgYXJlIGRlbGlnaHRlZCB0byBjb3VudCB5b3UgYXMgcGFydCBvZiBvdXIgaW52ZXN0b3IgY29tbXVuaXR5LCBhbmQgd2UgbG9vayBmb3J3YXJkIHRvIGJ1aWxkaW5nIGEgc3Ryb25nLCBsb25nLXRlcm0gcmVsYXRpb25zaGlwIHdpdGggeW91LjwvcD4KPC90ZD4KPC90cj4KCjx0cj4KPHRkIHN0eWxlPSJwYWRkaW5nOjI4cHggMzZweCA0cHggMzZweDsiPgo8cCBzdHlsZT0ibWFyZ2luOjAgMCAxOHB4IDA7IGZvbnQtc2l6ZToxMnB4OyBmb250LXdlaWdodDpib2xkOyBsZXR0ZXItc3BhY2luZzoxLjJweDsgY29sb3I6Izk4QTJCMzsgdGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlOyI+V2hhdCBoYXBwZW5zIG5leHQ8L3A+Cgo8dGFibGUgcm9sZT0icHJlc2VudGF0aW9uIiB3aWR0aD0iMTAwJSIgY2VsbHBhZGRpbmc9IjAiIGNlbGxzcGFjaW5nPSIwIiBib3JkZXI9IjAiPgo8dHI+Cjx0ZCB3aWR0aD0iNDAiIHZhbGlnbj0idG9wIiBzdHlsZT0icGFkZGluZy1ib3R0b206MThweDsiPgo8dGFibGUgcm9sZT0icHJlc2VudGF0aW9uIiBjZWxscGFkZGluZz0iMCIgY2VsbHNwYWNpbmc9IjAiIGJvcmRlcj0iMCI+Cjx0cj48dGQgd2lkdGg9IjI4IiBoZWlnaHQ9IjI4IiBhbGlnbj0iY2VudGVyIiB2YWxpZ249Im1pZGRsZSIgc3R5bGU9IndpZHRoOjI4cHg7IGhlaWdodDoyOHB4OyBiYWNrZ3JvdW5kLWNvbG9yOiNGREYxRTc7IGJvcmRlci1yYWRpdXM6MTRweDsgY29sb3I6I0I4NUQwRDsgZm9udC1zaXplOjEzcHg7IGZvbnQtd2VpZ2h0OmJvbGQ7Ij4xPC90ZD48L3RyPgo8L3RhYmxlPgo8L3RkPgo8dGQgdmFsaWduPSJ0b3AiIHN0eWxlPSJwYWRkaW5nLWJvdHRvbToxOHB4OyI+CjxwIHN0eWxlPSJtYXJnaW46MCAwIDNweCAwOyBmb250LXNpemU6MTVweDsgZm9udC13ZWlnaHQ6Ym9sZDsgY29sb3I6IzEwMTgyODsiPkEgcmVsYXRpb25zaGlwIG1hbmFnZXIgcmVhY2hlcyBvdXQ8L3A+CjxwIHN0eWxlPSJtYXJnaW46MDsgZm9udC1zaXplOjE0cHg7IGxpbmUtaGVpZ2h0OjEuNjsgY29sb3I6IzY2NzA4NTsiPllvdXIgZGVkaWNhdGVkIGNvbnRhY3Qgd2lsbCBpbnRyb2R1Y2UgdGhlbXNlbHZlcyBzaG9ydGx5IGFuZCBhbnN3ZXIgYW55IGVhcmx5IHF1ZXN0aW9ucy48L3A+CjwvdGQ+CjwvdHI+Cjx0cj4KPHRkIHdpZHRoPSI0MCIgdmFsaWduPSJ0b3AiIHN0eWxlPSJwYWRkaW5nLWJvdHRvbToxOHB4OyI+Cjx0YWJsZSByb2xlPSJwcmVzZW50YXRpb24iIGNlbGxwYWRkaW5nPSIwIiBjZWxsc3BhY2luZz0iMCIgYm9yZGVyPSIwIj4KPHRyPjx0ZCB3aWR0aD0iMjgiIGhlaWdodD0iMjgiIGFsaWduPSJjZW50ZXIiIHZhbGlnbj0ibWlkZGxlIiBzdHlsZT0id2lkdGg6MjhweDsgaGVpZ2h0OjI4cHg7IGJhY2tncm91bmQtY29sb3I6I0ZERjFFNzsgYm9yZGVyLXJhZGl1czoxNHB4OyBjb2xvcjojQjg1RDBEOyBmb250LXNpemU6MTNweDsgZm9udC13ZWlnaHQ6Ym9sZDsiPjI8L3RkPjwvdHI+CjwvdGFibGU+CjwvdGQ+Cjx0ZCB2YWxpZ249InRvcCIgc3R5bGU9InBhZGRpbmctYm90dG9tOjE4cHg7Ij4KPHAgc3R5bGU9Im1hcmdpbjowIDAgM3B4IDA7IGZvbnQtc2l6ZToxNXB4OyBmb250LXdlaWdodDpib2xkOyBjb2xvcjojMTAxODI4OyI+V2Ugd2FsayB5b3UgdGhyb3VnaCBvbmJvYXJkaW5nPC9wPgo8cCBzdHlsZT0ibWFyZ2luOjA7IGZvbnQtc2l6ZToxNHB4OyBsaW5lLWhlaWdodDoxLjY7IGNvbG9yOiM2NjcwODU7Ij5BIHNob3J0IGd1aWRlZCBzZXNzaW9uIGNvdmVyaW5nIGRvY3VtZW50YXRpb24sIHRpbWVsaW5lcyBhbmQgd2hhdCB3ZSB3aWxsIG5lZWQgZnJvbSB5b3UuPC9wPgo8L3RkPgo8L3RyPgo8dHI+Cjx0ZCB3aWR0aD0iNDAiIHZhbGlnbj0idG9wIiBzdHlsZT0icGFkZGluZy1ib3R0b206NHB4OyI+Cjx0YWJsZSByb2xlPSJwcmVzZW50YXRpb24iIGNlbGxwYWRkaW5nPSIwIiBjZWxsc3BhY2luZz0iMCIgYm9yZGVyPSIwIj4KPHRyPjx0ZCB3aWR0aD0iMjgiIGhlaWdodD0iMjgiIGFsaWduPSJjZW50ZXIiIHZhbGlnbj0ibWlkZGxlIiBzdHlsZT0id2lkdGg6MjhweDsgaGVpZ2h0OjI4cHg7IGJhY2tncm91bmQtY29sb3I6I0ZERjFFNzsgYm9yZGVyLXJhZGl1czoxNHB4OyBjb2xvcjojQjg1RDBEOyBmb250LXNpemU6MTNweDsgZm9udC13ZWlnaHQ6Ym9sZDsiPjM8L3RkPjwvdHI+CjwvdGFibGU+CjwvdGQ+Cjx0ZCB2YWxpZ249InRvcCIgc3R5bGU9InBhZGRpbmctYm90dG9tOjRweDsiPgo8cCBzdHlsZT0ibWFyZ2luOjAgMCAzcHggMDsgZm9udC1zaXplOjE1cHg7IGZvbnQtd2VpZ2h0OmJvbGQ7IGNvbG9yOiMxMDE4Mjg7Ij5Zb3UgZ2V0IHZpc2liaWxpdHkgaW50byB5b3VyIGludmVzdG1lbnRzPC9wPgo8cCBzdHlsZT0ibWFyZ2luOjA7IGZvbnQtc2l6ZToxNHB4OyBsaW5lLWhlaWdodDoxLjY7IGNvbG9yOiM2NjcwODU7Ij5TdGF0ZW1lbnRzLCBkaXN0cmlidXRpb25zIGFuZCBkb2N1bWVudHMsIGtlcHQgaW4gb25lIHBsYWNlIGFuZCBhbHdheXMgdXAgdG8gZGF0ZS48L3A+CjwvdGQ+CjwvdHI+CjwvdGFibGU+CjwvdGQ+CjwvdHI+Cgo8dHI+Cjx0ZCBzdHlsZT0icGFkZGluZzoyNHB4IDM2cHggOHB4IDM2cHg7Ij4KPHRhYmxlIHJvbGU9InByZXNlbnRhdGlvbiIgd2lkdGg9IjEwMCUiIGNlbGxwYWRkaW5nPSIwIiBjZWxsc3BhY2luZz0iMCIgYm9yZGVyPSIwIiBzdHlsZT0iYmFja2dyb3VuZC1jb2xvcjojRkRGMUU3OyBib3JkZXItbGVmdDo0cHggc29saWQgI0I4NUQwRDsgYm9yZGVyLXJhZGl1czo4cHg7Ij4KPHRyPgo8dGQgc3R5bGU9InBhZGRpbmc6MThweCAyMnB4OyI+CjxwIHN0eWxlPSJtYXJnaW46MCAwIDRweCAwOyBmb250LXNpemU6MTRweDsgZm9udC13ZWlnaHQ6Ym9sZDsgY29sb3I6IzhGNDgwQTsiPlF1ZXN0aW9ucyBpbiB0aGUgbWVhbnRpbWU/PC9wPgo8cCBzdHlsZT0ibWFyZ2luOjA7IGZvbnQtc2l6ZToxNHB4OyBsaW5lLWhlaWdodDoxLjY7IGNvbG9yOiM1QzQ2MzA7Ij5TaW1wbHkgcmVwbHkgdG8gdGhpcyBlbWFpbCBhbmQgb3VyIEludmVzdG9yIFJlbGF0aW9ucyB0ZWFtIHdpbGwgZ2V0IHN0cmFpZ2h0IGJhY2sgdG8geW91LiBXZSBhcmUgaGVyZSB0byBoZWxwLjwvcD4KPC90ZD4KPC90cj4KPC90YWJsZT4KPC90ZD4KPC90cj4KCjx0cj4KPHRkIHN0eWxlPSJwYWRkaW5nOjI0cHggMzZweCAzMnB4IDM2cHg7Ij4KPHAgc3R5bGU9Im1hcmdpbjowOyBmb250LXNpemU6MTVweDsgbGluZS1oZWlnaHQ6MS43OyBjb2xvcjojNDc1NDY3OyI+V2FybSByZWdhcmRzLDxicj4KPHN0cm9uZyBzdHlsZT0iY29sb3I6IzEwMTgyODsiPlRoZSBJbnZlc3RvciBSZWxhdGlvbnMgVGVhbTwvc3Ryb25nPjxicj4KPHNwYW4gc3R5bGU9ImNvbG9yOiM5OEEyQjM7IGZvbnQtc2l6ZToxNHB4OyI+RGhhbmFuaSBQcml2YXRlIEVxdWl0eSBHcm91cDwvc3Bhbj48L3A+CjwvdGQ+CjwvdHI+Cgo8dHI+Cjx0ZCBzdHlsZT0iYmFja2dyb3VuZC1jb2xvcjojRjdGOEZBOyBib3JkZXItdG9wOjFweCBzb2xpZCAjRTRFN0VDOyBwYWRkaW5nOjIwcHggMzZweDsgdGV4dC1hbGlnbjpjZW50ZXI7Ij4KPHAgc3R5bGU9Im1hcmdpbjowIDAgNHB4IDA7IGZvbnQtc2l6ZToxMnB4OyBmb250LXdlaWdodDpib2xkOyBjb2xvcjojNjY3MDg1OyBsZXR0ZXItc3BhY2luZzowLjRweDsiPkRQRUcgJm1pZGRvdDsgSW52ZXN0b3IgUmVsYXRpb25zPC9wPgo8cCBzdHlsZT0ibWFyZ2luOjA7IGZvbnQtc2l6ZToxMXB4OyBsaW5lLWhlaWdodDoxLjY7IGNvbG9yOiM5OEEyQjM7Ij5UaGlzIG1lc3NhZ2Ugd2FzIHNlbnQgdG8geW91IGJlY2F1c2UgeW91IHdlcmUgb25ib2FyZGVkIGFzIGFuIGludmVzdG9yIHdpdGggRGhhbmFuaSBQcml2YXRlIEVxdWl0eSBHcm91cC48L3A+CjwvdGQ+CjwvdHI+Cgo8L3RhYmxlPgoKPC90ZD4KPC90cj4KPC90YWJsZT4KCjwvYm9keT4KPC9odG1sPgo=';
String htmlBody_2 = EncodingUtil.base64Decode(bodyBase64_2).toString();

// --- STEP 6: scalar fields (kept in sync with scripts/email-templates/Investor_Welcome_Email.json). ---
String devName_2 = 'Investor_Welcome_Email_LTN';
String recordName_2 = 'Investor Welcome Email';
String subject_2 = 'Welcome to DPEG Investor Relations, {{{Recipient.FirstName}}}';
String uiType_2 = 'SFX';
String templateType_2 = 'custom';
String relatedEntityType_2 = 'Contact';
String templateStyle_2 = 'none'; // insert-only: describe-measured updateable=false
String encoding_2 = 'UTF-8';
Boolean isActive_2 = true;
String description_2 = 'Lightning (SFX) welcome email sent to a newly created Contact with the ' +
    'Investor record type. Sent by Investor_Welcome_Flow with recipientId = the new Contact, ' +
    'logEmailOnSend = true (so the send is logged on the Contact\'s own activity timeline). ' +
    'Replaces the classic (Aloha) Investor Welcome Email template (DeveloperName ' +
    'Investor_Welcome_Email, IR_Email_Templates folder), which is now unreferenced by any flow ' +
    'but left in place, untouched.';

// --- STEP 7: idempotent upsert-by-DeveloperName. ---
List<EmailTemplate> existing_2 = [
    SELECT Id
    FROM EmailTemplate
    WHERE DeveloperName = :devName_2
    LIMIT 1
];

if (existing_2.isEmpty()) {
    EmailTemplate t2 = new EmailTemplate(
        Name = recordName_2,
        DeveloperName = devName_2,
        FolderId = folderId,
        Subject = subject_2,
        HtmlValue = htmlBody_2,
        UiType = uiType_2,
        TemplateType = templateType_2,
        RelatedEntityType = relatedEntityType_2,
        TemplateStyle = templateStyle_2,
        Encoding = encoding_2,
        IsActive = isActive_2,
        Description = description_2
    );
    insert t2;
    System.debug(LoggingLevel.INFO, 'Inserted new EmailTemplate ' + devName_2 + ': ' + t2.Id);
} else {
    Id existingId_2 = existing_2[0].Id;
    EmailTemplate t2 = new EmailTemplate(
        Id = existingId_2,
        Subject = subject_2,
        HtmlValue = htmlBody_2,
        UiType = uiType_2,
        RelatedEntityType = relatedEntityType_2,
        Encoding = encoding_2,
        IsActive = isActive_2,
        Description = description_2
        // TemplateStyle, TemplateType, DeveloperName, FolderId deliberately omitted on update:
        // TemplateStyle is not updateable once set (measured); the other three are structural
        // identity/location fields that a body/content refresh should never silently move.
    );
    update t2;
    System.debug(LoggingLevel.INFO, 'Updated existing EmailTemplate ' + devName_2 + ': ' + existingId_2);
}
