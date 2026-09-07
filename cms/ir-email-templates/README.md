# CMS Workspace — IR email templates

Salesforce CMS content backing the Marketing/Broadcast email sends. These are **not**
Metadata API components — there is no `ManagedContent` metadata type, so they cannot be
retrieved or deployed with `sf project deploy/retrieve`. They are created and read through
the Connect CMS REST API, and the JSON in this folder is the source of truth.

## Workspace

| | |
|---|---|
| Name | `IR email templates` |
| `ManagedContentSpace` Id | `0ZuHn000000NwRtKAK` |
| Content type | `sfdc_cms__email` |
| FQN prefix | `marketing--IR_email_templates.sfdc_cms__email--<contentKey>` |

## Contents of the workspace

| Title | Content key | Used by |
|---|---|---|
| CapitalCall | `MCY2Q5TWGPPBDCBHCGKFANIQ32UY` | `Investment_Broadcast_Flow` → `Send_CapitalCall_Email` |
| Distribution | `MC2ZFNQOUNKFGA3F34WWAMNW5WDY` | `Investment_Broadcast_Flow` → `Send_Distribution_Email` |
| Contribution Notice | `MCCDP7QM7AJZDJHGWQN5LKNTV6BU` | — |
| DPEG IR Deck Master | `MCW77MPWH6E5BWDFOUR3H2JGUURY` | — |
| **IR New Launch** | **`MCMAPWY4ZIZBA4REAUPWDOUBJSKA`** | — (not yet wired to a flow) |
| ~~IR New Launch (broken duplicate)~~ | `MC2NFAB276BNH73LAOQUOXM7RNCY` | delete in the CMS UI — double-escaped HTML |

## IR New Launch

Source: [`IR_New_Launch.email.json`](IR_New_Launch.email.json) — the exact POST body used to
create it. Regenerate with [`build_IR_New_Launch.py`](build_IR_New_Launch.py).

**Content variable** — declared in `sfdc_cms:schema` and referenced as `{{$content.Name}}`:

| Variable | Type | Where it appears |
|---|---|---|
| `Name` | `lightning__textType` | subject line, hero headline, body sentence, offering row |

A flow supplies it the same way `Send_CapitalCall_Email` supplies `testName` — a
`contentSchemaParameter` transform with `outputFieldApiName: Name`.

Other merge fields used:

- `{!$unifiedIndividual.ssot__FirstName__c}` — recipient first name, via the
  `sfdc_cms__unifiedIndividualDataProvider` data provider on `UnifiedssotIndividualInvr__dlm`
- `{!$organization.Address}` and `{!$link.EmailAddressOptOutUrl}` — CAN-SPAM footer

**Brand palette** (taken from dhananipeg.com):
`#0e3416` forest green · `#4db892` mint accent · `#f5f2ea` cream · `#e0ddd4` sand.
Site fonts (Canela, Macklin Display, Helvetica Now) are licensed and unavailable in email,
so the template falls back to Georgia serif for display and Helvetica/Arial for body.

## Working with these via the API

```bash
TOKEN=$(sf org display -o plaid --json | python -c "import sys,json;print(json.load(sys.stdin)['result']['accessToken'])")
BASE=https://av1776338179294.my.salesforce.com/services/data/v67.0/connect/cms

# read
curl -sk -H "Authorization: Bearer $TOKEN" "$BASE/contents/MCMAPWY4ZIZBA4REAUPWDOUBJSKA"

# create
curl -sk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  --data-binary @IR_New_Launch.email.json "$BASE/contents"
```

### Gotchas

- The create payload field is **`contentBody`**, not `body`.
- Send **raw, unescaped HTML** in `rawHtml` / `text`. The API HTML-escapes on write; pre-escaping
  double-escapes and the email renders as visible markup.
- `lightning/section` rejects `lightning:colorGroup` (`additionalProperties: false`). Set band
  backgrounds inside the block HTML instead.
- `lightning:typography.letterSpacing` only accepts `normal`. Use CSS `letter-spacing` in the
  block HTML for tracking.
- `/connect/cms/contents/{key}` is **GET/HEAD only** — no update or delete. Edits and deletions
  happen in the CMS UI, or by creating a new content item.
- `urlName` in the POST body is ignored; the URL name comes from `sfdc_cms:urlName` **inside**
  `contentBody`. Set both or you get a duplicate URL name and two indistinguishable items.

### Verifying an `lightning/html` block round-tripped correctly

Fetch the content and look at `rawHtml`. It must be escaped exactly **once**:

| Stored form | Meaning |
|---|---|
| `&lt;table role=&quot;...` | correct — renders as HTML |
| `&amp;lt;table role&amp;#61;...` | double-escaped — renders as visible markup |

The API escapes on write, so always POST raw, unescaped HTML.
