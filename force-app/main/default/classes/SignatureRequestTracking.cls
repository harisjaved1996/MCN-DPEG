/**
 * Tracking layer for the Add Signature Request wizard.
 *
 * Master_Document__c = one send run against an investment (which document,
 * with sent/opened/completed/failed metrics). Document_Copy__c = one
 * recipient copy carrying the DocuSign envelope id and its live status.
 *
 * Status flow: dfsle__EnvelopeStatus__c records (written by the DocuSign
 * package via Connect or by StatusService.getStatus polling) are mirrored
 * onto copies by syncStatuses — invoked from the EnvelopeStatusSync trigger
 * and from the on-demand refresh. Metrics are recalculated after every write.
 */
public with sharing class SignatureRequestTracking {

    public static final String STATUS_SENT = 'Sent';
    public static final String STATUS_FAILED = 'Failed';
    public static final String STATUS_RESET = 'Reset';

    /** Statuses that imply the recipient opened the envelope. */
    private static final Set<String> OPENED_STATUSES = new Set<String>{
        'delivered', 'signed', 'completed', 'declined'
    };

    // ------------------------------------------------------------------
    // creation (called from send pipeline)
    // ------------------------------------------------------------------

    public static Id createMaster(SignatureRequestModels.SendRequest req) {
        Master_Document__c master = new Master_Document__c(
            Name = String.isBlank(req.document.name)
                ? 'Signature Request' : req.document.name.abbreviate(80),
            Investment__c = req.investmentId,
            Source_Type__c = req.document.sourceType,
            Content_Version_Id__c = req.document.contentVersionId == null
                ? null : String.valueOf(req.document.contentVersionId),
            Content_Document_Id__c = req.document.contentDocumentId == null
                ? null : String.valueOf(req.document.contentDocumentId),
            Template_Id__c = req.document.templateId,
            Email_Subject__c = req.emailSubject == null ? null : req.emailSubject.abbreviate(255),
            Request_Payload__c = JSON.serialize(req),
            Sent_Count__c = 0,
            Opened_Count__c = 0,
            Completed_Count__c = 0,
            Failed_Count__c = 0
        );
        insert master;
        return master.Id;
    }

    /**
     * DocuSign web-app deep link base for a sent envelope. Durable (unlike
     * session view URLs) so the investor-portal phase can reuse it; the
     * envelope UUID stored on each copy is the API-side key for embedded
     * signing later. Demo environment host — switch to
     * https://apps.docusign.com/send/documents/details/ for production.
     */
    @TestVisible
    private static String envelopeLinkBase = 'https://apps-d.docusign.com/send/documents/details/';

    /** One copy row PER RECIPIENT of the entity's shared envelope. */
    public static void createCopiesForOutcome(Id masterId, SignatureRequestModels.SendOutcome outcome) {
        List<SignatureRequestModels.RecipientPlan> plans = outcome.recipients;
        if (plans == null || plans.isEmpty()) {
            // Entity failed before its recipients were resolved: one failure row.
            SignatureRequestModels.RecipientPlan placeholder = new SignatureRequestModels.RecipientPlan();
            placeholder.contactId = outcome.contactId;
            placeholder.contactName = outcome.contactName;
            plans = new List<SignatureRequestModels.RecipientPlan>{ placeholder };
        }
        String link = String.isBlank(outcome.docuSignId) ? null : envelopeLinkBase + outcome.docuSignId;

        List<Document_Copy__c> copies = new List<Document_Copy__c>();
        for (SignatureRequestModels.RecipientPlan plan : plans) {
            String copyName = String.isBlank(plan.contactName)
                ? (String.isBlank(outcome.entityName) ? 'Recipient' : outcome.entityName)
                : plan.contactName;
            copies.add(new Document_Copy__c(
                Name = copyName.abbreviate(80),
                Master_Document__c = masterId,
                Contact__c = plan.contactId,
                Investing_Entity__c = outcome.entityId,
                DocuSign_Envelope_Id__c = outcome.docuSignId,
                Envelope_Record_Id__c = outcome.envelopeRecordId,
                Envelope_Link__c = link,
                Status__c = outcome.success ? STATUS_SENT : STATUS_FAILED,
                Sent_At__c = outcome.success ? Datetime.now() : null,
                Error_Message__c = outcome.errorMessage,
                Is_Primary__c = plan.isPrimary == true,
                Is_Required_Signer__c = plan.isRequiredSigner == true,
                Recipient_Role__c = plan.recipientRole,
                Routing_Order__c = plan.routingOrder
            ));
        }
        insert copies;
        recalcMetrics(new Set<Id>{ masterId });
    }

    // ------------------------------------------------------------------
    // status sync
    // ------------------------------------------------------------------

    /** Mirrors dfsle envelope statuses onto matching (non-reset) copies. */
    public static void syncStatuses(List<dfsle__EnvelopeStatus__c> statuses) {
        if (statuses == null || statuses.isEmpty()) {
            return;
        }
        Map<String, dfsle__EnvelopeStatus__c> byEnvelopeId = new Map<String, dfsle__EnvelopeStatus__c>();
        for (dfsle__EnvelopeStatus__c status : statuses) {
            if (String.isNotBlank(status.dfsle__DocuSignId__c)) {
                byEnvelopeId.put(status.dfsle__DocuSignId__c.toLowerCase(), status);
            }
        }
        if (byEnvelopeId.isEmpty()) {
            return;
        }

        List<Document_Copy__c> toUpdate = new List<Document_Copy__c>();
        Set<Id> masterIds = new Set<Id>();
        for (Document_Copy__c copy : [
            SELECT Id, Master_Document__c, DocuSign_Envelope_Id__c, Status__c,
                   Sent_At__c, Opened_At__c, Completed_At__c
            FROM Document_Copy__c
            WHERE DocuSign_Envelope_Id__c IN :byEnvelopeId.keySet()
              AND Status__c != :STATUS_RESET
        ]) {
            dfsle__EnvelopeStatus__c status =
                byEnvelopeId.get(copy.DocuSign_Envelope_Id__c.toLowerCase());
            if (status == null || !applyStatus(copy, status)) {
                continue;
            }
            toUpdate.add(copy);
            masterIds.add(copy.Master_Document__c);
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
            recalcMetrics(masterIds);
        }
    }

    /** Returns true when the copy changed. */
    private static Boolean applyStatus(Document_Copy__c copy, dfsle__EnvelopeStatus__c status) {
        Boolean changed = false;
        String statusLabel = status.dfsle__Status__c;
        String statusLower = statusLabel == null ? '' : statusLabel.toLowerCase();

        if (String.isNotBlank(statusLabel) && copy.Status__c != statusLabel) {
            copy.Status__c = statusLabel;
            changed = true;
        }
        if (status.dfsle__Sent__c != null && copy.Sent_At__c == null) {
            copy.Sent_At__c = status.dfsle__Sent__c;
            changed = true;
        }
        if (copy.Opened_At__c == null && OPENED_STATUSES.contains(statusLower)) {
            copy.Opened_At__c = status.dfsle__LastStatusUpdate__c != null
                ? status.dfsle__LastStatusUpdate__c : Datetime.now();
            changed = true;
        }
        if (status.dfsle__Completed__c != null && copy.Completed_At__c == null) {
            copy.Completed_At__c = status.dfsle__Completed__c;
            if (copy.Opened_At__c == null) {
                copy.Opened_At__c = status.dfsle__Completed__c;
            }
            changed = true;
        }
        return changed;
    }

    public static void recalcMetrics(Set<Id> masterIds) {
        if (masterIds == null || masterIds.isEmpty()) {
            return;
        }
        Map<Id, Master_Document__c> masters = new Map<Id, Master_Document__c>();
        for (Id masterId : masterIds) {
            masters.put(masterId, new Master_Document__c(
                Id = masterId, Sent_Count__c = 0, Opened_Count__c = 0,
                Completed_Count__c = 0, Failed_Count__c = 0));
        }
        for (Document_Copy__c copy : [
            SELECT Master_Document__c, Status__c, Opened_At__c, Completed_At__c
            FROM Document_Copy__c
            WHERE Master_Document__c IN :masterIds
        ]) {
            Master_Document__c master = masters.get(copy.Master_Document__c);
            if (copy.Status__c == STATUS_FAILED) {
                master.Failed_Count__c++;
                continue;
            }
            if (copy.Status__c == STATUS_RESET) {
                continue; // superseded copies do not count
            }
            master.Sent_Count__c++;
            if (copy.Opened_At__c != null) {
                master.Opened_Count__c++;
            }
            if (copy.Completed_At__c != null) {
                master.Completed_Count__c++;
            }
        }
        update masters.values();
    }

    // ------------------------------------------------------------------
    // reads for the LWCs
    // ------------------------------------------------------------------

    public static List<SignatureRequestModels.MasterDocSummary> getMasterDocuments(Id investmentId) {
        List<SignatureRequestModels.MasterDocSummary> result =
            new List<SignatureRequestModels.MasterDocSummary>();
        for (Master_Document__c master : [
            SELECT Id, Name, Source_Type__c, Content_Document_Id__c, Email_Subject__c,
                   Sent_Count__c, Opened_Count__c, Completed_Count__c, Failed_Count__c, CreatedDate
            FROM Master_Document__c
            WHERE Investment__c = :investmentId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ]) {
            SignatureRequestModels.MasterDocSummary dto = new SignatureRequestModels.MasterDocSummary();
            dto.id = master.Id;
            dto.name = master.Name;
            dto.sourceType = master.Source_Type__c;
            dto.contentDocumentId = master.Content_Document_Id__c;
            dto.emailSubject = master.Email_Subject__c;
            dto.sentCount = toInt(master.Sent_Count__c);
            dto.openedCount = toInt(master.Opened_Count__c);
            dto.completedCount = toInt(master.Completed_Count__c);
            dto.failedCount = toInt(master.Failed_Count__c);
            dto.createdDate = master.CreatedDate;
            result.add(dto);
        }
        return result;
    }

    public static List<SignatureRequestModels.CopyRow> getCopies(Id masterDocumentId) {
        List<SignatureRequestModels.CopyRow> rows = new List<SignatureRequestModels.CopyRow>();
        for (Document_Copy__c copy : [
            SELECT Id, Name, Contact__c, Contact__r.Name,
                   Investing_Entity__c, Investing_Entity__r.Name, Investing_Entity__r.Entity_Type__c,
                   DocuSign_Envelope_Id__c, Envelope_Link__c, Status__c, Sent_At__c, Opened_At__c,
                   Completed_At__c, Error_Message__c,
                   Is_Primary__c, Is_Required_Signer__c, Recipient_Role__c, Routing_Order__c
            FROM Document_Copy__c
            WHERE Master_Document__c = :masterDocumentId
            WITH USER_MODE
            ORDER BY Investing_Entity__r.Name, CreatedDate DESC, Routing_Order__c
        ]) {
            SignatureRequestModels.CopyRow row = new SignatureRequestModels.CopyRow();
            row.id = copy.Id;
            row.contactId = copy.Contact__c;
            row.contactName = copy.Contact__r != null ? copy.Contact__r.Name : copy.Name;
            row.entityName = copy.Investing_Entity__r != null ? copy.Investing_Entity__r.Name : null;
            row.entityType = copy.Investing_Entity__r != null
                ? copy.Investing_Entity__r.Entity_Type__c : null;
            row.status = copy.Status__c;
            row.sentAt = copy.Sent_At__c;
            row.openedAt = copy.Opened_At__c;
            row.completedAt = copy.Completed_At__c;
            row.errorMessage = copy.Error_Message__c;
            row.docuSignEnvelopeId = copy.DocuSign_Envelope_Id__c;
            row.envelopeLink = copy.Envelope_Link__c;
            row.isPrimary = copy.Is_Primary__c == true;
            row.isRequiredSigner = copy.Is_Required_Signer__c == true;
            row.recipientRole = copy.Recipient_Role__c;
            row.routingOrder = copy.Routing_Order__c == null ? null : copy.Routing_Order__c.intValue();
            row.resettable = copy.Status__c != STATUS_RESET && copy.Investing_Entity__c != null;
            row.viewable = String.isNotBlank(copy.DocuSign_Envelope_Id__c);
            rows.add(row);
        }
        return rows;
    }

    // ------------------------------------------------------------------
    // actions
    // ------------------------------------------------------------------

    /** DocuSign view URL for a copy's envelope (works for in-flight and completed). */
    public static String getCopyViewUrl(Id copyId) {
        Document_Copy__c copy = loadCopy(copyId);
        if (String.isBlank(copy.DocuSign_Envelope_Id__c)) {
            throw new SignatureRequestService.SignatureRequestException(
                'This copy has no DocuSign envelope to view.');
        }
        String returnUrl = Url.getOrgDomainUrl().toExternalForm() + '/' + copy.Master_Document__c;
        return SignatureRequestService.gateway.getEnvelopeViewUrl(
            copy.DocuSign_Envelope_Id__c, returnUrl);
    }

    /**
     * Resets the ENTIRE entity envelope the clicked copy belongs to: voids
     * the shared envelope (when still voidable), marks every sibling copy of
     * that entity Reset (they stop counting toward metrics), and queues a
     * fresh envelope for the whole entity from the master's stored payload —
     * same recipients, same routing.
     */
    public static SignatureRequestModels.SendReceipt resetAndResend(Id copyId) {
        Document_Copy__c copy = loadCopy(copyId);
        if (copy.Status__c == STATUS_RESET) {
            throw new SignatureRequestService.SignatureRequestException(
                'This copy was already reset.');
        }
        if (copy.Investing_Entity__c == null) {
            throw new SignatureRequestService.SignatureRequestException(
                'This copy predates the entity-envelope model and cannot be resent; send a new request instead.');
        }
        if (String.isBlank(copy.Master_Document__r.Request_Payload__c)) {
            throw new SignatureRequestService.SignatureRequestException(
                'The original request payload was not stored, so this document cannot be resent.');
        }

        SignatureRequestModels.SendRequest req;
        try {
            req = (SignatureRequestModels.SendRequest) JSON.deserialize(
                copy.Master_Document__r.Request_Payload__c,
                SignatureRequestModels.SendRequest.class);
        } catch (Exception e) {
            throw new SignatureRequestService.SignatureRequestException(
                'Stored request payload could not be read: ' + e.getMessage());
        }
        if (req.selectedAssociationIds == null || req.selectedAssociationIds.isEmpty()) {
            throw new SignatureRequestService.SignatureRequestException(
                'This master was sent before the entity-envelope model; send a new request instead.');
        }

        // Void first (callout before any DML). Completed/declined/voided
        // envelopes cannot be voided — skip silently and just supersede.
        String statusLower = copy.Status__c == null ? '' : copy.Status__c.toLowerCase();
        String voidNote = '';
        Boolean voidable = String.isNotBlank(copy.DocuSign_Envelope_Id__c)
            && statusLower != 'completed' && statusLower != 'declined'
            && statusLower != 'voided' && statusLower != STATUS_FAILED.toLowerCase();
        if (voidable) {
            try {
                SignatureRequestService.gateway.voidEnvelope(
                    copy.DocuSign_Envelope_Id__c,
                    'Reset by sender to correct and resend.');
            } catch (Exception e) {
                voidNote = ' (void failed: ' + e.getMessage() + ')';
            }
        }

        // Supersede every active copy of this entity's envelope on this master.
        List<Document_Copy__c> siblings = [
            SELECT Id, Status__c, Error_Message__c
            FROM Document_Copy__c
            WHERE Master_Document__c = :copy.Master_Document__c
              AND Investing_Entity__c = :copy.Investing_Entity__c
              AND Status__c != :STATUS_RESET
        ];
        for (Document_Copy__c sibling : siblings) {
            sibling.Status__c = STATUS_RESET;
            sibling.Error_Message__c = ('Reset on ' + Datetime.now().format() + voidNote
                + (sibling.Error_Message__c == null ? '' : '\n' + sibling.Error_Message__c))
                .abbreviate(32768);
        }
        update siblings;

        req.masterDocumentId = copy.Master_Document__c;

        SignatureRequestModels.SendReceipt receipt = new SignatureRequestModels.SendReceipt();
        receipt.plannedCount = 1;
        receipt.masterDocumentId = copy.Master_Document__c;
        receipt.asyncJobId = System.enqueueJob(
            new SignatureRequestSender(req, new List<Id>{ copy.Investing_Entity__c }));

        recalcMetrics(new Set<Id>{ copy.Master_Document__c });
        return receipt;
    }

    private static Document_Copy__c loadCopy(Id copyId) {
        List<Document_Copy__c> copies = [
            SELECT Id, Name, Master_Document__c, Master_Document__r.Request_Payload__c,
                   Contact__c, Investing_Entity__c, DocuSign_Envelope_Id__c, Status__c, Error_Message__c
            FROM Document_Copy__c
            WHERE Id = :copyId
            LIMIT 1
        ];
        if (copies.isEmpty()) {
            throw new SignatureRequestService.SignatureRequestException('Document copy not found.');
        }
        return copies[0];
    }

    private static Integer toInt(Decimal value) {
        return value == null ? 0 : value.intValue();
    }
}
