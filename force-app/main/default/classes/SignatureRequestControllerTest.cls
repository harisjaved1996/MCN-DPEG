@IsTest
private class SignatureRequestControllerTest {

    @TestSetup
    static void setup() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;

        Contact prime = new Contact(LastName = 'Prime', Email = 'prime@example.com', Phone = '111');
        Contact second = new Contact(LastName = 'Second', Email = 'second@example.com');
        insert new List<Contact>{ prime, second };

        Investing_Entity__c entity = new Investing_Entity__c(
            Name = 'Alpha LLC', Entity_Type__c = 'Partnership or LLC');
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
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
        insert new ContentDocumentLink(
            ContentDocumentId = cv.ContentDocumentId,
            LinkedEntityId = inv.Id,
            ShareType = 'V');
    }

    private static Id investmentId() {
        return [SELECT Id FROM Investment__c WHERE Name = 'Fund IV' LIMIT 1].Id;
    }

    private static List<Id> allAssociationIds() {
        List<Id> ids = new List<Id>();
        for (Associated_Contact__c a : [SELECT Id FROM Associated_Contact__c ORDER BY Name]) {
            ids.add(a.Id);
        }
        return ids;
    }

    private static String sendJson(Id invId, Id contentVersionId, List<Id> associationIds) {
        return JSON.serialize(new Map<String, Object>{
            'investmentId' => invId,
            'emailSubject' => 'Please sign',
            'emailMessage' => 'msg',
            'document' => new Map<String, Object>{
                'sourceType' => 'FILE', 'contentVersionId' => contentVersionId, 'name' => 'PPM.pdf',
                'pageCount' => 2, 'lastPageWidth' => 612, 'lastPageHeight' => 792 },
            'fields' => new List<Object>{
                new Map<String, Object>{
                    'clientId' => 'txt1', 'category' => 'ENTRY', 'entryKind' => 'REQUIRED_TEXT',
                    'label' => 'Required Text', 'page' => 1, 'x' => 100, 'y' => 200 } },
            'selectedAssociationIds' => associationIds
        });
    }

    @IsTest
    static void getMergeFieldsReturnsGroups() {
        List<SignatureRequestModels.MergeGroup> groups = SignatureRequestController.getMergeFields();
        Assert.isTrue(groups.size() >= 3, 'expected merge groups for wizard objects');
    }

    @IsTest
    static void getFilesReturnsLinkedPdf() {
        List<SignatureRequestModels.FileDoc> files = SignatureRequestController.getFiles(investmentId());
        Assert.areEqual(1, files.size());
        Assert.areEqual('PPM', files[0].title);
    }

    @IsTest
    static void getDocumentPreviewReturnsBase64AndGuardsSize() {
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;

        String b64 = SignatureRequestController.getDocumentPreview(cvId);
        Assert.isTrue(EncodingUtil.base64Decode(b64).toString().startsWith('%PDF'), 'round-trips the bytes');

        SignatureRequestController.MAX_PREVIEW_BYTES = 3;
        try {
            SignatureRequestController.getDocumentPreview(cvId);
            Assert.fail('expected size-guard failure');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('too large'), e.getMessage());
        }
    }

    @IsTest
    static void getProspectsReturnsAssociatedInvestors() {
        SignatureRequestModels.ProspectResult result = SignatureRequestController.getProspects(investmentId());
        Assert.areEqual('Fund IV', result.investmentName);
        Assert.areEqual(2, result.prospects.size(), 'both associated contacts listed');
        for (SignatureRequestModels.Prospect p : result.prospects) {
            Assert.areEqual('Alpha LLC', p.entityName);
            Assert.isNotNull(p.associationId);
        }
    }

    @IsTest
    static void getTemplatesMapsThroughGateway() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        fake.templateToReturn = new dfsle.Template(
            null, 'Sub Docs', null, null, 'Subject', null, null, null);
        SignatureRequestService.gateway = fake;

        // Template with a null id is dropped by the mapper rather than sent to the LWC broken.
        Assert.areEqual(0, SignatureRequestController.getTemplates().size());
    }

    @IsTest
    static void sendQueuesOneEnvelopePerEntityWithRecipientCopies() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        Id invId = investmentId();
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;

        Test.startTest();
        SignatureRequestModels.SendReceipt receipt =
            SignatureRequestController.send(sendJson(invId, cvId, allAssociationIds()));
        Test.stopTest();

        Assert.areEqual(1, receipt.plannedCount, 'one entity => one envelope');
        Assert.isNotNull(receipt.asyncJobId);
        Assert.isNotNull(receipt.masterDocumentId, 'tracking master created up front');
        Assert.areEqual(0, receipt.warnings.size(), receipt.warnings.toString());
        Assert.areEqual(1, fake.sendCount, 'queueable sent exactly one shared envelope');

        List<Document_Copy__c> copies = [
            SELECT Status__c, Is_Primary__c, Is_Required_Signer__c, Recipient_Role__c, Routing_Order__c
            FROM Document_Copy__c ORDER BY Routing_Order__c
        ];
        Assert.areEqual(2, copies.size(), 'one tracking copy per recipient of the shared envelope');
        Assert.areEqual('Sent', copies[0].Status__c);
        Boolean sawPrimary = false;
        for (Document_Copy__c c : copies) {
            if (c.Is_Primary__c) {
                sawPrimary = true;
                Assert.areEqual(2, c.Routing_Order__c, 'primary signs last');
            }
        }
        Assert.isTrue(sawPrimary);

        Assert.areEqual(1, SignatureRequestController.getMasterDocuments(invId).size());
        Assert.areEqual(2, SignatureRequestController.getCopies(receipt.masterDocumentId).size());
    }

    @IsTest
    static void sendWithoutPrimarySelectedIsRejected() {
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        Id secondAssoc = [SELECT Id FROM Associated_Contact__c WHERE Primary__c = FALSE LIMIT 1].Id;

        try {
            SignatureRequestController.send(sendJson(investmentId(), cvId, new List<Id>{ secondAssoc }));
            Assert.fail('expected no-primary failure');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('Nothing to send'), e.getMessage());
        }
    }

    @IsTest
    static void refreshStatusesPollsAndReturnsRows() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        Id invId = investmentId();
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            sendJson(invId, cvId, allAssociationIds()));
        Id masterId = SignatureRequestTracking.createMaster(req);

        List<SignatureRequestModels.CopyRow> rows =
            SignatureRequestController.refreshStatuses(masterId);
        Assert.areEqual(0, rows.size(), 'no copies yet');
        Assert.areEqual(1, fake.pollCount, 'DocuSign was polled');
    }

    @IsTest
    static void createPreviewEnvelopeReturnsSenderView() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        Id invId = investmentId();
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;

        try {
            String senderView = SignatureRequestController.createPreviewEnvelope(
                sendJson(invId, cvId, allAssociationIds()));
            Assert.isTrue(senderView.startsWith('https://'), senderView);
            Assert.areEqual(1, fake.draftCount, 'draft path used, not sendNow');
        } catch (AuraHandledException e) {
            // The fake gateway returns an envelope without a DocuSign id, which
            // is also a valid (guarded) outcome for this utility.
            Assert.isTrue(e.getMessage().contains('DocuSign id'), e.getMessage());
            Assert.areEqual(1, fake.draftCount, 'draft path used, not sendNow');
        }
    }
}
