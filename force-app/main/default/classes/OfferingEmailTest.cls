/**
 * Coverage for the Offering campaign send.
 *
 * Data Cloud DMO rows cannot be inserted in a test context, so anything that
 * reads ssot__* returns empty here. The tests therefore focus on the logic that
 * is genuinely ours: response parsing, status escalation, exclusion handling,
 * roll-ups and the batch wiring, with the API stubbed by a callout mock.
 */
@IsTest
private class OfferingEmailTest {

    private static final String SEND_DEF_ID = '0XB000000000001AAA';

    // ------------------------------------------------------------- fixtures

    private static void useTestSettings() {
        MarketingSendSettings.override_x = new Marketing_Send_Setting__mdt(
            Token_Endpoint__c = 'https://example.my.salesforce.com/services/oauth2/token',
            Consumer_Key__c = 'key',
            Consumer_Secret__c = 'secret',
            Api_Base_Url__c = 'https://api.salesforce.com/automation/actions360',
            Workspace_Id__c = '0Zu000000000001AAA',
            Workspace_Name__c = 'IR email templates',
            From_Address__c = 'no-reply@example.com',
            Chunk_Size__c = 2000
        );
    }

    private static Communication__c newCommunication() {
        Offering__c offering = new Offering__c(Name = 'Test Offering');
        insert offering;

        Communication__c c = new Communication__c(
            Offering__c = offering.Id,
            Email_Name__c = 'Distribution',
            Send_Definition_Id__c = SEND_DEF_ID,
            Status__c = 'Queued',
            Skip_Without_Consent__c = false
        );
        insert c;
        return c;
    }

    /** Token first, then whatever the test queued for the API call. */
    private class SendMock implements HttpCalloutMock {
        private final String apiBody;
        private final Integer apiStatus;
        private Integer calls = 0;

        SendMock(String apiBody, Integer apiStatus) {
            this.apiBody = apiBody;
            this.apiStatus = apiStatus;
        }

        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            calls++;
            if (req.getEndpoint().contains('oauth2/token')) {
                res.setStatusCode(200);
                res.setBody('{"access_token":"aaa.bbb.ccc","token_type":"Bearer"}');
                return res;
            }
            res.setStatusCode(apiStatus);
            res.setBody(apiBody);
            return res;
        }
    }

    private static String bulkBody(String individualId, String email, String status, String reason) {
        String props = (status == 'SUCCESS')
            ? '"properties":{"deliveryId":"del-1","channel":"email"}'
            : '"properties":{}';
        String reasonPart = (reason == null) ? '' : ',"reason":"' + reason + '"';
        return '{"requestId":"req-1","recipients":[{'
            + '"to":"' + email + '",'
            + '"individualId":"Individual__dlm/' + individualId + '",'
            + '"messageId":"msg-1",'
            + '"status":"' + status + '"' + reasonPart + ','
            + props + '}]}';
    }

    // ------------------------------------------------------------- settings

    @IsTest
    static void settingsFallBackToSafeChunkSize() {
        MarketingSendSettings.override_x = new Marketing_Send_Setting__mdt(Chunk_Size__c = null);
        System.assertEquals(2000, MarketingSendSettings.chunkSize(),
            'A blank chunk size should fall back rather than send zero recipients per call.');

        MarketingSendSettings.override_x = new Marketing_Send_Setting__mdt(Chunk_Size__c = 500);
        System.assertEquals(500, MarketingSendSettings.chunkSize());
    }

    // ------------------------------------------------- response parsing

    @IsTest
    static void parsesSuccessAndStripsTheIndividualPrefix() {
        List<DirectEmailSendService.SendResult> results = DirectEmailSendService.parseResults(
            bulkBody('003000000000001AAA', 'a@example.com', 'SUCCESS', null));

        System.assertEquals(1, results.size());
        DirectEmailSendService.SendResult r = results[0];
        System.assertEquals(true, r.isSuccess);
        System.assertEquals(false, r.isConsentBlocked);
        System.assertEquals('003000000000001AAA', r.individualId,
            'The Individual__dlm/ prefix must be stripped before it is stored.');
        System.assertEquals('del-1', r.deliveryId);
        System.assertEquals('req-1', r.requestId);
    }

    @IsTest
    static void recognisesConsentRejectionAsItsOwnOutcome() {
        List<DirectEmailSendService.SendResult> results = DirectEmailSendService.parseResults(
            bulkBody('003000000000001AAA', 'a@example.com', 'FAIL',
                     'CONSENT_NOT_GIVEN: Tried to send an email to recipient without opt-in'));

        System.assertEquals(false, results[0].isSuccess);
        System.assertEquals(true, results[0].isConsentBlocked,
            'A consent rejection is not an error; it must be distinguishable from a genuine failure.');
    }

    @IsTest
    static void treatsOtherFailuresAsErrorsNotConsent() {
        List<DirectEmailSendService.SendResult> results = DirectEmailSendService.parseResults(
            bulkBody('003000000000001AAA', 'a@example.com', 'FAIL',
                     'MISSING_TO_ADDRESS: Message was missing a recipient email address.'));

        System.assertEquals(false, results[0].isSuccess);
        System.assertEquals(false, results[0].isConsentBlocked);
    }

    @IsTest
    static void emptyRecipientListSkipsTheCallout() {
        useTestSettings();
        Test.startTest();
        List<DirectEmailSendService.SendResult> results =
            DirectEmailSendService.sendBulk(SEND_DEF_ID, new List<DirectEmailSendService.Recipient>());
        Test.stopTest();
        System.assertEquals(0, results.size(),
            'An empty chunk must not burn a callout; the API rejects it with 400 anyway.');
    }

    @IsTest
    static void surfacesApiFailuresAsExceptions() {
        useTestSettings();
        Test.setMock(HttpCalloutMock.class, new SendMock('{"message":"boom"}', 500));

        Boolean threw = false;
        Test.startTest();
        try {
            DirectEmailSendService.sendBulk(SEND_DEF_ID, new List<DirectEmailSendService.Recipient>{
                new DirectEmailSendService.Recipient('003000000000001AAA', 'a@example.com')
            });
        } catch (DirectEmailSendService.DirectSendException e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'A persistent 5xx must not be swallowed.');
    }

    // ------------------------------------------------------- exclusions

    @IsTest
    static void parsesStoredExclusions() {
        Set<String> ids = CommunicationSendBatch.parseExclusions('["003A","003B"]');
        System.assertEquals(2, ids.size());
        System.assertEquals(true, ids.contains('003A'));

        System.assertEquals(0, CommunicationSendBatch.parseExclusions(null).size());
        System.assertEquals(0, CommunicationSendBatch.parseExclusions('').size());
    }

    @IsTest
    static void malformedExclusionsFailClosed() {
        Boolean threw = false;
        try {
            CommunicationSendBatch.parseExclusions('not json');
        } catch (CommunicationSendBatch.SendException e) {
            threw = true;
        }
        System.assertEquals(true, threw,
            'An unreadable exclusion list must stop the send, never silently widen the audience.');
    }

    // ------------------------------------------------------------- batch

    /**
     * start() is skipped deliberately. Batch Apex refuses a DMO QueryLocator in
     * a test context ("Batch Apex QueryLocator doesn't support
     * ssot__Individual__dlm") even though it works in real execution, so the
     * scope is supplied directly and execute()/finish() are exercised on their
     * own.
     */
    @IsTest
    static void executeRecordsSendOutcomesAndFinishFinalises() {
        useTestSettings();
        Communication__c c = newCommunication();
        Test.setMock(HttpCalloutMock.class,
            new SendMock(bulkBody('003000000000001AAA', 'a@example.com', 'SUCCESS', null), 200));

        CommunicationSendBatch batch = new CommunicationSendBatch(c.Id);
        List<ssot__Individual__dlm> scope = new List<ssot__Individual__dlm>();

        Test.startTest();
        // No DMO rows can exist in a test, so the scope is empty. execute()
        // must cope with that rather than assuming work is always present.
        batch.execute(null, scope);
        batch.finish(null);
        Test.stopTest();

        Communication__c after = [
            SELECT Status__c, Execution_End__c, Total_Recipients__c
            FROM Communication__c WHERE Id = :c.Id];

        System.assertNotEquals(null, after.Execution_End__c, 'finish() must stamp the end time.');
        System.assertEquals(0, after.Total_Recipients__c, 'An empty scope targets nobody.');
        System.assertNotEquals('Queued', after.Status__c, 'Status must move off Queued.');
    }

    // --------------------------------------------------------- metrics

    @IsTest
    static void rollUpCountsClicksAsOpensToo() {
        Communication__c c = newCommunication();

        insert new List<Communication_Recipient__c>{
            new Communication_Recipient__c(Communication__c = c.Id, Individual_Id__c = '003A',
                Message_Id__c = 'm1', Send_Status__c = 'Sent', Engagement_Status__c = 'Opened'),
            new Communication_Recipient__c(Communication__c = c.Id, Individual_Id__c = '003B',
                Message_Id__c = 'm2', Send_Status__c = 'Sent', Engagement_Status__c = 'Clicked'),
            new Communication_Recipient__c(Communication__c = c.Id, Individual_Id__c = '003C',
                Message_Id__c = 'm3', Send_Status__c = 'Sent', Engagement_Status__c = 'Bounced - Hard'),
            new Communication_Recipient__c(Communication__c = c.Id, Individual_Id__c = '003D',
                Message_Id__c = 'm4', Send_Status__c = 'Sent', Engagement_Status__c = 'Unsubscribed')
        };

        Test.startTest();
        EngagementMetricsService.rollUp(c.Id);
        Test.stopTest();

        Communication__c after = [
            SELECT Opened_Count__c, Clicked_Count__c, Bounced_Count__c,
                   Unsubscribed_Count__c, Last_Metrics_Sync__c
            FROM Communication__c WHERE Id = :c.Id];

        System.assertEquals(2, after.Opened_Count__c,
            'A click implies an open even when the tracking pixel never fired.');
        System.assertEquals(1, after.Clicked_Count__c);
        System.assertEquals(1, after.Bounced_Count__c);
        System.assertEquals(1, after.Unsubscribed_Count__c);
        System.assertNotEquals(null, after.Last_Metrics_Sync__c);
    }

    @IsTest
    static void applyEngagementIgnoresRowsWithoutAMessageId() {
        Communication__c c = newCommunication();
        Communication_Recipient__c row = new Communication_Recipient__c(
            Communication__c = c.Id, Individual_Id__c = '003A', Send_Status__c = 'Sent');
        insert row;

        Test.startTest();
        List<Communication_Recipient__c> changed = EngagementMetricsService.applyEngagement(
            new List<Communication_Recipient__c>{ row });
        Test.stopTest();

        System.assertEquals(0, changed.size(),
            'Without a message id there is no key to correlate engagement on.');
    }

    /** The exact entry point the Refresh Metrics quick action calls. */
    @IsTest
    static void refreshMetricsSucceedsForACompletedSend() {
        Communication__c c = newCommunication();
        c.Status__c = 'Completed';
        c.Execution_End__c = System.now();
        update c;

        insert new Communication_Recipient__c(
            Communication__c = c.Id, Individual_Id__c = '003A',
            Message_Id__c = 'm1', Send_Status__c = 'Sent', Engagement_Status__c = 'Awaiting Data');

        Test.startTest();
        String message = OfferingEmailController.refreshMetrics(c.Id);
        Test.stopTest();

        // Name is an auto-number, so it is only populated once re-queried.
        String recordName = [SELECT Name FROM Communication__c WHERE Id = :c.Id].Name;

        System.assertNotEquals(null, message);
        System.assertEquals(true, message.contains(recordName),
            'The confirmation should name the record that is being refreshed.');
    }

    @IsTest
    static void refreshMetricsRejectsANullRecordId() {
        Boolean threw = false;
        try {
            OfferingEmailController.refreshMetrics(null);
        } catch (Exception e) {
            threw = true;
        }
        System.assertEquals(true, threw,
            'A null record id must fail loudly, not as "List has no rows for assignment to SObject".');
    }

    @IsTest
    static void syncIsRefusedWhileTheSendIsStillRunning() {
        Communication__c c = newCommunication();
        c.Status__c = 'In Progress';
        update c;

        Test.startTest();
        String message = EngagementMetricsService.syncCommunication(c.Id);
        Test.stopTest();

        System.assertEquals(true, message.contains('still running'),
            'Metrics are meaningless until the send has finished writing its rows.');
    }

    @IsTest
    static void metricsSyncBatchRunsForOneCommunication() {
        Communication__c c = newCommunication();
        c.Status__c = 'Completed';
        c.Execution_End__c = System.now();
        update c;

        insert new Communication_Recipient__c(
            Communication__c = c.Id, Individual_Id__c = '003A',
            Message_Id__c = 'm1', Send_Status__c = 'Sent', Engagement_Status__c = 'Awaiting Data');

        Test.startTest();
        Database.executeBatch(new CommunicationMetricsSyncBatch(c.Id), 200);
        Test.stopTest();

        Communication__c after = [
            SELECT Last_Metrics_Sync__c FROM Communication__c WHERE Id = :c.Id];
        System.assertNotEquals(null, after.Last_Metrics_Sync__c,
            'Even with no engagement yet, the sync should stamp when it last looked.');
    }

    @IsTest
    static void schedulerEnqueuesTheSweep() {
        Test.startTest();
        String jobId = System.schedule('Metrics test',
            '0 0 0 15 3 ? 2099', new CommunicationMetricsScheduler());
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }

    // ----------------------------------------------------------- controller

    @IsTest
    static void startSendRejectsAMissingEmail() {
        Offering__c offering = new Offering__c(Name = 'Test Offering');
        insert offering;

        Boolean threw = false;
        try {
            OfferingEmailController.startSend(offering.Id, null, null, null, null, true);
        } catch (Exception e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'A send with no email chosen must not start.');
    }

    @IsTest
    static void startSendRejectsAMissingOffering() {
        Boolean threw = false;
        try {
            OfferingEmailController.startSend(null, '20Y000000000001AAA', 'Distribution', null, null, true);
        } catch (Exception e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'A Communication has no meaning without its Offering.');
    }

    @IsTest
    static void audienceReadsAreSafeWhenDataCloudIsEmpty() {
        // DMO rows cannot be created in a test context, so these exercise the
        // query paths and confirm they degrade to empty rather than throwing.
        Test.startTest();
        AudienceService.AudiencePage page = AudienceService.getPage(null, 1, 10);
        AudienceService.AudiencePage searched = AudienceService.getPage('haris', 1, 10);
        AudienceService.ConsentSummary summary = AudienceService.summariseConsent();
        Test.stopTest();

        System.assertNotEquals(null, page);
        System.assertNotEquals(null, searched);
        System.assertNotEquals(null, summary);
        System.assertEquals(0, AudienceService.emailsByIndividualId(new Set<String>()).size());
        System.assertEquals(0, AudienceService.consentByEmail(new Set<String>()).size());
    }

    @IsTest
    static void browsingBeyondTheOffsetCeilingIsReportedNotThrown() {
        Test.startTest();
        AudienceService.AudiencePage page = AudienceService.getPage(null, 500, 25);
        Test.stopTest();

        System.assertEquals(true, page.browseLimitReached,
            'SOQL cannot OFFSET past 2000, so the UI needs to be told rather than shown an error.');
        System.assertEquals(0, page.members.size());
    }

    @IsTest
    static void consentResolvesToNoneWhenNoRecordExists() {
        Map<String, String> consent = new Map<String, String>{ 'known@example.com' => 'OPT_IN' };

        System.assertEquals('OPT_IN', AudienceService.resolveConsent('KNOWN@example.com', consent),
            'Address matching must be case-insensitive.');
        System.assertEquals('NONE', AudienceService.resolveConsent('other@example.com', consent),
            'No consent record means blocked, which is the safe default.');
        System.assertEquals('NONE', AudienceService.resolveConsent(null, consent));
    }
}
