/**
 * Lists the published emails available to send, and guarantees each one has a
 * send definition behind it.
 *
 * Step 1 of the wizard shows Marketing CMS content, but the Direct Email Send
 * API does not accept content directly. It accepts a sendDefinitionId, which is
 * the Id of a ListEmail record pointing at that content. Publishing a new email
 * in the workspace therefore is not enough on its own, so ensureSendDefinition
 * creates the missing ListEmail on first use and a newly published email works
 * with no manual setup.
 */
public with sharing class MarketingContentService {

    /** Content type assigned to email content in Marketing CMS. */
    private static final String EMAIL_CONTENT_TYPE = 'sfdc_cms__email';

    /** How many of the newest published emails a name search scans. See searchPage. */
    private static final Integer SEARCH_SCAN_LIMIT = 2000;

    /** One selectable email in step 1. */
    public class EmailOption {
        @AuraEnabled public String managedContentId;
        @AuraEnabled public String contentKey;
        @AuraEnabled public String name;
        @AuraEnabled public String workspaceName;
        @AuraEnabled public String sendDefinitionId;   // null until first use
        @AuraEnabled public String subject;
        @AuraEnabled public Datetime lastModified;
        @AuraEnabled public Datetime createdDate;
    }

    /** One page of published emails plus the cursor needed to fetch the next. */
    public class EmailPage {
        @AuraEnabled public List<EmailOption> emails = new List<EmailOption>();
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Boolean hasMore = false;
        @AuraEnabled public String nextCursor;
    }

    /**
     * Published email content in the configured workspace, newest first.
     *
     * Paged with a keyset cursor on (CreatedDate, Id) rather than OFFSET, so
     * the workspace can hold any number of emails. OFFSET would cap the list at
     * 2000 and get slower with every page; a keyset stays constant-time and has
     * no ceiling. ManagedContent is a standard object, so unlike the Data Cloud
     * DMOs it supports the range operators this needs.
     *
     * Only content with a published variant is returned. Draft content renders
     * as an empty message body, so offering it would invite a broken send.
     */
    public static EmailPage listPublishedEmails(String searchTerm, String cursor, Integer pageSize) {
        Integer lim = (pageSize == null || pageSize < 1) ? 5 : pageSize;
        return String.isBlank(searchTerm)
            ? browsePage(cursor, lim)
            : searchPage(searchTerm.trim(), cursor, lim);
    }

    /**
     * Unbounded browse. Keyset cursor on (CreatedDate, Id), so page 400 costs
     * the same as page 1 and there is no OFFSET ceiling.
     */
    private static EmailPage browsePage(String cursor, Integer lim) {
        EmailPage page = new EmailPage();

        Map<String, Object> binds = new Map<String, Object>{
            'workspaceId' => MarketingSendSettings.workspaceId(),
            'contentType' => EMAIL_CONTENT_TYPE
        };
        String base = ' FROM ManagedContent'
            + ' WHERE AuthoredManagedContentSpaceId = :workspaceId'
            + ' AND ContentTypeFullyQualifiedName = :contentType'
            + ' AND Id IN (SELECT ManagedContentId FROM ManagedContentVariant WHERE IsPublished = true)';

        page.totalCount = Database.countQueryWithBinds(
            'SELECT COUNT()' + base, binds, AccessLevel.USER_MODE);

        String keyset = '';
        Datetime cursorCreated = decodeCursorCreated(cursor);
        Id cursorId = decodeCursorId(cursor);
        if (cursorCreated != null && cursorId != null) {
            keyset = ' AND (CreatedDate < :cursorCreated'
                + ' OR (CreatedDate = :cursorCreated AND Id < :cursorId))';
            binds.put('cursorCreated', cursorCreated);
            binds.put('cursorId', cursorId);
        }

        List<ManagedContent> rows = (List<ManagedContent>) Database.queryWithBinds(
            'SELECT Id, Name, ContentKey, CreatedDate, LastModifiedDate' + base + keyset
                + ' ORDER BY CreatedDate DESC, Id DESC LIMIT ' + (lim + 1),
            binds, AccessLevel.USER_MODE);

        page.hasMore = rows.size() > lim;
        if (page.hasMore) {
            rows.remove(rows.size() - 1);
        }
        if (!rows.isEmpty()) {
            page.emails = decorate(rows);
            ManagedContent last = rows[rows.size() - 1];
            page.nextCursor = last.CreatedDate.getTime() + '|' + last.Id;
        }
        return page;
    }

    /**
     * Name search, filtered in Apex.
     *
     * ManagedContent.Name cannot be filtered in SOQL even though describe
     * reports it as filterable: both "Name = 'CapitalCall'" and
     * "Name LIKE '%apital%'" return zero rows against content that plainly
     * exists. SOSL is unavailable too ("entity type ManagedContent does not
     * support search"). The only workable option is to read the newest
     * SEARCH_SCAN_LIMIT published emails and match names in Apex.
     *
     * Browsing therefore has no ceiling; search covers the newest 2000, which
     * is far beyond any realistic workspace.
     */
    private static EmailPage searchPage(String term, String cursor, Integer lim) {
        EmailPage page = new EmailPage();
        String needle = term.toLowerCase();

        List<ManagedContent> matches = new List<ManagedContent>();
        for (ManagedContent mc : [
                SELECT Id, Name, ContentKey, CreatedDate, LastModifiedDate
                FROM ManagedContent
                WHERE AuthoredManagedContentSpaceId = :MarketingSendSettings.workspaceId()
                AND ContentTypeFullyQualifiedName = :EMAIL_CONTENT_TYPE
                AND Id IN (SELECT ManagedContentId FROM ManagedContentVariant WHERE IsPublished = true)
                ORDER BY CreatedDate DESC, Id DESC
                LIMIT :SEARCH_SCAN_LIMIT]) {
            if (String.isNotBlank(mc.Name) && mc.Name.toLowerCase().contains(needle)) {
                matches.add(mc);
            }
        }

        page.totalCount = matches.size();

        // Cursor is a plain index into the filtered list.
        Integer start = decodeIndexCursor(cursor);
        if (start >= matches.size()) {
            return page;
        }
        Integer stop = Math.min(start + lim, matches.size());

        List<ManagedContent> slice = new List<ManagedContent>();
        for (Integer i = start; i < stop; i++) {
            slice.add(matches[i]);
        }
        page.emails = decorate(slice);
        page.hasMore = stop < matches.size();
        if (page.hasMore) {
            page.nextCursor = 'idx:' + stop;
        }
        return page;
    }

    private static List<EmailOption> decorate(List<ManagedContent> rows) {
        Set<Id> contentIds = new Set<Id>();
        for (ManagedContent mc : rows) {
            contentIds.add(mc.Id);
        }
        Map<Id, ListEmail> definitionByContent = existingDefinitions(contentIds);
        String workspaceName = MarketingSendSettings.workspaceName();

        List<EmailOption> options = new List<EmailOption>();
        for (ManagedContent mc : rows) {
            ListEmail def = definitionByContent.get(mc.Id);

            EmailOption o = new EmailOption();
            o.managedContentId = mc.Id;
            o.contentKey = mc.ContentKey;
            o.name = mc.Name;
            o.workspaceName = workspaceName;
            o.lastModified = mc.LastModifiedDate;
            o.createdDate = mc.CreatedDate;
            o.sendDefinitionId = (def == null) ? null : def.Id;
            o.subject = (def == null) ? null : def.Subject;
            options.add(o);
        }
        return options;
    }

    private static Integer decodeIndexCursor(String cursor) {
        if (String.isBlank(cursor) || !cursor.startsWith('idx:')) {
            return 0;
        }
        try {
            return Math.max(0, Integer.valueOf(cursor.substringAfter('idx:')));
        } catch (Exception e) {
            return 0;
        }
    }

    private static Datetime decodeCursorCreated(String cursor) {
        if (String.isBlank(cursor) || !cursor.contains('|')) {
            return null;
        }
        try {
            return Datetime.newInstance(Long.valueOf(cursor.substringBefore('|')));
        } catch (Exception e) {
            return null;   // a bad cursor simply starts from the top
        }
    }

    private static Id decodeCursorId(String cursor) {
        if (String.isBlank(cursor) || !cursor.contains('|')) {
            return null;
        }
        try {
            return (Id) cursor.substringAfter('|');
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * Returns a usable sendDefinitionId for the chosen content, creating the
     * ListEmail if none exists yet.
     *
     * Tracking flags are switched on deliberately: without them Marketing Cloud
     * Next emits no open or click engagement, and the metrics on Communication
     * would stay empty forever.
     */
    public static Id ensureSendDefinition(Id managedContentId, String contentName) {
        Map<Id, ListEmail> existing = existingDefinitions(new Set<Id>{ managedContentId });
        if (existing.containsKey(managedContentId)) {
            return existing.get(managedContentId).Id;
        }

        ListEmail def = new ListEmail(
            Name = buildDefinitionName(contentName),
            Subject = contentName,
            FromAddress = MarketingSendSettings.fromAddress(),
            ManagedContentId = managedContentId,
            MessagePurpose = 'Promotional',
            IsOpenTrackingEnabled = true,
            IsClickTrackingEnabled = true
        );
        insert def;
        return def.Id;
    }

    /** Preview the rendered email without sending anything. */
    public static Map<String, Object> preview(Id sendDefinitionId, String individualId) {
        return DirectEmailSendService.preview(sendDefinitionId, individualId);
    }

    // ---------------------------------------------------------------- helpers

    private static Map<Id, ListEmail> existingDefinitions(Set<Id> contentIds) {
        Map<Id, ListEmail> byContent = new Map<Id, ListEmail>();
        for (ListEmail le : [
                SELECT Id, Name, Subject, ManagedContentId
                FROM ListEmail
                WHERE ManagedContentId IN :contentIds
                ORDER BY CreatedDate DESC]) {
            // Several definitions can point at the same content; the newest wins.
            if (!byContent.containsKey(le.ManagedContentId)) {
                byContent.put(le.ManagedContentId, le);
            }
        }
        return byContent;
    }

    private static String buildDefinitionName(String contentName) {
        String base = String.isBlank(contentName) ? 'Offering Email' : contentName;
        String suffix = ' Send Definition';
        Integer maxBase = 80 - suffix.length();
        if (base.length() > maxBase) {
            base = base.substring(0, maxBase);
        }
        return base + suffix;
    }

}
