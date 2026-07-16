@IsTest
private class SignatureRequestTrackingTest {

    @TestSetup
    static void setup() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;

        Contact alpha = new Contact(LastName = 'Alpha', Email = 'alpha@example.com');
        Contact beta = new Contact(LastName = 'Beta', Email = 'beta@example.com');
        insert new List<Contact>{ alpha, beta };

        List<Investing_Entity__c> entities = new List<Investing_Entity__c>{
            new Investing_Entity__c(Name = 'Alpha LLC', Entity_Type__c = 'Partnership or LLC', Contact__c = alpha.Id),
            new Investing_Entity__c(Name = 'Beta Trust', Entity_Type__c = 'Estate or Trust', Contact__c = beta.Id)
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

    private static Id investmentId() {
        return [SELECT Id FROM Investment__c LIMIT 1].Id;
    }

    private static Contact contactByName(String lastName) {
        return [SELECT Id, Name FROM Contact WHERE LastName = :lastName LIMIT 1];
    }

    private static SignatureRequestModels.SendRequest buildRequest(List<Id> contactIds) {
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        return SignatureRequestService.parseAndValidate(JSON.serialize(new Map<String, Object>{
            'investmentId' => investmentId(),
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

    private static SignatureRequestModels.SendOutcome outcomeFor(
            Contact c, Id entityId, Boolean success, String docuSignId) {
        SignatureRequestModels.SendOutcome o = new SignatureRequestModels.SendOutcome();
        o.contactId = c.Id;
        o.contactName = c.Name;
        o.entityId = entityId;
        o.success = success;
        o.docuSignId = docuSignId;
        o.errorMessage = success ? null : 'DocuSign said no';
        return o;
    }

    @IsTest
    static void masterAndCopyLifecycleRollsUpMetrics() {
        Contact alpha = contactByName('Alpha');
        Contact beta = contactByName('Beta');
        Id entityId = [SELECT Id FROM Investing_Entity__c WHERE Name = 'Alpha LLC' LIMIT 1].Id;

        SignatureRequestModels.SendRequest req = buildRequest(new List<Id>{ alpha.Id, beta.Id });
        Id masterId = SignatureRequestTracking.createMaster(req);

        Master_Document__c master = [
            SELECT Name, Source_Type__c, Request_Payload__c, Sent_Count__c, Failed_Count__c
            FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual('PPM.pdf', master.Name);
        Assert.areEqual('FILE', master.Source_Type__c);
        Assert.isTrue(String.isNotBlank(master.Request_Payload__c), 'payload stored for resends');

        SignatureRequestTracking.createCopyForOutcome(masterId,
            outcomeFor(alpha, entityId, true, 'aaaa1111-2222-3333-4444-555566667777'));
        SignatureRequestTracking.createCopyForOutcome(masterId,
            outcomeFor(beta, null, false, null));

        master = [
            SELECT Sent_Count__c, Opened_Count__c, Completed_Count__c, Failed_Count__c
            FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual(1, master.Sent_Count__c);
        Assert.areEqual(0, master.Opened_Count__c);
        Assert.areEqual(0, master.Completed_Count__c);
        Assert.areEqual(1, master.Failed_Count__c);

        List<SignatureRequestModels.MasterDocSummary> masters =
            SignatureRequestTracking.getMasterDocuments(investmentId());
        Assert.areEqual(1, masters.size());
        Assert.areEqual(1, masters[0].sentCount);
        Assert.areEqual(1, masters[0].failedCount);

        List<SignatureRequestModels.CopyRow> rows = SignatureRequestTracking.getCopies(masterId);
        Assert.areEqual(2, rows.size());
        for (SignatureRequestModels.CopyRow row : rows) {
            if (row.status == SignatureRequestTracking.STATUS_SENT) {
                Assert.isTrue(row.viewable, 'sent copy is viewable');
                Assert.areEqual('Alpha LLC', row.entityName);
            } else {
                Assert.areEqual(SignatureRequestTracking.STATUS_FAILED, row.status);
                Assert.isFalse(row.viewable, 'failed copy has no envelope to view');
            }
            Assert.isTrue(row.resettable);
        }
    }

    @IsTest
    static void syncStatusesTracksOpenedAndCompleted() {
        Contact alpha = contactByName('Alpha');
        SignatureRequestModels.SendRequest req = buildRequest(new List<Id>{ alpha.Id });
        Id masterId = SignatureRequestTracking.createMaster(req);
        SignatureRequestTracking.createCopyForOutcome(masterId,
            outcomeFor(alpha, null, true, 'bbbb1111-2222-3333-4444-555566667777'));

        // Case-insensitive envelope id match; Delivered marks the copy opened.
        SignatureRequestTracking.syncStatuses(new List<dfsle__EnvelopeStatus__c>{
            new dfsle__EnvelopeStatus__c(
                dfsle__DocuSignId__c = 'BBBB1111-2222-3333-4444-555566667777',
                dfsle__Status__c = 'Delivered',
                dfsle__Sent__c = Datetime.now().addMinutes(-10),
                dfsle__LastStatusUpdate__c = Datetime.now().addMinutes(-5))
        });

        Document_Copy__c copy = [
            SELECT Status__c, Opened_At__c, Completed_At__c FROM Document_Copy__c LIMIT 1
        ];
        Assert.areEqual('Delivered', copy.Status__c);
        Assert.isNotNull(copy.Opened_At__c, 'Delivered implies opened');
        Assert.isNull(copy.Completed_At__c);

        Master_Document__c master = [
            SELECT Opened_Count__c, Completed_Count__c FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual(1, master.Opened_Count__c);
        Assert.areEqual(0, master.Completed_Count__c);

        SignatureRequestTracking.syncStatuses(new List<dfsle__EnvelopeStatus__c>{
            new dfsle__EnvelopeStatus__c(
                dfsle__DocuSignId__c = 'bbbb1111-2222-3333-4444-555566667777',
                dfsle__Status__c = 'Completed',
                dfsle__Completed__c = Datetime.now())
        });

        copy = [SELECT Status__c, Completed_At__c FROM Document_Copy__c LIMIT 1];
        Assert.areEqual('Completed', copy.Status__c);
        Assert.isNotNull(copy.Completed_At__c);

        master = [
            SELECT Opened_Count__c, Completed_Count__c FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual(1, master.Opened_Count__c);
        Assert.areEqual(1, master.Completed_Count__c);
    }

    @IsTest
    static void resetAndResendVoidsSupersedesAndQueuesFreshCopy() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        Contact alpha = contactByName('Alpha');
        Id entityId = [SELECT Id FROM Investing_Entity__c WHERE Name = 'Alpha LLC' LIMIT 1].Id;
        SignatureRequestModels.SendRequest req = buildRequest(new List<Id>{ alpha.Id });
        Id masterId = SignatureRequestTracking.createMaster(req);
        SignatureRequestTracking.createCopyForOutcome(masterId,
            outcomeFor(alpha, entityId, true, 'cccc1111-2222-3333-4444-555566667777'));
        Id copyId = [SELECT Id FROM Document_Copy__c LIMIT 1].Id;

        Test.startTest();
        SignatureRequestModels.SendReceipt receipt = SignatureRequestTracking.resetAndResend(copyId);
        Test.stopTest(); // runs the queued single-contact sender with the fake gateway

        Assert.areEqual(1, receipt.plannedCount);
        Assert.areEqual(masterId, receipt.masterDocumentId);
        Assert.areEqual(1, fake.voidCount, 'in-flight envelope was voided');
        Assert.areEqual(1, fake.sendCount, 'a fresh envelope was sent');

        List<Document_Copy__c> copies = [
            SELECT Status__c FROM Document_Copy__c ORDER BY CreatedDate, Id
        ];
        Assert.areEqual(2, copies.size(), 'old (reset) + new copy');
        Assert.areEqual(SignatureRequestTracking.STATUS_RESET, copies[0].Status__c);
        Assert.areEqual(SignatureRequestTracking.STATUS_SENT, copies[1].Status__c);

        Master_Document__c master = [
            SELECT Sent_Count__c, Failed_Count__c FROM Master_Document__c WHERE Id = :masterId
        ];
        Assert.areEqual(1, master.Sent_Count__c, 'reset copy no longer counts');
        Assert.areEqual(0, master.Failed_Count__c);
    }

    @IsTest
    static void resetOnCompletedCopySkipsVoidButResends() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        Contact alpha = contactByName('Alpha');
        SignatureRequestModels.SendRequest req = buildRequest(new List<Id>{ alpha.Id });
        Id masterId = SignatureRequestTracking.createMaster(req);
        SignatureRequestTracking.createCopyForOutcome(masterId,
            outcomeFor(alpha, null, true, 'dddd1111-2222-3333-4444-555566667777'));
        Document_Copy__c copy = [SELECT Id FROM Document_Copy__c LIMIT 1];
        copy.Status__c = 'Completed';
        copy.Completed_At__c = Datetime.now();
        update copy;

        Test.startTest();
        SignatureRequestTracking.resetAndResend(copy.Id);
        Test.stopTest();

        Assert.areEqual(0, fake.voidCount, 'completed envelopes cannot be voided');
        Assert.areEqual(1, fake.sendCount, 'fresh copy still goes out');
        Assert.areEqual(SignatureRequestTracking.STATUS_RESET,
            [SELECT Status__c FROM Document_Copy__c WHERE Id = :copy.Id].Status__c);
    }

    @IsTest
    static void envelopeStatusTriggerSyncsCopies() {
        Contact alpha = contactByName('Alpha');
        SignatureRequestModels.SendRequest req = buildRequest(new List<Id>{ alpha.Id });
        Id masterId = SignatureRequestTracking.createMaster(req);
        SignatureRequestTracking.createCopyForOutcome(masterId,
            outcomeFor(alpha, null, true, 'eeee1111-2222-3333-4444-555566667777'));

        insert new dfsle__EnvelopeStatus__c(
            dfsle__DocuSignId__c = 'eeee1111-2222-3333-4444-555566667777',
            dfsle__Status__c = 'Delivered',
            dfsle__Sent__c = Datetime.now(),
            dfsle__LastStatusUpdate__c = Datetime.now(),
            dfsle__SourceId__c = String.valueOf(investmentId())
        );

        Document_Copy__c copy = [SELECT Status__c, Opened_At__c FROM Document_Copy__c LIMIT 1];
        Assert.areEqual('Delivered', copy.Status__c, 'trigger mirrored the DocuSign status');
        Assert.isNotNull(copy.Opened_At__c);
    }
}
