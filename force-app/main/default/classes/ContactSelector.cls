/**
 * Selector for the standard Contact object. Encapsulates ALL SOQL against Contact
 * per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must
 * live in Selector classes. Nothing else queries that object.").
 *
 * Consumers:
 *   • BrokerAssignmentController.getBrokerOptions -> selectBrokersOrderedByName
 *     (P4, Module B2 — Property Management; internal, USER_MODE).
 *   • BrokerController.getBrokerHub -> selectBrokersRankedByClosedVolume +
 *     selectTopBrokersByActiveListings (P4 cleanup wave F2 — the Broker Hub page;
 *     internal, USER_MODE. Module B missed this class; see the ⚠ FLS note below).
 *   • BrokerPortalController.brokerPriorityFor -> GuestReads
 *     .selectBrokerPriorityByEmailSystem (P4 cleanup wave — guest LWR deal-intake
 *     controller; SYSTEM_MODE + without sharing, nested class below).
 *   • BrokerFirmController.getBrokerFirm -> selectEarliestByAccountId (P4 cleanup
 *     wave G — Opportunity sidebar broker person; internal, USER_MODE, Name-only).
 *   • LeadConvertMatchService.matchForConversion -> selectByEmails (Smart Lead
 *     Conversion, 2026-08-02 — resolves the existing broker Contact so converting a
 *     repeat broker attaches instead of duplicating; internal, USER_MODE). This is
 *     the FIRST outer-class method here that reads the FLS-permissionable
 *     Contact.Email, so it is the first that can throw on FLS for a legitimate
 *     internal user — its caller owns the fail-soft. **Scoped to Contact.Broker
 *     (2026-08-10, IR segregation) — see that method's ApexDoc.**
 *
 * MODE — mixed, per method (each method's ApexDoc restates its own mode):
 *   • selectBrokersOrderedByName uses `WITH USER_MODE` (API 67). Design §5
 *     classifies the standard fields touched here: Name is permissionable=false
 *     (always readable). The query also selects the custom Contact.Broker_Firm__c
 *     and filters on the custom Contact.Is_Broker__c; BOTH are FLS-controlled custom
 *     fields granted by the DPEG_Acquisitions permission set (see the SelectorTest
 *     runAs proof). ⚠ CORRECTED 2026-08-10 (IR segregation, Task 6): DPEG_Acquisitions
 *     is NOT the only permset granting them — DPEG_Contact_Edit / DPEG_Contact_View
 *     (Task 2) also grant Contact-field FLS to reach the Contact.Broker record type,
 *     and the SelectorTest runAs fixture itself now assigns both. USER_MODE therefore
 *     enforces the running user's FLS on those custom fields, from whichever permset
 *     supplies it.
 *   • selectBrokersRankedByClosedVolume and selectTopBrokersByActiveListings use
 *     `WITH USER_MODE`. They select Name (permissionable=false) plus SEVEN custom
 *     Contact fields (Broker_Firm__c, Broker_Specialty__c, Broker_Status__c,
 *     Active_Listings__c, Offers_Received__c, Closed_Volume__c, Avg_Days_On_Market__c)
 *     and filter Is_Broker__c / Active_Listings__c. Those custom fields are covered by
 *     the P3 blanket "custom-field FLS gap = 0" verdict (design §5) but are NOT
 *     itemised in design §5's Contact FLS table — see the ⚠ DESIGN NOTE below.
 *   • GuestReads.selectBrokerPriorityByEmailSystem uses `WITH SYSTEM_MODE` (API 67)
 *     inside a `without sharing` inner class — the guest Broker-Portal intake path
 *     (see that class's ApexDoc).
 *
 * ⚠ SHARING — the broker-priority lookup is BEHAVIOR-PRESERVING WITHOUT SHARING (see
 * the nested `GuestReads` class). The outer ContactSelector stays `with sharing`;
 * only the guest lookup lives in the `without sharing` inner class so it sees the
 * broker Contact regardless of the guest user's sharing — exactly as the original
 * `without sharing` BrokerPortalController inline query did. Under `WITH SYSTEM_MODE`,
 * FLS is bypassed but record-level sharing follows the class keyword; a `with sharing`
 * selector would have silently scoped the lookup to the (minimal, unconfigured) guest
 * sharing and defaulted every broker to 'Standard' priority.
 *
 * ⚠ DESIGN NOTE (flagged to the orchestrator): design §5 characterises the Contact
 * queries as "selects Name only", but two relocated queries genuinely select custom,
 * FLS-controlled fields:
 *   - getBrokerOptions -> selectBrokersOrderedByName selects Broker_Firm__c and
 *     filters Is_Broker__c.
 *   - getBrokerHub -> selectBrokersRankedByClosedVolume /
 *     selectTopBrokersByActiveListings select SEVEN custom Broker_* fields and filter
 *     Is_Broker__c / Active_Listings__c. RentRollController/BrokerController were never
 *     in the design's §2 inventory (Module B built BrokerAssignment and missed them),
 *     so those seven fields were never itemised in §5's Contact FLS table — they rely
 *     solely on the P3 blanket "custom-field FLS gap = 0" measurement, not a per-field
 *     check. A running user WITHOUT a permset granting those Contact fields will hit a
 *     USER_MODE QueryException here. See the report.
 *
 * @see .claude/skills/sf-apex/references/AccountSelector.cls
 * @see force-app/main/default/classes/TaskSelector.cls (P4 standard-object template)
 * @see agent-output/p4-selector-design.md (§3 #19, §4, §5)
 */
public with sharing class ContactSelector {

    /**
     * Broker Contacts (Is_Broker__c = true) ordered by Name — backs
     * BrokerAssignmentController.getBrokerOptions, which renders each as a
     * "Name · Firm" picklist option. Selects Broker_Firm__c so the caller can build
     * that label; the field set and `ORDER BY Name` mirror the original inline query.
     *
     * @return Broker Contacts (Id, Name, Broker_Firm__c) ordered by Name; an empty
     *         list when no broker Contacts exist (never null).
     * @example
     * List<Contact> brokers = ContactSelector.selectBrokersOrderedByName();
     */
    public static List<Contact> selectBrokersOrderedByName() {
        return [
            SELECT Id, Name, Broker_Firm__c
            FROM Contact
            WHERE Is_Broker__c = true
            WITH USER_MODE
            ORDER BY Name
        ];
    }

    /**
     * All broker Contacts (Is_Broker__c = true) ranked by Closed_Volume__c — backs
     * BrokerController.getBrokerHub, which uses this both as the full broker list and to
     * derive the header stats (firm count, active-broker count, listing/offer/volume
     * totals). Ordered by Closed_Volume__c DESC NULLS LAST, then Name ASC, and selects
     * the seven Broker_* stat fields, mirroring the original inline query exactly.
     *
     * @return Broker Contacts (Id, Name, and the seven Broker_* fields) ranked by closed
     *         volume; an empty list when no broker Contacts exist (never null).
     * @example
     * List<Contact> brokers = ContactSelector.selectBrokersRankedByClosedVolume();
     */
    public static List<Contact> selectBrokersRankedByClosedVolume() {
        return [
            SELECT Id, Name, Broker_Firm__c, Broker_Specialty__c, Broker_Status__c,
                   Active_Listings__c, Offers_Received__c, Closed_Volume__c, Avg_Days_On_Market__c
            FROM Contact
            WHERE Is_Broker__c = true
            WITH USER_MODE
            ORDER BY Closed_Volume__c DESC NULLS LAST, Name ASC
        ];
    }

    /**
     * Top broker Contacts with at least one active listing, ranked for the "top brokers"
     * widget — backs BrokerController.getBrokerHub. Filters Is_Broker__c = true AND
     * Active_Listings__c > 0, orders by Active_Listings__c DESC then Closed_Volume__c
     * DESC NULLS LAST, and caps the result at maxRows. Field set matches
     * selectBrokersRankedByClosedVolume so the caller maps both lists identically.
     *
     * @param maxRows Maximum rows to return (the caller's TOP_LIMIT). A null or
     *                non-positive value yields an empty list without querying.
     * @return Up to maxRows broker Contacts with active listings, ranked; an empty list
     *         when maxRows is null/non-positive or no broker has active listings (never null).
     * @example
     * List<Contact> top = ContactSelector.selectTopBrokersByActiveListings(6);
     */
    public static List<Contact> selectTopBrokersByActiveListings(Integer maxRows) {
        if (maxRows == null || maxRows <= 0) {
            return new List<Contact>();
        }
        return [
            SELECT Id, Name, Broker_Firm__c, Broker_Specialty__c, Broker_Status__c,
                   Active_Listings__c, Offers_Received__c, Closed_Volume__c, Avg_Days_On_Market__c
            FROM Contact
            WHERE Is_Broker__c = true AND Active_Listings__c > 0
            WITH USER_MODE
            ORDER BY Active_Listings__c DESC, Closed_Volume__c DESC NULLS LAST
            LIMIT :maxRows
        ];
    }

    /**
     * The earliest-created Contact linked to an Account — backs
     * BrokerFirmController.getBrokerFirm, which treats it as the broker person behind
     * the brokerage firm (Account). Selects Id + Name (the caller reads only Name) and
     * orders CreatedDate ASC LIMIT 1, mirroring the original inline query. Added by P4
     * cleanup wave G.
     *
     * MODE — `WITH USER_MODE`. Only Name (permissionable=false) is selected and only
     * the standard AccountId is filtered, so USER_MODE cannot throw an FLS error here
     * (no custom, FLS-controlled field is touched — unlike the broker methods above).
     *
     * READ-FOR-DISPLAY: an Account with no linked Contact is a normal state, so this
     * returns Contact-or-null rather than throwing.
     *
     * @param accountId The firm Account whose broker Contact to read; null-safe.
     * @return The earliest-created Contact (Id, Name) for the Account, or null when
     *         the input is null or the Account has no Contact.
     * @example
     * Contact broker = ContactSelector.selectEarliestByAccountId(accountId);
     */
    public static Contact selectEarliestByAccountId(Id accountId) {
        if (accountId == null) {
            return null;
        }
        List<Contact> contacts = [
            SELECT Id, Name
            FROM Contact
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY CreatedDate
            LIMIT 1
        ];
        return contacts.isEmpty() ? null : contacts[0];
    }

    /**
     * Contacts whose Email exactly matches one of the supplied addresses AND that belong to an
     * Account — backs LeadConvertMatchService's broker match on Lead.Email (Smart Lead
     * Conversion), so converting a repeat broker attaches to the Contact they already are rather
     * than minting a duplicate.
     *
     * INTERNAL PATH, NOT GUEST. This lives on the OUTER class (with sharing, USER_MODE) and is
     * deliberately NOT a sibling of GuestReads.selectBrokerPriorityByEmailSystem below. That one
     * is the public Broker-Portal guest read and is without-sharing/SYSTEM_MODE for reasons that
     * do not apply here: this read runs for a signed-in user clicking Convert on a Lead record.
     * Do not "consolidate" the two — they answer different questions under different trust models.
     *
     * `AccountId != null` IS A FILTER, NOT A DEFENSIVE CHECK. Salesforce requires the conversion
     * target Contact to belong to the Account being converted into (LeadConvert.setContactId is
     * only valid alongside a setAccountId for that Contact's own Account). Excluding orphans in
     * the QUERY means the caller has no special case to forget: an account-less Contact simply
     * never matches, and that Lead takes the ordinary create-a-new-Contact path. Accepted
     * consequence (design L1): a broker whose only Contact has no Account still gets a duplicate.
     *
     * CASE-INSENSITIVITY IS THE PLATFORM'S. SOQL string comparison on Email fields is
     * case-insensitive by default, so `WHERE Email IN :emails` already means "case-insensitive
     * exact". Do NOT add LOWER() — invalid here and unnecessary. The caller still lower-cases its
     * Map keys, because Apex Map keys ARE case-sensitive.
     *
     * ORDERING IS LOAD-BEARING (design D2, oldest-wins), identical to AccountSelector.selectByNames:
     * `CreatedDate ASC, Id ASC` lets the caller take the first row per email as the winner.
     * CreatedDate alone is not a total order (same-transaction rows share it), so `Id ASC` is the
     * tiebreak that keeps the pick deterministic across conversions. No LIMIT — this is a bulk
     * read for N Leads and a LIMIT would drop other emails' rows.
     *
     * MODE — `WITH USER_MODE`. Contact.Email IS FLS-permissionable, so unlike the Name-only
     * methods above this query genuinely CAN throw for a user without read on it. USER_MODE
     * throws rather than degrading; that is handled by the sole caller, which catches
     * QueryException and falls back to no-match so conversion never regresses (see
     * LeadConvertMatchService's fail-soft section). Left to propagate here by design.
     *
     * RECORD TYPE SCOPE (2026-08-10, IR segregation). Restricted to Contact.Broker. The broker
     * and investor populations are disjoint by policy, so this filter changes no behaviour
     * today — it makes the guarantee STRUCTURAL. Without it, one shared email address between
     * a broker and an investor would attach an acquisition deal to an IR Contact and its
     * Investing_Entity Account, which is precisely the boundary this module exists to hold.
     *
     * ⚠ A Contact on the MASTER record type will not match. That is intended and is why the
     * Task 3 backfill is gated on a zero-row query before OWD flips.
     *
     * @param emails Broker email addresses to resolve (the converting Leads' Email values); null
     *               or empty returns an empty list WITHOUT querying.
     * @return Matching Broker-record-type Contacts with an Account (Id, Email, AccountId,
     *         CreatedDate) ordered CreatedDate ASC, Id ASC; an empty list when the input is
     *         null/empty, nothing matches, or the only matches are on a non-Broker record type
     *         (never null).
     * @throws System.QueryException when the running user lacks read on Contact or Contact.Email.
     * @example
     * List<Contact> brokers = ContactSelector.selectByEmails(new Set<String>{ 'broker@firm.com' });
     */
    public static List<Contact> selectByEmails(Set<String> emails) {
        if (emails == null || emails.isEmpty()) {
            return new List<Contact>();
        }
        return [
            SELECT Id, Email, AccountId, CreatedDate
            FROM Contact
            WHERE Email IN :emails
              AND AccountId != null
              AND RecordType.DeveloperName = 'Broker'
            WITH USER_MODE
            ORDER BY CreatedDate ASC, Id ASC
        ];
    }

    /**
     * Guest-portal anti-abuse Contact reads that MUST run WITHOUT SHARING.
     *
     * `without sharing` — guest-portal read; must see the broker Contact regardless
     * of the site guest user's sharing, which is minimal and unconfigured (P3 guest
     * spike incomplete). Inner classes do NOT inherit the outer class's sharing, so
     * `without sharing` is declared explicitly here; the outer ContactSelector stays
     * `with sharing`. Apex forbids static methods on inner classes, so this is an
     * instance method — call
     * `new ContactSelector.GuestReads().selectBrokerPriorityByEmailSystem(...)`.
     *
     * ⚠ PRE-PROMOTION: this preserves the INTENT (broker-priority visible to the
     * guest intake, as the original `without sharing` BrokerPortalController inline
     * query did), but the guest sharing/ownership model itself is still unverified —
     * the P3 guest-sharing spike must be completed before portal promotion.
     */
    public without sharing class GuestReads {

        /**
         * The most-recent broker Contact for an email — backs
         * BrokerPortalController.brokerPriorityFor, which copies the broker's
         * priority onto each lead they submit so intake can be worked priority-first.
         * Selects Broker_Priority__c and filters the custom Is_Broker__c, mirroring
         * the original inline query exactly (field set, LIMIT 1, email trim on bind).
         *
         * SYSTEM_MODE (API 67) bypasses FLS; the enclosing `without sharing` bypasses
         * record sharing — together reproducing the original all-fields/all-records
         * guest read.
         *
         * @param email The broker's email; matched case-sensitively against
         *              Contact.Email after trim. Null/blank returns null.
         * @return The matching broker Contact with Broker_Priority__c populated, or
         *         null when the input is blank or no broker Contact has that email.
         * @example
         * Contact broker = new ContactSelector.GuestReads()
         *     .selectBrokerPriorityByEmailSystem(email);
         */
        public Contact selectBrokerPriorityByEmailSystem(String email) {
            if (String.isBlank(email)) {
                return null;
            }
            String trimmedEmail = email.trim();
            List<Contact> brokers = [
                SELECT Broker_Priority__c
                FROM Contact
                WHERE Email = :trimmedEmail AND Is_Broker__c = true
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            return brokers.isEmpty() ? null : brokers[0];
        }
    }
}
