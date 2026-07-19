@IsTest
private class SignatureRequestSenderTest {

    @TestSetup
    static void setup() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;

        List<Contact> contacts = new List<Contact>{
            new Contact(LastName = 'Prime', Email = 'prime@example.com'),
            new Contact(LastName = 'Second', Email = 'second@example.com'),
            new Contact(LastName = 'Solo', Email = 'solo@example.com')
        };
        insert contacts;

        List<Investing_Entity__c> entities = new List<Investing_Entity__c>{
            new Investing_Entity__c(Name = 'Trust Entity', Entity_Type__c = 'Estate or Trust'),
            new Investing_Entity__c(Name = 'Solo LLC', Entity_Type__c = 'Partnership or LLC')
        };
        insert entities;

        insert new List<position__c>{
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[0].Id),
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[1].Id)
        };

        insert new List<Associated_Contact__c>{
            new Associated_Contact__c(Name = 'Prime', Investing_Entity__c = entities[0].Id,
                Contact__c = contacts[0].Id, Primary__c = true, Required_Signer__c = true),
            new Associated_Contact__c(Name = 'Second', Investing_Entity__c = entities[0].Id,
                Contact__c = contacts[1].Id, Primary__c = false, Required_Signer__c = true),
            new Associated_Contact__c(Name = 'Solo', Investing_Entity__c = entities[1].Id,
                Contact__c = contacts[2].Id, Primary__c = true, Required_Signer__c = true)
        };

        ContentVersion cv = new ContentVersion(
            Title = 'PPM', PathOnClient = 'PPM.pdf', VersionData = Blob.valueOf('%PDF-1.4 test'));
        insert cv;
    }

    private static List<Id> allAssociationIds() {
        List<Id> ids = new List<Id>();
        for (Associated_Contact__c a : [SELECT Id FROM Associated_Contact__c ORDER BY Name]) {
            ids.add(a.Id);
        }
        return ids;
    }

    private static List<Id> entityIds() {
        List<Id> ids = new List<Id>();
        for (Investing_Entity__c e : [SELECT Id FROM Investing_Entity__c ORDER BY Name]) {
            ids.add(e.Id);
        }
        return ids;
    }

    private static SignatureRequestModels.SendRequest fileRequest() {
        Id invId = [SELECT Id FROM Investment__c LIMIT 1].Id;
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        return SignatureRequestService.parseAndValidate(JSON.serialize(new Map<String, Object>{
            'investmentId' => invId,
            'emailSubject' => 'Please sign',
            'document' => new Map<String, Object>{
                'sourceType' => 'FILE', 'contentVersionId' => cvId, 'name' => 'PPM.pdf',
                'pageCount' => 2, 'lastPageWidth' => 612, 'lastPageHeight' => 792 },
            'fields' => new List<Object>{
                new Map<String, Object>{
                    'clientId' => 'txt1', 'category' => 'ENTRY', 'entryKind' => 'REQUIRED_TEXT',
                    'label' => 'Required Text', 'page' => 1, 'x' => 100, 'y' => 200 } },
            'selectedAssociationIds' => allAssociationIds()
        }));
    }

    @IsTest
    static void chainSendsOneEnvelopePerEntityAndFinishes() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        SignatureRequestModels.SendRequest req = fileRequest();
        List<Id> remaining = entityIds();

        List<SignatureRequestModels.SendOutcome> outcomes = new List<SignatureRequestModels.SendOutcome>();
        SignatureRequestSender link1 = new SignatureRequestSender(req, remaining, outcomes, null, false);
        link1.execute(null); // Test.isRunningTest() suppresses the real chain
        SignatureRequestSender link2 = new SignatureRequestSender(req, remaining, outcomes, null, true);
        link2.execute(null); // drains the last entity and runs finish()

        Assert.areEqual(2, fake.sendCount, 'one shared envelope per investing entity');
        Assert.areEqual(2, outcomes.size());
        for (SignatureRequestModels.SendOutcome o : outcomes) {
            Assert.isTrue(o.success, 'outcome should succeed: ' + o.errorMessage);
            Assert.isTrue(String.isNotBlank(o.entityName));
            Assert.isFalse(o.recipients.isEmpty(), 'recipients captured for tracking');
        }
    }

    @IsTest
    static void unknownEntityIsCapturedAsFailure() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        // An entity with no position on this investment is not sendable.
        Investing_Entity__c outsider = new Investing_Entity__c(
            Name = 'Outside LLC', Entity_Type__c = 'Individual');
        insert outsider;

        SignatureRequestModels.SendRequest req = fileRequest();
        List<SignatureRequestModels.SendOutcome> outcomes = new List<SignatureRequestModels.SendOutcome>();
        SignatureRequestSender link = new SignatureRequestSender(
            req, new List<Id>{ outsider.Id }, outcomes, null, true);
        link.execute(null);

        Assert.areEqual(1, outcomes.size());
        Assert.isFalse(outcomes[0].success);
        Assert.isTrue(outcomes[0].errorMessage.contains('No selected investors'), outcomes[0].errorMessage);
        Assert.areEqual(0, fake.sendCount);
    }

    @IsTest
    static void templateRoleLookupFailureFallsBackAndStillSends() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        fake.throwOnTemplate = true;
        SignatureRequestService.gateway = fake;

        Id invId = [SELECT Id FROM Investment__c LIMIT 1].Id;
        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            JSON.serialize(new Map<String, Object>{
                'investmentId' => invId,
                'document' => new Map<String, Object>{
                    'sourceType' => 'TEMPLATE',
                    'templateId' => '11111111-1111-1111-1111-111111111111',
                    'name' => 'Sub Docs' },
                'fields' => new List<Object>(),
                'selectedAssociationIds' => allAssociationIds()
            }));

        Id soloEntityId = [SELECT Id FROM Investing_Entity__c WHERE Name = 'Solo LLC' LIMIT 1].Id;
        List<SignatureRequestModels.SendOutcome> outcomes = new List<SignatureRequestModels.SendOutcome>();
        SignatureRequestSender link = new SignatureRequestSender(
            req, new List<Id>{ soloEntityId }, outcomes, null, false);
        link.execute(null);

        Assert.areEqual(1, outcomes.size());
        Assert.isTrue(outcomes[0].success,
            'send proceeds with the default role when template lookup fails: ' + outcomes[0].errorMessage);
        Assert.areEqual(1, fake.sendCount);
    }
}
