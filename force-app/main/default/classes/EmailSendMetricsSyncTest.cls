@IsTest
private class EmailSendMetricsSyncTest {

    private class EmptyGateway implements InvestmentEmailTracking.EngagementGateway {
        public List<InvestmentEmailModels.EngagementRow> fetchSendCandidates(
                Set<Id> contactIds, Datetime fromDt, Datetime toDt) {
            return new List<InvestmentEmailModels.EngagementRow>();
        }
        public List<InvestmentEmailModels.EngagementRow> fetchRunsEngagement(Set<String> flowRunIds) {
            return new List<InvestmentEmailModels.EngagementRow>();
        }
        public String fetchListEmailSubject(String listEmailId) {
            return null;
        }
    }

    @IsTest
    static void schedulableEnqueuesTheQueueable() {
        Test.startTest();
        new EmailSendMetricsSync().execute((SchedulableContext) null);
        Test.stopTest();

        Assert.areEqual(1, [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'EmailSendMetricsSync'
        ], 'the schedulable must hand off to a queueable');
    }

    @IsTest
    static void queueableSyncsOpenSends() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;
        Contact alpha = new Contact(LastName = 'Alpha', Email = 'alpha@example.com');
        insert alpha;

        InvestmentEmailController.Investor investor = new InvestmentEmailController.Investor();
        investor.id = alpha.Id;
        investor.name = 'Alpha';
        investor.email = alpha.Email;
        Id sendId = InvestmentEmailTracking.createSendRecord(
            inv.Id, 'Fund IV', 'Distribution', UUID.randomUUID().toString(),
            new List<InvestmentEmailController.Investor>{ investor });
        // Stale enough that the empty gateway drives it to the terminal status.
        update new Email_Send__c(Id = sendId, Sent_At__c = Datetime.now().addHours(-25));

        InvestmentEmailTracking.gateway = new EmptyGateway();

        Test.startTest();
        System.enqueueJob(new EmailSendMetricsSync.SyncJob());
        Test.stopTest();

        Assert.areEqual(InvestmentEmailTracking.STATUS_NO_DATA,
            [SELECT Status__c FROM Email_Send__c WHERE Id = :sendId].Status__c,
            'the queueable must run the sync pass');
    }
}
