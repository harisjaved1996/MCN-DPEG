/**
 * Tests for LeadConvertService — the post-convert stamping site.
 *
 * ═══ WHAT THE 2026-08-03 CONVERSION-ENRICHMENT METHODS PIN ═══
 * S1 split the LLM-extracted deal-screening field set BY MEANING: deal-process facts to the
 * Opportunity, physical property facts to the Property__c. Several of the assertions below exist
 * to stop a later "helpful" change from quietly undoing a deliberate decision:
 *   • Property__c.Lot_Size__c must stay NULL — we hold ACRES only and deriving SF from acres is
 *     forbidden by this module's anti-hallucination contract.
 *   • A RANGE-priced lead must leave Asking_Price__c NULL — synthesizing a midpoint would
 *     fabricate a price.
 *   • An out-of-range restricted-picklist value must be DROPPED, not pushed — `update updates` is
 *     all-or-none, so one illegal value would roll back the structural RecordTypeId / Property__c
 *     link for every lead in the chunk.
 *   • The broker OpportunityContactRole must be exactly ONE row — standard conversion already
 *     creates it, so a blind insert would duplicate both the broker and the primary flag.
 *
 * ⚠ NO FLS TEST EXISTS HERE, DELIBERATELY. LeadConvertService writes in SYSTEM MODE and
 * Trigger.new is not FLS-filtered, so a `System.runAs` test asserting "the stamp lands as a
 * non-admin persona" would pass whether or not the FLS grant exists — a test that cannot fail.
 * FLS on these fields is a DISPLAY gate, not a write gate, and is verified manually as a real
 * convert-capable persona (never as an admin, whose FLS on Metadata-API-deployed custom fields is
 * not representative). See agent-output/design-requirements-conversion-enrichment.md §9.4.
 *
 * ⚠ SEVERAL METHODS RE-INVOKE THE SERVICE DIRECTLY on an already-converted Lead. That is the only
 * way to drive states the platform will not produce (an out-of-range picklist value; a second
 * pass over the same converted set). It has one visible side effect worth knowing about: the
 * re-run also builds a SECOND Property, because only the trigger's `justConverted` guard — not
 * the service — makes the stamp fire once. Those tests assert on the Opportunity / the OCR, never
 * on the Property count.
 *
 * ⚠ NO TEST EXERCISES stampBrokerContactRoles' describe-guard SKIP PATH (the early return when
 * `OpportunityContactRole.Role` does not offer 'Broker'), and none can: `activePicklistValues()`
 * reads the LIVE org describe, which is identical in every test context to whatever is actually
 * deployed — there is no seam (unlike `EmailThreadGuardService.treatAllAsMaterialized`) that lets
 * a test force the value to appear absent. As long as the admin-deployed StandardValueSet addition
 * ships, 'Broker' is present in every test run, so the skip branch is only reachable by a deploy
 * that never added the value in the first place — a deploy-order failure, not something this suite
 * can simulate. Confirmed dead-in-test, not merely un-covered; do not add a test that fakes this by
 * asserting against a hardcoded picklist value list instead of the real describe.
 *
 * ⚠ EVERY LEAD CONVERTED HERE MUST CARRY Property_Address__c AND Email (2026-08-04). The Lead
 * validation rule Property_And_Email_Required_To_Convert refuses `Database.convertLead` when either
 * is blank, so a fixture that deliberately empties one of them no longer reaches this service at
 * all — it fails at the conversion with FIELD_CUSTOM_VALIDATION_EXCEPTION. TestDataFactory.createLead
 * supplies both, so the only exposure is a fixture that NULLS one on purpose; there is exactly one
 * such intent in this class and it is handled by
 * blankAddressLeavesTheDealNameAloneAndFallsBackToCompany, which drives the service directly rather
 * than through a conversion. Do not "simplify" that method back into a conversion — it cannot work.
 *
 * @see force-app/main/default/classes/LeadConvertService.cls
 * @see force-app/main/default/classes/OpportunityContactRoleSelector.cls
 * @see force-app/main/default/objects/Lead/validationRules/Property_And_Email_Required_To_Convert.validationRule-meta.xml
 */
@isTest
private class LeadConvertServiceTest {

    private static final Integer BULK_N = 251;

    /**
     * The minimum a Lead must carry to get PAST Property_And_Email_Required_To_Convert. Used by the
     * fixtures whose subject is what happens when everything ELSE is blank — naming it makes it
     * obvious in the assertions below which values are under test and which are gate tax.
     * Kept short so it survives both OPPORTUNITY_NAME_MAX and PROPERTY_NAME_MAX unclipped.
     */
    private static final String GATE_ADDRESS = '5 Gate Row, Austin TX';

    /** Batch size used by the governor-scaling proof; see stampCostDoesNotScaleWithBatchSize. */
    private static final Integer SCALE_N = 50;

    /**
     * Slack allowed between a 1-record and a SCALE_N-record invocation. Deliberately small: the
     * service's own cost is constant (2 SOQL / ≤5 DML — raised from ≤4 in the IR segregation
     * change, which added the Contact/Account record-type stamp), and a change that added ONE
     * query per Lead would show up as +SCALE_N-1, which no plausible tolerance hides.
     */
    private static final Integer SCALE_TOLERANCE = 5;

    private static String convertedStatus() {
        return [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1].MasterLabel;
    }

    private static Opportunity convertLeadOfType(String dealType, String company) {
        Lead l = TestDataFactory.createLead(false);
        l.LastName = 'Tester';
        l.Company = company;
        l.Deal_Type__c = dealType;
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Database.LeadConvertResult res = Database.convertLead(lc);
        System.assert(res.isSuccess(), 'Lead conversion should succeed');
        return [
            SELECT Id, Deal_Type__c, RecordType.DeveloperName
            FROM Opportunity
            WHERE Id = :res.getOpportunityId()
        ];
    }

    /** Standard single conversion (the recipe proven on this org — never setDoNotCreateOpportunity). */
    private static Database.LeadConvertResult convertOne(Lead l) {
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());
        Database.LeadConvertResult res = Database.convertLead(lc);
        System.assert(res.isSuccess(), 'Lead conversion should succeed');
        return res;
    }

    /**
     * Every deal-screening value the extraction pipeline can put on a Lead, set to a distinct
     * recognisable value so a mis-mapped field shows up as the WRONG value rather than as a
     * coincidentally-equal one. Mutates and returns the lead.
     */
    private static Lead withFullDealScreening(Lead l) {
        // Deal-process facts -> Opportunity
        l.Property_Name__c = 'Orion ParkView';
        l.Property_Address__c = '1400 Royal Lane, Dallas TX 75229';
        l.Guidance_Price__c = 7100000;
        l.Guidance_Cap_Rate__c = 6.75;
        l.Offer_Due_Date__c = Date.newInstance(2026, 9, 15);
        l.Sale_Process__c = 'Call for Offers';
        l.Parse_Confidence__c = 'HIGH';
        l.Deal_Room_Link__c = 'https://deals.example.invalid/room/orion';
        l.Listing_Broker_Name__c = 'Kevin Girard';
        l.Listing_Broker_Email__c = 'kevin.girard@example.invalid';
        // Physical property facts -> Property__c
        l.Building_SF__c = 84000;
        l.NOI__c = 512345.67;
        l.Year_Built__c = 1988;
        l.Year_Renovated__c = 2022;
        l.Unit_Count__c = 240;
        l.Occupancy_Pct__c = 88.50;
        l.Lot_Size_Acres__c = 12.34;
        l.WALT_Years__c = 7.5;
        l.ADR__c = 142.75;
        l.Zoning__c = 'C-2 Commercial';
        l.Seller_Entity__c = 'Royal Lane Holdings LP';
        return l;
    }

    /**
     * Re-reads converted Leads with EVERY field the service touches, so a test can hand the same
     * records back to `stampConvertedOpportunities` directly. `oldMap = null` makes the service
     * treat them as just-converted (see its `justConverted` guard).
     *
     * ⚠ ConvertedAccountId was ADDED here 2026-08-10 (IR segregation, Task 5). Without it,
     * stampConvertedPartyRecordTypes' read of l.ConvertedAccountId throws
     * `SObjectException: SObject row was retrieved via SOQL without querying the requested
     * field` for every test that drives the service directly off this helper's output — the
     * live trigger path is unaffected because Trigger.new in an after-update trigger already
     * carries every field.
     *
     * ⚠ RecordTypeId was ADDED here 2026-08-12 for exactly the same reason, one field later:
     * justConvertedByOpportunity now reads l.RecordTypeId to exclude Investor_Onboarding Leads
     * from the whole acquisitions cascade (see LeadConvertService's IR section). That read is
     * deliberately a direct field access rather than a defensive one, so a caller that forgets the
     * field fails LOUDLY here instead of silently running the cascade over an investor's Contact —
     * which means this SELECT is the thing that has to keep up, and that is the intended trade.
     */
    private static List<Lead> reReadForReRun(Set<Id> leadIds) {
        return [
            SELECT Id, Name, Company, Street, City, State, PostalCode, RecordTypeId,
                   IsConverted, ConvertedOpportunityId, ConvertedContactId, ConvertedAccountId,
                   Deal_Type__c, Asset_Type__c, Property_Name__c, Property_Address__c,
                   Guidance_Price__c, Guidance_Price_Low__c, Guidance_Price_High__c,
                   Guidance_Cap_Rate__c, Offer_Due_Date__c, Sale_Process__c, Parse_Confidence__c,
                   Deal_Room_Link__c, Listing_Broker_Name__c, Listing_Broker_Email__c,
                   Placer_AI_Link__c, CoStar_Link__c,
                   Building_SF__c, NOI__c, Year_Built__c, Year_Renovated__c, Unit_Count__c,
                   Occupancy_Pct__c, Lot_Size_Acres__c, WALT_Years__c, ADR__c, Zoning__c,
                   Seller_Entity__c
            FROM Lead
            WHERE Id IN :leadIds
        ];
    }

    private static Set<Id> idsOf(List<SObject> records) {
        return new Map<Id, SObject>(records).keySet();
    }

    private static List<OpportunityContactRole> rolesOn(Id opportunityId) {
        return [
            SELECT Id, OpportunityId, ContactId, Role, IsPrimary
            FROM OpportunityContactRole
            WHERE OpportunityId = :opportunityId
        ];
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 1. PRE-EXISTING BEHAVIOUR — deal type, record type, Property, approver.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void stampsLandDeal() {
        Test.startTest();
        Opportunity o = convertLeadOfType('Land', 'Land Holdings LLC');
        Test.stopTest();
        System.assertEquals('Land', o.Deal_Type__c, 'Deal type should carry to Opportunity');
        System.assertEquals('Land', o.RecordType.DeveloperName, 'Should get the Land record type');
    }

    @isTest
    static void stampsCommercialDeal() {
        Test.startTest();
        Opportunity o = convertLeadOfType('Commercial', 'Commercial Partners Inc');
        Test.stopTest();
        System.assertEquals('Commercial', o.Deal_Type__c, 'Deal type should carry to Opportunity');
        System.assertEquals('Commercial', o.RecordType.DeveloperName, 'Should get the Commercial record type');
    }

    @isTest
    static void createsAndLinksPropertyFromLead() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'CBRE';
        l.Deal_Type__c = 'Commercial';
        l.Property_Address__c = '123 Main St, El Paso, TX';
        l.Asset_Type__c = 'Retail';
        l.Guidance_Price__c = 8200000;
        l.Guidance_Cap_Rate__c = 6.25;
        l.Placer_AI_Link__c = 'https://placer.ai/abc';
        l.CoStar_Link__c = 'https://costar.com/xyz';
        insert l;

        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());

        Test.startTest();
        Database.LeadConvertResult res = Database.convertLead(lc);
        Test.stopTest();
        System.assert(res.isSuccess(), 'Lead conversion should succeed');

        Opportunity o = [SELECT Id, Property__c FROM Opportunity WHERE Id = :res.getOpportunityId()];
        System.assertNotEquals(null, o.Property__c, 'Conversion should create and link a Property');

        Property__c p = [
            SELECT Name, Address__c, Asset_Type__c, Asking_Price__c, Cap_Rate_Asking__c, Placer_URL__c, CoStar_URL__c
            FROM Property__c WHERE Id = :o.Property__c
        ];
        System.assertEquals('123 Main St, El Paso, TX', p.Address__c, 'Address copied from lead');
        System.assertEquals('Retail', p.Asset_Type__c, 'Asset type copied from lead');
        System.assertEquals(8200000, p.Asking_Price__c, 'Asking Price comes from Guidance Price');
        System.assertEquals(6.25, p.Cap_Rate_Asking__c, 'Cap Rate Asking comes from Guidance Cap Rate');
        System.assertEquals('https://placer.ai/abc', p.Placer_URL__c, 'Placer URL copied from lead');
        System.assertEquals('https://costar.com/xyz', p.CoStar_URL__c, 'CoStar URL copied from lead');
    }

    @isTest
    static void stampsConvertingUserAsLeadApprover() {
        // Conversion IS the approval to underwrite: no checkbox gate, and the
        // converting user lands on the deal as Lead Approved By.
        Test.startTest();
        Opportunity o = convertLeadOfType('Commercial', 'Straight Through LLC');
        Test.stopTest();

        Opportunity fresh = [SELECT Lead_Approved_By__c FROM Opportunity WHERE Id = :o.Id];
        System.assertEquals(UserInfo.getUserId(), fresh.Lead_Approved_By__c,
            'Converting user stamped on the Opportunity as the lead approver');
    }

    @isTest
    static void qualifiedNeedsNoApprovalAndIntakeStampsApply() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Gate LLC';
        insert l;

        // No approval gate: Qualified is reachable directly.
        l.Status = 'Qualified';
        update l;

        l = [SELECT Status, First_Seen_Date__c, DPEG_First__c FROM Lead WHERE Id = :l.Id];
        System.assertEquals('Qualified', l.Status, 'Qualified requires no prior approval');
        System.assertNotEquals(null, l.First_Seen_Date__c, 'First Seen stamped on create for all channels');
        System.assertEquals(UserInfo.getUserId(), l.DPEG_First__c, 'DPEG First stamped from the owning user');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 2. S1 — THE SPLIT. Deal-process facts to the Opportunity...
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void stampsDealProcessFieldsOntoOpportunity() {
        Lead l = withFullDealScreening(TestDataFactory.createLead(false));
        l.Company = 'Orion Capital Partners';
        l.Deal_Type__c = 'Commercial';
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Asking_Price__c, Guidance_Price_Low__c, Guidance_Price_High__c,
                   Guidance_Cap_Rate__c, Offer_Due_Date__c, Sale_Process__c, Parse_Confidence__c,
                   Deal_Room_Link__c, Listing_Broker_Name__c, Listing_Broker_Email__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];

        // ⚠ Asking_Price__c is the open-pipeline KPI's aggregation column. Before S1 an email-born
        // deal contributed 0 to it forever; this assertion is what makes that fix load-bearing.
        Assert.areEqual(7100000, o.Asking_Price__c,
            'Opportunity.Asking_Price__c must carry Lead.Guidance_Price__c — it is the column behind '
            + 'OpportunitySelector.aggregateOpenPipeline and selectTopByAskingPrice');
        Assert.areEqual(6.75, o.Guidance_Cap_Rate__c,
            'F1: the cap-rate twin of Asking_Price__c must be stamped too, or the deal shows a price '
            + 'with no cap rate');
        Assert.areEqual(Date.newInstance(2026, 9, 15), o.Offer_Due_Date__c, 'Offer due date carries');
        Assert.areEqual('Call for Offers', o.Sale_Process__c, 'Sale process carries (restricted picklist)');
        Assert.areEqual('HIGH', o.Parse_Confidence__c,
            'Parse confidence carries — it is the analyst\'s "should I trust the rest of this?" signal');
        Assert.areEqual('https://deals.example.invalid/room/orion', o.Deal_Room_Link__c,
            'The broker\'s data-room link carries (distinct from DPEG\'s own OneDrive_Folder_URL__c)');
        Assert.areEqual('Kevin Girard', o.Listing_Broker_Name__c, 'Listing broker name carries');
        Assert.areEqual('kevin.girard@example.invalid', o.Listing_Broker_Email__c, 'Listing broker email carries');
        Assert.isNull(o.Guidance_Price_Low__c,
            'A single stated price leaves the range EMPTY — the prompt fills one or the other, never both');
        Assert.isNull(o.Guidance_Price_High__c, 'Range high stays empty for a single-price deal');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // ...and physical property facts to the Property__c.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void stampsPhysicalFactsOntoProperty() {
        Lead l = withFullDealScreening(TestDataFactory.createLead(false));
        l.Company = 'Meridian Realty Group';
        l.Deal_Type__c = 'Commercial';
        l.Asset_Type__c = 'Retail';
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [SELECT Property__c FROM Opportunity WHERE Id = :res.getOpportunityId()];
        Assert.isNotNull(o.Property__c, 'Conversion still creates and links a Property');

        Property__c p = [
            SELECT Square_Footage__c, Annual_NOI__c, Year_Built__c, Year_Renovated__c,
                   Unit_Count__c, Occupancy_Pct__c, Occupancy_Rate_Market__c, Lot_Size_Acres__c,
                   Lot_Size__c, WALT_Years__c, ADR__c, Zoning__c, Seller_Entity__c
            FROM Property__c WHERE Id = :o.Property__c
        ];

        // Existing Property fields EXTENDED (not duplicated) because their semantics already match.
        Assert.areEqual(84000, p.Square_Footage__c, 'Building SF lands on the existing GLA field');
        Assert.areEqual(512345.67, p.Annual_NOI__c, 'NOI lands on the existing periodic-amount field');
        Assert.areEqual(1988, p.Year_Built__c, 'Year built carries');
        // New Property fields.
        Assert.areEqual(2022, p.Year_Renovated__c, 'Year renovated carries');
        Assert.areEqual(240, p.Unit_Count__c, 'Unit count carries');
        Assert.areEqual(88.50, p.Occupancy_Pct__c, 'The SUBJECT asset\'s stated occupancy carries');
        Assert.areEqual(12.34, p.Lot_Size_Acres__c, 'Lot size in ACRES carries');
        Assert.areEqual(7.5, p.WALT_Years__c, 'WALT carries');
        Assert.areEqual(142.75, p.ADR__c, 'ADR carries');
        Assert.areEqual('C-2 Commercial', p.Zoning__c, 'Zoning carries');
        Assert.areEqual('Royal Lane Holdings LP', p.Seller_Entity__c,
            'Seller entity carries as TEXT — there is no Seller object, so this is deliberately not a lookup');

        // ⚠ THE TWO NO-TOUCH GUARANTEES. Both fields are one plausible-looking line away from being
        // corrupted, and neither corruption would raise an error.
        Assert.isNull(p.Lot_Size__c,
            'Lot_Size__c is SQUARE FEET from the Offering Memorandum and must stay NULL. We hold acres '
            + 'only; SF = acres x 43,560 would DERIVE one number from another (forbidden by this '
            + 'module\'s anti-hallucination contract) and would overwrite an analyst\'s OM figure');
        Assert.isNull(p.Occupancy_Rate_Market__c,
            'Occupancy_Rate_Market__c is the MARKET benchmark (Placer/CoStar lineage). Writing the '
            + 'broker\'s figure into it would corrupt a comparison field — that is why Occupancy_Pct__c '
            + 'exists as a separate field');
    }

    /**
     * The accepted cost of refusing to fabricate a price, made explicit so a future "helpful"
     * midpoint change fails HERE rather than quietly inflating the pipeline-value KPI.
     */
    @isTest
    static void rangePricedLeadLeavesAskingPriceNull() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Zephyr Industrial Trust';
        l.Deal_Type__c = 'Commercial';
        l.Property_Address__c = '55 Range Road, Austin TX';
        // The prompt's own rule: a range fills low/high and leaves guidance_price null.
        l.Guidance_Price__c = null;
        l.Guidance_Price_Low__c = 6900000;
        l.Guidance_Price_High__c = 7400000;
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Asking_Price__c, Guidance_Price_Low__c, Guidance_Price_High__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.areEqual(6900000, o.Guidance_Price_Low__c, 'The range low bound is stamped');
        Assert.areEqual(7400000, o.Guidance_Price_High__c, 'The range high bound is stamped');
        Assert.isNull(o.Asking_Price__c,
            'A range-priced deal MUST leave Asking_Price__c null. Synthesizing a midpoint (or taking '
            + 'the high) would fabricate a price the email never stated — the exact behaviour this '
            + 'module forbids. Such a deal contributes 0 to the pipeline KPI until an analyst fills it');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 3. NAMING — Property__c.Name precedence (S1) and Opportunity.Name (D-f).
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void propertyNamePrefersPropertyNameOverAddress() {
        Lead named = TestDataFactory.createLead(false);
        named.Company = 'Halcyon Asset Advisors';
        named.Property_Name__c = 'Orion ParkView';
        named.Property_Address__c = '1400 Royal Lane, Dallas TX 75229';

        Lead unnamed = TestDataFactory.createLead(false);
        unnamed.Company = 'Sableridge Investments';
        unnamed.Property_Name__c = null;
        unnamed.Property_Address__c = '900 Fallback Way, Houston TX';
        insert new List<Lead>{ named, unnamed };

        Test.startTest();
        Database.LeadConvertResult namedRes = convertOne(named);
        Database.LeadConvertResult unnamedRes = convertOne(unnamed);
        Test.stopTest();

        Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
            SELECT Id, Property__c FROM Opportunity
            WHERE Id IN (:namedRes.getOpportunityId(), :unnamedRes.getOpportunityId())
        ]);
        Property__c namedProperty = [
            SELECT Name, Address__c FROM Property__c
            WHERE Id = :opps.get(namedRes.getOpportunityId()).Property__c
        ];
        Property__c unnamedProperty = [
            SELECT Name, Address__c FROM Property__c
            WHERE Id = :opps.get(unnamedRes.getOpportunityId()).Property__c
        ];

        Assert.areEqual('Orion ParkView', namedProperty.Name,
            'A marketing name now BEATS the address in the Property name precedence — this is the '
            + 'visible behaviour change S1 accepted; existing Properties are not back-filled');
        Assert.areEqual('1400 Royal Lane, Dallas TX 75229', namedProperty.Address__c,
            'The address is still stored on Address__c, so nothing becomes unfindable');
        Assert.areEqual('900 Fallback Way, Houston TX', unnamedProperty.Name,
            'With no marketing name the address is still the fallback — the pre-S1 behaviour');
    }

    @isTest
    static void opportunityNameFromPropertyName() {
        Lead named = TestDataFactory.createLead(false);
        named.Company = 'Cobalt Harbor Group';
        named.Property_Name__c = 'Orion ParkView';
        named.Property_Address__c = '1400 Royal Lane, Dallas TX 75229';

        Lead addressOnly = TestDataFactory.createLead(false);
        addressOnly.Company = 'Windward Peak Realty';
        addressOnly.Property_Name__c = null;
        addressOnly.Property_Address__c = '77 Address Only Blvd, Dallas TX';

        // Property_Name__c is Text(255); Opportunity.Name caps at 120.
        Lead overlong = TestDataFactory.createLead(false);
        overlong.Company = 'Juniper Stone Ventures';
        overlong.Property_Name__c = 'X'.repeat(200);
        insert new List<Lead>{ named, addressOnly, overlong };

        Test.startTest();
        Database.LeadConvertResult namedRes = convertOne(named);
        Database.LeadConvertResult addressRes = convertOne(addressOnly);
        Database.LeadConvertResult overlongRes = convertOne(overlong);
        Test.stopTest();

        Map<Id, Opportunity> opps = new Map<Id, Opportunity>([
            SELECT Id, Name FROM Opportunity
            WHERE Id IN (:namedRes.getOpportunityId(), :addressRes.getOpportunityId(),
                         :overlongRes.getOpportunityId())
        ]);

        Assert.areEqual('Orion ParkView', opps.get(namedRes.getOpportunityId()).Name,
            'D-f: the deal is named after the PROPERTY. Left to the platform it would be named from '
            + 'Lead.Company — "Unknown - Via Email", or after S4 the broker\'s FIRM, which every deal '
            + 'from that firm would share');
        Assert.areEqual('77 Address Only Blvd, Dallas TX', opps.get(addressRes.getOpportunityId()).Name,
            'With no marketing name the address names the deal');
        Assert.areEqual(120, opps.get(overlongRes.getOpportunityId()).Name.length(),
            'Opportunity.Name caps at 120 characters — an over-long property name is clipped, not rejected');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 4. THE RESTRICTED-PICKLIST GUARD — the all-or-none protection.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ WHY THIS TEST RE-INVOKES THE SERVICE INSTEAD OF INSERTING A BAD LEAD: Lead.Sale_Process__c
     * and Lead.Parse_Confidence__c are themselves RESTRICTED and byte-identical to the Opportunity
     * picklists, so no INSERTABLE lead can carry a value the target lacks. The realistic production
     * shape is a value RETIRED from one object and not the other — which is exactly what an
     * in-memory assignment reproduces, because picklist restriction is enforced at DML, not at
     * assignment. Delete the guard in LeadConvertService and this test fails with a DmlException.
     */
    @isTest
    static void unknownPicklistValueIsDroppedNotThrown() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Ashgrove Terminal Partners';
        l.Deal_Type__c = 'Commercial';
        l.Property_Address__c = '900 Guard Way, Houston TX';
        l.Sale_Process__c = 'Auction';
        l.Parse_Confidence__c = 'HIGH';
        insert l;
        Database.LeadConvertResult res = convertOne(l);

        Lead reRun = reReadForReRun(new Set<Id>{ l.Id })[0];
        reRun.Sale_Process__c = 'Retired Sale Process';   // not on the Opportunity picklist
        reRun.Parse_Confidence__c = 'UNKNOWN';            // not on the Opportunity picklist
        reRun.Listing_Broker_Name__c = 'Kevin Girard';    // a NON-picklist field on the same update
        reRun.Offer_Due_Date__c = Date.newInstance(2026, 10, 1);

        Test.startTest();
        LeadConvertService.stampConvertedOpportunities(new List<Lead>{ reRun }, null);
        Test.stopTest();

        Opportunity o = [
            SELECT Sale_Process__c, Parse_Confidence__c, Listing_Broker_Name__c, Offer_Due_Date__c,
                   RecordTypeId, Property__c, Lead_Approved_By__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.isNull(o.Sale_Process__c, 'An out-of-range restricted-picklist value is DROPPED, never pushed');
        Assert.isNull(o.Parse_Confidence__c, 'Same for the second guarded picklist');
        // The point of the guard is not the two nulls — it is that everything ELSE still landed.
        Assert.areEqual('Kevin Girard', o.Listing_Broker_Name__c,
            'The REST of the stamp must still land. `update updates` is all-or-none, so an unguarded '
            + 'illegal picklist value would have rolled back this field — and the structural '
            + 'RecordTypeId / Property__c link with it — for every lead in the chunk');
        Assert.areEqual(Date.newInstance(2026, 10, 1), o.Offer_Due_Date__c, 'And this one');
        Assert.isNotNull(o.RecordTypeId, 'The structural record type survived the guarded write');
        Assert.isNotNull(o.Property__c, 'The structural Property link survived the guarded write');
        Assert.areEqual(UserInfo.getUserId(), o.Lead_Approved_By__c, 'And the approver stamp');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 5. S2 — the primary Broker OpportunityContactRole.
    // ═════════════════════════════════════════════════════════════════════════

    @isTest
    static void createsPrimaryBrokerOpportunityContactRole() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Pinnacle Brokerage Advisors';
        l.Deal_Type__c = 'Commercial';
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        List<OpportunityContactRole> roles = rolesOn(res.getOpportunityId());
        Assert.areEqual(1, roles.size(),
            'EXACTLY ONE role row. Standard conversion already creates a primary OCR with a BLANK '
            + 'Role, so this proves the service UPDATED that row rather than inserting a second '
            + 'broker and a second primary');
        Assert.areEqual('Broker', roles[0].Role, 'The converted Contact is named as the Broker');
        Assert.isTrue(roles[0].IsPrimary, 'and is the primary contact on the deal');
        Assert.areEqual(res.getContactId(), roles[0].ContactId,
            'The role must point at the CONVERTED Contact — the submitting broker');

        // S2b — the same broker must ALSO land on the Broker__c lookup. The contact role alone was
        // invisible in practice: a related list cannot surface in the highlights panel, a compact
        // layout, a list view column or a report column, so nobody could see who the broker was.
        // The two are asserted together on purpose — they must never drift apart.
        Opportunity deal = [
            SELECT Broker__c, Listing_Broker_Email__c FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.areEqual(res.getContactId(), deal.Broker__c,
            'Broker__c mirrors the primary Broker contact role, so the broker is visible as a FIELD');
        Assert.areEqual(roles[0].ContactId, deal.Broker__c,
            'The lookup and the contact role must name the SAME Contact — they must not drift');
    }

    /**
     * Idempotency. In production the trigger's `justConverted` guard means this path fires once per
     * Lead and cannot re-run, so this drives the service directly — which is the only way to prove
     * the OCR WRITE ITSELF is read-then-write rather than relying on that guard.
     */
    @isTest
    static void opportunityContactRoleIsIdempotent() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Everline Property Group';
        l.Deal_Type__c = 'Commercial';
        insert l;
        Database.LeadConvertResult res = convertOne(l);
        Assert.areEqual(1, rolesOn(res.getOpportunityId()).size(), 'Baseline: one role row after conversion');

        Test.startTest();
        LeadConvertService.stampConvertedOpportunities(reReadForReRun(new Set<Id>{ l.Id }), null);
        LeadConvertService.stampConvertedOpportunities(reReadForReRun(new Set<Id>{ l.Id }), null);
        Test.stopTest();

        List<OpportunityContactRole> roles = rolesOn(res.getOpportunityId());
        Assert.areEqual(1, roles.size(),
            'Two further passes over the same converted set must leave the role COUNT unchanged — '
            + 'read-then-write is idempotent by construction, a blind insert would now show 3 rows');
        Assert.areEqual('Broker', roles[0].Role, 'and the role value is unchanged');
        Assert.isTrue(roles[0].IsPrimary, 'and it is still primary');
    }

    /**
     * IR segregation (2026-08-10) — job 5. Database.convertLead does not map record types onto
     * the Contact or Account it creates; without the explicit stamp the converted Contact takes
     * the running user's PROFILE default, which is unverifiable from source (profiles are
     * .forceignore'd) and may be Investor rather than Broker.
     */
    @isTest
    static void conversionStampsBrokerRecordTypesOnContactAndAccount() {
        Lead l = TestDataFactory.createLead(true);

        Test.startTest();
        Database.LeadConvert lc = new Database.LeadConvert();
        lc.setLeadId(l.Id);
        lc.setConvertedStatus(convertedStatus());
        Database.LeadConvertResult res = Database.convertLead(lc);
        Test.stopTest();

        Assert.isTrue(res.isSuccess(), 'Conversion must succeed.');

        Contact c = [SELECT RecordType.DeveloperName FROM Contact WHERE Id = :res.getContactId()];
        Account a = [SELECT RecordType.DeveloperName FROM Account WHERE Id = :res.getAccountId()];

        Assert.areEqual('Broker', c.RecordType.DeveloperName,
            'Conversion does not map Contact record types - without the explicit stamp the converted '
            + 'Contact takes the running user profile default, which may be Investor.');
        Assert.areEqual('Broker_Firm', a.RecordType.DeveloperName,
            'An Account left off Broker_Firm matches no sharing rule once Account OWD is Private.');
    }

    /**
     * The Task 5 bulk claim, pinned directly: 251 converted Leads processed through ONE
     * stampConvertedOpportunities invocation cost the SAME <=5 DML statements a single Lead
     * does — proof that stampConvertedPartyRecordTypes's two new statements are batched once
     * per invocation, never once per record.
     *
     * ⚠ Database.convertLead itself caps a single call's LeadConvert list at 200 (see
     * bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities), so the 251 Leads are
     * converted across two chunks first — outside the measured window — then re-read and driven
     * through the service directly in ONE call, which is the only way to observe a single
     * invocation's cost at this volume without also measuring convertLead's own chunking
     * overhead.
     */
    @isTest
    static void conversionDmlIsConstantAcross251Leads() {
        List<Lead> leads = TestDataFactory.createLeads(BULK_N, true);
        String status = convertedStatus();
        convertChunk(leads, 0, 200, status);
        convertChunk(leads, 200, BULK_N, status);

        List<Lead> reRun = reReadForReRun(idsOf(leads));
        Assert.areEqual(BULK_N, reRun.size(), 'All 251 leads converted ahead of the re-run');

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(reRun, null);
        Integer dmlDelta = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        Assert.isTrue(dmlDelta <= 5,
            'LeadConvertService is pinned at <=5 DML statements, CONSTANT in batch size. It moved '
            + 'from 3 to 5 in the IR segregation change to stamp the converted Contact and Account '
            + 'record types. A number that grows with record count means a statement moved inside a loop.');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 6. NULL SAFETY — the ordinary case for a thin email.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * ⚠ Property_Address__c IS POPULATED ON PURPOSE and is the ONLY extraction field that is (Email
     * comes from TestDataFactory). Property_And_Email_Required_To_Convert refuses a conversion when
     * either is blank, so the thin-email fixture this method used to build can no longer be
     * converted at all. Everything else the pipeline can fill is still empty, which is what this
     * method is about — the "leave the target null" assertions below are untouched.
     *
     * The three claims that genuinely NEEDED a blank address — Opportunity.Name left alone, the
     * Property name falling through to Company, and Property.Address__c staying null — moved intact
     * to blankAddressLeavesTheDealNameAloneAndFallsBackToCompany. They are not dropped, and they are
     * not asserted here against a fixture that can no longer produce them.
     */
    @isTest
    static void blankLeadFieldsLeaveTargetsNull() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Thinmail Holdings';
        l.Deal_Type__c = 'Commercial';
        // Everything the extraction pipeline might have filled is empty — the common case when an
        // email names a broker and nothing else — EXCEPT the address the conversion gate demands.
        l.Property_Name__c = null;
        l.Property_Address__c = GATE_ADDRESS;
        l.Asset_Type__c = null;
        l.Guidance_Price__c = null;
        l.Guidance_Cap_Rate__c = null;
        insert l;

        Test.startTest();
        Database.LeadConvertResult res = convertOne(l);
        Test.stopTest();

        Opportunity o = [
            SELECT Name, Property__c, Asking_Price__c, Guidance_Price_Low__c, Guidance_Price_High__c,
                   Guidance_Cap_Rate__c, Offer_Due_Date__c, Sale_Process__c, Parse_Confidence__c,
                   Deal_Room_Link__c, Listing_Broker_Name__c, Listing_Broker_Email__c
            FROM Opportunity WHERE Id = :res.getOpportunityId()
        ];
        Assert.isNull(o.Asking_Price__c, 'An empty lead leaves the Opportunity money fields null');
        Assert.isNull(o.Guidance_Price_Low__c, 'and the range low');
        Assert.isNull(o.Guidance_Price_High__c, 'and the range high');
        Assert.isNull(o.Guidance_Cap_Rate__c, 'and the cap rate');
        Assert.isNull(o.Offer_Due_Date__c, 'and the offer date');
        Assert.isNull(o.Sale_Process__c, 'and the guarded picklists');
        Assert.isNull(o.Parse_Confidence__c, 'and the second guarded picklist');
        Assert.isNull(o.Deal_Room_Link__c, 'and the deal room link');
        Assert.isNull(o.Listing_Broker_Name__c, 'and the listing broker');
        Assert.isNull(o.Listing_Broker_Email__c, 'and their email');
        Assert.areEqual(GATE_ADDRESS, o.Name,
            'With no property NAME, the deal is named after the address — the second rung of the '
            + 'precedence chain. The third rung (no name and no address, so Name is left alone) is '
            + 'unreachable through a conversion now and is pinned by '
            + 'blankAddressLeavesTheDealNameAloneAndFallsBackToCompany instead');

        Property__c p = [
            SELECT Name, Address__c, Asking_Price__c, Square_Footage__c, Annual_NOI__c, Unit_Count__c,
                   Occupancy_Pct__c, Lot_Size_Acres__c, Lot_Size__c, WALT_Years__c, ADR__c, Zoning__c,
                   Seller_Entity__c, Asset_Type__c
            FROM Property__c WHERE Id = :o.Property__c
        ];
        Assert.areEqual(GATE_ADDRESS, p.Name,
            'and the Property takes the same address as its name when no property name was extracted');
        Assert.areEqual(GATE_ADDRESS, p.Address__c,
            'the address the gate required is still copied onto the Property, not swallowed');
        Assert.isNull(p.Square_Footage__c, 'and no physical facts at all');
        Assert.isNull(p.Annual_NOI__c, 'no NOI');
        Assert.isNull(p.Unit_Count__c, 'no unit count');
        Assert.isNull(p.Occupancy_Pct__c, 'no occupancy');
        Assert.isNull(p.Lot_Size_Acres__c, 'no lot acres');
        Assert.isNull(p.Lot_Size__c, 'and still nothing in the OM square-footage field');
        Assert.isNull(p.WALT_Years__c, 'no WALT');
        Assert.isNull(p.ADR__c, 'no ADR');
        Assert.isNull(p.Zoning__c, 'no zoning');
        Assert.isNull(p.Seller_Entity__c, 'no seller entity');
        Assert.isNull(p.Asset_Type__c, 'and a blank asset type is not forced onto the picklist');
    }

    /**
     * The name-precedence FALLBACK — a lead carrying neither a property name, an address nor a
     * street. Three claims live here, moved verbatim (values and wording) out of
     * blankLeadFieldsLeaveTargetsNull when the conversion gate landed:
     *   1. Opportunity.Name is LEFT ALONE (Name is required; writing null would fail the update);
     *   2. Property.Name falls all the way through to Company;
     *   3. Property.Address__c stays null.
     *
     * ⚠ WHY THIS DRIVES THE SERVICE DIRECTLY INSTEAD OF CONVERTING. Property_And_Email_Required_To_Convert
     * makes a blank Property_Address__c UNCONVERTIBLE, so there is no longer any fixture that reaches
     * this branch through Database.convertLead. The branch is NOT dead code: the rule is enforced
     * only when the org setting "Require Validation for Converted Leads" is on (the rule's own file
     * records that as unverified in the target org and notes it fails OPEN when off), and Broker
     * Protection branch (c) deliberately mints address-less Leads (ARCHITECTURE.md §1). So the
     * fallback still has to be right, and this is the only way left to prove it.
     *
     * The re-invoke pattern (reReadForReRun + oldMap = null) is the one already used by
     * stampCostDoesNotScaleWithBatchSize and opportunityContactRoleIsIdempotent — see the class
     * header's note that a re-run also builds a SECOND Property. That second Property is precisely
     * what this method inspects.
     *
     * The Opportunity.Name reset before the re-run is what makes claim 1 OBSERVABLE: the real
     * conversion had already renamed the deal after GATE_ADDRESS, so without a known sentinel
     * "left alone" and "renamed to the address" would look identical.
     */
    @isTest
    static void blankAddressLeavesTheDealNameAloneAndFallsBackToCompany() {
        Lead l = TestDataFactory.createLead(false);
        l.Company = 'Thinmail Holdings';
        l.Deal_Type__c = 'Commercial';
        l.Property_Name__c = null;
        l.Property_Address__c = GATE_ADDRESS; // gate tax only — blanked again below, in memory
        l.Street = null;
        insert l;

        Database.LeadConvertResult res = convertOne(l);
        Id dealId = res.getOpportunityId();
        update new Opportunity(Id = dealId, Name = 'Thinmail Holdings');

        // The thin-email shape the pipeline really produces: a broker, a company, nothing else.
        List<Lead> reRun = reReadForReRun(new Set<Id>{ l.Id });
        reRun[0].Property_Name__c = null;
        reRun[0].Property_Address__c = null;
        reRun[0].Street = null;

        Test.startTest();
        LeadConvertService.stampConvertedOpportunities(reRun, null);
        Test.stopTest();

        Opportunity o = [SELECT Name, Property__c FROM Opportunity WHERE Id = :dealId];
        Assert.isTrue(o.Name.contains('Thinmail Holdings'),
            'With neither a property name nor an address, Opportunity.Name is LEFT ALONE — the '
            + 'platform-derived name stands rather than being blanked. Name is required, so writing '
            + 'null here would fail the whole update');

        Property__c p = [
            SELECT Name, Address__c FROM Property__c WHERE Id = :o.Property__c
        ];
        Assert.areEqual('Thinmail Holdings', p.Name,
            'The Property name precedence falls all the way through to Company when the lead carries '
            + 'neither a property name, an address nor a street');
        Assert.isNull(p.Address__c, 'No address on the lead means no address on the Property');
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 7. GOVERNOR HEADROOM — the cost must not scale with batch size.
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * THE HIGHEST-VALUE ASSERTION IN THIS CLASS. LeadConvertService's contract is 2 SOQL / ≤5 DML
     * PER INVOCATION regardless of batch size; a change that put one query inside
     * the per-Lead loop must fail here rather than in production.
     *
     * ⚠ WHY A COMPARISON RATHER THAN AN ABSOLUTE BUDGET: the measured window contains the whole
     * Opportunity-update cascade (OpportunityReviewTrigger and anything downstream of it), whose
     * cost is not this service's to pin. Comparing a 1-record invocation with a SCALE_N-record one
     * IN THE SAME TRANSACTION cancels that noise: only per-RECORD growth changes the difference.
     * Linear growth would show as +(SCALE_N - 1); SCALE_TOLERANCE (5) is far below that and far
     * above ordinary cascade variation.
     *
     * ⚠ The counters are read INSIDE the Test.startTest()/stopTest() window on purpose —
     * stopTest() restores the pre-test limit counters, so the same assertion written afterwards
     * would be silently vacuous.
     */
    @isTest
    static void stampCostDoesNotScaleWithBatchSize() {
        List<Lead> one = TestDataFactory.createLeads(1, true);
        List<Lead> many = TestDataFactory.createLeads(SCALE_N, true);
        String status = convertedStatus();
        convertChunk(one, 0, 1, status);
        convertChunk(many, 0, SCALE_N, status);

        List<Lead> oneReRun = reReadForReRun(idsOf(one));
        List<Lead> manyReRun = reReadForReRun(idsOf(many));

        Test.startTest();
        Integer q0 = Limits.getQueries();
        Integer d0 = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(oneReRun, null);
        Integer q1 = Limits.getQueries();
        Integer d1 = Limits.getDmlStatements();
        LeadConvertService.stampConvertedOpportunities(manyReRun, null);
        Integer q2 = Limits.getQueries();
        Integer d2 = Limits.getDmlStatements();
        Test.stopTest();

        Integer oneQueries = q1 - q0;
        Integer manyQueries = q2 - q1;
        Integer oneDml = d1 - d0;
        Integer manyDml = d2 - d1;

        // ⚠ THE ASSERTION IS ON THE GROWTH, NOT ON THE MANY-RECORD TOTAL. Asserting
        // `manyQueries <= <ceiling>` would be "fifty records under a ceiling" — it would pass a
        // service that got quietly more expensive as long as it stayed under the number, and the
        // number itself would be a guess about the whole conversion cascade. Subtracting the
        // 1-record invocation cancels that cascade cost and leaves only what scales.
        Integer queryGrowth = manyQueries - oneQueries;
        Integer dmlGrowth = manyDml - oneDml;

        Assert.isTrue(queryGrowth <= SCALE_TOLERANCE,
            'SOQL must not scale with batch size. Going from 1 record to ' + SCALE_N + ' grew the '
            + 'query cost by ' + queryGrowth + ' (' + oneQueries + ' -> ' + manyQueries + '); the '
            + 'allowed growth is ' + SCALE_TOLERANCE + '. One query per Lead would grow it by '
            + (SCALE_N - 1) + '. The selector read must stay ONE call for the whole converted set');
        Assert.isTrue(dmlGrowth <= SCALE_TOLERANCE,
            'DML must not scale with batch size. Going from 1 record to ' + SCALE_N + ' grew the '
            + 'statement count by ' + dmlGrowth + ' (' + oneDml + ' -> ' + manyDml + '); the '
            + 'allowed growth is ' + SCALE_TOLERANCE + '. The Property insert, the Opportunity '
            + 'update and each contact-role partition are ONE bulk statement each');
        Assert.isTrue(oneQueries >= 2,
            'Sanity: a single invocation still spends its two selector reads (record types + '
            + 'contact roles) — a zero here would mean the measurement, not the service, is broken');
    }

    /**
     * Bulk-safety per .claude/rules/bulk-test-rule.md: 251 lead conversions in
     * one transaction. Database.convertLead caps a single call's LeadConvert
     * list, so 251 is split across two calls (200 + 51) - itself a stronger
     * bulk-safety exercise than a single 251-record DML, since
     * LeadConvertService.stampConvertedOpportunities (and the downstream
     * OpportunityReviewTrigger cascade it feeds) fires twice in one transaction.
     *
     * Extended 2026-08-03 (Conversion Enrichment): the enriched stamp and the broker
     * OpportunityContactRole must both survive that split. The OCR assertion is the sharp one —
     * 251 rows, one per deal, is what a per-INVOCATION read-then-write produces; a per-RECORD one
     * would have exhausted SOQL long before getting here.
     */
    @isTest
    static void bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities() {
        List<Lead> leads = TestDataFactory.createLeads(BULK_N, false);
        for (Integer i = 0; i < leads.size(); i++) {
            leads[i].Deal_Type__c = Math.mod(i, 2) == 0 ? 'Land' : 'Commercial';
            // A representative slice of the enriched field set, one field per target object plus
            // one guarded picklist, so the bulk path exercises all three write shapes.
            leads[i].Building_SF__c = 10000 + i;
            leads[i].Unit_Count__c = 10 + i;
            leads[i].Sale_Process__c = 'Off-Market';
            leads[i].Offer_Due_Date__c = Date.today().addDays(30);
        }
        insert leads;

        String status = convertedStatus();
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        convertChunk(leads, 0, 200, status);
        convertChunk(leads, 200, BULK_N, status);
        Integer queryDelta = Limits.getQueries() - queriesBefore;
        Integer dmlDelta = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // Scaling guard. Read inside the window (stopTest restores the pre-test counters). This is
        // deliberately a SCALING bound, not a tight budget: the window covers the entire conversion
        // cascade, not just this service. A change that spends one query or one DML PER LEAD needs
        // 251 of them — it would blow the platform's own 100/150 ceilings first, and fails here
        // either way. The precise per-invocation contract is pinned by
        // stampCostDoesNotScaleWithBatchSize.
        Assert.isTrue(queryDelta < BULK_N,
            'SOQL for 251 conversions must not scale per-Lead (' + queryDelta + ' queries spent)');
        Assert.isTrue(dmlDelta < BULK_N,
            'DML for 251 conversions must not scale per-Lead (' + dmlDelta + ' statements spent)');

        List<Lead> convertedLeads = [
            SELECT Id, ConvertedOpportunityId, ConvertedContactId
            FROM Lead WHERE Id IN :leads AND IsConverted = true
        ];
        System.assertEquals(BULK_N, convertedLeads.size(), 'All 251 leads convert');

        Set<Id> oppIds = new Set<Id>();
        Set<Id> contactIds = new Set<Id>();
        for (Lead l : convertedLeads) {
            oppIds.add(l.ConvertedOpportunityId);
            contactIds.add(l.ConvertedContactId);
        }
        assertBulkOpportunitiesAndProperties(oppIds);
        assertBulkBrokerRoles(oppIds, contactIds);
    }

    /** 251 Opportunities carry the enriched deal fields; their 251 Properties carry the physical ones. */
    private static void assertBulkOpportunitiesAndProperties(Set<Id> oppIds) {
        List<Opportunity> converted = [
            SELECT Id, Property__c, RecordType.DeveloperName, Lead_Approved_By__c,
                   Asking_Price__c, Sale_Process__c, Offer_Due_Date__c
            FROM Opportunity WHERE Id IN :oppIds
        ];
        System.assertEquals(BULK_N, converted.size(), 'Every converted lead produced its own Opportunity');
        Set<Id> propertyIds = new Set<Id>();
        for (Opportunity o : converted) {
            System.assertNotEquals(null, o.Property__c, 'Every converted deal gets a linked Property');
            System.assertNotEquals(null, o.RecordType.DeveloperName, 'Record type resolved for every deal');
            System.assertEquals(UserInfo.getUserId(), o.Lead_Approved_By__c,
                'Converting user stamped on every deal');
            Assert.isNotNull(o.Asking_Price__c, 'Every deal carries the guidance price as its asking price');
            Assert.areEqual('Off-Market', o.Sale_Process__c, 'The guarded picklist landed on every deal');
            Assert.isNotNull(o.Offer_Due_Date__c, 'and the offer due date');
            propertyIds.add(o.Property__c);
        }

        List<Property__c> properties = [
            SELECT Id, Square_Footage__c, Unit_Count__c, Lot_Size__c
            FROM Property__c WHERE Id IN :propertyIds
        ];
        Assert.areEqual(BULK_N, properties.size(), 'Every converted deal built its own Property');
        for (Property__c p : properties) {
            Assert.isNotNull(p.Square_Footage__c, 'Physical facts carried on every Property');
            Assert.isNotNull(p.Unit_Count__c, 'including the new unit count');
            Assert.isNull(p.Lot_Size__c, 'and the OM square-footage field is never written, at any volume');
        }
    }

    /**
     * The sharp bulk assertion: 251 role rows, not 502. A per-RECORD read-then-write would have
     * exhausted SOQL long before getting here; a blind insert would have doubled the count.
     */
    private static void assertBulkBrokerRoles(Set<Id> oppIds, Set<Id> contactIds) {
        List<OpportunityContactRole> roles = [
            SELECT Id, OpportunityId, ContactId, Role, IsPrimary
            FROM OpportunityContactRole WHERE OpportunityId IN :oppIds
        ];
        Assert.areEqual(BULK_N, roles.size(),
            'EXACTLY 251 role rows — one per deal, not two. The read-then-write updated the row '
            + 'standard conversion created for each Opportunity across BOTH convertLead chunks');
        Set<Id> roleOppIds = new Set<Id>();
        for (OpportunityContactRole r : roles) {
            Assert.areEqual('Broker', r.Role, 'Every role row names the Broker');
            Assert.isTrue(r.IsPrimary, 'and is primary on its deal');
            Assert.isTrue(contactIds.contains(r.ContactId), 'and points at that deal\'s converted Contact');
            roleOppIds.add(r.OpportunityId);
        }
        Assert.areEqual(BULK_N, roleOppIds.size(), 'One role per distinct Opportunity — no doubled-up deals');
    }

    private static void convertChunk(List<Lead> leads, Integer fromIndex, Integer toIndex, String status) {
        List<Database.LeadConvert> converts = new List<Database.LeadConvert>();
        for (Integer i = fromIndex; i < toIndex; i++) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(leads[i].Id);
            lc.setConvertedStatus(status);
            converts.add(lc);
        }
        List<Database.LeadConvertResult> results = Database.convertLead(converts, false);
        for (Database.LeadConvertResult r : results) {
            System.assert(r.isSuccess(), 'Each lead in the bulk chunk should convert successfully');
        }
    }
}
