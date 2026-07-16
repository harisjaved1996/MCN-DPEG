@IsTest
private class InvestmentEmailTrackingTest {

    private static final String RUN_A = 'aaaaaaaa-0000-0000-0000-000000000001#Send_Distribution_Email';
    private static final String RUN_B = 'bbbbbbbb-0000-0000-0000-000000000002#Send_Distribution_Email';
    private static final String RUN_OTHER_ELEMENT = 'cccccccc-0000-0000-0000-000000000003#Send_CapitalCall_Email';

    @TestSetup
    static void setup() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;
        insert new List<Contact>{
            new Contact(LastName = 'Alpha', Email = 'alpha@example.com'),
            new Contact(LastName = 'Beta', Email = 'beta@example.com'),
            new Contact(LastName = 'Gamma', Email = 'gamma@example.com')
        };
    }

    // ------------------------------------------------------------------
    // fake gateway
    // ------------------------------------------------------------------

    private class FakeGateway implements InvestmentEmailTracking.EngagementGateway {
        List<InvestmentEmailModels.EngagementRow> rows =
            new List<InvestmentEmailModels.EngagementRow>();
        String listEmailSubject = 'Distribution Notice for Your Investment';

        public List<InvestmentEmailModels.EngagementRow> fetchSendCandidates(
                Set<Id> contactIds, Datetime fromDt, Datetime toDt) {
            List<InvestmentEmailModels.EngagementRow> result =
                new List<InvestmentEmailModels.EngagementRow>();
            for (InvestmentEmailModels.EngagementRow row : rows) {
                if (row.action == InvestmentEmailModels.ACTION_SEND_STATUS
                        && contactIds.contains(row.contactId)
                        && row.engagedAt >= fromDt && row.engagedAt <= toDt) {
                    result.add(row);
                }
            }
            return result;
        }

        public List<InvestmentEmailModels.EngagementRow> fetchRunsEngagement(Set<String> flowRunIds) {
            List<InvestmentEmailModels.EngagementRow> result =
                new List<InvestmentEmailModels.EngagementRow>();
            for (InvestmentEmailModels.EngagementRow row : rows) {
                if (flowRunIds.contains(row.flowRunId)) {
                    result.add(row);
                }
            }
            return result;
        }

        public String fetchListEmailSubject(String listEmailId) {
            return listEmailSubject;
        }
    }

    private static InvestmentEmailModels.EngagementRow row(String flowRunId, Id contactId,
            String action, Datetime engagedAt) {
        InvestmentEmailModels.EngagementRow r = new InvestmentEmailModels.EngagementRow();
        r.flowRunId = flowRunId;
        r.contactId = contactId;
        r.action = action;
        r.engagedAt = engagedAt;
        r.bulkEmailMessageId = '0XB000000000001AAA';
        if (action == InvestmentEmailModels.ACTION_SEND_STATUS) {
            r.sendStatus = 'SENT';
        }
        return r;
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    private static Id investmentId() {
        return [SELECT Id FROM Investment__c LIMIT 1].Id;
    }

    private static Map<String, Contact> contactsByName() {
        Map<String, Contact> byName = new Map<String, Contact>();
        for (Contact c : [SELECT Id, LastName, Email FROM Contact]) {
            byName.put(c.LastName, c);
        }
        return byName;
    }

    private static List<InvestmentEmailController.Investor> investors(List<Contact> contacts) {
        List<InvestmentEmailController.Investor> result =
            new List<InvestmentEmailController.Investor>();
        for (Contact c : contacts) {
            InvestmentEmailController.Investor investor = new InvestmentEmailController.Investor();
            investor.id = c.Id;
            investor.name = c.LastName;
            investor.email = c.Email;
            result.add(investor);
        }
        return result;
    }

    private static Id createSend(List<Contact> recipients) {
        return InvestmentEmailTracking.createSendRecord(
            investmentId(), 'Fund IV', 'Distribution',
            UUID.randomUUID().toString(), investors(recipients));
    }

    // ------------------------------------------------------------------
    // creation
    // ------------------------------------------------------------------

    @IsTest
    static void createSendRecordCreatesMasterAndRecipients() {
        Map<String, Contact> byName = contactsByName();

        Test.startTest();
        Id sendId = createSend(new List<Contact>{ byName.get('Alpha'), byName.get('Beta') });
        Test.stopTest();

        Email_Send__c send = [
            SELECT Status__c, Email_Choice__c, Total_Recipients__c, Sent_Count__c,
                   Sent_At__c, Send_Run_Id__c, Investment__c
            FROM Email_Send__c WHERE Id = :sendId
        ];
        Assert.areEqual(InvestmentEmailTracking.STATUS_QUEUED, send.Status__c);
        Assert.areEqual('Distribution', send.Email_Choice__c);
        Assert.areEqual(2, send.Total_Recipients__c);
        Assert.areEqual(0, send.Sent_Count__c);
        Assert.isNotNull(send.Sent_At__c);
        Assert.isNotNull(send.Send_Run_Id__c);
        Assert.areEqual(investmentId(), send.Investment__c);

        List<Email_Send_Recipient__c> recipients = [
            SELECT Status__c, Contact__c, Email__c FROM Email_Send_Recipient__c
            WHERE Email_Send__c = :sendId
        ];
        Assert.areEqual(2, recipients.size());
        for (Email_Send_Recipient__c recipient : recipients) {
            Assert.areEqual(InvestmentEmailTracking.RECIPIENT_PENDING, recipient.Status__c);
            Assert.isNotNull(recipient.Contact__c);
            Assert.isNotNull(recipient.Email__c);
        }
    }

    @IsTest
    static void markBroadcastOutcomeSetsStatus() {
        Map<String, Contact> byName = contactsByName();
        Id sendId = createSend(new List<Contact>{ byName.get('Alpha') });

        InvestmentEmailTracking.markBroadcastOutcome(sendId, true, null);
        Assert.areEqual(InvestmentEmailTracking.STATUS_BROADCAST_REQUESTED,
            [SELECT Status__c FROM Email_Send__c WHERE Id = :sendId].Status__c);

        InvestmentEmailTracking.markBroadcastOutcome(sendId, false, 'HTTP 400: bad payload');
        Email_Send__c send = [
            SELECT Status__c, Error_Message__c FROM Email_Send__c WHERE Id = :sendId
        ];
        Assert.areEqual(InvestmentEmailTracking.STATUS_BROADCAST_FAILED, send.Status__c);
        Assert.isTrue(send.Error_Message__c.contains('bad payload'));

        // Null id (flow path) is a no-op, not an error.
        InvestmentEmailTracking.markBroadcastOutcome(null, true, null);
    }

    // ------------------------------------------------------------------
    // claiming + engagement application
    // ------------------------------------------------------------------

    @IsTest
    static void claimAndApplyEngagement() {
        Map<String, Contact> byName = contactsByName();
        Contact alpha = byName.get('Alpha');
        Contact beta = byName.get('Beta');
        Id sendId = createSend(new List<Contact>{ alpha, beta });

        FakeGateway fake = new FakeGateway();
        Datetime base = Datetime.now().addMinutes(2);
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_SEND_STATUS, base));
        fake.rows.add(row(RUN_A, beta.Id, InvestmentEmailModels.ACTION_SEND_STATUS, base));
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_OPEN, base.addMinutes(3)));
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_OPEN, base.addMinutes(9)));
        InvestmentEmailModels.EngagementRow click =
            row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_CLICK, base.addMinutes(5));
        click.linkUrl = 'https://example.com/doc';
        fake.rows.add(click);
        // Telemetry rows and rows for the wrong element must be ignored.
        fake.rows.add(row(RUN_A, alpha.Id, 'MESSAGE_PROCESSING_TIME', base.addMinutes(1)));
        fake.rows.add(row(RUN_OTHER_ELEMENT, alpha.Id,
            InvestmentEmailModels.ACTION_SEND_STATUS, base));
        InvestmentEmailTracking.gateway = fake;

        Test.startTest();
        Boolean hasMore = InvestmentEmailTracking.syncOpenSends();
        Test.stopTest();

        Assert.isFalse(hasMore);
        Email_Send__c send = [
            SELECT Status__c, Flow_Run_Id__c, List_Email_Id__c, Subject__c,
                   Total_Recipients__c, Sent_Count__c, Opened_Count__c,
                   Clicked_Count__c, Bounced_Count__c, Last_Synced_At__c
            FROM Email_Send__c WHERE Id = :sendId
        ];
        Assert.areEqual(RUN_A, send.Flow_Run_Id__c);
        Assert.areEqual(InvestmentEmailTracking.STATUS_SYNCING, send.Status__c);
        Assert.areEqual('0XB000000000001AAA', send.List_Email_Id__c);
        Assert.areEqual('Distribution Notice for Your Investment', send.Subject__c);
        Assert.isNotNull(send.Last_Synced_At__c);
        Assert.areEqual(2, send.Total_Recipients__c);
        Assert.areEqual(2, send.Sent_Count__c);
        Assert.areEqual(1, send.Opened_Count__c);
        Assert.areEqual(1, send.Clicked_Count__c);
        Assert.areEqual(0, send.Bounced_Count__c);

        Email_Send_Recipient__c alphaRow = [
            SELECT Status__c, Sent_At__c, Opened_At__c, Clicked_At__c,
                   Open_Count__c, Click_Count__c, Last_Click_URL__c
            FROM Email_Send_Recipient__c
            WHERE Email_Send__c = :sendId AND Contact__c = :alpha.Id
        ];
        Assert.areEqual(InvestmentEmailTracking.RECIPIENT_CLICKED, alphaRow.Status__c);
        Assert.isNotNull(alphaRow.Sent_At__c);
        Assert.isNotNull(alphaRow.Opened_At__c);
        Assert.isNotNull(alphaRow.Clicked_At__c);
        Assert.areEqual(2, alphaRow.Open_Count__c);
        Assert.areEqual(1, alphaRow.Click_Count__c);
        Assert.areEqual('https://example.com/doc', alphaRow.Last_Click_URL__c);

        Email_Send_Recipient__c betaRow = [
            SELECT Status__c, Opened_At__c FROM Email_Send_Recipient__c
            WHERE Email_Send__c = :sendId AND Contact__c = :beta.Id
        ];
        Assert.areEqual(InvestmentEmailTracking.RECIPIENT_SENT, betaRow.Status__c);
        Assert.isNull(betaRow.Opened_At__c);
    }

    @IsTest
    static void clickWithoutOpenStillCountsAsOpened() {
        Map<String, Contact> byName = contactsByName();
        Contact alpha = byName.get('Alpha');
        Id sendId = createSend(new List<Contact>{ alpha });

        FakeGateway fake = new FakeGateway();
        Datetime base = Datetime.now().addMinutes(2);
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_SEND_STATUS, base));
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_CLICK, base.addMinutes(4)));
        InvestmentEmailTracking.gateway = fake;

        InvestmentEmailTracking.syncOpenSends();

        Email_Send_Recipient__c recipient = [
            SELECT Status__c, Opened_At__c, Open_Count__c FROM Email_Send_Recipient__c
            WHERE Email_Send__c = :sendId
        ];
        Assert.areEqual(InvestmentEmailTracking.RECIPIENT_CLICKED, recipient.Status__c);
        Assert.isNotNull(recipient.Opened_At__c, 'a click proves an open');
        Assert.areEqual(0, recipient.Open_Count__c, 'no tracked pixel open occurred');

        Assert.areEqual(1,
            [SELECT Opened_Count__c FROM Email_Send__c WHERE Id = :sendId].Opened_Count__c);
    }

    @IsTest
    static void bounceOverridesEverything() {
        Map<String, Contact> byName = contactsByName();
        Contact alpha = byName.get('Alpha');
        Id sendId = createSend(new List<Contact>{ alpha });

        FakeGateway fake = new FakeGateway();
        Datetime base = Datetime.now().addMinutes(2);
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_SEND_STATUS, base));
        InvestmentEmailModels.EngagementRow bounce =
            row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_SEND_STATUS, base.addMinutes(1));
        bounce.sendStatus = null;
        bounce.bounceType = 'HardBounce';
        bounce.bounceReason = 'Mailbox does not exist';
        fake.rows.add(bounce);
        InvestmentEmailTracking.gateway = fake;

        InvestmentEmailTracking.syncOpenSends();

        Email_Send_Recipient__c recipient = [
            SELECT Status__c, Bounced_At__c, Bounce_Type__c, Bounce_Reason__c
            FROM Email_Send_Recipient__c WHERE Email_Send__c = :sendId
        ];
        Assert.areEqual(InvestmentEmailTracking.RECIPIENT_BOUNCED, recipient.Status__c);
        Assert.isNotNull(recipient.Bounced_At__c);
        Assert.areEqual('HardBounce', recipient.Bounce_Type__c);
        Assert.areEqual('Mailbox does not exist', recipient.Bounce_Reason__c);

        Email_Send__c send = [
            SELECT Sent_Count__c, Bounced_Count__c FROM Email_Send__c WHERE Id = :sendId
        ];
        Assert.areEqual(0, send.Sent_Count__c, 'bounced recipients do not count as sent');
        Assert.areEqual(1, send.Bounced_Count__c);
    }

    @IsTest
    static void claimSkipsRunTakenByAnotherSendsRecipient() {
        Map<String, Contact> byName = contactsByName();
        Contact alpha = byName.get('Alpha');
        Id olderId = createSend(new List<Contact>{ alpha });
        Id newerId = createSend(new List<Contact>{ alpha });

        // The older send's recipient already claimed RUN_A for this contact.
        update new Email_Send__c(Id = olderId, Flow_Run_Id__c = RUN_A,
            Status__c = InvestmentEmailTracking.STATUS_SYNCING);
        Email_Send_Recipient__c olderRecipient = [
            SELECT Id FROM Email_Send_Recipient__c WHERE Email_Send__c = :olderId
        ];
        update new Email_Send_Recipient__c(Id = olderRecipient.Id, Flow_Run_Id__c = RUN_A);

        FakeGateway fake = new FakeGateway();
        Datetime base = Datetime.now().addMinutes(2);
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_SEND_STATUS, base));
        fake.rows.add(row(RUN_B, alpha.Id, InvestmentEmailModels.ACTION_SEND_STATUS,
            base.addMinutes(2)));
        InvestmentEmailTracking.gateway = fake;

        InvestmentEmailTracking.syncOpenSends();

        Assert.areEqual(RUN_B,
            [SELECT Flow_Run_Id__c FROM Email_Send_Recipient__c
             WHERE Email_Send__c = :newerId].Flow_Run_Id__c,
            'the taken (run, contact) pair must be skipped');
    }

    @IsTest
    static void backToBackSendsPairChronologically() {
        Map<String, Contact> byName = contactsByName();
        Contact alpha = byName.get('Alpha');
        Contact beta = byName.get('Beta');

        Id firstId = createSend(new List<Contact>{ alpha, beta });
        Id secondId = createSend(new List<Contact>{ alpha, beta });
        // Make the ordering unambiguous.
        update new Email_Send__c(Id = firstId, Sent_At__c = Datetime.now().addMinutes(-10));
        update new Email_Send__c(Id = secondId, Sent_At__c = Datetime.now().addMinutes(-5));

        FakeGateway fake = new FakeGateway();
        for (Contact c : new List<Contact>{ alpha, beta }) {
            fake.rows.add(row(RUN_A, c.Id, InvestmentEmailModels.ACTION_SEND_STATUS,
                Datetime.now().addMinutes(-9)));
            fake.rows.add(row(RUN_B, c.Id, InvestmentEmailModels.ACTION_SEND_STATUS,
                Datetime.now().addMinutes(-4)));
        }
        InvestmentEmailTracking.gateway = fake;

        InvestmentEmailTracking.syncOpenSends();

        for (Email_Send_Recipient__c recipient : [
            SELECT Email_Send__c, Flow_Run_Id__c FROM Email_Send_Recipient__c
        ]) {
            Assert.areEqual(recipient.Email_Send__c == firstId ? RUN_A : RUN_B,
                recipient.Flow_Run_Id__c,
                'oldest send must claim the earliest run per contact');
        }
    }

    @IsTest
    static void oneBroadcastWithDistinctGuidPerRecipientClaimsAll() {
        // Verified MCN behaviour: ONE Execute click stamps a DIFFERENT flow-run
        // GUID per recipient. Every recipient must claim its own GUID.
        Map<String, Contact> byName = contactsByName();
        Contact alpha = byName.get('Alpha');
        Contact beta = byName.get('Beta');
        Id sendId = createSend(new List<Contact>{ alpha, beta });

        FakeGateway fake = new FakeGateway();
        Datetime base = Datetime.now().addMinutes(1);
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_SEND_STATUS, base));
        fake.rows.add(row(RUN_B, beta.Id, InvestmentEmailModels.ACTION_SEND_STATUS, base));
        fake.rows.add(row(RUN_B, beta.Id, InvestmentEmailModels.ACTION_OPEN,
            base.addMinutes(3)));
        InvestmentEmailTracking.gateway = fake;

        InvestmentEmailTracking.syncOpenSends();

        Assert.areEqual(RUN_A, [
            SELECT Flow_Run_Id__c FROM Email_Send_Recipient__c
            WHERE Email_Send__c = :sendId AND Contact__c = :alpha.Id
        ].Flow_Run_Id__c);
        Assert.areEqual(RUN_B, [
            SELECT Flow_Run_Id__c FROM Email_Send_Recipient__c
            WHERE Email_Send__c = :sendId AND Contact__c = :beta.Id
        ].Flow_Run_Id__c);

        Email_Send__c send = [
            SELECT Sent_Count__c, Opened_Count__c, Status__c FROM Email_Send__c
            WHERE Id = :sendId
        ];
        Assert.areEqual(2, send.Sent_Count__c, 'both per-recipient runs must be counted');
        Assert.areEqual(1, send.Opened_Count__c);
        Assert.areEqual(InvestmentEmailTracking.STATUS_SYNCING, send.Status__c);
    }

    @IsTest
    static void unclaimableSendTimesOutToNoData() {
        Map<String, Contact> byName = contactsByName();
        Id freshId = createSend(new List<Contact>{ byName.get('Alpha') });
        Id staleId = createSend(new List<Contact>{ byName.get('Beta') });
        update new Email_Send__c(Id = staleId, Sent_At__c = Datetime.now().addHours(-25));

        InvestmentEmailTracking.gateway = new FakeGateway(); // no engagement at all

        InvestmentEmailTracking.syncOpenSends();

        Assert.areEqual(InvestmentEmailTracking.STATUS_QUEUED,
            [SELECT Status__c FROM Email_Send__c WHERE Id = :freshId].Status__c,
            'a fresh unclaimed send keeps waiting');
        Assert.areEqual(InvestmentEmailTracking.STATUS_NO_DATA,
            [SELECT Status__c FROM Email_Send__c WHERE Id = :staleId].Status__c,
            'an unclaimed send past the timeout gives up');
    }

    @IsTest
    static void secondSyncIsIdempotent() {
        Map<String, Contact> byName = contactsByName();
        Contact alpha = byName.get('Alpha');
        Id sendId = createSend(new List<Contact>{ alpha });

        FakeGateway fake = new FakeGateway();
        Datetime base = Datetime.now().addMinutes(2);
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_SEND_STATUS, base));
        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_OPEN, base.addMinutes(3)));
        InvestmentEmailTracking.gateway = fake;

        InvestmentEmailTracking.syncOpenSends();
        Email_Send_Recipient__c before = [
            SELECT Status__c, Sent_At__c, Opened_At__c, Open_Count__c
            FROM Email_Send_Recipient__c WHERE Email_Send__c = :sendId
        ];

        InvestmentEmailTracking.syncOpenSends();
        Email_Send_Recipient__c after = [
            SELECT Status__c, Sent_At__c, Opened_At__c, Open_Count__c
            FROM Email_Send_Recipient__c WHERE Email_Send__c = :sendId
        ];
        Assert.areEqual(before.Status__c, after.Status__c);
        Assert.areEqual(before.Sent_At__c, after.Sent_At__c);
        Assert.areEqual(before.Opened_At__c, after.Opened_At__c);
        Assert.areEqual(before.Open_Count__c, after.Open_Count__c);

        Email_Send__c send = [
            SELECT Sent_Count__c, Opened_Count__c FROM Email_Send__c WHERE Id = :sendId
        ];
        Assert.areEqual(1, send.Sent_Count__c);
        Assert.areEqual(1, send.Opened_Count__c);
    }

    @IsTest
    static void syncSendOnDemandReportsClaimState() {
        Map<String, Contact> byName = contactsByName();
        Contact alpha = byName.get('Alpha');
        Id sendId = createSend(new List<Contact>{ alpha });

        FakeGateway fake = new FakeGateway();
        InvestmentEmailTracking.gateway = fake;

        String waiting = InvestmentEmailTracking.syncSend(sendId);
        Assert.isTrue(waiting.contains('No engagement data'), waiting);

        fake.rows.add(row(RUN_A, alpha.Id, InvestmentEmailModels.ACTION_SEND_STATUS,
            Datetime.now().addMinutes(2)));
        String refreshed = InvestmentEmailTracking.syncSend(sendId);
        Assert.isTrue(refreshed.contains('refreshed'), refreshed);
        Assert.areEqual(RUN_A,
            [SELECT Flow_Run_Id__c FROM Email_Send__c WHERE Id = :sendId].Flow_Run_Id__c);
    }
}
