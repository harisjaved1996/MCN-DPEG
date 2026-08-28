/**
 * Configuration accessor for the Direct Email Send integration.
 *
 * Values live in the protected Marketing_Send_Setting__mdt "Default" record so
 * endpoints, the CMS workspace and the chunk size can change without a deploy.
 * Tests inject an override instead of relying on org data.
 */
public with sharing class MarketingSendSettings {

    @TestVisible private static Marketing_Send_Setting__mdt override_x;

    public static Marketing_Send_Setting__mdt get() {
        if (override_x != null) {
            return override_x;
        }
        Marketing_Send_Setting__mdt s = Marketing_Send_Setting__mdt.getInstance('Default');
        if (s == null) {
            throw new SettingsException(
                'Marketing_Send_Setting__mdt "Default" is missing. Create it in Setup before sending.');
        }
        return s;
    }

    public static String tokenEndpoint()  { return get().Token_Endpoint__c; }
    public static String consumerKey()    { return get().Consumer_Key__c; }
    public static String consumerSecret() { return get().Consumer_Secret__c; }
    public static String apiBaseUrl()     { return get().Api_Base_Url__c; }
    public static String workspaceId()    { return get().Workspace_Id__c; }
    public static String workspaceName()  { return get().Workspace_Name__c; }
    public static String fromAddress()    { return get().From_Address__c; }

    /** Recipients per bulk call. 5000 is the measured ceiling; 10000 returns 503. */
    public static Integer chunkSize() {
        Decimal c = get().Chunk_Size__c;
        return (c == null || c <= 0) ? 2000 : Integer.valueOf(c);
    }

    public class SettingsException extends Exception {}
}
