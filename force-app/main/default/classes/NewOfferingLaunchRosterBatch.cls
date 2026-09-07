/**
 * Builds the recipient roster for one New Offering Launch send, then triggers
 * the IR_New_Launch broadcast flow once.
 *
 * The flow does the sending, not this batch. That is the whole reason this
 * path exists: only a broadcast flow can populate the {{$content.Name}}
 * content variable in the email with the Offering name. So the work here is
 *
 *   execute()  write one Communication_Recipient__c per selected individual
 *   finish()   fire the flow once, after those rows have committed, and stamp
 *              the outcome on the Communication
 *
 * The recipient rows ARE the selection. The flow looks up
 * Communication_Recipient__c for the Communication it was handed and sends
 * only when the individual has a row, so a deselected person is simply one
 * that was never written. No separate exclusion object is involved.
 *
 * Ordering matters: if the flow ran before those rows committed it would find
 * nobody and send nothing, so the callout lives in finish().
 *
 * Batch Apex rather than a Queueable chain: chunking is automatic, so 7
 * recipients and 70,000 are the same code, and each transaction stays well
 * inside the 10,000 DML row ceiling.
 */
public with sharing class NewOfferingLaunchRosterBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    private final Id communicationId;
    private final Set<String> listedIndividualIds;
    private final Boolean whitelistMode;
    private final IRCommunicationSettings.Config cfg;

    // Stateful, rolled onto the header in finish().
    private Integer selectedCount = 0;
    private Integer skippedNoEmail = 0;
    private String firstError;

    public NewOfferingLaunchRosterBatch(Id communicationId) {
        this.communicationId = communicationId;

        Communication__c c = [
            SELECT Id, Excluded_Individual_Ids__c, Selection_Mode__c, IR_Communication_Config__c
            FROM Communication__c
            WHERE Id = :communicationId
            LIMIT 1];

        this.listedIndividualIds = parseIds(c.Excluded_Individual_Ids__c);
        this.whitelistMode = (c.Selection_Mode__c == NewOfferingLaunchController.MODE_ONLY);
        this.cfg = IRCommunicationSettings.get(c.IR_Communication_Config__c);
    }

    // ----------------------------------------------------------------- start

    /**
     * Iterable rather than QueryLocator: Batch Apex refuses a QueryLocator over
     * a Data Cloud DMO ("Batch Apex QueryLocator doesn't support
     * ssot__Individual__dlm"), so the audience is materialised instead.
     *
     * No DML in start() either — it would leave uncommitted work pending
     * against the first execute() and break its callout. The controller stamps
     * In Progress when it creates the record.
     */
    public Iterable<SObject> start(Database.BatchableContext ctx) {
        return NewOfferingLaunchAudience.audienceList(cfg.audienceSourceObject);
    }

    // --------------------------------------------------------------- execute

    public void execute(Database.BatchableContext ctx, List<ssot__Individual__dlm> scope) {
        Set<String> selectedIds = new Set<String>();
        Map<String, String> nameById = new Map<String, String>();

        for (ssot__Individual__dlm i : scope) {
            String individualId = i.ssot__Id__c;
            if (String.isBlank(individualId)) {
                continue;
            }
            // In whitelist mode anyone NOT listed is dropped; otherwise the
            // listed ids are the ones the sender unticked. Both directions
            // stay small on the wire.
            Boolean excluded = whitelistMode
                ? !listedIndividualIds.contains(individualId)
                : listedIndividualIds.contains(individualId);
            if (excluded) {
                continue;
            }
            selectedIds.add(individualId);
            nameById.put(individualId, i.ssot__PersonName__c);
        }
        if (selectedIds.isEmpty()) {
            return;
        }

        Map<String, String> emailById =
            NewOfferingLaunchAudience.emailsByIndividualId(selectedIds, cfg.audienceSourceObject);

        List<Communication_Recipient__c> rows = new List<Communication_Recipient__c>();
        for (String individualId : selectedIds) {
            String email = emailById.get(individualId);
            if (String.isBlank(email)) {
                // No address in Data Cloud means the flow cannot deliver to
                // them either. The row is still written so the roster stays a
                // complete record of who was targeted and why nothing arrived.
                skippedNoEmail++;
            }
            selectedCount++;
            rows.add(new Communication_Recipient__c(
                Communication__c = communicationId,
                Individual_Id__c = individualId,
                // Data Cloud sources this audience from Contact, so the
                // individual key IS the Contact Id.
                Contact__c = individualId,
                Individual_Name__c = nameById.get(individualId),
                Email_Address__c = email,
                Send_Status__c = String.isBlank(email) ? 'Failed' : 'Pending',
                Failure_Reason__c = String.isBlank(email)
                    ? 'No email address for this individual in Data Cloud.' : null,
                Engagement_Status__c = String.isBlank(email) ? 'Not Sent' : 'Awaiting Data'));
        }
        insertQuietly(rows);
    }

    // ---------------------------------------------------------------- finish

    public void finish(Database.BatchableContext ctx) {
        Communication__c c = [
            SELECT Id, Name, Offering__r.Name
            FROM Communication__c
            WHERE Id = :communicationId
            LIMIT 1];

        String status;
        String error = firstError;

        if (selectedCount == 0) {
            status = 'Completed with Errors';
            error = 'No individuals were selected, so nothing was sent.';
        } else {
            try {
                invokeFlow(c.Offering__r.Name, communicationId);
                // Stays In Progress until the metrics sync has claimed
                // engagement: Completed is a statement about delivery, and at
                // this point the flow has only been asked to run.
                status = 'In Progress';
            } catch (Exception e) {
                status = 'Completed with Errors';
                // A timeout is ambiguous, the flow may still have run. The
                // metrics sync keeps trying to claim engagement, so a
                // slow-but-successful trigger heals itself on the next sync.
                error = 'Flow trigger failed (the send may still have run): ' + e.getMessage();
            }
        }

        update new Communication__c(
            Id = communicationId,
            Status__c = status,
            Total_Recipients__c = selectedCount,
            Skipped_No_Email_Count__c = skippedNoEmail,
            Execution_End__c = System.now(),
            Error_Message__c = (error == null) ? null : error.abbreviate(4000));
    }

    // ------------------------------------------------------------ flow call

    /**
     * Invokes IR_New_Launch through the REST actions endpoint.
     *
     * A BroadcastNoTrigger flow cannot be started with Flow.Interview, so a
     * REST call is the only way in. It is authenticated with a
     * client_credentials token for this org rather than the legacy OwnOrg
     * named credential, whose connected app was deleted and which now returns
     * 401 INVALID_SESSION_ID on every call.
     */
    private void invokeFlow(String offeringName, Id communicationRecordId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            URL.getOrgDomainUrl().toExternalForm()
            + '/services/data/' + cfg.flowApiVersion + '/actions/custom/flow/'
            + cfg.flowApiName);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + accessToken());
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);   // 120s, the Apex maximum; the 10s default is not enough
        req.setBody(JSON.serialize(new Map<String, Object>{
            'inputs' => new List<Object>{
                new Map<String, Object>{
                    'OfferingNameInput' => offeringName,
                    'CommunicationIdInput' => String.valueOf(communicationRecordId)
                }
            }
        }));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new RosterException(
                'HTTP ' + res.getStatusCode() + ': ' + res.getBody().abbreviate(500));
        }
    }

    /**
     * client_credentials token for this org.
     *
     * The credentials live in the existing Marketing_Send_Setting__mdt
     * "Default" record. That record is read directly here rather than through
     * any shared Apex, so this module still depends on no other class. It is
     * deliberately not duplicated into a second custom metadata type: two
     * copies of the same OAuth client secret would be a maintenance trap.
     */
    private static String accessToken() {
        Marketing_Send_Setting__mdt s = Marketing_Send_Setting__mdt.getInstance('Default');
        if (s == null) {
            throw new RosterException(
                'Marketing_Send_Setting__mdt "Default" is missing. Create it before sending.');
        }
        List<String> missing = new List<String>();
        if (String.isBlank(s.Token_Endpoint__c))  { missing.add('Token Endpoint'); }
        if (String.isBlank(s.Consumer_Key__c))    { missing.add('Consumer Key'); }
        if (String.isBlank(s.Consumer_Secret__c)) { missing.add('Consumer Secret'); }
        if (!missing.isEmpty()) {
            throw new RosterException(
                String.join(missing, ' and ') + ' is not set on the Marketing Send Setting '
                + '"Default" record, so the flow cannot be invoked.');
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint(s.Token_Endpoint__c);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setTimeout(120000);
        req.setBody(
            'grant_type=client_credentials'
            + '&client_id=' + EncodingUtil.urlEncode(s.Consumer_Key__c, 'UTF-8')
            + '&client_secret=' + EncodingUtil.urlEncode(s.Consumer_Secret__c, 'UTF-8'));

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new RosterException(
                'Could not obtain an access token (HTTP ' + res.getStatusCode() + ').');
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String token = (String) body.get('access_token');
        if (String.isBlank(token)) {
            throw new RosterException('The token response contained no access_token.');
        }
        return token;
    }

    // --------------------------------------------------------------- helpers

    /** Records the first failure without aborting the rest of the roster. */
    private void insertQuietly(List<SObject> records) {
        try {
            insert records;
        } catch (Exception e) {
            if (firstError == null) {
                firstError = e.getMessage();
            }
        }
    }

    private static Set<String> parseIds(String serialised) {
        if (String.isBlank(serialised)) {
            return new Set<String>();
        }
        return new Set<String>((List<String>) JSON.deserialize(serialised, List<String>.class));
    }

    public class RosterException extends Exception {}
}
