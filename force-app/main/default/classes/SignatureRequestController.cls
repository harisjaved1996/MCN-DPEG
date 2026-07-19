/**
 * @AuraEnabled facade for the "Add Signature Request" wizard
 * (addSignatureRequest LWC on the Investment__c record page).
 *
 * Thin by design: parsing/validation/tab logic lives in
 * SignatureRequestService; async sending in SignatureRequestSender.
 */
public with sharing class SignatureRequestController {

    /** Max bytes for the Apex base64 preview fallback (heap-safe for sync Aura). */
    @TestVisible
    private static Integer MAX_PREVIEW_BYTES = 2000000;

    /** Merge-field palette: fields of Investment/position/Investing Entity/Contact. */
    @AuraEnabled(cacheable=true)
    public static List<SignatureRequestModels.MergeGroup> getMergeFields() {
        try {
            return SignatureRequestService.getMergeGroups();
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    /** PDF files linked to the investment record (latest versions). */
    @AuraEnabled
    public static List<SignatureRequestModels.FileDoc> getFiles(Id recordId) {
        try {
            Set<Id> documentIds = new Set<Id>();
            for (ContentDocumentLink link : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :recordId
                WITH USER_MODE
            ]) {
                documentIds.add(link.ContentDocumentId);
            }
            List<SignatureRequestModels.FileDoc> docs = new List<SignatureRequestModels.FileDoc>();
            if (documentIds.isEmpty()) {
                return docs;
            }
            for (ContentVersion version : [
                SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize, LastModifiedDate
                FROM ContentVersion
                WHERE ContentDocumentId IN :documentIds
                  AND IsLatest = TRUE
                  AND FileExtension = 'pdf'
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
            ]) {
                SignatureRequestModels.FileDoc doc = new SignatureRequestModels.FileDoc();
                doc.contentVersionId = version.Id;
                doc.contentDocumentId = version.ContentDocumentId;
                doc.title = version.Title;
                doc.extension = version.FileExtension;
                doc.sizeKb = version.ContentSize == null ? 0 : (Integer) Math.round(version.ContentSize / 1024.0);
                doc.lastModified = version.LastModifiedDate;
                docs.add(doc);
            }
            return docs;
        } catch (Exception e) {
            throw auraError('Could not load files: ' + e.getMessage());
        }
    }

    /** DocuSign account templates (callout via the dfsle Apex Toolkit). */
    @AuraEnabled
    public static List<SignatureRequestModels.TemplateDoc> getTemplates() {
        try {
            return SignatureRequestService.mapTemplates(SignatureRequestService.gateway.getTemplates());
        } catch (Exception e) {
            throw auraError('Could not load DocuSign templates. Confirm your DocuSign account is '
                + 'connected (Setup > DocuSign Setup) and you have the DocuSign Sender permission set. '
                + 'Details: ' + e.getMessage());
        }
    }

    /**
     * Base64 preview fallback for small PDFs. The LWC first tries the
     * same-origin file download servlet; this path exists for orgs/files
     * where that fetch is unavailable.
     */
    @AuraEnabled
    public static String getDocumentPreview(Id contentVersionId) {
        try {
            List<ContentVersion> versions = [
                SELECT Id, FileExtension, ContentSize, VersionData
                FROM ContentVersion
                WHERE Id = :contentVersionId
                WITH USER_MODE
                LIMIT 1
            ];
            if (versions.isEmpty()) {
                throw auraError('The selected file is no longer available.');
            }
            ContentVersion version = versions[0];
            if (version.FileExtension != 'pdf') {
                throw auraError('Only PDF files can be previewed.');
            }
            if (version.ContentSize > MAX_PREVIEW_BYTES) {
                throw auraError('This PDF is too large to preview inline (over '
                    + (MAX_PREVIEW_BYTES / 1000000) + ' MB). Compress it or use a DocuSign template.');
            }
            return EncodingUtil.base64Encode(version.VersionData);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError('Could not load the document preview: ' + e.getMessage());
        }
    }

    /** Investor contacts of this investment (deduped; most recent position wins). */
    @AuraEnabled
    public static SignatureRequestModels.ProspectResult getProspects(Id recordId) {
        try {
            return SignatureRequestService.loadProspects(recordId);
        } catch (Exception e) {
            throw auraError('Could not load prospects: ' + e.getMessage());
        }
    }

    /** Validates the wizard payload and queues ONE shared envelope per investing entity. */
    @AuraEnabled
    public static SignatureRequestModels.SendReceipt send(String requestJson) {
        try {
            SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(requestJson);

            Map<Id, SignatureRequestService.EntityRecipientGroup> groups =
                SignatureRequestService.loadRecipientGroups(req);
            List<Id> sendableEntityIds = new List<Id>();
            List<String> warnings = new List<String>();
            for (SignatureRequestService.EntityRecipientGroup grp : groups.values()) {
                if (grp.primary == null) {
                    warnings.add('Skipped ' + grp.entityName
                        + ': its primary investor is not selected (the primary fills the input fields).');
                } else {
                    sendableEntityIds.add(grp.entityId);
                }
            }
            if (sendableEntityIds.isEmpty()) {
                throw auraError('Nothing to send: no investing entity has its primary investor selected.');
            }

            // Tracking master first: copies attach to it as each envelope sends.
            req.masterDocumentId = SignatureRequestTracking.createMaster(req);

            SignatureRequestModels.SendReceipt receipt = new SignatureRequestModels.SendReceipt();
            receipt.plannedCount = sendableEntityIds.size();
            receipt.masterDocumentId = req.masterDocumentId;
            receipt.warnings = warnings;
            receipt.asyncJobId = System.enqueueJob(new SignatureRequestSender(req, sendableEntityIds));
            return receipt;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    /**
     * Verification utility: creates a DRAFT envelope for the first selected
     * contact and returns the DocuSign sender-view URL so tab placement can
     * be audited before a real send. Call from anonymous Apex or a console.
     */
    @AuraEnabled
    public static String createPreviewEnvelope(String requestJson) {
        try {
            SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(requestJson);
            Map<Id, SignatureRequestService.EntityRecipientGroup> groups =
                SignatureRequestService.loadRecipientGroups(req);
            SignatureRequestService.EntityRecipientGroup grp;
            for (SignatureRequestService.EntityRecipientGroup candidate : groups.values()) {
                if (candidate.primary != null) {
                    grp = candidate;
                    break;
                }
            }
            if (grp == null) {
                throw auraError('No investing entity with a selected primary investor to preview.');
            }
            SignatureRequestService.ProspectContext ctx = SignatureRequestService.loadEntityContexts(
                req, new Map<Id, SignatureRequestService.EntityRecipientGroup>{ grp.entityId => grp })
                .get(grp.entityId);
            if (ctx == null) {
                throw auraError('The entity no longer holds a position on this investment.');
            }
            String templateRole = req.document.sourceType == 'TEMPLATE'
                ? SignatureRequestService.resolveTemplateRole(req.document.templateId)
                : null;
            dfsle.Envelope draft = SignatureRequestService.gateway.saveDraft(
                SignatureRequestService.buildEntityEnvelope(req, ctx, grp, templateRole));
            String docuSignId = SignatureRequestService.readDocuSignId(draft);
            if (String.isBlank(docuSignId)) {
                throw auraError('Draft envelope was created but its DocuSign id could not be read.');
            }
            String returnUrl = Url.getOrgDomainUrl().toExternalForm() + '/' + req.investmentId;
            return SignatureRequestService.gateway.getSenderViewUrl(docuSignId, returnUrl);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // master document tracking
    // ------------------------------------------------------------------

    /** Master documents (send runs) of an investment, newest first. */
    @AuraEnabled
    public static List<SignatureRequestModels.MasterDocSummary> getMasterDocuments(Id recordId) {
        try {
            return SignatureRequestTracking.getMasterDocuments(recordId);
        } catch (Exception e) {
            throw auraError('Could not load master documents: ' + e.getMessage());
        }
    }

    /** Recipient copies of a master document with their DocuSign statuses. */
    @AuraEnabled
    public static List<SignatureRequestModels.CopyRow> getCopies(Id masterDocumentId) {
        try {
            return SignatureRequestTracking.getCopies(masterDocumentId);
        } catch (Exception e) {
            throw auraError('Could not load copies: ' + e.getMessage());
        }
    }

    /**
     * Polls DocuSign for current envelope statuses of this master's
     * investment (dfsle.StatusService), syncs them onto the copies, and
     * returns the refreshed rows.
     */
    @AuraEnabled
    public static List<SignatureRequestModels.CopyRow> refreshStatuses(Id masterDocumentId) {
        try {
            List<Master_Document__c> masters = [
                SELECT Id, Investment__c FROM Master_Document__c
                WHERE Id = :masterDocumentId WITH USER_MODE LIMIT 1
            ];
            if (masters.isEmpty()) {
                throw auraError('Master document not found.');
            }
            Id investmentId = masters[0].Investment__c;
            try {
                SignatureRequestService.gateway.pollStatuses(investmentId, 200);
            } catch (Exception pollError) {
                // Poll failures should not hide the data we already have.
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
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError('Could not refresh statuses: ' + e.getMessage());
        }
    }

    /** DocuSign view URL for a copy's envelope (in-flight or completed). */
    @AuraEnabled
    public static String getCopyViewUrl(Id copyId) {
        try {
            return SignatureRequestTracking.getCopyViewUrl(copyId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError('Could not open the document in DocuSign: ' + e.getMessage());
        }
    }

    /** Voids (when possible) and re-sends a copy to the same contact. */
    @AuraEnabled
    public static SignatureRequestModels.SendReceipt resetAndResend(Id copyId) {
        try {
            return SignatureRequestTracking.resetAndResend(copyId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw auraError('Reset failed: ' + e.getMessage());
        }
    }

    /** AuraHandledException whose message survives to the client and to tests. */
    private static AuraHandledException auraError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
