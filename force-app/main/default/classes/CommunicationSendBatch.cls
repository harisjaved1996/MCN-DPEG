/**
 * Performs the actual send for one Communication.
 *
 * Batch Apex is used rather than a Queueable chain because it solves every
 * governor constraint this job runs into at once:
 *
 *   - chunking is automatic, so 5k and 50k are the same code
 *   - one callout per execute, nowhere near the 120s cumulative callout budget
 *     (a 2000-recipient call measures ~7s, a 5000-recipient one ~18s)
 *   - at most one scope worth of recipient rows per transaction, comfortably
 *     under the 10,000 DML row ceiling
 *   - each 1.4MB API response is released before the next scope runs
 *
 * The wizard returns as soon as this is enqueued. Only the Communication header
 * is written synchronously, so the modal closes immediately no matter how large
 * the audience is.
 */
public with sharing class CommunicationSendBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    private final Id communicationId;
    private final String sendDefinitionId;
    private final Set<String> excludedIndividualIds;
    private final Boolean skipWithoutConsent;

    // Stateful counters, rolled onto the header in finish().
    private Integer totalProcessed = 0;
    private Integer sentCount = 0;
    private Integer failedCount = 0;
    private Integer blockedCount = 0;
    private Integer skippedNoEmail = 0;
    private String firstError;

    public CommunicationSendBatch(Id communicationId) {
        this.communicationId = communicationId;

        Communication__c c = [
            SELECT Id, Send_Definition_Id__c, Excluded_Individual_Ids__c, Skip_Without_Consent__c
            FROM Communication__c
            WHERE Id = :communicationId
            LIMIT 1];

        this.sendDefinitionId = c.Send_Definition_Id__c;
        this.excludedIndividualIds = parseExclusions(c.Excluded_Individual_Ids__c);
        this.skipWithoutConsent = c.Skip_Without_Consent__c == true;
    }

    // ----------------------------------------------------------------- start

    /**
     * Iterable rather than QueryLocator: Batch Apex refuses a QueryLocator over
     * a Data Cloud DMO ("Batch Apex QueryLocator doesn't support
     * ssot__Individual__dlm"), so the audience is materialised here instead.
     *
     * No DML either. Writing the status from start() leaves uncommitted work
     * pending against the first execute(), whose callout then fails with "a
     * callout was unsuccessful because of pending uncommitted work". The
     * controller stamps In Progress when it creates the record instead.
     */
    public Iterable<SObject> start(Database.BatchableContext ctx) {
        return AudienceService.audienceList();
    }

    // --------------------------------------------------------------- execute

    public void execute(Database.BatchableContext ctx, List<ssot__Individual__dlm> scope) {
        Map<String, String> nameById = new Map<String, String>();
        Set<String> candidateIds = new Set<String>();

        for (ssot__Individual__dlm i : scope) {
            if (excludedIndividualIds.contains(i.ssot__Id__c)) {
                continue;
            }
            candidateIds.add(i.ssot__Id__c);
            nameById.put(i.ssot__Id__c, i.ssot__PersonName__c);
        }
        if (candidateIds.isEmpty()) {
            return;
        }

        Map<String, String> emailById = AudienceService.emailsByIndividualId(candidateIds);

        // Consent lives on the address, so it is resolved per address, not per
        // individual. Marketing Cloud Next rejects anything that is not OPT_IN,
        // so when the sender asked to skip them we leave them out of the call
        // rather than generating a predictable failure row for each one.
        Map<String, String> consentByEmail = skipWithoutConsent
            ? AudienceService.consentByEmail(new Set<String>(emailById.values()))
            : new Map<String, String>();

        List<DirectEmailSendService.Recipient> recipients = new List<DirectEmailSendService.Recipient>();
        List<Communication_Recipient__c> rows = new List<Communication_Recipient__c>();

        for (String individualId : candidateIds) {
            String email = emailById.get(individualId);

            if (String.isBlank(email)) {
                // No contact point means no "to" address, and the API rejects
                // that outright. Record it rather than silently dropping them.
                totalProcessed++;
                skippedNoEmail++;
                rows.add(newRow(individualId, nameById.get(individualId), null,
                                'Failed', 'No email contact point in Data Cloud'));
                continue;
            }

            if (skipWithoutConsent
                    && AudienceService.resolveConsent(email, consentByEmail) != AudienceService.CONSENT_OPT_IN) {
                // Not counted as a recipient at all: they were never targeted.
                continue;
            }

            totalProcessed++;
            recipients.add(new DirectEmailSendService.Recipient(individualId, email));
        }

        if (!recipients.isEmpty()) {
            try {
                List<DirectEmailSendService.SendResult> results =
                    DirectEmailSendService.sendBulk(sendDefinitionId, recipients);

                for (DirectEmailSendService.SendResult r : results) {
                    Communication_Recipient__c row = newRow(
                        r.individualId, nameById.get(r.individualId), r.emailAddress, null, null);

                    row.Message_Id__c = r.messageId;
                    row.Delivery_Id__c = r.deliveryId;
                    row.Request_Id__c = r.requestId;

                    if (r.isSuccess) {
                        sentCount++;
                        row.Send_Status__c = 'Sent';
                        row.Engagement_Status__c = 'Awaiting Data';
                        row.Sent_At__c = System.now();
                    } else if (r.isConsentBlocked) {
                        blockedCount++;
                        row.Send_Status__c = 'Blocked - No Consent';
                        row.Engagement_Status__c = 'Not Sent';
                        row.Failure_Reason__c = truncate(r.reason, 255);
                    } else {
                        failedCount++;
                        row.Send_Status__c = 'Failed';
                        row.Engagement_Status__c = 'Not Sent';
                        row.Failure_Reason__c = truncate(r.reason, 255);
                    }
                    rows.add(row);
                }
            } catch (Exception e) {
                // A whole chunk failed. Record every recipient in it as failed
                // so the totals still reconcile against Total Recipients.
                failedCount += recipients.size();
                if (firstError == null) {
                    firstError = e.getMessage();
                }
                for (DirectEmailSendService.Recipient r : recipients) {
                    rows.add(newRow(r.individualId, nameById.get(r.individualId), r.emailAddress,
                                    'Failed', truncate('Chunk failed: ' + e.getMessage(), 255)));
                }
            }
        }

        if (!rows.isEmpty()) {
            insert rows;
        }
    }

    // ---------------------------------------------------------------- finish

    public void finish(Database.BatchableContext ctx) {
        Communication__c c = new Communication__c(Id = communicationId);
        c.Execution_End__c = System.now();
        c.Total_Recipients__c = totalProcessed;
        c.Sent_Count__c = sentCount;
        c.Failed_Count__c = failedCount;
        c.Blocked_No_Consent_Count__c = blockedCount;
        c.Skipped_No_Email_Count__c = skippedNoEmail;
        if (ctx != null) {
            c.Batch_Job_Id__c = ctx.getJobId();
        }

        if (sentCount == 0 && totalProcessed > 0) {
            c.Status__c = 'Failed';
        } else if (failedCount > 0 || blockedCount > 0 || skippedNoEmail > 0) {
            c.Status__c = 'Completed with Errors';
        } else {
            c.Status__c = 'Completed';
        }
        if (firstError != null) {
            c.Error_Message__c = firstError;
        }
        update c;
    }

    // --------------------------------------------------------------- helpers

    private Communication_Recipient__c newRow(
            String individualId, String name, String email, String sendStatus, String reason) {

        Communication_Recipient__c row = new Communication_Recipient__c(
            Communication__c = communicationId,
            Individual_Id__c = individualId,
            Individual_Name__c = truncate(name, 255),
            Email_Address__c = email
        );
        if (sendStatus != null) {
            row.Send_Status__c = sendStatus;
            row.Engagement_Status__c = 'Not Sent';
        }
        if (reason != null) {
            row.Failure_Reason__c = truncate(reason, 255);
        }
        return row;
    }

    @TestVisible
    private static Set<String> parseExclusions(String serialised) {
        Set<String> ids = new Set<String>();
        if (String.isBlank(serialised)) {
            return ids;
        }
        try {
            for (Object o : (List<Object>) JSON.deserializeUntyped(serialised)) {
                if (o != null) {
                    ids.add(String.valueOf(o));
                }
            }
        } catch (Exception e) {
            // A malformed exclusion list must not silently widen the audience.
            throw new SendException('Stored exclusion list could not be read: ' + e.getMessage());
        }
        return ids;
    }

    private static String truncate(String value, Integer max) {
        if (value == null) {
            return null;
        }
        return value.length() > max ? value.substring(0, max) : value;
    }

    public class SendException extends Exception {}
}
