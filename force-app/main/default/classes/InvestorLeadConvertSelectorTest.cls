/**
 * Tests for InvestorLeadConvertSelector — all SOQL for the IR lead-conversion feature.
 *
 * NEW 2026-08-16. This selector previously had NO dedicated test class; its coverage came
 * incidentally from a handful of methods inside InvestorLeadConvertServiceTest, which is why it sat
 * at 67% with its most important method — the cascade-delete safety re-query — barely exercised.
 *
 * ══ WHAT MATTERS HERE ══════════════════════════════════════════════════════════════════════════
 * Two properties are worth more than the field lists:
 *
 *   1. THE EMPTY-INPUT SHORT CIRCUIT IS A SOQL CONTRACT, NOT TIDINESS. All three methods return
 *      early WITHOUT querying on null/empty input, which is what lets the service call them
 *      unconditionally while keeping its 2-SOQL budget. Asserting "returns an empty list" alone
 *      would pass even if the query ran, so these tests assert Limits.getQueries() is UNCHANGED —
 *      the only assertion that can actually fail if someone deletes the guard.
 *
 *   2. selectContactsByIds IS THE SAFETY RE-QUERY. InvestorLeadConvertService deletes a temporary
 *      Account only when this method proves the Contact's AccountId is null. It must therefore
 *      report the STORED value, and it runs WITH SYSTEM_MODE precisely so an FLS gap cannot turn
 *      "prove it is safe to delete" into an exception that strands Accounts for a human to delete
 *      by hand — the measured 2026-08-16 data-loss path.
 *
 * ⚠ selectContactsByEmails is retained by the selector but is no longer called by the service (the
 * redesign made conversion CREATE the Contact rather than resolve onto an existing one). It is
 * still tested here because it is public API and its ORDER BY is load-bearing for any future
 * caller: newest-first with an Id tiebreak, since CreatedDate is not a total order for rows created
 * in the same transaction.
 *
 * @see force-app/main/default/classes/InvestorLeadConvertSelector.cls
 */
@isTest
private class InvestorLeadConvertSelectorTest {

    @TestSetup
    static void setupTestData() {
        TestDataFactory.createInvestorOnboardingLeads(2, true);
    }

    // ─── selectByIds ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectByIds_nullInput_returnsEmptyListWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Lead> results = InvestorLeadConvertSelector.selectByIds(null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Null input must return an empty list');
        Assert.areEqual(0, queriesUsed, 'Null input must not consume a SOQL query');
    }

    @isTest
    static void selectByIds_emptyInput_returnsEmptyListWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Lead> results = InvestorLeadConvertSelector.selectByIds(new Set<Id>());
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Empty input must return an empty list');
        Assert.areEqual(0, queriesUsed, 'Empty input must not consume a SOQL query');
    }

    @isTest
    static void selectByIds_validLead_returnsTheContractedFieldSet() {
        Lead seeded = [
            SELECT Id, Email, FirstName, LastName, Status, Is_Accredited__c
            FROM Lead LIMIT 1
        ];

        Test.startTest();
        List<Lead> results = InvestorLeadConvertSelector.selectByIds(new Set<Id>{ seeded.Id });
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'The seeded Lead must be returned');
        Lead fetched = results[0];
        // Every field below is relied on by InvestorLeadConvertService — IsConverted backs the
        // already-converted guard, the name/status fields make refusals identify the Lead, and the
        // last two are CARRIED onto the Contact. Narrowing the list breaks the service silently.
        Assert.areEqual(seeded.Email, fetched.Email, 'Email must be selected');
        Assert.areEqual(seeded.FirstName, fetched.FirstName, 'FirstName must be selected');
        Assert.areEqual(seeded.LastName, fetched.LastName, 'LastName must be selected');
        Assert.areEqual(seeded.Status, fetched.Status, 'Status must be selected');
        Assert.isFalse(fetched.IsConverted, 'IsConverted must be selected and false when unconverted');
        Assert.isNotNull(fetched.RecordTypeId, 'RecordTypeId must be selected');
        Assert.areEqual(seeded.Is_Accredited__c, fetched.Is_Accredited__c,
            'Is_Accredited__c must be selected — the service carries it onto the Contact');
    }

    @isTest
    static void selectByIds_unknownId_returnsEmptyListNotAnError() {
        // The NOT-FOUND CONTRACT: invisible or non-existent Leads simply do not come back. The
        // caller compares what it asked for against what returned; it must never assume the result
        // is index-parallel to the input.
        Lead seeded = [SELECT Id FROM Lead LIMIT 1];
        delete seeded;

        Test.startTest();
        List<Lead> results = InvestorLeadConvertSelector.selectByIds(new Set<Id>{ seeded.Id });
        Test.stopTest();

        Assert.areEqual(0, results.size(),
            'A Lead that cannot be seen must be absent from the result, not raise');
    }

    // ─── selectContactsByIds — the cascade-delete safety re-query ────────────────────────────

    @isTest
    static void selectContactsByIds_nullInput_returnsEmptyListWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Contact> results = InvestorLeadConvertSelector.selectContactsByIds(null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Null input must return an empty list');
        Assert.areEqual(0, queriesUsed, 'Null input must not consume a SOQL query');
    }

    @isTest
    static void selectContactsByIds_emptyInput_returnsEmptyListWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Contact> results =
            InvestorLeadConvertSelector.selectContactsByIds(new Set<Id>());
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Empty input must return an empty list');
        Assert.areEqual(0, queriesUsed, 'Empty input must not consume a SOQL query');
    }

    @isTest
    static void selectContactsByIds_attachedContact_reportsTheStoredAccountId() {
        Account parent = TestDataFactory.createAccount(true);
        Contact child = TestDataFactory.createContact(parent.Id, true);

        Test.startTest();
        List<Contact> results =
            InvestorLeadConvertSelector.selectContactsByIds(new Set<Id>{ child.Id });
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'The Contact must be returned');
        Assert.areEqual(parent.Id, results[0].AccountId,
            'An ATTACHED Contact must report its Account — this is the reading that makes the '
            + 'service REFUSE to delete the temporary Account');
    }

    @isTest
    static void selectContactsByIds_detachedContact_reportsNullAccountId() {
        Account parent = TestDataFactory.createAccount(true);
        Contact child = TestDataFactory.createContact(parent.Id, true);
        update new Contact(Id = child.Id, AccountId = null);

        Test.startTest();
        List<Contact> results =
            InvestorLeadConvertSelector.selectContactsByIds(new Set<Id>{ child.Id });
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'The Contact must be returned');
        Assert.isNull(results[0].AccountId,
            'A DETACHED Contact must report a null Account — this is the ONLY reading that permits '
            + 'the temporary Account to be deleted');
    }

    @isTest
    static void selectContactsByIds_bulkInput_returnsEveryContactInOneQuery() {
        Account parent = TestDataFactory.createAccount(true);
        List<Contact> children = TestDataFactory.createContacts(200, parent.Id, true);
        Set<Id> ids = new Map<Id, Contact>(children).keySet();

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Contact> results = InvestorLeadConvertSelector.selectContactsByIds(ids);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(200, results.size(), 'Every requested Contact must be returned');
        Assert.areEqual(1, queriesUsed,
            'The re-query must cost ONE SOQL for the whole batch, never one per Contact');
    }

    // ─── selectContactsByEmails ──────────────────────────────────────────────────────────────

    @isTest
    static void selectContactsByEmails_nullInput_returnsEmptyListWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Contact> results = InvestorLeadConvertSelector.selectContactsByEmails(null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Null input must return an empty list');
        Assert.areEqual(0, queriesUsed, 'Null input must not consume a SOQL query');
    }

    @isTest
    static void selectContactsByEmails_emptyInput_returnsEmptyListWithoutQuerying() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<Contact> results =
            InvestorLeadConvertSelector.selectContactsByEmails(new Set<String>());
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Empty input must return an empty list');
        Assert.areEqual(0, queriesUsed, 'Empty input must not consume a SOQL query');
    }

    @isTest
    static void selectContactsByEmails_duplicateEmails_returnsNewestFirst() {
        // ORDERING IS LOAD-BEARING: CreatedDate DESC with an Id DESC tiebreak implements
        // "most recently created wins". Without the tiebreak the winner is whichever row the
        // database happened to return, which makes this intermittently red.
        Account parent = TestDataFactory.createAccount(true);
        String sharedEmail = 'shared.investor@example.invalid';
        Contact older = TestDataFactory.createContact(parent.Id, false);
        older.Email = sharedEmail;
        Contact newer = TestDataFactory.createContact(parent.Id, false);
        newer.Email = sharedEmail;
        TestDataFactory.insertAllowingDuplicates(new List<SObject>{ older, newer });

        Test.startTest();
        List<Contact> results =
            InvestorLeadConvertSelector.selectContactsByEmails(new Set<String>{ sharedEmail });
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Both Contacts sharing the email must be returned');
        Assert.isTrue(results[0].Id > results[1].Id,
            'Results must be ordered newest-first — with equal CreatedDate the Id DESC tiebreak '
            + 'decides, and it must be deterministic');
    }

    @isTest
    static void selectContactsByEmails_noMatch_returnsEmptyList() {
        Test.startTest();
        List<Contact> results = InvestorLeadConvertSelector.selectContactsByEmails(
            new Set<String>{ 'nobody.at.all@example.invalid' });
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'An unmatched email must return an empty list');
    }
}
