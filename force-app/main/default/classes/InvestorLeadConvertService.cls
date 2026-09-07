/**
 * InvestorLeadConvertService — the Investor Relations lead conversion, exposed to Flow.
 *
 * Backs the "Investor Converted" quick action: quick action -> Screen Flow -> this Apex Action.
 *
 * 🔴 THERE IS NO CONTACT BEFORE CONVERSION — THE CONVERSION CREATES IT (redesigned 2026-08-12).
 * This class used to convert onto a Contact an earlier "Create Profile" step had already made.
 * That premise is gone: creating a standalone Contact ahead of conversion tripped
 * DUPLICATES_DETECTED, because the org's Contact duplicate rule matches a new Contact against OPEN
 * LEADS and therefore always matched the very Lead being worked. Letting Database.convertLead mint
 * the Contact sidesteps it entirely — conversion is a built-in operation the duplicate rule does
 * not block.
 *
 * Per Lead:
 *   1. insert a temporary Account, stamped Investing_Entity (describe-resolved, never a hardcoded Id)
 *   2. Database.convertLead(setLeadId + setAccountId + setDoNotCreateOpportunity(true)) — and
 *      deliberately NO setContactId, which is what makes the platform create the Contact
 *   3. read LeadConvertResult.getContactId()
 *   4. DETACH: one update setting AccountId = null and NOTHING ELSE
 *   5. CONFIRM: re-query those Contacts and keep only the ones the DATABASE says are now unparented
 *   6. delete the temporary Accounts that step 5 PROVED childless — never any other — and, for
 *      Investor_Onboarding Leads ONLY, follow that delete with Database.emptyRecycleBin so the
 *      throwaway Account is HARD-deleted rather than left restorable (see the hard-delete section)
 *   7. ENRICH: a second update carrying RecordTypeId = Contact `Investor` and the two IR fields
 *      Is_Accredited__c / Referred_By__c off the Lead
 *
 * ══ HARD DELETE OF THE TEMPORARY ACCOUNT — Investor_Onboarding ONLY (2026-08-16) ═════════════════
 * Step 6 used to leave the temporary Account in the Recycle Bin for 15 days. It now empties it, so
 * nothing restorable survives a conversion. Three things make this safe rather than reckless, and
 * all three were MEASURED on DPEG-IR-Implementation rather than assumed:
 *
 *   1. IT ONLY EVER TOUCHES AN ACCOUNT THIS CLASS JUST CREATED AND STEP 5 ALREADY PROVED CHILDLESS.
 *      The hard delete adds NO new record to the delete set — it re-uses deletableAccountIds
 *      verbatim. Every safety property of step 6 therefore carries over unchanged: an Account whose
 *      Contact could not be confirmed detached is still not deleted at all, let alone hard-deleted.
 *   2. emptyRecycleBin WORKS IN THE SAME TRANSACTION AS THE DELETE, DESPITE APPEARANCES. A probe did
 *      insert Account -> insert child Contact -> detach -> Database.delete -> Database.emptyRecycleBin,
 *      and a LATER transaction then found the row still readable as IsDeleted = true. That row is
 *      NOT a failed hard delete — it is Salesforce's physical retention before the background purge.
 *      The discriminating test is undelete: Database.undelete on that Account returned
 *      isSuccess() = false, `UNDELETE_FAILED: Entity is not in the recycle bin`, while the control
 *      arm (identical but with no emptyRecycleBin) undeleted successfully. A second transaction
 *      calling emptyRecycleBin on the same Id returned `INVALID_ID_FIELD: no recycle bin entry
 *      found`, which is the same fact from the other side: the bin entry is already gone.
 *      ⚠ DO NOT "FIX" THIS BY RE-QUERYING FOR IsDeleted = false. That assertion fails on a
 *      correctly hard-deleted record and would send the next reader chasing a non-bug.
 *   3. THE CONTACT IS UNAFFECTED. The same probe confirmed the detached Contact survived with
 *      IsDeleted = false. A hard delete cascades no further than a soft delete does — and by this
 *      point there is nothing left to cascade into.
 *
 * 🔴 SCOPED TO THE Investor_Onboarding LEAD RECORD TYPE, BY REQUEST. The record type is read off the
 * Lead captured at validate time and compared against a DESCRIBE-resolved Id. A Lead on any other
 * record type still gets the old behaviour — a plain, restorable delete. This matters because
 * InvestorLeadConvertSelector.selectByIds deliberately does NOT filter by record type (see its
 * header), so a non-IR Lead genuinely can reach this class, and irreversibility is not a default
 * worth extending to a path nobody asked for.
 *
 * ⚠ THE RECORD-TYPE LOOKUP HERE IS DELIBERATELY NOT isAvailable()-GUARDED, unlike recordTypeIdFor.
 * That helper feeds a WRITE, where stamping a record type the running user cannot use fails the DML.
 * This one CLASSIFIES a Lead that already carries the record type, and whether the running user may
 * USE it has nothing to do with whether the Lead has it. An org without the record type resolves to
 * null, no Lead matches, and every temporary Account falls back to a soft delete — degrading toward
 * the reversible option, which is the correct direction for a fail-safe.
 *
 * ⚠ A FAILED HARD DELETE IS A WARNING, NEVER A FAILURE. By the time it runs the Contact is created,
 * detached and safe, and the Account is already soft-deleted. The only cost is a Recycle Bin entry
 * an administrator can clear by hand, so it reports WARNING_TEMP_ACCOUNT_HARD_DELETE and never
 * touches `success`.
 *
 * ══ 🔴 WHY STEPS 4-7 ARE FOUR STATEMENTS AND NOT ONE — A DATA-LOSS POST-MORTEM (2026-08-16) ══════
 * This class previously did all of step 4 and step 7 in ONE update and deleted the temporary Account
 * whenever that update's Database.SaveResult reported success. Two investor Contacts were destroyed
 * (003ak00001tGp3CAAS, 003ak00001tuSHhAAM on DPEG-IR-Implementation). The mechanism, measured rather
 * than assumed, was:
 *
 *   (a) the combined update FAILED as a single row — so AccountId stayed set AND the IR fields were
 *       never carried (a converted Lead with Is_Accredited__c = true produced a Contact reading
 *       false, which is the visible symptom that identifies this failure);
 *   (b) the guard then worked exactly as designed and deliberately LEFT the temporary Account
 *       behind, warning the user;
 *   (c) days later an administrator, cleaning up leftover "IR Conversion Temp Account" records by
 *       hand, deleted them — and deleting an Account CASCADE-DELETES its Contacts.
 *
 * So the destroyer was a human delete, not this class's delete. That does not exonerate the design:
 * every stranded Account is a live cascade-delete waiting for a well-meaning cleanup. Two
 * independent changes were therefore made, and BOTH matter:
 *
 *   1. THE SAFETY WRITE IS NOW ALONE. Step 4 sets AccountId = null and nothing else, so it has the
 *      smallest possible failure surface. It can no longer be taken down by an unrelated field.
 *      MEASURED: `Database.update(new Contact(Id=c, AccountId=null, Referred_By__c=<bad Id>), false)`
 *      returns isSuccess() = false with INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY and leaves the
 *      Contact ATTACHED — one bad lookup value used to cost the detach. Enrichment now fails on its
 *      own, and a Contact that is merely un-enriched is a Contact that is still alive.
 *   2. THE DELETE NOW REQUIRES DATABASE EVIDENCE, NOT A SAVE-RESULT. A SaveResult reports that a
 *      statement was accepted, not that a field holds a value. Step 5 re-reads the Contacts and only
 *      an AccountId that is ACTUALLY null releases its temporary Account. This costs one extra SOQL;
 *      it is worth incomparably more than that.
 *
 * ⚠ DO NOT RE-MERGE STEPS 4 AND 7 TO "RESTORE THE 3-DML CONTRACT". The old contract is what this
 * change deliberately spent. Anyone adding a third carried field adds it to step 7, never to step 4.
 * Standard fields (Name, Email, Phone) are mapped by Database.convertLead itself — never carry those
 * in Apex (VERIFIED 2026-08-16 on a live conversion: the Contact is born with the Lead's Name, Email
 * and Phone already populated, so Apex must not and does not touch them).
 *
 * 🔴 STEP 4 MUST PRECEDE STEP 6, AND THIS IS NOT A STYLE PREFERENCE. Until it is detached the new
 * Contact is a CHILD of the temporary Account, and deleting an Account cascades into its Contacts —
 * deleting first destroys the investor Contact this action just created. Enforced structurally
 * (detachContacts, then confirmDetachments, then deleteTempAccounts) and evidentially (an Account Id
 * only enters the delete set once a RE-QUERY has shown its Contact's AccountId to be null).
 *
 * ⚠ DETACH AND DELETE BELONG IN THE SAME TRANSACTION — MEASURED, NOT ASSUMED (2026-08-16). The
 * obvious worry is that a null AccountId written earlier in the transaction might not be visible to
 * the delete's cascade evaluation, which would force step 6 into a Queueable. It is visible. A
 * savepoint-wrapped probe on DPEG-IR-Implementation did insert Account -> insert child Contact ->
 * update AccountId = null -> re-query (null) -> delete Account, and the Contact SURVIVED
 * (IsDeleted = false). The control arm, identical but skipping the detach, deleted the Contact
 * (IsDeleted = true), so the cascade is real and the test discriminates. No async hop is needed, and
 * adding one would be strictly worse: it would put a commit boundary between the conversion and the
 * cleanup, so a failure after commit would strand the Account with no in-transaction recovery.
 *
 * A null AccountId together with the `Investor` record type is accepted by the Contact validation
 * rule Record_Type_Matches_Account, so those two writes — and the two carried fields alongside
 * them — all fit in one statement.
 *
 * 🔴 setDoNotCreateOpportunity(true) WORKS HERE. The historical UNKNOWN_EXCEPTION it produced came
 * from the `Lead_Approved_Notify` record-triggered Flow binding a REQUIRED Apex input to
 * $Record.ConvertedOpportunityId; that flow now null-guards the binding. UNKNOWN_EXCEPTION from
 * Database.convertLead is ALWAYS a wrapper for a downstream trigger/rule/flow failure — it never
 * means "the platform does not support this option", and the real cause appears only in the raw
 * debug log.
 *
 * 🔴 THE Investor_Onboarding GUARD IN LeadConvertService STAYS — DO NOT DELETE IT AS REDUNDANT.
 * It is the only INTENTIONAL protection stopping the acquisitions cascade from stamping this
 * investor Contact as `Broker` (stampConvertedPartyRecordTypes, the one effect that survives) and
 * building a Property__c. The null-ConvertedOpportunityId early return only happens to catch IR
 * conversions today.
 *
 * ⚠ OpportunityReviewTriggerHandler.bypassDealTreeCreation is NOT set here: no Opportunity is
 * created, so OpportunityReviewTrigger never fires. That seam remains declared for other callers.
 *
 * ── GOVERNOR SHAPE IS A CONTRACT: 2 SOQL / 5 DML + 1 convertLead, CONSTANT IN LEAD COUNT ────────
 *   SOQL 1 — InvestorLeadConvertSelector.selectByIds          (the Leads, incl. the carried fields)
 *   DML  1 — Database.insert(tempAccounts, false)             (one bulk insert)
 *   ---- Database.convertLead(conversions, false)             (one call, partial success)
 *   DML  2 — Database.update(detachments, false)              (one bulk detach: AccountId = null ONLY)
 *   SOQL 2 — InvestorLeadConvertSelector.selectContactsByIds  (one bulk re-read: PROVE it is null)
 *   DML  3 — Database.delete(doomedAccounts, false)           (one bulk delete, proven-childless only)
 *   DML  4 — Database.emptyRecycleBin(hardDeletable)          (one bulk HARD delete, IR record type only)
 *   DML  5 — Database.update(enrichments, false)              (one bulk record-type + IR field carry)
 *
 * ⚠ DML 4 IS SKIPPED ENTIRELY when no converted Lead carries the Investor_Onboarding record type
 * (or the org has no such record type), so the shape is 4 DML on those paths and 5 on the IR path.
 * It is one statement for the whole batch either way and does not scale per Lead — the property
 * that actually matters. emptyRecycleBin counts as a DML STATEMENT (measured: Limits
 * .getDmlStatements() incremented by exactly one), and caps at 10,000 records per call, which this
 * feature cannot approach: the set is bounded by the Leads in a single Flow invocation.
 *
 * ⚠ THIS CONTRACT WAS WIDENED ON 2026-08-16 FROM "1 SOQL / 3 DML", DELIBERATELY, AND THE REASON IS
 * THE POST-MORTEM ABOVE. SOQL 2 buys the only trustworthy precondition for a cascading delete: the
 * stored AccountId, read back from the database instead of inferred from a save-result. DML 4 buys
 * the separation that stops a failed field write from taking the safety write down with it. Both
 * costs are ONE statement for the whole batch and neither scales per Lead, which is the property
 * that actually matters here — the old numbers were cheaper and unsafe, and a Contact is worth more
 * than a query. Do not "optimise" either of them back out.
 *
 * Every statement is isEmpty()-guarded and every one is allOrNone = false, so one bad Lead can
 * never roll back another Lead's conversion or — worse — another Lead's CLEANUP. Cleanup runs on
 * the failure path too: it is the unconditional next statement after the conversion attempt, not a
 * catch block. Record-type resolution is a memoized DESCRIBE and costs no SOQL.
 *
 * ── FAILURE HANDLING ────────────────────────────────────────────────────────────────────────────
 * Nothing here throws into the Flow's fault path — a fault screen cannot say WHICH Lead failed.
 * Every outcome is reported on its own index-parallel Result. Refusals that touch no database at
 * all: blank Lead Id, an Id that is not a Lead, Lead not visible, Lead already converted.
 *
 * ⚠ RECORD-TYPE VISIBILITY IS A DEPLOY GATE. Both stamps degrade to "leave it unset" when the
 * record type is absent or not available to the running user, and profiles are .forceignore'd, so
 * no file-based check can see it. Verify as the real IR persona; an administrator smoke test proves
 * nothing.
 * ⚠ The Lead's ConvertedAccountId points at the deleted temporary Account; the durable link is
 * ConvertedContactId. ConvertedOpportunityId is null.
 *
 * Layer: Service. Zero inline SOQL — the read goes through InvestorLeadConvertSelector.
 *
 * @see force-app/main/default/classes/InvestorLeadConvertSelector.cls
 * @see force-app/main/default/classes/LeadConvertService.cls (the acquisitions chain this avoids)
 * @see .claude/rules/invocable-rule.md
 */
public with sharing class InvestorLeadConvertService {

    /**
     * The org's converted LeadStatus. Verified against this org's Lead Status value set
     * (New, Under Review, Create Profile, Converted) — only 'Converted' is flagged converted=true.
     * Passing any other value to setConvertedStatus throws.
     */
    public static final String CONVERTED_STATUS = 'Converted';

    /**
     * Name prefix for the throwaway Account. The full name is "<prefix> <leadId>", which makes an
     * orphan (should one survive a catastrophic failure) self-identifying: it names the Lead it
     * belongs to, and distinct names keep N simultaneous temp Accounts from looking like N
     * duplicates of one record to any Account duplicate rule.
     */
    public static final String TEMP_ACCOUNT_NAME_PREFIX = 'IR Conversion Temp Account';

    /** Account record type stamped on the temporary Account. */
    private static final String TEMP_ACCOUNT_RECORD_TYPE = 'Investing_Entity';

    /** Contact record type stamped on the Contact the conversion creates. */
    private static final String INVESTOR_CONTACT_RECORD_TYPE = 'Investor';

    /**
     * The Lead record type whose temporary Account is HARD-deleted rather than merely soft-deleted.
     * Purely a CLASSIFIER — nothing is stamped with it — which is why the helper that resolves it is
     * not isAvailable()-guarded. See the hard-delete section of the class header.
     */
    private static final String IR_LEAD_RECORD_TYPE = 'Investor_Onboarding';

    // Memoized describe results. A SEPARATE "resolved" flag because null is a LEGITIMATE answer
    // (record type absent, or not available to this user) rather than a cache miss — without it
    // every invocation in such an org would re-describe forever.
    private static Id tempAccountRecordTypeIdCache;
    private static Boolean tempAccountRecordTypeResolved = false;
    private static Id investorContactRecordTypeIdCache;
    private static Boolean investorContactRecordTypeResolved = false;
    private static Id irLeadRecordTypeIdCache;
    private static Boolean irLeadRecordTypeResolved = false;

    // ── Refusals (no database work attempted) ───────────────────────────────────────────────
    public static final String ERROR_NOT_PROCESSED = 'This Lead was not processed.';
    public static final String ERROR_MISSING_LEAD_ID =
        'No Lead Id was supplied to the Investor Converted action.';
    public static final String ERROR_NOT_A_LEAD_ID =
        'The Id supplied to the Investor Converted action is not a Lead Id: ';
    public static final String ERROR_LEAD_NOT_FOUND =
        'Lead not found, or not visible to you: ';
    public static final String ERROR_ALREADY_CONVERTED =
        'This Lead has already been converted: ';

    // ── Failures (database work attempted) ──────────────────────────────────────────────────
    public static final String ERROR_READ_DENIED =
        'Unable to read the Lead records. This is usually a missing permission. Details: ';
    public static final String ERROR_TEMP_ACCOUNT =
        'Could not create the temporary Account used for conversion. Details: ';
    public static final String ERROR_CONVERT = 'Lead conversion failed. Details: ';
    public static final String ERROR_UNEXPECTED =
        'The Investor Converted action failed unexpectedly. Details: ';

    // ── Warnings (the conversion outcome stands; cleanup left something behind) ─────────────
    //
    // 🔴 EVERY "NOT DELETED" WARNING BELOW DESCRIBES A LIVE CASCADE-DELETE HAZARD, NOT TIDINESS.
    // The temporary Account still has the investor Contact hanging off it. Deleting that Account by
    // hand — which is exactly what a cleanup sweep of "IR Conversion Temp Account" records does —
    // DESTROYS the Contact. This is the measured 2026-08-16 data loss (see the class header). The
    // remedy is always: blank the Contact's Account field FIRST, confirm it, then delete the Account.
    public static final String WARNING_DETACH =
        'WARNING: the investor Contact could not be detached from the temporary Account, so the '
        + 'temporary Account was deliberately NOT deleted - deleting it would cascade-delete the '
        + 'Contact. An administrator must clear the Contact\'s Account field first, confirm it is '
        + 'empty, and only then delete the Account. Details: ';

    /**
     * The save-result said the detach worked and the database says otherwise. Rare, and the single
     * most important message in this class: it is the case that silently destroyed Contacts while
     * the old code trusted isSuccess() and deleted the Account anyway.
     */
    public static final String WARNING_DETACH_UNCONFIRMED =
        'WARNING: the investor Contact still reports an Account after the detach was accepted, or '
        + 'could not be read back to confirm it. The temporary Account was deliberately NOT deleted, '
        + 'because deleting it would cascade-delete the Contact. An administrator must clear the '
        + 'Contact\'s Account field, confirm it is empty, and only then delete the Account.';

    /**
     * The Contact is detached and safe; only the cosmetic/enrichment write failed. Deliberately NOT
     * a failure and deliberately NOT a detach warning — nothing is at risk, the record type and the
     * carried IR fields are simply missing and can be set by hand.
     */
    public static final String WARNING_FIELD_CARRY =
        'WARNING: the investor Contact was created and detached successfully, but its Investor '
        + 'record type and/or the Is Accredited / Referred By values carried from the Lead could not '
        + 'be saved. The Contact is safe; these fields must be set manually. Details: ';

    public static final String WARNING_TEMP_ACCOUNT_DELETE =
        'WARNING: the temporary Account could not be deleted and must be removed manually. '
        + 'The investor Contact is safe and is no longer attached to it. Details: ';

    /**
     * The soft delete succeeded and only the Recycle Bin purge failed. The mildest outcome in this
     * class: the Account is already gone from every list view and report, and the only residue is a
     * restorable copy in the Recycle Bin that expires on its own after 15 days.
     */
    public static final String WARNING_TEMP_ACCOUNT_HARD_DELETE =
        'WARNING: the temporary Account was deleted but could not be purged from the Recycle Bin, '
        + 'so a restorable copy remains there for 15 days. The investor Contact is safe and is not '
        + 'attached to it. No action is required; an administrator may empty the Recycle Bin to '
        + 'remove it sooner. Details: ';

    /**
     * Converts each supplied Investor Relations Lead, letting the conversion CREATE the investor
     * Contact, then re-typing that Contact as `Investor`, detaching it, and deleting the temporary
     * Account. Leaves NO Opportunity and no temporary Account behind. See the class header.
     *
     * Bulk-safe and index-parallel: results[i] always describes requests[i], for every outcome
     * including refusals. Two SOQL and at most five DML statements of its own, plus one
     * Database.convertLead call, regardless of how many Leads are supplied — see the governor-shape
     * contract in the class header, which is the authoritative statement of this.
     *
     * This method does not throw. Every failure is reported on the corresponding Result so the
     * Screen Flow can branch on `success` and display `errorMessage`.
     *
     * @param requests One entry per Lead to convert. A null or empty list returns an empty list.
     * @return One Result per Request, in the same order (never null, never shorter than the input).
     * @example
     * InvestorLeadConvertService.Request req = new InvestorLeadConvertService.Request();
     * req.leadId = leadId;
     * List<InvestorLeadConvertService.Result> results =
     *     InvestorLeadConvertService.convertInvestorLeads(
     *         new List<InvestorLeadConvertService.Request>{ req });
     */
    @InvocableMethod(
        label='Convert Investor Lead'
        description='Converts an Investor Relations Lead. The conversion itself creates the investor Contact (record type Investor, no Account) and no Opportunity; the temporary Account used to make it legal is deleted.'
        category='Investor Relations'
    )
    public static List<Result> convertInvestorLeads(List<Request> requests) {
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }
        // Seed one Result per Request FIRST, so the list is index-parallel and fully populated no
        // matter where processing stops. No caller ever receives a null or a short list.
        for (Integer i = 0; i < requests.size(); i++) {
            Result seeded = new Result();
            seeded.success = false;
            seeded.errorMessage = ERROR_NOT_PROCESSED;
            results.add(seeded);
        }
        try {
            process(requests, results);
        } catch (Exception e) {
            // Backstop only. Every expected failure is handled in typed form inside process().
            markUnprocessed(results, ERROR_UNEXPECTED + e.getMessage());
        }
        return results;
    }

    // ─── Orchestration ───────────────────────────────────────────────────────────────────────

    /**
     * The seven-step sequence from the class header. Each phase narrows the working set: a Lead that
     * fails a phase has its Result written and drops out, and later phases never see it.
     */
    private static void process(List<Request> requests, List<Result> results) {
        Map<Id, Lead> leadsById;
        try {
            leadsById = new Map<Id, Lead>(
                InvestorLeadConvertSelector.selectByIds(collectLeadIds(requests))  // SOQL 1
            );
        } catch (System.QueryException e) {
            // USER_MODE throws rather than degrading, and on this user-initiated path that is the
            // intended behaviour. Nothing has been written yet, so there is no cleanup to perform.
            failAll(results, ERROR_READ_DENIED + e.getMessage());
            return;
        }

        // Step 0 — validate and refuse. Nothing is written in this phase.
        List<Work> works = validate(requests, results, leadsById);
        if (works.isEmpty()) {
            return;
        }

        // Step 1 — one bulk insert of the temporary Accounts.
        works = createTempAccounts(works, results);
        if (works.isEmpty()) {
            return;
        }

        // Every Work here owns a temp Account, so this map resolves any temp Account Id back to the
        // Result that should carry a cleanup warning about it.
        Map<Id, Work> workByTempAccountId = new Map<Id, Work>();
        for (Work work : works) {
            workByTempAccountId.put(work.tempAccountId, work);
        }

        // Steps 2 and 3 — the conversion, which CREATES the Contact. Never throws out of this call.
        // A Lead whose conversion failed has no Contact, so its temp Account is childless and is
        // handed straight to the delete set.
        Set<Id> deletableAccountIds = new Set<Id>();
        List<Work> converted = convertLeads(works, results, deletableAccountIds);

        // ══ Steps 4-7 — CLEANUP. RUNS ON THE SUCCESS PATH AND THE FAILURE PATH ALIKE. ══
        // 🔴 THE ORDER OF THESE FOUR STATEMENTS IS NOT NEGOTIABLE. The new Contact is currently a
        // CHILD of the temporary Account; deleting an Account cascades into its Contacts, so
        // deleting first would DELETE THE INVESTOR'S CONTACT.
        //
        // Detach alone (nothing else can fail it) -> PROVE it by re-query -> delete only what was
        // proven childless -> and only then the non-critical enrichment.
        //
        // ⚠ ENRICHMENT IS LAST ON PURPOSE. Nothing may sit between confirmDetachments and
        // deleteTempAccounts: a statement in that gap could throw and skip the delete, stranding a
        // temporary Account that still looks deletable to a human — which is the precise setup for
        // the measured data loss. Enrichment after the delete can fail freely; by then the Contact
        // is detached, the Account is gone, and there is nothing left to cascade into.
        detachContacts(converted, results);
        confirmDetachments(converted, results, deletableAccountIds);
        deleteTempAccounts(deletableAccountIds, workByTempAccountId, results);
        applyInvestorFields(converted, results);
    }

    // ─── Step 0: validate ────────────────────────────────────────────────────────────────────

    /** Lead-typed Ids from the incoming requests; anything else is refused later, by index. */
    private static Set<Id> collectLeadIds(List<Request> requests) {
        Set<Id> leadIds = new Set<Id>();
        for (Request request : requests) {
            if (request != null && isLeadId(request.leadId)) {
                leadIds.add(request.leadId);
            }
        }
        return leadIds;
    }

    /**
     * Writes a refusal onto every Result that cannot proceed and returns the Work items that can.
     * No database work happens in this phase, so a refusal here needs no cleanup.
     */
    private static List<Work> validate(
        List<Request> requests,
        List<Result> results,
        Map<Id, Lead> leadsById
    ) {
        List<Work> works = new List<Work>();

        for (Integer i = 0; i < requests.size(); i++) {
            Request request = requests[i];
            Id leadId = (request == null) ? null : request.leadId;

            if (leadId == null) {
                fail(results[i], ERROR_MISSING_LEAD_ID);
                continue;
            }
            if (!isLeadId(leadId)) {
                // Refused rather than queried: a foreign Id inside `WHERE Id IN :leadIds` raises a
                // QueryException that would take down the whole batch over one bad input.
                fail(results[i], ERROR_NOT_A_LEAD_ID + leadId);
                continue;
            }
            Lead lead = leadsById.get(leadId);
            if (lead == null) {
                fail(results[i], ERROR_LEAD_NOT_FOUND + leadId);
                continue;
            }
            if (lead.IsConverted == true) {
                fail(results[i], ERROR_ALREADY_CONVERTED + leadLabel(lead));
                continue;
            }

            Work work = new Work();
            work.index = i;
            work.leadId = leadId;
            // Captured HERE, from the Lead already in hand, because the Lead is the only place
            // these values exist and it is about to be converted. Step 4 writes them onto the
            // Contact the conversion creates; carrying them on Work is what keeps that a
            // field-list change rather than a second read.
            work.isAccredited = lead.Is_Accredited__c;
            work.referredById = lead.Referred_By__c;
            // Captured here for the SAME reason as the two fields above: the Lead is about to be
            // converted, and step 6 needs to know whether this one earns a hard delete. Reading it
            // later would cost a second query for a value already in hand.
            work.leadRecordTypeId = lead.RecordTypeId;
            works.add(work);
        }
        return works;
    }

    // ─── Step 1: temporary Accounts ──────────────────────────────────────────────────────────

    /**
     * A record type Id resolved by DEVELOPER NAME, or null when the record type is absent from this
     * org or is not available to the running user. A DESCRIBE, so it costs no SOQL.
     *
     * 🔴 NEVER A HARDCODED ID — resolved by DeveloperName so this repo deploys to any org.
     * ⚠ isAvailable()-guarded: stamping a record type the running user cannot use fails the DML
     * outright, so an unavailable record type must degrade to "leave it unset" rather than take the
     * whole conversion down.
     */
    private static Id recordTypeIdFor(Schema.SObjectType sobjectType, String developerName) {
        // DEFERRED: record-type info does not need the child-relationship graph, and loading it
        // eagerly is a measurable cost on standard objects.
        Schema.RecordTypeInfo info = sobjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
            .getRecordTypeInfosByDeveloperName()
            .get(developerName);
        return (info != null && info.isAvailable()) ? info.getRecordTypeId() : null;
    }

    /** Memoized Investing_Entity Account record type Id (null is a legitimate answer). */
    private static Id tempAccountRecordTypeId() {
        if (!tempAccountRecordTypeResolved) {
            tempAccountRecordTypeIdCache =
                recordTypeIdFor(Account.SObjectType, TEMP_ACCOUNT_RECORD_TYPE);
            tempAccountRecordTypeResolved = true;
        }
        return tempAccountRecordTypeIdCache;
    }

    /** Memoized Investor Contact record type Id (null is a legitimate answer). */
    private static Id investorContactRecordTypeId() {
        if (!investorContactRecordTypeResolved) {
            investorContactRecordTypeIdCache =
                recordTypeIdFor(Contact.SObjectType, INVESTOR_CONTACT_RECORD_TYPE);
            investorContactRecordTypeResolved = true;
        }
        return investorContactRecordTypeIdCache;
    }

    /**
     * The Id of the `Investor_Onboarding` Lead record type, or null when this org has no such record
     * type. Memoized, and a DESCRIBE, so it costs no SOQL and the class's SOQL contract is unchanged.
     *
     * 🔴 DELIBERATELY NOT isAvailable()-GUARDED, unlike recordTypeIdFor. That helper serves a WRITE,
     * where an unavailable record type fails the DML outright. This one serves a CLASSIFICATION of a
     * Lead that already carries the record type, and whether the RUNNING USER may use it says
     * nothing about what the Lead is. Folding isAvailable() in here would silently downgrade the
     * hard delete to a soft delete for exactly the personas least likely to notice. Same reasoning,
     * and the same shape, as LeadConvertService.irLeadRecordTypeId().
     *
     * ⚠ A separate `resolved` flag because null is a LEGITIMATE answer (an Acquisitions-only org),
     * not a cache miss — without it every invocation in such an org would re-describe forever.
     */
    private static Id irLeadRecordTypeId() {
        if (!irLeadRecordTypeResolved) {
            Schema.RecordTypeInfo info = Lead.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
                .getRecordTypeInfosByDeveloperName()
                .get(IR_LEAD_RECORD_TYPE);
            irLeadRecordTypeIdCache = (info == null) ? null : info.getRecordTypeId();
            irLeadRecordTypeResolved = true;
        }
        return irLeadRecordTypeIdCache;
    }

    /**
     * One bulk insert. Returns only the Work items that now own a temporary Account.
     *
     * The Account exists because Lead.Company is nillable here and Person Accounts are enabled: a
     * blank-Company Lead left to convert on its own would mint a PERSON Account. Naming and typing
     * the target Account removes that path entirely.
     */
    private static List<Work> createTempAccounts(List<Work> works, List<Result> results) {
        Id tempAccountRecordTypeId = tempAccountRecordTypeId();
        List<Account> tempAccounts = new List<Account>();
        for (Work work : works) {
            Account tempAccount = new Account(Name = TEMP_ACCOUNT_NAME_PREFIX + ' ' + work.leadId);
            if (tempAccountRecordTypeId != null) {
                tempAccount.RecordTypeId = tempAccountRecordTypeId;
            }
            tempAccounts.add(tempAccount);
        }
        List<Database.SaveResult> saveResults = Database.insert(tempAccounts, false);   // DML 1

        List<Work> live = new List<Work>();
        for (Integer i = 0; i < works.size(); i++) {
            Work work = works[i];
            if (saveResults[i].isSuccess()) {
                work.tempAccountId = saveResults[i].getId();
                results[work.index].accountId = work.tempAccountId;
                live.add(work);
            } else {
                fail(results[work.index], ERROR_TEMP_ACCOUNT + firstError(saveResults[i].getErrors()));
            }
        }
        return live;
    }

    // ─── Steps 2 and 3: convert, and read the Contact the conversion created ─────────────────

    /**
     * The conversion itself: a temporary Account, NO Opportunity, and — the point of the redesign —
     * NO setContactId, so the platform CREATES the Contact from the Lead's own name/email/phone.
     * Creating that Contact ourselves beforehand is what tripped the duplicate rule (class header).
     *
     * Deliberately swallows any exception from Database.convertLead and converts it into per-Lead
     * messages: a rethrow would leave every temporary Account in this batch orphaned, because the
     * caller's cleanup statements would never run.
     *
     * @return Only the Work items that converted and carry a Contact Id. A Lead that did NOT
     *         convert has no Contact, so its temporary Account is childless and is added to
     *         deletableAccountIds here rather than waiting for a detach with nothing to detach.
     */
    private static List<Work> convertLeads(
        List<Work> works,
        List<Result> results,
        Set<Id> deletableAccountIds
    ) {
        List<Work> converted = new List<Work>();
        if (works.isEmpty()) {
            return converted;
        }
        List<Database.LeadConvert> conversions = new List<Database.LeadConvert>();
        for (Work work : works) {
            Database.LeadConvert conversion = new Database.LeadConvert();
            conversion.setLeadId(work.leadId);
            // The Account is supplied; the CONTACT deliberately is not. setContactId is what would
            // reuse a pre-existing Contact, and creating one to reuse is exactly what the org's
            // duplicate rule refuses.
            conversion.setAccountId(work.tempAccountId);
            // 🔴 THE NO-OPPORTUNITY RULE, ENFORCED AT SOURCE. Nothing downstream has to find or
            // delete an Opportunity because none is ever created, which also keeps the whole
            // acquisitions deal-tree cascade out of this transaction.
            conversion.setDoNotCreateOpportunity(true);
            conversion.setConvertedStatus(CONVERTED_STATUS);
            conversions.add(conversion);
        }

        List<Database.LeadConvertResult> convertResults;
        try {
            convertResults = Database.convertLead(conversions, false);
        } catch (Exception e) {
            for (Work work : works) {
                fail(results[work.index], ERROR_CONVERT + e.getMessage());
                deletableAccountIds.add(work.tempAccountId);
            }
            return converted;
        }

        for (Integer i = 0; i < works.size(); i++) {
            Work work = works[i];
            Database.LeadConvertResult convertResult = convertResults[i];
            if (convertResult.isSuccess()) {
                work.contactId = convertResult.getContactId();
                results[work.index].success = true;
                results[work.index].errorMessage = null;
                results[work.index].contactId = work.contactId;
                results[work.index].accountId = convertResult.getAccountId();
                converted.add(work);
                // ⚠ convertResult.getOpportunityId() is deliberately NOT read. It is null by
                // construction (setDoNotCreateOpportunity), and reading it into state would invite
                // the next reader to re-add a delete step for a record that does not exist.
            } else {
                fail(results[work.index], ERROR_CONVERT + firstError(convertResult.getErrors()));
                deletableAccountIds.add(work.tempAccountId);
            }
        }
        return converted;
    }

    // ─── Step 4: detach, and ONLY detach (MUST run before step 6) ────────────────────────────

    /**
     * 🔴 STEP 4 OF 7 — THE SAFETY WRITE. This must complete, and be CONFIRMED by step 5, before
     * deleteTempAccounts runs. The Contact the conversion just created is a CHILD of the temporary
     * Account; deleting an Account cascades into its Contacts, so deleting before this detach would
     * DELETE THE INVESTOR'S CONTACT.
     *
     * 🔴 THIS STATEMENT WRITES ONE FIELD AND MUST CONTINUE TO WRITE ONE FIELD. Every additional
     * field on this update is another way for the detach to fail, and a failed detach strands a
     * temporary Account that a human will eventually delete by hand, cascading into the Contact.
     * The record type and the carried IR fields therefore live in applyInvestorFields (step 7),
     * which runs after the delete and cannot endanger anything.
     *
     * MEASURED (DPEG-IR-Implementation, savepoint-wrapped, 2026-08-16): with a bad Referred_By__c
     * value on the same statement, `Database.update` returned isSuccess() = false with
     * INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY and the Contact was left ATTACHED — a single
     * unrelated field value was enough to defeat the detach. That is the coupling this split removes.
     *
     * ⚠ AccountId = null is assigned via the SObject constructor, which DOES register an explicit
     * null for DML — VERIFIED, not assumed: getPopulatedFieldsAsMap() on the constructed Contact
     * returns {AccountId, Id, ...}, and a live probe confirmed the stored AccountId became null.
     *
     * A save-result is recorded on the Work but is NOT by itself permission to delete anything —
     * step 5 decides that from the database. `success` is left alone throughout: the conversion
     * genuinely happened, and reporting failure would send the user back to retry a Lead that is
     * already converted.
     */
    private static void detachContacts(List<Work> works, List<Result> results) {
        if (works.isEmpty()) {
            return;
        }
        List<Contact> detachments = new List<Contact>();
        for (Work work : works) {
            detachments.add(new Contact(Id = work.contactId, AccountId = null));
        }
        List<Database.SaveResult> saveResults = Database.update(detachments, false);   // DML 2

        for (Integer i = 0; i < works.size(); i++) {
            if (!saveResults[i].isSuccess()) {
                works[i].detachError = firstError(saveResults[i].getErrors());
            }
        }
    }

    // ─── Step 5: CONFIRM the detach from the database (the delete's only precondition) ───────

    /**
     * 🔴 STEP 5 OF 7 — THE GUARD THAT ACTUALLY PROTECTS THE CONTACT. A temporary Account Id enters
     * deletableAccountIds ONLY when a RE-QUERY shows its Contact's AccountId is genuinely null.
     *
     * 🔴 A Database.SaveResult IS NOT EVIDENCE AND MUST NEVER AGAIN BE TREATED AS EVIDENCE. It says
     * a statement was accepted, not that a field holds a value. The previous version of this class
     * deleted the temporary Account on the strength of isSuccess() alone; investor Contacts were
     * destroyed. Reading the stored value costs one SOQL for the entire batch and is the only
     * precondition strong enough to justify a cascading delete.
     *
     * FAILS CLOSED, ALWAYS. A Contact that does not come back from the re-query — deleted, invisible,
     * anything — is treated as still attached and its temporary Account is LEFT BEHIND. An orphan
     * Account is an inconvenience a human can resolve; a cascade-deleted investor Contact is data
     * loss that only the Recycle Bin can undo, and only for 15 days.
     *
     * ⚠ The re-query is WITH SYSTEM_MODE (see InvestorLeadConvertSelector.selectContactsByIds). If
     * it throws anyway, that exception propagates to the caller's backstop and NOTHING is deleted —
     * which is the safe direction, though it strands every temporary Account in the batch.
     */
    private static void confirmDetachments(
        List<Work> works,
        List<Result> results,
        Set<Id> deletableAccountIds
    ) {
        if (works.isEmpty()) {
            return;
        }
        Set<Id> contactIds = new Set<Id>();
        for (Work work : works) {
            contactIds.add(work.contactId);
        }
        Map<Id, Contact> storedById = new Map<Id, Contact>(
            InvestorLeadConvertSelector.selectContactsByIds(contactIds)                 // SOQL 2
        );

        for (Work work : works) {
            Contact stored = storedById.get(work.contactId);
            if (stored != null && stored.AccountId == null) {
                // PROVEN childless. This is the ONLY route into the delete set for a Lead that
                // actually converted.
                deletableAccountIds.add(work.tempAccountId);
                continue;
            }
            // Still attached, or unreadable. Strand the Account and say why, preferring the
            // platform's own error when the detach statement reported one.
            warn(
                results[work.index],
                work.detachError != null
                    ? WARNING_DETACH + work.detachError
                    : WARNING_DETACH_UNCONFIRMED
            );
        }
    }

    // ─── Step 6: delete the temporary Accounts ───────────────────────────────────────────────

    /**
     * 🔴 STEP 6 OF 7 — ONLY EVER CALLED AFTER detachContacts AND confirmDetachments. Every Id in
     * deletableAccountIds has been proven childless by one of exactly two routes:
     *   • its Lead never converted, so no Contact was ever created under it; or
     *   • a RE-QUERY of its Contact returned AccountId = null (confirmDetachments).
     *
     * That invariant is the entire safety of this method. Calling it with an unvetted Id set — for
     * example one populated from Database.SaveResult.isSuccess(), as this class once did — CASCADE-
     * DELETES INVESTOR CONTACTS. It has already done so in production; see the class header.
     *
     * A delete failure is a warning, never a failure of the conversion — the Contact is already
     * safe by this point, and the residue is one empty Account named after its Lead.
     *
     * ⚠ ALSO SELECTS WHAT GETS HARD-DELETED, and that selection is deliberately made HERE rather
     * than upstream in confirmDetachments. The delete set is a safety decision; the purge set is a
     * scoping decision, and folding the record-type test into the safety guard would entangle the
     * two — a future edit to the scoping rule could then change which Accounts are deleted at all.
     * An Account reaches hardDeleteTempAccounts only if its OWN DeleteResult succeeded, so the
     * purge can never run ahead of, or instead of, the delete it depends on.
     */
    private static void deleteTempAccounts(
        Set<Id> deletableAccountIds,
        Map<Id, Work> workByTempAccountId,
        List<Result> results
    ) {
        if (deletableAccountIds.isEmpty()) {
            return;
        }
        List<Id> accountIds = new List<Id>(deletableAccountIds);
        List<Account> doomedAccounts = new List<Account>();
        for (Id accountId : accountIds) {
            doomedAccounts.add(new Account(Id = accountId));
        }
        List<Database.DeleteResult> deleteResults = Database.delete(doomedAccounts, false);  // DML 3

        // Only Accounts whose OWN delete succeeded AND whose Lead carries the Investor_Onboarding
        // record type are eligible for the Recycle Bin purge. Both halves are required: purging an
        // Id whose delete failed is meaningless, and the record-type test is the scoping the feature
        // was asked for.
        Id irRecordTypeId = irLeadRecordTypeId();
        List<Account> hardDeletable = new List<Account>();
        List<Id> hardDeletableIds = new List<Id>();

        for (Integer i = 0; i < accountIds.size(); i++) {
            Work work = workByTempAccountId.get(accountIds[i]);
            if (!deleteResults[i].isSuccess()) {
                if (work != null) {
                    warn(
                        results[work.index],
                        WARNING_TEMP_ACCOUNT_DELETE + firstError(deleteResults[i].getErrors())
                    );
                }
                continue;
            }
            if (irRecordTypeId != null && work != null && work.leadRecordTypeId == irRecordTypeId) {
                hardDeletable.add(new Account(Id = accountIds[i]));
                hardDeletableIds.add(accountIds[i]);
            }
        }

        hardDeleteTempAccounts(hardDeletable, hardDeletableIds, workByTempAccountId, results);
    }

    /**
     * Empties the Recycle Bin of the temporary Accounts belonging to Investor_Onboarding Leads, so
     * the conversion leaves nothing restorable behind.
     *
     * 🔴 THIS METHOD ADDS NOTHING TO THE DELETE SET AND MUST NEVER BE GIVEN AN ID OF ITS OWN. Its
     * input is a strict subset of what deleteTempAccounts ALREADY successfully deleted, which is
     * itself the set confirmDetachments PROVED childless. Every safety property of steps 4-6 is
     * therefore inherited rather than re-argued: an Account that still has the investor's Contact
     * attached never reaches the soft delete, so it can never reach this method either.
     *
     * ⚠ NOT A FAILURE PATH. By the time this runs the Contact exists, is detached and confirmed, and
     * the Account is already soft-deleted. Anything that goes wrong here costs a Recycle Bin entry
     * that expires by itself in 15 days, so it reports WARNING_TEMP_ACCOUNT_HARD_DELETE and leaves
     * `success` alone — reporting failure would tell the user to retry an already-converted Lead.
     *
     * ⚠ TRY/CATCH IS LOAD-BEARING, NOT DEFENSIVE HABIT. Unlike Database.delete with allOrNone=false,
     * Database.emptyRecycleBin THROWS (EmptyRecycleBinException) rather than returning a per-row
     * failure for whole-call problems. An uncaught throw here would reach the caller's backstop and
     * overwrite every Result in the batch with ERROR_UNEXPECTED — turning a cosmetic residue into a
     * report that conversions failed, when in fact they all succeeded. It is caught here and
     * downgraded to the per-Lead warning it actually is.
     *
     * ⚠ DO NOT ASSERT `IsDeleted = false` ANYWHERE AGAINST THIS. A hard-deleted row remains readable
     * with IsDeleted = true under ALL ROWS until Salesforce's background purge; the property that
     * changed is that it is no longer in the Recycle Bin. The observable test is Database.undelete
     * failing with UNDELETE_FAILED — see the hard-delete section of the class header.
     */
    private static void hardDeleteTempAccounts(
        List<Account> hardDeletable,
        List<Id> hardDeletableIds,
        Map<Id, Work> workByTempAccountId,
        List<Result> results
    ) {
        if (hardDeletable.isEmpty()) {
            return;
        }
        List<Database.EmptyRecycleBinResult> purgeResults;
        try {
            purgeResults = Database.emptyRecycleBin(hardDeletable);                          // DML 4
        } catch (Exception e) {
            for (Id accountId : hardDeletableIds) {
                Work work = workByTempAccountId.get(accountId);
                if (work != null) {
                    warn(results[work.index], WARNING_TEMP_ACCOUNT_HARD_DELETE + e.getMessage());
                }
            }
            return;
        }

        for (Integer i = 0; i < hardDeletableIds.size(); i++) {
            if (purgeResults[i].isSuccess()) {
                continue;
            }
            Work work = workByTempAccountId.get(hardDeletableIds[i]);
            if (work != null) {
                warn(
                    results[work.index],
                    WARNING_TEMP_ACCOUNT_HARD_DELETE + firstError(purgeResults[i].getErrors())
                );
            }
        }
    }

    // ─── Step 7: record type and the carried IR fields (NON-critical, runs last) ─────────────

    /**
     * 🔴 STEP 7 OF 7 — THE ENRICHMENT WRITE, AND IT IS DELIBERATELY THE LEAST IMPORTANT STATEMENT
     * IN THIS CLASS. It stamps RecordTypeId = Contact `Investor` and carries the two IR fields off
     * the Lead: Is_Accredited__c (Checkbox -> Checkbox) and Referred_By__c (Lookup(Contact) ->
     * Lookup(Contact), so the Id is assigned straight across with no parsing and no name matching).
     *
     * 🔴 IT RUNS AFTER THE DELETE, AND MOVING IT EARLIER RE-CREATES THE BUG. These fields used to
     * ride on the detach statement, so any failure among them failed the detach too, stranded the
     * temporary Account, and set up the cascade delete that destroyed two investor Contacts. By
     * running here it cannot endanger anything: the Contact is already detached and confirmed, and
     * its temporary Account is already gone. A failure now costs two field values and a record type,
     * all of which an administrator can set by hand — which is why it reports WARNING_FIELD_CARRY
     * rather than WARNING_DETACH, and why it never touches `success`.
     *
     * Runs for EVERY converted Work, including ones whose detach failed: the Contact exists either
     * way and is no less entitled to its data. Values are assigned UNCONDITIONALLY, including null —
     * the Contact was created seconds ago by this same conversion, so there is no prior value to
     * preserve and copying the Lead's null is the correct answer rather than an omission. Contrast
     * RecordTypeId, which IS guarded: there, null means "record type absent or unavailable to this
     * user", a cache answer that must degrade to leaving the field alone rather than blanking it.
     *
     * ⚠ Standard fields (Name, Email, Phone) are NOT carried here and must never be. Database.
     * convertLead maps them itself — VERIFIED 2026-08-16 against a live conversion, where the Contact
     * was born already carrying the Lead's name, email address and phone number.
     *
     * ⚠ The `Investor` record type combined with a null AccountId is accepted by the
     * Record_Type_Matches_Account validation rule, which only fires when the Contact's Account HAS a
     * record type that is not Investing_Entity — verified against the live rule formula, whose first
     * clause is NOT(ISBLANK(AccountId)).
     */
    private static void applyInvestorFields(List<Work> works, List<Result> results) {
        if (works.isEmpty()) {
            return;
        }
        Id investorRecordTypeId = investorContactRecordTypeId();
        List<Contact> enrichments = new List<Contact>();
        for (Work work : works) {
            Contact enrichment = new Contact(
                Id = work.contactId,
                Is_Accredited__c = work.isAccredited,
                Referred_By__c = work.referredById
            );
            if (investorRecordTypeId != null) {
                enrichment.RecordTypeId = investorRecordTypeId;
            }
            enrichments.add(enrichment);
        }
        List<Database.SaveResult> saveResults = Database.update(enrichments, false);   // DML 4

        for (Integer i = 0; i < works.size(); i++) {
            if (!saveResults[i].isSuccess()) {
                warn(
                    results[works[i].index],
                    WARNING_FIELD_CARRY + firstError(saveResults[i].getErrors())
                );
            }
        }
    }

    // ─── Small helpers ───────────────────────────────────────────────────────────────────────

    /** True when the Id actually addresses a Lead — guards the selector's `Id IN` bind. */
    private static Boolean isLeadId(Id value) {
        return value != null && value.getSObjectType() == Lead.SObjectType;
    }

    /** Marks one Result as failed with a specific, user-actionable message. */
    private static void fail(Result result, String message) {
        result.success = false;
        result.errorMessage = message;
    }

    /**
     * Appends a cleanup warning WITHOUT changing `success`. A conversion that happened, happened;
     * downgrading it because the throwaway Account lingered would tell the user to retry a Lead
     * that is already converted.
     */
    private static void warn(Result result, String warning) {
        result.errorMessage = String.isBlank(result.errorMessage)
            ? warning
            : result.errorMessage + ' ' + warning;
    }

    /** Fails every Result with one message — used when the read phase itself is denied. */
    private static void failAll(List<Result> results, String message) {
        for (Result result : results) {
            fail(result, message);
        }
    }

    /** Replaces the seeded "not processed" message on anything the backstop catch interrupted. */
    private static void markUnprocessed(List<Result> results, String message) {
        for (Result result : results) {
            if (result.success != true && ERROR_NOT_PROCESSED.equals(result.errorMessage)) {
                result.errorMessage = message;
            }
        }
    }

    /** The first platform error as "STATUS_CODE: message", or a stable fallback. */
    private static String firstError(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'Unknown error.';
        }
        Database.Error error = errors[0];
        return String.valueOf(error.getStatusCode()) + ': ' + error.getMessage();
    }

    /** A human-readable identifier for a Lead, for refusal messages. */
    private static String leadLabel(Lead lead) {
        List<String> nameParts = new List<String>();
        if (String.isNotBlank(lead.FirstName)) {
            nameParts.add(lead.FirstName);
        }
        if (String.isNotBlank(lead.LastName)) {
            nameParts.add(lead.LastName);
        }
        String name = nameParts.isEmpty() ? String.valueOf(lead.Id) : String.join(nameParts, ' ');
        String status = String.isBlank(lead.Status) ? 'unknown' : lead.Status;
        return name + ' (Status: ' + status + ')';
    }

    // ─── Internal working state ──────────────────────────────────────────────────────────────

    /**
     * One in-flight conversion. Carries the input index so any phase can write its outcome back to
     * the correct Result without re-deriving position.
     *
     * ⚠ contactId is populated by the CONVERSION, not before it — there is no pre-existing Contact
     * in this design, so there is nothing to look up and no original AccountId to restore.
     */
    private class Work {
        private Integer index;
        private Id leadId;
        private Id tempAccountId;
        private Id contactId;

        // ⚠ Carried from the Lead at VALIDATE time — i.e. BEFORE the conversion — and written in
        // step 4. Reading them after conversion is not an option worth taking: it would need a
        // second query and would break the 1-SOQL contract for nothing, since the values are
        // already in hand.
        private Boolean isAccredited;   // Lead.Is_Accredited__c  -> Contact.Is_Accredited__c
        private Id referredById;        // Lead.Referred_By__c    -> Contact.Referred_By__c

        /**
         * The Lead's own record type. NOT carried onto anything — it is read once, in step 6, to
         * decide whether this Lead's temporary Account is hard-deleted or merely soft-deleted.
         * See the hard-delete section of the class header.
         */
        private Id leadRecordTypeId;

        /**
         * The platform error from the step-4 detach, or null when that statement was accepted.
         *
         * ⚠ IT IS A DIAGNOSTIC, NOT A DECISION. Nothing branches on this to decide whether a
         * temporary Account may be deleted — confirmDetachments decides that from a re-query of the
         * stored AccountId, and only from that. This field exists so the warning the user finally
         * reads can quote the platform's own message instead of a generic one, which is precisely
         * what was missing when this failure was first investigated.
         */
        private String detachError;
    }

    // ─── Flow contract ───────────────────────────────────────────────────────────────────────

    /** Input from the calling Screen Flow: the Lead to convert. */
    public class Request {
        @InvocableVariable(
            label='Lead Id'
            description='The Investor Relations Lead to convert. The conversion creates its Contact.'
            required=true
        )
        public Id leadId;
    }

    /**
     * Output to the calling Screen Flow, one per Request and in the same order. Branch on
     * `success`; display `errorMessage`.
     */
    public class Result {
        @InvocableVariable(
            label='Success'
            description='True when the Lead was converted and its investor Contact created.'
        )
        public Boolean success;

        @InvocableVariable(
            label='Error Message'
            description='Why the conversion was refused or failed. May also carry a cleanup warning on an otherwise successful conversion.'
        )
        public String errorMessage;

        @InvocableVariable(
            label='Contact Id'
            description='The investor Contact created by the conversion, re-typed as Investor and detached from any Account.'
        )
        public Id contactId;

        @InvocableVariable(
            label='Account Id'
            description='The TEMPORARY Account used to make the conversion legal. It is deleted before this action returns, so do not navigate to it.'
        )
        public Id accountId;
    }
}
