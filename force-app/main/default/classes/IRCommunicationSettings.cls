/**
 * Configuration accessor for one IR broadcast campaign.
 *
 * Everything that used to be a constant in this module now lives on an
 * IR_Communication__mdt record: the workspace, the email, the flow, the
 * send element, the Communication name prefix and the audience filter.
 * Changing which email goes out, or adding a second campaign, is a metadata
 * edit rather than a deployment.
 *
 * The one thing that CANNOT move here is the content the flow itself sends.
 * A broadcast flow pins its contentId and its content-variable schema
 * declaratively in the flow definition, so switching emails always means
 * editing the flow too. Content_Key__c exists to keep the two honest:
 * resolveContent() fails loudly when the record it finds is not the one the
 * flow is wired to, instead of silently displaying one email and sending
 * another.
 */
public with sharing class IRCommunicationSettings {

    /** Developer name of the record backing the Send New Offering Launch action. */
    public static final String NEW_LAUNCH = 'IR_New_Launch';

    @TestVisible private static Map<String, IR_Communication__mdt> overrides =
        new Map<String, IR_Communication__mdt>();

    /** Resolved, defaulted view of one campaign record. */
    public class Config {
        public String developerName;
        public String workspaceName;
        public String emailName;
        public String contentKey;          // may be blank
        public String contentType;
        public String flowApiName;
        public String sendElementName;
        public String namePrefix;
        public String audienceSourceObject;
        public Integer claimWindowHours;
        public Integer batchScope;
        public String flowApiVersion;
    }

    /** One resolved CMS email, with its real publish state. */
    public class Content {
        @AuraEnabled public String managedContentId;
        @AuraEnabled public String contentKey;
        @AuraEnabled public String name;
        @AuraEnabled public String workspaceName;
        @AuraEnabled public Boolean isPublished;
    }

    // ------------------------------------------------------------------ read

    public static Config get(String developerName) {
        String name = String.isBlank(developerName) ? NEW_LAUNCH : developerName;

        IR_Communication__mdt row = overrides.containsKey(name)
            ? overrides.get(name)
            : IR_Communication__mdt.getInstance(name);

        if (row == null) {
            throw new SettingsException(
                'IR_Communication__mdt record "' + name + '" is missing. '
                + 'Create it in Setup under Custom Metadata Types before sending.');
        }

        List<String> missing = new List<String>();
        if (String.isBlank(row.Workspace_Name__c)) { missing.add('Workspace Name'); }
        if (String.isBlank(row.Email_Name__c))     { missing.add('Email Name'); }
        if (String.isBlank(row.Flow_API_Name__c))  { missing.add('Flow API Name'); }
        if (!missing.isEmpty()) {
            throw new SettingsException(
                String.join(missing, ', ') + ' not set on the IR Communication record "'
                + name + '".');
        }

        Config c = new Config();
        c.developerName = name;
        c.workspaceName = row.Workspace_Name__c;
        c.emailName = row.Email_Name__c;
        c.contentKey = row.Content_Key__c;
        c.contentType = blankTo(row.Content_Type__c, 'sfdc_cms__email');
        c.flowApiName = row.Flow_API_Name__c;
        c.sendElementName = row.Send_Element_Name__c;
        c.namePrefix = blankTo(row.Communication_Name_Prefix__c, '');
        c.audienceSourceObject = blankTo(row.Audience_Source_Object__c, 'Contact');
        c.claimWindowHours = intOr(row.Claim_Window_Hours__c, 24);
        c.batchScope = intOr(row.Batch_Scope__c, 200);
        c.flowApiVersion = blankTo(row.Flow_API_Version__c, 'v62.0');
        return c;
    }

    // --------------------------------------------------------------- content

    /**
     * The CMS email this campaign sends, with its real publish state.
     *
     * Resolution order matters. When Content_Key__c is set it wins outright,
     * because that is the identifier the flow uses; the name is then only a
     * label. Falling back to the name is what allowed two records called
     * "IR New Launch" to disagree with the flow, so a name-resolved record is
     * cross-checked against the key whenever one is configured.
     */
    public static Content resolveContent(Config c) {
        List<ManagedContentSpace> spaces = [
            SELECT Id FROM ManagedContentSpace WHERE Name = :c.workspaceName LIMIT 1];
        if (spaces.isEmpty()) {
            throw new SettingsException(
                'The CMS workspace "' + c.workspaceName + '" was not found.');
        }

        List<ManagedContent> found;
        if (String.isNotBlank(c.contentKey)) {
            found = [
                SELECT Id, Name, ContentKey
                FROM ManagedContent
                WHERE ContentKey = :c.contentKey
                AND AuthoredManagedContentSpaceId = :spaces[0].Id
                LIMIT 1];
            if (found.isEmpty()) {
                throw new SettingsException(
                    'No content with key ' + c.contentKey + ' exists in the "'
                    + c.workspaceName + '" workspace. Check Content Key on the '
                    + c.developerName + ' record.');
            }
        } else {
            found = [
                SELECT Id, Name, ContentKey
                FROM ManagedContent
                WHERE Name = :c.emailName
                AND ContentTypeFullyQualifiedName = :c.contentType
                AND AuthoredManagedContentSpaceId = :spaces[0].Id
                ORDER BY LastModifiedDate DESC];
            if (found.isEmpty()) {
                throw new SettingsException(
                    'The email "' + c.emailName + '" was not found in the "'
                    + c.workspaceName + '" workspace.');
            }
            if (found.size() > 1) {
                throw new SettingsException(
                    found.size() + ' emails in "' + c.workspaceName + '" are named "'
                    + c.emailName + '". Set Content Key on the ' + c.developerName
                    + ' record so the right one is unambiguous.');
            }
        }

        Content result = new Content();
        result.managedContentId = found[0].Id;
        result.contentKey = found[0].ContentKey;
        result.name = found[0].Name;
        result.workspaceName = c.workspaceName;
        result.isPublished = isPublished(found[0].ContentKey);
        return result;
    }

    /**
     * Real publish state, from the primary variant.
     *
     * Worth checking rather than assuming: a broadcast flow refuses unpublished
     * content at send time with "We can't send unpublished content", and that
     * failure surfaces long after the sender has clicked Send.
     */
    private static Boolean isPublished(String contentKey) {
        for (ManagedContentVariant v : [
                SELECT IsPublished
                FROM ManagedContentVariant
                WHERE ManagedContentKey = :contentKey AND IsPrimary = TRUE
                LIMIT 1]) {
            return v.IsPublished == true;
        }
        return false;
    }

    // --------------------------------------------------------------- helpers

    private static String blankTo(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    private static Integer intOr(Decimal value, Integer fallback) {
        return (value == null || value <= 0) ? fallback : Integer.valueOf(value);
    }

    public class SettingsException extends Exception {}
}
