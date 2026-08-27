/**
 * REST API for the investor web portal.
 *
 * GET  /services/apexrest/portal/v1/documents?contactId=003...   (or ?email=...)
 *     -> signature documents (Document_Copy__c rows) for one investor contact,
 *        with a computed "waitingOnName" so the portal knows whose turn it is.
 *
 * GET  /services/apexrest/portal/v1/investment-documents?contactId=003...
 *     -> general files (Salesforce Files / Notes & Attachments) uploaded directly
 *        on any Investment__c the contact holds a position in — e.g. back-office
 *        drops a PPM or statement on the Investment record and every investor in
 *        that investment can see it in the portal. Not tied to DocuSign at all.
 *
 * POST /services/apexrest/portal/v1/refresh   body: {"masterDocumentId":"a4Q..."}
 *     -> polls DocuSign for the master's investment and syncs copy statuses;
 *        called by the portal right after a signing ceremony completes.
 */
@RestResource(urlMapping='/portal/v1/*')
global with sharing class PortalDocumentApi {

    private static final Set<String> DONE_STATUSES = new Set<String>{ 'signed', 'completed' };

    global class InvestmentDocument {
        public String contentDocumentId;
        public String contentVersionId;
        public String title;
        public String fileType;
        public String fileExtension;
        public Integer contentSize;
        public String description;
        public String investmentId;
        public String investmentName;
        public Datetime uploadedDate;
    }

    global class InvestmentDocumentsResponse {
        public String contactId;
        public String contactName;
        public List<InvestmentDocument> documents = new List<InvestmentDocument>();
    }

    global class PortalDocument {
        public String copyId;
        public String documentName;
        public String masterDocumentId;
        public String investmentName;
        public String envelopeId;
        public String envelopeLink;
        public String status;
        public Datetime sentAt;
        public Datetime completedAt;
        public Boolean isPrimary;
        public Boolean isRequiredSigner;
        public Integer routingOrder;
        public String entityName;
        public String waitingOnName;
    }

    global class DocumentsResponse {
        public String contactId;
        public String contactName;
        public List<PortalDocument> documents = new List<PortalDocument>();
    }

    @HttpGet
    global static void doGet() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        try {
            String action = resolveAction();
            if (action == 'documents') {
                Id contactId = resolveContactId();
                res.statusCode = 200;
                res.responseBody = Blob.valueOf(JSON.serialize(buildDocuments(contactId)));
            } else if (action == 'investment-documents') {
                Id contactId = resolveContactId();
                res.statusCode = 200;
                res.responseBody = Blob.valueOf(JSON.serialize(buildInvestmentDocuments(contactId)));
            } else {
                fail(res, 404, 'Unknown resource. Use /portal/v1/documents or /portal/v1/investment-documents.');
            }
        } catch (PortalApiException e) {
            fail(res, e.statusCode, e.getMessage());
        } catch (Exception e) {
            fail(res, 500, e.getMessage());
        }
    }

    @HttpPost
    global static void doPost() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        try {
            String action = resolveAction();
            if (action != 'refresh') {
                fail(res, 404, 'Unknown resource. Use /portal/v1/refresh.');
                return;
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody == null ? '{}' : RestContext.request.requestBody.toString());
            String masterId = (String) body.get('masterDocumentId');
            if (String.isBlank(masterId)) {
                throw new PortalApiException(400, 'masterDocumentId is required.');
            }
            List<SignatureRequestModels.CopyRow> rows = refreshMaster(Id.valueOf(masterId));
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'masterDocumentId' => masterId,
                'copies' => rows
            }));
        } catch (PortalApiException e) {
            fail(res, e.statusCode, e.getMessage());
        } catch (Exception e) {
            fail(res, 500, e.getMessage());
        }
    }

    // ----- GET: documents ---------------------------------------------------

    @TestVisible
    private static DocumentsResponse buildDocuments(Id contactId) {
        List<Contact> contacts = [
            SELECT Id, Name FROM Contact WHERE Id = :contactId WITH USER_MODE LIMIT 1
        ];
        if (contacts.isEmpty()) {
            throw new PortalApiException(404, 'Contact not found.');
        }

        DocumentsResponse result = new DocumentsResponse();
        result.contactId = contacts[0].Id;
        result.contactName = contacts[0].Name;

        List<Document_Copy__c> copies = [
            SELECT Id, Contact__c, Master_Document__c, Master_Document__r.Name,
                   Master_Document__r.Investment__r.Name,
                   DocuSign_Envelope_Id__c, Envelope_Link__c, Status__c,
                   Sent_At__c, Completed_At__c, Is_Primary__c, Is_Required_Signer__c,
                   Routing_Order__c, Investing_Entity__r.Name
            FROM Document_Copy__c
            WHERE Contact__c = :contactId
              AND Status__c != :SignatureRequestTracking.STATUS_RESET
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ];

        Set<String> envelopeIds = new Set<String>();
        for (Document_Copy__c copy : copies) {
            if (String.isNotBlank(copy.DocuSign_Envelope_Id__c)) {
                envelopeIds.add(copy.DocuSign_Envelope_Id__c.toLowerCase());
            }
        }

        // Siblings on the same envelopes tell us whose turn it currently is.
        Map<String, List<Document_Copy__c>> siblingsByEnvelope = new Map<String, List<Document_Copy__c>>();
        if (!envelopeIds.isEmpty()) {
            for (Document_Copy__c sibling : [
                SELECT Contact__c, Contact__r.Name, DocuSign_Envelope_Id__c,
                       Status__c, Routing_Order__c
                FROM Document_Copy__c
                WHERE DocuSign_Envelope_Id__c IN :envelopeIds
                  AND Status__c != :SignatureRequestTracking.STATUS_RESET
                WITH USER_MODE
            ]) {
                String key = sibling.DocuSign_Envelope_Id__c == null
                    ? '' : sibling.DocuSign_Envelope_Id__c.toLowerCase();
                if (!siblingsByEnvelope.containsKey(key)) {
                    siblingsByEnvelope.put(key, new List<Document_Copy__c>());
                }
                siblingsByEnvelope.get(key).add(sibling);
            }
        }

        for (Document_Copy__c copy : copies) {
            PortalDocument doc = new PortalDocument();
            doc.copyId = copy.Id;
            doc.documentName = copy.Master_Document__r.Name;
            doc.masterDocumentId = copy.Master_Document__c;
            doc.investmentName = copy.Master_Document__r.Investment__r != null
                ? copy.Master_Document__r.Investment__r.Name : null;
            doc.envelopeId = copy.DocuSign_Envelope_Id__c;
            doc.envelopeLink = copy.Envelope_Link__c;
            doc.status = copy.Status__c;
            doc.sentAt = copy.Sent_At__c;
            doc.completedAt = copy.Completed_At__c;
            doc.isPrimary = copy.Is_Primary__c == true;
            doc.isRequiredSigner = copy.Is_Required_Signer__c == true;
            doc.routingOrder = copy.Routing_Order__c == null ? null : (Integer) copy.Routing_Order__c;
            doc.entityName = copy.Investing_Entity__r != null ? copy.Investing_Entity__r.Name : null;
            doc.waitingOnName = waitingOn(copy, siblingsByEnvelope);
            result.documents.add(doc);
        }
        return result;
    }

    /**
     * Name of an earlier-routing signer who has not finished yet — meaning
     * this copy's recipient cannot sign until that person does. Null when it
     * is this recipient's turn (or the row itself is already done/failed).
     */
    private static String waitingOn(
        Document_Copy__c copy, Map<String, List<Document_Copy__c>> siblingsByEnvelope
    ) {
        if (copy.DocuSign_Envelope_Id__c == null || copy.Routing_Order__c == null) {
            return null;
        }
        String statusLower = copy.Status__c == null ? '' : copy.Status__c.toLowerCase();
        if (DONE_STATUSES.contains(statusLower) || statusLower == 'failed'
            || statusLower == 'declined' || statusLower == 'voided') {
            return null;
        }
        List<Document_Copy__c> siblings =
            siblingsByEnvelope.get(copy.DocuSign_Envelope_Id__c.toLowerCase());
        if (siblings == null) {
            return null;
        }
        for (Document_Copy__c sibling : siblings) {
            if (sibling.Contact__c == copy.Contact__c
                || sibling.Routing_Order__c == null
                || sibling.Routing_Order__c >= copy.Routing_Order__c) {
                continue;
            }
            String siblingStatus = sibling.Status__c == null ? '' : sibling.Status__c.toLowerCase();
            if (!DONE_STATUSES.contains(siblingStatus)) {
                return sibling.Contact__r != null ? sibling.Contact__r.Name : 'another signer';
            }
        }
        return null;
    }

    // ----- GET: investment-documents -----------------------------------------

    /**
     * Files uploaded directly on any Investment__c the contact is an investor
     * in (via Associated_Contact__c -> Investing_Entity__c -> position__c),
     * regardless of who uploaded them or whether DocuSign is involved at all.
     */
    @TestVisible
    private static InvestmentDocumentsResponse buildInvestmentDocuments(Id contactId) {
        List<Contact> contacts = [
            SELECT Id, Name FROM Contact WHERE Id = :contactId WITH USER_MODE LIMIT 1
        ];
        if (contacts.isEmpty()) {
            throw new PortalApiException(404, 'Contact not found.');
        }

        InvestmentDocumentsResponse result = new InvestmentDocumentsResponse();
        result.contactId = contacts[0].Id;
        result.contactName = contacts[0].Name;

        Set<Id> entityIds = new Set<Id>();
        for (Associated_Contact__c assoc : [
            SELECT Investing_Entity__c FROM Associated_Contact__c
            WHERE Contact__c = :contactId AND Investing_Entity__c != NULL
            WITH USER_MODE
        ]) {
            entityIds.add(assoc.Investing_Entity__c);
        }
        if (entityIds.isEmpty()) {
            return result;
        }

        Map<Id, Investment__c> investmentsById = new Map<Id, Investment__c>();
        for (position__c pos : [
            SELECT Investment__c, Investment__r.Name FROM position__c
            WHERE Investing_Entity__c IN :entityIds AND Investment__c != NULL
            WITH USER_MODE
        ]) {
            if (!investmentsById.containsKey(pos.Investment__c)) {
                investmentsById.put(pos.Investment__c, pos.Investment__r);
            }
        }
        if (investmentsById.isEmpty()) {
            return result;
        }

        for (ContentDocumentLink link : [
            SELECT LinkedEntityId,
                   ContentDocument.Id, ContentDocument.Title, ContentDocument.FileType,
                   ContentDocument.FileExtension, ContentDocument.ContentSize,
                   ContentDocument.Description, ContentDocument.LatestPublishedVersionId,
                   ContentDocument.CreatedDate
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :investmentsById.keySet()
            WITH USER_MODE
            ORDER BY ContentDocument.CreatedDate DESC
        ]) {
            InvestmentDocument doc = new InvestmentDocument();
            doc.contentDocumentId = link.ContentDocument.Id;
            doc.contentVersionId = link.ContentDocument.LatestPublishedVersionId;
            doc.title = link.ContentDocument.Title;
            doc.fileType = link.ContentDocument.FileType;
            doc.fileExtension = link.ContentDocument.FileExtension;
            doc.contentSize = link.ContentDocument.ContentSize;
            doc.description = link.ContentDocument.Description;
            doc.investmentId = link.LinkedEntityId;
            Investment__c inv = investmentsById.get(link.LinkedEntityId);
            doc.investmentName = inv != null ? inv.Name : null;
            doc.uploadedDate = link.ContentDocument.CreatedDate;
            result.documents.add(doc);
        }
        return result;
    }

    private static Id resolveContactId() {
        Map<String, String> params = RestContext.request.params;
        String contactIdParam = params.get('contactId');
        if (String.isNotBlank(contactIdParam)) {
            try {
                return Id.valueOf(contactIdParam);
            } catch (Exception e) {
                throw new PortalApiException(400, 'Invalid contactId.');
            }
        }
        String email = params.get('email');
        if (String.isBlank(email)) {
            throw new PortalApiException(400, 'Pass contactId or email.');
        }
        List<Contact> matches = [
            SELECT Id FROM Contact WHERE Email = :email WITH USER_MODE LIMIT 1
        ];
        if (matches.isEmpty()) {
            throw new PortalApiException(404, 'No contact with that email.');
        }
        return matches[0].Id;
    }

    // ----- POST: refresh ----------------------------------------------------

    @TestVisible
    private static List<SignatureRequestModels.CopyRow> refreshMaster(Id masterDocumentId) {
        List<Master_Document__c> masters = [
            SELECT Id, Investment__c FROM Master_Document__c
            WHERE Id = :masterDocumentId WITH USER_MODE LIMIT 1
        ];
        if (masters.isEmpty()) {
            throw new PortalApiException(404, 'Master document not found.');
        }
        Id investmentId = masters[0].Investment__c;
        try {
            SignatureRequestService.gateway.pollStatuses(investmentId, 200);
        } catch (Exception pollError) {
            // Poll failures should not hide the statuses we already have.
            System.debug(LoggingLevel.WARN, 'Status poll failed: ' + pollError.getMessage());
        }
        SignatureRequestTracking.syncStatuses([
            SELECT Id, dfsle__DocuSignId__c, dfsle__Status__c, dfsle__Sent__c,
                   dfsle__Completed__c, dfsle__LastStatusUpdate__c
            FROM dfsle__EnvelopeStatus__c
            WHERE dfsle__SourceId__c = :String.valueOf(investmentId)
               OR dfsle__SourceId__c = :String.valueOf(investmentId).left(15)
        ]);
        return SignatureRequestTracking.getCopies(masterDocumentId);
    }

    // ----- plumbing ---------------------------------------------------------

    private static String resolveAction() {
        String uri = RestContext.request.requestURI;
        Integer marker = uri.indexOf('/portal/v1/');
        return marker == -1 ? '' : uri.substring(marker + '/portal/v1/'.length()).toLowerCase();
    }

    private static void fail(RestResponse res, Integer statusCode, String message) {
        res.statusCode = statusCode;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'error' => message }));
    }

    private class PortalApiException extends Exception {
        public Integer statusCode;
        private PortalApiException(Integer statusCode, String message) {
            this(message);
            this.statusCode = statusCode;
        }
    }
}
