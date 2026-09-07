/**
 * Tests for ContactSelector (P4, Module B2 — Property Management; standard object).
 *
 * Covers the single relocated query:
 *   - selectBrokersOrderedByName : the Is_Broker__c = true filter, ORDER BY Name,
 *     Broker_Firm__c population, the no-brokers empty result, AND the standard-object
 *     USER_MODE proof required by design §7.
 *
 * USER_MODE PROOF NUANCE (design mismatch flagged to the orchestrator): unlike the
 * Task standard-object proof, this query selects the CUSTOM Contact.Broker_Firm__c
 * and filters the CUSTOM Contact.Is_Broker__c. A bare Standard User has no FLS on
 * those custom fields, so USER_MODE would throw. The runAs proof therefore assigns
 * DPEG_Contact_Edit, the layer-3 module set that owns broker Contact access —
 * mirroring the real broker-options persona, and confirming USER_MODE returns rows
 * once the grants are present. (This read DPEG_Acquisitions until 2026-08-10; that
 * monolith was retired and it was never the ONLY grantor — DPEG_Contact_Edit and
 * DPEG_Contact_View both carry these fields.)
 *
 * @see force-app/main/default/classes/TaskSelectorTest.cls (P4 standard-object template)
 * @see agent-output/p4-selector-design.md (§3 #19, §5, §7)
 */
@isTest
private class ContactSelectorTest {

    private static final Integer BULK_N = 251;

    // ─────────────────────────────────────────────────────────────────────────
    // selectBrokersOrderedByName
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectBrokersOrderedByName_returnsOnlyBrokersOrderedByName() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(2, null, false);
        brokers[0].LastName = 'Zeta';                 // Name 'Test Zeta' -> sorts last
        brokers[0].Broker_Firm__c = 'Zeta Realty';
        brokers[1].LastName = 'Alpha';                // Name 'Test Alpha' -> sorts first
        brokers[1].Broker_Firm__c = 'Alpha Realty';
        insert brokers;
        // A non-broker Contact must be excluded (Is_Broker__c defaults false).
        TestDataFactory.createContact(null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersOrderedByName();
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Only Is_Broker__c = true Contacts are returned; the plain Contact is excluded');
        Assert.areEqual('Test Alpha', rows[0].Name, 'ORDER BY Name returns the alphabetically-first broker first');
        Assert.areEqual('Alpha Realty', rows[0].Broker_Firm__c, 'Broker_Firm__c is selected for the option label');
        Assert.areEqual('Test Zeta', rows[1].Name, 'The second broker sorts after the first by Name');
    }

    @isTest
    static void selectBrokersOrderedByName_noBrokers_returnsEmpty() {
        // Only non-broker Contacts exist.
        TestDataFactory.createContacts(3, null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersOrderedByName();
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'With no broker Contacts the selector returns an empty list, not null');
    }

    /**
     * Standard-object USER_MODE proof (design §5/§7). A freshly created Standard
     * User granted the DPEG_Contact_Edit permission set (which grants Contact CRUD
     * plus FLS on the custom Contact.Is_Broker__c / Broker_Firm__c this query touches)
     * reads broker rows under WITH USER_MODE. The broker Contacts are inserted INSIDE
     * runAs so the Standard User owns them (removing sharing as a variable and isolating
     * the FLS question). The User + PermissionSetAssignment DML is isolated in its own
     * runAs block to avoid MIXED_DML_OPERATION with the non-setup Contact DML.
     *
     * ⚠ This named DPEG_Acquisitions until 2026-08-10, when that legacy monolith was
     * retired (docs/permission-set-retirement-runbook.md). The query below resolves a
     * permission set BY NAME, so deleting the named set fails this test with
     * "System.QueryException: List has no rows for assignment to SObject" rather than
     * with an FLS assertion — i.e. the failure does NOT look like a permission problem.
     * DPEG_Contact_Edit is the conformant successor: it is the layer-3 module set that
     * owns broker Contact access, so it is the correct grant to prove FLS with here.
     * User granted the DPEG_Acquisitions permission set (which grants FLS on the
     * custom Contact.Is_Broker__c / Broker_Firm__c this query touches) reads broker
     * rows under WITH USER_MODE. The broker Contacts are inserted INSIDE runAs so the
     * Standard User owns them (removing sharing as a variable and isolating the FLS
     * question). The User + PermissionSetAssignment DML is isolated in its own runAs
     * block to avoid MIXED_DML_OPERATION with the non-setup Contact DML.
     *
     * ⚠ ALSO GRANTS DPEG_Contact_Edit (added 2026-08-10, fix round 1). TestDataFactory now
     * stamps every factory Contact onto the Contact.Broker record type (IR/Acquisitions
     * segregation, Task 3), and DPEG_Acquisitions alone does not carry that record type's
     * visibility - only DPEG_Contact_Edit / DPEG_Contact_View do (Task 2). Without this grant
     * TestDataFactory.recordTypeId's isAvailable() guard degrades this persona to an unstamped
     * (default-record-type) Contact rather than throwing - but that would silently defeat this
     * test's own stated intent, "mirrors the real broker-options persona": a persona reading the
     * broker-options list must be able to see and create Broker-typed Contacts in the first
     * place, so DPEG_Contact_Edit belongs on this fixture on the merits, independent of the
     * factory change that surfaced its absence.
     */
    @isTest
    static void selectBrokersOrderedByName_standardUserWithGrants_userModeReturnsRows() {
        User standardUser = buildStandardUser();
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DPEG_Contact_Edit' LIMIT 1].Id;
        Id acqPermSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DPEG_Acquisitions' LIMIT 1].Id;
        Id contactEditPermSetId = [SELECT Id FROM PermissionSet WHERE Name = 'DPEG_Contact_Edit' LIMIT 1].Id;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert standardUser;
            insert new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = standardUser.Id, PermissionSetId = acqPermSetId),
                new PermissionSetAssignment(AssigneeId = standardUser.Id, PermissionSetId = contactEditPermSetId)
            };
        }

        Test.startTest();
        System.runAs(standardUser) {
            // Insert 2 broker Contacts as the Standard User (side effect is the point;
            // the selector re-queries them), exercising create + FLS end-to-end.
            TestDataFactory.createBrokerContacts(2, null, true);

            List<Contact> rows = ContactSelector.selectBrokersOrderedByName();

            Assert.areEqual(2, rows.size(),
                'A Standard User granted DPEG_Contact_Edit reads broker Contacts under WITH USER_MODE');
            Assert.isNotNull(rows[0].Broker_Firm__c,
                'Broker_Firm__c (custom, FLS-controlled) is readable under USER_MODE once DPEG_Contact_Edit grants it');
        }
        Test.stopTest();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectBrokersRankedByClosedVolume  (BrokerController — Broker Hub)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectBrokersRankedByClosedVolume_ranksByVolumeThenName_excludesNonBrokers() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(3, null, false);
        brokers[0].LastName = 'Zulu';  brokers[0].Closed_Volume__c = 10000000; brokers[0].Active_Listings__c = 2;
        brokers[1].LastName = 'Bravo'; brokers[1].Closed_Volume__c = 30000000; brokers[1].Active_Listings__c = 8;
        // Alpha ties Bravo on Closed_Volume__c so the Name ASC tiebreak decides order.
        brokers[2].LastName = 'Alpha'; brokers[2].Closed_Volume__c = 30000000; brokers[2].Active_Listings__c = 4;
        insert brokers;
        // A non-broker Contact (Is_Broker__c defaults false) must be excluded.
        TestDataFactory.createContact(null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersRankedByClosedVolume();
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'Only Is_Broker__c = true Contacts are returned; the plain Contact is excluded');
        Assert.areEqual('Test Alpha', rows[0].Name,
            'Closed_Volume__c DESC then Name ASC: Alpha wins the 30M tie over Bravo on Name');
        Assert.areEqual('Test Bravo', rows[1].Name, 'Bravo is the second of the two 30M brokers');
        Assert.areEqual('Test Zulu', rows[2].Name, 'The 10M broker ranks last by Closed_Volume__c DESC');
        Assert.areEqual(30000000, rows[0].Closed_Volume__c, 'Closed_Volume__c is selected for the header stats');
        Assert.areEqual(4, rows[0].Active_Listings__c, 'Active_Listings__c is selected for the header stats');
    }

    @isTest
    static void selectBrokersRankedByClosedVolume_noBrokers_returnsEmpty() {
        TestDataFactory.createContacts(3, null, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersRankedByClosedVolume();
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'With no broker Contacts the selector returns an empty list, not null');
    }

    @isTest
    static void selectBrokersRankedByClosedVolume_251Brokers_returnsAll() {
        // A 251-record standard-object insert can trip an org duplicate rule; the
        // factory makes Email unique, and AllowSave is set as defence-in-depth
        // (guardrail from prior selector waves — see LeadSelectorTest).
        List<Contact> brokers = TestDataFactory.createBrokerContacts(BULK_N, null, false);
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Database.insert(brokers, dml);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectBrokersRankedByClosedVolume();
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(),
            'All 251 broker Contacts are returned at data volume (bulk-safe single query)');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectTopBrokersByActiveListings  (BrokerController — Broker Hub top list)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectTopBrokersByActiveListings_filtersZeroListings_ranksByActiveListings() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(4, null, false);
        brokers[0].LastName = 'Eight'; brokers[0].Active_Listings__c = 8; brokers[0].Closed_Volume__c = 24000000;
        brokers[0].Broker_Firm__c = 'CBRE';
        brokers[1].LastName = 'Five';  brokers[1].Active_Listings__c = 5; brokers[1].Closed_Volume__c = 18000000;
        brokers[2].LastName = 'Two';   brokers[2].Active_Listings__c = 2; brokers[2].Closed_Volume__c = 6000000;
        brokers[3].LastName = 'Zero';  brokers[3].Active_Listings__c = 0; brokers[3].Closed_Volume__c = 0;
        insert brokers;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectTopBrokersByActiveListings(6);
        Test.stopTest();

        Assert.areEqual(3, rows.size(), 'Active_Listings__c > 0 excludes the zero-listing broker');
        Assert.areEqual(8, rows[0].Active_Listings__c, 'Highest Active_Listings__c first');
        Assert.areEqual(2, rows[2].Active_Listings__c, 'Lowest of the three last');
        Assert.areEqual('CBRE', rows[0].Broker_Firm__c, 'Broker_Firm__c is selected for the top-broker card');
    }

    @isTest
    static void selectTopBrokersByActiveListings_respectsMaxRows() {
        List<Contact> brokers = TestDataFactory.createBrokerContacts(4, null, false);
        brokers[0].LastName = 'Ten';  brokers[0].Active_Listings__c = 10; brokers[0].Closed_Volume__c = 40000000;
        brokers[1].LastName = 'Nine'; brokers[1].Active_Listings__c = 9;  brokers[1].Closed_Volume__c = 30000000;
        brokers[2].LastName = 'Six';  brokers[2].Active_Listings__c = 6;  brokers[2].Closed_Volume__c = 20000000;
        brokers[3].LastName = 'Four'; brokers[3].Active_Listings__c = 4;  brokers[3].Closed_Volume__c = 10000000;
        insert brokers;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectTopBrokersByActiveListings(2);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'LIMIT :maxRows caps the result at 2 rows');
        Assert.areEqual(10, rows[0].Active_Listings__c, 'The top broker by Active_Listings__c is first');
        Assert.areEqual(9, rows[1].Active_Listings__c, 'The second-highest is second; the rest are cut by the LIMIT');
    }

    @isTest
    static void selectTopBrokersByActiveListings_nullOrNonPositiveMaxRows_returnsEmpty() {
        TestDataFactory.createBrokerContacts(2, null, true);

        Test.startTest();
        List<Contact> nullRows = ContactSelector.selectTopBrokersByActiveListings(null);
        List<Contact> zeroRows = ContactSelector.selectTopBrokersByActiveListings(0);
        Test.stopTest();

        Assert.areEqual(0, nullRows.size(), 'A null maxRows short-circuits to an empty list without querying');
        Assert.areEqual(0, zeroRows.size(), 'A non-positive maxRows short-circuits to an empty list without querying');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // GuestReads.selectBrokerPriorityByEmailSystem
    //   (BrokerPortalController — guest; SYSTEM_MODE + without sharing)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Lives in the `without sharing` GuestReads inner class (all-records guest read,
    // preserving the original controller behavior); SYSTEM_MODE additionally bypasses
    // FLS. These tests run as the default (privileged) test user and prove the query
    // shape (email trim, Is_Broker__c filter, field population, blank guard). The
    // guest sharing/ownership model itself is out of scope for a unit test — it needs
    // the P3 guest-sharing spike verified before portal promotion (see the report).

    @isTest
    static void selectBrokerPriorityByEmailSystem_matchingBroker_returnsPriority() {
        Contact broker = TestDataFactory.createBrokerContact(null, false);
        broker.Email = 'known.broker@example.com';
        broker.Broker_Priority__c = 'High';
        insert broker;

        Test.startTest();
        Contact result = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem('  known.broker@example.com  ');
        Test.stopTest();

        Assert.isNotNull(result, 'A broker Contact with the given email resolves');
        Assert.areEqual('High', result.Broker_Priority__c, 'Broker_Priority__c is populated for the caller to copy');
    }

    @isTest
    static void selectBrokerPriorityByEmailSystem_nonBrokerWithSameEmail_excluded() {
        // A non-broker Contact (Is_Broker__c defaults false) with the same email
        // must not match — the WHERE Is_Broker__c = true filter excludes it.
        Contact plain = TestDataFactory.createContact(null, false);
        plain.Email = 'plain.contact@example.com';
        insert plain;

        Test.startTest();
        Contact result = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem('plain.contact@example.com');
        Test.stopTest();

        Assert.isNull(result, 'A non-broker Contact is excluded by Is_Broker__c = true');
    }

    @isTest
    static void selectBrokerPriorityByEmailSystem_noMatch_returnsNull() {
        Test.startTest();
        Contact result = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem('nobody@example.com');
        Test.stopTest();

        Assert.isNull(result, 'An unknown email returns null (caller defaults to Standard)');
    }

    @isTest
    static void selectBrokerPriorityByEmailSystem_blankInput_returnsNull() {
        Test.startTest();
        Contact nullResult = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem(null);
        Contact blankResult = new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem('   ');
        Test.stopTest();

        Assert.isNull(nullResult, 'Null input returns null');
        Assert.isNull(blankResult, 'Blank input returns null');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectEarliestByAccountId  (BrokerFirmController — sidebar broker person)
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectEarliestByAccountId_returnsContactScopedToAccount() {
        // Two same-City/State Accounts AND two similar Contacts each trip an org
        // duplicate rule on the second insert; bypass both (defence-in-depth pattern
        // from prior waves).
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.AllowSave = true;
        Account firmA = TestDataFactory.createAccount(false);
        Account firmB = TestDataFactory.createAccount(false);
        Database.insert(new List<Account>{ firmA, firmB }, dml);
        Contact contactA = TestDataFactory.createContact(firmA.Id, false);
        Contact contactB = TestDataFactory.createContact(firmB.Id, false);  // different firm — must not be returned
        Database.insert(new List<Contact>{ contactA, contactB }, dml);

        Test.startTest();
        Contact result = ContactSelector.selectEarliestByAccountId(firmA.Id);
        Test.stopTest();

        Assert.isNotNull(result, 'A firm Account with a linked Contact resolves a broker person');
        Assert.areEqual(contactA.Id, result.Id, 'Only the Contact under the requested Account is returned');
        Assert.isNotNull(result.Name, 'Name must be populated for the sidebar broker name');
    }

    @isTest
    static void selectEarliestByAccountId_manyContacts_returnsSingleRow() {
        Account firm = TestDataFactory.createAccount(true);
        TestDataFactory.createContacts(BULK_N, firm.Id, true);

        Test.startTest();
        Contact result = ContactSelector.selectEarliestByAccountId(firm.Id);
        Test.stopTest();

        Assert.isNotNull(result, 'LIMIT 1 returns a single Contact even with 251 under the Account');
        Assert.isNotNull(result.Name, 'Name is populated on the returned row');
    }

    @isTest
    static void selectEarliestByAccountId_noContact_returnsNull() {
        Account firm = TestDataFactory.createAccount(true);

        Test.startTest();
        Contact result = ContactSelector.selectEarliestByAccountId(firm.Id);
        Test.stopTest();

        Assert.isNull(result, 'An Account with no linked Contact returns null');
    }

    @isTest
    static void selectEarliestByAccountId_nullInput_returnsNull() {
        Test.startTest();
        Contact result = ContactSelector.selectEarliestByAccountId(null);
        Test.stopTest();

        Assert.isNull(result, 'Null input returns null');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // selectByEmails  (LeadConvertMatchService — Smart Lead Conversion, 2026-08-02)
    //
    // The consumer's own suite (LeadConvertMatchServiceTest) exercises this query through
    // matchForConversion end to end, including the D2 oldest-wins tie-break. These are the
    // direct selector-level proofs of the two contracts that class depends on: the
    // AccountId != null filter, and the null/empty-input short-circuit that no existing test
    // (at the selector OR the service layer) reaches — every LeadConvertMatchServiceTest
    // fixture supplies a non-blank Lead.Email, so the emails set handed to this method is
    // never actually empty in that suite.
    // ─────────────────────────────────────────────────────────────────────────

    @isTest
    static void selectByEmails_exactEmailMatchWithAccount_returnsTheContact() {
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createContact(firm.Id, false);
        broker.Email = 'selector.broker@firm.invalid';
        insert broker;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ 'selector.broker@firm.invalid' });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'The exactly-matching, account-having Contact should be returned');
        Assert.areEqual(broker.Id, rows[0].Id, 'The matching Contact should be returned');
        Assert.areEqual(firm.Id, rows[0].AccountId,
            'AccountId is selected — it is what the caller carries forward as the conversion target Account');
        Assert.isNotNull(rows[0].CreatedDate, 'CreatedDate is selected — it drives the D2 oldest-wins ordering');
    }

    /**
     * `AccountId != null` IS THE FILTER, NOT A DEFENSIVE CHECK (ContactSelector's own header).
     * An orphan Contact sharing the same email must never come back, or the caller would hand
     * Database.LeadConvert.setContactId a Contact with no Account, which convertLead rejects.
     */
    @isTest
    static void selectByEmails_matchingContactWithNoAccount_isExcluded() {
        Contact orphan = TestDataFactory.createContact(null, false);
        orphan.Email = 'orphan.selector@firm.invalid';
        insert orphan;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ 'orphan.selector@firm.invalid' });
        Test.stopTest();

        Assert.areEqual(0, rows.size(),
            'An account-less Contact must never be returned — Database.LeadConvert.setContactId requires an Account');
    }

    /** SOQL Email comparison is case-insensitive by default; see AccountSelector's identical note. */
    @isTest
    static void selectByEmails_caseInsensitiveMatch_stillReturnsTheContact() {
        Account firm = TestDataFactory.createAccount(true);
        Contact broker = TestDataFactory.createContact(firm.Id, false);
        broker.Email = 'Mixed.Case.Selector@Firm.Invalid';
        insert broker;

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ 'mixed.case.selector@firm.invalid' });
        Test.stopTest();

        Assert.areEqual(1, rows.size(), 'A differently-cased candidate must still match');
        Assert.areEqual(broker.Id, rows[0].Id, 'The matching Contact should be returned');
    }

    /**
     * D2 — oldest wins, `ORDER BY CreatedDate ASC, Id ASC`, mirroring
     * AccountSelectorTest.selectByNames_multipleRowsSameName_ordersOldestFirst and
     * LeadConvertMatchServiceTest.matchForConversion_multipleContactsSameEmail_oldestWins: the
     * older Contact is inserted SECOND (higher Id) and then aged, so an Id-only or
     * insert-order-only sort would return the wrong row first.
     */
    @isTest
    static void selectByEmails_multipleRowsSameEmail_ordersOldestFirst() {
        // Both seeds are duplicate-shaped and must allow-save — the same defence-in-depth already
        // applied inline by a prior wave in selectEarliestByAccountId_accountWithContacts_* above,
        // now consolidated into TestDataFactory.insertAllowingDuplicates:
        //   • the two Accounts, because createAccounts stamps every row BillingCity='Houston' /
        //     BillingState='TX' and the standard Account rule matches fuzzy-name + city/state, so
        //     ANY two factory Accounts in one transaction match each other;
        //   • the two Contacts, because sharing an Email is the entire point of this tie-break.
        // Neither weakens the assertions: the rows, Ids and CreatedDates are untouched.
        Account firmA = TestDataFactory.createAccount(false);
        Account firmB = TestDataFactory.createAccount(false);
        TestDataFactory.insertAllowingDuplicates(new List<Account>{ firmA, firmB });

        String sharedEmail = 'ambiguous.selector@firm.invalid';
        Contact newer = TestDataFactory.createContact(firmA.Id, false);
        newer.Email = sharedEmail;
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ newer }); // first -> lower Id, recent CreatedDate
        Contact older = TestDataFactory.createContact(firmB.Id, false);
        older.Email = sharedEmail;
        TestDataFactory.insertAllowingDuplicates(new List<Contact>{ older }); // second -> higher Id
        Test.setCreatedDate(older.Id, Datetime.now().addYears(-2));

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ sharedEmail });
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Both same-email Contacts should be returned — no LIMIT here, the caller applies it');
        Assert.areEqual(older.Id, rows[0].Id,
            'CreatedDate ASC must put the OLDER row first even though it has the HIGHER Id');
        Assert.areEqual(newer.Id, rows[1].Id, 'The newer row sorts second');
    }

    /**
     * IR segregation (2026-08-10, Task 6). The broker and investor populations are disjoint by
     * policy, so this pins the STRUCTURAL guarantee: even a fabricated shared-email collision
     * between a broker and an investor Contact must not surface an IR Contact as a lead-conversion
     * match target — see the RECORD TYPE SCOPE note on ContactSelector.selectByEmails's ApexDoc.
     */
    @isTest
    static void selectByEmails_investorContact_isExcluded() {
        Account investorAccount = TestDataFactory.createAccount(false);
        investorAccount.RecordTypeId = [SELECT Id FROM RecordType
            WHERE SobjectType = 'Account' AND DeveloperName = 'Investing_Entity' LIMIT 1].Id;
        insert investorAccount;

        Contact investor = TestDataFactory.createContact(investorAccount.Id, false);
        investor.Email = 'shared.address@example.invalid';
        investor.RecordTypeId = [SELECT Id FROM RecordType
            WHERE SobjectType = 'Contact' AND DeveloperName = 'Investor' LIMIT 1].Id;
        insert investor;

        Test.startTest();
        List<Contact> matched = ContactSelector.selectByEmails(
            new Set<String>{ 'shared.address@example.invalid' });
        Test.stopTest();

        Assert.areEqual(0, matched.size(),
            'An investor Contact must never be a lead-conversion match target - attaching an '
            + 'acquisition deal to an IR Contact would drag it across the security boundary.');
    }

    @isTest
    static void selectByEmails_noMatch_returnsEmpty() {
        Account firm = TestDataFactory.createAccount(true);
        TestDataFactory.createContact(firm.Id, true);

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(new Set<String>{ 'nobody.matches@firm.invalid' });
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'An email nothing matches returns an empty list, not null');
    }

    /**
     * GAP CLOSED (unit-testing agent pass, 2026-08-03). Neither this selector's own suite nor
     * LeadConvertMatchServiceTest previously exercised this branch: every match-service fixture
     * supplies a non-blank Lead.Email, so `emails` handed to selectByEmails is never actually
     * empty anywhere else in the app's test suite.
     */
    @isTest
    static void selectByEmails_nullOrEmptyInput_returnsEmptyWithoutQuerying() {
        Test.startTest();
        Integer before = Limits.getQueries();
        List<Contact> forNull = ContactSelector.selectByEmails(null);
        List<Contact> forEmpty = ContactSelector.selectByEmails(new Set<String>());
        Integer after = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(0, forNull.size(), 'A null email set short-circuits to an empty list, not null');
        Assert.areEqual(0, forEmpty.size(), 'An empty email set short-circuits to an empty list, not null');
        Assert.areEqual(0, after - before, 'Neither call should spend a query — the empty-set guard runs before the SOQL');
    }

    /**
     * Bulk-safety at data volume, per this repo's standing selector-layer convention — see
     * selectBrokersRankedByClosedVolume_251Brokers_returnsAll above — independent of, and in
     * addition to, the SERVICE-level 251 proof in
     * LeadConvertMatchServiceTest.matchForConversion_at251Leads_isBulkSafe.
     */
    @isTest
    static void selectByEmails_251DistinctEmailsWithAccounts_returnsAll() {
        Account firm = TestDataFactory.createAccount(true);
        List<Contact> brokers = TestDataFactory.createContacts(BULK_N, firm.Id, true);
        Set<String> emails = new Set<String>();
        for (Contact c : brokers) {
            emails.add(c.Email);
        }

        Test.startTest();
        List<Contact> rows = ContactSelector.selectByEmails(emails);
        Test.stopTest();

        Assert.areEqual(BULK_N, rows.size(), 'All 251 distinctly-emailed, account-having Contacts must be returned in one query');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private static User buildStandardUser() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = 'ctcstd' + String.valueOf(Datetime.now().getTime());
        return new User(
            FirstName = 'Std',
            LastName = 'ContactSel',
            Alias = 'ctcsel',
            Email = 'std.contactsel@example.invalid',
            Username = unique + '@example.invalid.dpeg',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/Chicago',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
    }
}
