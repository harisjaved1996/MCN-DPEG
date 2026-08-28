/**
 * Reads the send audience entirely from Data Cloud. Nothing here touches
 * Contact or Lead in Sales Cloud.
 *
 * Three DMOs are involved:
 *
 *   ssot__Individual__dlm                        the person
 *     ssot__Id__c            join key, also the value sent as individualId
 *     ssot__PersonName__c    display name
 *
 *   ssot__ContactPointEmail__dlm                 the address
 *     ssot__Id__c            same join key
 *     ssot__EmailAddress__c  drives BOTH delivery and the consent decision
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
 *     2000, hence MAX_BROWSE_OFFSET below. Sending is unaffected because the
 *     batch streams a QueryLocator rather than paging.
 */
public with sharing class AudienceService {

    /** SOQL will not accept an OFFSET beyond this. Browsing past it needs a search. */
    public static final Integer MAX_BROWSE_OFFSET = 2000;

    /**
     * The Individual DMO holds every ingested person, which in this org is 531
     * rows: 150 from the Contact_Home stream and 381 from Leads. Campaigns
     * target Contacts only, so every query here is restricted by the source
     * object rather than by inferring intent from the record Id prefix.
     */
    private static final String SOURCE_OBJECT = 'Contact';
    private static final String SOURCE_FILTER = 'ssot__DataSourceObjectId__c = \'' + SOURCE_OBJECT + '\'';

    public static final String CONSENT_OPT_IN = 'OPT_IN';
    public static final String CONSENT_OPT_OUT = 'OPT_OUT';
    public static final String CONSENT_NONE = 'NONE';

    /** One selectable row in the wizard. */
    public class AudienceMember {
        @AuraEnabled public String individualId;
        @AuraEnabled public String name;
        @AuraEnabled public String email;
        @AuraEnabled public String consentStatus;   // OPT_IN | OPT_OUT | NONE
        @AuraEnabled public Boolean sendable;       // only OPT_IN can actually be delivered
    }

    /** A page of members plus the counters the wizard header needs. */
    public class AudiencePage {
        @AuraEnabled public List<AudienceMember> members = new List<AudienceMember>();
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Integer pageNumber = 1;
        @AuraEnabled public Integer pageSize = 25;
        @AuraEnabled public Boolean hasMore = false;
        @AuraEnabled public Boolean browseLimitReached = false;
    }

    /** Org-wide consent counters, used for the pre-send warning banner. */
    public class ConsentSummary {
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Integer optedIn = 0;
        @AuraEnabled public Integer blocked = 0;   // OPT_OUT plus no record at all
    }

    // --------------------------------------------------------------- reading

    /**
     * One page of the audience, name-sorted, with email and consent resolved.
     *
     * @param searchTerm matched against person name and email address
     * @param pageNumber 1-based
     */
    public static AudiencePage getPage(String searchTerm, Integer pageNumber, Integer pageSize) {
        AudiencePage page = new AudiencePage();
        page.pageNumber = (pageNumber == null || pageNumber < 1) ? 1 : pageNumber;
        page.pageSize = (pageSize == null || pageSize < 1) ? 25 : pageSize;

        Integer offset = (page.pageNumber - 1) * page.pageSize;
        if (offset > MAX_BROWSE_OFFSET) {
            page.browseLimitReached = true;
            return page;
        }

        String term = normaliseTerm(searchTerm);
        Set<String> idsMatchingEmail = String.isBlank(term)
            ? new Set<String>()
            : individualIdsByEmailLike(term);

        List<ssot__Individual__dlm> rows = queryIndividuals(term, idsMatchingEmail, page.pageSize + 1, offset);

        page.hasMore = rows.size() > page.pageSize;
        if (page.hasMore) {
            rows.remove(rows.size() - 1);
        }
        page.totalCount = countAudience(searchTerm);

        Set<String> ids = new Set<String>();
        for (ssot__Individual__dlm i : rows) {
            ids.add(i.ssot__Id__c);
        }
        Map<String, String> emailById = emailsByIndividualId(ids);
        Map<String, String> consentByEmail = consentByEmail(new Set<String>(emailById.values()));

        for (ssot__Individual__dlm i : rows) {
            String email = emailById.get(i.ssot__Id__c);
            AudienceMember m = new AudienceMember();
            m.individualId = i.ssot__Id__c;
            m.name = String.isBlank(i.ssot__PersonName__c) ? i.ssot__Id__c : i.ssot__PersonName__c;
            m.email = email;
            m.consentStatus = resolveConsent(email, consentByEmail);
            m.sendable = (m.consentStatus == CONSENT_OPT_IN);
            page.members.add(m);
        }
        return page;
    }

    /** Total individuals matching the search, unaffected by the OFFSET ceiling. */
    public static Integer countAudience(String searchTerm) {
        String term = normaliseTerm(searchTerm);
        if (String.isBlank(term)) {
            return Database.countQuery(
                'SELECT COUNT() FROM ssot__Individual__dlm WHERE ' + SOURCE_FILTER);
        }
        Set<String> idsMatchingEmail = individualIdsByEmailLike(term);
        String soql = 'SELECT COUNT() FROM ssot__Individual__dlm WHERE ' + SOURCE_FILTER
            + ' AND ' + nameOrEmailPredicate(idsMatchingEmail);
        return Database.countQueryWithBinds(soql, bindsFor(term, idsMatchingEmail), AccessLevel.SYSTEM_MODE);
    }

    /**
     * Consent counts across the whole audience. Deliberately capped: this is a
     * banner, not a report, and the consent DMO is normally far smaller than
     * the individual DMO.
     */
    public static ConsentSummary summariseConsent() {
        ConsentSummary s = new ConsentSummary();
        s.total = countAudience(null);

        Set<String> optedInEmails = new Set<String>();
        for (ssot__CommunicationSubscriptionConsent__dlm c : [
                SELECT ssot__ContactPointValueText__c, ssot__ConsentStatus__c
                FROM ssot__CommunicationSubscriptionConsent__dlm
                WHERE ssot__ConsentStatus__c = :CONSENT_OPT_IN
                LIMIT 50000]) {
            if (String.isNotBlank(c.ssot__ContactPointValueText__c)) {
                optedInEmails.add(c.ssot__ContactPointValueText__c.toLowerCase());
            }
        }
        s.optedIn = optedInEmails.isEmpty()
            ? 0
            : Database.countQuery(
                'SELECT COUNT() FROM ssot__ContactPointEmail__dlm'
                + ' WHERE ssot__EmailAddress__c IN :optedInEmails'
                + ' AND ' + SOURCE_FILTER);
        s.blocked = Math.max(0, s.total - s.optedIn);
        return s;
    }

    // ---------------------------------------------------------------- lookups

    /** Address per individual. Join is on ssot__Id__c, never on PartyId, which is null for leads. */
    public static Map<String, String> emailsByIndividualId(Set<String> individualIds) {
        Map<String, String> byId = new Map<String, String>();
        if (individualIds == null || individualIds.isEmpty()) {
            return byId;
        }
        for (ssot__ContactPointEmail__dlm cpe : [
                SELECT ssot__Id__c, ssot__EmailAddress__c
                FROM ssot__ContactPointEmail__dlm
                WHERE ssot__Id__c IN :individualIds
                AND ssot__EmailAddress__c != null
                AND ssot__DataSourceObjectId__c = :SOURCE_OBJECT]) {
            // First address wins when an individual has several contact points.
            if (!byId.containsKey(cpe.ssot__Id__c)) {
                byId.put(cpe.ssot__Id__c, cpe.ssot__EmailAddress__c);
            }
        }
        return byId;
    }

    /** Consent keyed by lower-cased address. Consent belongs to the address, not the person. */
    public static Map<String, String> consentByEmail(Set<String> emails) {
        Map<String, String> byEmail = new Map<String, String>();
        if (emails == null || emails.isEmpty()) {
            return byEmail;
        }
        Set<String> clean = new Set<String>();
        for (String e : emails) {
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
                byEmail.put(c.ssot__ContactPointValueText__c.toLowerCase(), c.ssot__ConsentStatus__c);
            }
        }
        return byEmail;
    }

    public static String resolveConsent(String email, Map<String, String> consentByEmail) {
        if (String.isBlank(email)) {
            return CONSENT_NONE;
        }
        String status = consentByEmail.get(email.toLowerCase());
        return String.isBlank(status) ? CONSENT_NONE : status;
    }

    /**
     * The audience the send batch iterates.
     *
     * Returned as a list rather than a QueryLocator: Batch Apex rejects a
     * QueryLocator over a Data Cloud DMO at runtime with "Batch Apex
     * QueryLocator doesn't support ssot__Individual__dlm", even though
     * Database.getQueryLocator will happily construct one. An Iterable batch
     * sidesteps that entirely.
     *
     * The trade-off is that the whole audience is materialised in start(),
     * so this is bounded by the 50,000 SOQL row limit rather than being a
     * true stream. That is well clear of the 20k this is designed for; beyond
     * 50k the audience would need snapshotting into a custom object first.
     * No OFFSET is involved, so the 2000-row browse ceiling does not apply.
     */
    public static List<ssot__Individual__dlm> audienceList() {
        return [
            SELECT ssot__Id__c, ssot__PersonName__c
            FROM ssot__Individual__dlm
            WHERE ssot__DataSourceObjectId__c = :SOURCE_OBJECT
            ORDER BY ssot__Id__c
            LIMIT 50000
        ];
    }

    // ----------------------------------------------------------------- helpers

    private static List<ssot__Individual__dlm> queryIndividuals(
            String term, Set<String> idsMatchingEmail, Integer lim, Integer offset) {

        String soql = 'SELECT ssot__Id__c, ssot__PersonName__c FROM ssot__Individual__dlm WHERE '
            + SOURCE_FILTER
            + (String.isBlank(term) ? '' : ' AND ' + nameOrEmailPredicate(idsMatchingEmail))
            + ' ORDER BY ssot__PersonName__c NULLS LAST, ssot__Id__c'
            + ' LIMIT ' + lim
            + (offset > 0 ? ' OFFSET ' + offset : '');
        return (List<ssot__Individual__dlm>) Database.queryWithBinds(
            soql, bindsFor(term, idsMatchingEmail), AccessLevel.SYSTEM_MODE);
    }

    /**
     * Name match OR email match. The email side arrives pre-resolved as a set of
     * individual ids because DMOs reject semi-joins.
     */
    private static String nameOrEmailPredicate(Set<String> idsMatchingEmail) {
        String predicate = '(ssot__PersonName__c LIKE :likeTerm'
            + ' OR ssot__FirstName__c LIKE :likeTerm'
            + ' OR ssot__LastName__c LIKE :likeTerm';
        if (!idsMatchingEmail.isEmpty()) {
            predicate += ' OR ssot__Id__c IN :idsMatchingEmail';
        }
        return predicate + ')';
    }

    /** Bind map for the dynamic predicates above. Keys must match the :names used there. */
    private static Map<String, Object> bindsFor(String term, Set<String> idsMatchingEmail) {
        return new Map<String, Object>{
            'likeTerm' => '%' + term + '%',
            'idsMatchingEmail' => idsMatchingEmail
        };
    }

    private static Set<String> individualIdsByEmailLike(String term) {
        Set<String> ids = new Set<String>();
        String likeTerm = '%' + term + '%';
        for (ssot__ContactPointEmail__dlm cpe : [
                SELECT ssot__Id__c
                FROM ssot__ContactPointEmail__dlm
                WHERE ssot__EmailAddress__c LIKE :likeTerm
                AND ssot__DataSourceObjectId__c = :SOURCE_OBJECT
                LIMIT 2000]) {
            ids.add(cpe.ssot__Id__c);
        }
        return ids;
    }

    private static String normaliseTerm(String searchTerm) {
        if (String.isBlank(searchTerm)) {
            return null;
        }
        return String.escapeSingleQuotes(searchTerm.trim());
    }
}
