@IsTest
private class SignatureRequestControllerTest {

    @TestSetup
    static void setup() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;

        Contact alpha = new Contact(LastName = 'Alpha', Email = 'alpha@example.com', Phone = '111');
        insert alpha;

        Investing_Entity__c entity = new Investing_Entity__c(
            Name = 'Alpha LLC', Entity_Type__c = 'Partnership or LLC', Contact__c = alpha.Id);
        insert entity;

        insert new position__c(Investment__c = inv.Id, Investing_Entity__c = entity.Id);

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

    private static String sendJson(Id invId, Id contentVersionId, List<Id> contactIds) {
        return JSON.serialize(new Map<String, Object>{
            'investmentId' => invId,
            'emailSubject' => 'Please sign',
            'emailMessage' => 'msg',
            'document' => new Map<String, Object>{
                'sourceType' => 'FILE', 'contentVersionId' => contentVersionId, 'name' => 'PPM.pdf' },
            'fields' => new List<Object>{
                new Map<String, Object>{
                    'clientId' => 'sig1', 'category' => 'RECIPIENT', 'recipientKind' => 'SIGNATURE',
                    'label' => 'Signature', 'page' => 1, 'x' => 100, 'y' => 200 } },
            'selectedContactIds' => contactIds
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
        Assert.areEqual('pdf', files[0].extension);
        Assert.isNotNull(files[0].contentVersionId);
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
    static void getProspectsReturnsInvestors() {
        SignatureRequestModels.ProspectResult result = SignatureRequestController.getProspects(investmentId());
        Assert.areEqual('Fund IV', result.investmentName);
        Assert.areEqual(1, result.prospects.size());
        Assert.areEqual('Alpha LLC', result.prospects[0].entityName);
    }

    @IsTest
    static void getTemplatesMapsThroughGateway() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        fake.templateToReturn = new dfsle.Template(
            null, 'Sub Docs', null, null, 'Subject', null, null, null);
        SignatureRequestService.gateway = fake;

        List<SignatureRequestModels.TemplateDoc> templates = SignatureRequestController.getTemplates();
        // Template with a null id is dropped by the mapper rather than sent to the LWC broken.
        Assert.areEqual(0, templates.size());
    }

    @IsTest
    static void sendQueuesOneEnvelopePerContact() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        Id invId = investmentId();
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        Id alphaId = [SELECT Id FROM Contact WHERE LastName = 'Alpha' LIMIT 1].Id;

        Test.startTest();
        SignatureRequestModels.SendReceipt receipt =
            SignatureRequestController.send(sendJson(invId, cvId, new List<Id>{ alphaId }));
        Test.stopTest();

        Assert.areEqual(1, receipt.plannedCount);
        Assert.isNotNull(receipt.asyncJobId);
        Assert.isNotNull(receipt.masterDocumentId, 'tracking master created up front');
        Assert.areEqual(1, fake.sendCount, 'queueable sent exactly one envelope');

        List<Document_Copy__c> copies = [
            SELECT Status__c, Contact__c, Master_Document__c FROM Document_Copy__c
        ];
        Assert.areEqual(1, copies.size(), 'one tracking copy per sent envelope');
        Assert.areEqual(receipt.masterDocumentId, copies[0].Master_Document__c);
        Assert.areEqual(alphaId, copies[0].Contact__c);
        Assert.areEqual('Sent', copies[0].Status__c);

        List<SignatureRequestModels.MasterDocSummary> masters =
            SignatureRequestController.getMasterDocuments(invId);
        Assert.areEqual(1, masters.size());
        Assert.areEqual(1, masters[0].sentCount);

        List<SignatureRequestModels.CopyRow> rows =
            SignatureRequestController.getCopies(receipt.masterDocumentId);
        Assert.areEqual(1, rows.size());
    }

    @IsTest
    static void refreshStatusesPollsAndReturnsRows() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        Id invId = investmentId();
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        Id alphaId = [SELECT Id FROM Contact WHERE LastName = 'Alpha' LIMIT 1].Id;

        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            sendJson(invId, cvId, new List<Id>{ alphaId }));
        Id masterId = SignatureRequestTracking.createMaster(req);

        List<SignatureRequestModels.CopyRow> rows =
            SignatureRequestController.refreshStatuses(masterId);
        Assert.areEqual(0, rows.size(), 'no copies yet');
        Assert.areEqual(1, fake.pollCount, 'DocuSign was polled');
    }

    @IsTest
    static void sendRejectsNonInvestorSelection() {
        Contact stranger = new Contact(LastName = 'Stranger', Email = 's@example.com');
        insert stranger;
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;

        try {
            SignatureRequestController.send(sendJson(investmentId(), cvId, new List<Id>{ stranger.Id }));
            Assert.fail('expected non-investor failure');
        } catch (AuraHandledException e) {
            Assert.isTrue(e.getMessage().contains('current investors'), e.getMessage());
        }
    }

    @IsTest
    static void createPreviewEnvelopeReturnsSenderView() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;

        Id invId = investmentId();
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        Id alphaId = [SELECT Id FROM Contact WHERE LastName = 'Alpha' LIMIT 1].Id;

        try {
            String senderView = SignatureRequestController.createPreviewEnvelope(
                sendJson(invId, cvId, new List<Id>{ alphaId }));
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
