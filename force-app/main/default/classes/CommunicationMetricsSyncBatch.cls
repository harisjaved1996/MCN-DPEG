/**
 * Pulls Data Cloud engagement onto recipient rows, then rolls the totals up.
 *
 * Batched over Communication_Recipient__c rather than run inline because a
 * 20,000-recipient send is 20,000 rows to reconcile, which no single
 * transaction can query, update and aggregate.
 *
 * Two modes:
 *   new CommunicationMetricsSyncBatch(id)   one Communication, on demand
 *   new CommunicationMetricsSyncBatch()     every recent send, from the scheduler
 */
public with sharing class CommunicationMetricsSyncBatch
        implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    // AllowsCallouts is required even though nothing here calls out explicitly:
    // SOQL against a Data Cloud DMO is executed as a callout under the covers,
    // so without it the first engagement query dies with "Too many callouts: 1".

    /** How long after a send we keep looking for late engagement. */
    private static final Integer TRACKING_WINDOW_DAYS = 30;

    private final Id targetCommunicationId;
    private final Set<Id> affectedCommunicationIds = new Set<Id>();

    public CommunicationMetricsSyncBatch() {
        this(null);
    }

    public CommunicationMetricsSyncBatch(Id targetCommunicationId) {
        this.targetCommunicationId = targetCommunicationId;
    }

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        Datetime cutoff = System.now().addDays(-TRACKING_WINDOW_DAYS);
        Id target = targetCommunicationId;

        if (target != null) {
            return Database.getQueryLocator([
                SELECT Id, Communication__c, Message_Id__c, Send_Status__c, Engagement_Status__c,
                       Sent_At__c, Opened_At__c, Open_Count__c, Clicked_At__c, Click_Count__c,
                       Last_Clicked_URL__c, Bounced_At__c, Bounce_Type__c, Bounce_Reason__c,
                       Unsubscribed_At__c, Last_Engagement_At__c, Device_Type__c, Email_Client__c
                FROM Communication_Recipient__c
                WHERE Communication__c = :target
                AND Message_Id__c != null
            ]);
        }

        // Scheduled sweep: only sends still inside the tracking window, and only
        // recipients that were actually accepted for delivery.
        return Database.getQueryLocator([
            SELECT Id, Communication__c, Message_Id__c, Send_Status__c, Engagement_Status__c,
                   Sent_At__c, Opened_At__c, Open_Count__c, Clicked_At__c, Click_Count__c,
                   Last_Clicked_URL__c, Bounced_At__c, Bounce_Type__c, Bounce_Reason__c,
                   Unsubscribed_At__c, Last_Engagement_At__c, Device_Type__c, Email_Client__c
            FROM Communication_Recipient__c
            WHERE Message_Id__c != null
            AND Send_Status__c = 'Sent'
            AND Communication__r.Execution_End__c >= :cutoff
        ]);
    }

    public void execute(Database.BatchableContext ctx, List<Communication_Recipient__c> scope) {
        for (Communication_Recipient__c r : scope) {
            affectedCommunicationIds.add(r.Communication__c);
        }

        List<Communication_Recipient__c> changed = EngagementMetricsService.applyEngagement(scope);
        if (!changed.isEmpty()) {
            update changed;
        }
    }

    public void finish(Database.BatchableContext ctx) {
        // Roll-ups are aggregate queries per Communication, so this stays well
        // inside limits even after a sweep across many sends.
        for (Id communicationId : affectedCommunicationIds) {
            try {
                EngagementMetricsService.rollUp(communicationId);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Roll-up failed for ' + communicationId + ': ' + e.getMessage());
            }
        }
    }
}
