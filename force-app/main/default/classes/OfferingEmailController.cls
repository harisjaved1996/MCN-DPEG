/**
 * Everything the Offering send wizard calls.
 *
 * The send entry point is deliberately thin. It writes a single Communication
 * header, hands the work to a batch and returns, so the modal can close the
 * instant the user clicks Send regardless of whether the audience is 500 or
 * 50,000. No recipient rows are created here; the batch writes them per chunk.
 */
public with sharing class OfferingEmailController {

    // ------------------------------------------------------------- step one

    /**
     * One page of published emails from the configured Marketing CMS workspace,
     * newest first. Paged with a keyset cursor so the workspace can hold any
     * number of emails; pass the previous page's nextCursor to advance.
     */
    @AuraEnabled(cacheable=true)
    public static MarketingContentService.EmailPage getPublishedEmails(
            String searchTerm, String cursor, Integer pageSize) {
        try {
            return MarketingContentService.listPublishedEmails(searchTerm, cursor, pageSize);
        } catch (Exception e) {
            throw asAura('Could not load published emails', e);
        }
    }

    /**
     * Renders the chosen email so the sender sees it before committing.
     * Creates the send definition if this content has never been sent before,
     * which is also what makes a newly published email immediately usable.
     */
    @AuraEnabled
    public static Map<String, Object> previewEmail(String managedContentId, String emailName) {
        try {
            Id sendDefinitionId = MarketingContentService.ensureSendDefinition(managedContentId, emailName);
            String sampleIndividualId = anyIndividualId();
            if (sampleIndividualId == null) {
                throw new AuraHandledException('There are no individuals in Data Cloud to render a preview against.');
            }
            Map<String, Object> preview = MarketingContentService.preview(sendDefinitionId, sampleIndividualId);
            preview.put('sendDefinitionId', sendDefinitionId);
            return preview;
        } catch (Exception e) {
            throw asAura('Could not render a preview', e);
        }
    }

    // ------------------------------------------------------------- step two

    /** One page of the Data Cloud audience, with email and consent resolved. */
    @AuraEnabled(cacheable=true)
    public static AudienceService.AudiencePage getAudiencePage(
            String searchTerm, Integer pageNumber, Integer pageSize) {
        try {
            return AudienceService.getPage(searchTerm, pageNumber, pageSize);
        } catch (Exception e) {
            throw asAura('Could not load the audience', e);
        }
    }

    /** Counts for the pre-send banner: how many can actually be delivered to. */
    @AuraEnabled(cacheable=true)
    public static AudienceService.ConsentSummary getConsentSummary() {
        try {
            return AudienceService.summariseConsent();
        } catch (Exception e) {
            throw asAura('Could not summarise consent', e);
        }
    }

    // ----------------------------------------------------------------- send

    /**
     * Creates the Communication and starts the send.
     *
     * @param excludedIndividualIds individuals the sender unticked. Selection is
     *        tracked as exclusions rather than inclusions so the browser never
     *        has to hold or post tens of thousands of ids.
     * @return the new Communication Id, so the wizard can link straight to it.
     */
    @AuraEnabled
    public static Id startSend(
            Id offeringId,
            String managedContentId,
            String emailName,
            String searchTerm,
            List<String> excludedIndividualIds,
            Boolean skipWithoutConsent) {

        if (offeringId == null) {
            throw new AuraHandledException('An Offering is required.');
        }
        if (String.isBlank(managedContentId)) {
            throw new AuraHandledException('Choose an email before sending.');
        }

        try {
            Id sendDefinitionId = MarketingContentService.ensureSendDefinition(managedContentId, emailName);

            ManagedContent content = [
                SELECT Id, Name, ContentKey FROM ManagedContent WHERE Id = :managedContentId LIMIT 1];

            Communication__c c = new Communication__c(
                Offering__c = offeringId,
                Email_Name__c = content.Name,
                Content_Key__c = content.ContentKey,
                Managed_Content_Id__c = content.Id,
                Send_Definition_Id__c = sendDefinitionId,
                Workspace_Name__c = MarketingSendSettings.workspaceName(),
                Audience_Filter__c = searchTerm,
                // Stamped here rather than in the batch's start(): DML in
                // start() leaves uncommitted work pending against the first
                // execute() and its callout then fails.
                Status__c = 'In Progress',
                Execution_Start__c = System.now(),
                Skip_Without_Consent__c = (skipWithoutConsent == null ? true : skipWithoutConsent),
                Excluded_Individual_Ids__c =
                    (excludedIndividualIds == null || excludedIndividualIds.isEmpty())
                        ? null
                        : JSON.serialize(excludedIndividualIds)
            );
            insert c;

            // Scope matches the configured chunk size so one execute() is one
            // bulk callout. Batch Apex caps scope at 2000.
            Integer scope = Math.min(MarketingSendSettings.chunkSize(), 2000);
            Database.executeBatch(new CommunicationSendBatch(c.Id), scope);

            return c.Id;
        } catch (Exception e) {
            throw asAura('The send could not be started', e);
        }
    }

    // -------------------------------------------------------------- metrics

    /** On-demand engagement refresh from the Communication record page. */
    @AuraEnabled
    public static String refreshMetrics(Id communicationId) {
        try {
            return EngagementMetricsService.syncCommunication(communicationId);
        } catch (Exception e) {
            throw asAura('Could not refresh metrics', e);
        }
    }

    // -------------------------------------------------------------- helpers

    private static String anyIndividualId() {
        List<ssot__Individual__dlm> sample = [
            SELECT ssot__Id__c FROM ssot__Individual__dlm WHERE ssot__Id__c != null LIMIT 1];
        return sample.isEmpty() ? null : sample[0].ssot__Id__c;
    }

    /**
     * AuraHandledException hides its cause from the client unless the message is
     * set explicitly, which turns every server error into "Script-thrown
     * exception" in the browser. Setting it keeps the real reason visible.
     */
    private static AuraHandledException asAura(String context, Exception e) {
        if (e instanceof AuraHandledException) {
            return (AuraHandledException) e;
        }
        AuraHandledException ex = new AuraHandledException(context + ': ' + e.getMessage());
        ex.setMessage(context + ': ' + e.getMessage());
        return ex;
    }
}
