/**
 * Shared DTOs for the investment email send tracking module.
 *
 * EngagementRow is the DMO-decoupled shape of one ssot__EmailEngagement__dlm
 * event. All tracking logic works on these rows, never on DMO SObjects, so
 * tests can fabricate engagement without Data Cloud and the gateway can later
 * switch from direct SOQL to the Data Cloud Query API without touching logic.
 */
public with sharing class InvestmentEmailModels {

    /** ssot__EngagementChannelActionId__c values this module cares about. */
    public static final String ACTION_SEND_STATUS = 'SEND_STATUS';
    public static final String ACTION_OPEN = 'OPEN';
    public static final String ACTION_CLICK = 'CLICK';

    public class EngagementRow {
        /** ssot__FlowElementRunId__c: "<GUID>#<SendElementName>". */
        public String flowRunId;
        /** ssot__IndividualId__c: the CRM Contact Id (identity resolution keys on it). */
        public Id contactId;
        /** ssot__EngagementChannelActionId__c. */
        public String action;
        /** ssot__EngagementDateTm__c. */
        public Datetime engagedAt;
        /** ssot__EmailRecipientSendStatus__c (populated on SEND_STATUS rows). */
        public String sendStatus;
        /** ssot__LinkURL__c (populated on CLICK rows). */
        public String linkUrl;
        /** ssot__EmailBounceType__c — non-null means the message bounced. */
        public String bounceType;
        /** ssot__BounceReasonText__c. */
        public String bounceReason;
        /** ssot__BulkEmailMessageId__c: the ListEmail id of the sent email. */
        public String bulkEmailMessageId;
    }
}
