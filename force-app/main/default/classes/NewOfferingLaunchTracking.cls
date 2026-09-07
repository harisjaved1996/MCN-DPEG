/**
 * Pulls Data Cloud engagement onto the Communication_Recipient__c rows of a
 * New Offering Launch send, and rolls the counters onto the Communication.
 *
 * Fully standalone: its own DMO queries, its own roll-up, no shared Apex.
 *
 * A broadcast flow returns nothing per recipient, so there is no message id to
 * match engagement on. Instead each recipient CLAIMS a flow run:
 *
 *   ssot__EmailEngagement__dlm rows carry ssot__FlowElementRunId__c, shaped
 *   "<GUID>#<SendElementName>" — a distinct GUID per recipient per send. The
 *   claim takes the earliest SEND_STATUS row for that individual, inside this
 *   send's time window, whose run no other recipient already holds. Once
 *   claimed, every later open/click/bounce is keyed off that run id.
 *
 * Claims are restricted to runs ending in this flow's send element, so a
 * concurrent broadcast from any other flow to the same person can never be
 * mistaken for this one.
 *
 * Engagement lags the send by roughly 5-15 minutes of Data Cloud ingestion, so
 * a sync run immediately afterwards legitimately finds nothing. Re-running is
 * safe and idempotent: claimed rows keep their run id.
 */
public with sharing class NewOfferingLaunchTracking {

    /** Data Cloud timestamps drift slightly from Apex's clock. */
    public static final Integer CLOCK_SKEW_MINUTES = 5;

    /** Recipient ids mutated by this run, committed once at the end. */
    private static Set<Id> touched = new Set<Id>();
    private static Set<Id> newlyClaimed = new Set<Id>();

    private static final String ACTION_SEND_STATUS = 'SEND_STATUS';
    private static final String ACTION_OPEN = 'OPEN';
    private static final String ACTION_CLICK = 'CLICK';

    /** DMO-decoupled shape of one ssot__EmailEngagement__dlm event. */
    public class EngagementRow {
        public String flowRunId;
        public Id contactId;
        public String action;
        public Datetime engagedAt;
        public String sendStatus;
        public String linkUrl;
        public String bounceType;
        public String bounceReason;
    }

    // ------------------------------------------------------------ entry point

    /**
     * Claims runs, applies engagement and recomputes the header counters.
     * Returns a message suitable for a toast.
     */
    public static String syncCommunication(Id communicationId) {
        if (communicationId == null) {
            throw new TrackingException('No Communication was supplied to refresh.');
        }

        // A bare [SELECT ... LIMIT 1] would surface a missing or inaccessible
        // record as "List has no rows for assignment to SObject".
        List<Communication__c> found = [
            SELECT Id, Name, Status__c, Execution_Start__c, IR_Communication_Config__c
            FROM Communication__c
            WHERE Id = :communicationId
            LIMIT 1];
        if (found.isEmpty()) {
            throw new TrackingException(
                'Communication ' + communicationId + ' was not found, or you cannot access it.');
        }
        Communication__c c = found[0];
        touched = new Set<Id>();
        newlyClaimed = new Set<Id>();

        List<Communication_Recipient__c> recipients = [
            SELECT Id, Contact__c, Individual_Id__c, Flow_Run_Id__c, Send_Status__c,
                   Engagement_Status__c, Sent_At__c, Opened_At__c, Clicked_At__c,
                   Bounced_At__c, Open_Count__c, Click_Count__c, Last_Clicked_URL__c,
                   Bounce_Type__c, Bounce_Reason__c, Last_Engagement_At__c
            FROM Communication_Recipient__c
            WHERE Communication__c = :communicationId];

        if (recipients.isEmpty()) {
            return 'No recipients are recorded against ' + c.Name + ' yet.';
        }

        // The campaign record is read from the Communication rather than
        // assumed, so a second campaign with a different flow and send element
        // tracks correctly through this same class.
        IRCommunicationSettings.Config cfg =
            IRCommunicationSettings.get(c.IR_Communication_Config__c);

        // Querying a ssot__*__dlm object is a callout under the covers, so a
        // DML statement between the two Data Cloud reads makes the second one
        // fail with "pending uncommitted work". Both reads therefore happen
        // up front and every change is committed afterwards, in one pass.
        Integer claimed = claimRuns(c, recipients, cfg);
        Integer updated = applyEngagement(recipients);

        List<Communication_Recipient__c> dirty = new List<Communication_Recipient__c>();
        for (Communication_Recipient__c r : recipients) {
            if (touched.contains(r.Id) || newlyClaimed.contains(r.Id)) {
                dirty.add(r);
            }
        }
        if (!dirty.isEmpty()) {
            update dirty;
        }
        rollUp(communicationId);

        if (claimed == 0 && updated == 0) {
            return 'No new engagement yet for ' + c.Name
                + '. Data Cloud lags the send by 5-15 minutes.';
        }
        return 'Updated ' + updated + ' recipient' + (updated == 1 ? '' : 's')
            + ' for ' + c.Name + '.';
    }

    // ----------------------------------------------------------------- claim

    /**
     * Gives every unclaimed recipient the earliest SEND_STATUS run not already
     * spoken for. Returns how many were newly claimed.
     */
    private static Integer claimRuns(Communication__c c,
            List<Communication_Recipient__c> recipients, IRCommunicationSettings.Config cfg) {
        Map<Id, Communication_Recipient__c> unclaimedByContact =
            new Map<Id, Communication_Recipient__c>();

        for (Communication_Recipient__c r : recipients) {
            if (String.isBlank(r.Flow_Run_Id__c) && r.Contact__c != null) {
                unclaimedByContact.put(r.Contact__c, r);
            }
        }
        if (unclaimedByContact.isEmpty()) {
            return 0;
        }

        Datetime anchor = (c.Execution_Start__c == null) ? System.now() : c.Execution_Start__c;
        Datetime fromDt =
            anchor.addMinutes(-CLOCK_SKEW_MINUTES).addHours(-cfg.claimWindowHours);
        Datetime toDt = System.now().addMinutes(CLOCK_SKEW_MINUTES);

        List<EngagementRow> candidates =
            fetchSendCandidates(unclaimedByContact.keySet(), fromDt, toDt);
        candidates = sortByEngagedAt(candidates);

        Set<String> taken = claimedRunIds(runIdsOf(candidates));
        List<Communication_Recipient__c> claimed = new List<Communication_Recipient__c>();

        // Only runs from this campaign's send element can be claimed, so a
        // concurrent broadcast from another flow to the same person is never
        // mistaken for this one. Without a send element name configured there
        // is no safe way to tell them apart, so nothing is claimed.
        if (String.isBlank(cfg.sendElementName)) {
            return 0;
        }
        String suffix = '#' + cfg.sendElementName;

        for (EngagementRow row : candidates) {
            if (String.isBlank(row.flowRunId) || !row.flowRunId.endsWith(suffix)) {
                continue;   // another flow's send, or an unusable row
            }
            if (taken.contains(row.flowRunId)) {
                continue;
            }
            Communication_Recipient__c r = unclaimedByContact.get(row.contactId);
            if (r == null) {
                continue;   // already claimed earlier in this same pass
            }
            r.Flow_Run_Id__c = row.flowRunId;
            taken.add(row.flowRunId);
            unclaimedByContact.remove(row.contactId);
            newlyClaimed.add(r.Id);
            claimed.add(r);
        }
        return claimed.size();
    }

    /**
     * Run ids already held by a recipient of any Communication, so two sends
     * can never share one. Only this object is consulted: the run ids are
     * filtered to this flow's send element, so nothing outside this module can
     * be holding them.
     */
    private static Set<String> claimedRunIds(Set<String> candidateRunIds) {
        Set<String> taken = new Set<String>();
        if (candidateRunIds.isEmpty()) {
            return taken;
        }
        for (Communication_Recipient__c r : [
                SELECT Flow_Run_Id__c
                FROM Communication_Recipient__c
                WHERE Flow_Run_Id__c IN :candidateRunIds]) {
            taken.add(r.Flow_Run_Id__c);
        }
        return taken;
    }

    // ------------------------------------------------------------ engagement

    /** Replays every event of the claimed runs onto its recipient. */
    private static Integer applyEngagement(List<Communication_Recipient__c> recipients) {
        Map<String, Communication_Recipient__c> byRunId =
            new Map<String, Communication_Recipient__c>();
        for (Communication_Recipient__c r : recipients) {
            if (String.isNotBlank(r.Flow_Run_Id__c)) {
                byRunId.put(r.Flow_Run_Id__c, r);
            }
        }
        if (byRunId.isEmpty()) {
            return 0;
        }

        Set<Id> changed = new Set<Id>();
        for (EngagementRow row : fetchRunsEngagement(byRunId.keySet())) {
            Communication_Recipient__c r = byRunId.get(row.flowRunId);
            if (r != null && absorb(r, row)) {
                changed.add(r.Id);
            }
        }
        touched.addAll(changed);
        return changed.size();
    }

    /**
     * Folds one event into a recipient. Statuses only move forwards
     * (Sent -> Opened -> Clicked), so events arriving out of order cannot
     * downgrade a row.
     */
    private static Boolean absorb(Communication_Recipient__c r, EngagementRow row) {
        Boolean touched = false;

        if (row.engagedAt != null
                && (r.Last_Engagement_At__c == null || row.engagedAt > r.Last_Engagement_At__c)) {
            r.Last_Engagement_At__c = row.engagedAt;
            touched = true;
        }

        if (String.isNotBlank(row.bounceType)) {
            if (r.Bounced_At__c == null || row.engagedAt < r.Bounced_At__c) {
                r.Bounced_At__c = row.engagedAt;
            }
            r.Bounce_Type__c = row.bounceType;
            r.Bounce_Reason__c = abbreviate(row.bounceReason, 255);
            r.Send_Status__c = 'Failed';
            setStatus(r, 'HARD'.equalsIgnoreCase(row.bounceType)
                ? 'Bounced - Hard' : 'Bounced - Soft');
            return true;
        }

        if (ACTION_SEND_STATUS.equals(row.action)) {
            if ('SENT'.equalsIgnoreCase(row.sendStatus)) {
                if (r.Sent_At__c == null || row.engagedAt < r.Sent_At__c) {
                    r.Sent_At__c = row.engagedAt;
                }
                r.Send_Status__c = 'Sent';
                setStatus(r, 'Sent');
                touched = true;
            }
        } else if (ACTION_OPEN.equals(row.action)) {
            r.Open_Count__c = nz(r.Open_Count__c) + 1;
            if (r.Opened_At__c == null || row.engagedAt < r.Opened_At__c) {
                r.Opened_At__c = row.engagedAt;
            }
            setStatus(r, 'Opened');
            touched = true;
        } else if (ACTION_CLICK.equals(row.action)) {
            r.Click_Count__c = nz(r.Click_Count__c) + 1;
            if (r.Clicked_At__c == null || row.engagedAt < r.Clicked_At__c) {
                r.Clicked_At__c = row.engagedAt;
            }
            // A click proves an open even when the tracking pixel was blocked.
            if (r.Opened_At__c == null || row.engagedAt < r.Opened_At__c) {
                r.Opened_At__c = row.engagedAt;
            }
            r.Last_Clicked_URL__c = abbreviate(row.linkUrl, 255);
            setStatus(r, 'Clicked');
            touched = true;
        }
        return touched;
    }

    private static void setStatus(Communication_Recipient__c r, String status) {
        if (rankOf(status) > rankOf(r.Engagement_Status__c)) {
            r.Engagement_Status__c = status;
        }
    }

    private static Integer rankOf(String status) {
        if (status == 'Clicked') { return 5; }
        if (status == 'Bounced - Hard' || status == 'Bounced - Soft') { return 4; }
        if (status == 'Opened') { return 3; }
        if (status == 'Sent') { return 2; }
        if (status == 'Not Sent') { return 1; }
        return 0;   // Awaiting Data, or nothing yet
    }

    // --------------------------------------------------------------- roll-up

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
                // A click implies an open even when the pixel never fired.
                opened += total;
                clicked += total;
            } else if (status == 'Bounced - Soft' || status == 'Bounced - Hard') {
                bounced += total;
            } else if (status == 'Unsubscribed' || status == 'Complaint') {
                unsubscribed += total;
            }
        }

        Integer sent = [
            SELECT COUNT()
            FROM Communication_Recipient__c
            WHERE Communication__c = :communicationId AND Sent_At__c != NULL];

        Communication__c header = new Communication__c(
            Id = communicationId,
            Sent_Count__c = sent,
            Opened_Count__c = opened,
            Clicked_Count__c = clicked,
            Bounced_Count__c = bounced,
            Unsubscribed_Count__c = unsubscribed,
            Last_Metrics_Sync__c = System.now());

        // The roster batch leaves the record In Progress because at that point
        // the flow has only been ASKED to run - nothing is known about
        // delivery. Data Cloud confirming a send is the first evidence it
        // actually went out, so that is what completes the record. Without
        // this the status stayed In Progress forever.
        if (sent > 0) {
            header.Status__c = 'Completed';
        }
        update header;
    }

    // ---------------------------------------------------- Data Cloud gateway

    /**
     * SEND_STATUS rows for a contact set in a time window (claim candidates).
     *
     * Dynamic SOQL throughout: ssot__EmailEngagement__dlm is a Data Cloud
     * object with no compile-time schema guarantee in every org shape.
     */
    private static List<EngagementRow> fetchSendCandidates(
            Set<Id> contactIds, Datetime fromDt, Datetime toDt) {

        if (contactIds == null || contactIds.isEmpty()) {
            return new List<EngagementRow>();
        }
        List<String> contactKeys = new List<String>();
        for (Id contactId : contactIds) {
            contactKeys.add(String.valueOf(contactId));
        }

        String soql =
            'SELECT ssot__FlowElementRunId__c, ssot__IndividualId__c, '
            + 'ssot__EngagementDateTm__c '
            + 'FROM ssot__EmailEngagement__dlm '
            + 'WHERE ssot__EngagementChannelActionId__c = \'' + ACTION_SEND_STATUS + '\' '
            + 'AND ssot__IndividualId__c IN :contactKeys '
            + 'AND ssot__EngagementDateTm__c >= :fromDt '
            + 'AND ssot__EngagementDateTm__c <= :toDt '
            + 'LIMIT 50000';

        return toRows(Database.queryWithBinds(soql, new Map<String, Object>{
            'contactKeys' => contactKeys, 'fromDt' => fromDt, 'toDt' => toDt
        }, AccessLevel.SYSTEM_MODE));
    }

    /** Every engagement event of the given claimed flow runs. */
    private static List<EngagementRow> fetchRunsEngagement(Set<String> flowRunIds) {
        if (flowRunIds == null || flowRunIds.isEmpty()) {
            return new List<EngagementRow>();
        }
        List<String> runKeys = new List<String>(flowRunIds);

        String soql =
            'SELECT ssot__FlowElementRunId__c, ssot__IndividualId__c, '
            + 'ssot__EngagementChannelActionId__c, ssot__EngagementDateTm__c, '
            + 'ssot__EmailRecipientSendStatus__c, ssot__LinkURL__c, '
            + 'ssot__EmailBounceType__c, ssot__BounceReasonText__c '
            + 'FROM ssot__EmailEngagement__dlm '
            + 'WHERE ssot__FlowElementRunId__c IN :runKeys '
            + 'LIMIT 50000';

        return toRows(Database.queryWithBinds(
            soql, new Map<String, Object>{ 'runKeys' => runKeys }, AccessLevel.SYSTEM_MODE));
    }

    /** DMO SObjects are read through getPopulatedFieldsAsMap so an absent field never throws. */
    private static List<EngagementRow> toRows(List<SObject> records) {
        List<EngagementRow> rows = new List<EngagementRow>();
        for (SObject record : records) {
            Map<String, Object> populated = record.getPopulatedFieldsAsMap();

            EngagementRow row = new EngagementRow();
            row.flowRunId = (String) populated.get('ssot__FlowElementRunId__c');
            row.contactId = toContactId((String) populated.get('ssot__IndividualId__c'));
            row.engagedAt = (Datetime) populated.get('ssot__EngagementDateTm__c');
            row.action = (String) populated.get('ssot__EngagementChannelActionId__c');
            row.sendStatus = (String) populated.get('ssot__EmailRecipientSendStatus__c');
            row.linkUrl = (String) populated.get('ssot__LinkURL__c');
            row.bounceType = (String) populated.get('ssot__EmailBounceType__c');
            row.bounceReason = (String) populated.get('ssot__BounceReasonText__c');
            rows.add(row);
        }
        return rows;
    }

    /** ssot__IndividualId__c is the CRM Contact Id, but arrives as text. */
    private static Id toContactId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }

    // --------------------------------------------------------------- helpers

    /**
     * Apex cannot sort a list of non-Comparable objects, so the ordering is
     * done on a key-prefixed shadow map. Earliest event first.
     */
    private static List<EngagementRow> sortByEngagedAt(List<EngagementRow> rows) {
        Map<String, EngagementRow> byKey = new Map<String, EngagementRow>();
        Integer seq = 0;
        for (EngagementRow r : rows) {
            Long millis = (r.engagedAt == null) ? 0 : r.engagedAt.getTime();
            byKey.put(String.valueOf(millis).leftPad(20, '0') + '#' + seq++, r);
        }
        List<String> keys = new List<String>(byKey.keySet());
        keys.sort();

        List<EngagementRow> sorted = new List<EngagementRow>();
        for (String k : keys) {
            sorted.add(byKey.get(k));
        }
        return sorted;
    }

    private static Set<String> runIdsOf(List<EngagementRow> rows) {
        Set<String> ids = new Set<String>();
        for (EngagementRow r : rows) {
            if (String.isNotBlank(r.flowRunId)) {
                ids.add(r.flowRunId);
            }
        }
        return ids;
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    private static String abbreviate(String value, Integer max) {
        if (String.isBlank(value)) {
            return null;
        }
        return value.length() > max ? value.substring(0, max) : value;
    }

    public class TrackingException extends Exception {}
}
