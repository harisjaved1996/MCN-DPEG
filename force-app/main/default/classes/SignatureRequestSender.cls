/**
 * Self-chaining Queueable that sends one DocuSign envelope per execution.
 *
 * dfsle.EnvelopeService.sendEnvelope performs callouts AND DML inside the
 * managed package, so batching several envelopes into one transaction risks
 * "uncommitted work pending". One contact per link keeps every transaction's
 * callout/DML ordering safe; a run of N contacts is a chain of N links.
 *
 * Outcomes accumulate in chain state; the final link notifies the sending
 * user via the Signature_Request_Result custom notification.
 */
public with sharing class SignatureRequestSender implements Queueable, Database.AllowsCallouts {

    private final SignatureRequestModels.SendRequest req;
    private final List<Id> remaining;
    private final List<SignatureRequestModels.SendOutcome> outcomes;
    private final String templateRole;
    private final Boolean templateRoleResolved;

    public SignatureRequestSender(SignatureRequestModels.SendRequest req, List<Id> contactIds) {
        this(req, contactIds, new List<SignatureRequestModels.SendOutcome>(), null, false);
    }

    @TestVisible
    private SignatureRequestSender(
            SignatureRequestModels.SendRequest req,
            List<Id> remaining,
            List<SignatureRequestModels.SendOutcome> outcomes,
            String templateRole,
            Boolean templateRoleResolved) {
        this.req = req;
        this.remaining = remaining;
        this.outcomes = outcomes;
        this.templateRole = templateRole;
        this.templateRoleResolved = templateRoleResolved;
    }

    public void execute(QueueableContext context) {
        String role = templateRole;
        Boolean roleResolved = templateRoleResolved;

        // Resolve the template's recipient role once, up front (callout).
        if (!roleResolved && req.document != null && req.document.sourceType == 'TEMPLATE') {
            try {
                role = SignatureRequestService.resolveTemplateRole(req.document.templateId);
            } catch (Exception e) {
                role = null; // envelope falls back to 'Signer 1'
                System.debug(LoggingLevel.WARN,
                    'SignatureRequestSender: template role lookup failed - ' + e.getMessage());
            }
            roleResolved = true;
        }

        if (!remaining.isEmpty()) {
            Id contactId = remaining.remove(0);
            SignatureRequestModels.SendOutcome outcome = sendToContact(contactId, role);
            outcomes.add(outcome);
            if (req.masterDocumentId != null) {
                try {
                    // DML after the callout is fine (only callout-after-DML is blocked).
                    SignatureRequestTracking.createCopyForOutcome(req.masterDocumentId, outcome);
                } catch (Exception trackingError) {
                    System.debug(LoggingLevel.WARN,
                        'SignatureRequestSender: copy tracking failed - ' + trackingError.getMessage());
                }
            }
        }

        if (remaining.isEmpty()) {
            finish();
        } else if (!Test.isRunningTest()) {
            System.enqueueJob(new SignatureRequestSender(req, remaining, outcomes, role, roleResolved));
        }
    }

    private SignatureRequestModels.SendOutcome sendToContact(Id contactId, String role) {
        SignatureRequestModels.SendOutcome outcome = new SignatureRequestModels.SendOutcome();
        outcome.contactId = contactId;
        try {
            Map<Id, SignatureRequestService.ProspectContext> contexts =
                SignatureRequestService.loadProspectContexts(req, new Set<Id>{ contactId });
            SignatureRequestService.ProspectContext ctx = contexts.get(contactId);
            if (ctx == null) {
                throw new SignatureRequestService.SignatureRequestException(
                    'Contact is no longer an investor on this investment.');
            }
            outcome.contactName = ctx.contactName;
            outcome.entityId = ctx.entityRecord == null ? null : (Id) ctx.entityRecord.get('Id');

            dfsle.Envelope envelope = SignatureRequestService.buildEnvelope(req, ctx, role);
            envelope = SignatureRequestService.gateway.sendNow(envelope);

            outcome.success = true;
            outcome.docuSignId = SignatureRequestService.readDocuSignId(envelope);
            outcome.envelopeRecordId = SignatureRequestService.readEnvelopeRecordId(envelope);
            if (String.isBlank(outcome.docuSignId)) {
                // Backstop: dfsle creates the status record in this same
                // transaction; the newest one for this investment is ours.
                List<dfsle__EnvelopeStatus__c> justCreated = [
                    SELECT dfsle__DocuSignId__c FROM dfsle__EnvelopeStatus__c
                    WHERE dfsle__SourceId__c = :String.valueOf(req.investmentId)
                    ORDER BY CreatedDate DESC, Id DESC
                    LIMIT 1
                ];
                if (!justCreated.isEmpty()) {
                    outcome.docuSignId = justCreated[0].dfsle__DocuSignId__c;
                }
            }
        } catch (Exception e) {
            outcome.success = false;
            outcome.errorMessage = e.getMessage();
        }
        return outcome;
    }

    private void finish() {
        Integer sent = 0;
        List<String> failures = new List<String>();
        for (SignatureRequestModels.SendOutcome outcome : outcomes) {
            if (outcome.success) {
                sent++;
            } else {
                String who = String.isBlank(outcome.contactName)
                    ? String.valueOf(outcome.contactId) : outcome.contactName;
                failures.add(who + ' - ' + outcome.errorMessage);
            }
        }

        String title = 'Signature requests: ' + sent + ' sent'
            + (failures.isEmpty() ? '' : ', ' + failures.size() + ' failed');
        String body = failures.isEmpty()
            ? 'All DocuSign envelopes were sent. Track signing status on the investment record.'
            : ('Failed: ' + String.join(failures, ' | ')).abbreviate(740);

        System.debug(LoggingLevel.INFO, 'SignatureRequestSender finished. ' + title + ' :: ' + body);

        try {
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'Signature_Request_Result'
                LIMIT 1
            ];
            if (!types.isEmpty()) {
                Messaging.CustomNotification notification = new Messaging.CustomNotification();
                notification.setNotificationTypeId(types[0].Id);
                notification.setTitle(title.abbreviate(250));
                notification.setBody(body);
                notification.setTargetId(req.investmentId);
                notification.send(new Set<String>{ UserInfo.getUserId() });
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'SignatureRequestSender: completion notification failed - ' + e.getMessage());
        }
    }
}
