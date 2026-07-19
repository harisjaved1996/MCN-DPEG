/**
 * Self-chaining Queueable that sends ONE shared envelope per INVESTING
 * ENTITY per execution (required secondary signers first, primary last,
 * view-only contacts as carbon copies).
 *
 * dfsle.EnvelopeService.sendEnvelope performs callouts AND DML inside the
 * managed package, so batching several envelopes into one transaction risks
 * "uncommitted work pending". One entity per link keeps every transaction's
 * callout/DML ordering safe; a run of N entities is a chain of N links.
 *
 * Outcomes accumulate in chain state; the final link notifies the sending
 * user via the Signature_Request_Result custom notification.
 */
public with sharing class SignatureRequestSender implements Queueable, Database.AllowsCallouts {

    private final SignatureRequestModels.SendRequest req;
    private final List<Id> remainingEntityIds;
    private final List<SignatureRequestModels.SendOutcome> outcomes;
    private final String templateRole;
    private final Boolean templateRoleResolved;

    public SignatureRequestSender(SignatureRequestModels.SendRequest req, List<Id> entityIds) {
        this(req, entityIds, new List<SignatureRequestModels.SendOutcome>(), null, false);
    }

    @TestVisible
    private SignatureRequestSender(
            SignatureRequestModels.SendRequest req,
            List<Id> remainingEntityIds,
            List<SignatureRequestModels.SendOutcome> outcomes,
            String templateRole,
            Boolean templateRoleResolved) {
        this.req = req;
        this.remainingEntityIds = remainingEntityIds;
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

        if (!remainingEntityIds.isEmpty()) {
            Id entityId = remainingEntityIds.remove(0);
            SignatureRequestModels.SendOutcome outcome = sendToEntity(entityId, role);
            outcomes.add(outcome);
            if (req.masterDocumentId != null) {
                try {
                    // DML after the callout is fine (only callout-after-DML is blocked).
                    SignatureRequestTracking.createCopiesForOutcome(req.masterDocumentId, outcome);
                } catch (Exception trackingError) {
                    System.debug(LoggingLevel.WARN,
                        'SignatureRequestSender: copy tracking failed - ' + trackingError.getMessage());
                }
            }
        }

        if (remainingEntityIds.isEmpty()) {
            finish();
        } else if (!Test.isRunningTest()) {
            System.enqueueJob(new SignatureRequestSender(
                req, remainingEntityIds, outcomes, role, roleResolved));
        }
    }

    private SignatureRequestModels.SendOutcome sendToEntity(Id entityId, String role) {
        SignatureRequestModels.SendOutcome outcome = new SignatureRequestModels.SendOutcome();
        outcome.entityId = entityId;
        try {
            Map<Id, SignatureRequestService.EntityRecipientGroup> groups =
                SignatureRequestService.loadRecipientGroups(req);
            SignatureRequestService.EntityRecipientGroup grp = groups.get(entityId);
            if (grp == null) {
                throw new SignatureRequestService.SignatureRequestException(
                    'No selected investors remain for this investing entity.');
            }
            outcome.entityName = grp.entityName;
            outcome.recipients = grp.recipients;
            if (grp.primary == null) {
                throw new SignatureRequestService.SignatureRequestException(
                    'No primary investor selected for investing entity "' + grp.entityName + '".');
            }
            outcome.contactId = grp.primary.contactId;
            outcome.contactName = grp.primary.contactName;

            Map<Id, SignatureRequestService.ProspectContext> contexts =
                SignatureRequestService.loadEntityContexts(
                    req, new Map<Id, SignatureRequestService.EntityRecipientGroup>{ entityId => grp });
            SignatureRequestService.ProspectContext ctx = contexts.get(entityId);
            if (ctx == null) {
                throw new SignatureRequestService.SignatureRequestException(
                    'Investing entity no longer holds a position on this investment.');
            }

            dfsle.Envelope envelope = SignatureRequestService.buildEntityEnvelope(req, ctx, grp, role);
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
                String who = String.isBlank(outcome.entityName)
                    ? String.valueOf(outcome.entityId) : outcome.entityName;
                failures.add(who + ' - ' + outcome.errorMessage);
            }
        }

        String title = 'Signature requests: ' + sent + ' envelope(s) sent'
            + (failures.isEmpty() ? '' : ', ' + failures.size() + ' failed');
        String body = failures.isEmpty()
            ? 'All entity envelopes were sent via DocuSign. Track signing status on the investment record.'
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
