/**
 * Everything the "Send New Offering Launch" wizard calls.
 *
 * Fully standalone. This module shares no Apex with the Send Campaign Email
 * path; the only things it has in common with the rest of the org are the
 * Communication__c and Communication_Recipient__c objects.
 *
 * Nothing about the campaign is hardcoded here. The workspace, the email, the
 * flow, the Communication name prefix and the audience filter all come from an
 * IR_Communication__mdt record, so a second campaign is a new metadata record
 * plus a new flow rather than a code change.
 *
 * Why it sends through a broadcast flow rather than a per-recipient API: the
 * email carries a {{$content.Name}} content variable that has to receive the
 * Offering name, and only a flow can populate a content variable, via its
 * contentSchemaParameter transform. So this path writes the recipient rows
 * first and then asks the flow to fan out over its segment, sending only to
 * individuals that have a recipient row for this Communication.
 */
public with sharing class NewOfferingLaunchController {

    /** Everyone is targeted except the listed ids (the default). */
    public static final String MODE_ALL_EXCEPT = 'All Except Listed';

    /** Only the listed ids are targeted. Used after Deselect all. */
    public static final String MODE_ONLY = 'Only Listed';

    // ------------------------------------------------------------- step one

    /**
     * The email this campaign sends, with its real publish state.
     *
     * Step 1 is a confirmation rather than a picker: the flow hard-references
     * this content, so offering any other email would send a template the flow
     * is not wired to.
     */
    @AuraEnabled(cacheable=true)
    public static IRCommunicationSettings.Content getLaunchEmail(String configName) {
        try {
            return IRCommunicationSettings.resolveContent(
                IRCommunicationSettings.get(configName));
        } catch (Exception e) {
            throw asAura('Could not load the launch email', e);
        }
    }

    // ------------------------------------------------------------- step two

    /**
     * One page of the audience. Individuals come from Data Cloud filtered to
     * the campaign's Audience_Source_Object__c, which is the same filter the
     * broadcast flow's segment uses, so the list matches what the flow reaches.
     */
    @AuraEnabled(cacheable=true)
    public static NewOfferingLaunchAudience.AudiencePage getAudiencePage(
            String configName, String searchTerm, Integer pageNumber, Integer pageSize) {
        try {
            IRCommunicationSettings.Config c = IRCommunicationSettings.get(configName);
            return NewOfferingLaunchAudience.getPage(
                searchTerm, pageNumber, pageSize, c.audienceSourceObject);
        } catch (Exception e) {
            throw asAura('Could not load the audience', e);
        }
    }

    /** Total individuals in the audience, used to seed "all selected". */
    @AuraEnabled(cacheable=true)
    public static Integer getAudienceCount(String configName, String searchTerm) {
        try {
            IRCommunicationSettings.Config c = IRCommunicationSettings.get(configName);
            return NewOfferingLaunchAudience.countAudience(searchTerm, c.audienceSourceObject);
        } catch (Exception e) {
            throw asAura('Could not count the audience', e);
        }
    }

    // ----------------------------------------------------------------- send

    /**
     * Creates the Communication and starts the roster batch.
     *
     * Selection travels as a mode plus a list of exceptions, never as the full
     * set: "all except" carries who was unticked, "only listed" carries who was
     * ticked. Both stay small, so neither a 10,000-strong audience nor a
     * three-person pick has to post the other side of the set.
     *
     * @return the new Communication Id so the wizard can link straight to it.
     */
    @AuraEnabled
    public static Id startSend(
            Id offeringId, String configName, String selectionMode, List<String> individualIds) {

        if (offeringId == null) {
            throw new AuraHandledException('An Offering is required.');
        }

        String mode = String.isBlank(selectionMode) ? MODE_ALL_EXCEPT : selectionMode;
        if (mode != MODE_ALL_EXCEPT && mode != MODE_ONLY) {
            throw new AuraHandledException('Unrecognised selection mode: ' + selectionMode);
        }

        try {
            IRCommunicationSettings.Config cfg = IRCommunicationSettings.get(configName);
            IRCommunicationSettings.Content email = IRCommunicationSettings.resolveContent(cfg);

            // Checked here rather than left to the flow: an unpublished email
            // fails at send time with "We can't send unpublished content",
            // long after the sender has clicked Send and closed the modal.
            if (email.isPublished != true) {
                throw new AuraHandledException(
                    'The "' + email.name + '" email is not published, so it cannot be sent. '
                    + 'Publish it in the ' + cfg.workspaceName + ' workspace and try again.');
            }

            Offering__c offering = [SELECT Id, Name FROM Offering__c WHERE Id = :offeringId LIMIT 1];

            Integer listed = (individualIds == null) ? 0 : individualIds.size();
            Integer selected = (mode == MODE_ONLY)
                ? listed
                : NewOfferingLaunchAudience.countAudience(null, cfg.audienceSourceObject) - listed;
            if (selected <= 0) {
                throw new AuraHandledException('Select at least one recipient before sending.');
            }

            Communication__c c = new Communication__c(
                Name = communicationName(cfg.namePrefix, offering.Name),
                Offering__c = offeringId,
                Email_Name__c = email.name,
                Content_Key__c = email.contentKey,
                Managed_Content_Id__c = email.managedContentId,
                Workspace_Name__c = cfg.workspaceName,
                IR_Communication_Config__c = cfg.developerName,
                Send_Run_Id__c = UUID.randomUUID().toString(),
                Status__c = 'In Progress',
                Execution_Start__c = System.now(),
                Selection_Mode__c = mode,
                Excluded_Individual_Ids__c = (listed == 0) ? null : JSON.serialize(individualIds)
            );
            insert c;

            // Scope comes from the campaign record. Each execute writes one
            // batch of recipient rows, well under the 10,000 DML row ceiling.
            // The single flow callout happens once, in finish().
            Database.executeBatch(new NewOfferingLaunchRosterBatch(c.Id), cfg.batchScope);

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
            return NewOfferingLaunchTracking.syncCommunication(communicationId);
        } catch (Exception e) {
            throw asAura('Could not refresh metrics', e);
        }
    }

    // -------------------------------------------------------------- helpers

    /**
     * Joins the configured prefix to the Offering name.
     *
     * Custom metadata strips trailing whitespace, so a prefix stored as
     * "New Launch - " comes back as "New Launch -" and naive concatenation
     * produces "New Launch -Spring 2026". The separator is therefore added
     * here rather than trusted to survive the round trip.
     */
    @TestVisible
    private static String communicationName(String prefix, String offeringName) {
        String p = (prefix == null) ? '' : prefix.trim();
        return String.isBlank(p) ? offeringName : p + ' ' + offeringName;
    }

    /**
     * AuraHandledException hides its cause from the client unless the message
     * is set explicitly, which turns every server error into "Script-thrown
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
