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

    /**
     * Prospect list for the wizard: one row per Associated_Contact__c of any
     * investing entity holding a position in this investment. All rows are
     * pre-selected in the UI; Primary/Required Signer flags come along so the
     * user sees each investor's role.
     */
    public static SignatureRequestModels.ProspectResult loadProspects(Id investmentId) {
        SignatureRequestModels.ProspectResult result = new SignatureRequestModels.ProspectResult();

        List<Investment__c> investments = [
            SELECT Id, Name FROM Investment__c WHERE Id = :investmentId WITH USER_MODE LIMIT 1
        ];
        if (investments.isEmpty()) {
            throw new SignatureRequestException('Investment record not found or not accessible.');
        }
        result.investmentName = investments[0].Name;

        // Entities invested here; most recent position per entity for display.
        Map<Id, Id> latestPositionByEntity = new Map<Id, Id>();
        for (position__c pos : [
            SELECT Id, Investing_Entity__c
            FROM position__c
            WHERE Investment__c = :investmentId AND Investing_Entity__c != NULL
            WITH USER_MODE
            ORDER BY CreatedDate DESC
        ]) {
            if (!latestPositionByEntity.containsKey(pos.Investing_Entity__c)) {
                latestPositionByEntity.put(pos.Investing_Entity__c, pos.Id);
            }
        }
        if (latestPositionByEntity.isEmpty()) {
            return result;
        }

        for (Associated_Contact__c assoc : [
            SELECT Id, Primary__c, Required_Signer__c,
                   Investing_Entity__c, Investing_Entity__r.Name, Investing_Entity__r.Entity_Type__c,
                   Contact__c, Contact__r.Name, Contact__r.Email, Contact__r.Phone
            FROM Associated_Contact__c
            WHERE Investing_Entity__c IN :latestPositionByEntity.keySet()
              AND Contact__c != NULL
            WITH USER_MODE
            ORDER BY Investing_Entity__r.Name, Primary__c DESC, CreatedDate
        ]) {
            if (String.isBlank(assoc.Contact__r.Email)) {
                result.skippedNoEmailCount++;
                continue;
            }
            SignatureRequestModels.Prospect p = new SignatureRequestModels.Prospect();
            p.associationId = assoc.Id;
            p.contactId = assoc.Contact__c;
            p.name = assoc.Contact__r.Name;
            p.email = assoc.Contact__r.Email;
            p.phone = assoc.Contact__r.Phone;
            p.entityId = assoc.Investing_Entity__c;
            p.entityName = assoc.Investing_Entity__r.Name;
            p.entityType = assoc.Investing_Entity__r.Entity_Type__c;
            p.positionId = latestPositionByEntity.get(assoc.Investing_Entity__c);
            p.isPrimary = assoc.Primary__c == true;
            // Business rule: the primary investor is always a required signer.
            p.isRequiredSigner = assoc.Required_Signer__c == true || assoc.Primary__c == true;
            result.prospects.add(p);
        }
        return result;
    }

    /** Selected recipients of one investing entity's shared envelope. */
    public class EntityRecipientGroup {
        public Id entityId;
        public String entityName;
        public SignatureRequestModels.RecipientPlan primary;
        public List<SignatureRequestModels.RecipientPlan> recipients =
            new List<SignatureRequestModels.RecipientPlan>();
    }

    /**
     * Groups the selected Associated_Contact__c rows by investing entity,
     * limited to entities that hold a position in this investment. Contacts
     * without an email are dropped; the primary flag forces required-signer.
     */
    public static Map<Id, EntityRecipientGroup> loadRecipientGroups(
            SignatureRequestModels.SendRequest req) {

        Map<Id, EntityRecipientGroup> groups = new Map<Id, EntityRecipientGroup>();
        if (req.selectedAssociationIds == null || req.selectedAssociationIds.isEmpty()) {
            return groups;
        }
        Set<Id> entityIds = new Set<Id>();
        for (position__c pos : [
            SELECT Investing_Entity__c
            FROM position__c
            WHERE Investment__c = :req.investmentId AND Investing_Entity__c != NULL
            WITH USER_MODE
        ]) {
            entityIds.add(pos.Investing_Entity__c);
        }
        if (entityIds.isEmpty()) {
            return groups;
        }

        for (Associated_Contact__c assoc : [
            SELECT Id, Primary__c, Required_Signer__c,
                   Investing_Entity__c, Investing_Entity__r.Name,
                   Contact__c, Contact__r.Name, Contact__r.Email, Contact__r.Phone
            FROM Associated_Contact__c
            WHERE Id IN :req.selectedAssociationIds
              AND Investing_Entity__c IN :entityIds
              AND Contact__c != NULL
            WITH USER_MODE
            ORDER BY Primary__c DESC, CreatedDate
        ]) {
            if (String.isBlank(assoc.Contact__r.Email)) {
                continue;
            }
            EntityRecipientGroup grp = groups.get(assoc.Investing_Entity__c);
            if (grp == null) {
                grp = new EntityRecipientGroup();
                grp.entityId = assoc.Investing_Entity__c;
                grp.entityName = assoc.Investing_Entity__r.Name;
                groups.put(grp.entityId, grp);
            }
            SignatureRequestModels.RecipientPlan plan = new SignatureRequestModels.RecipientPlan();
            plan.associationId = assoc.Id;
            plan.contactId = assoc.Contact__c;
            plan.contactName = assoc.Contact__r.Name;
            plan.contactEmail = assoc.Contact__r.Email;
            plan.contactPhone = assoc.Contact__r.Phone;
            plan.isPrimary = assoc.Primary__c == true;
            plan.isRequiredSigner = assoc.Required_Signer__c == true || plan.isPrimary;
            if (plan.isPrimary && grp.primary == null) {
                grp.primary = plan;
            }
            grp.recipients.add(plan);
        }
        return groups;
    }

    /**
     * Loads the merge-value context PER INVESTING ENTITY: the entity's most
     * recent position on this investment, the entity itself, the investment,
     * and the entity's PRIMARY contact (Contact merge fields resolve against
     * the primary — they fill the input fields). Only describe-validated
     * field names ever enter the dynamic SOQL.
     */
    public static Map<Id, ProspectContext> loadEntityContexts(
            SignatureRequestModels.SendRequest req, Map<Id, EntityRecipientGroup> groups) {

        Map<Id, ProspectContext> contexts = new Map<Id, ProspectContext>();
        if (groups == null || groups.isEmpty()) {
            return contexts;
        }
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

        // Most recent position per entity, with entity relationship fields.
        Set<Id> entityIds = groups.keySet();
        List<String> selectParts = new List<String>{ 'Id', 'Investing_Entity__c' };
        Set<String> seen = new Set<String>{ 'id', 'investing_entity__c' };
        for (String f : fieldsByObject.get('position__c')) {
            addSelect(selectParts, seen, f);
        }
        for (String f : fieldsByObject.get('investing_entity__c')) {
            addSelect(selectParts, seen, 'Investing_Entity__r.' + f);
        }
        String posQuery = 'SELECT ' + String.join(selectParts, ', ')
            + ' FROM position__c'
            + ' WHERE Investment__c = :investmentId'
            + ' AND Investing_Entity__c IN :entityIds'
            + ' ORDER BY CreatedDate DESC';
        Map<Id, SObject> positionByEntity = new Map<Id, SObject>();
        for (SObject pos : Database.queryWithBinds(
                posQuery,
                new Map<String, Object>{ 'investmentId' => req.investmentId, 'entityIds' => entityIds },
                AccessLevel.USER_MODE)) {
            Id entityId = (Id) pos.get('Investing_Entity__c');
            if (!positionByEntity.containsKey(entityId)) {
                positionByEntity.put(entityId, pos);
            }
        }

        // Primary contacts with the Contact merge fields.
        Set<Id> primaryContactIds = new Set<Id>();
        for (EntityRecipientGroup grp : groups.values()) {
            if (grp.primary != null) {
                primaryContactIds.add(grp.primary.contactId);
            }
        }
        Map<Id, SObject> contactById = new Map<Id, SObject>();
        if (!primaryContactIds.isEmpty()) {
            List<String> contactSelect = new List<String>{ 'Id' };
            Set<String> seenContact = new Set<String>{ 'id' };
            for (String f : fieldsByObject.get('contact')) {
                addSelect(contactSelect, seenContact, f);
            }
            String contactQuery = 'SELECT ' + String.join(contactSelect, ', ')
                + ' FROM Contact WHERE Id IN :contactIds';
            for (SObject c : Database.queryWithBinds(
                    contactQuery,
                    new Map<String, Object>{ 'contactIds' => primaryContactIds },
                    AccessLevel.USER_MODE)) {
                contactById.put((Id) c.get('Id'), c);
            }
        }

        for (EntityRecipientGroup grp : groups.values()) {
            SObject pos = positionByEntity.get(grp.entityId);
            if (pos == null) {
                continue; // entity no longer holds a position here
            }
            SObject entity = pos.getSObject('Investing_Entity__r');
            SObject primaryContact = grp.primary == null ? null : contactById.get(grp.primary.contactId);

            ProspectContext ctx = new ProspectContext();
            ctx.contactId = grp.primary == null ? null : grp.primary.contactId;
            ctx.contactName = grp.primary == null ? null : grp.primary.contactName;
            ctx.contactEmail = grp.primary == null ? null : grp.primary.contactEmail;
            ctx.contactPhone = grp.primary == null ? null : grp.primary.contactPhone;
            ctx.entityType = entity == null ? null : (String) entity.get('Entity_Type__c');
            ctx.contactRecord = primaryContact;
            ctx.entityRecord = entity;
            ctx.positionRecord = pos;
            ctx.investmentRecord = investment;
            contexts.put(grp.entityId, ctx);
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
        if (req.selectedAssociationIds == null || req.selectedAssociationIds.isEmpty()) {
            throw new SignatureRequestException('Select at least one investor to send to.');
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

    /**
     * Auto-generated signing block (Sign Here + Full Name + Date Signed) in
     * the generic area at the bottom of the LAST page — one block per
     * required signer, stacked. Skipped when page metadata is unavailable
     * (template masters or a stale client).
     */
    public static List<SignatureRequestModels.TabSpec> buildAutoSignSpecs(
            SignatureRequestModels.DocumentSelection doc,
            Integer slotIndex, Integer totalSlots, String labelPrefix) {

        List<SignatureRequestModels.TabSpec> specs = new List<SignatureRequestModels.TabSpec>();
        if (doc == null || doc.pageCount == null || doc.pageCount < 1 || doc.lastPageHeight == null) {
            return specs;
        }
        Decimal blockHeight = 64;
        Decimal bottomMargin = 30;
        Decimal y = doc.lastPageHeight - bottomMargin - (blockHeight * (totalSlots - slotIndex));
        if (y < 24) {
            y = 24 + (slotIndex * 14); // degenerate short page: overlap rather than fall off
        }
        Integer page = doc.pageCount;
        Integer yTop = (Integer) Math.round(y);

        SignatureRequestModels.TabSpec sign = new SignatureRequestModels.TabSpec();
        sign.kind = 'SIGN_HERE';
        sign.dataLabel = labelPrefix + '_sign';
        sign.page = page;
        sign.x = 54;
        sign.y = yTop;
        specs.add(sign);

        SignatureRequestModels.TabSpec fullName = new SignatureRequestModels.TabSpec();
        fullName.kind = 'FULL_NAME';
        fullName.dataLabel = labelPrefix + '_name';
        fullName.page = page;
        fullName.x = 230;
        fullName.y = yTop + 22;
        specs.add(fullName);

        SignatureRequestModels.TabSpec dateSigned = new SignatureRequestModels.TabSpec();
        dateSigned.kind = 'DATE_SIGNED';
        dateSigned.dataLabel = labelPrefix + '_date';
        dateSigned.page = page;
        dateSigned.x = 430;
        dateSigned.y = yTop + 22;
        specs.add(dateSigned);

        return specs;
    }

    /**
     * Builds ONE shared envelope for an investing entity:
     * - required secondary signers sign FIRST (routing 1), each with an
     *   auto-generated signing block at the end of the document;
     * - the PRIMARY investor signs LAST with every manually placed input
     *   field (signature/text/checkbox), all merge fields, plus their own
     *   auto signing block;
     * - non-required contacts receive a view-only (carbon copy) of the
     *   document.
     * The envelope completes only when every required signer has signed.
     */
    public static dfsle.Envelope buildEntityEnvelope(
            SignatureRequestModels.SendRequest req,
            ProspectContext ctx,
            EntityRecipientGroup grp,
            String templateRole) {

        if (grp.primary == null) {
            throw new SignatureRequestException(
                'Investing entity "' + grp.entityName + '" has no primary investor selected.');
        }
        Boolean isFile = req.document.sourceType == 'FILE';

        dfsle.Envelope envelope = gateway.emptyEnvelope(req.investmentId);

        dfsle.Document masterDocument;
        if (isFile) {
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
        } else {
            masterDocument = dfsle.Document.fromTemplate(
                dfsle.UUID.parse(req.document.templateId), req.document.name);
        }

        // Classify recipients.
        List<SignatureRequestModels.RecipientPlan> requiredSecondaries =
            new List<SignatureRequestModels.RecipientPlan>();
        List<SignatureRequestModels.RecipientPlan> viewers =
            new List<SignatureRequestModels.RecipientPlan>();
        for (SignatureRequestModels.RecipientPlan plan : grp.recipients) {
            if (plan.isPrimary) {
                continue;
            }
            if (plan.isRequiredSigner) {
                requiredSecondaries.add(plan);
            } else {
                viewers.add(plan);
            }
        }
        Boolean hasSecondSigners = !requiredSecondaries.isEmpty();
        Integer totalBlocks = requiredSecondaries.size() + 1; // + primary

        List<dfsle.Recipient> recipients = new List<dfsle.Recipient>();

        // Required secondary signers: routing 1, auto block each.
        Integer slot = 0;
        Integer signerNumber = 2;
        for (SignatureRequestModels.RecipientPlan plan : requiredSecondaries) {
            plan.routingOrder = 1;
            plan.recipientRole = 'Signer';
            dfsle.Recipient recipient = dfsle.Recipient.fromSource(
                plan.contactName, plan.contactEmail, plan.contactPhone,
                'Signer ' + signerNumber, new dfsle.Entity(plan.contactId));
            recipient = recipient.withRoutingOrder(1);
            if (isFile) {
                List<dfsle.Tab> tabs = toDfsleTabs(buildAutoSignSpecs(
                    req.document, slot, totalBlocks, 'auto_s' + signerNumber));
                if (!tabs.isEmpty()) {
                    recipient = recipient.withTabs(tabs);
                }
            }
            recipients.add(recipient);
            slot++;
            signerNumber++;
        }

        // Primary investor: signs last, owns every placed input field.
        SignatureRequestModels.RecipientPlan primary = grp.primary;
        primary.routingOrder = hasSecondSigners ? 2 : 1;
        primary.recipientRole = 'Signer';
        String primaryRole = isFile || String.isBlank(templateRole) ? 'Signer 1' : templateRole;
        dfsle.Recipient primaryRecipient = dfsle.Recipient.fromSource(
            primary.contactName, primary.contactEmail, primary.contactPhone,
            primaryRole, new dfsle.Entity(primary.contactId));
        primaryRecipient = primaryRecipient.withRoutingOrder(primary.routingOrder);
        if (isFile) {
            List<SignatureRequestModels.TabSpec> primarySpecs = buildTabSpecs(req.fields, ctx);
            primarySpecs.addAll(buildAutoSignSpecs(req.document, slot, totalBlocks, 'auto_primary'));
            List<dfsle.Tab> tabs = toDfsleTabs(primarySpecs);
            if (!tabs.isEmpty()) {
                primaryRecipient = primaryRecipient.withTabs(tabs);
            }
        }
        recipients.add(primaryRecipient);

        // View-only recipients (carbon copies) get the document immediately.
        for (SignatureRequestModels.RecipientPlan plan : viewers) {
            plan.routingOrder = 1;
            plan.recipientRole = 'Viewer';
            dfsle.Recipient viewer = dfsle.Recipient.fromSource(
                plan.contactName, plan.contactEmail, plan.contactPhone,
                'Viewer', new dfsle.Entity(plan.contactId));
            viewer = viewer.withRoutingOrder(1);
            viewer = viewer.withType('CarbonCopy');
            recipients.add(viewer);
        }

        String subject = String.isBlank(req.emailSubject)
            ? 'Signature requested: ' + String.valueOf(ctx.investmentRecord.get('Name'))
            : req.emailSubject;

        return envelope
            .withDocuments(new List<dfsle.Document>{ masterDocument })
            .withRecipients(recipients)
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
