@IsTest
public class SignatureRequestServiceTest {

    /** Fake dfsle gateway: records interactions, never calls DocuSign. */
    public class FakeGateway implements SignatureRequestService.EnvelopeGateway {
        public Integer emptyCount = 0;
        public Integer sendCount = 0;
        public Integer draftCount = 0;
        public Integer voidCount = 0;
        public Integer pollCount = 0;
        public Boolean throwOnTemplate = false;
        public Boolean throwOnVoid = false;
        public dfsle.Template templateToReturn;
        public dfsle.Envelope lastSent;

        public dfsle.Envelope emptyEnvelope(Id sourceId) {
            emptyCount++;
            return newEnvelope();
        }
        public dfsle.Envelope sendNow(dfsle.Envelope envelope) {
            sendCount++;
            lastSent = envelope;
            return envelope;
        }
        public dfsle.Envelope saveDraft(dfsle.Envelope envelope) {
            draftCount++;
            lastSent = envelope;
            return envelope;
        }
        public List<dfsle.Template> getTemplates() {
            return templateToReturn == null
                ? new List<dfsle.Template>()
                : new List<dfsle.Template>{ templateToReturn };
        }
        public dfsle.Template getTemplate(String templateId) {
            if (throwOnTemplate) {
                throw new SignatureRequestService.SignatureRequestException('no template access');
            }
            return templateToReturn;
        }
        public String getSenderViewUrl(String docuSignId, String returnUrl) {
            return 'https://demo.docusign.net/sender/' + docuSignId;
        }
        public String getEnvelopeViewUrl(String docuSignId, String returnUrl) {
            return 'https://demo.docusign.net/documents/' + docuSignId;
        }
        public Boolean voidEnvelope(String docuSignId, String reason) {
            if (throwOnVoid) {
                throw new SignatureRequestService.SignatureRequestException('void not allowed');
            }
            voidCount++;
            return true;
        }
        public void pollStatuses(Id sourceId, Integer maximumRecords) {
            pollCount++;
        }
        private dfsle.Envelope newEnvelope() {
            return new dfsle.Envelope(null, null, null, null, null, null, null, null, null, null, null, null);
        }
    }

    /**
     * Fund IV with two invested entities:
     * - Trust Entity (Estate or Trust): Prime (primary), Second (required
     *   signer), Watcher (view-only), NoEmail (required but no email).
     * - Solo LLC (Partnership or LLC): Solo (primary).
     */
    @TestSetup
    static void setup() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;

        List<Contact> contacts = new List<Contact>{
            new Contact(LastName = 'Prime', Email = 'prime@example.com', Phone = '111'),
            new Contact(LastName = 'Second', Email = 'second@example.com'),
            new Contact(LastName = 'Watcher', Email = 'watcher@example.com'),
            new Contact(LastName = 'NoEmail'),
            new Contact(LastName = 'Solo', Email = 'solo@example.com')
        };
        insert contacts;

        List<Investing_Entity__c> entities = new List<Investing_Entity__c>{
            new Investing_Entity__c(Name = 'Trust Entity', Entity_Type__c = 'Estate or Trust'),
            new Investing_Entity__c(Name = 'Solo LLC', Entity_Type__c = 'Partnership or LLC')
        };
        insert entities;

        insert new List<position__c>{
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[0].Id),
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[1].Id)
        };

        insert new List<Associated_Contact__c>{
            new Associated_Contact__c(Name = 'Prime', Investing_Entity__c = entities[0].Id,
                Contact__c = contacts[0].Id, Primary__c = true, Required_Signer__c = true),
            new Associated_Contact__c(Name = 'Second', Investing_Entity__c = entities[0].Id,
                Contact__c = contacts[1].Id, Primary__c = false, Required_Signer__c = true),
            new Associated_Contact__c(Name = 'Watcher', Investing_Entity__c = entities[0].Id,
                Contact__c = contacts[2].Id, Primary__c = false, Required_Signer__c = false),
            new Associated_Contact__c(Name = 'NoEmail', Investing_Entity__c = entities[0].Id,
                Contact__c = contacts[3].Id, Primary__c = false, Required_Signer__c = true),
            new Associated_Contact__c(Name = 'Solo', Investing_Entity__c = entities[1].Id,
                Contact__c = contacts[4].Id, Primary__c = true, Required_Signer__c = true)
        };
    }

    public static Id investmentId() {
        return [SELECT Id FROM Investment__c WHERE Name = 'Fund IV' LIMIT 1].Id;
    }

    public static List<Id> allAssociationIds() {
        List<Id> ids = new List<Id>();
        for (Associated_Contact__c a : [
            SELECT Id FROM Associated_Contact__c
            WHERE Contact__r.Email != NULL
            ORDER BY Name
        ]) {
            ids.add(a.Id);
        }
        return ids;
    }

    public static String requestJson(Id invId, List<Id> associationIds, List<Object> fields) {
        return JSON.serialize(new Map<String, Object>{
            'investmentId' => invId,
            'emailSubject' => 'Please sign',
            'emailMessage' => 'Review and sign.',
            'document' => new Map<String, Object>{
                'sourceType' => 'FILE',
                'contentVersionId' => makeContentVersion(),
                'name' => 'PPM.pdf',
                'pageCount' => 3,
                'lastPageWidth' => 612,
                'lastPageHeight' => 792
            },
            'fields' => fields,
            'selectedAssociationIds' => associationIds
        });
    }

    private static Id makeContentVersion() {
        ContentVersion cv = new ContentVersion(
            Title = 'PPM', PathOnClient = 'PPM.pdf', VersionData = Blob.valueOf('%PDF-1.4 test'));
        insert cv;
        return [SELECT Id FROM ContentVersion WHERE Id = :cv.Id].Id;
    }

    private static Map<String, Object> mergeField(String clientId, String obj, String field, List<String> entityTypes) {
        return new Map<String, Object>{
            'clientId' => clientId, 'category' => 'MERGE',
            'objectApiName' => obj, 'fieldApiName' => field, 'label' => field,
            'entityTypes' => entityTypes, 'page' => 1, 'x' => 72.4, 'y' => 100.6,
            'width' => 120, 'height' => 16
        };
    }

    @IsTest
    static void mergeGroupsExposeWizardObjects() {
        List<SignatureRequestModels.MergeGroup> groups = SignatureRequestService.getMergeGroups();

        Map<String, Set<String>> byObject = new Map<String, Set<String>>();
        for (SignatureRequestModels.MergeGroup grp : groups) {
            Set<String> names = new Set<String>();
            for (SignatureRequestModels.MergeFieldDef def : grp.fields) {
                names.add(def.fieldApiName);
            }
            byObject.put(grp.objectApiName, names);
        }
        Assert.isTrue(byObject.get('Investing_Entity__c').contains('Entity_Type__c'), 'entity type missing');
        Assert.isTrue(byObject.get('Contact').contains('Email'), 'contact email missing');
        Assert.isTrue(byObject.get('Investment__c').contains('Name'), 'investment name missing');
    }

    @IsTest
    static void loadProspectsListsAssociationsWithRoles() {
        SignatureRequestModels.ProspectResult result = SignatureRequestService.loadProspects(investmentId());

        Assert.areEqual('Fund IV', result.investmentName);
        Assert.areEqual(4, result.prospects.size(), 'Prime+Second+Watcher+Solo (NoEmail hidden)');
        Assert.areEqual(1, result.skippedNoEmailCount);

        Map<String, SignatureRequestModels.Prospect> byName = new Map<String, SignatureRequestModels.Prospect>();
        for (SignatureRequestModels.Prospect p : result.prospects) {
            byName.put(p.name, p);
        }
        Assert.isTrue(byName.get('Prime').isPrimary);
        Assert.isTrue(byName.get('Prime').isRequiredSigner, 'primary is always a required signer');
        Assert.isFalse(byName.get('Second').isPrimary);
        Assert.isTrue(byName.get('Second').isRequiredSigner);
        Assert.isFalse(byName.get('Watcher').isRequiredSigner, 'viewer is not a required signer');
        Assert.areEqual('Trust Entity', byName.get('Prime').entityName);
        Assert.isNotNull(byName.get('Prime').associationId);
    }

    @IsTest
    static void loadRecipientGroupsGroupsByEntityAndFindsPrimary() {
        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            requestJson(investmentId(), allAssociationIds(), new List<Object>()));
        Map<Id, SignatureRequestService.EntityRecipientGroup> groups =
            SignatureRequestService.loadRecipientGroups(req);

        Assert.areEqual(2, groups.size(), 'one group per invested entity');
        for (SignatureRequestService.EntityRecipientGroup grp : groups.values()) {
            if (grp.entityName == 'Trust Entity') {
                Assert.areEqual(3, grp.recipients.size(), 'NoEmail dropped');
                Assert.isNotNull(grp.primary, 'primary resolved');
                Assert.isTrue(grp.primary.isPrimary);
                Assert.isTrue(grp.primary.contactName.contains('Prime'));
            } else {
                Assert.areEqual('Solo LLC', grp.entityName);
                Assert.areEqual(1, grp.recipients.size());
                Assert.isNotNull(grp.primary);
            }
        }
    }

    @IsTest
    static void parseAndValidateRejectsBadPayloads() {
        Id invId = investmentId();
        List<Id> assocIds = allAssociationIds();

        try {
            SignatureRequestService.parseAndValidate('{"investmentId": null}');
            Assert.fail('expected missing-investment failure');
        } catch (SignatureRequestService.SignatureRequestException e) {
            Assert.isTrue(e.getMessage().contains('investment'), e.getMessage());
        }

        try {
            SignatureRequestService.parseAndValidate(requestJson(invId, new List<Id>(), new List<Object>()));
            Assert.fail('expected empty-selection failure');
        } catch (SignatureRequestService.SignatureRequestException e) {
            Assert.isTrue(e.getMessage().contains('at least one investor'), e.getMessage());
        }

        try {
            SignatureRequestService.parseAndValidate(requestJson(invId, assocIds,
                new List<Object>{ mergeField('f1', 'Account', 'Name', null) }));
            Assert.fail('expected non-whitelisted-object failure');
        } catch (SignatureRequestService.SignatureRequestException e) {
            Assert.isTrue(e.getMessage().contains('not available'), e.getMessage());
        }

        SignatureRequestModels.SendRequest ok = SignatureRequestService.parseAndValidate(
            requestJson(invId, assocIds,
                new List<Object>{ mergeField('f1', 'Investing_Entity__c', 'Name', null) }));
        Assert.areEqual(1, ok.fields.size());
    }

    @IsTest
    static void buildTabSpecsAppliesEntityFilterAndResolvesPrimaryValues() {
        Id invId = investmentId();
        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            requestJson(invId, allAssociationIds(), new List<Object>{
                mergeField('fEntityName', 'Investing_Entity__c', 'Name', null),
                mergeField('fRestricted', 'Investing_Entity__c', 'Entity_Type__c',
                    new List<String>{ 'Estate or Trust' }),
                mergeField('fPrimaryEmail', 'Contact', 'Email', null),
                new Map<String, Object>{
                    'clientId' => 'fReqText', 'category' => 'ENTRY', 'entryKind' => 'REQUIRED_TEXT',
                    'label' => 'Required Text', 'page' => 2, 'x' => 10, 'y' => 20 }
            }));

        Map<Id, SignatureRequestService.EntityRecipientGroup> groups =
            SignatureRequestService.loadRecipientGroups(req);
        Map<Id, SignatureRequestService.ProspectContext> contexts =
            SignatureRequestService.loadEntityContexts(req, groups);

        SignatureRequestService.ProspectContext trustCtx;
        SignatureRequestService.ProspectContext soloCtx;
        for (SignatureRequestService.EntityRecipientGroup grp : groups.values()) {
            if (grp.entityName == 'Trust Entity') {
                trustCtx = contexts.get(grp.entityId);
            } else {
                soloCtx = contexts.get(grp.entityId);
            }
        }

        List<SignatureRequestModels.TabSpec> trustSpecs =
            SignatureRequestService.buildTabSpecs(req.fields, trustCtx);
        List<SignatureRequestModels.TabSpec> soloSpecs =
            SignatureRequestService.buildTabSpecs(req.fields, soloCtx);

        Assert.areEqual(4, trustSpecs.size(), 'restricted field included for Estate or Trust');
        Assert.areEqual(3, soloSpecs.size(), 'restricted field skipped for Partnership or LLC');

        Assert.areEqual('Trust Entity', trustSpecs[0].value);
        Assert.isTrue(trustSpecs[0].readOnly, 'merge tabs are locked');
        Assert.areEqual(72, trustSpecs[0].x, 'x rounded to integer points');

        Assert.areEqual('prime@example.com', trustSpecs[2].value,
            'Contact merge fields resolve against the PRIMARY investor');
        Assert.areEqual('solo@example.com', soloSpecs[1].value);
    }

    @IsTest
    static void buildTabSpecsSkipsRestrictedForNullEntityType() {
        SignatureRequestService.ProspectContext ctx = new SignatureRequestService.ProspectContext();
        ctx.entityType = null;
        ctx.entityRecord = new Investing_Entity__c(Name = 'X');

        SignatureRequestModels.PlacedField f = new SignatureRequestModels.PlacedField();
        f.clientId = 'f1';
        f.category = 'RECIPIENT';
        f.recipientKind = 'SIGNATURE';
        f.entityTypes = new List<String>{ 'Individual' };
        f.page = 1; f.x = 1; f.y = 1;

        List<SignatureRequestModels.TabSpec> specs = SignatureRequestService.buildTabSpecs(
            new List<SignatureRequestModels.PlacedField>{ f }, ctx);
        Assert.areEqual(0, specs.size(), 'null entity type never matches a restriction, any category');
    }

    @IsTest
    static void formatValueCoversTypes() {
        Assert.areEqual('', SignatureRequestService.formatValue(Schema.DisplayType.STRING, null));
        Assert.areEqual('Yes', SignatureRequestService.formatValue(Schema.DisplayType.BOOLEAN, true));
        Assert.areEqual('No', SignatureRequestService.formatValue(Schema.DisplayType.BOOLEAN, false));
        Assert.isTrue(String.isNotBlank(
            SignatureRequestService.formatValue(Schema.DisplayType.DATE, Date.newInstance(2026, 7, 15))));
        Assert.areEqual('plain', SignatureRequestService.formatValue(Schema.DisplayType.STRING, 'plain'));
    }

    @IsTest
    static void autoSignSpecsStackFromLastPageBottom() {
        SignatureRequestModels.DocumentSelection doc = new SignatureRequestModels.DocumentSelection();
        doc.sourceType = 'FILE';
        doc.pageCount = 3;
        doc.lastPageWidth = 612;
        doc.lastPageHeight = 792;

        List<SignatureRequestModels.TabSpec> first =
            SignatureRequestService.buildAutoSignSpecs(doc, 0, 2, 'auto_s2');
        List<SignatureRequestModels.TabSpec> second =
            SignatureRequestService.buildAutoSignSpecs(doc, 1, 2, 'auto_primary');

        Assert.areEqual(3, first.size(), 'Sign Here + Full Name + Date Signed');
        Assert.areEqual('SIGN_HERE', first[0].kind);
        Assert.areEqual(3, first[0].page, 'always the LAST page');
        Assert.isTrue(second[0].y > first[0].y, 'later slots sit lower on the page');
        Assert.areEqual('auto_primary_sign', second[0].dataLabel);

        // No page metadata (template master) -> no auto blocks.
        doc.pageCount = null;
        Assert.areEqual(0, SignatureRequestService.buildAutoSignSpecs(doc, 0, 1, 'x').size());
    }

    @IsTest
    static void buildEntityEnvelopeAssignsRolesAndRouting() {
        FakeGateway fake = new FakeGateway();
        SignatureRequestService.gateway = fake;

        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            requestJson(investmentId(), allAssociationIds(),
                new List<Object>{ mergeField('f1', 'Contact', 'Email', null) }));

        Map<Id, SignatureRequestService.EntityRecipientGroup> groups =
            SignatureRequestService.loadRecipientGroups(req);
        SignatureRequestService.EntityRecipientGroup trust;
        for (SignatureRequestService.EntityRecipientGroup grp : groups.values()) {
            if (grp.entityName == 'Trust Entity') {
                trust = grp;
            }
        }
        SignatureRequestService.ProspectContext ctx =
            SignatureRequestService.loadEntityContexts(req, groups).get(trust.entityId);

        dfsle.Envelope envelope = SignatureRequestService.buildEntityEnvelope(req, ctx, trust, null);

        Assert.isNotNull(envelope);
        Assert.areEqual(1, fake.emptyCount, 'gateway created the empty envelope');
        for (SignatureRequestModels.RecipientPlan plan : trust.recipients) {
            if (plan.isPrimary) {
                Assert.areEqual(2, plan.routingOrder, 'primary signs after required secondaries');
                Assert.areEqual('Signer', plan.recipientRole);
            } else if (plan.isRequiredSigner) {
                Assert.areEqual(1, plan.routingOrder, 'required secondary signs first');
            } else {
                Assert.areEqual('Viewer', plan.recipientRole, 'non-required contact is view-only');
            }
        }
    }

    @IsTest
    static void templateHelpersSurviveOpaqueShapes() {
        FakeGateway fake = new FakeGateway();
        SignatureRequestService.gateway = fake;

        Assert.areEqual(0, SignatureRequestService.mapTemplates(null).size());
        Assert.isNull(SignatureRequestService.readDocuSignId(null));

        dfsle.Envelope env = new dfsle.Envelope(null, null, null, null, null, null, null, null, null, null, null, null);
        Assert.isNull(SignatureRequestService.readDocuSignId(env));
        dfsle.Envelope envWithIds = new dfsle.Envelope(
            null, null, dfsle.UUID.parse('33333333-3333-3333-3333-333333333333'),
            null, null, null, null, null, null, null, null, null);
        Assert.areEqual('33333333-3333-3333-3333-333333333333',
            SignatureRequestService.readDocuSignId(envWithIds));

        fake.templateToReturn = new dfsle.Template(null, 'Blank', null, null, null, null, null, null);
        Assert.isNull(SignatureRequestService.resolveTemplateRole('11111111-1111-1111-1111-111111111111'));

        fake.templateToReturn = new dfsle.Template(
            dfsle.UUID.parse('22222222-2222-2222-2222-222222222222'), 'Sub Docs',
            null, null, 'Subject', null,
            new List<dfsle.Recipient>{
                dfsle.Recipient.fromSource('Tester', 't@example.com', null, 'Signer 1', null) },
            null);
        List<SignatureRequestModels.TemplateDoc> mapped =
            SignatureRequestService.mapTemplates(fake.getTemplates());
        Assert.areEqual(1, mapped.size());
        Assert.areEqual('Sub Docs', mapped[0].name);
        Assert.areEqual('Signer 1',
            SignatureRequestService.resolveTemplateRole('22222222-2222-2222-2222-222222222222'));
    }
}
