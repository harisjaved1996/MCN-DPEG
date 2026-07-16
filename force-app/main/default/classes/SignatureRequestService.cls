/**
 * Core logic for the "Add Signature Request" wizard.
 *
 * Everything DocuSign goes through the dfsle Apex Toolkit behind the
 * EnvelopeGateway seam (dfsle statics cannot be mocked, so tests inject a
 * fake gateway). Tab planning is done on assertable TabSpec DTOs first and
 * only mapped to dfsle.Tab objects at the very end.
 *
 * Coordinates arriving from the LWC are PDF points (72dpi, top-left origin),
 * the same unit and origin DocuSign uses for absolute tab positioning.
 */
public with sharing class SignatureRequestService {

    public class SignatureRequestException extends Exception {}

    /** Objects whose fields may be offered/used as merge fields. */
    public static final List<String> MERGE_OBJECTS = new List<String>{
        'Investment__c', 'position__c', 'Investing_Entity__c', 'Contact'
    };

    /** Field types that make sense as document merge values. */
    private static final Set<Schema.DisplayType> ALLOWED_TYPES = new Set<Schema.DisplayType>{
        Schema.DisplayType.STRING, Schema.DisplayType.TEXTAREA, Schema.DisplayType.PICKLIST,
        Schema.DisplayType.MULTIPICKLIST, Schema.DisplayType.CURRENCY, Schema.DisplayType.DOUBLE,
        Schema.DisplayType.INTEGER, Schema.DisplayType.LONG, Schema.DisplayType.PERCENT,
        Schema.DisplayType.DATE, Schema.DisplayType.DATETIME, Schema.DisplayType.EMAIL,
        Schema.DisplayType.PHONE, Schema.DisplayType.URL, Schema.DisplayType.BOOLEAN
    };

    /** Noise fields excluded from the merge palette. */
    private static final Set<String> DENY_FIELDS = new Set<String>{
        'isdeleted', 'systemmodstamp', 'lastactivitydate', 'lastvieweddate',
        'lastreferenceddate', 'currencyisocode', 'islocked', 'mayedit',
        'jigsaw', 'jigsawcontactid', 'cleanstatus', 'photourl', 'isemailbounced',
        'donotcall', 'hasoptedoutofemail', 'hasoptedoutoffax'
    };

    // ------------------------------------------------------------------
    // dfsle gateway seam (tests replace this)
    // ------------------------------------------------------------------

    public interface EnvelopeGateway {
        dfsle.Envelope emptyEnvelope(Id sourceId);
        dfsle.Envelope sendNow(dfsle.Envelope envelope);
        dfsle.Envelope saveDraft(dfsle.Envelope envelope);
        List<dfsle.Template> getTemplates();
        dfsle.Template getTemplate(String templateId);
        String getSenderViewUrl(String docuSignId, String returnUrl);
        String getEnvelopeViewUrl(String docuSignId, String returnUrl);
        Boolean voidEnvelope(String docuSignId, String reason);
        void pollStatuses(Id sourceId, Integer maximumRecords);
    }

    private class DfsleGateway implements EnvelopeGateway {
        public dfsle.Envelope emptyEnvelope(Id sourceId) {
            return dfsle.EnvelopeService.getEmptyEnvelope(new dfsle.Entity(sourceId));
        }
        public dfsle.Envelope sendNow(dfsle.Envelope envelope) {
            return dfsle.EnvelopeService.sendEnvelope(envelope, true);
        }
        public dfsle.Envelope saveDraft(dfsle.Envelope envelope) {
            return dfsle.EnvelopeService.sendEnvelope(envelope, false);
        }
        public List<dfsle.Template> getTemplates() {
            return dfsle.TemplateService.getTemplates();
        }
        public dfsle.Template getTemplate(String templateId) {
            return dfsle.TemplateService.getTemplate(dfsle.UUID.parse(templateId));
        }
        public String getSenderViewUrl(String docuSignId, String returnUrl) {
            // Namespaced static calls cannot be method-chained in Apex.
            Url senderView = dfsle.EnvelopeService.getSenderViewUrl(
                dfsle.UUID.parse(docuSignId), new Url(returnUrl));
            return senderView.toExternalForm();
        }
        public String getEnvelopeViewUrl(String docuSignId, String returnUrl) {
            Url viewUrl = dfsle.StatusService.getViewUrl(
                dfsle.UUID.parse(docuSignId), new Url(returnUrl));
            return viewUrl.toExternalForm();
        }
        public Boolean voidEnvelope(String docuSignId, String reason) {
            return dfsle.StatusService.voidEnvelope(dfsle.UUID.parse(docuSignId), reason);
        }
        public void pollStatuses(Id sourceId, Integer maximumRecords) {
            dfsle.StatusService.getStatus(new Set<Id>{ sourceId }, maximumRecords);
        }
    }

    @TestVisible
    public static EnvelopeGateway gateway = new DfsleGateway();

    // ------------------------------------------------------------------
    // Merge palette
    // ------------------------------------------------------------------

    public static List<SignatureRequestModels.MergeGroup> getMergeGroups() {
        List<SignatureRequestModels.MergeGroup> groups = new List<SignatureRequestModels.MergeGroup>();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        for (String objectName : MERGE_OBJECTS) {
            Schema.SObjectType t = globalDescribe.get(objectName.toLowerCase());
            if (t == null || !t.getDescribe().isAccessible()) {
                continue;
            }
            Schema.DescribeSObjectResult objDescribe = t.getDescribe();
            SignatureRequestModels.MergeGroup grp = new SignatureRequestModels.MergeGroup();
            grp.objectApiName = objDescribe.getName();
            grp.objectLabel = objDescribe.getLabel();

            for (Schema.SObjectField f : objDescribe.fields.getMap().values()) {
                Schema.DescribeFieldResult fd = f.getDescribe();
                if (!fd.isAccessible()
                        || !ALLOWED_TYPES.contains(fd.getType())
                        || DENY_FIELDS.contains(fd.getName().toLowerCase())) {
                    continue;
                }
                SignatureRequestModels.MergeFieldDef def = new SignatureRequestModels.MergeFieldDef();
                def.fieldApiName = fd.getName();
                def.label = fd.getLabel();
                def.type = fd.getType().name();
                grp.fields.add(def);
            }
            groups.add(grp);
        }
        return groups;
    }

    // ------------------------------------------------------------------
    // Prospects (step 3) and per-contact context (send time)
    // ------------------------------------------------------------------

    public class ProspectContext {
        public Id contactId;
        public String contactName;
        public String contactEmail;
        public String contactPhone;
        public String entityType;
        public SObject contactRecord;
        public SObject entityRecord;
        public SObject positionRecord;
        public SObject investmentRecord;
    }

    /** Prospect list for the wizard: one row per contact (most recent position wins). */
    public static SignatureRequestModels.ProspectResult loadProspects(Id investmentId) {
        SignatureRequestModels.ProspectResult result = new SignatureRequestModels.ProspectResult();

        List<Investment__c> investments = [
            SELECT Id, Name FROM Investment__c WHERE Id = :investmentId WITH USER_MODE LIMIT 1
        ];
        if (investments.isEmpty()) {
            throw new SignatureRequestException('Investment record not found or not accessible.');
        }
        result.investmentName = investments[0].Name;

        Set<Id> seenContacts = new Set<Id>();
        for (position__c pos : [
            SELECT Id, CreatedDate,
                   Investing_Entity__c, Investing_Entity__r.Name, Investing_Entity__r.Entity_Type__c,
                   Investing_Entity__r.Contact__c, Investing_Entity__r.Contact__r.Name,
                   Investing_Entity__r.Contact__r.Email, Investing_Entity__r.Contact__r.Phone
            FROM position__c
            WHERE Investment__c = :investmentId
              AND Investing_Entity__c != NULL
              AND Investing_Entity__r.Contact__c != NULL
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ]) {
            Id contactId = (Id) pos.Investing_Entity__r.Contact__c;
            if (seenContacts.contains(contactId)) {
                continue; // most recent position already captured
            }
            seenContacts.add(contactId);

            if (String.isBlank(pos.Investing_Entity__r.Contact__r.Email)) {
                result.skippedNoEmailCount++;
                continue;
            }
            SignatureRequestModels.Prospect p = new SignatureRequestModels.Prospect();
            p.contactId = contactId;
            p.name = pos.Investing_Entity__r.Contact__r.Name;
            p.email = pos.Investing_Entity__r.Contact__r.Email;
            p.phone = pos.Investing_Entity__r.Contact__r.Phone;
            p.entityId = pos.Investing_Entity__c;
            p.entityName = pos.Investing_Entity__r.Name;
            p.entityType = pos.Investing_Entity__r.Entity_Type__c;
            p.positionId = pos.Id;
            result.prospects.add(p);
        }
        return result;
    }

    /**
     * Loads the merge-value context for the given contacts, re-deriving each
     * contact's most recent position/entity on THIS investment. Only
     * describe-validated field names ever enter the dynamic SOQL.
     */
    public static Map<Id, ProspectContext> loadProspectContexts(
            SignatureRequestModels.SendRequest req, Set<Id> contactIds) {

        Map<String, Set<String>> fieldsByObject = collectMergeFields(req.fields);

        // Base fields the wizard always needs.
        addField(fieldsByObject, 'Contact', 'Name');
        addField(fieldsByObject, 'Contact', 'Email');
        addField(fieldsByObject, 'Contact', 'Phone');
        addField(fieldsByObject, 'Investing_Entity__c', 'Name');
        addField(fieldsByObject, 'Investing_Entity__c', 'Entity_Type__c');
        addField(fieldsByObject, 'position__c', 'CreatedDate');
        addField(fieldsByObject, 'Investment__c', 'Name');

        // Investment record (shared by all contexts)
        String invQuery = 'SELECT ' + String.join(new List<String>(fieldsByObject.get('investment__c')), ', ')
            + ' FROM Investment__c WHERE Id = :investmentId LIMIT 1';
        List<SObject> invRecords = Database.queryWithBinds(
            invQuery, new Map<String, Object>{ 'investmentId' => req.investmentId }, AccessLevel.USER_MODE);
        if (invRecords.isEmpty()) {
            throw new SignatureRequestException('Investment record not found or not accessible.');
        }
        SObject investment = invRecords[0];

        // Positions with entity + contact relationship fields
        List<String> selectParts = new List<String>{ 'Id', 'Investing_Entity__c', 'Investing_Entity__r.Contact__c' };
        Set<String> seen = new Set<String>{ 'id', 'investing_entity__c', 'investing_entity__r.contact__c' };
        for (String f : fieldsByObject.get('position__c')) {
            addSelect(selectParts, seen, f);
        }
        for (String f : fieldsByObject.get('investing_entity__c')) {
            addSelect(selectParts, seen, 'Investing_Entity__r.' + f);
        }
        for (String f : fieldsByObject.get('contact')) {
            addSelect(selectParts, seen, 'Investing_Entity__r.Contact__r.' + f);
        }
        String posQuery = 'SELECT ' + String.join(selectParts, ', ')
            + ' FROM position__c'
            + ' WHERE Investment__c = :investmentId'
            + ' AND Investing_Entity__c != NULL'
            + ' AND Investing_Entity__r.Contact__c IN :contactIds'
            + ' ORDER BY CreatedDate DESC';
        List<SObject> positions = Database.queryWithBinds(
            posQuery,
            new Map<String, Object>{ 'investmentId' => req.investmentId, 'contactIds' => contactIds },
            AccessLevel.USER_MODE);

        Map<Id, ProspectContext> contexts = new Map<Id, ProspectContext>();
        for (SObject pos : positions) {
            SObject entity = pos.getSObject('Investing_Entity__r');
            SObject contact = entity == null ? null : entity.getSObject('Contact__r');
            if (entity == null || contact == null) {
                continue;
            }
            Id contactId = (Id) contact.get('Id');
            if (contexts.containsKey(contactId)) {
                continue; // most recent position already captured
            }
            ProspectContext ctx = new ProspectContext();
            ctx.contactId = contactId;
            ctx.contactName = (String) contact.get('Name');
            ctx.contactEmail = (String) contact.get('Email');
            ctx.contactPhone = (String) contact.get('Phone');
            ctx.entityType = (String) entity.get('Entity_Type__c');
            ctx.contactRecord = contact;
            ctx.entityRecord = entity;
            ctx.positionRecord = pos;
            ctx.investmentRecord = investment;
            contexts.put(contactId, ctx);
        }
        return contexts;
    }

    // ------------------------------------------------------------------
    // Request parsing / validation
    // ------------------------------------------------------------------

    public static SignatureRequestModels.SendRequest parseAndValidate(String requestJson) {
        SignatureRequestModels.SendRequest req;
        try {
            req = (SignatureRequestModels.SendRequest) JSON.deserialize(
                requestJson, SignatureRequestModels.SendRequest.class);
        } catch (Exception e) {
            throw new SignatureRequestException('Invalid request payload: ' + e.getMessage());
        }
        if (req == null || req.investmentId == null) {
            throw new SignatureRequestException('Missing investment record id.');
        }
        if (req.document == null || String.isBlank(req.document.sourceType)) {
            throw new SignatureRequestException('No master document selected.');
        }
        if (req.document.sourceType != 'FILE' && req.document.sourceType != 'TEMPLATE') {
            throw new SignatureRequestException('Unknown document source: ' + req.document.sourceType);
        }
        if (req.document.sourceType == 'FILE' && req.document.contentVersionId == null) {
            throw new SignatureRequestException('No file selected for the master document.');
        }
        if (req.document.sourceType == 'TEMPLATE' && String.isBlank(req.document.templateId)) {
            throw new SignatureRequestException('No DocuSign template selected.');
        }
        if (req.selectedContactIds == null || req.selectedContactIds.isEmpty()) {
            throw new SignatureRequestException('Select at least one prospect to send to.');
        }
        if (req.fields == null || req.document.sourceType == 'TEMPLATE') {
            req.fields = new List<SignatureRequestModels.PlacedField>(); // template fields come from DocuSign
        }

        Integer counter = 0;
        for (SignatureRequestModels.PlacedField f : req.fields) {
            counter++;
            if (String.isBlank(f.clientId)) {
                f.clientId = 'fld_' + counter;
            }
            if (f.page == null || f.page < 1 || f.x == null || f.y == null || f.x < 0 || f.y < 0) {
                throw new SignatureRequestException('Field "' + f.label + '" has an invalid position.');
            }
            if (f.category == 'MERGE') {
                validateMergeField(f);
            } else if (f.category == 'ENTRY') {
                if (f.entryKind != 'REQUIRED_TEXT' && f.entryKind != 'OPTIONAL_TEXT' && f.entryKind != 'CHECKBOX') {
                    throw new SignatureRequestException('Unknown entry field kind: ' + f.entryKind);
                }
            } else if (f.category == 'RECIPIENT') {
                if (f.recipientKind != 'SIGNATURE' && f.recipientKind != 'DATE_SIGNED'
                        && f.recipientKind != 'FULL_NAME' && f.recipientKind != 'EMAIL') {
                    throw new SignatureRequestException('Unknown recipient field kind: ' + f.recipientKind);
                }
            } else {
                throw new SignatureRequestException('Unknown field category: ' + f.category);
            }
        }
        return req;
    }

    private static void validateMergeField(SignatureRequestModels.PlacedField f) {
        Schema.DescribeFieldResult fd = describeMergeField(f.objectApiName, f.fieldApiName);
        if (fd == null) {
            throw new SignatureRequestException(
                'Merge field ' + f.objectApiName + '.' + f.fieldApiName + ' is not available.');
        }
    }

    /** Returns the describe for a whitelisted, accessible merge field; null otherwise. */
    private static Schema.DescribeFieldResult describeMergeField(String objectApiName, String fieldApiName) {
        if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) {
            return null;
        }
        Boolean whitelisted = false;
        for (String allowed : MERGE_OBJECTS) {
            if (allowed.equalsIgnoreCase(objectApiName)) {
                whitelisted = true;
                break;
            }
        }
        if (!whitelisted) {
            return null;
        }
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectApiName.toLowerCase());
        if (t == null) {
            return null;
        }
        Schema.SObjectField f = t.getDescribe().fields.getMap().get(fieldApiName.toLowerCase());
        if (f == null) {
            return null;
        }
        Schema.DescribeFieldResult fd = f.getDescribe();
        if (!fd.isAccessible() || !ALLOWED_TYPES.contains(fd.getType())) {
            return null;
        }
        return fd;
    }

    private static Map<String, Set<String>> collectMergeFields(List<SignatureRequestModels.PlacedField> fields) {
        Map<String, Set<String>> byObject = new Map<String, Set<String>>();
        for (String objectName : MERGE_OBJECTS) {
            byObject.put(objectName.toLowerCase(), new Set<String>());
        }
        if (fields != null) {
            for (SignatureRequestModels.PlacedField f : fields) {
                if (f.category == 'MERGE') {
                    Schema.DescribeFieldResult fd = describeMergeField(f.objectApiName, f.fieldApiName);
                    if (fd != null) {
                        byObject.get(f.objectApiName.toLowerCase()).add(fd.getName());
                    }
                }
            }
        }
        return byObject;
    }

    private static void addField(Map<String, Set<String>> byObject, String objectName, String fieldName) {
        byObject.get(objectName.toLowerCase()).add(fieldName);
    }

    private static void addSelect(List<String> parts, Set<String> seen, String path) {
        if (!seen.contains(path.toLowerCase())) {
            seen.add(path.toLowerCase());
            parts.add(path);
        }
    }

    // ------------------------------------------------------------------
    // Tab planning
    // ------------------------------------------------------------------

    /**
     * Builds the per-recipient tab plan. The entity-type filter applies to
     * EVERY field category (merge, entry, signature/recipient): a field
     * restricted to certain entity types is skipped for recipients whose
     * investing entity's Entity_Type__c is not selected (a null entity type
     * only ever receives unrestricted fields). This lets a document carry
     * e.g. separate signature blocks per entity type.
     */
    public static List<SignatureRequestModels.TabSpec> buildTabSpecs(
            List<SignatureRequestModels.PlacedField> fields, ProspectContext ctx) {

        List<SignatureRequestModels.TabSpec> specs = new List<SignatureRequestModels.TabSpec>();
        for (SignatureRequestModels.PlacedField f : fields) {
            if (f.entityTypes != null && !f.entityTypes.isEmpty()
                    && (ctx.entityType == null || !f.entityTypes.contains(ctx.entityType))) {
                continue; // filtered out for this recipient
            }

            SignatureRequestModels.TabSpec spec = new SignatureRequestModels.TabSpec();
            spec.dataLabel = f.clientId; // unique per tab: identical labels would sync values
            spec.page = f.page;
            spec.x = (Integer) Math.round(f.x);
            spec.y = (Integer) Math.round(f.y);
            spec.width = f.width == null ? null : (Integer) Math.round(f.width);
            spec.height = f.height == null ? null : (Integer) Math.round(f.height);

            if (f.category == 'MERGE') {
                spec.kind = 'TEXT';
                spec.readOnly = true;
                spec.value = resolveMergeValue(f, ctx);
            } else if (f.category == 'ENTRY') {
                if (f.entryKind == 'CHECKBOX') {
                    spec.kind = 'CHECKBOX';
                } else {
                    spec.kind = 'TEXT';
                    spec.required = f.entryKind == 'REQUIRED_TEXT';
                }
            } else if (f.category == 'RECIPIENT') {
                if (f.recipientKind == 'SIGNATURE') {
                    spec.kind = 'SIGN_HERE';
                } else if (f.recipientKind == 'DATE_SIGNED') {
                    spec.kind = 'DATE_SIGNED';
                } else if (f.recipientKind == 'FULL_NAME') {
                    spec.kind = 'FULL_NAME';
                } else {
                    spec.kind = 'EMAIL';
                }
            }
            specs.add(spec);
        }
        return specs;
    }

    private static String resolveMergeValue(SignatureRequestModels.PlacedField f, ProspectContext ctx) {
        SObject record;
        if ('Contact'.equalsIgnoreCase(f.objectApiName)) {
            record = ctx.contactRecord;
        } else if ('Investing_Entity__c'.equalsIgnoreCase(f.objectApiName)) {
            record = ctx.entityRecord;
        } else if ('position__c'.equalsIgnoreCase(f.objectApiName)) {
            record = ctx.positionRecord;
        } else if ('Investment__c'.equalsIgnoreCase(f.objectApiName)) {
            record = ctx.investmentRecord;
        }
        if (record == null) {
            return '';
        }
        Schema.DescribeFieldResult fd = describeMergeField(f.objectApiName, f.fieldApiName);
        if (fd == null) {
            return '';
        }
        Object value;
        try {
            value = record.get(fd.getName());
        } catch (Exception e) {
            return ''; // field not queried (shouldn't happen: same describe drives the query)
        }
        return formatValue(fd.getType(), value);
    }

    @TestVisible
    private static String formatValue(Schema.DisplayType displayType, Object value) {
        if (value == null) {
            return '';
        }
        try {
            if (displayType == Schema.DisplayType.BOOLEAN) {
                return ((Boolean) value) ? 'Yes' : 'No';
            }
            if (displayType == Schema.DisplayType.DATE) {
                return ((Date) value).format();
            }
            if (displayType == Schema.DisplayType.DATETIME) {
                return ((Datetime) value).format();
            }
            if (displayType == Schema.DisplayType.CURRENCY
                    || displayType == Schema.DisplayType.DOUBLE
                    || displayType == Schema.DisplayType.PERCENT) {
                return ((Decimal) value).format();
            }
        } catch (Exception e) {
            // fall through to String.valueOf
        }
        return String.valueOf(value);
    }

    // ------------------------------------------------------------------
    // dfsle mapping + envelope assembly
    // ------------------------------------------------------------------

    public static List<dfsle.Tab> toDfsleTabs(List<SignatureRequestModels.TabSpec> specs) {
        List<dfsle.Tab> tabs = new List<dfsle.Tab>();
        for (SignatureRequestModels.TabSpec spec : specs) {
            dfsle.Tab.Position position = new dfsle.Tab.Position(
                1,          // document sequence: single master document
                spec.page,
                spec.x,
                spec.y,
                spec.width,
                spec.height);

            dfsle.Tab tab;
            if (spec.kind == 'TEXT') {
                tab = new dfsle.TextTab()
                    .withValue(spec.value)
                    .withReadOnly(spec.readOnly)
                    .withRequired(spec.required)
                    .withDataLabel(spec.dataLabel)
                    .withPosition(position);
            } else if (spec.kind == 'CHECKBOX') {
                tab = new dfsle.CheckboxTab()
                    .withDataLabel(spec.dataLabel)
                    .withPosition(position);
            } else if (spec.kind == 'SIGN_HERE') {
                tab = new dfsle.SignHereTab()
                    .withDataLabel(spec.dataLabel)
                    .withPosition(position);
            } else if (spec.kind == 'DATE_SIGNED') {
                tab = new dfsle.DateSignedTab()
                    .withDataLabel(spec.dataLabel)
                    .withPosition(position);
            } else if (spec.kind == 'FULL_NAME') {
                tab = new dfsle.FullNameTab()
                    .withDataLabel(spec.dataLabel)
                    .withPosition(position);
            } else if (spec.kind == 'EMAIL') {
                tab = new dfsle.EmailAddressTab()
                    .withDataLabel(spec.dataLabel)
                    .withPosition(position);
            }
            if (tab != null) {
                tabs.add(tab);
            }
        }
        return tabs;
    }

    /** Builds the complete per-contact envelope (does not send it). */
    public static dfsle.Envelope buildEnvelope(
            SignatureRequestModels.SendRequest req, ProspectContext ctx, String templateRole) {

        dfsle.Envelope envelope = gateway.emptyEnvelope(req.investmentId);

        dfsle.Document masterDocument;
        String recipientRole;
        if (req.document.sourceType == 'FILE') {
            List<ContentVersion> versions = [
                SELECT Id, Title, FileExtension, ContentSize, ContentDocumentId
                FROM ContentVersion
                WHERE Id = :req.document.contentVersionId
                WITH USER_MODE
                LIMIT 1
            ];
            if (versions.isEmpty()) {
                throw new SignatureRequestException('The selected file is no longer available.');
            }
            masterDocument = dfsle.Document.fromFile(versions[0]);
            recipientRole = 'Signer 1';
        } else {
            masterDocument = dfsle.Document.fromTemplate(
                dfsle.UUID.parse(req.document.templateId), req.document.name);
            recipientRole = String.isBlank(templateRole) ? 'Signer 1' : templateRole;
        }

        dfsle.Recipient recipient = dfsle.Recipient.fromSource(
            ctx.contactName,
            ctx.contactEmail,
            ctx.contactPhone,
            recipientRole,
            new dfsle.Entity(ctx.contactId));
        recipient = recipient.withRoutingOrder(1);

        if (req.document.sourceType == 'FILE') {
            List<dfsle.Tab> tabs = toDfsleTabs(buildTabSpecs(req.fields, ctx));
            if (!tabs.isEmpty()) {
                recipient = recipient.withTabs(tabs);
            }
        }

        String subject = String.isBlank(req.emailSubject)
            ? 'Signature requested: ' + String.valueOf(ctx.investmentRecord.get('Name'))
            : req.emailSubject;

        return envelope
            .withDocuments(new List<dfsle.Document>{ masterDocument })
            .withRecipients(new List<dfsle.Recipient>{ recipient })
            .withEmail(subject, req.emailMessage);
    }

    // ------------------------------------------------------------------
    // Template helpers (JSON introspection: managed member visibility varies)
    // ------------------------------------------------------------------

    /** First recipient role name of the template, or null when undeterminable. */
    public static String resolveTemplateRole(String templateId) {
        dfsle.Template template = gateway.getTemplate(templateId);
        if (template == null || template.recipients == null || template.recipients.isEmpty()) {
            return null;
        }
        try {
            dfsle.Recipient first = template.recipients[0];
            return first.role == null ? null : first.role.name;
        } catch (Exception e) {
            return null;
        }
    }

    /** Maps toolkit templates to wire-friendly DTOs (direct member access). */
    public static List<SignatureRequestModels.TemplateDoc> mapTemplates(List<dfsle.Template> templates) {
        List<SignatureRequestModels.TemplateDoc> docs = new List<SignatureRequestModels.TemplateDoc>();
        if (templates == null) {
            return docs;
        }
        for (dfsle.Template t : templates) {
            if (t == null || t.id == null) {
                continue;
            }
            SignatureRequestModels.TemplateDoc doc = new SignatureRequestModels.TemplateDoc();
            doc.templateId = String.valueOf(t.id);
            doc.name = t.name;
            doc.emailSubject = t.emailSubject;
            docs.add(doc);
        }
        return docs;
    }

    /**
     * DocuSign envelope id (UUID string) off a toolkit envelope, or null.
     * Direct member access: dfsle types are NOT JSON-serializable
     * ("Type cannot be serialized"), so introspection is not an option.
     */
    public static String readDocuSignId(dfsle.Envelope envelope) {
        if (envelope == null || envelope.docuSignId == null) {
            return null;
        }
        return String.valueOf(envelope.docuSignId);
    }

    /** Salesforce dfsle__Envelope__c record id off a toolkit envelope, or null. */
    public static String readEnvelopeRecordId(dfsle.Envelope envelope) {
        if (envelope == null || envelope.id == null) {
            return null;
        }
        return String.valueOf(envelope.id);
    }
}
