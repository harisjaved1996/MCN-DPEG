/**
 * DTOs for the "Add Signature Request" wizard (addSignatureRequest LWC).
 *
 * Inbound shapes (SendRequest and children) are deserialized from the single
 * JSON string the LWC posts; outbound shapes carry @AuraEnabled members.
 * Coordinates on PlacedField are PDF points (72dpi, top-left origin, 1-based
 * page) — the LWC converts from canvas pixels before posting.
 */
public with sharing class SignatureRequestModels {

    // ---------- inbound (LWC -> Apex, via JSON.deserialize) ----------

    public class SendRequest {
        public Id investmentId;
        public String emailSubject;
        public String emailMessage;
        public DocumentSelection document;
        public List<PlacedField> fields;
        public List<Id> selectedContactIds;
        public Id masterDocumentId; // tracking record copies attach to (set server-side)
    }

    public class DocumentSelection {
        public String sourceType;       // FILE | TEMPLATE
        public Id contentVersionId;     // FILE only
        public Id contentDocumentId;    // FILE only
        public String templateId;       // TEMPLATE only (DocuSign UUID string)
        public String name;
    }

    public class PlacedField {
        public String clientId;         // unique per placed field; reused as the DocuSign dataLabel
        public String category;         // MERGE | ENTRY | RECIPIENT
        public String objectApiName;    // MERGE only
        public String fieldApiName;     // MERGE only
        public String entryKind;        // ENTRY only: REQUIRED_TEXT | OPTIONAL_TEXT | CHECKBOX
        public String recipientKind;    // RECIPIENT only: SIGNATURE | DATE_SIGNED | FULL_NAME | EMAIL
        public String label;
        public List<String> entityTypes; // MERGE only; empty/null = visible to all entity types
        public Integer page;            // 1-based
        public Decimal x;               // PDF points from page top-left
        public Decimal y;
        public Decimal width;           // nullable -> DocuSign default
        public Decimal height;
    }

    // ---------- intermediate (assertable tab plan, no dfsle types) ----------

    public class TabSpec {
        public String kind;             // TEXT | CHECKBOX | SIGN_HERE | DATE_SIGNED | FULL_NAME | EMAIL
        public String dataLabel;
        public String value;            // TEXT merge values only
        public Boolean readOnly = false;
        public Boolean required = false;
        public Integer page;
        public Integer x;
        public Integer y;
        public Integer width;
        public Integer height;
    }

    // ---------- outbound (Apex -> LWC) ----------

    public class FileDoc {
        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public String title;
        @AuraEnabled public String extension;
        @AuraEnabled public Integer sizeKb;
        @AuraEnabled public Datetime lastModified;
    }

    public class TemplateDoc {
        @AuraEnabled public String templateId;
        @AuraEnabled public String name;
        @AuraEnabled public String emailSubject;
    }

    public class MergeGroup {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public List<MergeFieldDef> fields = new List<MergeFieldDef>();
    }

    public class MergeFieldDef {
        @AuraEnabled public String fieldApiName;
        @AuraEnabled public String label;
        @AuraEnabled public String type;
    }

    public class Prospect {
        @AuraEnabled public Id contactId;
        @AuraEnabled public String name;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
        @AuraEnabled public Id entityId;
        @AuraEnabled public String entityName;
        @AuraEnabled public String entityType;
        @AuraEnabled public Id positionId;
    }

    public class ProspectResult {
        @AuraEnabled public String investmentName;
        @AuraEnabled public List<Prospect> prospects = new List<Prospect>();
        @AuraEnabled public Integer skippedNoEmailCount = 0;
    }

    public class SendReceipt {
        @AuraEnabled public Id asyncJobId;
        @AuraEnabled public Integer plannedCount;
        @AuraEnabled public Id masterDocumentId;
    }

    public class MasterDocSummary {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String sourceType;
        @AuraEnabled public String contentDocumentId;
        @AuraEnabled public String emailSubject;
        @AuraEnabled public Integer sentCount;
        @AuraEnabled public Integer openedCount;
        @AuraEnabled public Integer completedCount;
        @AuraEnabled public Integer failedCount;
        @AuraEnabled public Datetime createdDate;
    }

    public class CopyRow {
        @AuraEnabled public Id id;
        @AuraEnabled public Id contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String entityName;
        @AuraEnabled public String entityType;
        @AuraEnabled public String status;
        @AuraEnabled public Datetime sentAt;
        @AuraEnabled public Datetime openedAt;
        @AuraEnabled public Datetime completedAt;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String docuSignEnvelopeId;
        @AuraEnabled public Boolean resettable;
        @AuraEnabled public Boolean viewable;
    }

    // ---------- queueable chain state ----------

    public class SendOutcome {
        public Id contactId;
        public String contactName;
        public Id entityId;
        public Boolean success = false;
        public String docuSignId;
        public String envelopeRecordId;
        public String errorMessage;
    }
}
