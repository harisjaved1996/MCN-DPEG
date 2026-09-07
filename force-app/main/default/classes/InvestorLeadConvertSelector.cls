/**
 * Selector for the Investor Relations lead-conversion action. Encapsulates ALL SOQL for that
 * feature per ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live in
 * Selector classes"). Its sole consumer is InvestorLeadConvertService.
 *
 * ── WHY A FEATURE-SCOPED SELECTOR RATHER THAN LeadSelector / ContactSelector ─────────────────
 * This class spans TWO objects, which is a deliberate, narrow departure from the one-selector-
 * per-SObject convention. It is not duplication — neither incumbent selector can serve this
 * feature, and extending them would be actively harmful:
 *
 *   • ContactSelector.selectByEmails filters `AccountId != null AND RecordType.DeveloperName =
 *     'Broker'`. An IR investor Contact matches NEITHER clause by construction: it is created
 *     account-less by the "Create Profile" step (which is the entire reason this feature needs a
 *     temporary Account at all), and it is not a broker. Widening those two filters to serve IR
 *     would silently re-open the acquisition-side boundary that ARCHITECTURE.md's IR-segregation
 *     work closed on 2026-08-10 — a repeat broker could then attach to an investor Contact.
 *   • LeadSelector has no method returning this field set. selectMatchKeysByIds returns only
 *     (Id, Email, Company) and selectConversionById returns only the conversion state; this
 *     feature needs IsConverted for the already-converted guard AND the name/status/record-type
 *     fields that make its refusal messages identify the Lead to a human.
 *
 * Keeping both reads here means the IR conversion path can be reasoned about, and its FLS
 * surface audited, in one file. If IR grows a second feature that reads Contact, promote the
 * Contact method to ContactSelector as a record-type-scoped sibling rather than growing this class.
 *
 * ── MODE ────────────────────────────────────────────────────────────────────────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector).
 *
 * ⚠ AMENDED 2026-08-16 — THIS CLASS NOW MIXES MODES DELIBERATELY. READ THE METHOD, NOT THE CLASS.
 * This paragraph used to read "`WITH USER_MODE` on BOTH methods"; there are now three methods and
 * that claim is false. The rule is per-method and turns on WHO ASKED FOR THE READ:
 *
 *   • selectByIds, selectContactsByEmails — `WITH USER_MODE`. The §2 default, and here a deliberate
 *     choice rather than an inherited one. This is a USER-INITIATED path: a person clicks the
 *     "Investor Converted" quick action, a Screen Flow runs, and this Apex reads on their behalf at
 *     their request. A permission gap on that path is a real provisioning defect and SHOULD surface
 *     as an error the user can report, not be bypassed into a silently wrong answer.
 *   • selectContactsByIds — `WITH SYSTEM_MODE`. The cascade-delete safety re-query. The user did not
 *     ask for it; it is performed on their behalf to decide whether a delete is safe, which is §2's
 *     automation-path exception. A USER_MODE throw there does not degrade, it disables the cleanup
 *     org-wide and strands temporary Accounts — the exact precondition for the measured data loss.
 *     The full justification, and the separate sharing analysis, live at that method.
 *
 * ⚠ USER_MODE THROWS, IT DOES NOT DEGRADE. Both queries touch FLS-permissionable fields
 * (Lead.Email / FirstName / LastName / Status, Contact.Email / AccountId), so a user without the
 * right grants raises System.QueryException — reported as "No such column '<field>' on entity
 * '<object>'", which is how the platform words an FLS DENIAL, not a missing field. Do not read
 * that message as a broken query. Both methods leave the exception to PROPAGATE; the caller owns
 * the decision about what to do with it (InvestorLeadConvertService catches it and returns a typed
 * failure on every Result rather than throwing into the Flow's fault path).
 *
 * @see force-app/main/default/classes/InvestorLeadConvertService.cls (sole consumer)
 * @see force-app/main/default/classes/ContactSelector.cls (the broker-scoped email read; not reusable here)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls (reference pattern)
 */
public with sharing class InvestorLeadConvertSelector {

    /**
     * The Leads to be converted, with everything the IR conversion action needs to validate them
     * and to name them in a refusal message.
     *
     * FIELD SET IS THE CONTRACT — do not narrow it:
     *   • IsConverted backs the already-converted guard. Without it the action would hand an
     *     already-converted Lead to Database.convertLead and surface a raw platform DML error
     *     instead of a clean message.
     *   • Email is the key that resolves the existing investor Contact (see selectContactsByEmails).
     *   • FirstName / LastName / Status / RecordTypeId are diagnostic: they let the service say
     *     WHICH Lead it refused and why, which is the difference between a Flow the user can act
     *     on and one that reports "something went wrong".
     *   • Is_Accredited__c / Referred_By__c are CARRIED, not read for display: the service copies
     *     them onto the Contact the conversion creates, riding on the detach statement it already
     *     issues (InvestorLeadConvertService.detachContacts). They are here — rather than in a
     *     second read — precisely so the feature's 1-SOQL contract is unchanged: this is a FIELD
     *     LIST widening, not a new query. Standard fields (Name, Email, Phone) are mapped by
     *     Database.convertLead itself and are deliberately NOT carried in Apex.
     *
     * ⚠ WIDENING THE FIELD LIST WIDENS THE FLS SURFACE. Under WITH USER_MODE a persona without
     * Read on EITHER carried field makes this query THROW, which the service reports as
     * ERROR_READ_DENIED on every Result — i.e. the whole conversion is refused, not degraded.
     * DPEG_IR_Default_Access (the only permission set granting this feature's Apex) grants both
     * Lead fields readable+editable, so the designed persona is covered; any NEW persona given this
     * action must be granted both.
     *
     * NO RECORD TYPE FILTER, DELIBERATELY. RecordTypeId is SELECTED but not FILTERED. Restricting
     * to the Investor_Onboarding record type would make a Lead on any other type return zero rows
     * and surface as "Lead not found" — a misleading message for a real, visible record. The quick
     * action that invokes this feature is itself scoped to the IR page layout, so the record-type
     * boundary is enforced where the user actually is. Selecting the field keeps it available if a
     * future decision wants an explicit, well-worded refusal instead.
     *
     * NOT-FOUND CONTRACT — Leads the running user cannot SEE simply do not come back. The caller
     * compares the returned Ids against what it asked for and reports the difference as a typed
     * failure; it must never assume the result is index-parallel to the input.
     *
     * @param leadIds The Leads to read; null or empty returns an empty list WITHOUT querying, so
     *                callers pay no SOQL for an empty key set.
     * @return Matching Leads (Id, Email, FirstName, LastName, Status, IsConverted, RecordTypeId,
     *         Is_Accredited__c, Referred_By__c); an empty list when the input is null/empty or
     *         nothing is visible (never null).
     * @throws System.QueryException when the running user lacks Read on Lead or on any selected
     *         FLS-permissionable field. Left to propagate by design — see the class header.
     * @example
     * List<Lead> leads = InvestorLeadConvertSelector.selectByIds(new Set<Id>{ leadId });
     */
    public static List<Lead> selectByIds(Set<Id> leadIds) {
        if (leadIds == null || leadIds.isEmpty()) {
            return new List<Lead>();
        }
        return [
            SELECT Id, Email, FirstName, LastName, Status, IsConverted, RecordTypeId,
                   Is_Accredited__c, Referred_By__c
            FROM Lead
            WHERE Id IN :leadIds
            WITH USER_MODE
        ];
    }

    /**
     * The CASCADE-DELETE SAFETY RE-QUERY. Reads back the Contacts the conversion just created so the
     * caller can PROVE, from the database rather than from a save-result, that each one is no longer
     * parented to its temporary Account before that Account is deleted.
     *
     * 🔴 THIS METHOD EXISTS BECAUSE A Database.SaveResult IS NOT EVIDENCE OF THE STORED STATE. It
     * reports that a statement was accepted, not that a particular field now holds a particular
     * value. Deleting an Account cascade-deletes its Contacts, so the ONLY safe precondition for
     * that delete is a re-read showing AccountId = null. See
     * InvestorLeadConvertService.confirmDetachments — a Contact that does not come back from this
     * query, for ANY reason, is treated as still attached and its temporary Account is left alone.
     *
     * ── MODE: `WITH SYSTEM_MODE`, AND THIS IS THE ONE METHOD HERE THAT EARNS IT ─────────────────
     * The class header's blanket "USER_MODE on both methods, this is a user-initiated path" reasoning
     * was written when this class had two methods and is NO LONGER TRUE OF THE WHOLE CLASS. It still
     * governs selectByIds and selectContactsByEmails, which back reads the user actually asked for.
     * This read is different in kind: the user asked to convert a Lead, not to re-read a Contact.
     * This is a safety check the platform performs ON THEIR BEHALF, which is exactly the
     * automation-path exception in ARCHITECTURE.md §2.
     *
     * The consequence of getting it wrong is the whole reason for the distinction: USER_MODE THROWS,
     * IT DOES NOT DEGRADE. A persona without FLS Read on Contact.AccountId would make this query
     * raise System.QueryException, no Contact would ever be confirmed, and therefore NO temporary
     * Account would ever be deleted — every conversion would strand one. That is not a harmless
     * degradation: a stranded "IR Conversion Temp Account" is precisely what a human later deletes by
     * hand, and that manual delete cascade-destroys the investor Contact. MEASURED on
     * DPEG-IR-Implementation 2026-08-16: two investor Contacts (003ak00001tGp3CAAS,
     * 003ak00001tuSHhAAM) were destroyed exactly that way. Choosing USER_MODE here would convert a
     * field-permission gap into the very data loss this re-query exists to prevent.
     *
     * ⚠ SHARING IS A SEPARATE QUESTION AND WAS ASKED SEPARATELY (ARCHITECTURE.md §2 is explicit that
     * SYSTEM_MODE lifts CRUD/FLS and never sharing). It needs no `without sharing` inner class:
     * Contact's org-wide default in this org is ReadWrite for internal users — measured 2026-08-16
     * via Tooling `EntityDefinition.InternalSharingModel` — so `with sharing` cannot filter these
     * rows for any internal persona, and the Contact was created seconds earlier in this same
     * transaction by the running user. If Contact OWD is ever narrowed to Private or
     * ControlledByParent, revisit this: a sharing-filtered row would read as "unconfirmed", which
     * fails CLOSED (the Account is left behind) — inconvenient, never destructive.
     *
     * @param contactIds The Contacts to re-read; null or empty returns an empty list WITHOUT
     *                   querying, so callers pay no SOQL for an empty key set.
     * @return Matching Contacts (Id, AccountId); an empty list when the input is null/empty or
     *         nothing matches (never null). NOT index-parallel to the input — the caller must map
     *         by Id and treat an absent Id as "not confirmed".
     * @example
     * Map<Id, Contact> byId =
     *     new Map<Id, Contact>(InvestorLeadConvertSelector.selectContactsByIds(contactIds));
     */
    public static List<Contact> selectContactsByIds(Set<Id> contactIds) {
        if (contactIds == null || contactIds.isEmpty()) {
            return new List<Contact>();
        }
        return [
            SELECT Id, AccountId
            FROM Contact
            WHERE Id IN :contactIds
            WITH SYSTEM_MODE
        ];
    }

    /**
     * Contacts whose Email matches one of the supplied addresses, MOST RECENTLY CREATED FIRST —
     * this is how the IR conversion action finds the investor Contact that the earlier
     * "Create Profile" step already created, so conversion REUSES it instead of minting a second.
     *
     * ⚠ NO `AccountId != null` FILTER, AND THAT IS THE WHOLE POINT. ContactSelector.selectByEmails
     * carries that filter because acquisition-side conversion attaches a broker to a firm that
     * already exists. The IR Contact is the exact opposite case: it is created ACCOUNT-LESS, and
     * the temporary Account this feature builds exists precisely to give it a parent for the
     * duration of the convertLead call (Salesforce requires the target Contact to belong to the
     * Account being converted into). Adding that filter here would make the feature match nothing
     * and fail 100% of the time.
     *
     * ⚠ NO RECORD TYPE FILTER, DELIBERATELY. ContactSelector.selectByEmails is scoped to
     * `RecordType.DeveloperName = 'Broker'`; the mirror-image `'Investor'` filter is NOT applied
     * here because this codebase has not verified that record type exists and is available in the
     * target org. An unverified filter fails SILENTLY — it returns zero rows and the feature
     * reports "no Contact found" for a Contact sitting in plain sight — which is the worst
     * available failure mode. Scope this once the record type is confirmed present AND the
     * existing Contacts have been migrated onto it, not before.
     *
     * ORDERING IS LOAD-BEARING. `CreatedDate DESC` implements "take the most recently created
     * match", so the caller reads the FIRST row per email as the winner with no second sort.
     * `Id DESC` is a REQUIRED tiebreak, not decoration: CreatedDate is not a total order — rows
     * created in the same transaction share it to the second — so without it the winner is
     * whichever row the database happened to return, which makes the pick non-deterministic in
     * production and makes any test that seeds two Contacts in one setup method intermittently
     * red. Newest-wins is the opposite of the oldest-wins rule used by ContactSelector /
     * AccountSelector on the acquisition side; that is intended (a re-run of "Create Profile"
     * should be honoured, not ignored) and is why the two must not be "harmonised".
     *
     * AccountId IS SELECTED FOR A REASON — it is not display data. The caller records each
     * Contact's ORIGINAL parent before re-parenting it to the temporary Account, so it can put the
     * Contact back exactly where it found it. In the designed IR path that value is null and the
     * restore is literally "set AccountId back to null"; selecting it means the one case where it
     * is NOT null does not silently destroy a real Account relationship. See
     * InvestorLeadConvertService.detachContacts.
     *
     * No LIMIT: this is a bulk read for N Leads at once, so the per-email "first row wins" is
     * applied by the caller when it buckets the rows. A LIMIT here would silently drop other
     * emails' rows.
     *
     * @param emails The Lead email addresses to resolve; null or empty returns an empty list
     *               WITHOUT querying. Matching is case-INSENSITIVE — SOQL string comparison on
     *               Email is case-insensitive by default, so no LOWER() is needed (nor valid)
     *               here. The caller still lower-cases its Map keys, because Apex Map keys ARE
     *               case-sensitive.
     * @return Matching Contacts (Id, Email, AccountId, CreatedDate) ordered CreatedDate DESC,
     *         Id DESC; an empty list when the input is null/empty or nothing matches (never null).
     * @throws System.QueryException when the running user lacks Read on Contact or on
     *         Contact.Email / Contact.AccountId. Left to propagate by design — see the class header.
     * @example
     * List<Contact> existing =
     *     InvestorLeadConvertSelector.selectContactsByEmails(new Set<String>{ 'investor@fund.com' });
     */
    public static List<Contact> selectContactsByEmails(Set<String> emails) {
        if (emails == null || emails.isEmpty()) {
            return new List<Contact>();
        }
        return [
            SELECT Id, Email, AccountId, CreatedDate
            FROM Contact
            WHERE Email IN :emails
            WITH USER_MODE
            ORDER BY CreatedDate DESC, Id DESC
        ];
    }
}
