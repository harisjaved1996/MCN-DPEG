@IsTest
private class SignatureRequestSenderTest {

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
            new Investing_Entity__c(Name = 'Alpha LLC', Entity_Type__c = 'Partnership or LLC', Contact__c = contacts[0].Id),
            new Investing_Entity__c(Name = 'Beta Trust', Entity_Type__c = 'Estate or Trust', Contact__c = contacts[1].Id)
        };
        insert entities;

        insert new List<position__c>{
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[0].Id),
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[1].Id)
        };

        ContentVersion cv = new ContentVersion(
            Title = 'PPM', PathOnClient = 'PPM.pdf', VersionData = Blob.valueOf('%PDF-1.4 test'));
        insert cv;
    }

    private static SignatureRequestModels.SendRequest fileRequest(List<Id> contactIds) {
        Id invId = [SELECT Id FROM Investment__c LIMIT 1].Id;
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        return SignatureRequestService.parseAndValidate(JSON.serialize(new Map<String, Object>{
            'investmentId' => invId,
            'emailSubject' => 'Please sign',
            'document' => new Map<String, Object>{
                'sourceType' => 'FILE', 'contentVersionId' => cvId, 'name' => 'PPM.pdf' },
            'fields' => new List<Object>{
                new Map<String, Object>{
                    'clientId' => 'sig1', 'category' => 'RECIPIENT', 'recipientKind' => 'SIGNATURE',
                    'label' => 'Signature', 'page' => 1, 'x' => 100, 'y' => 200 } },
            'selectedContactIds' => contactIds
        }));
    }

    @IsTest
    static void chainSendsEveryContactAndFinishes() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        List<Id> contactIds = new List<Id>();
        for (Contact c : [SELECT Id FROM Contact ORDER BY LastName]) {
            contactIds.add(c.Id);
        }
        SignatureRequestModels.SendRequest req = fileRequest(contactIds);

        List<SignatureRequestModels.SendOutcome> outcomes = new List<SignatureRequestModels.SendOutcome>();
        SignatureRequestSender link1 = new SignatureRequestSender(req, contactIds, outcomes, null, false);
        link1.execute(null); // Test.isRunningTest() suppresses the real chain
        SignatureRequestSender link2 = new SignatureRequestSender(req, contactIds, outcomes, null, true);
        link2.execute(null); // drains the last contact and runs finish()

        Assert.areEqual(2, fake.sendCount, 'one envelope per contact');
        Assert.areEqual(2, outcomes.size());
        for (SignatureRequestModels.SendOutcome o : outcomes) {
            Assert.isTrue(o.success, 'outcome should succeed: ' + o.errorMessage);
            Assert.isTrue(String.isNotBlank(o.contactName));
        }
    }

    @IsTest
    static void nonInvestorContactIsCapturedAsFailure() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        Contact stranger = new Contact(LastName = 'Stranger', Email = 's@example.com');
        insert stranger;

        Id alphaId = [SELECT Id FROM Contact WHERE LastName = 'Alpha' LIMIT 1].Id;
        SignatureRequestModels.SendRequest req = fileRequest(new List<Id>{ alphaId });

        List<SignatureRequestModels.SendOutcome> outcomes = new List<SignatureRequestModels.SendOutcome>();
        SignatureRequestSender link = new SignatureRequestSender(
            req, new List<Id>{ stranger.Id }, outcomes, null, true);
        link.execute(null);

        Assert.areEqual(1, outcomes.size());
        Assert.isFalse(outcomes[0].success);
        Assert.isTrue(outcomes[0].errorMessage.contains('no longer an investor'), outcomes[0].errorMessage);
        Assert.areEqual(0, fake.sendCount, 'nothing sent for a non-investor');
    }

    @IsTest
    static void templateRoleLookupFailureFallsBackAndStillSends() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        fake.throwOnTemplate = true;
        SignatureRequestService.gateway = fake;

        Id invId = [SELECT Id FROM Investment__c LIMIT 1].Id;
        Id alphaId = [SELECT Id FROM Contact WHERE LastName = 'Alpha' LIMIT 1].Id;
        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            JSON.serialize(new Map<String, Object>{
                'investmentId' => invId,
                'document' => new Map<String, Object>{
                    'sourceType' => 'TEMPLATE',
                    'templateId' => '11111111-1111-1111-1111-111111111111',
                    'name' => 'Sub Docs' },
                'fields' => new List<Object>(),
                'selectedContactIds' => new List<Id>{ alphaId }
            }));

        List<SignatureRequestModels.SendOutcome> outcomes = new List<SignatureRequestModels.SendOutcome>();
        SignatureRequestSender link = new SignatureRequestSender(
            req, new List<Id>{ alphaId }, outcomes, null, false);
        link.execute(null);

        Assert.areEqual(1, outcomes.size());
        Assert.isTrue(outcomes[0].success,
            'send proceeds with the default role when template lookup fails: ' + outcomes[0].errorMessage);
        Assert.areEqual(1, fake.sendCount);
    }
}
