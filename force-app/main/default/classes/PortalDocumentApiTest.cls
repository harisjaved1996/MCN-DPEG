@IsTest
private class PortalDocumentApiTest {

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

    private static Contact contactByLastName(String lastName) {
        return [SELECT Id, Name, Email FROM Contact WHERE LastName = :lastName LIMIT 1];
    }

    /** Master + one shared-envelope copy pair (Second routing 1, Prime routing 2). */
    private static Id seedTracking(String envelopeId) {
        Id cvId = [SELECT Id FROM ContentVersion WHERE Title = 'PPM' LIMIT 1].Id;
        Id invId = [SELECT Id FROM Investment__c LIMIT 1].Id;
        List<Id> assocIds = new List<Id>();
        for (Associated_Contact__c a : [SELECT Id FROM Associated_Contact__c ORDER BY Name]) {
            assocIds.add(a.Id);
        }
        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            JSON.serialize(new Map<String, Object>{
                'investmentId' => invId,
                'emailSubject' => 'Please sign',
                'document' => new Map<String, Object>{
                    'sourceType' => 'FILE', 'contentVersionId' => cvId, 'name' => 'PPM.pdf',
                    'pageCount' => 2, 'lastPageWidth' => 612, 'lastPageHeight' => 792 },
                'fields' => new List<Object>(),
                'selectedAssociationIds' => assocIds
            }));
        Id masterId = SignatureRequestTracking.createMaster(req);

        Contact prime = contactByLastName('Prime');
        Contact second = contactByLastName('Second');

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
        outcome.entityId = [SELECT Id FROM Investing_Entity__c LIMIT 1].Id;
        outcome.entityName = 'Trust Entity';
        outcome.contactId = prime.Id;
        outcome.contactName = prime.Name;
        outcome.success = true;
        outcome.docuSignId = envelopeId;
        outcome.recipients = new List<SignatureRequestModels.RecipientPlan>{ secondPlan, primaryPlan };
        SignatureRequestTracking.createCopiesForOutcome(masterId, outcome);
        return masterId;
    }

    private static RestResponse invokeGet(Map<String, String> params) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/portal/v1/documents';
        req.httpMethod = 'GET';
        req.params.putAll(params);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        PortalDocumentApi.doGet();
        return RestContext.response;
    }

    private static RestResponse invokePost(String uri, String body) {
        RestRequest req = new RestRequest();
        req.requestURI = uri;
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(body);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        PortalDocumentApi.doPost();
        return RestContext.response;
    }

    @IsTest
    static void primaryWaitsOnSecondaryUntilSigned() {
        seedTracking('aaaa1111-2222-3333-4444-555566667777');
        Contact prime = contactByLastName('Prime');
        Contact second = contactByLastName('Second');

        RestResponse res = invokeGet(new Map<String, String>{ 'contactId' => prime.Id });
        Assert.areEqual(200, res.statusCode, res.responseBody.toString());
        PortalDocumentApi.DocumentsResponse primeDocs = (PortalDocumentApi.DocumentsResponse)
            JSON.deserialize(res.responseBody.toString(), PortalDocumentApi.DocumentsResponse.class);
        Assert.areEqual(1, primeDocs.documents.size());
        PortalDocumentApi.PortalDocument doc = primeDocs.documents[0];
        Assert.areEqual('PPM.pdf', doc.documentName);
        Assert.areEqual('Fund IV', doc.investmentName);
        Assert.isTrue(doc.isPrimary);
        Assert.areEqual(2, doc.routingOrder);
        Assert.areEqual(second.Name, doc.waitingOnName, 'primary waits until routing-1 signer is done');

        // The secondary signer's own row is actionable immediately.
        res = invokeGet(new Map<String, String>{ 'contactId' => second.Id });
        PortalDocumentApi.DocumentsResponse secondDocs = (PortalDocumentApi.DocumentsResponse)
            JSON.deserialize(res.responseBody.toString(), PortalDocumentApi.DocumentsResponse.class);
        Assert.isNull(secondDocs.documents[0].waitingOnName);

        // Secondary signs -> primary is unblocked.
        Document_Copy__c secondCopy = [
            SELECT Id FROM Document_Copy__c WHERE Contact__c = :second.Id LIMIT 1
        ];
        secondCopy.Status__c = 'Signed';
        update secondCopy;

        res = invokeGet(new Map<String, String>{ 'contactId' => prime.Id });
        primeDocs = (PortalDocumentApi.DocumentsResponse)
            JSON.deserialize(res.responseBody.toString(), PortalDocumentApi.DocumentsResponse.class);
        Assert.isNull(primeDocs.documents[0].waitingOnName, 'unblocked after secondary signed');
    }

    @IsTest
    static void lookupByEmailAndErrorPaths() {
        seedTracking('bbbb1111-2222-3333-4444-555566667777');

        RestResponse res = invokeGet(new Map<String, String>{ 'email' => 'second@example.com' });
        Assert.areEqual(200, res.statusCode, res.responseBody.toString());
        PortalDocumentApi.DocumentsResponse docs = (PortalDocumentApi.DocumentsResponse)
            JSON.deserialize(res.responseBody.toString(), PortalDocumentApi.DocumentsResponse.class);
        Assert.areEqual(1, docs.documents.size());

        Assert.areEqual(400, invokeGet(new Map<String, String>()).statusCode, 'no identifier');
        Assert.areEqual(404,
            invokeGet(new Map<String, String>{ 'email' => 'nobody@example.com' }).statusCode);
        Assert.areEqual(400,
            invokeGet(new Map<String, String>{ 'contactId' => 'garbage' }).statusCode);
    }

    @IsTest
    static void resetCopiesAreExcluded() {
        seedTracking('cccc1111-2222-3333-4444-555566667777');
        Contact prime = contactByLastName('Prime');
        Document_Copy__c copy = [
            SELECT Id FROM Document_Copy__c WHERE Contact__c = :prime.Id LIMIT 1
        ];
        copy.Status__c = SignatureRequestTracking.STATUS_RESET;
        update copy;

        RestResponse res = invokeGet(new Map<String, String>{ 'contactId' => prime.Id });
        PortalDocumentApi.DocumentsResponse docs = (PortalDocumentApi.DocumentsResponse)
            JSON.deserialize(res.responseBody.toString(), PortalDocumentApi.DocumentsResponse.class);
        Assert.areEqual(0, docs.documents.size(), 'reset rows hidden from the portal');
    }

    @IsTest
    static void refreshPollsDocuSignAndReturnsCopies() {
        SignatureRequestServiceTest.FakeGateway fake = new SignatureRequestServiceTest.FakeGateway();
        SignatureRequestService.gateway = fake;
        Id masterId = seedTracking('dddd1111-2222-3333-4444-555566667777');

        Test.startTest();
        RestResponse res = invokePost('/services/apexrest/portal/v1/refresh',
            JSON.serialize(new Map<String, Object>{ 'masterDocumentId' => masterId }));
        Test.stopTest();

        Assert.areEqual(200, res.statusCode, res.responseBody.toString());
        Assert.areEqual(1, fake.pollCount, 'DocuSign was polled');
        Map<String, Object> payload =
            (Map<String, Object>) JSON.deserializeUntyped(res.responseBody.toString());
        Assert.areEqual(2, ((List<Object>) payload.get('copies')).size());
    }

    @IsTest
    static void refreshValidatesInput() {
        Assert.areEqual(400,
            invokePost('/services/apexrest/portal/v1/refresh', '{}').statusCode);
        Assert.areEqual(404,
            invokePost('/services/apexrest/portal/v1/nonsense', '{}').statusCode);
    }

    private static RestResponse invokeGetInvestmentDocuments(Map<String, String> params) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/portal/v1/investment-documents';
        req.httpMethod = 'GET';
        req.params.putAll(params);
        RestContext.request = req;
        RestContext.response = new RestResponse();
        PortalDocumentApi.doGet();
        return RestContext.response;
    }

    /** A file dropped directly on the Investment (no DocuSign) is visible to every investor. */
    @IsTest
    static void investmentDocumentsAreVisibleToEveryInvestorOnThatInvestment() {
        Contact prime = contactByLastName('Prime');
        Contact second = contactByLastName('Second');
        Contact outsider = new Contact(LastName = 'Outsider', Email = 'outsider@example.com');
        insert outsider;

        Id investmentId = [SELECT Id FROM Investment__c LIMIT 1].Id;
        Id contentDocumentId = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Title = 'PPM' LIMIT 1
        ].ContentDocumentId;
        insert new ContentDocumentLink(
            ContentDocumentId = contentDocumentId,
            LinkedEntityId = investmentId,
            ShareType = 'V');

        RestResponse res = invokeGetInvestmentDocuments(new Map<String, String>{ 'contactId' => prime.Id });
        Assert.areEqual(200, res.statusCode, res.responseBody.toString());
        PortalDocumentApi.InvestmentDocumentsResponse primeDocs =
            (PortalDocumentApi.InvestmentDocumentsResponse) JSON.deserialize(
                res.responseBody.toString(), PortalDocumentApi.InvestmentDocumentsResponse.class);
        Assert.areEqual(1, primeDocs.documents.size());
        Assert.areEqual('PPM', primeDocs.documents[0].title);
        Assert.areEqual('Fund IV', primeDocs.documents[0].investmentName);

        res = invokeGetInvestmentDocuments(new Map<String, String>{ 'contactId' => second.Id });
        PortalDocumentApi.InvestmentDocumentsResponse secondDocs =
            (PortalDocumentApi.InvestmentDocumentsResponse) JSON.deserialize(
                res.responseBody.toString(), PortalDocumentApi.InvestmentDocumentsResponse.class);
        Assert.areEqual(1, secondDocs.documents.size(), 'every investor on the investment sees the file');

        res = invokeGetInvestmentDocuments(new Map<String, String>{ 'contactId' => outsider.Id });
        PortalDocumentApi.InvestmentDocumentsResponse outsiderDocs =
            (PortalDocumentApi.InvestmentDocumentsResponse) JSON.deserialize(
                res.responseBody.toString(), PortalDocumentApi.InvestmentDocumentsResponse.class);
        Assert.areEqual(0, outsiderDocs.documents.size(), 'non-investors see nothing');
    }

    @IsTest
    static void investmentDocumentsNotFoundContactErrors() {
        RestResponse res = invokeGetInvestmentDocuments(new Map<String, String>{ 'contactId' => '003000000000000AAA' });
        Assert.areEqual(404, res.statusCode);
    }
}
