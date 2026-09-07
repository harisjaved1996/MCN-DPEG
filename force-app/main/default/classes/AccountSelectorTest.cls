/**
 * Tests for AccountSelector — the first Account SOQL in the application, added with Smart Lead
 * Conversion (`agent-output/design-requirements-lead-convert-matching.md` §4/§7).
 *
 * Names are set directly (not via `TestDataFactory.createAccounts`, which deliberately generates
 * unique unpredictable names) because `selectByNames` is an EXACT-name lookup — the whole point of
 * these tests is controlling the Name value under test, matching the pattern
 * `LeadConvertMatchServiceTest.buildFirm` already uses for the same reason.
 *
 * RECORD TYPE SCOPE (2026-08-10, IR segregation, Task 6). Because these fixtures are built with
 * raw `new Account(...)` rather than `TestDataFactory.createAccount` (which auto-stamps
 * Account.Broker_Firm — see TestDataFactory.createAccounts), every fixture below that must MATCH
 * `selectByNames` now stamps `RecordTypeId = brokerFirmRecordTypeId()` explicitly via the helper
 * at the bottom of this class. `selectByEmailsIgnoresInvestorContacts`'s ContactSelectorTest twin
 * is `selectByNames_investorEntityAccount_isExcluded` below.
 *
 * @see force-app/main/default/classes/AccountSelector.cls
 * @see force-app/main/default/classes/LeadConvertMatchServiceTest.cls (the sole consumer's own
 *      integration-level coverage of this same query, including the D2 oldest-wins tie-break)
 */
@isTest
private class AccountSelectorTest {

    private static final Integer BULK_N = 251;

    @isTest
    static void selectByNames_exactNameMatch_returnsTheAccount() {
        Account firm = new Account(Name = 'Selector Test Firm LLC', BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());
        insert firm;
        // An unrelated Account with a different name must not leak into the result.
        insert new Account(Name = 'A Totally Different Firm', BillingCity = 'Dallas', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());

        Test.startTest();
        List<Account> rows = AccountSelector.selectByNames(new Set<String>{ 'Selector Test Firm LLC' });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'Only the exactly-named Account should be returned');
        Assert.areEqual(firm.Id, rows[0].Id, 'The returned row should be the matching Account');
        Assert.areEqual('Selector Test Firm LLC', rows[0].Name, 'Name is selected for the caller\'s Map key');
        Assert.isNotNull(rows[0].CreatedDate, 'CreatedDate is selected — it drives the D2 oldest-wins ordering');
    }

    /**
     * SOQL string comparison on Text fields is case-insensitive by default (AccountSelector's own
     * header: "do NOT wrap either side in LOWER() — it is not valid SOQL here and is not needed").
     * This pins that the QUERY itself returns a case-differing row; LeadConvertMatchServiceTest
     * separately pins that the CALLER's Map-key normalization then pairs it correctly.
     */
    @isTest
    static void selectByNames_caseInsensitiveMatch_stillReturnsTheAccount() {
        Account firm = new Account(Name = 'MIXED CASE FIRM NAME', BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());
        insert firm;

        Test.startTest();
        List<Account> rows = AccountSelector.selectByNames(new Set<String>{ 'mixed case firm name' });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'A differently-cased candidate must still match — SOQL Text comparison is case-insensitive');
        Assert.areEqual(firm.Id, rows[0].Id, 'The matching Account should be returned');
    }

    /**
     * D2 — oldest wins, `ORDER BY CreatedDate ASC, Id ASC`. The older Account is inserted SECOND
     * (so it has the HIGHER Id) and then aged with `Test.setCreatedDate`, exactly mirroring
     * `LeadConvertMatchServiceTest.matchForConversion_multipleAccountsSameName_oldestWins` — an
     * implementation that sorted by Id or insert order alone would return the WRONG row first.
     */
    @isTest
    static void selectByNames_multipleRowsSameName_ordersOldestFirst() {
        // Two Accounts with the SAME Name is duplicate-shaped on purpose — it is the only way to
        // express this tie-break — and the org's Account duplicate rule is active by design, so
        // the seed must allow-save (see TestDataFactory.insertAllowingDuplicates). This does not
        // weaken the test: the rows, their Names, their Ids and their CreatedDates are unchanged.
        Account newer = new Account(Name = 'Ambiguous Selector Firm', BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ newer }); // first -> lower Id, recent CreatedDate
        Account older = new Account(Name = 'Ambiguous Selector Firm', BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ older }); // second -> higher Id
        Test.setCreatedDate(older.Id, Datetime.now().addYears(-2));

        Test.startTest();
        List<Account> rows = AccountSelector.selectByNames(new Set<String>{ 'Ambiguous Selector Firm' });
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both same-named Accounts should be returned — no LIMIT here, the caller applies it');
        Assert.areEqual(older.Id, rows[0].Id,
            'CreatedDate ASC must put the OLDER row first even though it has the HIGHER Id — an '
            + 'Id-only or insert-order-only sort would return the newer row here and pick the wrong winner');
        Assert.areEqual(newer.Id, rows[1].Id, 'The newer row sorts second');
    }

    @isTest
    static void selectByNames_noMatch_returnsEmpty() {
        insert new Account(Name = 'Unrelated Firm', BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = brokerFirmRecordTypeId());

        Test.startTest();
        List<Account> rows = AccountSelector.selectByNames(new Set<String>{ 'Nobody Named This' });
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'A name nothing matches returns an empty list, not null');
    }

    @isTest
    static void selectByNames_nullOrEmptyInput_returnsEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Account> forNull = AccountSelector.selectByNames(null);
        List<Account> forEmpty = AccountSelector.selectByNames(new Set<String>());
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null name set short-circuits to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty name set short-circuits to an empty list, not null');
        Assert.areEqual(0, after - before, 'Neither call should spend a query — the empty-set guard runs before the SOQL');
    }

    /**
     * Bulk-safety at data volume, per this repo's standing selector-layer convention
     * (`.claude/rules/bulk-test-rule.md`; see e.g. `ContactSelectorTest.
     * selectBrokersRankedByClosedVolume_251Brokers_returnsAll`) — independent of, and in addition
     * to, the SERVICE-level 251 proof in `LeadConvertMatchServiceTest.
     * matchForConversion_at251Leads_isBulkSafe`, which proves the 3-selector CONTRACT rather than
     * this selector's own single-query bulk safety.
     */
    @isTest
    static void selectByNames_251DistinctNames_returnsAll() {
        // ⚠ THESE NAMES MUST BE MUTUALLY DISSIMILAR, NOT MERELY DISTINCT. The first version of this
        // test used 'Bulk Selector Firm ' + i and failed with DUPLICATES_DETECTED at ROW 200 — the
        // standard Account rule matches on a FUZZY name, and 251 names differing only by a trailing
        // counter are fuzzy-identical to each other. (Row 200 is the batch boundary: the first 200
        // are saved, then the next chunk is compared against them.) "251 distinct names" was true
        // and irrelevant — distinct is not the bar, dissimilar is.
        //
        // Fixed BOTH ways deliberately: each name now carries a high-entropy token so the rows are
        // genuinely not near-duplicates, AND the insert allow-saves so this test can never again be
        // held hostage by fuzzy-matching heuristics that are not in source control. The names stay
        // exact-matchable, which is all selectByNames cares about.
        List<Account> firms = new List<Account>();
        Set<String> names = new Set<String>();
        for (Integer i = 0; i < BULK_N; i++) {
            String token = String.valueOf(Math.abs(Crypto.getRandomLong())).right(9);
            String name = 'BulkFirm' + token + 'Idx' + i;
            names.add(name);
            firms.add(new Account(Name = name, BillingCity = 'Houston', BillingState = 'TX',
                RecordTypeId = brokerFirmRecordTypeId()));
        }
        TestDataFactory.insertAllowingDuplicates(firms);

        Test.startTest();
        List<Account> rows = AccountSelector.selectByNames(names);
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(), 'All 251 distinctly-named Accounts must be returned in one query');
    }

    /**
     * IR segregation (2026-08-10, Task 6). The broker and investor populations are disjoint by
     * policy, so this pins the STRUCTURAL guarantee: even a fabricated shared-name collision
     * between a brokerage firm and an investing entity must not surface an IR Account as a
     * lead-conversion match target — see the RECORD TYPE SCOPE note on
     * AccountSelector.selectByNames's ApexDoc. Mirrors
     * ContactSelectorTest.selectByEmails_investorContact_isExcluded.
     */
    @isTest
    static void selectByNames_investorEntityAccount_isExcluded() {
        Account investorAccount = new Account(Name = 'Shared Name Investing Entity',
            BillingCity = 'Houston', BillingState = 'TX',
            RecordTypeId = [SELECT Id FROM RecordType
                WHERE SobjectType = 'Account' AND DeveloperName = 'Investing_Entity' LIMIT 1].Id);
        insert investorAccount;

        Test.startTest();
        List<Account> matched = AccountSelector.selectByNames(
            new Set<String>{ 'Shared Name Investing Entity' });
        Test.stopTest();

        Assert.areEqual(0, matched.size(),
            'An investor Account must never be a lead-conversion match target - attaching an '
            + 'acquisition deal\'s new Contact to it would drag it across the security boundary.');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * The Account.Broker_Firm record type Id, resolved via describe (no SOQL, no FLS/sharing
     * dependency) — mirrors TestDataFactory's own private `recordTypeId` helper. Used to stamp
     * fixtures built with raw `new Account(...)` (see the class header note) so they match
     * `selectByNames`'s 2026-08-10 RecordType.DeveloperName = 'Broker_Firm' scope.
     */
    private static Id brokerFirmRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Broker_Firm').getRecordTypeId();
    }
}
