/**
 * Pulls engagement from Data Cloud onto Communication_Recipient__c rows and
 * rolls the totals up onto the Communication.
 *
 * Correlation is exact. ssot__EmailEngagement__dlm.ssot__RecipientMessageId__c
 * holds the same messageId that Direct Email Send API returned per recipient,
 * so rows are joined on that rather than on individual plus a time window. That
 * keeps repeat sends to the same person from cross-contaminating each other.
 *
 * Engagement ingestion lags the send by roughly 5-15 minutes, so this is
 * designed to be run repeatedly and to be safe to re-run.
 */
public with sharing class EngagementMetricsService {

    // Action values observed on the DMO. MESSAGE_PROCESSING_TIME is telemetry.
    private static final String ACTION_SEND = 'SEND_STATUS';
    private static final String ACTION_OPEN = 'OPEN';
    private static final String ACTION_CLICK = 'CLICK';
    private static final String ACTION_BOUNCE = 'BOUNCE';
    private static final String ACTION_UNSUB = 'UNSUBSCRIBE';
    private static final String ACTION_COMPLAINT = 'COMPLAINT';

    /**
     * Applies engagement to a chunk of recipient rows. Returns the rows that
     * actually changed, so callers only issue DML when there is something new.
     */
    public static List<Communication_Recipient__c> applyEngagement(List<Communication_Recipient__c> rows) {
        Map<String, Communication_Recipient__c> byMessageId = new Map<String, Communication_Recipient__c>();
        for (Communication_Recipient__c r : rows) {
            if (String.isNotBlank(r.Message_Id__c)) {
                byMessageId.put(r.Message_Id__c, r);
            }
        }
        if (byMessageId.isEmpty()) {
            return new List<Communication_Recipient__c>();
        }

        Set<String> messageIds = byMessageId.keySet();
        Set<Id> touched = new Set<Id>();

        for (ssot__EmailEngagement__dlm e : [
                SELECT ssot__RecipientMessageId__c, ssot__EngagementChannelActionId__c,
                       ssot__EngagementDateTm__c, ssot__EmailRecipientSendStatus__c,
                       ssot__EmailBounceType__c, ssot__BounceReasonText__c,
                       ssot__LinkURL__c, ssot__DeviceTypeText__c, ssot__EmailClientName__c,
                       ssot__UnsubscribeSourceText__c
                FROM ssot__EmailEngagement__dlm
                WHERE ssot__RecipientMessageId__c IN :messageIds
                ORDER BY ssot__EngagementDateTm__c ASC
                LIMIT 50000]) {

            Communication_Recipient__c row = byMessageId.get(e.ssot__RecipientMessageId__c);
            if (row == null) {
                continue;
            }
            if (applyEvent(row, e)) {
                touched.add(row.Id);
            }
        }

        List<Communication_Recipient__c> changed = new List<Communication_Recipient__c>();
        for (Communication_Recipient__c r : rows) {
            if (touched.contains(r.Id)) {
                changed.add(r);
            }
        }
        return changed;
    }

    /**
     * Folds one engagement event into a recipient row.
     * Engagement status only ever escalates, so a later open cannot demote a
     * recorded click and a bounce always wins.
     */
    private static Boolean applyEvent(Communication_Recipient__c row, ssot__EmailEngagement__dlm e) {
        String action = e.ssot__EngagementChannelActionId__c;
        Datetime occurred = e.ssot__EngagementDateTm__c;

        if (action == ACTION_SEND) {
            if ('NOT_SENT'.equalsIgnoreCase(e.ssot__EmailRecipientSendStatus__c)) {
                setStatus(row, 'Not Sent', 0);
            } else {
                if (row.Sent_At__c == null) {
                    row.Sent_At__c = occurred;
                }
                setStatus(row, 'Sent', 1);
            }
        } else if (action == ACTION_OPEN) {
            row.Open_Count__c = nz(row.Open_Count__c) + 1;
            if (row.Opened_At__c == null) {
                row.Opened_At__c = occurred;
            }
            captureContext(row, e);
            setStatus(row, 'Opened', 2);

        } else if (action == ACTION_CLICK) {
            row.Click_Count__c = nz(row.Click_Count__c) + 1;
            if (row.Clicked_At__c == null) {
                row.Clicked_At__c = occurred;
            }
            if (String.isNotBlank(e.ssot__LinkURL__c)) {
                row.Last_Clicked_URL__c = e.ssot__LinkURL__c.abbreviate(255);
            }
            captureContext(row, e);
            setStatus(row, 'Clicked', 3);

        } else if (action == ACTION_BOUNCE) {
            row.Bounced_At__c = occurred;
            row.Bounce_Type__c = e.ssot__EmailBounceType__c;
            row.Bounce_Reason__c = abbreviate(e.ssot__BounceReasonText__c, 255);
            setStatus(row,
                'HARD'.equalsIgnoreCase(e.ssot__EmailBounceType__c) ? 'Bounced - Hard' : 'Bounced - Soft',
                4);

        } else if (action == ACTION_UNSUB) {
            row.Unsubscribed_At__c = occurred;
            setStatus(row, 'Unsubscribed', 5);

        } else if (action == ACTION_COMPLAINT) {
            setStatus(row, 'Complaint', 5);

        } else {
            // MESSAGE_PROCESSING_TIME and anything unrecognised: telemetry only.
            return false;
        }

        if (occurred != null && (row.Last_Engagement_At__c == null || occurred > row.Last_Engagement_At__c)) {
            row.Last_Engagement_At__c = occurred;
        }
        return true;
    }

    /** Escalate only. Rank orders the funnel so replays cannot move a row backwards. */
    private static void setStatus(Communication_Recipient__c row, String status, Integer rank) {
        Integer current = rankOf(row.Engagement_Status__c);
        if (rank >= current) {
            row.Engagement_Status__c = status;
        }
    }

    private static Integer rankOf(String status) {
        if (status == null) return -1;
        if (status == 'Awaiting Data') return -1;
        if (status == 'Not Sent') return 0;
        if (status == 'Sent') return 1;
        if (status == 'Opened') return 2;
        if (status == 'Clicked') return 3;
        if (status == 'Bounced - Soft' || status == 'Bounced - Hard') return 4;
        if (status == 'Unsubscribed' || status == 'Complaint') return 5;
        return -1;
    }

    private static void captureContext(Communication_Recipient__c row, ssot__EmailEngagement__dlm e) {
        if (String.isNotBlank(e.ssot__DeviceTypeText__c)) {
            row.Device_Type__c = abbreviate(e.ssot__DeviceTypeText__c, 80);
        }
        if (String.isNotBlank(e.ssot__EmailClientName__c)) {
            row.Email_Client__c = abbreviate(e.ssot__EmailClientName__c, 80);
        }
    }

    // -------------------------------------------------------------- roll-up

    /** Recomputes the header counters from the recipient rows. */
    public static void rollUp(Id communicationId) {
        Integer opened = 0, clicked = 0, bounced = 0, unsubscribed = 0;

        for (AggregateResult ar : [
                SELECT Engagement_Status__c status, COUNT(Id) total
                FROM Communication_Recipient__c
                WHERE Communication__c = :communicationId
                GROUP BY Engagement_Status__c]) {

            String status = (String) ar.get('status');
            Integer total = (Integer) ar.get('total');

            if (status == 'Opened') {
                opened += total;
            } else if (status == 'Clicked') {
                // A click implies an open even when the open pixel never fired.
                opened += total;
                clicked += total;
            } else if (status == 'Bounced - Soft' || status == 'Bounced - Hard') {
                bounced += total;
            } else if (status == 'Unsubscribed' || status == 'Complaint') {
                unsubscribed += total;
            }
        }

        update new Communication__c(
            Id = communicationId,
            Opened_Count__c = opened,
            Clicked_Count__c = clicked,
            Bounced_Count__c = bounced,
            Unsubscribed_Count__c = unsubscribed,
            Last_Metrics_Sync__c = System.now()
        );
    }

    /** On-demand refresh for one Communication. Returns a user-facing message. */
    public static String syncCommunication(Id communicationId) {
        if (communicationId == null) {
            throw new MetricsException('No Communication was supplied to refresh.');
        }

        // A bare [SELECT ... LIMIT 1] would surface a missing or inaccessible
        // record as "List has no rows for assignment to SObject", which tells
        // the user nothing.
        List<Communication__c> found = [
            SELECT Id, Name, Status__c, Sent_Count__c
            FROM Communication__c WHERE Id = :communicationId LIMIT 1];
        if (found.isEmpty()) {
            throw new MetricsException(
                'Communication ' + communicationId + ' was not found, or you do not have access to it.');
        }
        Communication__c c = found[0];

        if (c.Status__c == 'Queued' || c.Status__c == 'In Progress') {
            return 'This send is still running. Metrics become available once it finishes.';
        }
        Database.executeBatch(new CommunicationMetricsSyncBatch(communicationId), 200);
        return 'Refreshing engagement for ' + c.Name + '. Data Cloud lags the send by 5-15 minutes.';
    }

    // -------------------------------------------------------------- helpers

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    private static String abbreviate(String value, Integer max) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.length() > max ? value.substring(0, max) : value;
    }

    public class MetricsException extends Exception {}
}
