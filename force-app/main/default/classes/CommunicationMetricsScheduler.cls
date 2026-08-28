/**
 * Periodic engagement sweep.
 *
 * Data Cloud ingests engagement 5-15 minutes behind the send and keeps
 * trickling opens and clicks for days, so this runs on a schedule rather than
 * once after a send completes.
 *
 * Schedule four times an hour:
 *   System.schedule('Communication Metrics :00', '0 0  * * * ?', new CommunicationMetricsScheduler());
 *   System.schedule('Communication Metrics :15', '0 15 * * * ?', new CommunicationMetricsScheduler());
 *   System.schedule('Communication Metrics :30', '0 30 * * * ?', new CommunicationMetricsScheduler());
 *   System.schedule('Communication Metrics :45', '0 45 * * * ?', new CommunicationMetricsScheduler());
 *
 * A Schedulable and a Batchable are kept in separate classes on purpose; this
 * org rejects a class that implements both.
 */
public with sharing class CommunicationMetricsScheduler implements Schedulable {

    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new CommunicationMetricsSyncBatch(), 200);
    }
}
