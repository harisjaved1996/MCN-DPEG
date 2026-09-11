/**
 * OfferingEmailSender — sends a rendered HTML email to internal Users from Flow, driving the subject
 * and body from a stored EmailTemplate and merging record values into them.
 *
 * Built for IR_Offering_Notification_Flow, which notifies every active member of the Offering Queue
 * when a new Offering lands there. Nothing in the class is Offering-specific, so any record-triggered
 * flow that needs a branded HTML notification can reuse it.
 *
 * WHY THIS EXISTS. The standard Flow "Send Email" core action (emailSimple) cannot do both halves of
 * what an internal record notification needs. MEASURED against this org on API 67:
 *   - emailBody + recipientId       -> fails outright: CANNOT_EXECUTE_FLOW_TRIGGER, "0 recipients".
 *                                      recipientId resolves an address only on the emailTemplateId path,
 *                                      and a record-triggered flow error aborts the save, so this also
 *                                      blocked record creation entirely.
 *   - emailBody + emailAddresses    -> delivers, but always as text/plain; the recipient sees raw markup.
 *                                      richTextFormattedBody=true and a Text Template with
 *                                      isViewedAsPlainText=false were both verified present in the
 *                                      retrieved org copy, and the body was tried as CDATA and as escaped
 *                                      entities. No effect.
 *   - emailTemplateId + recipientId -> renders HTML, but the template cannot merge the triggering record's
 *                                      fields: relatedRecordId is rejected alongside a User recipientId
 *                                      ("WhatId is not available for sending emails to UserIds", HTTP 400).
 * So through emailSimple, rendered HTML and record-specific content are mutually exclusive.
 * Messaging.SingleEmailMessage.setHtmlBody() has neither limitation, hence this class.
 *
 * PORTABILITY IS THE POINT. Callers name the template by DeveloperName, never by Id, so the same flow
 * metadata works in any org: deploy the metadata, run
 * scripts/apex/investor-relations/load-lightning-email-templates.apex to create the template records,
 * and the flow finds them. Nothing has to be rebuilt by hand in the target org, and no template body is
 * duplicated between a flow and a template record.
 *
 * WHY setTargetObjectId RATHER THAN setToAddresses. Single emails addressed to internal Users via
 * targetObjectId do NOT count against the org's daily single-email limit; sends to raw addresses do.
 * These are per-record notifications, so the difference compounds.
 *
 * BULK-SAFE BY DESIGN. Messaging.sendEmail counts against the EmailInvocations governor, which allows
 * only 10 calls per transaction. Callers therefore pass the WHOLE recipient collection in one request and
 * this class issues a single sendEmail across every request. Do NOT call it from inside a Flow loop —
 * that reintroduces the ceiling and caps a queue at 10 members.
 *
 * TOKENS. The platform's own {{{...}}} merge syntax cannot be used here: it is resolved by the send
 * pipeline, which is exactly the pipeline that refuses to give us a record context. So subjects and bodies
 * carry literal %%...%% tokens, substituted below before the message is built:
 *
 *   TOKEN           WORKS IN          MEANING
 *   %%FIRSTNAME%%   subject + body    the recipient's FirstName, or "there" when blank.
 *   %%RECORDNAME%%  subject + body    the triggering record's name, from the caller.
 *   %%RECORDID%%    body only         the triggering record's Id, for links.
 *   %%BASEURL%%     body only         the org base URL, so a body can link a record as
 *                                     %%BASEURL%%/%%RECORDID%%. Flow can only reach this through
 *                                     version-pinned $Api tokens that break on API upgrades.
 *
 * %%RECORDID%% and %%BASEURL%% are deliberately body-only: they exist to build a link, a subject cannot
 * carry one, and merging them into every subject would be work that never changes a single character.
 * A subject therefore runs one replace, not three. If a subject ever genuinely needs them, swap its
 * applyRecordName call for applyRecordTokens and update this table — do not leave the two out of step.
 *
 * FAILS CLOSED. A missing template, a blank subject or body, or an empty recipient list skips the send
 * rather than throwing. This runs inside a record-triggered flow's transaction, and a thrown exception
 * would roll back the user's record save — a notification problem must never cost someone their data.
 */
public with sharing class OfferingEmailSender {
    private static final String FIRST_NAME_TOKEN = '%%FIRSTNAME%%';
    private static final String BASE_URL_TOKEN = '%%BASEURL%%';
    private static final String RECORD_ID_TOKEN = '%%RECORDID%%';
    private static final String RECORD_NAME_TOKEN = '%%RECORDNAME%%';

    // Used when a recipient User has no FirstName, so a greeting never reads "Hi ,".
    private static final String FALLBACK_FIRST_NAME = 'there';

    public class Request {
        @InvocableVariable(
            label='Recipients'
            description='User records to email. Id is required; FirstName feeds the %%FIRSTNAME%% token.'
            required=true)
        public List<User> recipients;

        @InvocableVariable(
            label='Email Template Developer Name'
            description='DeveloperName of the EmailTemplate supplying Subject and HtmlValue. Never an Id, so this is portable across orgs. Leave blank to pass Subject and HTML Body directly instead.')
        public String templateDeveloperName;

        @InvocableVariable(
            label='Subject'
            description='Used only when Email Template Developer Name is blank.')
        public String subject;

        @InvocableVariable(
            label='HTML Body'
            description='Used only when Email Template Developer Name is blank.')
        public String htmlBody;

        @InvocableVariable(
            label='Record Id'
            description='Substituted for %%RECORDID%% in the HTML body, typically to build a link as %%BASEURL%%/%%RECORDID%%. Not merged into the subject.')
        public String recordId;

        @InvocableVariable(
            label='Record Name'
            description='Substituted for %%RECORDNAME%% in both the subject and the body.')
        public String recordName;
    }

    @InvocableMethod(
        label='Send Offering Notification Email'
        description='Sends a rendered HTML email to internal Users, optionally from a stored EmailTemplate looked up by DeveloperName. Use instead of the Send Email core action when the body is HTML and needs record values merged in.'
        category='Email')
    public static void send(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }

        Map<String, EmailTemplate> templatesByDeveloperName = loadTemplates(requests);
        String orgBaseUrl = URL.getOrgDomainUrl().toExternalForm();

        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();

        for (Request request : requests) {
            if (request == null || request.recipients == null || request.recipients.isEmpty()) {
                continue;
            }

            // Start from whatever the caller passed inline; a named template overrides both below.
            String subjectTemplate = request.subject;
            String bodyTemplate = request.htmlBody;

            if (String.isNotBlank(request.templateDeveloperName)) {
                EmailTemplate storedTemplate = templatesByDeveloperName.get(request.templateDeveloperName);
                if (storedTemplate == null) {
                    // Almost always means the loader script has not been run in this org yet.
                    System.debug(
                        LoggingLevel.ERROR,
                        'OfferingEmailSender: no EmailTemplate with DeveloperName ' +
                        request.templateDeveloperName + '. Run ' +
                        'scripts/apex/investor-relations/load-lightning-email-templates.apex in this org. ' +
                        'Skipping send.'
                    );
                    continue;
                }
                subjectTemplate = storedTemplate.Subject;
                bodyTemplate = storedTemplate.HtmlValue;
            }

            if (String.isBlank(subjectTemplate) || String.isBlank(bodyTemplate)) {
                continue;
            }

            // Record tokens resolve to the same text for every recipient, so they are merged once per
            // request. Only the recipient tokens are merged inside the loop below.
            // The subject only ever carries the record name, so it only pays for that one merge.
            String sharedSubject = applyRecordName(subjectTemplate, request.recordName);
            String sharedBody = applyRecordTokens(
                bodyTemplate, request.recordName, request.recordId, orgBaseUrl
            );

            for (User recipient : request.recipients) {
                if (recipient == null || recipient.Id == null) {
                    continue;
                }

                Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
                message.setTargetObjectId(recipient.Id);
                // Without this the platform tries to log the send as an activity against the target,
                // which fails for a User and is meaningless for an internal notification.
                message.setSaveAsActivity(false);
                message.setSubject(applyRecipientTokens(sharedSubject, recipient.FirstName));
                message.setHtmlBody(applyRecipientTokens(sharedBody, recipient.FirstName));
                messages.add(message);
            }
        }

        if (messages.isEmpty()) {
            return;
        }

        // allOrNothing = false: one bad address must not roll back the triggering record's save.
        Messaging.sendEmail(messages, false);
    }

    /**
     * Merges %%RECORDNAME%% only — the single token a subject line uses.
     *
     * Public because it defines part of the token contract that template authors write against, and
     * because it is a pure function worth asserting on directly. A null value merges as empty text
     * rather than the word "null" appearing in someone's inbox.
     */
    public static String applyRecordName(String text, String recordName) {
        if (String.isBlank(text)) {
            return text;
        }
        return text.replace(RECORD_NAME_TOKEN, recordName == null ? '' : recordName);
    }

    /**
     * Merges every record-level token — the full set a body uses. Delegates the name to applyRecordName
     * so that merge is defined in exactly one place.
     *
     * "Record-level" means the value is the same for every recipient of one request, which is why these
     * are merged once per request rather than once per person.
     */
    public static String applyRecordTokens(String text, String recordName, String recordId, String baseUrl) {
        if (String.isBlank(text)) {
            return text;
        }
        return applyRecordName(text, recordName)
            .replace(RECORD_ID_TOKEN, recordId == null ? '' : recordId)
            .replace(BASE_URL_TOKEN, baseUrl == null ? '' : baseUrl);
    }

    /**
     * Merges the tokens whose values differ from one recipient to the next. Kept separate from
     * applyRecordTokens so the shared work is not repeated once per person.
     */
    public static String applyRecipientTokens(String text, String firstName) {
        if (String.isBlank(text)) {
            return text;
        }
        String resolvedFirstName = String.isBlank(firstName) ? FALLBACK_FIRST_NAME : firstName;
        return text.replace(FIRST_NAME_TOKEN, resolvedFirstName);
    }

    /**
     * One query for every template named across the whole batch, rather than one per request.
     */
    private static Map<String, EmailTemplate> loadTemplates(List<Request> requests) {
        Set<String> developerNames = new Set<String>();
        for (Request request : requests) {
            if (request != null && String.isNotBlank(request.templateDeveloperName)) {
                developerNames.add(request.templateDeveloperName);
            }
        }

        Map<String, EmailTemplate> templatesByDeveloperName = new Map<String, EmailTemplate>();
        if (developerNames.isEmpty()) {
            return templatesByDeveloperName;
        }

        for (EmailTemplate storedTemplate : [
            SELECT DeveloperName, Subject, HtmlValue
            FROM EmailTemplate
            WHERE DeveloperName IN :developerNames
        ]) {
            templatesByDeveloperName.put(storedTemplate.DeveloperName, storedTemplate);
        }
        return templatesByDeveloperName;
    }
}
