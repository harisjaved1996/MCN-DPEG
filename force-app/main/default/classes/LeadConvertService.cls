/**
 * Runs on lead conversion (from LeadConvertTrigger). Conversion is the approval to
 * underwrite (no separate lead-approval gate), so the converting user is stamped on
 * the Opportunity as Lead Approved By. Beyond that, five jobs in one transaction:
 *
 *   1. Deal type / record type — carries the lead's Deal Type onto the new
 *      Opportunity and sets the matching Opportunity record type (Land or
 *      Commercial) so the deal lands on the correct sales path. Standard
 *      conversion doesn't translate a custom picklist into the record-type
 *      choice, so we apply it here.
 *
 *   2. Property creation — standard conversion only ever creates the
 *      Account, Contact, and Opportunity (all standard objects); it never
 *      creates the custom Property. So we create the Property the deal is about
 *      and link it to the Opportunity (Opportunity.Property__c), copying the
 *      seller's asking price and cap rate (from the lead's Guidance fields)
 *      plus the address, asset type, and Placer/CoStar links carried on the lead.
 *
 *   3. CONVERSION ENRICHMENT (S1, 2026-08-03) — the deal-screening field set the
 *      Broker-Protection extraction pipeline writes onto the Lead used to DIE at
 *      conversion: the Opportunity arrived nearly empty. Conversion now SPLITS that
 *      set by meaning — DEAL-PROCESS facts (guidance range, offer due date, sale
 *      process, deal room, listing broker, parse confidence) go to the Opportunity;
 *      PHYSICAL PROPERTY facts (SF, NOI, units, occupancy, year built/renovated,
 *      lot acres, WALT, ADR, zoning, seller entity) go to the Property__c. Neither
 *      object gets the other half — that split IS the design, not an oversight.
 *
 *   4. BROKER CONTACT ROLE (S2, 2026-08-03) — the submitting broker becomes visible
 *      on the deal as a primary OpportunityContactRole with Role = 'Broker'.
 *
 *   5. BROKER RECORD TYPE STAMP (IR segregation, 2026-08-10) — Database.convertLead does NOT
 *      map record types onto the Contact or the Account it creates; they take whatever is
 *      default for the RUNNING USER'S PROFILE, which is unverifiable from source (profiles are
 *      .forceignore'd in this repo) and can differ per persona. This stamps Contact.Broker and
 *      Account.Broker_Firm deterministically, so the converted Account always lands on the
 *      record type the post-OWD-flip sharing rules key on — see stampConvertedPartyRecordTypes.
 *
 * ═══ 🔴 INVESTOR RELATIONS LEADS ARE EXCLUDED FROM ALL FIVE JOBS (2026-08-12) ═══
 * justConvertedByOpportunity SKIPS any Lead on the `Investor_Onboarding` record type, so an IR
 * conversion reaches none of the work above. This guard is NOT defensive tidying — it is the only
 * thing protecting the IR/Acquisitions segregation boundary, and it replaced a protection that was
 * accidental.
 *
 * WHAT CHANGED. InvestorLeadConvertService converts an IR Lead onto a pre-existing investor
 * Contact and must leave no Opportunity behind. It used to suppress the Opportunity with
 * Database.LeadConvert.setDoNotCreateOpportunity(true), which meant ConvertedOpportunityId stayed
 * null and this method's `if (oppToLead.isEmpty()) return;` early return did the protecting — by
 * side effect, not by intent. That flag does not work in this org (it makes convertLead return
 * UNKNOWN_EXCEPTION for every Lead — see LeadConvertActionService's header and
 * LeadConvertActionServiceTest lines 11-14), so IR now lets the Opportunity be created and DELETES
 * it afterwards. The early return therefore no longer fires for IR, and without this guard every
 * job above would run on an investor.
 *
 * WHY IT MATTERS MOST FOR JOB 5. createProperties, buildOpportunityUpdates and
 * stampBrokerContactRoles all write to records IR throws away seconds later (the Opportunity and
 * its temporary Account) — wrong, but self-cleaning. stampConvertedPartyRecordTypes is different:
 * it writes RecordTypeId = Contact.Broker onto the investor's REAL, DURABLE Contact, which
 * survives. That is a silent re-classification of an investor as a broker, and because Contact OWD
 * is ControlledByParent and the sharing rules key on record type, it is a visibility change, not a
 * cosmetic one.
 *
 * ⚠ THE RECORD TYPE IS RESOLVED BY DEVELOPER NAME AT RUNTIME, AND DELIBERATELY NOT
 * isAvailable()-GUARDED — unlike recordTypeId() below, which serves a WRITE. This one serves an
 * EXCLUSION: whether the running user may USE the Investor_Onboarding record type has nothing to
 * do with whether a Lead already carries it, and folding isAvailable() in here would silently
 * re-open the cascade for exactly the personas least likely to notice. An org with no such record
 * type resolves it to null and the guard is inert, so Acquisitions-only orgs behave exactly as
 * before. It is a describe, so it costs no SOQL and the 2-SOQL contract above is unchanged.
 *
 * ⚠ IT READS Lead.RecordTypeId DIRECTLY, so a caller handing this method Leads queried WITHOUT
 * that field gets a loud SObjectException rather than a silent segregation breach. Trigger.new
 * always carries it; the one direct caller in the test suite selects it explicitly (see
 * LeadConvertServiceTest.reReadForReRun, which took the same treatment for ConvertedAccountId on
 * 2026-08-10).
 *
 * ═══ THE OCR IS A READ-THEN-WRITE, NEVER A BLIND INSERT ═══
 * ⚠ STANDARD LEAD CONVERSION ALREADY CREATES AN OpportunityContactRole for the converted
 * Contact — IsPrimary = true, Role BLANK. Inserting our own row would therefore leave the
 * deal with TWO rows for one Contact and a second primary (Salesforce permits one primary
 * per Opportunity, so the insert either demotes the platform's row or fails; either way the
 * deal ends up wrong). So we read the existing rows through OpportunityContactRoleSelector
 * and UPDATE the matching (Opportunity, Contact) row, inserting only when none exists. That
 * is correct whether or not the platform creates the row — it does not depend on undocumented
 * conversion behaviour — and it is naturally idempotent if this path ever re-runs.
 *
 * ═══ BULK SHAPE IS A CONTRACT: 2 SOQL, ≤5 DML, CONSTANT — WAS ≤4, RAISED 2026-08-10 ═══
 *   SOQL 1 — RecordTypeSelector (Land / Commercial)
 *   SOQL 2 — OpportunityContactRoleSelector (the rows conversion already created)
 *   DML  1 — Database.insert(properties, false)
 *   DML  2 — update updates                       (all-or-none, deliberately — see below)
 *   DML  3 — Database.update(roleUpdates, false)  ┐ the contact-role write, PARTITIONED.
 *   DML  4 — Database.insert(roleInserts, false)  ┘ Each is isEmpty()-guarded, and standard
 *            conversion always creates the role row, so the ORDINARY case is all-updates and
 *            spends exactly ONE statement here. A batch mixing deals that have a
 *            conversion-created role with deals that do not would spend both. That mixed batch
 *            is not reachable through this path (conversion behaves uniformly).
 *   DML  5 — Database.update(contactUpdates, false)  (IR segregation, 2026-08-10) — stamps
 *            Contact.Broker onto every converted Contact in the chunk, ONE statement.
 *   DML  6 — Database.update(accountUpdates, false)  (IR segregation, 2026-08-10) — stamps
 *            Account.Broker_Firm onto every DISTINCT converted Account in the chunk, ONE
 *            statement. "Distinct" matters here: several Leads can converge on ONE Account
 *            (LeadConvertMatchService reusing an existing broker firm), and a duplicate Id in
 *            one update statement throws DUPLICATE_VALUE — see stampConvertedPartyRecordTypes.
 *
 *   Both DML 5 and DML 6 are isEmpty()-guarded and CONSTANT IN BATCH SIZE — one statement for
 *   every converted Contact in the chunk, one for every distinct converted Account, never one
 *   per record. They are never both absent (every conversion produces a Contact and an
 *   Account), so the honest worst case actually reachable through this path is DML 1, 2, one of
 *   {3 or 4}, 5, 6 — five statements. The class-level contract is therefore 2 SOQL / ≤5 DML.
 *
 *   ⚠ WHY NOT ONE upsert: partitioning costs one conditional statement and removes an unknown.
 *   insert and update on OpportunityContactRole are certainly supported — the platform creates
 *   and edits these rows itself during conversion — whereas upsert support on this standard
 *   junction is not something this codebase has ever exercised. A runtime DML failure here does
 *   not fail politely: it is raised inside a Lead after-update trigger and takes the whole
 *   conversion with it.
 *
 * Constant regardless of batch size; nothing here queries or writes inside a loop. Picklist
 * getDescribe() calls are DESCRIBES, not queries, and consume no query limit.
 * LeadConvertServiceTest.bulkConversion251LeadsCreatesPropertiesAndStampsOpportunities drives
 * 251 conversions in two convertLead chunks — so this service fires TWICE in one transaction
 * — and asserts the per-invocation bound. A future change that adds one query per Lead must
 * fail there, not in production.
 *
 * ═══ WHY EVERY RESTRICTED PICKLIST WRITE IS DESCRIBE-GUARDED ═══
 * `update updates` is ALL-OR-NONE and stays that way: the structural fields (RecordTypeId,
 * Property__c link, Lead_Approved_By__c) must land or the conversion is broken. But picklist
 * values bypass the compile checker — a code-first deploy goes green and then throws at
 * runtime — so ONE illegal value on ONE Lead would roll back the stamping for EVERY Lead in
 * the chunk, structural fields included. activePicklistValues() removes that failure mode at
 * source by dropping any value the target picklist does not actually offer, which keeps the
 * all-or-none guarantee affordable. The Property insert keeps Database.insert(..., false) for
 * the same reason it always had it: one bad Property must never roll back the conversion.
 *
 * ═══ FLS POSTURE — READ THIS BEFORE ASSUMING A BLANK FIELD IS A FAILED STAMP ═══
 * This service's DML runs in SYSTEM MODE and Trigger.new is not FLS-filtered, so a missing FLS
 * grant does NOT block the stamp — the data lands. FLS is required only so the persona can SEE
 * the values; without it the highlight panel renders blank, silently. Verify as a real persona,
 * never as an admin (a System Administrator has no FLS on Metadata-API-deployed custom fields —
 * ARCHITECTURE.md §2). A blank field for the persona means a missing FLS grant, not a failed
 * stamp: query the row directly to tell the two apart.
 *
 * @see force-app/main/default/classes/OpportunityContactRoleSelector.cls
 * @see agent-output/design-requirements-conversion-enrichment.md (S1-S4, D-a..D-g)
 */
public with sharing class LeadConvertService {

    /** OpportunityContactRole.Role value identifying the submitting broker on a deal (S2). */
    private static final String BROKER_ROLE = 'Broker';

    /**
     * The Lead record type owned by Investor Relations. Every Lead carrying it is excluded from
     * this entire service — see the IR section of the class header for why.
     */
    private static final String IR_LEAD_RECORD_TYPE = 'Investor_Onboarding';

    /** Opportunity.Name is a Text field, max 120 characters. */
    private static final Integer OPPORTUNITY_NAME_MAX = 120;

    /** Property__c.Name is a Text field, max 80 characters. */
    private static final Integer PROPERTY_NAME_MAX = 80;

    // ── ACTIVE VALUES OF EVERY RESTRICTED PICKLIST THIS CLASS WRITES ────────────────────────────
    // Resolved once per transaction and reused. getDescribe() is a DESCRIBE, not a query — it
    // consumes no SOQL limit — so the memoization is to keep the per-record stamping methods free
    // of picklist plumbing, not to save a limit. Holding them here rather than threading them
    // through every method as parameters is what keeps buildProperty / applyDealFields about the
    // record they are stamping.
    private static Set<String> assetTypeValuesCache;
    private static Set<String> saleProcessValuesCache;
    private static Set<String> parseConfidenceValuesCache;
    private static Set<String> contactRoleValuesCache;

    // The Investor_Onboarding Lead record type Id. Memoized with a separate "resolved" flag
    // because null is a LEGITIMATE answer (an org without the IR record type), not a cache miss —
    // without the flag every invocation in such an org would re-describe forever.
    private static Id irLeadRecordTypeIdCache;
    private static Boolean irLeadRecordTypeResolved = false;

    /** Active values on Property__c.Asset_Type__c. */
    private static Set<String> assetTypeValues() {
        if (assetTypeValuesCache == null) {
            assetTypeValuesCache = activePicklistValues(Property__c.Asset_Type__c);
        }
        return assetTypeValuesCache;
    }

    /** Active values on Opportunity.Sale_Process__c. */
    private static Set<String> saleProcessValues() {
        if (saleProcessValuesCache == null) {
            saleProcessValuesCache = activePicklistValues(Opportunity.Sale_Process__c);
        }
        return saleProcessValuesCache;
    }

    /** Active values on Opportunity.Parse_Confidence__c. */
    private static Set<String> parseConfidenceValues() {
        if (parseConfidenceValuesCache == null) {
            parseConfidenceValuesCache = activePicklistValues(Opportunity.Parse_Confidence__c);
        }
        return parseConfidenceValuesCache;
    }

    /** Active values on OpportunityContactRole.Role (the ContactRole standard value set). */
    private static Set<String> contactRoleValues() {
        if (contactRoleValuesCache == null) {
            contactRoleValuesCache = activePicklistValues(OpportunityContactRole.Role);
        }
        return contactRoleValuesCache;
    }

    /**
     * The Id of the `Investor_Onboarding` Lead record type, or null when this org has no such
     * record type. Resolved by DEVELOPER NAME through a describe — never a hardcoded Id, so this
     * repo deploys to any org — and it costs no SOQL, so the class's 2-SOQL contract is unchanged.
     *
     * 🔴 DELIBERATELY NOT isAvailable()-GUARDED, unlike recordTypeId() below. That helper feeds a
     * WRITE, where an unavailable record type would fail the DML, so skipping it is correct there.
     * This one feeds an EXCLUSION: whether the RUNNING USER may use the IR record type says
     * nothing about whether the LEAD already carries it. Adding isAvailable() here would make an
     * acquisitions persona (or any principal the IR record type is not assigned to) silently run
     * the full cascade over an investor's Contact — the exact failure this guard exists to stop.
     */
    private static Id irLeadRecordTypeId() {
        if (!irLeadRecordTypeResolved) {
            Schema.RecordTypeInfo info = Lead.SObjectType.getDescribe()
                .getRecordTypeInfosByDeveloperName()
                .get(IR_LEAD_RECORD_TYPE);
            irLeadRecordTypeIdCache = (info == null) ? null : info.getRecordTypeId();
            irLeadRecordTypeResolved = true;
        }
        return irLeadRecordTypeIdCache;
    }

    /**
     * Called from the Lead after-update trigger. For each lead that just
     * converted (and created an Opportunity): build its Property, stamp the
     * Opportunity's Property link / Deal Type / RecordTypeId plus the deal-process
     * field set, and put the converted Contact on the deal as the primary Broker.
     */
    public static void stampConvertedOpportunities(List<Lead> newLeads, Map<Id, Lead> oldMap) {
        Map<Id, Lead> oppToLead = justConvertedByOpportunity(newLeads, oldMap);
        if (oppToLead.isEmpty()) {
            return;
        }
        // 1. Build one Property per converted deal and link it back to its Opportunity.  [DML 1]
        Map<Id, Id> oppToPropertyId = createProperties(oppToLead);
        // 2. Stamp every Opportunity: structural fields plus the deal-process set.  [SOQL 1, DML 2]
        List<Opportunity> updates = buildOpportunityUpdates(oppToLead, oppToPropertyId);
        update updates;
        // 3. Put the converted Contact on the deal as the primary Broker.  [SOQL 2, DML 3/4]
        stampBrokerContactRoles(oppToLead);
        // 4. Stamp the converted Contact and Account with their broker record types.  [DML 5, DML 6]
        stampConvertedPartyRecordTypes(oppToLead.values());
    }

    /**
     * The leads that just converted in this transaction (IsConverted false -> true) AND produced
     * an Opportunity, keyed by that Opportunity. The false->true edge is what makes the stamp fire
     * exactly once per lead, so nothing downstream needs its own re-entry guard.
     *
     * 🔴 INVESTOR RELATIONS LEADS ARE EXCLUDED HERE, AND THIS IS THE WHOLE OF THAT GUARD. Every
     * other method in this class consumes the map this one returns, so one skip keeps an IR
     * conversion out of all five jobs — including the Contact record-type overwrite that would
     * otherwise land permanently on the investor's real Contact. See the IR section of the class
     * header for the full argument; note especially that an IR conversion now DOES carry a
     * ConvertedOpportunityId (InvestorLeadConvertService deletes that Opportunity moments later),
     * so the `!= null` test below no longer excludes it and the record type is the only signal
     * left.
     */
    private static Map<Id, Lead> justConvertedByOpportunity(List<Lead> newLeads, Map<Id, Lead> oldMap) {
        Id irRecordTypeId = irLeadRecordTypeId();
        Map<Id, Lead> oppToLead = new Map<Id, Lead>();
        for (Lead l : newLeads) {
            // Reads Lead.RecordTypeId directly on purpose: a caller that queried Leads without it
            // gets a loud SObjectException rather than a silent segregation breach.
            if (irRecordTypeId != null && irRecordTypeId == l.RecordTypeId) {
                continue;
            }
            Lead prior = (oldMap == null) ? null : oldMap.get(l.Id);
            Boolean justConverted = l.IsConverted && (prior == null || !prior.IsConverted);
            if (justConverted && l.ConvertedOpportunityId != null) {
                oppToLead.put(l.ConvertedOpportunityId, l);
            }
        }
        return oppToLead;
    }

    /**
     * Inserts one Property per converted deal and returns Opportunity Id -> new Property Id for
     * the deals whose insert succeeded.
     *
     * allOrNone = false: a single bad Property must never roll back the whole conversion. The cost
     * is that a failed row simply leaves Opportunity.Property__c null (and with it the
     * Property_Address__c formula blank) rather than raising — deliberate, and the same posture
     * the class has had since it was written.
     */
    private static Map<Id, Id> createProperties(Map<Id, Lead> oppToLead) {
        List<Property__c> properties = new List<Property__c>();
        List<Id> propertyOppIds = new List<Id>(); // parallel to `properties`
        for (Id oppId : oppToLead.keySet()) {
            properties.add(buildProperty(oppToLead.get(oppId)));
            propertyOppIds.add(oppId);
        }
        Map<Id, Id> oppToPropertyId = new Map<Id, Id>();
        Database.SaveResult[] saves = Database.insert(properties, false);
        for (Integer i = 0; i < saves.size(); i++) {
            if (saves[i].isSuccess()) {
                oppToPropertyId.put(propertyOppIds[i], saves[i].getId());
            }
        }
        return oppToPropertyId;
    }

    /**
     * One update record per converted Opportunity: the STRUCTURAL fields (approver, Property link,
     * deal type, record type) plus the deal-process field set. Returned rather than written so the
     * caller keeps the single `update` statement visible at the top level — that statement is
     * all-or-none by design, which is why every picklist write below it is describe-guarded.
     */
    private static List<Opportunity> buildOpportunityUpdates(
        Map<Id, Lead> oppToLead,
        Map<Id, Id> oppToPropertyId
    ) {
        Map<String, Id> rtByName = new Map<String, Id>();
        for (RecordType rt : RecordTypeSelector.selectByObjectAndDeveloperNames(
                'Opportunity', new Set<String>{ 'Land', 'Commercial' })) {
            rtByName.put(rt.DeveloperName, rt.Id);
        }

        List<Opportunity> updates = new List<Opportunity>();
        for (Id oppId : oppToLead.keySet()) {
            Lead l = oppToLead.get(oppId);
            Opportunity o = new Opportunity(Id = oppId);
            // Conversion IS the approval to underwrite: the converting user is the approver.
            o.Lead_Approved_By__c = UserInfo.getUserId();
            // S2b (2026-08-05) — mirror the submitting broker onto a LOOKUP as well as the
            // OpportunityContactRole created below. The role alone was invisible in practice: a
            // contact role is a related list, so it cannot appear in the highlights panel, a
            // compact layout, a list view column or a report column on the Opportunity. Riding on
            // this existing loop keeps the class's 2-SOQL / 3-DML contract EXACTLY as documented in
            // the header — the value is already on the Lead, so this adds no query and no
            // statement. ⚠ This is the SUBMITTING broker; the OM's listing broker is a different
            // person and lives in Listing_Broker_Name__c / Listing_Broker_Email__c (set by
            // applyDealFields below). Do not merge the two.
            if (l.ConvertedContactId != null) {
                o.Broker__c = l.ConvertedContactId;
            }
            if (oppToPropertyId.containsKey(oppId)) {
                o.Property__c = oppToPropertyId.get(oppId);
            }
            if (String.isNotBlank(l.Deal_Type__c)) {
                o.Deal_Type__c = l.Deal_Type__c;
                Id rtId = rtByName.get(l.Deal_Type__c); // dealType is 'Land' or 'Commercial'
                if (rtId != null) {
                    o.RecordTypeId = rtId;
                }
            }
            applyDealFields(o, l);
            updates.add(o);
        }
        return updates;
    }

    /**
     * Copies the lead's DEAL-PROCESS field set onto the Opportunity (S1). The physical
     * property facts deliberately do NOT come here — they go to the Property__c in
     * buildProperty. Every target field mirrors its Lead source's type, length, precision
     * and scale exactly, and InboundEmailFieldUtil already clipped the Lead values at the
     * email boundary, so nothing needs re-clipping here.
     *
     * Every field on a freshly created Opportunity is empty at this instant, so there is no
     * "don't clobber the analyst" branch — adding one would be untestable dead code today and
     * would mask a real bug tomorrow.
     */
    private static void applyDealFields(Opportunity o, Lead l) {
        // ⚠ Asking_Price__c is the aggregation column behind OpportunitySelector
        // .aggregateOpenPipeline (open-pipeline value KPI) and the ordering key of
        // selectTopByAskingPrice. Stamping it makes email-born deals count toward both for
        // the first time — correct, but a visible jump on the next dashboard refresh.
        o.Asking_Price__c = l.Guidance_Price__c;
        // A RANGE-PRICED DEAL LEAVES Asking_Price__c NULL, DELIBERATELY. The extraction prompt's
        // own rule fills guidance_price_low/high and leaves guidance_price null for a range, and
        // synthesizing a midpoint here would FABRICATE a price — the exact behaviour this module
        // forbids everywhere else. Such a deal contributes 0 to the pipeline KPI until an analyst
        // fills it in. Accepted and pinned by LeadConvertServiceTest.
        o.Guidance_Price_Low__c = l.Guidance_Price_Low__c;
        o.Guidance_Price_High__c = l.Guidance_Price_High__c;
        // F1 (approved at Gate 1, 2026-08-03): the cap-rate twin of Asking_Price__c. Without it
        // the deal shows a price and no cap rate — an asymmetric pair that reads as a defect.
        o.Guidance_Cap_Rate__c = l.Guidance_Cap_Rate__c;
        o.Offer_Due_Date__c = l.Offer_Due_Date__c;
        o.Deal_Room_Link__c = l.Deal_Room_Link__c;
        o.Listing_Broker_Name__c = l.Listing_Broker_Name__c;
        o.Listing_Broker_Email__c = l.Listing_Broker_Email__c;
        // Restricted picklists — see the class header. An unknown value is DROPPED, never pushed.
        o.Sale_Process__c = picklistValueOrNull(l.Sale_Process__c, saleProcessValues());
        o.Parse_Confidence__c = picklistValueOrNull(l.Parse_Confidence__c, parseConfidenceValues());

        // D-f (approved at Gate 1, 2026-08-03) — NAME THE DEAL AFTER THE PROPERTY.
        // The platform derives Opportunity.Name from Lead.Company, which for an email-born deal
        // is either 'Unknown - Via Email' or (after the S4 prompt rule) the broker's FIRM — so
        // every deal from one firm would share one plausible-looking name. Naming from the
        // property makes the deal identifiable. Post-convert only: LeadConvertActionService and
        // Database.LeadConvert.setOpportunityName are untouched. When the lead carries neither a
        // property name nor an address we leave Name unassigned, which preserves whatever the
        // platform derived rather than blanking a required field.
        String dealName = clip(
            firstNonBlank(new List<String>{ l.Property_Name__c, l.Property_Address__c }),
            OPPORTUNITY_NAME_MAX
        );
        if (dealName != null) {
            o.Name = dealName;
        }
    }

    /**
     * Builds (does not insert) the Property for a converted lead, copying the fields the
     * lead carries — the address block, the seller's asking terms, the market links, and
     * (S1) the PHYSICAL property facts the extraction pipeline pulled from the email.
     * Asset type is only set when the lead's value exists on Property's restricted picklist,
     * so an unexpected value can't fail the insert.
     */
    private static Property__c buildProperty(Lead l) {
        String address = String.isNotBlank(l.Property_Address__c) ? l.Property_Address__c : l.Street;
        // NAME PRECEDENCE (S1): a marketing name beats the address. Previously the address always
        // won, so a named asset converted as "1400 Royal Lane, Dallas TX" instead of "Orion
        // ParkView". The address is still on Address__c and on the Property tab, so nothing
        // becomes unfindable — but conversion-born Property names DO read differently from here
        // on, and existing records are deliberately not back-filled.
        String name = firstNonBlank(new List<String>{
            l.Property_Name__c, l.Property_Address__c, l.Street, l.Company, l.Name
        });
        if (name == null) {
            name = 'Property';
        }
        name = clip(name, PROPERTY_NAME_MAX);

        Property__c p = new Property__c();
        p.Name = name;
        p.Address__c = address;
        p.City__c = l.City;
        p.State__c = l.State;
        p.Zip__c = l.PostalCode;
        // The seller's stated asking terms carried on the lead become the Property's asking terms.
        p.Asking_Price__c = l.Guidance_Price__c;
        p.Cap_Rate_Asking__c = l.Guidance_Cap_Rate__c;
        p.Placer_URL__c = l.Placer_AI_Link__c;
        p.CoStar_URL__c = l.CoStar_Link__c;
        p.Asset_Type__c = picklistValueOrNull(l.Asset_Type__c, assetTypeValues());

        // ── S1: physical property facts, carried from the lead ──────────────────────────────
        // Existing Property fields whose semantics already match the lead's, extended rather
        // than duplicated (Square_Footage__c is documented as building GLA; Annual_NOI__c is the
        // §1 rule-5 periodic-amount name for NOI).
        p.Square_Footage__c = l.Building_SF__c;
        p.Annual_NOI__c = l.NOI__c;
        p.Year_Built__c = l.Year_Built__c;
        // New Property fields mirroring their lead sources exactly.
        p.Unit_Count__c = l.Unit_Count__c;
        p.Occupancy_Pct__c = l.Occupancy_Pct__c;   // the SUBJECT asset's stated occupancy —
                                                   // never Occupancy_Rate_Market__c, which is the
                                                   // Placer/CoStar market benchmark.
        p.Year_Renovated__c = l.Year_Renovated__c;
        p.Lot_Size_Acres__c = l.Lot_Size_Acres__c;
        p.WALT_Years__c = l.WALT_Years__c;
        p.ADR__c = l.ADR__c;
        p.Zoning__c = l.Zoning__c;
        p.Seller_Entity__c = l.Seller_Entity__c;
        // ⚠ NEVER WRITE Property__c.Lot_Size__c HERE. It is SQUARE FEET, entered from the
        // Offering Memorandum; we hold ACRES only (LLMExtractionParser canonicalizes lot_size_sf
        // into acres and stores nothing else). Computing SF = acres x 43,560 would derive one
        // number from another — forbidden by this module's anti-hallucination contract — and
        // would overwrite an analyst's OM figure with a machine estimate.
        return p;
    }

    /**
     * S2 — put each converted Contact on its new Opportunity as the primary Broker.
     *
     * READ-THEN-WRITE, never a blind insert: standard conversion has already created a primary
     * OpportunityContactRole for this Contact with a blank Role (see the class header). One
     * selector read for the whole converted set, then ONE bulk statement per partition —
     * SOQL 2 of 2, DML 3 (≤4), constant regardless of batch size. The partition is deliberate
     * and is explained in the class header: upsert would be one statement instead of two, but
     * its support on this standard junction is the one unknown in this method, and a DML failure
     * raised inside a Lead after-update trigger rolls back the entire conversion.
     *
     * The 'Broker' role value is DESCRIBE-GUARDED for the same reason the field picklists are:
     * OpportunityContactRole.Role is driven by the ContactRole standard value set, so a value
     * missing from the target org would throw at runtime — and here that would roll back the
     * whole conversion, not just the role. When the value is absent we skip the step entirely
     * (no read, no write) and conversion proceeds untouched; the visible symptom is a broker with
     * no role on the Contact Roles list, which is exactly what the persona UAT checks.
     */
    private static void stampBrokerContactRoles(Map<Id, Lead> oppToLead) {
        if (!contactRoleValues().contains(BROKER_ROLE)) {
            return;
        }
        Map<Id, Id> oppToContactId = convertedContactByOpportunity(oppToLead);
        if (oppToContactId.isEmpty()) {
            return;
        }
        Map<String, OpportunityContactRole> existingByPair = existingRolesByPair(oppToContactId.keySet());

        // PARTITION by whether conversion already left us a row. Doing this in the loop — rather
        // than handing one mixed list to upsert — is what keeps every DML statement below an
        // operation the platform certainly supports on this junction.
        List<OpportunityContactRole> roleUpdates = new List<OpportunityContactRole>();
        List<OpportunityContactRole> roleInserts = new List<OpportunityContactRole>();
        for (Id oppId : oppToContactId.keySet()) {
            Id contactId = oppToContactId.get(oppId);
            OpportunityContactRole prior = existingByPair.get(pairKey(oppId, contactId));
            if (prior == null) {
                roleInserts.add(new OpportunityContactRole(
                    OpportunityId = oppId,
                    ContactId = contactId,
                    Role = BROKER_ROLE,
                    IsPrimary = true
                ));
                continue;
            }
            // Update the row conversion already made: name the role, and claim primary only when
            // it is not already primary (Salesforce allows one primary per Opportunity, so
            // re-asserting it is pointless churn that could demote a deliberate choice).
            OpportunityContactRole edit = new OpportunityContactRole(Id = prior.Id, Role = BROKER_ROLE);
            if (prior.IsPrimary != true) {
                edit.IsPrimary = true;
            }
            roleUpdates.add(edit);
        }
        // ONE bulk statement per partition, each isEmpty()-guarded so an empty list never spends a
        // DML. The update comes first because it is the ordinary path: conversion creates the row,
        // so roleInserts is normally empty and this method normally costs exactly one statement.
        // allOrNone = false on both, for the same reason as the Property insert — one bad role row
        // must never roll back a completed conversion.
        if (!roleUpdates.isEmpty()) {
            Database.update(roleUpdates, false);
        }
        if (!roleInserts.isEmpty()) {
            Database.insert(roleInserts, false);
        }
    }

    /**
     * Converted Opportunity Id -> converted Contact Id, skipping any lead that produced no
     * Contact. LastName is required on a Lead so a Contact is always produced in practice, but the
     * null check costs nothing and keeps the pairing total.
     */
    private static Map<Id, Id> convertedContactByOpportunity(Map<Id, Lead> oppToLead) {
        Map<Id, Id> oppToContactId = new Map<Id, Id>();
        for (Id oppId : oppToLead.keySet()) {
            Id contactId = oppToLead.get(oppId).ConvertedContactId;
            if (contactId != null) {
                oppToContactId.put(oppId, contactId);
            }
        }
        return oppToContactId;
    }

    /**
     * The contact-role rows that already exist on the converted Opportunities, keyed by
     * (Opportunity, Contact). ONE selector call for the whole set — SOQL 2 of 2.
     */
    private static Map<String, OpportunityContactRole> existingRolesByPair(Set<Id> opportunityIds) {
        Map<String, OpportunityContactRole> existingByPair = new Map<String, OpportunityContactRole>();
        for (OpportunityContactRole r : OpportunityContactRoleSelector.selectByOpportunityIds(opportunityIds)) {
            existingByPair.put(pairKey(r.OpportunityId, r.ContactId), r);
        }
        return existingByPair;
    }

    /** Stable composite key for an (Opportunity, Contact) pair. */
    private static String pairKey(Id opportunityId, Id contactId) {
        return String.valueOf(opportunityId) + '|' + String.valueOf(contactId);
    }

    /**
     * Stamp Contact.Broker and Account.Broker_Firm onto the records standard conversion just
     * created (IR segregation, 2026-08-10).
     *
     * WHY THIS EXISTS. Database.convertLead does NOT map record types onto the Contact or the
     * Account — they take whatever is default for the RUNNING USER'S PROFILE. Profiles are
     * .forceignore'd in this repo, so that default is unverifiable from source and can differ
     * per persona. Once Account OWD is Private, an Account on the wrong record type (or none)
     * matches no sharing rule and takes its Contacts with it, because Contact is
     * ControlledByParent. Deterministic beats depending on a file we cannot read.
     *
     * GOVERNOR CONTRACT — this raises the class budget from 3 DML to ≤5, and that was a
     * deliberate decision, not drift (see the class header). Both statements are
     * isEmpty()-guarded and both are CONSTANT IN BATCH SIZE, which is the property that
     * actually matters: one statement for every converted Contact in the chunk, one for every
     * converted Account, never one per record. A matched Account (LeadConvertMatchService
     * reusing an existing broker firm) is already stamped from the Task 3 backfill, so the
     * ordinary repeat-broker path writes fewer rows — but the statement count is what is
     * pinned, so the contract states the worst case.
     *
     * Both use allOrNone = false for the same reason the Property insert does: a failure to
     * stamp a record type must not roll back the structural RecordTypeId / Property__c link on
     * the Opportunity, which `update updates` guarantees all-or-none above.
     *
     * ═══ FIX ROUND 1 (2026-08-10) — DIAGNOSED: THIS IS A PROVISIONING GAP, NOT AN APEX DEFECT ═══
     * conversionStampsBrokerRecordTypesOnContactAndAccount failed with "Actual: null" after
     * deploy. Reproduced live via a savepoint-wrapped anonymous-Apex probe against usman-dpeg
     * (rolled back, no permanent org change) rather than by inspection:
     *   - recordTypeId(Contact.SObjectType, 'Broker') and recordTypeId(Account.SObjectType,
     *     'Broker_Firm') both resolve non-null Ids, but Schema.RecordTypeInfo.isAvailable()
     *     returns FALSE for both, for the exact principal every Apex test and anonymous
     *     execution runs as in this org (usman.khan.dpeg@avanzasolutions.com, System
     *     Administrator profile, WITH DPEG_Admin_Access assigned).
     *   - Forcing the identical Database.update the guard would otherwise skip confirms
     *     isAvailable() is telling the truth, not lying: it fails with
     *     INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY, "invalid record type" (the update path)
     *     and INVALID_CROSS_REFERENCE_KEY, "Record Type ID... isn't valid for the user" (the
     *     insert path) — the same shape TestDataFactory.recordTypeId's header already documents
     *     for this org.
     *   - ConvertedContactId / ConvertedAccountId ARE populated correctly at this point (verified
     *     by direct read-back), and nothing runs afterward to clear a stamp that never landed —
     *     ruling out hypotheses 2-4 the fix-round brief asked to check first.
     *   - ROOT CAUSE, confirmed by a read-only metadata retrieve of the LIVE org copy of
     *     DPEG_Admin_Access (not the repo file): the org's deployed permission set does NOT
     *     contain the six IR-segregation <recordTypeVisibilities> entries the repo file declares
     *     (Account.Broker_Firm, Account.Investing_Entity, Contact.Broker, Contact.Investor,
     *     Lead.Acquisition_Broker) — only the pre-existing ones (Contract
     *     Review / Disposition / LOI / NDA / Opportunity) are live. Task 2's grant was committed
     *     to source but never actually landed in the org; the record types themselves (Task 1)
     *     did land, which is why they resolve to a non-null Id and why this looked like a
     *     visibility-check bug rather than a deploy gap. THIS APEX WAS NEVER THE PROBLEM — the
     *     guard is doing exactly what it is supposed to do, silently and correctly, in front of a
     *     principal the org has not yet provisioned. Remedy is a permission-set redeploy, out of
     *     this class's scope and out of Apex's control entirely — no code change here can fix it.
     *
     * ═══ HOW A SKIPPED STAMP BECOMES VISIBLE ═══ (the fix-round brief's "think carefully" ask)
     * allOrNone = false is kept for the reason stated above; a hard throw here would take down
     * every conversion in the chunk over a record-type problem unrelated to the deal itself — the
     * same reasoning that keeps the Property insert non-blocking. Silently unstamped can never
     * become PERMANENTLY invisible, though, because two things are already true and neither is
     * new machinery:
     *   1. conversionStampsBrokerRecordTypesOnContactAndAccount is exactly the read-back
     *      assertion this class's own FLS POSTURE section (above) already mandates for a
     *      not-obviously-a-bug blank field — "query the row directly to tell the two apart." It
     *      is what caught this gap the moment the code reached a real org, before any user did.
     *   2. There is no sanctioned way to make an in-transaction signal LOUDER without either
     *      violating this repo's "no System.debug in production code" rule or reintroducing the
     *      unconditional-throw failure mode this guard exists to prevent (ARCHITECTURE.md §2's
     *      automation-path exception; the same ContentPublication-shaped hazard TestDataFactory's
     *      recordTypeId() header already cites). The correct lever is therefore OPERATIONAL, not
     *      code: re-run this test (or the UAT persona check the FLS POSTURE paragraph already
     *      prescribes) after any permission-set deploy that touches record-type visibility, and
     *      treat a null RecordType.DeveloperName read-back as "provisioning gap," never as "the
     *      stamp code is broken."
     */
    private static void stampConvertedPartyRecordTypes(List<Lead> convertedLeads) {
        Id contactRt = recordTypeId(Contact.SObjectType, 'Broker');
        Id accountRt = recordTypeId(Account.SObjectType, 'Broker_Firm');

        List<Contact> contactUpdates = new List<Contact>();
        List<Account> accountUpdates = new List<Account>();
        Set<Id> seenAccountIds = new Set<Id>();

        for (Lead l : convertedLeads) {
            if (contactRt != null && l.ConvertedContactId != null) {
                contactUpdates.add(new Contact(Id = l.ConvertedContactId, RecordTypeId = contactRt));
            }
            // Several Leads can converge on ONE Account (Smart Lead Conversion reuses a firm),
            // and a duplicate Id in one DML statement throws DUPLICATE_VALUE.
            if (accountRt != null && l.ConvertedAccountId != null && seenAccountIds.add(l.ConvertedAccountId)) {
                accountUpdates.add(new Account(Id = l.ConvertedAccountId, RecordTypeId = accountRt));
            }
        }

        if (!contactUpdates.isEmpty()) {
            Database.update(contactUpdates, false);
        }
        if (!accountUpdates.isEmpty()) {
            Database.update(accountUpdates, false);
        }
    }

    /**
     * The Id of a record type by developer name, or null when it does not exist in this org or
     * is not available to the running user. A describe, not a query — it costs no SOQL, so the
     * class's 2-SOQL contract is unchanged. Guarded on isAvailable() (not just non-null)
     * because this is a USER-INITIATED path (conversion), unlike the automation-path helpers in
     * EmailToLeadService / TestDataFactory that guard on null only — see ARCHITECTURE.md §2's
     * WITH SYSTEM_MODE automation-path table and the 2026-08-10 measured finding that record
     * type visibility is enforced on Apex DML unconditionally.
     */
    private static Id recordTypeId(Schema.SObjectType sobjType, String developerName) {
        Schema.RecordTypeInfo info = sobjType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    private static String firstNonBlank(List<String> values) {
        for (String v : values) {
            if (String.isNotBlank(v)) {
                return v;
            }
        }
        return null;
    }

    /** Truncates to a field's maximum length; null in, null out. */
    private static String clip(String value, Integer maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength);
    }

    /** The lead's value when the target picklist actually offers it, otherwise null. */
    private static String picklistValueOrNull(String value, Set<String> allowedValues) {
        return (String.isNotBlank(value) && allowedValues.contains(value)) ? value : null;
    }

    /**
     * Active values on any picklist, so we never push a value a restricted picklist rejects.
     * Generalized from the original assetTypePicklistValues() when S1 added two more restricted
     * picklist writes — see the class header for why guarding at source is what lets
     * `update updates` stay all-or-none. getDescribe() is a describe call, not a query: it
     * consumes no SOQL limit, so calling it once per picklist per invocation is free.
     */
    private static Set<String> activePicklistValues(Schema.SObjectField field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry e : field.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                values.add(e.getValue());
            }
        }
        return values;
    }
}
