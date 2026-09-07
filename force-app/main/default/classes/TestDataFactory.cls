/**
 * Centralised test-data factory for the DPEG org.
 *
 * Mandated by ARCHITECTURE.md §2 ("Test data: always use TestDataFactory") and
 * listed there under Reference Implementations. Covers all 33 custom objects plus
 * the standard Account / Contact / Lead / Opportunity / Task surface the app uses.
 *
 * ╔═══════════════════════════════════════════════════════════════════════════╗
 * ║ ⚠ READ BEFORE USE — TWO THINGS THAT WILL BITE YOU                          ║
 * ╚═══════════════════════════════════════════════════════════════════════════╝
 *
 * ⚠ 1. THE SCAFFOLD CACHE DOES NOT CROSS THE @TestSetup BOUNDARY.
 *
 *   The default*() accessors (defaultProperty, defaultPropertyAsset, defaultUnit,
 *   defaultOpportunity, defaultTransaction, defaultDisposition, defaultLeaseInquiry,
 *   defaultLeaseRenewal, defaultWorkOrder, defaultContractReview, defaultLoi,
 *   defaultUnderwriting) cache in STATIC fields. Statics are wiped between the
 *   @TestSetup transaction and each test-method transaction.
 *
 *   Therefore: if @TestSetup calls default*() and a test method ALSO calls
 *   default*(), the test method SILENTLY CREATES A SECOND RECORD. It does not
 *   reuse the @TestSetup one. Counts drift, rollups look wrong, and the failure
 *   surfaces far from its cause.
 *
 *     // WRONG — creates a second Property_Asset__c
 *     @TestSetup static void setup() { TestDataFactory.createWorkOrders(251, true); }
 *     @isTest static void t() { Id a = TestDataFactory.defaultPropertyAsset().Id; ... }
 *
 *     // RIGHT — query for what @TestSetup created
 *     @isTest static void t() { Id a = [SELECT Id FROM Property_Asset__c LIMIT 1].Id; ... }
 *
 *   Rule: NEVER call default*() in a test method if @TestSetup already built data.
 *   Query for it instead. Within a single transaction the cache is stable and safe.
 *
 * ⚠ 2. FOUR FIELDS ARE TYPE-INVERTED AGAINST THEIR OWN NAMES.
 *
 *   - Disposition__c.Package_Sent__c        is a DATE     (sounds Boolean)
 *   - Transaction__c.Is_Wire_Approval_Due__c is a CHECKBOX (sounds like a Date)
 *   - Counter_Offer__c.Revision_Number__c   is TEXT       (says "Number")
 *   - Deal_Message__c.Revision__c           is TEXT       (sounds like a Number)
 *
 *   Do not type from the field name — check the metadata. This factory got all
 *   four wrong on the first pass WITH the metadata open; the compiler caught them.
 *   `Revision_Number__c` typed as Text is the sharpest case: the name contains the
 *   word "Number" and it is not one. This defect class is the evidence behind the
 *   type-suffix rule in ARCHITECTURE.md §1.
 *
 *   Related: seven money/duration fields are TEXT, not Currency/Number, against
 *   ARCHITECTURE.md §1's naming convention — Lease_Inquiry__c.Base_Rent__c,
 *   .TI_Allowance__c; Lease_Renewal__c.Current_Rent__c;
 *   Development_Feasibility_Review__c.Est_Cost_Impact__c, .Proposals_Target__c;
 *   Construction_Feasibility_Review__c.Estimated_Timeline_Impact__c;
 *   CAM_Reconciliation__c.Reconciliation_Year__c. They take String literals here.
 *
 * ⚠ 3. FIVE OBJECTS HAVE RECORD TYPES AND THE FACTORY STAMPS ALL FIVE.
 *   (This note said TWO until 2026-08-09; NDA__c arrived in Tranche 3A, LOI__c in 3B and
 *   Contract_Review__c in 3C.)
 *
 *   - Opportunity -> createOpportunitiesByRecordType (Land / Commercial)
 *   - Disposition__c -> createDispositions (On_Market by default; Off_Market via the
 *     4-argument overload or createDisposition(assetId, rtName, doInsert))
 *   - NDA__c -> createNdas (Acquisition_NDA by default; Disposition_NDA via the
 *     4-argument overload or createDispositionNda(dispositionId, doInsert))
 *   - LOI__c -> createLois (Acquisition_LOI by default; Disposition_LOI via the
 *     4-argument overload or createDispositionLoi(dispositionId, doInsert))
 *   - Contract_Review__c -> createContractReviews (Acquisition_PSA by default; Disposition_PSA
 *     via the 4-argument overload or createDispositionContractReview(dispositionId, doInsert))
 *
 *   An UNSTAMPED record inherits the TEST-RUNNING USER'S PROFILE DEFAULT, which is org
 *   state and not deployable (`profiles/**` is .forceignore'd) — so an unstamped fixture
 *   is green or red depending on who runs the suite. All five stamps are guarded on
 *   isAvailable(), so they degrade to the platform default in an org where the record types
 *   have not deployed rather than turning every affected test red.
 *
 *   ⚠ THREE OF THE FOUR CUSTOM OBJECTS ALSO SEED A PER-RECORD-TYPE STARTING PICKLIST VALUE, and
 *   that is not cosmetic: record-type picklist restriction is enforced by the UI ONLY, so Apex DML
 *   would happily insert an off-set value and produce a fixture RecordStageAdvanceService
 *   cannot advance. NDA__c: 'Pending' vs 'Not Sent'. LOI__c: 'Draft' vs 'Received' (fully
 *   disjoint sets — there is no shared value to fall back on). Disposition__c seeds
 *   'Disposition Readiness', which is valid on both of its types.
 *
 *   🔴 Contract_Review__c IS THE EXPLICIT EXCEPTION AND IT IS NOT AN OVERSIGHT. Its two record
 *   types expose the IDENTICAL Negotiation_Status__c and Stage__c value sets (stated deliberately
 *   in Disposition_PSA's own record type file), so there is no per-type seed to choose and a
 *   branch would invent a difference that does not exist. What differs between its types is the
 *   PERMISSION GATE, which is not a field on the row and therefore not the factory's business.
 *
 * ── CONVENTIONS ──────────────────────────────────────────────────────────────
 *  - Every object exposes createXs(count, [parents], doInsert) returning a List,
 *    and a singular createX([parents], doInsert) that delegates to the bulk form.
 *  - `doInsert = false` returns unsaved records so callers can mutate before DML.
 *  - Bulk methods build in memory and perform exactly ONE DML at the end — they
 *    are safe to call with 251+ per .claude/rules/bulk-test-rule.md.
 *  - Callers customise via applyOverrides(records, Map<String,Object>) rather than
 *    the factory growing a method per field permutation.
 *  - Child objects that hang off a hub parent also expose a no-parent overload
 *    which lazily builds a shared scaffold (see defaultPropertyAsset() et al), so
 *    a 251-record setup is a single line.
 *
 * ── SCHEMA FACTS THIS FACTORY ENCODES (verified against force-app metadata) ───
 *  - 31 of 33 custom objects use an AutoNumber Name. Name is NEVER set on them;
 *    only Property__c and Property_Asset__c have a writeable Text Name.
 *  - Formula / rollup fields are never assigned (they are not writeable).
 *  - 5 Master-Detail parents are mandatory: Unit__c.Property_Asset__c,
 *    Rent_Step__c.Unit__c, Lease_Activity__c.Lease_Inquiry__c,
 *    Renewal_Activity__c.Lease_Renewal__c, Work_Order_Activity__c.Work_Order__c.
 *  - Deal_Message__c has an active validation rule (Exactly_One_Parent): exactly
 *    one of LOI__c / Underwriting__c / Contract_Review__c. Hence three methods.
 *  - Broker__c lookups on Broker_Assignment__c and Lease_Inquiry__c carry an
 *    active lookup filter requiring Contact.Is_Broker__c = true — use
 *    createBrokerContacts(), not createContacts().
 *  - The 4 Yardi mirror external ids are unique; they use a static counter so
 *    repeated factory calls in one transaction cannot collide.
 *  - Task links to Transaction__c via Transaction_Deal__c (defined on the Activity
 *    object folder), NOT WhatId.
 *
 * ── CASCADES CALLERS MUST KNOW ABOUT ─────────────────────────────────────────
 *  Inserting an Opportunity fires OpportunityReviewTrigger:
 *    - ensureNda() always creates one NDA__c and re-updates the Opportunity.
 *    - StageName 'PSA' also creates a Contract_Review__c (+ Opp update).
 *    - StageName 'Underwriting' also creates an Underwriting__c (+ Opp update).
 *    - 'Development Review' / 'Construction Review' create feasibility reviews.
 *  Default stage is therefore 'New' (valid in both business processes) to keep
 *  the blast radius to the unavoidable NDA. Tests asserting NDA__c counts must
 *  account for the auto-created one.
 *
 *  ⚠ MOVING a saved Opportunity between stages now crosses VALIDATION-RULE GATES
 *  (signed NDA / approved underwriting / approved LOI / signed contract, plus a
 *  backward-movement block). Setting StageName BEFORE insert still bypasses them
 *  all, because ISCHANGED() is false on insert. To cross a gate legitimately, use
 *  the four stage-gate helpers next to createOpportunitiesByRecordType:
 *  signPrimaryNda / approveUnderwriting / placeApprovedLoi / signContract.
 *
 * ── DELIBERATE DEVIATION ─────────────────────────────────────────────────────
 *  This class exceeds the sf-apex 500-line guidance. That rule targets
 *  single-responsibility production classes; ARCHITECTURE.md §2 names exactly one
 *  factory at exactly this path, and Phase 2 migrates 44 test classes onto it.
 *  Splitting it would contradict the doc and the migration. Responsibility is
 *  still singular: test-data construction.
 *
 * @see .claude/rules/bulk-test-rule.md
 * @see .claude/skills/sf-apex-test/references/test-data-factory.md
 */
@isTest
public with sharing class TestDataFactory {

    // ═══════════════════════════════════════════════════════════════════════════
    // INFRASTRUCTURE
    // ═══════════════════════════════════════════════════════════════════════════

    /** Monotonic per-transaction counter. Backs values on fields with a UNIQUE
     *  constraint so two factory calls in one transaction cannot collide. */
    private static Integer uniqueCounter = 0;

    private static Integer nextUnique() {
        return uniqueCounter++;
    }

    /**
     * Applies field overrides to every record in a collection.
     * @param records   Records to mutate (may be unsaved).
     * @param overrides Field API name -> value.
     * @example
     * List<Work_Order__c> wos = TestDataFactory.createWorkOrders(251, false);
     * TestDataFactory.applyOverrides(wos, new Map<String, Object>{ 'Status__c' => 'Closed' });
     * insert wos;
     */
    public static void applyOverrides(List<SObject> records, Map<String, Object> overrides) {
        if (records == null || records.isEmpty() || overrides == null || overrides.isEmpty()) {
            return;
        }
        for (SObject record : records) {
            for (String fieldName : overrides.keySet()) {
                record.put(fieldName, overrides.get(fieldName));
            }
        }
    }

    /**
     * Single-record convenience form of applyOverrides.
     * @param record    Record to mutate.
     * @param overrides Field API name -> value.
     */
    public static void applyOverrides(SObject record, Map<String, Object> overrides) {
        if (record == null) {
            return;
        }
        applyOverrides(new List<SObject>{ record }, overrides);
    }

    /** Single DML for a whole collection. Never called inside a loop. */
    private static void insertIf(Boolean doInsert, List<SObject> records) {
        if (doInsert == true && !records.isEmpty()) {
            insert records;
        }
    }

    /**
     * Inserts records that are DELIBERATELY duplicate-shaped, telling the org's duplicate rules to
     * alert-but-save instead of blocking.
     *
     * ── WHY THIS EXISTS (added 2026-08-03) ────────────────────────────────────────────────────
     * `Standard_Account_Duplicate_Rule` and `Standard_Contact_Duplicate_Rule` are ACTIVE BY DESIGN
     * in this org and are deliberately left that way (they protect every UI-driven creation path;
     * see the D4 discussion in LeadConvertActionService). They are `actionOnInsert=Allow` /
     * `operationsOnInsert=Alert,Report` — "warn a human, let them continue" — but Apex DML has no
     * surface on which to render an alert, so the platform degrades "Alert" into a hard
     * DUPLICATES_DETECTED and the insert fails.
     *
     * That bites any test that must SEED duplicate-shaped rows on purpose — a tie-break test needs
     * two Accounts with the same Name, or two Contacts with the same Email, and cannot be written
     * any other way. `DuplicateRuleHeader.allowSave` is the platform's supported mechanism for
     * exactly this, and unlike lead conversion (where the setters on Database.LeadConvert are
     * required because DML options do not reach the records conversion creates) a PLAIN insert DOES
     * honour it.
     *
     * ⚠ SCOPE — this is NOT related to Smart Lead Conversion's D4 bypass. That bypass covers
     * records created BY A CONVERSION only; it does nothing for ordinary test seeding. Two separate
     * mechanisms, two separate reasons.
     *
     * ⚠ IT DOES NOT WEAKEN ANY ASSERTION. `allowSave` only suppresses the duplicate BLOCK at insert
     * time; it changes nothing about the rows themselves, so a tie-break test still gets exactly
     * the two same-named / same-emailed rows it asked for and still discriminates on CreatedDate
     * and Id. `optAllOrNone` stays TRUE so a genuine failure (bad field, validation rule, missing
     * required value) still throws loudly — this helper suppresses duplicate alerts, not errors.
     *
     * ⚠ FUZZY MATCHING IS WIDER THAN "IDENTICAL". The standard Account rule matches on a FUZZY
     * name, so names differing only by a trailing counter — which is exactly what
     * `createAccounts` generates ('Test Account 0-1' vs 'Test Account 0-2') — can match each other.
     * Two separate `createAccount(true)` calls in one transaction are therefore already enough to
     * trip it. Prefer genuinely dissimilar names where the test does not care about the value; use
     * this helper where it does.
     *
     * @param records the duplicate-shaped records to insert; null/empty is a no-op.
     * @example
     * List<Account> firms = TestDataFactory.createAccounts(2, false);
     * TestDataFactory.insertAllowingDuplicates(firms);
     */
    public static void insertAllowingDuplicates(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            return;
        }
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        dml.optAllOrNone = true;   // a REAL failure must still throw; only duplicate alerts are suppressed
        Database.insert(records, dml);
    }

    private static void requirePositive(Integer count) {
        if (count == null || count < 1) {
            throw new TestDataFactoryException('count must be a positive integer; received: ' + count);
        }
    }

    /**
     * The Id of a record type by developer name, or null when it does not exist in this org OR
     * is not available to the running user (which, inside System.runAs, is the impersonated user).
     *
     * ⚠ REVERSED 2026-08-10 (fix round 1) — READ BEFORE CHANGING THIS METHOD AGAIN.
     *
     * The first pass of this helper guarded on `info != null` alone, deliberately omitting
     * `isAvailable()`, on the reasoning that "Apex DML writes in system mode regardless, so
     * isAvailable() would never block the write - it would only leave records unstamped."
     * That reasoning was WRONG and was falsified by a live reproduction, not by inspection:
     *
     *   ContactSelectorTest.selectBrokersOrderedByName_standardUserWithGrants_userModeReturnsRows
     *   System.DmlException: INVALID_CROSS_REFERENCE_KEY, Record Type ID: this ID value isn't
     *   valid for the user: 012iw0000009xtjAAA: [RecordTypeId]
     *     Class.TestDataFactory.insertIf: line 161
     *     Class.TestDataFactory.createBrokerContacts: line 504
     *
     * That insert is a PLAIN `insert records;` - no WITH USER_MODE, no AccessLevel.USER_MODE
     * anywhere in its path - which is already the CRUD/FLS-bypassing default every other DML
     * statement in this factory uses, executed inside System.runAs(standardUser). It still threw.
     * Record-type visibility is enforced by a layer the AccessLevel enum does not reach: it is
     * checked against the EFFECTIVE RUNNING USER's profile/permission-set record-type
     * assignments at DML time, for every insert/update of that record's type, independent of
     * whether the surrounding DML is CRUD/FLS-checked (WITH USER_MODE) or CRUD/FLS-bypassing
     * (the default, or AccessLevel.SYSTEM_MODE) - AccessLevel governs CRUD, FLS and sharing only.
     * Assigning a RecordTypeId the running user cannot access throws INVALID_CROSS_REFERENCE_KEY
     * unconditionally; there is no DML mode that downgrades that into "insert succeeds, unstamped."
     *
     * So the real choice was never "throws vs. silently unstamped" - it was always "throws vs.
     * doesn't set RecordTypeId at all," and only `isAvailable()` can tell those apart before the
     * DML fires. Guarding on `info != null` alone described an outcome (a quietly unstamped
     * record) that this DML layer cannot actually produce for an unavailable-but-existing record
     * type; the actual failure mode is a hard exception, in the transaction of whichever test (or
     * later, production principal) is under-provisioned - the same shape as this repo's
     * ContentPublication incident (see ARCHITECTURE.md §2, InboundEmailAttachmentService), where
     * an unconditional write became a single point of failure for a transaction that had nothing
     * to do with the write's own purpose.
     *
     * Null is therefore a legitimate answer for TWO reasons, not one: the record type does not
     * exist in this org (lets Tasks 1 and 3 land in either order), OR it exists but is not
     * available to the running user - in which case the caller leaves RecordTypeId unset and the
     * platform applies whichever default record type IS available to that user, so a
     * deliberately under-provisioned test persona (this codebase's `*_minimumAccessUserNoFLS_*`
     * pattern is pervasive - see TaskSelectorTest, OnboardingTaskRollupServiceTest,
     * TaskRollupServiceTest) can still call createLead/createAccount/createContact without the
     * factory itself becoming a new, unrelated point of failure for a test whose entire purpose
     * is to exercise that restricted persona.
     *
     * `isAvailable()` reflects the CONTEXT user, and inside System.runAs the context user is the
     * impersonated one - this is the same mechanism every FLS/permission probe in this suite
     * already depends on (PermissionSetAssignmentSelector, UserSelector, the whole
     * `WITH USER_MODE` testing pattern), so it needs no new proof here; verified for the admin
     * test-running user specifically (System Administrator returns isAvailable() = true for all
     * three record types), so this reinstatement does not regress
     * TestDataFactoryTest.factoryStampsAcquisitionSideRecordTypes, which runs as that user.
     *
     * A describe, not a query - it costs no SOQL, which matters because this runs inside every
     * governor-pinned test in the suite.
     */
    private static Id recordTypeId(Schema.SObjectType sobjType, String developerName) {
        Schema.RecordTypeInfo info = sobjType.getDescribe()
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    private static void requireId(Id value, String label) {
        if (value == null) {
            throw new TestDataFactoryException(label + ' is required and cannot be null.');
        }
    }

    /**
     * Reject an Id that is not of the expected SObject type.
     *
     * Added 2026-08-03 alongside the Competing_Broker_Submission__c winner anchor, which is the
     * factory's first method taking TWO Id parameters that differ only in which object they point
     * at (`winningLeadId`, `winningOpportunityId`). Positional Ids of the same Apex type are
     * trivially transposable at a call site and would compile silently — the same hazard
     * EmailToLeadService.LeadRequest's Javadoc cites for its DTO. Checking the prefix turns a
     * transposition into an immediate, named failure instead of a confusing DML error.
     *
     * @param value    The Id to check; null is allowed (use requireId for presence).
     * @param expected The SObject type it must belong to.
     * @param label    Parameter name for the error message.
     */
    private static void requireSObjectType(Id value, Schema.SObjectType expected, String label) {
        if (value != null && value.getSObjectType() != expected) {
            throw new TestDataFactoryException(
                label + ' must be a ' + expected + ' Id but was a ' + value.getSObjectType()
                + ' Id. Check the argument order.');
        }
    }

    /** Thrown when the factory is asked for something it cannot legally build. */
    public class TestDataFactoryException extends Exception {}

    // ═══════════════════════════════════════════════════════════════════════════
    // LAZY SCAFFOLD
    //
    // Hub parents cached per transaction so child factories can offer a
    // parentless overload. NOTE: statics do not survive the @TestSetup ->
    // test-method transaction boundary, so a test method calling defaultX()
    // after an @TestSetup that also called it will get a SECOND record. Query
    // for @TestSetup-created data instead of relying on the cache across it.
    // ═══════════════════════════════════════════════════════════════════════════

    private static Property__c cachedProperty;
    private static Property_Asset__c cachedPropertyAsset;
    private static Opportunity cachedOpportunity;
    private static Transaction__c cachedTransaction;
    private static Disposition__c cachedDisposition;
    private static Lease_Inquiry__c cachedLeaseInquiry;
    private static Lease_Renewal__c cachedLeaseRenewal;
    private static Unit__c cachedUnit;
    private static Work_Order__c cachedWorkOrder;
    private static Contract_Review__c cachedContractReview;
    private static LOI__c cachedLoi;
    private static Underwriting__c cachedUnderwriting;

    /** Shared inserted Property__c for this transaction. */
    public static Property__c defaultProperty() {
        if (cachedProperty == null) {
            cachedProperty = createProperties(1, true)[0];
        }
        return cachedProperty;
    }

    /** Shared inserted Property_Asset__c (under defaultProperty). */
    public static Property_Asset__c defaultPropertyAsset() {
        if (cachedPropertyAsset == null) {
            cachedPropertyAsset = createPropertyAssets(1, defaultProperty().Id, true)[0];
        }
        return cachedPropertyAsset;
    }

    /** Shared inserted Unit__c (under defaultPropertyAsset). */
    public static Unit__c defaultUnit() {
        if (cachedUnit == null) {
            cachedUnit = createUnits(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedUnit;
    }

    /** Shared inserted Opportunity at stage 'New'. Note: this also creates an NDA__c. */
    public static Opportunity defaultOpportunity() {
        if (cachedOpportunity == null) {
            cachedOpportunity = createOpportunities(1, true)[0];
        }
        return cachedOpportunity;
    }

    /** Shared inserted Transaction__c. */
    public static Transaction__c defaultTransaction() {
        if (cachedTransaction == null) {
            cachedTransaction = createTransactions(1, true)[0];
        }
        return cachedTransaction;
    }

    /** Shared inserted Disposition__c (under defaultPropertyAsset). */
    public static Disposition__c defaultDisposition() {
        if (cachedDisposition == null) {
            cachedDisposition = createDispositions(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedDisposition;
    }

    /** Shared inserted Lease_Inquiry__c (under defaultPropertyAsset). */
    public static Lease_Inquiry__c defaultLeaseInquiry() {
        if (cachedLeaseInquiry == null) {
            cachedLeaseInquiry = createLeaseInquiries(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedLeaseInquiry;
    }

    /** Shared inserted Lease_Renewal__c (under defaultPropertyAsset). */
    public static Lease_Renewal__c defaultLeaseRenewal() {
        if (cachedLeaseRenewal == null) {
            cachedLeaseRenewal = createLeaseRenewals(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedLeaseRenewal;
    }

    /** Shared inserted Work_Order__c (under defaultPropertyAsset). */
    public static Work_Order__c defaultWorkOrder() {
        if (cachedWorkOrder == null) {
            cachedWorkOrder = createWorkOrders(1, defaultPropertyAsset().Id, true)[0];
        }
        return cachedWorkOrder;
    }

    /** Shared inserted Contract_Review__c (under defaultOpportunity). */
    public static Contract_Review__c defaultContractReview() {
        if (cachedContractReview == null) {
            cachedContractReview = createContractReviews(1, defaultOpportunity().Id, true)[0];
        }
        return cachedContractReview;
    }

    /** Shared inserted LOI__c (under defaultOpportunity). */
    public static LOI__c defaultLoi() {
        if (cachedLoi == null) {
            cachedLoi = createLois(1, defaultOpportunity().Id, true)[0];
        }
        return cachedLoi;
    }

    /** Shared inserted Underwriting__c (under defaultOpportunity). */
    public static Underwriting__c defaultUnderwriting() {
        if (cachedUnderwriting == null) {
            cachedUnderwriting = createUnderwritings(1, defaultOpportunity().Id, true)[0];
        }
        return cachedUnderwriting;
    }

    /**
     * Clears the cached scaffold. Call when a test needs a genuinely fresh graph
     * within the same transaction.
     */
    public static void resetScaffold() {
        cachedProperty = null;
        cachedPropertyAsset = null;
        cachedOpportunity = null;
        cachedTransaction = null;
        cachedDisposition = null;
        cachedLeaseInquiry = null;
        cachedLeaseRenewal = null;
        cachedUnit = null;
        cachedWorkOrder = null;
        cachedContractReview = null;
        cachedLoi = null;
        cachedUnderwriting = null;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STANDARD OBJECTS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count    Number of Accounts.
     * @param doInsert Insert when true.
     * @return Accounts with unique Names (Account duplicate rule is Alert/Allow,
     *         but unique names keep matching-rule noise out of test output).
     */
    public static List<Account> createAccounts(Integer count, Boolean doInsert) {
        requirePositive(count);
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accounts.add(new Account(
                Name = 'Test Account ' + i + '-' + nextUnique(),
                BillingCity = 'Houston',
                BillingState = 'TX',
                BillingCountry = 'USA',
                Phone = '713-555-' + String.valueOf(i).leftPad(4, '0')
            ));
        }
        Id brokerFirmRt = recordTypeId(Account.SObjectType, 'Broker_Firm');
        if (brokerFirmRt != null) {
            for (Account a : accounts) {
                a.RecordTypeId = brokerFirmRt;
            }
        }
        insertIf(doInsert, accounts);
        return accounts;
    }

    /** Single Account. @param doInsert Insert when true. @return The Account. */
    public static Account createAccount(Boolean doInsert) {
        return createAccounts(1, doInsert)[0];
    }

    /**
     * @param count     Number of Contacts.
     * @param accountId Parent Account; may be null (Contact.AccountId is optional).
     * @param doInsert  Insert when true.
     * @return Contacts.
     */
    public static List<Contact> createContacts(Integer count, Id accountId, Boolean doInsert) {
        requirePositive(count);
        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < count; i++) {
            Integer u = nextUnique();
            contacts.add(new Contact(
                FirstName = 'Test',
                LastName = 'Contact ' + i,
                Email = 'test.contact' + u + '@example.invalid',
                Phone = '713-555-' + String.valueOf(i).leftPad(4, '0'),
                AccountId = accountId
            ));
        }
        Id brokerRt = recordTypeId(Contact.SObjectType, 'Broker');
        if (brokerRt != null) {
            for (Contact c : contacts) {
                c.RecordTypeId = brokerRt;
            }
        }
        insertIf(doInsert, contacts);
        return contacts;
    }

    /** Single Contact. @param accountId Parent Account (nullable). @param doInsert Insert when true. @return The Contact. */
    public static Contact createContact(Id accountId, Boolean doInsert) {
        return createContacts(1, accountId, doInsert)[0];
    }

    /**
     * Contacts flagged Is_Broker__c = true. REQUIRED for any Broker__c lookup:
     * Broker_Assignment__c.Broker__c and Lease_Inquiry__c.Broker__c both carry an
     * active, non-optional lookup filter on Contact.Is_Broker__c.
     * @param count     Number of broker Contacts.
     * @param accountId Parent Account (nullable).
     * @param doInsert  Insert when true.
     * @return Broker Contacts.
     */
    public static List<Contact> createBrokerContacts(Integer count, Id accountId, Boolean doInsert) {
        List<Contact> brokers = createContacts(count, accountId, false);
        for (Integer i = 0; i < brokers.size(); i++) {
            brokers[i].Is_Broker__c = true;
            brokers[i].Broker_Status__c = 'Active';
            brokers[i].Broker_Firm__c = 'Test Brokerage ' + i;
            brokers[i].Broker_License__c = 'LIC-' + String.valueOf(nextUnique()).leftPad(6, '0');
        }
        insertIf(doInsert, brokers);
        return brokers;
    }

    /** Single broker Contact. @param accountId Parent Account (nullable). @param doInsert Insert when true. @return The broker Contact. */
    public static Contact createBrokerContact(Id accountId, Boolean doInsert) {
        return createBrokerContacts(1, accountId, doInsert)[0];
    }

    /**
     * @param count    Number of Leads.
     * @param doInsert Insert when true.
     * @return Leads at Status 'New' (this org's custom Lead status set is
     *         New / Under Review / Qualified / Converted / Disqualified).
     */
    public static List<Lead> createLeads(Integer count, Boolean doInsert) {
        requirePositive(count);
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < count; i++) {
            Integer u = nextUnique();
            leads.add(new Lead(
                FirstName = 'Test',
                LastName = 'Lead ' + i,
                Company = 'Test Company ' + i + '-' + u,
                Email = 'test.lead' + u + '@example.invalid',
                Status = 'New',
                Deal_Type__c = 'Commercial',
                Asset_Type__c = 'Retail',
                Property_Address__c = i + ' Test Street, Houston, TX',
                Guidance_Price__c = 1000000 + (i * 1000),
                Guidance_Cap_Rate__c = 6.5
            ));
        }
        Id acqRt = recordTypeId(Lead.SObjectType, 'Acquisition_Broker');
        if (acqRt != null) {
            for (Lead l : leads) {
                l.RecordTypeId = acqRt;
            }
        }
        insertIf(doInsert, leads);
        return leads;
    }

    /** Single Lead. @param doInsert Insert when true. @return The Lead. */
    public static Lead createLead(Boolean doInsert) {
        return createLeads(1, doInsert)[0];
    }

    /**
     * Leads on the `Investor_Onboarding` record type, ready for InvestorLeadConvertService.
     *
     * DELIBERATELY SEPARATE FROM createLeads. That method stamps `Acquisition_Broker` and carries
     * the acquisition field set (Deal_Type__c, Guidance_Price__c, ...), none of which belongs on an
     * IR Lead — and a Lead on the wrong record type never reaches the IR code paths at all, so
     * reusing it would silently produce tests that prove nothing.
     *
     * FIELDS ARE THE IR CONVERSION'S OWN PRECONDITIONS, not decoration: IR_Lead_Create_Profile_Flow
     * refuses to convert unless Email, Phone, LastName and Is_Accredited__c are all populated, so a
     * Lead built here satisfies that gate by construction.
     *
     * 🔴 OWNERSHIP IS HANDED BACK TO THE RUNNING USER AFTER INSERT, AND THIS IS LOAD-BEARING.
     * IR_Lead_Assignment_Flow is a before-save flow on Create that reassigns OwnerId to the
     * Investor Onboarding QUEUE, and Database.convertLead REFUSES a queue-owned Lead — MEASURED on
     * DPEG-IR-Implementation 2026-08-16: `REQUIRED_FIELD_MISSING: Converted objects can only be
     * owned by users. If the lead is not owned by a user, you must specify a user for the Owner
     * field.` Without this second update every conversion test would fail on that error instead of
     * exercising the code under test. This mirrors the real UI journey, where the "Assign to Me"
     * action claims the Lead out of the queue before "Create Profile" is available.
     *
     * @param count    Number of Leads.
     * @param doInsert Insert when true. Ownership is only reclaimed when this is true — there is no
     *                 Id to update otherwise.
     * @return The Leads (Ids populated when doInsert).
     */
    public static List<Lead> createInvestorOnboardingLeads(Integer count, Boolean doInsert) {
        requirePositive(count);
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < count; i++) {
            Integer u = nextUnique();
            // NAMES ARE DELIBERATELY MADE HIGHLY DISTINCT, not merely index-suffixed. The org's
            // Contact duplicate rule fuzzy-matches a NEW Contact against OPEN LEADS, so in a bulk
            // conversion the Contact minted for Lead i can match Leads i+1..N and the platform
            // rejects the conversion with DUPLICATES_DETECTED. MEASURED 2026-08-16: with
            // FirstName 'IR' / LastName 'Investor <i>', 3 of 50 conversions failed that way.
            // Seeding the unique counter into BOTH name parts removes the fuzzy similarity.
            leads.add(new Lead(
                FirstName = 'Irina' + u,
                LastName = 'Vanterpool' + u,
                Company = 'IR Investor Co ' + i + '-' + u,
                Email = 'ir.investor' + u + '@example.invalid',
                Phone = '555010' + i,
                Status = 'New',
                Is_Accredited__c = true
            ));
        }
        Id irRt = recordTypeId(Lead.SObjectType, 'Investor_Onboarding');
        if (irRt != null) {
            for (Lead l : leads) {
                l.RecordTypeId = irRt;
            }
        }
        // insertAllowingDuplicates, NOT insertIf. The org's Lead duplicate rule matches on the
        // name/company shape these records share, and a bulk batch trips DUPLICATES_DETECTED on
        // row 0 — MEASURED at 50 Leads, 2026-08-16. The duplicate rule is production behaviour
        // worth keeping; it just must not decide whether this factory can seed a fixture.
        if (doInsert) {
            insertAllowingDuplicates(leads);
        }

        if (doInsert) {
            List<Lead> reclaimOwnership = new List<Lead>();
            for (Lead l : leads) {
                reclaimOwnership.add(new Lead(Id = l.Id, OwnerId = UserInfo.getUserId()));
            }
            update reclaimOwnership;   // one DML for the whole collection, never inside a loop
        }
        return leads;
    }

    /** Single Investor Onboarding Lead. @param doInsert Insert when true. @return The Lead. */
    public static Lead createInvestorOnboardingLead(Boolean doInsert) {
        return createInvestorOnboardingLeads(1, doInsert)[0];
    }

    /**
     * Opportunities at StageName 'New' — valid in BOTH the Land and Commercial
     * business processes, and the only stage that does not cascade a feasibility
     * review / Contract Review / Underwriting child on insert.
     *
     * WARNING: OpportunityReviewTrigger.ensureNda still creates one NDA__c per
     * Opportunity and re-updates the Opportunity. 251 Opps => 753 DML rows.
     *
     * @param count     Number of Opportunities.
     * @param accountId Parent Account (nullable).
     * @param doInsert  Insert when true.
     * @return Opportunities.
     */
    public static List<Opportunity> createOpportunities(Integer count, Id accountId, Boolean doInsert) {
        requirePositive(count);
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opps.add(new Opportunity(
                Name = 'Test Opportunity ' + i,
                AccountId = accountId,
                StageName = 'New',
                CloseDate = Date.today().addDays(90),
                Amount = 1000000 + (i * 1000),
                Deal_Type__c = 'Commercial',
                // Opportunity.Asset_Type__c uses 'Retail Strip'; Lead/Property use 'Retail'.
                Asset_Type__c = 'Retail Strip',
                Asking_Price__c = 1000000 + (i * 1000),
                Guidance_Cap_Rate__c = 6.5
            ));
        }
        insertIf(doInsert, opps);
        return opps;
    }

    /** Opportunities with no Account. @param count Number. @param doInsert Insert when true. @return Opportunities. */
    public static List<Opportunity> createOpportunities(Integer count, Boolean doInsert) {
        return createOpportunities(count, (Id) null, doInsert);
    }

    /** Single Opportunity. @param accountId Parent Account (nullable). @param doInsert Insert when true. @return The Opportunity. */
    public static Opportunity createOpportunity(Id accountId, Boolean doInsert) {
        return createOpportunities(1, accountId, doInsert)[0];
    }

    /**
     * Opportunities on a specific record type. StageName stays 'New' because it is
     * the only stage present in both the Land and Commercial business processes;
     * a stage outside the record type's process fails on insert.
     * @param count                  Number of Opportunities.
     * @param recordTypeDeveloperName 'Land' or 'Commercial'.
     * @param accountId              Parent Account (nullable).
     * @param doInsert               Insert when true.
     * @return Opportunities.
     */
    public static List<Opportunity> createOpportunitiesByRecordType(
        Integer count,
        String recordTypeDeveloperName,
        Id accountId,
        Boolean doInsert
    ) {
        Schema.RecordTypeInfo info = Schema.SObjectType.Opportunity
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        if (info == null) {
            throw new TestDataFactoryException(
                'Unknown Opportunity record type: ' + recordTypeDeveloperName + '. Expected Land or Commercial.'
            );
        }
        List<Opportunity> opps = createOpportunities(count, accountId, false);
        for (Opportunity opp : opps) {
            opp.RecordTypeId = info.getRecordTypeId();
            opp.Deal_Type__c = recordTypeDeveloperName;
        }
        insertIf(doInsert, opps);
        return opps;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OPPORTUNITY STAGE-GATE FIXTURES
    //
    // Four helpers that put an ALREADY-INSERTED deal into the state a stage
    // validation rule demands, so a test that legitimately needs to cross a gate
    // says so in one readable line.
    //
    //   signPrimaryNda      -> a signed primary NDA        (Underwriting / LOI / PSA /
    //                                                       About to Close / Closed Won)
    //   approveUnderwriting -> UW_Approved__c              (LOI)
    //   placeApprovedLoi    -> Primary_LOI__c + LOI_Approved__c (PSA)
    //   signContract        -> Contract_Signed__c          (Closed Won)
    //
    // ── WHY HELPERS AND NOT NINE AD-HOC PATCH-UPS ────────────────────────────
    // The gates are one family of rules; when the family changes (a stage added to
    // the NDA list, a new prerequisite) exactly one place should need editing.
    // Each helper also names the BUSINESS state it creates, so a reader of the test
    // sees "this deal has an approved LOI" rather than four opaque field writes.
    //
    // ── CONTRACT ─────────────────────────────────────────────────────────────
    //  - They take SAVED Opportunities. A record with no Id is rejected loudly
    //    rather than silently doing nothing — these prepare a deal that already
    //    exists, they do not build one.
    //  - Bulk-safe: every helper is ONE DML statement per object it touches, with
    //    no SOQL or DML inside a loop, so the 251-record bulk tests can call them.
    //  - They MIRROR every value they write back onto the caller's in-memory
    //    records, so a later `update opps` in the test carries the same values and
    //    cannot silently re-trigger a "changed to meet criteria" flow.
    //  - DML is done through minimal `new Opportunity(Id = ...)` shells so a helper
    //    can never write back a stale field the caller happens to be holding.
    //
    // ⚠ SIDE EFFECT worth knowing: setting LOI_Approved__c fires the after-save
    //   `LOI_Approval_Stamp` flow (ApprovalAuditService + two group notifications).
    //   With no approval history the audit stamp is a no-op, but the flow does run.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Guard for the stage-gate helpers: they prepare saved deals, so an unsaved record is a
     * caller mistake that must fail by name rather than as a confusing DML error later.
     *
     * @param opportunities The deals to prepare.
     * @param helper        Helper name, for the error message.
     * @return The same list, once every record is known to carry an Id.
     */
    private static List<Opportunity> requireSavedOpportunities(
        List<Opportunity> opportunities,
        String helper
    ) {
        if (opportunities == null || opportunities.isEmpty()) {
            throw new TestDataFactoryException(
                helper + ' requires at least one Opportunity; received null or an empty list.');
        }
        for (Opportunity opp : opportunities) {
            if (opp == null || opp.Id == null) {
                throw new TestDataFactoryException(
                    helper + ' requires INSERTED Opportunities, but one record has no Id. '
                    + 'These helpers prepare a saved deal to cross a stage gate — call them after insert.');
            }
        }
        return opportunities;
    }

    /**
     * Signs each deal's PRIMARY NDA, satisfying the signed-NDA stage gate.
     *
     * ⚠ It SIGNS THE EXISTING RECORD rather than inserting a rival NDA.
     * OpportunityReviewService.ensureNda already opens exactly one Pending NDA per Opportunity on
     * insert and stamps it onto Primary_NDA__c, and the gate reads `Primary_NDA__r.NDA_Signed__c`.
     * Inserting a second, signed NDA would satisfy nothing unless it were also stamped as primary,
     * and would break every test that asserts one NDA per deal. (Same pattern as
     * OpportunityDocStatusControllerTest, which signs the auto-created record in place.)
     *
     * The caller's in-memory copy never carries Primary_NDA__c — the trigger stamps it AFTER the
     * insert returns — so the deals are re-read here. A deal with no primary NDA at all (the
     * cascade was bypassed) gets a signed one created and stamped, so the helper's postcondition
     * is the same either way.
     *
     * @param opportunities Inserted Opportunities to prepare (required, non-empty).
     * @return The NDA records that are now signed, one per deal.
     */
    public static List<NDA__c> signPrimaryNda(List<Opportunity> opportunities) {
        Map<Id, Opportunity> byId =
            new Map<Id, Opportunity>(requireSavedOpportunities(opportunities, 'signPrimaryNda'));

        Map<Id, Id> primaryByDeal = new Map<Id, Id>();
        for (Opportunity saved : [
            SELECT Id, Primary_NDA__c FROM Opportunity WHERE Id IN :byId.keySet()
        ]) {
            primaryByDeal.put(saved.Id, saved.Primary_NDA__c);
        }

        List<NDA__c> signed = new List<NDA__c>();
        List<Opportunity> withoutPrimary = new List<Opportunity>();
        for (Opportunity deal : byId.values()) {
            Id primaryNdaId = primaryByDeal.get(deal.Id);
            if (primaryNdaId == null) {
                withoutPrimary.add(deal);
                continue;
            }
            deal.Primary_NDA__c = primaryNdaId;
            signed.add(new NDA__c(
                Id = primaryNdaId,
                Status__c = 'Signed',
                NDA_Signed__c = true,
                Date_Signed__c = Date.today()
            ));
        }
        if (!signed.isEmpty()) {
            update signed;
        }

        if (!withoutPrimary.isEmpty()) {
            List<NDA__c> replacements = new List<NDA__c>();
            for (Opportunity deal : withoutPrimary) {
                replacements.add(createSignedNdas(1, deal.Id, false)[0]); // build only — no DML in the loop
            }
            insert replacements;
            List<Opportunity> stamps = new List<Opportunity>();
            for (Integer i = 0; i < withoutPrimary.size(); i++) {
                withoutPrimary[i].Primary_NDA__c = replacements[i].Id;
                stamps.add(new Opportunity(
                    Id = withoutPrimary[i].Id, Primary_NDA__c = replacements[i].Id));
            }
            update stamps;
            signed.addAll(replacements);
        }
        return signed;
    }

    /**
     * Signs the primary NDA on one deal.
     * @param opportunity An inserted Opportunity.
     * @return The now-signed NDA.
     */
    public static NDA__c signPrimaryNda(Opportunity opportunity) {
        return signPrimaryNda(new List<Opportunity>{ opportunity })[0];
    }

    /**
     * Marks each deal's underwriting as principal-approved (UW_Approved__c), satisfying the
     * "underwriting approved before LOI" gate.
     *
     * This writes ONLY the flag the gate reads. It deliberately does not fake Underwriting_Status__c
     * or the UW_Approved_By__c / UW_Approval_Date__c audit stamps: those are written by
     * ApprovalAuditService from real approval history, and inventing them here would let a test
     * assert an audit trail that no approver ever created.
     *
     * @param opportunities Inserted Opportunities to prepare (required, non-empty).
     * @return The same Opportunities, with the flag mirrored onto the in-memory records.
     */
    public static List<Opportunity> approveUnderwriting(List<Opportunity> opportunities) {
        List<Opportunity> deals = requireSavedOpportunities(opportunities, 'approveUnderwriting');
        Map<Id, Opportunity> updates = new Map<Id, Opportunity>();
        for (Opportunity deal : deals) {
            deal.UW_Approved__c = true;
            updates.put(deal.Id, new Opportunity(Id = deal.Id, UW_Approved__c = true));
        }
        update updates.values();
        return deals;
    }

    /**
     * Marks one deal's underwriting as principal-approved.
     * @param opportunity An inserted Opportunity.
     * @return The same Opportunity.
     */
    public static Opportunity approveUnderwriting(Opportunity opportunity) {
        return approveUnderwriting(new List<Opportunity>{ opportunity })[0];
    }

    /**
     * Puts an APPROVED LOI in place on each deal — creates one LOI__c, designates it as
     * Primary_LOI__c and sets LOI_Approved__c — satisfying the "approved LOI before PSA" gate.
     *
     * Both halves are required: the gate reads the lookup AND the flag, because the LOI approval
     * process deliberately leaves the deal parked at the LOI stage, so the flag is the only
     * evidence the approval happened.
     *
     * The returned LOIs are index-aligned to the input, so a caller that needs particular LOI
     * terms can mutate and re-save the record it got back rather than inserting a second LOI
     * (which the controller layer would not read — it prefers Primary_LOI__c).
     *
     * @param opportunities Inserted Opportunities to prepare (required, non-empty).
     * @return The newly created LOIs, one per deal, index-aligned to the input list.
     */
    public static List<LOI__c> placeApprovedLoi(List<Opportunity> opportunities) {
        List<Opportunity> deals = requireSavedOpportunities(opportunities, 'placeApprovedLoi');

        List<LOI__c> lois = new List<LOI__c>();
        for (Opportunity deal : deals) {
            LOI__c loi = createLois(1, deal.Id, false)[0]; // build only — no DML in the loop
            loi.LOI_Status__c = 'Approved';
            lois.add(loi);
        }
        insert lois;

        Map<Id, Opportunity> updates = new Map<Id, Opportunity>();
        for (Integer i = 0; i < deals.size(); i++) {
            deals[i].Primary_LOI__c = lois[i].Id;
            deals[i].LOI_Approved__c = true;
            updates.put(deals[i].Id, new Opportunity(
                Id = deals[i].Id,
                Primary_LOI__c = lois[i].Id,
                LOI_Approved__c = true
            ));
        }
        update updates.values();
        return lois;
    }

    /**
     * Puts an approved LOI in place on one deal.
     * @param opportunity An inserted Opportunity.
     * @return The LOI now designated Primary_LOI__c.
     */
    public static LOI__c placeApprovedLoi(Opportunity opportunity) {
        return placeApprovedLoi(new List<Opportunity>{ opportunity })[0];
    }

    /**
     * Marks each deal's contract as signed (Contract_Signed__c + Contract_Executed_Date__c),
     * satisfying the "contract signed before Closed Won" gate.
     *
     * Mirrors what ContractExecutionService stamps on a real PSA execution, minus the Transaction
     * hand-off: Contract_Executed_Date__c is a DateTime (Day 0) and is set because a signed
     * contract with no execution date is a state the real service never produces.
     *
     * @param opportunities Inserted Opportunities to prepare (required, non-empty).
     * @return The same Opportunities, with both values mirrored onto the in-memory records.
     */
    public static List<Opportunity> signContract(List<Opportunity> opportunities) {
        List<Opportunity> deals = requireSavedOpportunities(opportunities, 'signContract');
        DateTime dayZero = DateTime.now();
        Map<Id, Opportunity> updates = new Map<Id, Opportunity>();
        for (Opportunity deal : deals) {
            deal.Contract_Signed__c = true;
            deal.Contract_Executed_Date__c = dayZero;
            updates.put(deal.Id, new Opportunity(
                Id = deal.Id,
                Contract_Signed__c = true,
                Contract_Executed_Date__c = dayZero
            ));
        }
        update updates.values();
        return deals;
    }

    /**
     * Marks one deal's contract as signed.
     * @param opportunity An inserted Opportunity.
     * @return The same Opportunity.
     */
    public static Opportunity signContract(Opportunity opportunity) {
        return signContract(new List<Opportunity>{ opportunity })[0];
    }

    /**
     * Day-0 checklist Tasks for a Transaction. These attach via Transaction_Deal__c
     * (NOT WhatId) so they stay off the Activity timeline, and they fire
     * TaskRollupTrigger.
     *
     * NOTE: this method does not cap `count`. TaskFanoutService fans out ~75 Tasks
     * per Transaction; 251 Transactions x 75 = 18,825 rows against the 10,000
     * DML-rows limit. That break is a genuine Phase 7 finding — the factory
     * deliberately does not paper over it by shrinking the fan-out.
     *
     * @param count         Tasks to create.
     * @param transactionId Transaction__c.Id (required).
     * @param doInsert      Insert when true.
     * @return Tasks.
     */
    public static List<Task> createChecklistTasks(Integer count, Id transactionId, Boolean doInsert) {
        requirePositive(count);
        requireId(transactionId, 'transactionId');
        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < count; i++) {
            tasks.add(new Task(
                Subject = 'Test Checklist Task ' + i,
                Status = 'Not Started',
                Priority = 'Normal',
                ActivityDate = Date.today().addDays(14),
                Transaction_Deal__c = transactionId,
                Task_Group__c = 'A. Contract Execution & Title Opening',
                Task_Sequence__c = i + 1
            ));
        }
        insertIf(doInsert, tasks);
        return tasks;
    }

    /** Checklist Tasks against the shared scaffold Transaction. @param count Tasks. @param doInsert Insert when true. @return Tasks. */
    public static List<Task> createChecklistTasks(Integer count, Boolean doInsert) {
        return createChecklistTasks(count, defaultTransaction().Id, doInsert);
    }

    /**
     * Fan-out shaped data: N Tasks for each supplied Transaction, one DML total.
     * @param transactions      Parent Transactions (must be inserted).
     * @param tasksPerTransaction Tasks per Transaction.
     * @param doInsert          Insert when true.
     * @return All Tasks across all Transactions.
     */
    public static List<Task> createChecklistTasksFor(
        List<Transaction__c> transactions,
        Integer tasksPerTransaction,
        Boolean doInsert
    ) {
        requirePositive(tasksPerTransaction);
        List<Task> tasks = new List<Task>();
        for (Transaction__c txn : transactions) {
            requireId(txn.Id, 'Transaction__c.Id (insert Transactions before fanning out Tasks)');
            for (Integer i = 0; i < tasksPerTransaction; i++) {
                tasks.add(new Task(
                    Subject = 'Test Checklist Task ' + i,
                    Status = 'Not Started',
                    Priority = 'Normal',
                    ActivityDate = Date.today().addDays(14),
                    Transaction_Deal__c = txn.Id,
                    Task_Group__c = 'A. Contract Execution & Title Opening',
                    Task_Sequence__c = i + 1
                ));
            }
        }
        insertIf(doInsert, tasks);
        return tasks;
    }

    /**
     * Onboarding checklist Tasks (Property Management module).
     * @param count        Tasks to create.
     * @param onboardingId Onboarding__c.Id (required).
     * @param doInsert     Insert when true.
     * @return Tasks.
     */
    public static List<Task> createOnboardingTasks(Integer count, Id onboardingId, Boolean doInsert) {
        requirePositive(count);
        requireId(onboardingId, 'onboardingId');
        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < count; i++) {
            tasks.add(new Task(
                Subject = 'Test Onboarding Task ' + i,
                Status = 'Not Started',
                Priority = 'Normal',
                ActivityDate = Date.today().addDays(7),
                Onboarding__c = onboardingId,
                Onboarding_Status__c = 'Not Started',
                Source_System__c = 'Salesforce'
            ));
        }
        insertIf(doInsert, tasks);
        return tasks;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY CHAIN
    // Property__c -> Property_Asset__c -> Unit__c (MD) -> Rent_Step__c (MD)
    // Property__c and Property_Asset__c are the ONLY two custom objects with a
    // writeable Text Name; the other 31 are AutoNumber and must never be named.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count    Number of Properties.
     * @param doInsert Insert when true.
     * @return Property__c records (Name is a Text field here, so it is set).
     */
    public static List<Property__c> createProperties(Integer count, Boolean doInsert) {
        requirePositive(count);
        List<Property__c> properties = new List<Property__c>();
        for (Integer i = 0; i < count; i++) {
            properties.add(new Property__c(
                Name = 'Test Property ' + i,
                Address__c = i + ' Test Street',
                City__c = 'Houston',
                State__c = 'TX',
                Zip__c = '77001',
                County__c = 'Harris',
                Asset_Type__c = 'Retail',
                Square_Footage__c = 10000 + (i * 100),
                Asking_Price__c = 1000000 + (i * 1000),
                Cap_Rate_Asking__c = 6.5,
                Market_Cap_Rate__c = 6.0,
                Annual_NOI__c = 65000 + (i * 100),
                Year_Built__c = 1995,
                Parcel_ID__c = 'PARCEL-' + String.valueOf(nextUnique()).leftPad(8, '0')
            ));
        }
        insertIf(doInsert, properties);
        return properties;
    }

    /** Single Property. @param doInsert Insert when true. @return The Property__c. */
    public static Property__c createProperty(Boolean doInsert) {
        return createProperties(1, doInsert)[0];
    }

    /**
     * @param count      Number of Property Assets.
     * @param propertyId Parent Property__c (lookup, optional in schema).
     * @param doInsert   Insert when true.
     * @return Property_Asset__c records (Text Name is set).
     */
    public static List<Property_Asset__c> createPropertyAssets(Integer count, Id propertyId, Boolean doInsert) {
        requirePositive(count);
        List<Property_Asset__c> assets = new List<Property_Asset__c>();
        for (Integer i = 0; i < count; i++) {
            assets.add(new Property_Asset__c(
                Name = 'Test Asset ' + i,
                Property__c = propertyId,
                Property_Type__c = 'Retail',
                Status__c = 'Active',
                NOI__c = 65000 + (i * 100),
                Market_Cap_Rate__c = 6.0,
                Argus_Value__c = 1000000 + (i * 1000),
                Target_Sale_Price__c = 1200000 + (i * 1000),
                Sell_Readiness_Score__c = 50,
                Vacant_Area__c = 0
            ));
        }
        insertIf(doInsert, assets);
        return assets;
    }

    /** Property Assets under the shared scaffold Property. @param count Number. @param doInsert Insert when true. @return Assets. */
    public static List<Property_Asset__c> createPropertyAssets(Integer count, Boolean doInsert) {
        return createPropertyAssets(count, defaultProperty().Id, doInsert);
    }

    /** Single Property Asset. @param propertyId Parent Property. @param doInsert Insert when true. @return The asset. */
    public static Property_Asset__c createPropertyAsset(Id propertyId, Boolean doInsert) {
        return createPropertyAssets(1, propertyId, doInsert)[0];
    }

    /**
     * Units. Property_Asset__c is a MASTER-DETAIL parent — mandatory.
     * Yardi_Unit_Id__c is a unique external id, so it is counter-backed.
     * @param count           Number of Units.
     * @param propertyAssetId Master Property_Asset__c (required).
     * @param doInsert        Insert when true.
     * @return Units.
     */
    public static List<Unit__c> createUnits(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        requireId(propertyAssetId, 'propertyAssetId (Unit__c.Property_Asset__c is Master-Detail)');
        List<Unit__c> units = new List<Unit__c>();
        for (Integer i = 0; i < count; i++) {
            units.add(new Unit__c(
                Property_Asset__c = propertyAssetId,
                Suite_Number__c = 'Suite ' + (100 + i),
                Tenant_Name__c = 'Test Tenant ' + i,
                Status__c = 'Occupied',
                Square_Feet__c = 1000 + (i * 10),
                Current_Monthly_Rent__c = 5000 + (i * 10),
                Current_Rent_PSF__c = 20,
                Asking_Rent_PSF__c = 22,
                Estimated_NNN_PSF__c = 5,
                Lease_Start__c = Date.today().addMonths(-12),
                Lease_End__c = Date.today().addMonths(12),
                Yardi_Unit_Id__c = 'YU-' + String.valueOf(nextUnique()).leftPad(10, '0')
            ));
        }
        insertIf(doInsert, units);
        return units;
    }

    /** Units under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Units. */
    public static List<Unit__c> createUnits(Integer count, Boolean doInsert) {
        return createUnits(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Unit. @param propertyAssetId Master asset. @param doInsert Insert when true. @return The Unit. */
    public static Unit__c createUnit(Id propertyAssetId, Boolean doInsert) {
        return createUnits(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Rent steps. Unit__c is a MASTER-DETAIL parent — mandatory.
     * Type__c has no picklist default, so it is set explicitly.
     * @param count    Number of Rent Steps.
     * @param unitId   Master Unit__c (required).
     * @param doInsert Insert when true.
     * @return Rent Steps.
     */
    public static List<Rent_Step__c> createRentSteps(Integer count, Id unitId, Boolean doInsert) {
        requirePositive(count);
        requireId(unitId, 'unitId (Rent_Step__c.Unit__c is Master-Detail)');
        List<Rent_Step__c> steps = new List<Rent_Step__c>();
        for (Integer i = 0; i < count; i++) {
            steps.add(new Rent_Step__c(
                Unit__c = unitId,
                Type__c = 'Current Term',
                Period_Label__c = 'Year ' + (i + 1),
                Period_Start__c = Date.today().addMonths(12 * i),
                Period_End__c = Date.today().addMonths(12 * (i + 1)).addDays(-1),
                Monthly_Rent__c = 5000 + (i * 250),
                Rent_PSF__c = 20 + i,
                Sort_Order__c = i + 1
            ));
        }
        insertIf(doInsert, steps);
        return steps;
    }

    /** Rent steps under the shared scaffold Unit. @param count Number. @param doInsert Insert when true. @return Rent Steps. */
    public static List<Rent_Step__c> createRentSteps(Integer count, Boolean doInsert) {
        return createRentSteps(count, defaultUnit().Id, doInsert);
    }

    /** Single Rent Step. @param unitId Master Unit. @param doInsert Insert when true. @return The Rent Step. */
    public static Rent_Step__c createRentStep(Id unitId, Boolean doInsert) {
        return createRentSteps(1, unitId, doInsert)[0];
    }

    /**
     * Builds the full Property -> Asset -> Unit -> Rent_Step chain in 4 DML
     * statements regardless of size. Use this instead of nesting factory calls
     * when a test needs the whole chain populated.
     *
     * Row arithmetic (assert against the 10,000 DML-rows limit before scaling):
     *   rows = 1 + assetCount + (assetCount * unitsPerAsset)
     *            + (assetCount * unitsPerAsset * stepsPerUnit)
     *
     * @param assetCount    Property_Asset__c records under one Property__c.
     * @param unitsPerAsset Unit__c per asset.
     * @param stepsPerUnit  Rent_Step__c per unit.
     * @return Populated graph.
     */
    public static PropertyGraph createPropertyGraph(Integer assetCount, Integer unitsPerAsset, Integer stepsPerUnit) {
        requirePositive(assetCount);
        PropertyGraph graph = new PropertyGraph();
        graph.property = createProperties(1, true)[0];
        graph.assets = createPropertyAssets(assetCount, graph.property.Id, true);

        graph.units = new List<Unit__c>();
        if (unitsPerAsset != null && unitsPerAsset > 0) {
            for (Property_Asset__c asset : graph.assets) {
                graph.units.addAll(createUnits(unitsPerAsset, asset.Id, false));
            }
            insert graph.units;
        }

        graph.rentSteps = new List<Rent_Step__c>();
        if (stepsPerUnit != null && stepsPerUnit > 0 && !graph.units.isEmpty()) {
            for (Unit__c unit : graph.units) {
                graph.rentSteps.addAll(createRentSteps(stepsPerUnit, unit.Id, false));
            }
            insert graph.rentSteps;
        }
        return graph;
    }

    /** Result of createPropertyGraph — the Property chain in one object. */
    public class PropertyGraph {
        public Property__c property;
        public List<Property_Asset__c> assets;
        public List<Unit__c> units;
        public List<Rent_Step__c> rentSteps;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ACQUISITIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /** NDA__c record type developer name for the buy-side NDA (the factory default). */
    public static final String NDA_RT_ACQUISITION = 'Acquisition_NDA';
    /** NDA__c record type developer name for the sell-side NDA. */
    public static final String NDA_RT_DISPOSITION = 'Disposition_NDA';

    /**
     * NDAs on the ACQUISITION record type. Remember OpportunityReviewTrigger.ensureNda already
     * creates one NDA per Opportunity on insert — these are additional.
     * @param count         Number of NDAs.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return NDAs at Status 'Pending', record type Acquisition_NDA.
     */
    public static List<NDA__c> createNdas(Integer count, Id opportunityId, Boolean doInsert) {
        return createNdas(count, opportunityId, NDA_RT_ACQUISITION, doInsert);
    }

    /**
     * NDAs on an explicit record type (D7 / D14.1). Same shape and same reasoning as
     * createDispositions — see that method's header for why the record type is stamped at all
     * rather than inherited from the test-running user's profile default.
     *
     * 🔴 THE SEED STATUS IS CHOSEN BY RECORD TYPE, AND IT HAS TO BE. The two value sets OVERLAP
     * but are not equal: 'Pending' exists only on Acquisition_NDA and 'Not Sent' only on
     * Disposition_NDA. Record-type picklist restriction is UI-only — Apex DML does NOT enforce
     * it — so a shared seed value would insert happily and produce a fixture whose status is off
     * its own record type's value set, which RecordStageAdvanceService would then refuse to
     * advance for reasons no test message would explain.
     *
     * ⚠ Party_Role__c is seeded ONLY on the disposition type. On an acquisition DPEG is itself
     * the buyer, so 'Buyer' would name US — the meaning inversion the Acquisition_NDA record type
     * file records, which is why that type carries the values with NO default.
     *
     * ⚠ The stamp is GUARDED on isAvailable(), exactly like createDispositions: an undeployed or
     * unassigned record type leaves RecordTypeId unset rather than turning every NDA test in the
     * repo red. A green suite is therefore NOT proof the record types landed — TestDataFactoryTest
     * and post-deploy gate T-A1 are.
     *
     * @param count                   Number of NDAs.
     * @param opportunityId           Parent Opportunity (nullable).
     * @param recordTypeDeveloperName NDA_RT_ACQUISITION or NDA_RT_DISPOSITION.
     * @param doInsert                Insert when true.
     * @return NDAs seeded at their record type's starting status.
     */
    public static List<NDA__c> createNdas(
        Integer count,
        Id opportunityId,
        String recordTypeDeveloperName,
        Boolean doInsert
    ) {
        requirePositive(count);
        Id recordTypeId = ndaRecordTypeId(recordTypeDeveloperName);
        Boolean isDisposition = NDA_RT_DISPOSITION.equals(recordTypeDeveloperName);
        List<NDA__c> ndas = new List<NDA__c>();
        for (Integer i = 0; i < count; i++) {
            NDA__c nda = new NDA__c(
                Opportunity__c = opportunityId,
                Status__c = isDisposition ? 'Not Sent' : 'Pending',
                Counterparty_Name__c = 'Test Counterparty ' + i,
                Method__c = 'DocuSign',
                Date_Sent__c = Date.today(),
                Is_Non_Expiring__c = false,
                NDA_Expiry_Date__c = Date.today().addYears(1)
            );
            if (isDisposition) {
                nda.Party_Role__c = 'Buyer';
            }
            if (recordTypeId != null) {
                nda.RecordTypeId = recordTypeId;
            }
            ndas.add(nda);
        }
        insertIf(doInsert, ndas);
        return ndas;
    }

    /**
     * NDAs parented to a DISPOSITION, on the Disposition_NDA record type — the shape
     * DispositionStageEntryService auto-creates and the shape the off-market all-signed gate
     * counts.
     *
     * ⚠ Party_Role__c is 'Buyer', which is also DispositionStageEntryService's idempotency key.
     * A test that wants to prove auto-create was SUPPRESSED seeds one of these first; a test that
     * wants auto-create to FIRE must not.
     *
     * @param count         Number of NDAs.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return NDAs at Status 'Not Sent', Party_Role__c 'Buyer', record type Disposition_NDA.
     */
    public static List<NDA__c> createDispositionNdas(
        Integer count,
        Id dispositionId,
        Boolean doInsert
    ) {
        List<NDA__c> ndas = createNdas(count, null, NDA_RT_DISPOSITION, false);
        for (NDA__c nda : ndas) {
            nda.Disposition__c = dispositionId;
        }
        insertIf(doInsert, ndas);
        return ndas;
    }

    /** Single disposition-parented NDA. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The NDA. */
    public static NDA__c createDispositionNda(Id dispositionId, Boolean doInsert) {
        return createDispositionNdas(1, dispositionId, doInsert)[0];
    }

    /**
     * Resolves an NDA__c record type developer name to its Id, or null when it does not exist in
     * this org / is not available to the running user. An UNRECOGNISED name is a caller mistake
     * and throws, so a typo fails loudly instead of silently producing a default-record-type
     * fixture.
     *
     * 🔴 THE ALLOW-LIST COMPARISON MUST BE CASE-SENSITIVE, AND `!=` IS NOT — the identical trap
     * dispositionRecordTypeId documents at length. Apex `==` / `!=` on String is
     * case-INSENSITIVE while getRecordTypeInfosByDeveloperName() keys its map case-SENSITIVELY,
     * so with `!=` a name like 'acquisition_nda' would pass the guard, miss the describe map, and
     * silently degrade to the platform default. `String.equals(Object)` is case-sensitive, so
     * guard and lookup answer the same question. Constant-first keeps a null argument on the
     * throw path rather than NPE-ing.
     */
    private static Id ndaRecordTypeId(String recordTypeDeveloperName) {
        if (!NDA_RT_ACQUISITION.equals(recordTypeDeveloperName)
            && !NDA_RT_DISPOSITION.equals(recordTypeDeveloperName)) {
            throw new TestDataFactoryException(
                'Unknown NDA__c record type: ' + recordTypeDeveloperName
                + '. Expected Acquisition_NDA or Disposition_NDA.'
            );
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.NDA__c
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** Signed NDAs — required to move an Opportunity into Underwriting. @param count Number. @param opportunityId Parent Opp. @param doInsert Insert when true. @return NDAs. */
    public static List<NDA__c> createSignedNdas(Integer count, Id opportunityId, Boolean doInsert) {
        List<NDA__c> ndas = createNdas(count, opportunityId, false);
        for (NDA__c nda : ndas) {
            nda.Status__c = 'Signed';
            nda.NDA_Signed__c = true;
            nda.Date_Signed__c = Date.today();
        }
        insertIf(doInsert, ndas);
        return ndas;
    }

    /** Single NDA. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The NDA. */
    public static NDA__c createNda(Id opportunityId, Boolean doInsert) {
        return createNdas(1, opportunityId, doInsert)[0];
    }

    /** LOI__c record type developer name for the buy-side LOI (the factory default). */
    public static final String LOI_RT_ACQUISITION = 'Acquisition_LOI';
    /** LOI__c record type developer name for the sell-side LOI. */
    public static final String LOI_RT_DISPOSITION = 'Disposition_LOI';

    /**
     * LOIs on the ACQUISITION record type — the shape OpportunityReviewService auto-creates on
     * entry to the LOI stage.
     *
     * @param count         Number of LOIs.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return LOIs at stage 'Draft', record type Acquisition_LOI.
     */
    public static List<LOI__c> createLois(Integer count, Id opportunityId, Boolean doInsert) {
        return createLois(count, opportunityId, LOI_RT_ACQUISITION, doInsert);
    }

    /**
     * LOIs on an explicit record type (D6, Tranche 3B). Same shape and same reasoning as
     * createNdas / createDispositions — see createDispositions' header for why the record type is
     * stamped at all rather than inherited from the test-running user's profile default.
     *
     * 🔴 THE SEED STAGE IS CHOSEN BY RECORD TYPE, AND IT HAS TO BE. Unlike NDA__c the two LOI
     * value sets are FULLY DISJOINT — 'Draft' exists only on Acquisition_LOI and 'Received' only on
     * Disposition_LOI, with no overlap at all — so there is no shared value that would work for
     * both. Record-type picklist restriction is UI-only (Apex DML does NOT enforce it), so a
     * hardcoded 'Draft' would insert happily onto a disposition LOI and produce a fixture whose
     * stage is off its own record type's value set, which RecordStageAdvanceService would then
     * refuse to advance for reasons no test message would explain.
     *
     * ⚠ Submitted_Date__c is seeded ONLY on the acquisition type. It is acquisition-directional
     * (DPEG submits the LOI on a purchase; on a sale the LOI ARRIVES from the buyer), and the
     * Disposition_LOI record type file layout-excludes it. Same per-type treatment createNdas
     * gives Party_Role__c.
     *
     * ⚠ The stamp is GUARDED on isAvailable(), exactly like createNdas / createDispositions: an
     * undeployed or unassigned record type leaves RecordTypeId unset rather than turning every LOI
     * test in the repo red. A green suite is therefore NOT proof the record types landed —
     * TestDataFactoryTest and post-deploy gate T-A1 are.
     *
     * @param count                   Number of LOIs.
     * @param opportunityId           Parent Opportunity (nullable).
     * @param recordTypeDeveloperName LOI_RT_ACQUISITION or LOI_RT_DISPOSITION.
     * @param doInsert                Insert when true.
     * @return LOIs seeded at their record type's starting stage.
     */
    public static List<LOI__c> createLois(
        Integer count,
        Id opportunityId,
        String recordTypeDeveloperName,
        Boolean doInsert
    ) {
        requirePositive(count);
        Id recordTypeId = loiRecordTypeId(recordTypeDeveloperName);
        Boolean isDisposition = LOI_RT_DISPOSITION.equals(recordTypeDeveloperName);
        List<LOI__c> lois = new List<LOI__c>();
        for (Integer i = 0; i < count; i++) {
            LOI__c loi = new LOI__c(
                Opportunity__c = opportunityId,
                Stage__c = isDisposition ? 'Received' : 'Draft',
                Offer_Price__c = 1000000 + (i * 1000),
                Offer_Cap_Rate__c = 6.5,
                Earnest_Money__c = 50000,
                Due_Diligence_Days__c = 45,
                Closing_Period_Days__c = 30,
                NOI__c = 65000 + (i * 100),
                Square_Footage__c = 10000 + (i * 100),
                Title_Company__c = 'Test Title Co'
            );
            if (!isDisposition) {
                loi.Submitted_Date__c = Date.today();
            }
            if (recordTypeId != null) {
                loi.RecordTypeId = recordTypeId;
            }
            lois.add(loi);
        }
        insertIf(doInsert, lois);
        return lois;
    }

    /**
     * LOIs parented to a DISPOSITION, on the Disposition_LOI record type — the sell-side
     * negotiation record D6 migrates off Disposition_Offer__c.
     *
     * ⚠ Opportunity__c is left NULL deliberately. A disposition LOI hangs off Disposition__c
     * only, and that lookup is CounterOfferService.isSaleSide's fallback discriminator for the
     * migration window in which every row still sits on the Master record type — a fixture
     * carrying both parents would make the two clauses of that rule indistinguishable.
     *
     * @param count         Number of LOIs.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return LOIs at stage 'Received', record type Disposition_LOI.
     */
    public static List<LOI__c> createDispositionLois(
        Integer count,
        Id dispositionId,
        Boolean doInsert
    ) {
        List<LOI__c> lois = createLois(count, null, LOI_RT_DISPOSITION, false);
        for (LOI__c loi : lois) {
            loi.Disposition__c = dispositionId;
        }
        insertIf(doInsert, lois);
        return lois;
    }

    /** Single disposition-parented LOI. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The LOI. */
    public static LOI__c createDispositionLoi(Id dispositionId, Boolean doInsert) {
        return createDispositionLois(1, dispositionId, doInsert)[0];
    }

    /**
     * Resolves an LOI__c record type developer name to its Id, or null when it does not exist in
     * this org / is not available to the running user. An UNRECOGNISED name is a caller mistake
     * and throws, so a typo fails loudly instead of silently producing a default-record-type
     * fixture.
     *
     * 🔴 THE ALLOW-LIST COMPARISON MUST BE CASE-SENSITIVE, AND `!=` IS NOT — the identical trap
     * dispositionRecordTypeId documents at length. Apex `==` / `!=` on String is
     * case-INSENSITIVE while getRecordTypeInfosByDeveloperName() keys its map case-SENSITIVELY,
     * so with `!=` a name like 'acquisition_loi' would pass the guard, miss the describe map, and
     * silently degrade to the platform default. `String.equals(Object)` is case-sensitive, so
     * guard and lookup answer the same question. Constant-first keeps a null argument on the
     * throw path rather than NPE-ing.
     */
    private static Id loiRecordTypeId(String recordTypeDeveloperName) {
        if (!LOI_RT_ACQUISITION.equals(recordTypeDeveloperName)
            && !LOI_RT_DISPOSITION.equals(recordTypeDeveloperName)) {
            throw new TestDataFactoryException(
                'Unknown LOI__c record type: ' + recordTypeDeveloperName
                + '. Expected Acquisition_LOI or Disposition_LOI.'
            );
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.LOI__c
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** LOIs under the shared scaffold Opportunity. @param count Number. @param doInsert Insert when true. @return LOIs. */
    public static List<LOI__c> createLois(Integer count, Boolean doInsert) {
        return createLois(count, defaultOpportunity().Id, doInsert);
    }

    /** Single LOI. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The LOI. */
    public static LOI__c createLoi(Id opportunityId, Boolean doInsert) {
        return createLois(1, opportunityId, doInsert)[0];
    }

    /**
     * Counter offers. Direction__c has no picklist default, so it is set.
     * @param count    Number of Counter Offers.
     * @param loiId    Parent LOI__c (required for a meaningful record).
     * @param doInsert Insert when true.
     * @return Counter Offers.
     */
    public static List<Counter_Offer__c> createCounterOffers(Integer count, Id loiId, Boolean doInsert) {
        requirePositive(count);
        requireId(loiId, 'loiId');
        List<Counter_Offer__c> counters = new List<Counter_Offer__c>();
        for (Integer i = 0; i < count; i++) {
            counters.add(new Counter_Offer__c(
                LOI__c = loiId,
                Direction__c = 'Seller',
                Counter_Price__c = 1050000 + (i * 1000),
                Counter_Cap_Rate__c = 6.25,
                Counter_Date__c = Date.today().addDays(i),
                Revision_Number__c = String.valueOf(i + 1) // TEXT despite the "_Number" suffix
            ));
        }
        insertIf(doInsert, counters);
        return counters;
    }

    /** Counter offers under the shared scaffold LOI. @param count Number. @param doInsert Insert when true. @return Counter Offers. */
    public static List<Counter_Offer__c> createCounterOffers(Integer count, Boolean doInsert) {
        return createCounterOffers(count, defaultLoi().Id, doInsert);
    }

    /** Single Counter Offer. @param loiId Parent LOI. @param doInsert Insert when true. @return The Counter Offer. */
    public static Counter_Offer__c createCounterOffer(Id loiId, Boolean doInsert) {
        return createCounterOffers(1, loiId, doInsert)[0];
    }

    /**
     * @param count         Number of Underwritings.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return Underwritings at stage 'Requested'.
     */
    public static List<Underwriting__c> createUnderwritings(Integer count, Id opportunityId, Boolean doInsert) {
        requirePositive(count);
        List<Underwriting__c> records = new List<Underwriting__c>();
        for (Integer i = 0; i < count; i++) {
            records.add(new Underwriting__c(
                Opportunity__c = opportunityId,
                Stage__c = 'Requested',
                Status__c = 'In Progress',
                My_Price__c = 1000000 + (i * 1000),
                My_Cap_Rate__c = 6.75,
                Market_Cap_Rate__c = 6.0,
                Underwritten_NOI__c = 65000 + (i * 100),
                Equity_Required__c = 300000,
                Projected_Loan__c = 700000,
                Hold_Period__c = 5,
                Target_Return__c = 15,
                Year_5_IRR__c = 16,
                Equity_Multiple__c = 1.8,
                Cash_On_Cash_Return__c = 8,
                GRM__c = 12
            ));
        }
        insertIf(doInsert, records);
        return records;
    }

    /** Underwritings under the shared scaffold Opportunity. @param count Number. @param doInsert Insert when true. @return Underwritings. */
    public static List<Underwriting__c> createUnderwritings(Integer count, Boolean doInsert) {
        return createUnderwritings(count, defaultOpportunity().Id, doInsert);
    }

    /** Single Underwriting. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The Underwriting. */
    public static Underwriting__c createUnderwriting(Id opportunityId, Boolean doInsert) {
        return createUnderwritings(1, opportunityId, doInsert)[0];
    }

    /** Contract_Review__c record type developer name for the buy-side PSA (the factory default). */
    public static final String CONTRACT_REVIEW_RT_ACQUISITION = 'Acquisition_PSA';
    /** Contract_Review__c record type developer name for the sell-side PSA. */
    public static final String CONTRACT_REVIEW_RT_DISPOSITION = 'Disposition_PSA';

    /**
     * Contract Reviews on the ACQUISITION record type — the shape OpportunityReviewService
     * auto-creates on entry to the PSA stage.
     *
     * @param count         Number of Contract Reviews.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return Contract Reviews at stage 'PSA Drafting', record type Acquisition_PSA.
     */
    public static List<Contract_Review__c> createContractReviews(Integer count, Id opportunityId, Boolean doInsert) {
        return createContractReviews(count, opportunityId, CONTRACT_REVIEW_RT_ACQUISITION, doInsert);
    }

    /**
     * Contract Reviews on an explicit record type (D16.3, Tranche 3C). Same shape and same
     * reasoning as createNdas / createLois / createDispositions — see createDispositions' header
     * for why the record type is stamped at all rather than inherited from the test-running user's
     * profile default.
     *
     * 🔴 UNLIKE createNdas AND createLois, NOTHING ELSE IN THE ROW VARIES BY RECORD TYPE, AND THAT
     * IS THE INTERESTING PART RATHER THAN AN OMISSION. Those two branch their seed STAGE because
     * their value sets differ ('Pending' vs 'Not Sent'; 'Draft' vs 'Received'). Both PSA record
     * types expose the IDENTICAL four Negotiation_Status__c values and the identical three Stage__c
     * values — Disposition_PSA's own record type file states this is deliberate — so one seed is
     * correct for both and a branch here would be inventing a difference that does not exist.
     *
     * ⚠ Ball_In_Court__c IS DELIBERATELY LEFT UNSET on both types, even though it is the ONE field
     * whose value set genuinely differs ('Seller' on Acquisition_PSA, 'Buyer' on Disposition_PSA —
     * the inversion those record types exist to fix). Two reasons: this factory has never seeded
     * it, so seeding it now would silently change the starting state of every existing Contract
     * Review fixture in the repo; and nothing DERIVES from a seeded value — PsaVersionService
     * WRITES the field, so a fixture that pre-populates it can only mask a bug in that write. A
     * test that needs a starting ball-in-court should set it explicitly and say why.
     *
     * ⚠ The stamp is GUARDED on isAvailable(), exactly like createNdas / createLois /
     * createDispositions: an undeployed or unassigned record type leaves RecordTypeId unset rather
     * than turning every Contract Review test in the repo red. A green suite is therefore NOT proof
     * the record types landed — TestDataFactoryTest and post-deploy gate T-A1 are.
     *
     * @param count                   Number of Contract Reviews.
     * @param opportunityId           Parent Opportunity (nullable).
     * @param recordTypeDeveloperName CONTRACT_REVIEW_RT_ACQUISITION or CONTRACT_REVIEW_RT_DISPOSITION.
     * @param doInsert                Insert when true.
     * @return Contract Reviews at stage 'PSA Drafting'.
     */
    public static List<Contract_Review__c> createContractReviews(
        Integer count,
        Id opportunityId,
        String recordTypeDeveloperName,
        Boolean doInsert
    ) {
        requirePositive(count);
        Id recordTypeId = contractReviewRecordTypeId(recordTypeDeveloperName);
        List<Contract_Review__c> reviews = new List<Contract_Review__c>();
        for (Integer i = 0; i < count; i++) {
            Contract_Review__c cr = new Contract_Review__c(
                Opportunity__c = opportunityId,
                // ⚠ Stage__c is a DERIVED PROJECTION — Contract_Review_Stage_Sync recomputes it from
                // Negotiation_Status__c on every save, so this seed is replaced on insert by the
                // flow's mapping of the status default (which produces this same value). It is kept
                // because removing it changes nothing and would read like a fix.
                Stage__c = 'PSA Drafting',
                Contract_Value__c = 1000000 + (i * 1000),
                PSA_Date__c = Date.today()
            );
            if (recordTypeId != null) {
                cr.RecordTypeId = recordTypeId;
            }
            reviews.add(cr);
        }
        insertIf(doInsert, reviews);
        return reviews;
    }

    /**
     * Contract Reviews parented to a DISPOSITION, on the Disposition_PSA record type — the
     * sell-side PSA whose execution ContractExecutionService turns into a `Closing` stage advance.
     *
     * ⚠ Opportunity__c is left NULL deliberately, and here that is load-bearing rather than merely
     * tidy: `ContractExecutionService.handleExecution` runs its two arms off the two parent
     * LOOKUPS, not off the record type, so a fixture carrying BOTH parents would run BOTH arms and
     * make the acquisition and disposition assertions indistinguishable.
     *
     * @param count         Number of Contract Reviews.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Contract Reviews at stage 'PSA Drafting', record type Disposition_PSA.
     */
    public static List<Contract_Review__c> createDispositionContractReviews(
        Integer count,
        Id dispositionId,
        Boolean doInsert
    ) {
        List<Contract_Review__c> reviews =
            createContractReviews(count, null, CONTRACT_REVIEW_RT_DISPOSITION, false);
        for (Contract_Review__c cr : reviews) {
            cr.Disposition__c = dispositionId;
        }
        insertIf(doInsert, reviews);
        return reviews;
    }

    /** Single disposition-parented Contract Review. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The Contract Review. */
    public static Contract_Review__c createDispositionContractReview(Id dispositionId, Boolean doInsert) {
        return createDispositionContractReviews(1, dispositionId, doInsert)[0];
    }

    /**
     * Resolves a Contract_Review__c record type developer name to its Id, or null when it does not
     * exist in this org / is not available to the running user. An UNRECOGNISED name is a caller
     * mistake and throws, so a typo fails loudly instead of silently producing a
     * default-record-type fixture.
     *
     * 🔴 THE ALLOW-LIST COMPARISON MUST BE CASE-SENSITIVE, AND `!=` IS NOT — the identical trap
     * dispositionRecordTypeId documents at length. Apex `==` / `!=` on String is case-INSENSITIVE
     * while getRecordTypeInfosByDeveloperName() keys its map case-SENSITIVELY, so with `!=` a name
     * like 'acquisition_psa' would pass the guard, miss the describe map, and silently degrade to
     * the platform default. `String.equals(Object)` is case-sensitive, so guard and lookup answer
     * the same question. Constant-first keeps a null argument on the throw path rather than
     * NPE-ing.
     *
     * ⚠ THE SILENT DEGRADATION WOULD BE HARDER TO SPOT ON THIS OBJECT THAN ON ITS TWO SIBLINGS,
     * which is why the guard matters more here rather than less. A mis-typed NDA or LOI record type
     * produces a fixture whose stage is off its own value set and whose walk test fails; a mis-typed
     * PSA record type produces a fixture that walks PERFECTLY (both types share one sequence) and
     * is wrong only about which PERSONA may drive it.
     */
    private static Id contractReviewRecordTypeId(String recordTypeDeveloperName) {
        if (!CONTRACT_REVIEW_RT_ACQUISITION.equals(recordTypeDeveloperName)
            && !CONTRACT_REVIEW_RT_DISPOSITION.equals(recordTypeDeveloperName)) {
            throw new TestDataFactoryException(
                'Unknown Contract_Review__c record type: ' + recordTypeDeveloperName
                + '. Expected Acquisition_PSA or Disposition_PSA.'
            );
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.Contract_Review__c
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** Contract Reviews under the shared scaffold Opportunity. @param count Number. @param doInsert Insert when true. @return Contract Reviews. */
    public static List<Contract_Review__c> createContractReviews(Integer count, Boolean doInsert) {
        return createContractReviews(count, defaultOpportunity().Id, doInsert);
    }

    /** Single Contract Review. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The Contract Review. */
    public static Contract_Review__c createContractReview(Id opportunityId, Boolean doInsert) {
        return createContractReviews(1, opportunityId, doInsert)[0];
    }

    /**
     * PSA versions. Contract_Review__c is a REQUIRED lookup (deleteConstraint
     * Restrict). Direction__c has no picklist default, so it is set.
     * @param count            Number of PSA Versions.
     * @param contractReviewId Parent Contract_Review__c (required).
     * @param doInsert         Insert when true.
     * @return PSA Versions.
     */
    public static List<PSA_Version__c> createPsaVersions(Integer count, Id contractReviewId, Boolean doInsert) {
        requirePositive(count);
        requireId(contractReviewId, 'contractReviewId (PSA_Version__c.Contract_Review__c is required)');
        List<PSA_Version__c> versions = new List<PSA_Version__c>();
        for (Integer i = 0; i < count; i++) {
            versions.add(new PSA_Version__c(
                Contract_Review__c = contractReviewId,
                Direction__c = 'Ours',
                Version_Date__c = Date.today().addDays(i),
                Summary__c = 'Test PSA version ' + i,
                Document_URL__c = 'https://example.invalid/psa/' + i
            ));
        }
        insertIf(doInsert, versions);
        return versions;
    }

    /** PSA versions under the shared scaffold Contract Review. @param count Number. @param doInsert Insert when true. @return PSA Versions. */
    public static List<PSA_Version__c> createPsaVersions(Integer count, Boolean doInsert) {
        return createPsaVersions(count, defaultContractReview().Id, doInsert);
    }

    /** Single PSA Version. @param contractReviewId Parent Contract Review. @param doInsert Insert when true. @return The PSA Version. */
    public static PSA_Version__c createPsaVersion(Id contractReviewId, Boolean doInsert) {
        return createPsaVersions(1, contractReviewId, doInsert)[0];
    }

    /**
     * Deal messages parented to an LOI. The active Exactly_One_Parent validation
     * rule requires EXACTLY one of LOI / Underwriting / Contract Review — hence
     * three distinct methods rather than one with nullable parents.
     * @param count    Number of Deal Messages.
     * @param loiId    Parent LOI__c (required).
     * @param doInsert Insert when true.
     * @return Deal Messages.
     */
    public static List<Deal_Message__c> createDealMessagesForLoi(Integer count, Id loiId, Boolean doInsert) {
        requireId(loiId, 'loiId');
        List<Deal_Message__c> messages = buildDealMessages(count);
        for (Deal_Message__c message : messages) {
            message.LOI__c = loiId;
        }
        insertIf(doInsert, messages);
        return messages;
    }

    /**
     * Deal messages parented to an Underwriting (exactly-one-parent rule).
     * @param count          Number of Deal Messages.
     * @param underwritingId Parent Underwriting__c (required).
     * @param doInsert       Insert when true.
     * @return Deal Messages.
     */
    public static List<Deal_Message__c> createDealMessagesForUnderwriting(
        Integer count,
        Id underwritingId,
        Boolean doInsert
    ) {
        requireId(underwritingId, 'underwritingId');
        List<Deal_Message__c> messages = buildDealMessages(count);
        for (Deal_Message__c message : messages) {
            message.Underwriting__c = underwritingId;
        }
        insertIf(doInsert, messages);
        return messages;
    }

    /**
     * Deal messages parented to a Contract Review (exactly-one-parent rule).
     * @param count            Number of Deal Messages.
     * @param contractReviewId Parent Contract_Review__c (required).
     * @param doInsert         Insert when true.
     * @return Deal Messages.
     */
    public static List<Deal_Message__c> createDealMessagesForContractReview(
        Integer count,
        Id contractReviewId,
        Boolean doInsert
    ) {
        requireId(contractReviewId, 'contractReviewId');
        List<Deal_Message__c> messages = buildDealMessages(count);
        for (Deal_Message__c message : messages) {
            message.Contract_Review__c = contractReviewId;
        }
        insertIf(doInsert, messages);
        return messages;
    }

    private static List<Deal_Message__c> buildDealMessages(Integer count) {
        requirePositive(count);
        Datetime entryStamp = System.now();
        List<Deal_Message__c> messages = new List<Deal_Message__c>();
        for (Integer i = 0; i < count; i++) {
            messages.add(new Deal_Message__c(
                Direction__c = 'Internal',
                Method__c = 'Note',
                Entry_DateTime__c = entryStamp, // ARCHITECTURE.md §1 rule-9 stamp
                Details__c = 'Test deal message ' + i,
                Revision__c = String.valueOf(i + 1) // TEXT, not Number
            ));
        }
        return messages;
    }

    /**
     * @param count         Number of Development Feasibility Reviews.
     * @param opportunityId Parent Opportunity (nullable).
     * @param propertyId    Parent Property__c (nullable).
     * @param doInsert      Insert when true.
     * @return Reviews at stage 'Requested'.
     */
    public static List<Development_Feasibility_Review__c> createDevelopmentReviews(
        Integer count,
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Development_Feasibility_Review__c> reviews = new List<Development_Feasibility_Review__c>();
        for (Integer i = 0; i < count; i++) {
            reviews.add(new Development_Feasibility_Review__c(
                Opportunity__c = opportunityId,
                Property__c = propertyId,
                Requested_By__c = UserInfo.getUserId(),
                Stage__c = 'Requested',
                Architecture_Firm__c = 'Test Architects ' + i,
                Developable_Area__c = 5000 + (i * 10),
                Proposals_Target__c = '3',        // TEXT, not Number
                Proposals_Received__c = 0,
                Est_Cost_Impact__c = '100000'     // TEXT, not Currency
            ));
        }
        insertIf(doInsert, reviews);
        return reviews;
    }

    /** Single Development Feasibility Review. @param opportunityId Parent Opp. @param propertyId Parent Property. @param doInsert Insert when true. @return The review. */
    public static Development_Feasibility_Review__c createDevelopmentReview(
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        return createDevelopmentReviews(1, opportunityId, propertyId, doInsert)[0];
    }

    /**
     * @param count         Number of Construction Feasibility Reviews.
     * @param opportunityId Parent Opportunity (nullable).
     * @param propertyId    Parent Property__c (nullable).
     * @param doInsert      Insert when true.
     * @return Reviews at stage 'Requested'.
     */
    public static List<Construction_Feasibility_Review__c> createConstructionReviews(
        Integer count,
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Construction_Feasibility_Review__c> reviews = new List<Construction_Feasibility_Review__c>();
        for (Integer i = 0; i < count; i++) {
            reviews.add(new Construction_Feasibility_Review__c(
                Opportunity__c = opportunityId,
                Property__c = propertyId,
                Requested_By__c = UserInfo.getUserId(),
                Stage__c = 'Requested',
                Roof_Age_Years__c = 10,
                Estimated_Roof_Cost__c = 50000,
                Estimated_MEP_Cost__c = 25000,
                Estimated_Upgrade_Cost__c = 75000,
                Estimated_Timeline_Impact__c = '30', // TEXT, not Number
                Addition_Work_Required__c = false
            ));
        }
        insertIf(doInsert, reviews);
        return reviews;
    }

    /** Single Construction Feasibility Review. @param opportunityId Parent Opp. @param propertyId Parent Property. @param doInsert Insert when true. @return The review. */
    public static Construction_Feasibility_Review__c createConstructionReview(
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        return createConstructionReviews(1, opportunityId, propertyId, doInsert)[0];
    }

    /**
     * @param count         Number of Offerings.
     * @param opportunityId Parent Opportunity (nullable).
     * @param doInsert      Insert when true.
     * @return Offerings at status 'Draft'.
     */
    public static List<Offering__c> createOfferings(Integer count, Id opportunityId, Boolean doInsert) {
        requirePositive(count);
        List<Offering__c> offerings = new List<Offering__c>();
        for (Integer i = 0; i < count; i++) {
            offerings.add(new Offering__c(
                Opportunity__c = opportunityId,
                Status__c = 'Draft'
            ));
        }
        insertIf(doInsert, offerings);
        return offerings;
    }

    /** Single Offering. @param opportunityId Parent Opp. @param doInsert Insert when true. @return The Offering. */
    public static Offering__c createOffering(Id opportunityId, Boolean doInsert) {
        return createOfferings(1, opportunityId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // TRANSACTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count         Number of Transactions.
     * @param opportunityId Parent Opportunity (nullable).
     * @param propertyId    Parent Property__c (nullable).
     * @param doInsert      Insert when true.
     * @return Transactions at stage 'Open Contract'.
     */
    public static List<Transaction__c> createTransactions(
        Integer count,
        Id opportunityId,
        Id propertyId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Transaction__c> transactions = new List<Transaction__c>();
        for (Integer i = 0; i < count; i++) {
            transactions.add(new Transaction__c(
                Opportunity__c = opportunityId,
                Property__c = propertyId,
                Stage__c = 'Open Contract',
                Status__c = 'Active',
                Contract_Value__c = 1000000 + (i * 1000),
                Earnest_Money__c = 50000,
                Loan_Required__c = false,
                Contract_Executed_Date__c = Date.today(),
                Feasibility_Deadline__c = Date.today().addDays(45),
                Target_Close_Date__c = Date.today().addDays(75),
                // Is_Wire_Approval_Due__c is a CHECKBOX despite the date-sounding name.
                Is_Wire_Approval_Due__c = false
            ));
        }
        insertIf(doInsert, transactions);
        return transactions;
    }

    /** Standalone Transactions (no parents). @param count Number. @param doInsert Insert when true. @return Transactions. */
    public static List<Transaction__c> createTransactions(Integer count, Boolean doInsert) {
        return createTransactions(count, null, null, doInsert);
    }

    /** Single Transaction. @param opportunityId Parent Opp. @param propertyId Parent Property. @param doInsert Insert when true. @return The Transaction. */
    public static Transaction__c createTransaction(Id opportunityId, Id propertyId, Boolean doInsert) {
        return createTransactions(1, opportunityId, propertyId, doInsert)[0];
    }

    /**
     * Critical dates. BOTH Transaction__c and Due_Date__c are schema-required.
     * Type__c has no picklist default, so it is set.
     * @param count         Number of Critical Dates.
     * @param transactionId Parent Transaction__c (required).
     * @param doInsert      Insert when true.
     * @return Critical Dates.
     */
    public static List<Critical_Date__c> createCriticalDates(Integer count, Id transactionId, Boolean doInsert) {
        requirePositive(count);
        requireId(transactionId, 'transactionId (Critical_Date__c.Transaction__c is required)');
        List<Critical_Date__c> dates = new List<Critical_Date__c>();
        for (Integer i = 0; i < count; i++) {
            dates.add(new Critical_Date__c(
                Transaction__c = transactionId,
                Type__c = 'Closing Date',
                Due_Date__c = Date.today().addDays(30 + i)
            ));
        }
        insertIf(doInsert, dates);
        return dates;
    }

    /** Critical dates under the shared scaffold Transaction. @param count Number. @param doInsert Insert when true. @return Critical Dates. */
    public static List<Critical_Date__c> createCriticalDates(Integer count, Boolean doInsert) {
        return createCriticalDates(count, defaultTransaction().Id, doInsert);
    }

    /** Single Critical Date. @param transactionId Parent Transaction. @param doInsert Insert when true. @return The Critical Date. */
    public static Critical_Date__c createCriticalDate(Id transactionId, Boolean doInsert) {
        return createCriticalDates(1, transactionId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DISPOSITIONS
    // NOTE: Wire__c parents to Disposition__c, NOT Transaction__c — the org has no
    // Wire__c -> Transaction__c relationship. Transaction__c.Wire_Open_Risks__c is
    // computed from checklist Tasks, not from Wire__c.
    // ═══════════════════════════════════════════════════════════════════════════

    /** Disposition__c record type developer name for the broker-listed path (the factory default). */
    public static final String DISPOSITION_RT_ON_MARKET = 'On_Market';
    /** Disposition__c record type developer name for the direct-sale path. */
    public static final String DISPOSITION_RT_OFF_MARKET = 'Off_Market';

    /**
     * @param count           Number of Dispositions.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Dispositions at stage 'Disposition Readiness', record type On_Market.
     */
    public static List<Disposition__c> createDispositions(Integer count, Id propertyAssetId, Boolean doInsert) {
        return createDispositions(count, propertyAssetId, DISPOSITION_RT_ON_MARKET, doInsert);
    }

    /**
     * Dispositions on an explicit record type.
     *
     * 🔴 WHY THE RECORD TYPE IS STAMPED AT ALL. Leaving RecordTypeId unset makes every
     * test's Disposition inherit the TEST-RUNNING USER'S PROFILE DEFAULT — which is org
     * state, is not deployable (`profiles/**` is .forceignore'd), and differs between a
     * scratch org and usman-dpeg. A test whose fixture depends on that is green or red
     * depending on who runs it. Stamping it makes the fixture a property of this file.
     *
     * ⚠ The stamp is GUARDED, not asserted. When the record type does not exist in the org
     * (e.g. the §4 metadata has not deployed yet) RecordTypeId is left unset and the
     * platform default applies. That is deliberate: an undeployed record type must not turn
     * every disposition test in the repo red, and the guard costs one describe. It does
     * mean a green suite is NOT proof the record types deployed — post-deploy gate B4 is.
     *
     * ⚠ On_Market and Off_Market carry DISJOINT Disposition_Stage__c value sets. This
     * factory seeds 'Disposition Readiness', which is valid on BOTH, so either record type
     * inserts cleanly. A caller that moves the record to a path-specific stage must pick the
     * matching record type: 'BOV Outreach' / 'Active Listing' / 'Call for Offers' are
     * On_Market only, and 'NDA' / 'Disposition Offer' are Off_Market only.
     *
     * ⚠ Stage is NEVER seeded as 'Completed'. The Wire_Complete_Before_Completed validation
     * rule fires on OR(ISNEW(), ISCHANGED(Disposition_Stage__c)) and would refuse the
     * insert unless the derived Wire_Verification_Completed__c were already true — which no
     * brand-new record can be.
     *
     * @param count                   Number of Dispositions.
     * @param propertyAssetId         Parent Property_Asset__c (nullable).
     * @param recordTypeDeveloperName DISPOSITION_RT_ON_MARKET or DISPOSITION_RT_OFF_MARKET.
     * @param doInsert                Insert when true.
     * @return Dispositions at stage 'Disposition Readiness'.
     */
    public static List<Disposition__c> createDispositions(
        Integer count,
        Id propertyAssetId,
        String recordTypeDeveloperName,
        Boolean doInsert
    ) {
        requirePositive(count);
        Id recordTypeId = dispositionRecordTypeId(recordTypeDeveloperName);
        List<Disposition__c> dispositions = new List<Disposition__c>();
        for (Integer i = 0; i < count; i++) {
            dispositions.add(new Disposition__c(
                Property_Asset__c = propertyAssetId,
                Disposition_Stage__c = 'Disposition Readiness',
                Listing_Date__c = Date.today(),
                Submission_Deadline__c = Date.today().addDays(30),
                Closing_Date__c = Date.today().addDays(90),
                Brokers_Contacted__c = 0,
                Responses_Received__c = 0,
                Gross_Sale_Proceeds__c = 1200000 + (i * 1000),
                Selling_Costs__c = 60000,
                Title_Company__c = 'Test Title Co',
                PSA_Executed__c = false,
                // Package_Sent__c is a DATE despite the Boolean-sounding name.
                Package_Sent__c = Date.today(),
                Closing_Statement_Uploaded__c = false
            ));
        }
        if (recordTypeId != null) {
            for (Disposition__c d : dispositions) {
                d.RecordTypeId = recordTypeId;
            }
        }
        insertIf(doInsert, dispositions);
        return dispositions;
    }

    /**
     * Resolves a Disposition__c record type developer name to its Id, or null when it does
     * not exist in this org / is not available to the running user (see the guard rationale
     * on createDispositions). An UNRECOGNISED name is a caller mistake and throws, so a typo
     * fails loudly instead of silently producing a default-record-type fixture.
     *
     * 🔴 THE ALLOW-LIST COMPARISON MUST BE CASE-SENSITIVE, AND `!=` IS NOT. Apex `==` / `!=`
     * on String is case-INSENSITIVE, while `getRecordTypeInfosByDeveloperName()` keys the map
     * case-SENSITIVELY. With `!=` the two disagreed, and the disagreement is exactly the hole
     * this method exists to close: 'on_market' passed the allow-list (case-insensitively
     * equal to the constant), then missed the describe map (case-sensitively different), and
     * returned null — the silent degrade-to-platform-default the throw was written to
     * prevent. `String.equals(Object)` is case-sensitive, so the guard and the lookup now
     * answer the same question. Both constants are non-null literals, so a null argument is
     * simply not equal to either and still throws, unchanged.
     */
    private static Id dispositionRecordTypeId(String recordTypeDeveloperName) {
        if (!DISPOSITION_RT_ON_MARKET.equals(recordTypeDeveloperName)
            && !DISPOSITION_RT_OFF_MARKET.equals(recordTypeDeveloperName)) {
            throw new TestDataFactoryException(
                'Unknown Disposition__c record type: ' + recordTypeDeveloperName
                + '. Expected On_Market or Off_Market.'
            );
        }
        Schema.RecordTypeInfo info = Schema.SObjectType.Disposition__c
            .getRecordTypeInfosByDeveloperName()
            .get(recordTypeDeveloperName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** Dispositions under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Dispositions. */
    public static List<Disposition__c> createDispositions(Integer count, Boolean doInsert) {
        return createDispositions(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Disposition on an explicit record type. @param propertyAssetId Parent asset. @param recordTypeDeveloperName On_Market or Off_Market. @param doInsert Insert when true. @return The Disposition. */
    public static Disposition__c createDisposition(Id propertyAssetId, String recordTypeDeveloperName, Boolean doInsert) {
        return createDispositions(1, propertyAssetId, recordTypeDeveloperName, doInsert)[0];
    }

    /** Single Disposition. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The Disposition. */
    public static Disposition__c createDisposition(Id propertyAssetId, Boolean doInsert) {
        return createDispositions(1, propertyAssetId, doInsert)[0];
    }

    /**
     * @param count         Number of Disposition Offers.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Offers at status 'Received'.
     */
    public static List<Disposition_Offer__c> createDispositionOffers(Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<Disposition_Offer__c> offers = new List<Disposition_Offer__c>();
        for (Integer i = 0; i < count; i++) {
            offers.add(new Disposition_Offer__c(
                Disposition__c = dispositionId,
                Offer_Status__c = 'Received',
                Buyer_Name__c = 'Test Buyer ' + i,
                Offer_Amount__c = 1150000 + (i * 1000),
                Offer_Date__c = Date.today(),
                Earnest_Money_Proposed__c = 50000,
                Due_Diligence_Days__c = 30,
                Closing_Period_Days__c = 30
            ));
        }
        insertIf(doInsert, offers);
        return offers;
    }

    /** Disposition Offers under the shared scaffold Disposition. @param count Number. @param doInsert Insert when true. @return Offers. */
    public static List<Disposition_Offer__c> createDispositionOffers(Integer count, Boolean doInsert) {
        return createDispositionOffers(count, defaultDisposition().Id, doInsert);
    }

    /** Single Disposition Offer. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The offer. */
    public static Disposition_Offer__c createDispositionOffer(Id dispositionId, Boolean doInsert) {
        return createDispositionOffers(1, dispositionId, doInsert)[0];
    }

    /**
     * @param count         Number of BOV Submissions.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return BOV Submissions at status 'Backup'.
     */
    public static List<BOV_Submission__c> createBovSubmissions(Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<BOV_Submission__c> submissions = new List<BOV_Submission__c>();
        for (Integer i = 0; i < count; i++) {
            submissions.add(new BOV_Submission__c(
                Disposition__c = dispositionId,
                Submission_Status__c = 'Backup',
                Broker_Firm__c = 'Test Brokerage ' + i,
                Contact_Name__c = 'Test Broker ' + i,
                BOV_Amount__c = 1200000 + (i * 1000),
                Cap_Rate__c = 6.25,
                Commission_Rate__c = 2.5,
                Days_To_Market__c = 30,
                BOV_Score__c = 80,
                Hist_Success_Rate__c = 75
            ));
        }
        insertIf(doInsert, submissions);
        return submissions;
    }

    /** BOV Submissions under the shared scaffold Disposition. @param count Number. @param doInsert Insert when true. @return Submissions. */
    public static List<BOV_Submission__c> createBovSubmissions(Integer count, Boolean doInsert) {
        return createBovSubmissions(count, defaultDisposition().Id, doInsert);
    }

    /** Single BOV Submission. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The submission. */
    public static BOV_Submission__c createBovSubmission(Id dispositionId, Boolean doInsert) {
        return createBovSubmissions(1, dispositionId, doInsert)[0];
    }

    /**
     * @param count         Number of Broker Listings.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Broker Listings at status 'On Track'.
     */
    public static List<Broker_Listing__c> createBrokerListings(Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<Broker_Listing__c> listings = new List<Broker_Listing__c>();
        for (Integer i = 0; i < count; i++) {
            listings.add(new Broker_Listing__c(
                Disposition__c = dispositionId,
                Listing_Status__c = 'On Track',
                Broker_Firm__c = 'Test Brokerage ' + i,
                Contact_Name__c = 'Test Broker ' + i,
                List_Date__c = Date.today(),
                Call_For_Offers_Date__c = Date.today().addDays(30),
                Commission_Percent__c = 2.5,
                Days_On_Market__c = 0,
                Offers_Received__c = 0
            ));
        }
        insertIf(doInsert, listings);
        return listings;
    }

    /** Broker Listings under the shared scaffold Disposition. @param count Number. @param doInsert Insert when true. @return Listings. */
    public static List<Broker_Listing__c> createBrokerListings(Integer count, Boolean doInsert) {
        return createBrokerListings(count, defaultDisposition().Id, doInsert);
    }

    /** Single Broker Listing. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The listing. */
    public static Broker_Listing__c createBrokerListing(Id dispositionId, Boolean doInsert) {
        return createBrokerListings(1, dispositionId, doInsert)[0];
    }

    /**
     * Wires. Parents to Disposition__c — there is no Wire__c -> Transaction__c
     * relationship in this org.
     * @param count         Number of Wires.
     * @param dispositionId Parent Disposition__c (nullable).
     * @param doInsert      Insert when true.
     * @return Wires.
     */
    public static List<Wire__c> createWires(Integer count, Id dispositionId, Boolean doInsert) {
        requirePositive(count);
        List<Wire__c> wires = new List<Wire__c>();
        for (Integer i = 0; i < count; i++) {
            wires.add(new Wire__c(
                Disposition__c = dispositionId,
                Confirmed_Wire_Amount__c = 50000 + (i * 100),
                Verbal_Verification_Completed__c = false,
                Verifier_Name__c = 'Test Verifier ' + i,
                Verifier_Phone__c = '713-555-' + String.valueOf(i).leftPad(4, '0'),
                Wire_Instructions_Source__c = 'Test Source'
            ));
        }
        insertIf(doInsert, wires);
        return wires;
    }

    /** Wires under the shared scaffold Disposition. @param count Number. @param doInsert Insert when true. @return Wires. */
    public static List<Wire__c> createWires(Integer count, Boolean doInsert) {
        return createWires(count, defaultDisposition().Id, doInsert);
    }

    /** Single Wire. @param dispositionId Parent Disposition. @param doInsert Insert when true. @return The Wire. */
    public static Wire__c createWire(Id dispositionId, Boolean doInsert) {
        return createWires(1, dispositionId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — ONBOARDING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count           Number of Onboardings.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Onboardings at stage 'Property Set up'.
     */
    public static List<Onboarding__c> createOnboardings(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        List<Onboarding__c> onboardings = new List<Onboarding__c>();
        for (Integer i = 0; i < count; i++) {
            onboardings.add(new Onboarding__c(
                Property_Asset__c = propertyAssetId,
                Stage__c = 'Property Set up',
                Status__c = 'In Progress',
                Onboarding_Lead__c = UserInfo.getUserId(),
                Start_Date__c = Date.today(),
                Target_Completion_Date__c = Date.today().addDays(30),
                Tasks_Total__c = 0,
                Tasks_Complete__c = 0,
                Tasks_Open__c = 0,
                Tasks_Not_Started__c = 0,
                Tasks_In_Progress__c = 0,
                Tasks_Blocked__c = 0,
                Tasks_Overdue__c = 0
            ));
        }
        insertIf(doInsert, onboardings);
        return onboardings;
    }

    /** Onboardings under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Onboardings. */
    public static List<Onboarding__c> createOnboardings(Integer count, Boolean doInsert) {
        return createOnboardings(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Onboarding. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The Onboarding. */
    public static Onboarding__c createOnboarding(Id propertyAssetId, Boolean doInsert) {
        return createOnboardings(1, propertyAssetId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — LEASING
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Lease inquiries. Tenant_Name__c is schema-required.
     * Broker__c is intentionally NOT defaulted — its lookup filter demands a
     * Contact with Is_Broker__c = true. Use createBrokerContacts() and override.
     * @param count           Number of Lease Inquiries.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Lease Inquiries at stage 'Inquiry Received'.
     */
    public static List<Lease_Inquiry__c> createLeaseInquiries(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        List<Lease_Inquiry__c> inquiries = new List<Lease_Inquiry__c>();
        for (Integer i = 0; i < count; i++) {
            inquiries.add(new Lease_Inquiry__c(
                Property_Asset__c = propertyAssetId,
                Tenant_Name__c = 'Test Tenant ' + i,
                Stage__c = 'Inquiry Received',
                Ball_In_Court__c = 'Landlord',
                Handling_Person__c = UserInfo.getUserId(),
                Inquiry_Date__c = Date.today(),
                Stage_Start_Date__c = Date.today(),
                Space_Required__c = 1000 + (i * 10),
                // Base_Rent__c / TI_Allowance__c are TEXT (blessed quoted-deal-term Text),
                // not Currency/Number — see the type-inversion note in the class header.
                // Lease_Term_Months__c / Free_Rent_Months__c are typed Number(months) per §1 rule 9 (Wave D).
                Base_Rent__c = String.valueOf(5000 + (i * 10)),
                Lease_Term_Months__c = 60,
                Free_Rent_Months__c = 2,
                TI_Allowance__c = '25',
                Initial_Notes__c = 'Test inquiry ' + i
            ));
        }
        insertIf(doInsert, inquiries);
        return inquiries;
    }

    /** Lease Inquiries under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Inquiries. */
    public static List<Lease_Inquiry__c> createLeaseInquiries(Integer count, Boolean doInsert) {
        return createLeaseInquiries(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Lease Inquiry. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The inquiry. */
    public static Lease_Inquiry__c createLeaseInquiry(Id propertyAssetId, Boolean doInsert) {
        return createLeaseInquiries(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Lease activities. Lease_Inquiry__c is a MASTER-DETAIL parent — mandatory.
     * @param count          Number of Lease Activities.
     * @param leaseInquiryId Master Lease_Inquiry__c (required).
     * @param doInsert       Insert when true.
     * @return Lease Activities.
     */
    public static List<Lease_Activity__c> createLeaseActivities(Integer count, Id leaseInquiryId, Boolean doInsert) {
        requirePositive(count);
        requireId(leaseInquiryId, 'leaseInquiryId (Lease_Activity__c.Lease_Inquiry__c is Master-Detail)');
        Datetime entryStamp = System.now();
        List<Lease_Activity__c> activities = new List<Lease_Activity__c>();
        for (Integer i = 0; i < count; i++) {
            activities.add(new Lease_Activity__c(
                Lease_Inquiry__c = leaseInquiryId,
                Ball_In_Court__c = 'Landlord',
                Entry_DateTime__c = entryStamp, // ARCHITECTURE.md §1 rule-9 stamp
                Logged_By__c = UserInfo.getUserId(),
                Details__c = 'Test lease activity ' + i
            ));
        }
        insertIf(doInsert, activities);
        return activities;
    }

    /** Lease Activities under the shared scaffold inquiry. @param count Number. @param doInsert Insert when true. @return Activities. */
    public static List<Lease_Activity__c> createLeaseActivities(Integer count, Boolean doInsert) {
        return createLeaseActivities(count, defaultLeaseInquiry().Id, doInsert);
    }

    /** Single Lease Activity. @param leaseInquiryId Master inquiry. @param doInsert Insert when true. @return The activity. */
    public static Lease_Activity__c createLeaseActivity(Id leaseInquiryId, Boolean doInsert) {
        return createLeaseActivities(1, leaseInquiryId, doInsert)[0];
    }

    /**
     * Leases. BOTH Lease_Inquiry__c and Stage__c are schema-required.
     * @param count          Number of Leases.
     * @param leaseInquiryId Parent Lease_Inquiry__c (required).
     * @param doInsert       Insert when true.
     * @return Leases at stage 'Draft'.
     */
    public static List<Lease__c> createLeases(Integer count, Id leaseInquiryId, Boolean doInsert) {
        requirePositive(count);
        requireId(leaseInquiryId, 'leaseInquiryId (Lease__c.Lease_Inquiry__c is required)');
        List<Lease__c> leases = new List<Lease__c>();
        for (Integer i = 0; i < count; i++) {
            leases.add(new Lease__c(
                Lease_Inquiry__c = leaseInquiryId,
                Stage__c = 'Draft',
                Legal_Owner__c = UserInfo.getUserId(),
                Target_Execution_Date__c = Date.today().addDays(30)
            ));
        }
        insertIf(doInsert, leases);
        return leases;
    }

    /** Leases under the shared scaffold inquiry. @param count Number. @param doInsert Insert when true. @return Leases. */
    public static List<Lease__c> createLeases(Integer count, Boolean doInsert) {
        return createLeases(count, defaultLeaseInquiry().Id, doInsert);
    }

    /** Single Lease. @param leaseInquiryId Parent inquiry. @param doInsert Insert when true. @return The Lease. */
    public static Lease__c createLease(Id leaseInquiryId, Boolean doInsert) {
        return createLeases(1, leaseInquiryId, doInsert)[0];
    }

    /**
     * Broker assignments. Broker__c is left null by default — its lookup filter
     * requires Contact.Is_Broker__c = true. Use createBrokerAssignments(count,
     * assetId, brokerId, doInsert) with a Contact from createBrokerContacts().
     * @param count           Number of Broker Assignments.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param brokerContactId Broker Contact (must have Is_Broker__c = true); nullable.
     * @param doInsert        Insert when true.
     * @return Broker Assignments at status 'Active'.
     */
    public static List<Broker_Assignment__c> createBrokerAssignments(
        Integer count,
        Id propertyAssetId,
        Id brokerContactId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Broker_Assignment__c> assignments = new List<Broker_Assignment__c>();
        for (Integer i = 0; i < count; i++) {
            assignments.add(new Broker_Assignment__c(
                Property_Asset__c = propertyAssetId,
                Broker__c = brokerContactId,
                Status__c = 'Active',
                Listing_Start_Date__c = Date.today().addDays(-30),
                Listing_End_Date__c = Date.today().addDays(335),
                Last_Check_In_Date__c = Date.today()
            ));
        }
        insertIf(doInsert, assignments);
        return assignments;
    }

    /** Broker Assignments under the shared scaffold asset with a fresh broker Contact. @param count Number. @param doInsert Insert when true. @return Assignments. */
    public static List<Broker_Assignment__c> createBrokerAssignments(Integer count, Boolean doInsert) {
        Contact broker = createBrokerContacts(1, null, true)[0];
        return createBrokerAssignments(count, defaultPropertyAsset().Id, broker.Id, doInsert);
    }

    /** Single Broker Assignment. @param propertyAssetId Parent asset. @param brokerContactId Broker Contact. @param doInsert Insert when true. @return The assignment. */
    public static Broker_Assignment__c createBrokerAssignment(
        Id propertyAssetId,
        Id brokerContactId,
        Boolean doInsert
    ) {
        return createBrokerAssignments(1, propertyAssetId, brokerContactId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — RENEWALS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Lease renewals. BOTH Tenant_Name__c and Lease_End__c are schema-required.
     * Unit_Label__c on this object is a TEXT field, not a lookup to Unit__c.
     * @param count           Number of Lease Renewals.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Lease Renewals at stage 'Not Yet Started'.
     */
    public static List<Lease_Renewal__c> createLeaseRenewals(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        List<Lease_Renewal__c> renewals = new List<Lease_Renewal__c>();
        for (Integer i = 0; i < count; i++) {
            renewals.add(new Lease_Renewal__c(
                Property_Asset__c = propertyAssetId,
                Tenant_Name__c = 'Test Tenant ' + i,
                Lease_End__c = Date.today().addDays(120),
                Lease_Start__c = Date.today().addYears(-3),
                Stage__c = 'Not Yet Started',
                Handling_Person__c = UserInfo.getUserId(),
                Unit_Label__c = 'Suite ' + (100 + i),
                Current_Rent__c = String.valueOf(5000 + (i * 10)), // TEXT, not Currency
                Proposed_Rate__c = 5250 + (i * 10),
                Space_Sq_Ft__c = 1000 + (i * 10),
                Has_Renewal_Option__c = true,
                Last_Contact_Date__c = Date.today()
            ));
        }
        insertIf(doInsert, renewals);
        return renewals;
    }

    /** Lease Renewals under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Renewals. */
    public static List<Lease_Renewal__c> createLeaseRenewals(Integer count, Boolean doInsert) {
        return createLeaseRenewals(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Lease Renewal. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The renewal. */
    public static Lease_Renewal__c createLeaseRenewal(Id propertyAssetId, Boolean doInsert) {
        return createLeaseRenewals(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Renewal activities. Lease_Renewal__c is a MASTER-DETAIL parent — mandatory.
     * @param count          Number of Renewal Activities.
     * @param leaseRenewalId Master Lease_Renewal__c (required).
     * @param doInsert       Insert when true.
     * @return Renewal Activities.
     */
    public static List<Renewal_Activity__c> createRenewalActivities(Integer count, Id leaseRenewalId, Boolean doInsert) {
        requirePositive(count);
        requireId(leaseRenewalId, 'leaseRenewalId (Renewal_Activity__c.Lease_Renewal__c is Master-Detail)');
        Datetime entryStamp = System.now();
        List<Renewal_Activity__c> activities = new List<Renewal_Activity__c>();
        for (Integer i = 0; i < count; i++) {
            activities.add(new Renewal_Activity__c(
                Lease_Renewal__c = leaseRenewalId,
                Method__c = 'Call',
                Entry_DateTime__c = entryStamp, // ARCHITECTURE.md §1 rule-9 stamp
                Details__c = 'Test renewal activity ' + i
            ));
        }
        insertIf(doInsert, activities);
        return activities;
    }

    /** Renewal Activities under the shared scaffold renewal. @param count Number. @param doInsert Insert when true. @return Activities. */
    public static List<Renewal_Activity__c> createRenewalActivities(Integer count, Boolean doInsert) {
        return createRenewalActivities(count, defaultLeaseRenewal().Id, doInsert);
    }

    /** Single Renewal Activity. @param leaseRenewalId Master renewal. @param doInsert Insert when true. @return The activity. */
    public static Renewal_Activity__c createRenewalActivity(Id leaseRenewalId, Boolean doInsert) {
        return createRenewalActivities(1, leaseRenewalId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — MAINTENANCE (YARDI MIRRORS)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Work orders. Subject__c is schema-required; Reported_DateTime__c anchors every
     * SLA formula, so it is set deterministically rather than relying on CreatedDate.
     * Ownership uses Owner_User__c (a lookup), NOT the standard OwnerId. Unit_Label__c
     * here is a TEXT field (may hold non-unit values such as 'Common' - it was never a
     * unit reference).
     *
     * Reported_DateTime__c is the ARCHITECTURE.md §1 rule-9 SLA anchor. To override it
     * on a returned record, use createWorkOrdersReportedAt.
     * @param count           Number of Work Orders.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Work Orders at status 'New'.
     */
    public static List<Work_Order__c> createWorkOrders(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        Datetime reportedStamp = System.now().addHours(-1);
        List<Work_Order__c> workOrders = new List<Work_Order__c>();
        for (Integer i = 0; i < count; i++) {
            workOrders.add(new Work_Order__c(
                Property_Asset__c = propertyAssetId,
                Subject__c = 'Test Work Order ' + i,
                Reported_DateTime__c = reportedStamp, // ARCHITECTURE.md §1 rule-9 SLA anchor
                Status__c = 'New',
                Priority__c = 'Medium',
                Category__c = 'General',
                Owner_User__c = UserInfo.getUserId(),
                Owner_Role__c = 'Maintenance',
                Tenant_Name__c = 'Test Tenant ' + i,
                Unit_Label__c = 'Suite ' + (100 + i),
                Vendor__c = 'Test Vendor ' + i,
                Description__c = 'Test work order description ' + i
            ));
        }
        insertIf(doInsert, workOrders);
        return workOrders;
    }

    /** Work Orders under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Work Orders. */
    public static List<Work_Order__c> createWorkOrders(Integer count, Boolean doInsert) {
        return createWorkOrders(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Work Order. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The Work Order. */
    public static Work_Order__c createWorkOrder(Id propertyAssetId, Boolean doInsert) {
        return createWorkOrders(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Work orders with an explicit reported timestamp — use this to drive the SLA
     * formula tiers (24/48/168/360h) deterministically instead of sleeping.
     *
     * Sets Reported_DateTime__c to reportedDate — the ARCHITECTURE.md §1 rule-9 SLA anchor.
     * @param count           Number of Work Orders.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param reportedDate    Value for Reported_DateTime__c (SLA anchor).
     * @param doInsert        Insert when true.
     * @return Work Orders.
     */
    public static List<Work_Order__c> createWorkOrdersReportedAt(
        Integer count,
        Id propertyAssetId,
        DateTime reportedDate,
        Boolean doInsert
    ) {
        if (reportedDate == null) {
            throw new TestDataFactoryException('reportedDate is required; Work_Order__c.Reported_DateTime__c anchors all SLA math.');
        }
        List<Work_Order__c> workOrders = createWorkOrders(count, propertyAssetId, false);
        for (Work_Order__c workOrder : workOrders) {
            workOrder.Reported_DateTime__c = reportedDate; // ARCHITECTURE.md §1 rule-9 SLA anchor
        }
        insertIf(doInsert, workOrders);
        return workOrders;
    }

    /**
     * Work order activities. Work_Order__c is a MASTER-DETAIL parent — mandatory.
     * @param count       Number of Work Order Activities.
     * @param workOrderId Master Work_Order__c (required).
     * @param doInsert    Insert when true.
     * @return Work Order Activities.
     */
    public static List<Work_Order_Activity__c> createWorkOrderActivities(
        Integer count,
        Id workOrderId,
        Boolean doInsert
    ) {
        requirePositive(count);
        requireId(workOrderId, 'workOrderId (Work_Order_Activity__c.Work_Order__c is Master-Detail)');
        Datetime entryStamp = System.now();
        List<Work_Order_Activity__c> activities = new List<Work_Order_Activity__c>();
        for (Integer i = 0; i < count; i++) {
            activities.add(new Work_Order_Activity__c(
                Work_Order__c = workOrderId,
                Kind__c = 'Sync',
                Entry_DateTime__c = entryStamp, // ARCHITECTURE.md §1 rule-9 stamp
                Actor__c = 'Test Actor ' + i,
                Detail__c = 'Test work order activity ' + i
            ));
        }
        insertIf(doInsert, activities);
        return activities;
    }

    /** Work Order Activities under the shared scaffold Work Order. @param count Number. @param doInsert Insert when true. @return Activities. */
    public static List<Work_Order_Activity__c> createWorkOrderActivities(Integer count, Boolean doInsert) {
        return createWorkOrderActivities(count, defaultWorkOrder().Id, doInsert);
    }

    /** Single Work Order Activity. @param workOrderId Master Work Order. @param doInsert Insert when true. @return The activity. */
    public static Work_Order_Activity__c createWorkOrderActivity(Id workOrderId, Boolean doInsert) {
        return createWorkOrderActivities(1, workOrderId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROPERTY MANAGEMENT — FINANCE MIRRORS
    // The three Yardi external ids below are UNIQUE, so they are counter-backed.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @param count           Number of CAM Reconciliations.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return CAM Reconciliations at status 'Pending'.
     */
    public static List<CAM_Reconciliation__c> createCamReconciliations(
        Integer count,
        Id propertyAssetId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<CAM_Reconciliation__c> reconciliations = new List<CAM_Reconciliation__c>();
        for (Integer i = 0; i < count; i++) {
            reconciliations.add(new CAM_Reconciliation__c(
                Property_Asset__c = propertyAssetId,
                Status__c = 'Pending',
                Amount__c = 10000 + (i * 100),
                Reconciliation_Year__c = String.valueOf(Date.today().year()), // TEXT, not Number
                Yardi_CAM_Id__c = 'YC-' + String.valueOf(nextUnique()).leftPad(10, '0')
            ));
        }
        insertIf(doInsert, reconciliations);
        return reconciliations;
    }

    /** CAM Reconciliations under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Reconciliations. */
    public static List<CAM_Reconciliation__c> createCamReconciliations(Integer count, Boolean doInsert) {
        return createCamReconciliations(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single CAM Reconciliation. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The reconciliation. */
    public static CAM_Reconciliation__c createCamReconciliation(Id propertyAssetId, Boolean doInsert) {
        return createCamReconciliations(1, propertyAssetId, doInsert)[0];
    }

    /**
     * Delinquencies. Aging_Bucket__c has no picklist default, so it is set.
     * @param count           Number of Delinquencies.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Delinquencies.
     */
    public static List<Delinquency__c> createDelinquencies(Integer count, Id propertyAssetId, Boolean doInsert) {
        requirePositive(count);
        List<Delinquency__c> delinquencies = new List<Delinquency__c>();
        for (Integer i = 0; i < count; i++) {
            delinquencies.add(new Delinquency__c(
                Property_Asset__c = propertyAssetId,
                Aging_Bucket__c = '1-30 Days',
                Balance__c = 1000 + (i * 10),
                Tenant_Name__c = 'Test Tenant ' + i,
                Unit_Suite__c = 'Suite ' + (100 + i),
                Yardi_AR_Id__c = 'YA-' + String.valueOf(nextUnique()).leftPad(10, '0')
            ));
        }
        insertIf(doInsert, delinquencies);
        return delinquencies;
    }

    /** Delinquencies under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Delinquencies. */
    public static List<Delinquency__c> createDelinquencies(Integer count, Boolean doInsert) {
        return createDelinquencies(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Delinquency. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The delinquency. */
    public static Delinquency__c createDelinquency(Id propertyAssetId, Boolean doInsert) {
        return createDelinquencies(1, propertyAssetId, doInsert)[0];
    }

    /**
     * @param count           Number of Insurance Policies.
     * @param propertyAssetId Parent Property_Asset__c (nullable).
     * @param doInsert        Insert when true.
     * @return Insurance Policies.
     */
    public static List<Insurance_Policy__c> createInsurancePolicies(
        Integer count,
        Id propertyAssetId,
        Boolean doInsert
    ) {
        requirePositive(count);
        List<Insurance_Policy__c> policies = new List<Insurance_Policy__c>();
        for (Integer i = 0; i < count; i++) {
            policies.add(new Insurance_Policy__c(
                Property_Asset__c = propertyAssetId,
                Policy_Name__c = 'Test Policy ' + i,
                Carrier__c = 'Test Carrier ' + i,
                Expiry_Date__c = Date.today().addDays(180),
                Yardi_Policy_Id__c = 'YP-' + String.valueOf(nextUnique()).leftPad(10, '0')
            ));
        }
        insertIf(doInsert, policies);
        return policies;
    }

    /** Insurance Policies under the shared scaffold asset. @param count Number. @param doInsert Insert when true. @return Policies. */
    public static List<Insurance_Policy__c> createInsurancePolicies(Integer count, Boolean doInsert) {
        return createInsurancePolicies(count, defaultPropertyAsset().Id, doInsert);
    }

    /** Single Insurance Policy. @param propertyAssetId Parent asset. @param doInsert Insert when true. @return The policy. */
    public static Insurance_Policy__c createInsurancePolicy(Id propertyAssetId, Boolean doInsert) {
        return createInsurancePolicies(1, propertyAssetId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BROKER PROTECTION (Property_Registry__c / Competing_Broker_Submission__c)
    //
    // Both objects carry an insert-scoped Winning_Lead_Required validation rule
    // (AND(ISNEW(), ISBLANK(Winning_Lead__c))) — Winning_Lead__c is required on
    // insert but may legally be nulled afterward (SetNull on Lead delete; also how
    // PropertyMatchingService.findOrphanedRegistry's "orphan" row is simulated in
    // tests: insert with a winner, then update Winning_Lead__c to null).
    //
    // Property_Registry__c.Property_Key__c is UNIQUE + case-insensitive, so the
    // bulk factory method mints a counter-backed key per row; tests that need a
    // caller-controlled key (exact-match / fuzzy-match / race-collision scenarios)
    // use the explicit-key single-record overload instead.
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Property_Registry__c winner rows, each with its own unique Property_Key__c
     * (counter-backed) so bulk calls never collide on the unique index.
     * @param count         Number of registry rows.
     * @param winningLeadId Winning_Lead__c (required by the VR on insert).
     * @param doInsert      Insert when true.
     * @return Property_Registry__c rows.
     */
    /**
     * ⚠ THIS GUARD IS STILL CORRECT — DO NOT "HARMONIZE" IT WITH THE SUBMISSION FACTORY.
     * Checked 2026-08-03 when Competing_Broker_Submission__c gained its Opportunity anchor.
     * Property_Registry__c deliberately did NOT: its `Winning_Lead__c` is only ever written with
     * a Lead created milliseconds earlier (which cannot be converted yet) or re-pointed on an
     * orphan row whose lookup is already null, so it is never exposed to the converted-Lead
     * rejection and its own Winning_Lead_Required VR is unchanged. Requiring the Lead here
     * remains the accurate rule. See PropertyClaimService.registerWinner's prohibition note.
     */
    public static List<Property_Registry__c> createPropertyRegistries(Integer count, Id winningLeadId, Boolean doInsert) {
        requirePositive(count);
        requireId(winningLeadId, 'winningLeadId (Property_Registry__c.Winning_Lead__c is required on insert)');
        List<Property_Registry__c> registries = new List<Property_Registry__c>();
        for (Integer i = 0; i < count; i++) {
            String key = 'test property key ' + nextUnique();
            registries.add(new Property_Registry__c(
                Property_Key__c = key,
                Normalized_Address__c = key,
                Winning_Lead__c = winningLeadId,
                Registered_DateTime__c = Datetime.now()
            ));
        }
        insertIf(doInsert, registries);
        return registries;
    }

    /** Single Property Registry with an auto-generated unique key. @param winningLeadId Winning_Lead__c (required). @param doInsert Insert when true. @return The registry row. */
    public static Property_Registry__c createPropertyRegistry(Id winningLeadId, Boolean doInsert) {
        return createPropertyRegistries(1, winningLeadId, doInsert)[0];
    }

    /**
     * Single Property Registry with a caller-controlled Property_Key__c — needed
     * for exact-match / fuzzy-match / unique-index-collision test scenarios where
     * the test must control the key value directly rather than accept an
     * auto-generated one.
     * @param propertyKey   Exact Property_Key__c / Normalized_Address__c value.
     * @param winningLeadId Winning_Lead__c (required by the VR on insert).
     * @param doInsert      Insert when true.
     * @return The registry row.
     */
    public static Property_Registry__c createPropertyRegistry(String propertyKey, Id winningLeadId, Boolean doInsert) {
        requireId(winningLeadId, 'winningLeadId (Property_Registry__c.Winning_Lead__c is required on insert)');
        Property_Registry__c registry = new Property_Registry__c(
            Property_Key__c = propertyKey,
            Normalized_Address__c = propertyKey,
            Winning_Lead__c = winningLeadId,
            Registered_DateTime__c = Datetime.now()
        );
        insertIf(doInsert, new List<Property_Registry__c>{ registry });
        return registry;
    }

    /**
     * Competing_Broker_Submission__c rows against one winning Lead. Submitted_DateTime__c
     * ascends with index (starting 1 day ago) and Is_Winning_Submission__c is true only
     * at index 0, so the factory's own "winner" row is also the chronologically-earliest
     * one — matching the real invariant (selectByWinningLead orders ASC, earliest first).
     * ⚠ THE WINNER ANCHOR IS SPLIT ACROSS TWO FIELDS (2026-08-03). A submission names its winner
     * as EITHER `Winning_Lead__c` (the winning Lead is still open) OR `Winning_Opportunity__c`
     * (it has been converted — the platform rejects a lookup SET to a converted Lead). These
     * Lead-only overloads build the FIRST shape and keep their original guard; use the
     * `winningOpportunityId` overloads below for the second. See PropertyClaimService's WINNER
     * ANCHOR note and the widened Winning_Lead_Required validation rule.
     *
     * @param count         Number of submissions.
     * @param winningLeadId Winning_Lead__c (required on this overload).
     * @param doInsert      Insert when true.
     * @return Competing_Broker_Submission__c rows.
     */
    public static List<Competing_Broker_Submission__c> createCompetingBrokerSubmissions(
        Integer count,
        Id winningLeadId,
        Boolean doInsert
    ) {
        requireId(winningLeadId, 'winningLeadId (Competing_Broker_Submission__c.Winning_Lead__c is required on insert)');
        return createCompetingBrokerSubmissions(count, winningLeadId, null, doInsert);
    }

    /**
     * Competing_Broker_Submission__c rows against a winner named by EITHER anchor.
     *
     * ═══ WHY THIS OVERLOAD EXISTS ═══
     * The Lead-only signature above encoded "Winning_Lead__c is required on insert", which was
     * true until 2026-08-03 and is now only HALF the rule. It rejected the exact shape the
     * winner-anchor fix introduces — an Opportunity-anchored row with both Lead lookups null —
     * and no test could build a post-conversion submission at all.
     *
     * 🔴 THE GUARD IS NOT REMOVED, IT IS RESTATED TO MATCH THE VALIDATION RULE: at least one
     * anchor must be supplied. Dropping the check entirely would let a test build a row the org
     * would reject, turning a clear factory error into a confusing DML failure at the call site —
     * which is the whole reason this factory validates rather than trusting its callers.
     *
     * ⚠ AN OPPORTUNITY-ANCHORED ROW GETS `Source_Lead__c = null` TOO, and that is the real
     * production shape rather than a simplification: per that field's contract a persisted
     * `Source_Lead__c` is either null or equal to `Winning_Lead__c`, so once the winner is
     * converted it is the same unwritable Lead.
     *
     * @param count                Number of submissions.
     * @param winningLeadId        Winning_Lead__c, or null when anchoring on the Opportunity.
     * @param winningOpportunityId Winning_Opportunity__c, or null when anchoring on the Lead.
     * @param doInsert             Insert when true.
     * @return Competing_Broker_Submission__c rows.
     * @throws TestDataFactoryException when neither anchor is supplied, or when an Id is of the
     *         wrong SObject type (the two parameters are adjacent and same-typed).
     */
    public static List<Competing_Broker_Submission__c> createCompetingBrokerSubmissions(
        Integer count,
        Id winningLeadId,
        Id winningOpportunityId,
        Boolean doInsert
    ) {
        requirePositive(count);
        if (winningLeadId == null && winningOpportunityId == null) {
            throw new TestDataFactoryException(
                'A Competing_Broker_Submission__c needs a winner anchor: supply winningLeadId '
                + '(open winner) OR winningOpportunityId (converted winner). The '
                + 'Winning_Lead_Required validation rule rejects a row with neither.');
        }
        requireSObjectType(winningLeadId, Lead.SObjectType, 'winningLeadId');
        requireSObjectType(winningOpportunityId, Opportunity.SObjectType, 'winningOpportunityId');

        Datetime base = Datetime.now().addDays(-1);
        List<Competing_Broker_Submission__c> subs = new List<Competing_Broker_Submission__c>();
        for (Integer i = 0; i < count; i++) {
            Integer u = nextUnique();
            subs.add(new Competing_Broker_Submission__c(
                Winning_Lead__c = winningLeadId,
                Winning_Opportunity__c = winningOpportunityId,
                // Null on the Opportunity path: the source Lead is the same converted Lead, which
                // is equally unwritable. Only the Lead-anchored shape carries one.
                Source_Lead__c = winningLeadId,
                Broker_Name__c = 'Test Broker ' + i,
                Broker_Email__c = 'test.broker' + u + '@example.invalid',
                Forwarded_By_Email__c = 'test.forwarder' + u + '@example.invalid',
                Property_Address_Raw__c = i + ' Test Submission Street',
                Submitted_DateTime__c = base.addMinutes(i),
                Email_Subject__c = 'FW: Test property ' + i,
                Is_Winning_Submission__c = (i == 0)
            ));
        }
        insertIf(doInsert, subs);
        return subs;
    }

    /** Single Competing Broker Submission (winning), anchored on an OPEN Lead. @param winningLeadId Winning_Lead__c (required). @param doInsert Insert when true. @return The submission. */
    public static Competing_Broker_Submission__c createCompetingBrokerSubmission(Id winningLeadId, Boolean doInsert) {
        return createCompetingBrokerSubmissions(1, winningLeadId, doInsert)[0];
    }

    /**
     * Single Competing Broker Submission anchored on EITHER a Lead or an Opportunity — the
     * post-conversion shape. Pass exactly one; see the bulk overload for the full rationale.
     *
     * @param winningLeadId        Winning_Lead__c, or null when anchoring on the Opportunity.
     * @param winningOpportunityId Winning_Opportunity__c, or null when anchoring on the Lead.
     * @param doInsert             Insert when true.
     * @return The submission.
     * @example
     * // A submission written after the winning Lead was converted:
     * TestDataFactory.createCompetingBrokerSubmission(null, opportunityId, true);
     */
    public static Competing_Broker_Submission__c createCompetingBrokerSubmission(
        Id winningLeadId,
        Id winningOpportunityId,
        Boolean doInsert
    ) {
        return createCompetingBrokerSubmissions(1, winningLeadId, winningOpportunityId, doInsert)[0];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BROKER PROTECTION — CONCURRENCY CONTROL (W4)
    //
    // Property_Claim_Lock__c is a pure lock-partition object: one row per COARSE
    // address cluster (Cluster_Key__c is unique + externalId + required, no parent
    // lookups). PropertyClaimService.claim() get-or-creates this row and takes a
    // FOR UPDATE lock on it before deciding a winner. The bulk method mints a
    // counter-backed key per row so concurrent factory calls in one transaction
    // never collide on the unique index; the explicit-key overload is for tests
    // that must control the exact cluster key (get-or-create / lock scenarios).
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Property_Claim_Lock__c rows, each with its own unique Cluster_Key__c
     * (counter-backed) so bulk calls never collide on the unique index.
     * @param count    Number of lock rows.
     * @param doInsert Insert when true.
     * @return Property_Claim_Lock__c rows.
     */
    public static List<Property_Claim_Lock__c> createPropertyClaimLocks(Integer count, Boolean doInsert) {
        requirePositive(count);
        List<Property_Claim_Lock__c> locks = new List<Property_Claim_Lock__c>();
        for (Integer i = 0; i < count; i++) {
            locks.add(new Property_Claim_Lock__c(
                Cluster_Key__c = 'test cluster key ' + nextUnique()
            ));
        }
        insertIf(doInsert, locks);
        return locks;
    }

    /** Single Property Claim Lock with an auto-generated unique cluster key. @param doInsert Insert when true. @return The lock row. */
    public static Property_Claim_Lock__c createPropertyClaimLock(Boolean doInsert) {
        return createPropertyClaimLocks(1, doInsert)[0];
    }

    /**
     * Single Property Claim Lock with a caller-controlled Cluster_Key__c — needed for
     * get-or-create / FOR UPDATE lock-acquisition scenarios where the test must control
     * the key value directly rather than accept an auto-generated one.
     * @param clusterKey Exact Cluster_Key__c value.
     * @param doInsert   Insert when true.
     * @return The lock row.
     */
    public static Property_Claim_Lock__c createPropertyClaimLock(String clusterKey, Boolean doInsert) {
        Property_Claim_Lock__c lockRow = new Property_Claim_Lock__c(Cluster_Key__c = clusterKey);
        insertIf(doInsert, new List<Property_Claim_Lock__c>{ lockRow });
        return lockRow;
    }
}
