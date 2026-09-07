/**
 * Selector for the standard Account object. Encapsulates ALL SOQL against Account per
 * ARCHITECTURE.md §2 and .claude/rules/apex-layering-rule.md ("All SOQL must live in Selector
 * classes. Nothing else queries that object.").
 *
 * ⚠ THIS IS THE FIRST ACCOUNT SOQL IN THE APPLICATION. Before this class there was zero Account
 * SOQL anywhere in force-app/main/default/classes (verified 2026-08-02). Every future Account read
 * belongs here — do not inline one.
 *
 * Consumers:
 *   • LeadConvertMatchService.matchForConversion -> selectByNames (Smart Lead Conversion: resolves
 *     an existing brokerage-firm Account by exact name when a converting Lead has no matching
 *     Contact, so the new Contact lands under the firm that already exists instead of minting a
 *     second Account). Internal, user-initiated path — USER_MODE. **Scoped to Account.Broker_Firm
 *     (2026-08-10, IR segregation) — see that method's ApexDoc.**
 *
 * DOMAIN NOTE — in this app an Account IS a brokerage firm (see BrokerFirmController, which
 * aggregates every Opportunity on an Account into that firm's deal counts). "Account name" and
 * "firm name" are the same thing throughout.
 *
 * ── MODE ──────────────────────────────────────────────────────────────────────────────────
 * `with sharing` per ARCHITECTURE.md §2 (mandatory on every selector). Sharing is deliberate and
 * has a stated consequence: an Account the converting user cannot see will not match, so the
 * conversion mints a new one — silently, since the duplicate-rule bypass that shipped with this
 * feature no longer blocks it (see the fail-soft section of LeadConvertMatchService's header).
 *
 * `WITH USER_MODE` (API 67), the §2 default. This is an interactive, user-initiated read (a user
 * clicking Convert on a Lead), not the guest/automation path that earns SYSTEM_MODE in
 * LeadSelector.GuestReads / EmailThreadGuardService, so no SYSTEM_MODE justification exists.
 *
 * ⚠ USER_MODE THROWS, it does not degrade. Of the fields selected here, Name and CreatedDate are
 * `permissionable=false` (never FLS-subject), so the realistic failure is OBJECT-level: a running
 * user with no Read on Account. That still raises System.QueryException. The sole caller catches it
 * and falls back to no-match rather than letting it break conversion — see
 * LeadConvertMatchService's "fail-soft" section. Do not add a caller that assumes this cannot throw.
 *
 * @see force-app/main/default/classes/LeadConvertMatchService.cls (sole consumer)
 * @see force-app/main/default/classes/ContactSelector.cls (companion email-keyed read)
 * @see .claude/skills/sf-apex/references/AccountSelector.cls (reference pattern)
 */
public with sharing class AccountSelector {

    /**
     * Accounts whose Name exactly matches one of the supplied names — backs
     * LeadConvertMatchService's firm-name match on Lead.Company.
     *
     * CASE-INSENSITIVITY IS THE PLATFORM'S, NOT OURS. SOQL string comparison on Text fields is
     * case-insensitive by default, so `WHERE Name IN :names` already means "case-insensitive
     * exact". Do NOT wrap either side in LOWER() — it is not valid SOQL here and is not needed.
     * The caller still lower-cases when it BUCKETS the rows into a Map, because Apex Map keys are
     * case-sensitive even though the query was not.
     *
     * ORDERING IS LOAD-BEARING (design D2, oldest-wins). `ORDER BY CreatedDate ASC, Id ASC` lets
     * the caller take the FIRST row per name as the winner without a second sort. CreatedDate
     * alone is not a total order — rows created in one transaction can share it — so `Id ASC` is
     * the tiebreak that makes the pick deterministic and stops the target oscillating between two
     * Accounts across conversions. Because the order is ascending, a newly created duplicate can
     * never displace the canonical target: the rule is convergent.
     *
     * No LIMIT: this is a bulk read for N Leads at once, so the per-name "LIMIT 1" is applied by
     * the caller when it builds its map. Adding LIMIT here would silently drop other names' rows.
     *
     * RECORD TYPE SCOPE (2026-08-10, IR segregation). Restricted to Account.Broker_Firm. The
     * broker and investor populations are disjoint by policy, so this filter changes no behaviour
     * today — it makes the guarantee STRUCTURAL. Without it, one shared firm name between a
     * brokerage and an investing entity would attach an acquisition deal's new Contact to an
     * Investing_Entity Account, which is precisely the boundary this module exists to hold.
     *
     * ⚠ An Account on the MASTER record type will not match. That is intended and is why the
     * Task 3 backfill is gated on a zero-row query before OWD flips.
     *
     * @param names Account names to resolve (typically the converting Leads' Company values);
     *              null or empty returns an empty list WITHOUT querying, so callers pay no SOQL
     *              for an empty key set.
     * @return Matching Broker_Firm-record-type Accounts (Id, Name, CreatedDate) ordered
     *         CreatedDate ASC, Id ASC; an empty list when the input is null/empty, nothing
     *         matches, or the only matches are on a non-Broker_Firm record type (never null).
     * @throws System.QueryException when the running user lacks Read on Account (USER_MODE).
     *         Deliberately left to propagate — LeadConvertMatchService owns the fail-soft decision.
     * @example
     * List<Account> firms = AccountSelector.selectByNames(new Set<String>{ 'Marcus & Millichap' });
     */
    public static List<Account> selectByNames(Set<String> names) {
        if (names == null || names.isEmpty()) {
            return new List<Account>();
        }
        return [
            SELECT Id, Name, CreatedDate
            FROM Account
            WHERE Name IN :names
              AND RecordType.DeveloperName = 'Broker_Firm'
            WITH USER_MODE
            ORDER BY CreatedDate ASC, Id ASC
        ];
    }
}
