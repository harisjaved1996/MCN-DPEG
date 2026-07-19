@IsTest
private class SignatureRequestTrackingTest {

    @TestSetup
    static void setup() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;

        Contact prime = new Contact(LastName = 'Prime', Email = 'prime@example.com');
        Contact second = new Contact(LastName = 'Second', Email = 'second@example.com');
        insert new List<Contact>{ prime, second };

        Investing_Entity__c entity = new Investing_Entity__c(
            Name = 'Trust Entity', Entity_Type__c = 'Estate or Trust');
        insert entity;

        insert new position__c(Investment__c = inv.Id, Investing_Entity__c = entity.Id);

        insert new List<Associated_Contact__c>{
            new Associated_Contact__c(Name = 'Prime', Investing_Entity__c = entity.Id,
                Contact__c = prime.Id, Primary__c = true, Required_Signer__c = true),
            new Associated_Contact__c(Name = 'Second', Investing_Entity__c = entity.Id,
                Contact__c = second.Id, Primary__c = false, Required_Signer__c = true)
        };

        ContentVersion cv = new ContentVersion(
            Title = 'PPM', PathOnClient = 'PPM.pdf', VersionData = Blob.valueOf('%PDF-1.4 test'));
        insert cv;
    }

    private static Id investmentId() {
        return [SELECT Id FROM Investment__c LIMIT 1].Id;
    }

    private static Id entityId() {
        return [SELECT Id FROM Investing_Entity__c LIMIT 1].Id;
    }

    private static SignatureRequestModels.SendRequest buildRequest() {
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        List<Id> assocIds = new List<Id>();
        for (Associated_Contact__c a : [SELECT Id FROM Associated_Contact__c ORDER BY Name]) {
            assocIds.add(a.Id);
        }
        return SignatureRequestService.parseAndValidate(JSON.serialize(new Map<String, Object>{
            'investmentId' => investmentId(),
            'emailSubject' => 'Please sign',
            'document' => new Map<String, Object>{
                'sourceType' => 'FILE', 'contentVersionId' => cvId, 'name' => 'PPM.pdf',
                'pageCount' => 2, 'lastPageWidth' => 612, 'lastPageHeight' => 792 },
            'fields' => new List<Object>(),
            'selectedAssociationIds' => assocIds
        }));
    }

    /** Entity outcome with primary + required-secondary recipients. */
    private static SignatureRequestModels.SendOutcome entityOutcome(String docuSignId) {
        Contact prime = [SELECT Id, Name FROM Contact WHERE LastName = 'Prime' LIMIT 1];
        Contact second = [SELECT Id, Name FROM Contact WHERE LastName = 'Second' LIMIT 1];

        SignatureRequestModels.RecipientPlan primaryPlan = new SignatureRequestModels.RecipientPlan();
        primaryPlan.contactId = prime.Id;
        primaryPlan.contactName = prime.Name;
        primaryPlan.isPrimary = true;
        primaryPlan.isRequiredSigner = true;
        primaryPlan.routingOrder = 2;
        primaryPlan.recipientRole = 'Signer';

        SignatureRequestModels.RecipientPlan secondPlan = new SignatureRequestModels.RecipientPlan();
        secondPlan.contactId = second.Id;
        secondPlan.contactName = second.Name;
        secondPlan.isRequiredSigner = true;
        secondPlan.routingOrder = 1;
        secondPlan.recipientRole = 'Signer';

        SignatureRequestModels.SendOutcome outcome = new SignatureRequestModels.SendOutcome();
        outcome.entityId = entityId();
        outcome.entityName = 'Trust Entity';
        outcome.contactId = prime.Id;
        outcome.contactName = prime.Name;
        outcome.success = docuSignId != null;
        outcome.docuSignId = docuSignId;
        outcome.errorMessage = docuSignId == null ? 'DocuSign said no' : null;
        outcome.recipients = new List<SignatureRequestModels.RecipientPlan>{ secondPlan, primaryPlan };
        return outcome;
    }

    @IsTest
    static void masterAndRecipientCopiesRollUpMetrics() {
        SignatureRequestModels.SendRequest req = buildRequest();
        Id masterId = SignatureRequestTracking.createMaster(req);

        Master_Document__c master = [
            SELECT Name, Source_Type__c, Request_Payload__c FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual('PPM.pdf', master.Name);
        Assert.isTrue(master.Request_Payload__c.contains('selectedAssociationIds'),
            'payload stored for entity-level resends');

        SignatureRequestTracking.createCopiesForOutcome(masterId,
            entityOutcome('aaaa1111-2222-3333-4444-555566667777'));

        List<Document_Copy__c> copies = [
            SELECT Status__c, Is_Primary__c, Routing_Order__c, DocuSign_Envelope_Id__c, Envelope_Link__c
            FROM Document_Copy__c ORDER BY Routing_Order__c
        ];
        Assert.areEqual(2, copies.size(), 'one copy per recipient of the shared envelope');
        Assert.areEqual(copies[0].DocuSign_Envelope_Id__c, copies[1].DocuSign_Envelope_Id__c,
            'both copies share the entity envelope');
        Assert.isTrue(copies[0].Envelope_Link__c.contains('aaaa1111'),
            'durable envelope link stored for the portal phase');
        Assert.isTrue(copies[1].Is_Primary__c, 'routing order 2 row is the primary');

        Master_Document__c counted = [
            SELECT Sent_Count__c, Opened_Count__c, Completed_Count__c, Failed_Count__c
            FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual(2, counted.Sent_Count__c);
        Assert.areEqual(0, counted.Failed_Count__c);

        List<SignatureRequestModels.CopyRow> rows = SignatureRequestTracking.getCopies(masterId);
        Assert.areEqual(2, rows.size());
        for (SignatureRequestModels.CopyRow row : rows) {
            Assert.isTrue(row.viewable);
            Assert.isTrue(row.resettable);
            Assert.areEqual('Signer', row.recipientRole);
            Assert.isTrue(String.isNotBlank(row.envelopeLink));
        }
    }

    @IsTest
    static void failedEntityOutcomeCreatesFailureRow() {
        SignatureRequestModels.SendRequest req = buildRequest();
        Id masterId = SignatureRequestTracking.createMaster(req);

        SignatureRequestTracking.createCopiesForOutcome(masterId, entityOutcome(null));

        Master_Document__c master = [
            SELECT Sent_Count__c, Failed_Count__c FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual(0, master.Sent_Count__c);
        Assert.areEqual(2, master.Failed_Count__c, 'both recipient rows count as failed');
    }

    @IsTest
    static void syncStatusesFlipsAllCopiesOfTheEnvelope() {
        SignatureRequestModels.SendRequest req = buildRequest();
        Id masterId = SignatureRequestTracking.createMaster(req);
        SignatureRequestTracking.createCopiesForOutcome(masterId,
            entityOutcome('bbbb1111-2222-3333-4444-555566667777'));

        SignatureRequestTracking.syncStatuses(new List<dfsle__EnvelopeStatus__c>{
            new dfsle__EnvelopeStatus__c(
                dfsle__DocuSignId__c = 'BBBB1111-2222-3333-4444-555566667777',
                dfsle__Status__c = 'Delivered',
                dfsle__Sent__c = Datetime.now().addMinutes(-10),
                dfsle__LastStatusUpdate__c = Datetime.now().addMinutes(-5))
        });

        for (Document_Copy__c copy : [SELECT Status__c, Opened_At__c FROM Document_Copy__c]) {
            Assert.areEqual('Delivered', copy.Status__c, 'envelope status mirrors onto every copy');
            Assert.isNotNull(copy.Opened_At__c);
        }

        SignatureRequestTracking.syncStatuses(new List<dfsle__EnvelopeStatus__c>{
            new dfsle__EnvelopeStatus__c(
                dfsle__DocuSignId__c = 'bbbb1111-2222-3333-4444-555566667777',
                dfsle__Status__c = 'Completed',
                dfsle__Completed__c = Datetime.now())
        });

        Master_Document__c master = [
            SELECT Opened_Count__c, Completed_Count__c FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual(2, master.Opened_Count__c);
        Assert.areEqual(2, master.Completed_Count__c);
    }

    @IsTest
    static void resetAndResendCascadesTheWholeEntityEnvelope() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        SignatureRequestModels.SendRequest req = buildRequest();
        Id masterId = SignatureRequestTracking.createMaster(req);
        SignatureRequestTracking.createCopiesForOutcome(masterId,
            entityOutcome('cccc1111-2222-3333-4444-555566667777'));
        Id anyCopyId = [SELECT Id FROM Document_Copy__c LIMIT 1].Id;

        Test.startTest();
        SignatureRequestModels.SendReceipt receipt = SignatureRequestTracking.resetAndResend(anyCopyId);
        Test.stopTest(); // runs the queued entity sender with the fake gateway

        Assert.areEqual(masterId, receipt.masterDocumentId);
        Assert.areEqual(1, fake.voidCount, 'shared envelope voided once');
        Assert.areEqual(1, fake.sendCount, 'one fresh entity envelope sent');

        Integer resetCount = 0;
        Integer sentCount = 0;
        for (Document_Copy__c copy : [SELECT Status__c FROM Document_Copy__c]) {
            if (copy.Status__c == SignatureRequestTracking.STATUS_RESET) {
                resetCount++;
            } else if (copy.Status__c == SignatureRequestTracking.STATUS_SENT) {
                sentCount++;
            }
        }
        Assert.areEqual(2, resetCount, 'both sibling copies superseded');
        Assert.areEqual(2, sentCount, 'fresh copies for both recipients');

        Master_Document__c master = [
            SELECT Sent_Count__c FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual(2, master.Sent_Count__c, 'reset copies no longer count');
    }

    @IsTest
    static void resetOnCompletedCopySkipsVoidButResends() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        SignatureRequestModels.SendRequest req = buildRequest();
        Id masterId = SignatureRequestTracking.createMaster(req);
        SignatureRequestTracking.createCopiesForOutcome(masterId,
            entityOutcome('dddd1111-2222-3333-4444-555566667777'));
        Document_Copy__c copy = [SELECT Id FROM Document_Copy__c LIMIT 1];
        copy.Status__c = 'Completed';
        update copy;

        Test.startTest();
        SignatureRequestTracking.resetAndResend(copy.Id);
        Test.stopTest();

        Assert.areEqual(0, fake.voidCount, 'completed envelopes cannot be voided');
        Assert.areEqual(1, fake.sendCount, 'fresh entity envelope still goes out');
    }

    @IsTest
    static void envelopeStatusTriggerSyncsCopies() {
        SignatureRequestModels.SendRequest req = buildRequest();
        Id masterId = SignatureRequestTracking.createMaster(req);
        SignatureRequestTracking.createCopiesForOutcome(masterId,
            entityOutcome('eeee1111-2222-3333-4444-555566667777'));

        insert new dfsle__EnvelopeStatus__c(
            dfsle__DocuSignId__c = 'eeee1111-2222-3333-4444-555566667777',
            dfsle__Status__c = 'Delivered',
            dfsle__Sent__c = Datetime.now(),
            dfsle__LastStatusUpdate__c = Datetime.now(),
            dfsle__SourceId__c = String.valueOf(investmentId())
        );

        for (Document_Copy__c copy : [SELECT Status__c, Opened_At__c FROM Document_Copy__c]) {
            Assert.areEqual('Delivered', copy.Status__c, 'trigger mirrored the DocuSign status');
            Assert.isNotNull(copy.Opened_At__c);
        }
    }
}
