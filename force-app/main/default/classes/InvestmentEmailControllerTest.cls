@IsTest
private class InvestmentEmailControllerTest {

    @TestSetup
    static void setup() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;

        List<Contact> contacts = new List<Contact>{
            new Contact(LastName = 'Alpha', Email = 'alpha@example.com'),
            new Contact(LastName = 'Beta', Email = 'beta@example.com')
        };
        insert contacts;

        List<Investing_Entity__c> entities = new List<Investing_Entity__c>{
            new Investing_Entity__c(Name = 'Alpha LLC',
                Entity_Type__c = 'Partnership or LLC', Contact__c = contacts[0].Id),
            new Investing_Entity__c(Name = 'Beta Trust',
                Entity_Type__c = 'Estate or Trust', Contact__c = contacts[1].Id)
        };
        insert entities;

        insert new List<position__c>{
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[0].Id),
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[1].Id)
        };
    }

    private class BroadcastMock implements HttpCalloutMock {
        Integer statusCode;
        BroadcastMock(Integer statusCode) {
            this.statusCode = statusCode;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(statusCode == 200
                ? '[{"actionName":"Investment_Broadcast_Flow","isSuccess":true}]'
                : '[{"isSuccess":false,"errors":[{"message":"bad payload"}]}]');
            return res;
        }
    }

    private static Id investmentId() {
        return [SELECT Id FROM Investment__c LIMIT 1].Id;
    }

    @IsTest
    static void getInvestorsWalksTheChain() {
        InvestmentEmailController.InvestorData data =
            InvestmentEmailController.getInvestors(investmentId());
        Assert.areEqual('Fund IV', data.investmentName);
        Assert.areEqual(2, data.investors.size());
    }

    @IsTest
    static void sendEmailCreatesTrackingAndExclusions() {
        Id alphaId = [SELECT Id FROM Contact WHERE LastName = 'Alpha' LIMIT 1].Id;
        Id betaId = [SELECT Id FROM Contact WHERE LastName = 'Beta' LIMIT 1].Id;

        Test.setMock(HttpCalloutMock.class, new BroadcastMock(200));
        Test.startTest();
        String message = InvestmentEmailController.sendEmail(
            investmentId(), 'Fund IV', 'Distribution', new List<Id>{ betaId });
        Test.stopTest(); // runs the queueable callout

        Assert.isTrue(message.startsWith('SUCCESS'), message);

        Email_Send__c send = [
            SELECT Status__c, Email_Choice__c, Total_Recipients__c, Send_Run_Id__c
            FROM Email_Send__c
        ];
        Assert.areEqual(InvestmentEmailTracking.STATUS_BROADCAST_REQUESTED, send.Status__c,
            'queueable outcome must land on the tracking record');
        Assert.areEqual(1, send.Total_Recipients__c, 'deselected contact must be excluded');

        List<Email_Send_Recipient__c> recipients = [
            SELECT Contact__c, Status__c FROM Email_Send_Recipient__c
        ];
        Assert.areEqual(1, recipients.size());
        Assert.areEqual(alphaId, recipients[0].Contact__c);
        Assert.areEqual(InvestmentEmailTracking.RECIPIENT_PENDING, recipients[0].Status__c);

        List<Send_Exclusion__c> exclusions = [
            SELECT Contact__c, Send_Run_Id__c FROM Send_Exclusion__c
        ];
        Assert.areEqual(1, exclusions.size());
        Assert.areEqual(betaId, exclusions[0].Contact__c);
        Assert.areEqual(send.Send_Run_Id__c, exclusions[0].Send_Run_Id__c,
            'exclusions and the send record must share the run id');
    }

    @IsTest
    static void sendEmailCalloutFailureIsRecorded() {
        Test.setMock(HttpCalloutMock.class, new BroadcastMock(400));
        Test.startTest();
        InvestmentEmailController.sendEmail(
            investmentId(), 'Fund IV', 'CapitalCall', new List<Id>());
        Test.stopTest();

        Email_Send__c send = [SELECT Status__c, Error_Message__c FROM Email_Send__c];
        Assert.areEqual(InvestmentEmailTracking.STATUS_BROADCAST_FAILED, send.Status__c);
        Assert.isTrue(send.Error_Message__c.contains('400'), send.Error_Message__c);
    }

    @IsTest
    static void sendEmailFailsClosedOnBadData() {
        // A non-Contact id in the deselected list makes the exclusion DML throw;
        // nothing may be created or queued after that.
        Boolean threw = false;
        Test.startTest();
        try {
            InvestmentEmailController.sendEmail(
                investmentId(), 'Fund IV', 'Distribution',
                new List<Id>{ UserInfo.getUserId() });
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'bad exclusion data must surface as an error');
        Assert.areEqual(0, [SELECT COUNT() FROM Email_Send__c],
            'no tracking record may exist after a failed send');
        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'InvestmentEmailSender'],
            'no broadcast may be queued after a failed send');
    }

    @IsTest
    static void sendEmailRejectsBlankChoice() {
        Boolean threw = false;
        try {
            InvestmentEmailController.sendEmail(investmentId(), 'Fund IV', '', null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw);
    }

    @IsTest
    static void refreshEmailSendDelegatesToTracking() {
        InvestmentEmailController.Investor investor = new InvestmentEmailController.Investor();
        investor.id = [SELECT Id FROM Contact WHERE LastName = 'Alpha' LIMIT 1].Id;
        investor.name = 'Alpha';
        investor.email = 'alpha@example.com';
        Id sendId = InvestmentEmailTracking.createSendRecord(
            investmentId(), 'Fund IV', 'Distribution',
            UUID.randomUUID().toString(),
            new List<InvestmentEmailController.Investor>{ investor });

        InvestmentEmailTracking.gateway = new EmptyGateway();
        String message = InvestmentEmailController.refreshEmailSend(sendId);
        Assert.isTrue(message.contains('No engagement data'), message);
    }

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
}
