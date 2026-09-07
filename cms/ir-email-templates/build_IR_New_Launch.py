# -*- coding: utf-8 -*-
import json, uuid, html, io, os, sys

G_DARK = "#0a2a12"
G = "#0e3416"
MINT = "#4db892"
CREAM = "#f5f2ea"
SAND = "#e0ddd4"
SANS = "'Helvetica Neue',Helvetica,Arial,sans-serif"
SERIF = "Georgia,'Times New Roman',Times,serif"
VAR = "{{$content.Name}}"
# $unifiedIndividual needs a data provider bound to the unified DMO and does
# NOT resolve in a broadcast send - the first two tests rendered "Dear ,".
# $recipient is the built-in send context and needs no provider; it is what
# the UI-authored Contribution Notice template uses.
FIRST = "{!$recipient.FirstName}"
OPTOUT = "{!$link.EmailAddressOptOutUrl}"
ORG_ADDRESS = "{!$organization.Address}"


def uid():
    return str(uuid.uuid4())


def html_block(raw):
    return {
        "attributes": {
            "lightning:borderRadius": "{!$brand.borderRadius.square}",
            "lightning:borderWidth": "{!$brand.borderWeight.none}",
            "lightning:colorGroup": {
                "backgroundColor": "{!$brand.colorScheme.root}",
                "borderColor": "{!$brand.colorScheme.neutral}",
                "linkColor": "{!$brand.colorScheme.primaryAccent}",
                "textColor": "{!$brand.colorScheme.contrast}",
            },
            "lightning:margin": "{!$brand.spacing.none}",
            "lightning:padding": "{!$brand.spacing.none}",
            "rawHtml": raw,
        },
        "definition": "lightning/html",
        "id": uid(),
        "type": "block",
    }


def paragraph(text, color="#6b7a6e", size=11, align="center", pad="{!$brand.spacing.xSmall}"):
    return {
        "attributes": {
            "align": align,
            "lightning:borderRadius": "{!$brand.borderRadius.square}",
            "lightning:borderWidth": "{!$brand.borderWeight.none}",
            "lightning:colorGroup": {
                "backgroundColor": "{!$brand.colorScheme.root}",
                "borderColor": "{!$brand.colorScheme.neutral}",
                "linkColor": G,
                "textColor": color,
            },
            "lightning:margin": "{!$brand.spacing.none}",
            "lightning:padding": pad,
            "lightning:typography": {
                "fontFamily": "{!$brand.fontFamily.verdana}",
                "fontSize": {"unit": "px", "value": float(size)},
                "fontWeight": "{!$brand.fontWeight.normal}",
                "letterSpacing": "normal",
                "lineHeight": 1.6,
                "textTransform": "none",
            },
            "text": text,
        },
        "definition": "lightning/paragraph",
        "id": uid(),
        "type": "block",
    }


def button(label, url):
    return {
        "attributes": {
            "lightning:borderRadius": {"unit": "px", "value": 2.0},
            "lightning:borderWidth": "{!$brand.buttonStyleGroup.primary.lightning:borderWidth}",
            "lightning:buttonColorGroup": {
                "backgroundColor": G,
                "backgroundHoverColor": "#1a5c30",
                "borderColor": G,
                "borderHoverColor": "#1a5c30",
                "textColor": "#FFFFFF",
                "textHoverColor": "#FFFFFF",
            },
            "lightning:click": {
                "actions": [
                    {
                        "attributes": {"openInNewTab": True, "url": url},
                        "definition": "sfdc_cms__navigateToUrlAction",
                        "generatedUrl": url,
                    }
                ]
            },
            "lightning:horizontalAlignment": "center",
            "lightning:margin": "{!$brand.spacing.none}",
            "lightning:padding": {
                "bottom": {"unit": "rem", "value": 0.85},
                "left": {"unit": "rem", "value": 2.25},
                "right": {"unit": "rem", "value": 2.25},
                "top": {"unit": "rem", "value": 0.85},
            },
            "lightning:typography": {
                "fontFamily": "{!$brand.fontFamily.verdana}",
                "fontSize": {"unit": "px", "value": 13.0},
                "fontWeight": "{!$brand.fontWeight.bold}",
                "letterSpacing": "normal",
                "lineHeight": 1.5,
                "textTransform": "uppercase",
            },
            "sfdc_cms:styleGroup": "{!$brand.buttonStyleGroup.primary}",
            "text": label,
        },
        "definition": "lightning/actionButton",
        "id": uid(),
        "type": "block",
    }


def column(children):
    return {
        "attributes": {
            "columnWidth": 12.0,
            "lightning:backgroundImage": {"position": "center center", "repeat": "no-repeat", "size": "cover"},
            "lightning:borderRadius": "{!$brand.borderRadius.square}",
            "lightning:borderWidth": "{!$brand.borderWeight.none}",
            "lightning:colorScheme": "{!$brand.colorScheme}",
            "lightning:margin": "{!$brand.spacing.none}",
            "lightning:padding": "{!$brand.spacing.none}",
            "lightning:verticalAlignment": "top",
        },
        "definition": "lightning/column",
        "id": uid(),
        "type": "block",
        "children": children,
    }


def section(children, bg, text_color="#FFFFFF"):
    return {
        "attributes": {
            "lightning:backgroundImage": {"position": "center center", "repeat": "no-repeat", "size": "cover"},
            "lightning:borderRadius": "{!$brand.borderRadius.square}",
            "lightning:borderWidth": "{!$brand.borderWeight.none}",
            "lightning:colorScheme": "{!$brand.colorScheme}",
            "lightning:margin": "{!$brand.spacing.none}",
            "lightning:padding": "{!$brand.spacing.none}",
            "stackOnMobile": True,
            "reverseOrderOnMobile": False,
        },
        "definition": "lightning/section",
        "id": uid(),
        "type": "block",
        "children": [column(children)],
    }


def row(label, value, last=False):
    border = "" if last else "border-bottom:1px solid " + SAND + ";"
    return (
        '<tr><td style="padding:14px 0;' + border + '">'
        '<div style="font-family:' + SANS + ';font-size:10px;font-weight:600;letter-spacing:2px;'
        'text-transform:uppercase;color:#7a8a7d;">' + label + '</div>'
        '<div style="font-family:' + SERIF + ';font-size:17px;line-height:1.4;color:' + G + ';'
        'padding-top:7px;">' + value + '</div>'
        '</td></tr>'
    )


TBL = ('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
       'style="border-collapse:collapse;')

hero = (
    TBL + 'background:' + G + ';">'
    '<tr><td style="height:4px;background:' + MINT + ';line-height:4px;font-size:0;">&nbsp;</td></tr>'
    '<tr><td align="center" style="padding:44px 32px 12px 32px;">'
    '<div style="font-family:' + SANS + ';font-size:13px;font-weight:600;letter-spacing:4px;'
    'text-transform:uppercase;color:' + CREAM + ';">Dhanani Private Equity Group</div>'
    '<div style="width:44px;height:2px;background:' + MINT + ';margin:18px auto 14px auto;'
    'line-height:2px;font-size:0;">&nbsp;</div>'
    '<div style="font-family:' + SANS + ';font-size:11px;line-height:1.5;letter-spacing:1.6px;'
    'text-transform:uppercase;color:#9fb5a5;">Houston-Based &middot; Family-Owned Real Estate Syndication</div>'
    '</td></tr>'
    '<tr><td align="center" style="padding:26px 32px 48px 32px;">'
    '<div style="font-family:' + SANS + ';font-size:11px;font-weight:700;letter-spacing:3.5px;'
    'text-transform:uppercase;color:' + MINT + ';padding-bottom:20px;">New Project Launch</div>'
    '<div style="font-family:' + SERIF + ';font-size:40px;line-height:1.18;color:#ffffff;">' + VAR + '</div>'
    '</td></tr></table>'
)

# Merge fields from a data provider ({!$unifiedIndividual...}) are silently
# blanked inside a lightning/html block - the first send rendered "Dear ,".
# Content variables ({{$content.Name}}) DO resolve there, which is why the hero
# worked. So anything carrying a data-provider merge field has to be a native
# block, and the greeting and body copy are paragraphs rather than raw HTML.
greeting_text = 'Dear ' + FIRST + ','

copy_text = ('DPEG is excited to launch our newest project, <strong>' + VAR + '</strong>. '
             'Please review the attached offering deck and reply to this email to confirm '
             'your commitment by the date below.')

card = (
    TBL + 'background:#ffffff;">'
    '<tr><td style="padding:4px 36px 0 36px;">'
    + TBL + 'background:' + CREAM + ';border-left:3px solid ' + G + ';" width="100%">'
    '<tr><td style="padding:6px 26px 10px 26px;">'
    + TBL + '" width="100%">'
    + row("Offering", VAR)
    + row("Location", "[location]")
    + row("Commitment Deadline", "[deadline]", last=True)
    + '</table></td></tr></table></td></tr></table>'
)

spacer = TBL + 'background:#ffffff;"><tr><td style="height:30px;line-height:30px;font-size:0;">&nbsp;</td></tr></table>'

closing = (
    TBL + 'background:#ffffff;">'
    '<tr><td style="padding:34px 36px 42px 36px;font-family:' + SANS + ';color:#1a1a1a;">'
    '<p style="margin:0;font-size:16px;line-height:1.7;">Thank you for your continued partnership.</p>'
    '<div style="width:34px;height:2px;background:' + MINT + ';margin:22px 0 14px 0;line-height:2px;'
    'font-size:0;">&nbsp;</div>'
    '<div style="font-family:' + SERIF + ';font-size:15px;line-height:1.5;color:' + G + ';">Investor Relations</div>'
    '<div style="font-family:' + SANS + ';font-size:12px;line-height:1.6;color:#6b7a6e;padding-top:3px;">'
    'Dhanani Private Equity Group</div>'
    '</td></tr></table>'
)

footer_top = (
    TBL + 'background:' + CREAM + ';">'
    '<tr><td style="height:3px;background:' + G + ';line-height:3px;font-size:0;">&nbsp;</td></tr>'
    '<tr><td align="center" style="padding:30px 32px 4px 32px;">'
    '<div style="font-family:' + SANS + ';font-size:11px;font-weight:600;letter-spacing:3px;'
    'text-transform:uppercase;color:' + G + ';">Dhanani Private Equity Group</div>'
    '<div style="width:28px;height:1px;background:' + SAND + ';margin:14px auto 0 auto;line-height:1px;'
    'font-size:0;">&nbsp;</div>'
    '</td></tr></table>'
)

BODY_PAD = {"top": {"unit": "rem", "value": 0.5}, "bottom": {"unit": "rem", "value": 0.25},
            "left": {"unit": "rem", "value": 2.25}, "right": {"unit": "rem", "value": 2.25}}
TOP_PAD = {"top": {"unit": "rem", "value": 2.5}, "bottom": {"unit": "rem", "value": 0.25},
           "left": {"unit": "rem", "value": 2.25}, "right": {"unit": "rem", "value": 2.25}}
FOOT_PAD = {"top": {"unit": "rem", "value": 0.25}, "bottom": {"unit": "rem", "value": 1.75},
            "left": {"unit": "rem", "value": 2.0}, "right": {"unit": "rem", "value": 2.0}}

blocks = [
    section([html_block(hero)], G),
    section(
        [paragraph(greeting_text, color="#1a1a1a", size=16, align="left", pad=TOP_PAD),
         paragraph(copy_text, color="#1a1a1a", size=16, align="left", pad=BODY_PAD),
         html_block(card),
         html_block(spacer),
         button("View the Offering", "https://dhananipeg.com/"),
         html_block(closing)],
        "#ffffff", text_color="#1a1a1a",
    ),
    section(
        [html_block(footer_top),
         # Unsubscribe as a real anchor rather than a bare URL. The first send
         # printed the whole tracking link as visible text, which is unreadable
         # and looks broken.
         paragraph(
             '<a href="' + OPTOUT + '">Unsubscribe</a>',
             color="#6b7a6e", size=11, pad=FOOT_PAD),
         # Org address is required for CAN-SPAM. It renders as the literal
         # token [organization:Address] until Setup > Company Information has
         # a street/city/state/postcode filled in.
         paragraph(ORG_ADDRESS, color="#8a978d", size=11, pad=FOOT_PAD)],
        CREAM, text_color="#6b7a6e",
    ),
]

content_body = {
    "backgroundColor": "#eceae3",
    "lightning:backgroundImage": {"position": "center center", "repeat": "no-repeat", "size": "cover"},
    "lightning:brandSource": {"defaultBrandOption": "sfdcBrand"},
    "lightning:colorScheme": "{!$brand.colorScheme}",
    "lightning:dataProviders": [],
    "lightning:expressions": [],
    "lightning:padding": "{!$brand.spacing.none}",
    "messagePurpose": "promotional",
    "sfdc_cms:attachments": [],
    "sfdc_cms:block": {
        "definition": "sfdc_cms/rootContentBlock",
        "id": uid(),
        "type": "block",
        "children": blocks,
    },
    "sfdc_cms:schema": {
        "$schema": "sfdc://metaschema/sfdc_cms__propertyType",
        "properties": {
            "Name": {
                "title": "Name",
                "type": "string",
                "$ref": "sfdc:propertyType/lightning__textType",
                "lightning:type": "lightning__textType",
            }
        },
        "type": "object",
    },
    "sfdc_cms:title": "IR New Launch",
    "sfdc_cms:urlName": "ir-new-launch-v3",
    "subjectLine": "New Project Launch - {{$content.Name}}",
    "sfdc_cms:variants": [],
}

payload = {
    "contentSpaceOrFolderId": "0ZuHn000000NwRtKAK",
    "contentType": "sfdc_cms__email",
    "title": "IR New Launch",
    "urlName": "ir-new-launch-v3",
    "body": content_body,
}

out = sys.argv[1]
with io.open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2, ensure_ascii=False)
print("written:", out, os.path.getsize(out), "bytes")
