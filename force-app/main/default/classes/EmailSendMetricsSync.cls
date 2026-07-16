/**
 * Periodic metrics sync for Email_Send__c records.
 *
 * Schedulable only enqueues the Queueable: the DMO SOQL and the (future
 * possibility of a) REST fallback both belong in a queueable context, not in
 * the restricted scheduled-Apex context. The queueable processes a bounded
 * scope of open sends and chains once when more remain.
 *
 * Schedule (Apex cron has no *&#47;15):
 *   System.schedule('EmailSendMetricsSync :00', '0 0 * * * ?', new EmailSendMetricsSync());
 *   System.schedule('EmailSendMetricsSync :15', '0 15 * * * ?', new EmailSendMetricsSync());
 *   System.schedule('EmailSendMetricsSync :30', '0 30 * * * ?', new EmailSendMetricsSync());
 *   System.schedule('EmailSendMetricsSync :45', '0 45 * * * ?', new EmailSendMetricsSync());
 */
public with sharing class EmailSendMetricsSync implements Schedulable {

    public void execute(SchedulableContext sc) {
        System.enqueueJob(new SyncJob());
    }

    /**
     * Separate class because Apex forbids one class implementing both
     * Schedulable and Queueable.
     */
    public class SyncJob implements Queueable, Database.AllowsCallouts {
        public void execute(QueueableContext qc) {
            Boolean hasMore = false;
            try {
                hasMore = InvestmentEmailTracking.syncOpenSends();
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'EmailSendMetricsSync failed: ' + e.getMessage());
            }
            if (hasMore && !Test.isRunningTest()) {
                System.enqueueJob(new SyncJob());
            }
        }
    }
}
