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

    @TestSetup
    static void setup() {
        Investment__c inv = new Investment__c(Name = 'Fund IV');
        insert inv;

        List<Contact> contacts = new List<Contact>{
            new Contact(LastName = 'Alpha', Email = 'alpha@example.com', Phone = '111-1111'),
            new Contact(LastName = 'Beta', Email = 'beta@example.com'),
            new Contact(LastName = 'NoEmail')
        };
        insert contacts;

        List<Investing_Entity__c> entities = new List<Investing_Entity__c>{
            new Investing_Entity__c(Name = 'Alpha LLC', Entity_Type__c = 'Partnership or LLC', Contact__c = contacts[0].Id),
            new Investing_Entity__c(Name = 'Alpha Trust', Entity_Type__c = 'Estate or Trust', Contact__c = contacts[0].Id),
            new Investing_Entity__c(Name = 'Beta Individual', Entity_Type__c = 'Individual', Contact__c = contacts[1].Id),
            new Investing_Entity__c(Name = 'Silent LLC', Entity_Type__c = 'Partnership or LLC', Contact__c = contacts[2].Id)
        };
        insert entities;

        List<position__c> positions = new List<position__c>{
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[0].Id), // Alpha older
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[1].Id), // Alpha newer
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[2].Id),
            new position__c(Investment__c = inv.Id, Investing_Entity__c = entities[3].Id)
        };
        insert positions;
        Test.setCreatedDate(positions[0].Id, Datetime.now().addDays(-10));
        Test.setCreatedDate(positions[1].Id, Datetime.now().addDays(-1));
        Test.setCreatedDate(positions[2].Id, Datetime.now().addDays(-5));
        Test.setCreatedDate(positions[3].Id, Datetime.now().addDays(-5));
    }

    private static Id investmentId() {
        return [SELECT Id FROM Investment__c WHERE Name = 'Fund IV' LIMIT 1].Id;
    }

    private static Contact contactByName(String lastName) {
        return [SELECT Id, Name, Email, Phone FROM Contact WHERE LastName = :lastName LIMIT 1];
    }

    private static String requestJson(Id invId, List<Id> contactIds, List<Object> fields) {
        return JSON.serialize(new Map<String, Object>{
            'investmentId' => invId,
            'emailSubject' => 'Please sign',
            'emailMessage' => 'Review and sign.',
            'document' => new Map<String, Object>{
                'sourceType' => 'FILE',
                'contentVersionId' => makeContentVersion(),
                'name' => 'PPM.pdf'
            },
            'fields' => fields,
            'selectedContactIds' => contactIds
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
        Assert.isTrue(byObject.containsKey('Investing_Entity__c'), 'entity group missing');
        Assert.isTrue(byObject.get('Investing_Entity__c').contains('Name'), 'entity Name missing');
        Assert.isTrue(byObject.get('Investing_Entity__c').contains('Entity_Type__c'), 'entity type missing');
        Assert.isTrue(byObject.get('Contact').contains('Email'), 'contact email missing');
        Assert.isTrue(byObject.get('Investment__c').contains('Name'), 'investment name missing');
    }

    @IsTest
    static void loadProspectsDedupesAndSkipsNoEmail() {
        SignatureRequestModels.ProspectResult result = SignatureRequestService.loadProspects(investmentId());

        Assert.areEqual('Fund IV', result.investmentName);
        Assert.areEqual(2, result.prospects.size(), 'Alpha deduped + Beta; NoEmail skipped');
        Assert.areEqual(1, result.skippedNoEmailCount);

        Map<String, SignatureRequestModels.Prospect> byName = new Map<String, SignatureRequestModels.Prospect>();
        for (SignatureRequestModels.Prospect p : result.prospects) {
            byName.put(p.name, p);
        }
        Assert.isTrue(byName.containsKey('Alpha'), 'Alpha missing');
        Assert.areEqual('Alpha Trust', byName.get('Alpha').entityName,
            'most recent position entity must win for duplicated contact');
    }

    @IsTest
    static void parseAndValidateRejectsBadPayloads() {
        Id invId = investmentId();
        Id alphaId = contactByName('Alpha').Id;

        try {
            SignatureRequestService.parseAndValidate('{"investmentId": null}');
            Assert.fail('expected missing-investment failure');
        } catch (SignatureRequestService.SignatureRequestException e) {
            Assert.isTrue(e.getMessage().contains('investment'), e.getMessage());
        }

        try {
            SignatureRequestService.parseAndValidate(requestJson(invId, new List<Id>(), new List<Object>()));
            Assert.fail('expected empty-contacts failure');
        } catch (SignatureRequestService.SignatureRequestException e) {
            Assert.isTrue(e.getMessage().contains('at least one'), e.getMessage());
        }

        try {
            SignatureRequestService.parseAndValidate(requestJson(invId, new List<Id>{ alphaId },
                new List<Object>{ mergeField('f1', 'Account', 'Name', null) }));
            Assert.fail('expected non-whitelisted-object failure');
        } catch (SignatureRequestService.SignatureRequestException e) {
            Assert.isTrue(e.getMessage().contains('not available'), e.getMessage());
        }

        SignatureRequestModels.SendRequest ok = SignatureRequestService.parseAndValidate(
            requestJson(invId, new List<Id>{ alphaId },
                new List<Object>{ mergeField('f1', 'Investing_Entity__c', 'Name', null) }));
        Assert.areEqual(1, ok.fields.size());
        Assert.areEqual('Name', ok.fields[0].fieldApiName);
    }

    @IsTest
    static void buildTabSpecsAppliesEntityTypeFilterAndValues() {
        Id invId = investmentId();
        Id alphaId = contactByName('Alpha').Id;
        Id betaId = contactByName('Beta').Id;

        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            requestJson(invId, new List<Id>{ alphaId, betaId }, new List<Object>{
                mergeField('fEntityName', 'Investing_Entity__c', 'Name', null),
                mergeField('fRestricted', 'Investing_Entity__c', 'Entity_Type__c',
                    new List<String>{ 'Estate or Trust' }),
                new Map<String, Object>{
                    'clientId' => 'fReqText', 'category' => 'ENTRY', 'entryKind' => 'REQUIRED_TEXT',
                    'label' => 'Required Text', 'page' => 2, 'x' => 10, 'y' => 20 },
                new Map<String, Object>{
                    'clientId' => 'fSig', 'category' => 'RECIPIENT', 'recipientKind' => 'SIGNATURE',
                    'label' => 'Signature', 'page' => 3, 'x' => 30, 'y' => 40 },
                new Map<String, Object>{
                    'clientId' => 'fSigTrust', 'category' => 'RECIPIENT', 'recipientKind' => 'SIGNATURE',
                    'label' => 'Trust Signature', 'page' => 3, 'x' => 30, 'y' => 90,
                    'entityTypes' => new List<String>{ 'Estate or Trust' } }
            }));

        Map<Id, SignatureRequestService.ProspectContext> contexts =
            SignatureRequestService.loadProspectContexts(req, new Set<Id>{ alphaId, betaId });
        SignatureRequestService.ProspectContext alphaCtx = contexts.get(alphaId); // Estate or Trust (most recent)
        SignatureRequestService.ProspectContext betaCtx = contexts.get(betaId);   // Individual

        List<SignatureRequestModels.TabSpec> alphaSpecs = SignatureRequestService.buildTabSpecs(req.fields, alphaCtx);
        List<SignatureRequestModels.TabSpec> betaSpecs = SignatureRequestService.buildTabSpecs(req.fields, betaCtx);

        Assert.areEqual(5, alphaSpecs.size(), 'restricted fields included for matching entity type');
        Assert.areEqual(3, betaSpecs.size(),
            'restricted merge AND restricted signature both skipped for non-matching entity type');

        SignatureRequestModels.TabSpec entityName = alphaSpecs[0];
        Assert.areEqual('TEXT', entityName.kind);
        Assert.isTrue(entityName.readOnly, 'merge tabs are locked');
        Assert.areEqual('Alpha Trust', entityName.value, 'value from most recent position entity');
        Assert.areEqual('fEntityName', entityName.dataLabel);
        Assert.areEqual(72, entityName.x, 'x rounded to integer points');
        Assert.areEqual(101, entityName.y, 'y rounded to integer points');

        SignatureRequestModels.TabSpec restricted = alphaSpecs[1];
        Assert.areEqual('Estate or Trust', restricted.value);

        SignatureRequestModels.TabSpec entry = alphaSpecs[2];
        Assert.areEqual('TEXT', entry.kind);
        Assert.isTrue(entry.required);
        Assert.isFalse(entry.readOnly);

        Assert.areEqual('SIGN_HERE', alphaSpecs[3].kind);
        Assert.areEqual('fSigTrust', alphaSpecs[4].dataLabel,
            'entity-type-restricted signature reaches matching recipients');

        Boolean betaHasTrustSig = false;
        for (SignatureRequestModels.TabSpec spec : betaSpecs) {
            if (spec.dataLabel == 'fSigTrust') {
                betaHasTrustSig = true;
            }
        }
        Assert.isFalse(betaHasTrustSig, 'restricted signature omitted for non-matching recipient');

        List<dfsle.Tab> tabs = SignatureRequestService.toDfsleTabs(alphaSpecs);
        Assert.areEqual(5, tabs.size(), 'every spec maps to a dfsle tab');
    }

    @IsTest
    static void buildTabSpecsSkipsRestrictedForNullEntityType() {
        SignatureRequestService.ProspectContext ctx = new SignatureRequestService.ProspectContext();
        ctx.entityType = null;
        ctx.entityRecord = new Investing_Entity__c(Name = 'X');

        SignatureRequestModels.PlacedField f = new SignatureRequestModels.PlacedField();
        f.clientId = 'f1';
        f.category = 'MERGE';
        f.objectApiName = 'Investing_Entity__c';
        f.fieldApiName = 'Name';
        f.entityTypes = new List<String>{ 'Individual' };
        f.page = 1; f.x = 1; f.y = 1;

        SignatureRequestModels.PlacedField sig = new SignatureRequestModels.PlacedField();
        sig.clientId = 'f2';
        sig.category = 'RECIPIENT';
        sig.recipientKind = 'SIGNATURE';
        sig.entityTypes = new List<String>{ 'Individual' };
        sig.page = 1; sig.x = 1; sig.y = 1;

        List<SignatureRequestModels.TabSpec> specs = SignatureRequestService.buildTabSpecs(
            new List<SignatureRequestModels.PlacedField>{ f, sig }, ctx);
        Assert.areEqual(0, specs.size(), 'null entity type never matches a restriction, any category');
    }

    @IsTest
    static void formatValueCoversTypes() {
        Assert.areEqual('', SignatureRequestService.formatValue(Schema.DisplayType.STRING, null));
        Assert.areEqual('Yes', SignatureRequestService.formatValue(Schema.DisplayType.BOOLEAN, true));
        Assert.areEqual('No', SignatureRequestService.formatValue(Schema.DisplayType.BOOLEAN, false));
        Assert.isTrue(String.isNotBlank(
            SignatureRequestService.formatValue(Schema.DisplayType.DATE, Date.newInstance(2026, 7, 15))));
        Assert.isTrue(String.isNotBlank(
            SignatureRequestService.formatValue(Schema.DisplayType.CURRENCY, (Object) 1234.5)));
        Assert.areEqual('plain', SignatureRequestService.formatValue(Schema.DisplayType.STRING, 'plain'));
    }

    @IsTest
    static void buildEnvelopeUsesGatewayAndFileDocument() {
        FakeGateway fake = new FakeGateway();
        SignatureRequestService.gateway = fake;

        Id invId = investmentId();
        Id alphaId = contactByName('Alpha').Id;
        SignatureRequestModels.SendRequest req = SignatureRequestService.parseAndValidate(
            requestJson(invId, new List<Id>{ alphaId },
                new List<Object>{ mergeField('f1', 'Contact', 'Email', null) }));

        Map<Id, SignatureRequestService.ProspectContext> contexts =
            SignatureRequestService.loadProspectContexts(req, new Set<Id>{ alphaId });

        dfsle.Envelope envelope = SignatureRequestService.buildEnvelope(req, contexts.get(alphaId), null);

        Assert.isNotNull(envelope);
        Assert.areEqual(1, fake.emptyCount, 'gateway created the empty envelope');
    }

    @IsTest
    static void templateHelpersSurviveOpaqueShapes() {
        FakeGateway fake = new FakeGateway();
        SignatureRequestService.gateway = fake;

        Assert.areEqual(0, SignatureRequestService.mapTemplates(null).size());
        Assert.areEqual(0, SignatureRequestService.mapTemplates(fake.getTemplates()).size());
        Assert.isNull(SignatureRequestService.readDocuSignId(null));

        // Envelope with null docuSignId reads safely; with a value it round-trips.
        dfsle.Envelope env = new dfsle.Envelope(null, null, null, null, null, null, null, null, null, null, null, null);
        Assert.isNull(SignatureRequestService.readDocuSignId(env));
        dfsle.Envelope envWithIds = new dfsle.Envelope(
            null, null, dfsle.UUID.parse('33333333-3333-3333-3333-333333333333'),
            null, null, null, null, null, null, null, null, null);
        Assert.areEqual('33333333-3333-3333-3333-333333333333',
            SignatureRequestService.readDocuSignId(envWithIds));

        // Template without recipients -> null role, no throw.
        fake.templateToReturn = new dfsle.Template(null, 'Blank', null, null, null, null, null, null);
        Assert.isNull(SignatureRequestService.resolveTemplateRole('11111111-1111-1111-1111-111111111111'));

        // Template with id + a named role maps and resolves.
        fake.templateToReturn = new dfsle.Template(
            dfsle.UUID.parse('22222222-2222-2222-2222-222222222222'), 'Sub Docs',
            null, null, 'Subject', null,
            new List<dfsle.Recipient>{
                dfsle.Recipient.fromSource('Tester', 't@example.com', null, 'Signer 1', null) },
            null);
        List<SignatureRequestModels.TemplateDoc> mapped =
            SignatureRequestService.mapTemplates(fake.getTemplates());
        Assert.areEqual(1, mapped.size());
        Assert.areEqual('22222222-2222-2222-2222-222222222222', mapped[0].templateId);
        Assert.areEqual('Sub Docs', mapped[0].name);
        Assert.areEqual('Signer 1',
            SignatureRequestService.resolveTemplateRole('22222222-2222-2222-2222-222222222222'));
    }
}
