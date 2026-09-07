/**
 * Data Cloud reads for the IR broadcast wizard.
 *
 * Deliberately standalone: this module shares no Apex with the Send Campaign
 * Email path, so changes on either side cannot break the other. The only
 * things it has in common with the rest of the org are the Communication__c
 * and Communication_Recipient__c objects.
 *
 * The audience filter is not hardcoded. Every entry point takes the
 * ssot__DataSourceObjectId__c value to filter on, which comes from
 * Audience_Source_Object__c on the campaign's IR_Communication__mdt record, so
 * pointing a campaign at a different Data Cloud source is a metadata edit.
 *
 * Three DMOs are involved:
 *
 *   ssot__Individual__dlm                        the person
 *     ssot__Id__c            join key; for Contact-sourced rows this IS the
 *                            18-character Contact Id
 *     ssot__PersonName__c    display name
 *
 *   ssot__ContactPointEmail__dlm                 the address
 *     ssot__Id__c            same join key (NOT PartyId, which is null here)
 *     ssot__EmailAddress__c  the address itself
 *
 *   ssot__CommunicationSubscriptionConsent__dlm  the permission
 *     ssot__ContactPointValueText__c  the address
 *     ssot__ConsentStatus__c          OPT_IN / OPT_OUT
 *
 * Two DMO limitations shape this class:
 *
 *  1. Semi-joins are rejected ("semi join sub selects can only query id
 *     fields"), so every join is done in Apex over an IN filter.
 *  2. Range operators are unsupported on DMO fields, so keyset pagination is
 *     impossible and browsing falls back to LIMIT/OFFSET. SOQL caps OFFSET at
 *     2000, hence MAX_BROWSE_OFFSET. Sending is unaffected: the roster batch
 *     materialises the whole audience instead of paging it.
 */
public with sharing class NewOfferingLaunchAudience {

    /** SOQL will not accept an OFFSET beyond this. Browsing past it needs a search. */
    public static final Integer MAX_BROWSE_OFFSET = 2000;

    public static final String CONSENT_OPT_IN = 'OPT_IN';
    public static final String CONSENT_NONE = 'NONE';

    /** One selectable row in step 2. */
    public class Member {
        @AuraEnabled public String individualId;
        @AuraEnabled public String name;
        @AuraEnabled public String email;
        @AuraEnabled public String consentStatus;   // OPT_IN | OPT_OUT | NONE
        @AuraEnabled public Boolean sendable;       // only OPT_IN can be delivered
    }

    /** A page of members plus what the wizard header needs. */
    public class AudiencePage {
        @AuraEnabled public List<Member> members = new List<Member>();
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Integer pageNumber = 1;
        @AuraEnabled public Integer pageSize = 25;
        @AuraEnabled public Boolean hasMore = false;
        @AuraEnabled public Boolean browseLimitReached = false;
    }

    // --------------------------------------------------------------- reading

    /**
     * One page of the audience, name-sorted, with email and consent resolved.
     *
     * @param searchTerm   matched against person name and email address
     * @param pageNumber   1-based
     * @param sourceObject ssot__DataSourceObjectId__c value to filter on
     */
    public static AudiencePage getPage(
            String searchTerm, Integer pageNumber, Integer pageSize, String sourceObject) {

        AudiencePage page = new AudiencePage();
        page.pageNumber = (pageNumber == null || pageNumber < 1) ? 1 : pageNumber;
        page.pageSize = (pageSize == null || pageSize < 1) ? 25 : pageSize;

        Integer offset = (page.pageNumber - 1) * page.pageSize;
        if (offset > MAX_BROWSE_OFFSET) {
            page.browseLimitReached = true;
            return page;
        }

        String term = normalise(searchTerm);
        Set<String> idsMatchingEmail = String.isBlank(term)
            ? new Set<String>()
            : individualIdsByEmailLike(term, sourceObject);

        List<ssot__Individual__dlm> rows =
            queryIndividuals(term, idsMatchingEmail, page.pageSize + 1, offset, sourceObject);

        page.hasMore = rows.size() > page.pageSize;
        if (page.hasMore) {
            rows.remove(rows.size() - 1);
        }
        page.totalCount = countAudience(searchTerm, sourceObject);

        Set<String> ids = new Set<String>();
        for (ssot__Individual__dlm i : rows) {
            ids.add(i.ssot__Id__c);
        }
        Map<String, String> emailById = emailsByIndividualId(ids, sourceObject);
        Map<String, String> consent = consentByEmail(new Set<String>(emailById.values()));

        for (ssot__Individual__dlm i : rows) {
            String email = emailById.get(i.ssot__Id__c);
            Member m = new Member();
            m.individualId = i.ssot__Id__c;
            m.name = String.isBlank(i.ssot__PersonName__c) ? i.ssot__Id__c : i.ssot__PersonName__c;
            m.email = email;
            m.consentStatus = resolveConsent(email, consent);
            m.sendable = (m.consentStatus == CONSENT_OPT_IN);
            page.members.add(m);
        }
        return page;
    }

    /** Total individuals matching the search, unaffected by the OFFSET ceiling. */
    public static Integer countAudience(String searchTerm, String sourceObject) {
        String term = normalise(searchTerm);
        if (String.isBlank(term)) {
            return Database.countQuery(
                'SELECT COUNT() FROM ssot__Individual__dlm WHERE ' + sourceFilter(sourceObject));
        }
        Set<String> idsMatchingEmail = individualIdsByEmailLike(term, sourceObject);
        String soql = 'SELECT COUNT() FROM ssot__Individual__dlm WHERE '
            + sourceFilter(sourceObject) + ' AND ' + nameOrEmailPredicate(idsMatchingEmail);
        return Database.countQueryWithBinds(
            soql, bindsFor(term, idsMatchingEmail), AccessLevel.SYSTEM_MODE);
    }

    /**
     * The whole audience, for the roster batch.
     *
     * Returned as a list rather than a QueryLocator: Batch Apex rejects a
     * QueryLocator over a Data Cloud DMO at runtime with "Batch Apex
     * QueryLocator doesn't support ssot__Individual__dlm", even though
     * Database.getQueryLocator constructs one happily.
     *
     * The trade-off is that the audience is materialised, so it is bounded by
     * the 50,000 SOQL row limit rather than being a true stream. That is well
     * clear of the volumes this is built for. No OFFSET is involved, so the
     * 2000-row browse ceiling does not apply here.
     */
    public static List<ssot__Individual__dlm> audienceList(String sourceObject) {
        String soql = 'SELECT ssot__Id__c, ssot__PersonName__c FROM ssot__Individual__dlm'
            + ' WHERE ' + sourceFilter(sourceObject) + ' LIMIT 50000';
        return Database.query(soql);
    }

    // --------------------------------------------------------------- lookups

    /** Address per individual. Joined on ssot__Id__c, never PartyId. */
    public static Map<String, String> emailsByIndividualId(
            Set<String> individualIds, String sourceObject) {

        Map<String, String> byId = new Map<String, String>();
        if (individualIds == null || individualIds.isEmpty()) {
            return byId;
        }
        String src = safe(sourceObject);
        for (ssot__ContactPointEmail__dlm cpe : [
                SELECT ssot__Id__c, ssot__EmailAddress__c
                FROM ssot__ContactPointEmail__dlm
                WHERE ssot__Id__c IN :individualIds
                AND ssot__EmailAddress__c != NULL
                AND ssot__DataSourceObjectId__c = :src]) {
            // First address wins when an individual has several contact points.
            if (!byId.containsKey(cpe.ssot__Id__c)) {
                byId.put(cpe.ssot__Id__c, cpe.ssot__EmailAddress__c);
            }
        }
        return byId;
    }

    /** Consent keyed by lower-cased address. Consent belongs to the address. */
    public static Map<String, String> consentByEmail(Set<String> emails) {
        Map<String, String> byEmail = new Map<String, String>();
        Set<String> clean = new Set<String>();
        for (String e : (emails == null ? new Set<String>() : emails)) {
            if (String.isNotBlank(e)) {
                clean.add(e);
            }
        }
        if (clean.isEmpty()) {
            return byEmail;
        }
        for (ssot__CommunicationSubscriptionConsent__dlm c : [
                SELECT ssot__ContactPointValueText__c, ssot__ConsentStatus__c
                FROM ssot__CommunicationSubscriptionConsent__dlm
                WHERE ssot__ContactPointValueText__c IN :clean]) {
            if (String.isNotBlank(c.ssot__ContactPointValueText__c)) {
                byEmail.put(
                    c.ssot__ContactPointValueText__c.toLowerCase(), c.ssot__ConsentStatus__c);
            }
        }
        return byEmail;
    }

    public static String resolveConsent(String email, Map<String, String> consent) {
        if (String.isBlank(email)) {
            return CONSENT_NONE;
        }
        String status = consent.get(email.toLowerCase());
        return String.isBlank(status) ? CONSENT_NONE : status;
    }

    // --------------------------------------------------------------- private

    private static List<ssot__Individual__dlm> queryIndividuals(
            String term, Set<String> idsMatchingEmail, Integer lim, Integer offset,
            String sourceObject) {

        String soql = 'SELECT ssot__Id__c, ssot__PersonName__c FROM ssot__Individual__dlm'
            + ' WHERE ' + sourceFilter(sourceObject);
        if (String.isNotBlank(term)) {
            soql += ' AND ' + nameOrEmailPredicate(idsMatchingEmail);
        }
        soql += ' ORDER BY ssot__PersonName__c NULLS LAST LIMIT :lim OFFSET :offset';

        Map<String, Object> binds = bindsFor(term, idsMatchingEmail);
        binds.put('lim', lim);
        binds.put('offset', offset);
        return Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE);
    }

    /** Individuals whose address matches, resolved separately because DMOs reject semi-joins. */
    private static Set<String> individualIdsByEmailLike(String term, String sourceObject) {
        Set<String> ids = new Set<String>();
        String likeTerm = '%' + term + '%';
        String src = safe(sourceObject);
        for (ssot__ContactPointEmail__dlm cpe : [
                SELECT ssot__Id__c
                FROM ssot__ContactPointEmail__dlm
                WHERE ssot__EmailAddress__c LIKE :likeTerm
                AND ssot__DataSourceObjectId__c = :src
                LIMIT 50000]) {
            ids.add(cpe.ssot__Id__c);
        }
        return ids;
    }

    private static String nameOrEmailPredicate(Set<String> idsMatchingEmail) {
        return idsMatchingEmail.isEmpty()
            ? '(ssot__PersonName__c LIKE :likeTerm)'
            : '(ssot__PersonName__c LIKE :likeTerm OR ssot__Id__c IN :emailIds)';
    }

    private static Map<String, Object> bindsFor(String term, Set<String> idsMatchingEmail) {
        return new Map<String, Object>{
            'likeTerm' => '%' + term + '%',
            'emailIds' => idsMatchingEmail
        };
    }

    /**
     * The source object is admin-supplied config rather than user input, but it
     * is still concatenated into dynamic SOQL, so it is escaped.
     */
    private static String sourceFilter(String sourceObject) {
        return 'ssot__DataSourceObjectId__c = \'' + safe(sourceObject) + '\'';
    }

    private static String safe(String sourceObject) {
        String value = String.isBlank(sourceObject) ? 'Contact' : sourceObject.trim();
        return String.escapeSingleQuotes(value);
    }

    private static String normalise(String searchTerm) {
        return String.isBlank(searchTerm) ? null : searchTerm.trim();
    }
}
