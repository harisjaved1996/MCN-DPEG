/**
 * Tracking layer for the one-button investment email sends.
 *
 * Email_Send__c = one Execute click (which email, which investment, metrics).
 * Email_Send_Recipient__c = one selected contact with their live engagement
 * status, mirrored from the Data Cloud Email Engagement DMO.
 *
 * Correlation: Marketing Cloud stamps every engagement event with
 * ssot__FlowElementRunId__c = "<GUID>#<SendElementName>". Verified in-org:
 * one broadcast produces a DISTINCT GUID PER RECIPIENT (all sharing the send
 * element name and near-identical timestamps), so correlation happens per
 * recipient - each Email_Send_Recipient__c CLAIMS the earliest unclaimed
 * SEND_STATUS row of its contact whose element matches the send's email
 * choice. All later engagement (opens, clicks, bounces) carries the same
 * per-recipient GUID, so synced metrics can never bleed between sends.
 *
 * Engagement lags the send by minutes (Data Cloud ingestion), so claiming
 * retries on every sync cycle until CLAIM_TIMEOUT_HOURS passes.
 */
public with sharing class InvestmentEmailTracking {

    public static final Integer CLAIM_TIMEOUT_HOURS = 24;
    public static final Integer SYNC_WINDOW_DAYS = 7;
    public static final Integer CLOCK_SKEW_MINUTES = 5;
    /** Sends processed per sync cycle (keeps DMO queries well under limits). */
    public static final Integer SYNC_SCOPE = 10;

    public static final String STATUS_QUEUED = 'Queued';
    public static final String STATUS_BROADCAST_REQUESTED = 'Broadcast Requested';
    public static final String STATUS_BROADCAST_FAILED = 'Broadcast Failed';
    public static final String STATUS_SYNCING = 'Syncing';
    public static final String STATUS_COMPLETED = 'Completed';
    public static final String STATUS_NO_DATA = 'No Engagement Data';

    public static final String RECIPIENT_PENDING = 'Pending';
    public static final String RECIPIENT_SENT = 'Sent';
    public static final String RECIPIENT_OPENED = 'Opened';
    public static final String RECIPIENT_CLICKED = 'Clicked';
    public static final String RECIPIENT_BOUNCED = 'Bounced';

    // ------------------------------------------------------------------
    // Data Cloud gateway (tests replace this; logic never touches the DMO)
    // ------------------------------------------------------------------

    public interface EngagementGateway {
        /** SEND_STATUS rows for a contact set in a time window (claim candidates). */
        List<InvestmentEmailModels.EngagementRow> fetchSendCandidates(
            Set<Id> contactIds, Datetime fromDt, Datetime toDt);
        /** Every engagement row of the given claimed flow runs. */
        List<InvestmentEmailModels.EngagementRow> fetchRunsEngagement(Set<String> flowRunIds);
        /** Subject of the ListEmail record Marketing Cloud sent. */
        String fetchListEmailSubject(String listEmailId);
    }

    public static EngagementGateway gateway = new DlmGateway();

    /**
     * Production gateway. Dynamic SOQL only: ssot__EmailEngagement__dlm is a
     * Data Cloud object with no compile-time schema guarantee, and test
     * contexts cannot insert DMO rows.
     */
    public class DlmGateway implements EngagementGateway {

        public List<InvestmentEmailModels.EngagementRow> fetchSendCandidates(
                Set<Id> contactIds, Datetime fromDt, Datetime toDt) {
            if (contactIds == null || contactIds.isEmpty()) {
                return new List<InvestmentEmailModels.EngagementRow>();
            }
            List<String> contactKeys = new List<String>();
            for (Id contactId : contactIds) {
                contactKeys.add(String.valueOf(contactId));
            }
            String soql =
                'SELECT ssot__FlowElementRunId__c, ssot__IndividualId__c, '
                + 'ssot__EngagementDateTm__c, ssot__BulkEmailMessageId__c '
                + 'FROM ssot__EmailEngagement__dlm '
                + 'WHERE ssot__EngagementChannelActionId__c = \'SEND_STATUS\' '
                + 'AND ssot__IndividualId__c IN :contactKeys '
                + 'AND ssot__EngagementDateTm__c >= :fromDt '
                + 'AND ssot__EngagementDateTm__c <= :toDt '
                + 'LIMIT 9500';
            return toRows(Database.queryWithBinds(
                soql,
                new Map<String, Object>{
                    'contactKeys' => contactKeys, 'fromDt' => fromDt, 'toDt' => toDt },
                AccessLevel.SYSTEM_MODE));
        }

        public List<InvestmentEmailModels.EngagementRow> fetchRunsEngagement(
                Set<String> flowRunIds) {
            if (flowRunIds == null || flowRunIds.isEmpty()) {
                return new List<InvestmentEmailModels.EngagementRow>();
            }
            List<String> runKeys = new List<String>(flowRunIds);
            String soql =
                'SELECT ssot__FlowElementRunId__c, ssot__IndividualId__c, '
                + 'ssot__EngagementChannelActionId__c, ssot__EngagementDateTm__c, '
                + 'ssot__EmailRecipientSendStatus__c, ssot__LinkURL__c, '
                + 'ssot__EmailBounceType__c, ssot__BounceReasonText__c, '
                + 'ssot__BulkEmailMessageId__c '
                + 'FROM ssot__EmailEngagement__dlm '
                + 'WHERE ssot__FlowElementRunId__c IN :runKeys '
                + 'LIMIT 9500';
            return toRows(Database.queryWithBinds(
                soql,
                new Map<String, Object>{ 'runKeys' => runKeys },
                AccessLevel.SYSTEM_MODE));
        }

        public String fetchListEmailSubject(String listEmailId) {
            if (String.isBlank(listEmailId)) {
                return null;
            }
            List<ListEmail> emails = [
                SELECT Subject FROM ListEmail WHERE Id = :listEmailId LIMIT 1
            ];
            return emails.isEmpty() ? null : emails[0].Subject;
        }

        private List<InvestmentEmailModels.EngagementRow> toRows(List<SObject> records) {
            List<InvestmentEmailModels.EngagementRow> rows =
                new List<InvestmentEmailModels.EngagementRow>();
            for (SObject record : records) {
                InvestmentEmailModels.EngagementRow row = new InvestmentEmailModels.EngagementRow();
                row.flowRunId = (String) record.get('ssot__FlowElementRunId__c');
                row.contactId = toContactId((String) record.get('ssot__IndividualId__c'));
                row.engagedAt = (Datetime) record.get('ssot__EngagementDateTm__c');
                row.bulkEmailMessageId = (String) record.get('ssot__BulkEmailMessageId__c');
                // Fields absent from the candidates query stay null via the populated map.
                Map<String, Object> populated = record.getPopulatedFieldsAsMap();
                row.action = (String) populated.get('ssot__EngagementChannelActionId__c');
                row.sendStatus = (String) populated.get('ssot__EmailRecipientSendStatus__c');
                row.linkUrl = (String) populated.get('ssot__LinkURL__c');
                row.bounceType = (String) populated.get('ssot__EmailBounceType__c');
                row.bounceReason = (String) populated.get('ssot__BounceReasonText__c');
                rows.add(row);
            }
            return rows;
        }

        /** DMO individual ids are strings; tolerate values that are not Contact ids. */
        private Id toContactId(String value) {
            if (String.isBlank(value)) {
                return null;
            }
            try {
                return Id.valueOf(value);
            } catch (Exception e) {
                return null;
            }
        }
    }

    // ------------------------------------------------------------------
    // creation (called from the send pipeline, pre-enqueue, fail closed)
    // ------------------------------------------------------------------

    public static Id createSendRecord(Id investmentId, String investmentName,
            String emailChoice, String sendRunId,
            List<InvestmentEmailController.Investor> recipients) {

        Email_Send__c send = new Email_Send__c(
            Name = (emailChoice + ' - ' + investmentName).abbreviate(60)
                + ' - ' + Datetime.now().format('yyyy-MM-dd HH:mm'),
            Investment__c = investmentId,
            Email_Choice__c = emailChoice,
            Send_Run_Id__c = sendRunId,
            Status__c = STATUS_QUEUED,
            Sent_At__c = Datetime.now(),
            Total_Recipients__c = recipients == null ? 0 : recipients.size(),
            Sent_Count__c = 0,
            Opened_Count__c = 0,
            Clicked_Count__c = 0,
            Bounced_Count__c = 0
        );
        insert send;

        List<Email_Send_Recipient__c> rows = new List<Email_Send_Recipient__c>();
        if (recipients != null) {
            for (InvestmentEmailController.Investor investor : recipients) {
                rows.add(new Email_Send_Recipient__c(
                    Name = (String.isBlank(investor.name)
                        ? String.valueOf(investor.id) : investor.name).abbreviate(80),
                    Email_Send__c = send.Id,
                    Contact__c = investor.id,
                    Email__c = investor.email,
                    Status__c = RECIPIENT_PENDING,
                    Open_Count__c = 0,
                    Click_Count__c = 0
                ));
            }
        }
        if (!rows.isEmpty()) {
            insert rows;
        }
        return send.Id;
    }

    /** Called by the broadcast Queueable after its callout (DML after callout is legal). */
    public static void markBroadcastOutcome(Id emailSendId, Boolean success, String detail) {
        if (emailSendId == null) {
            return;
        }
        update new Email_Send__c(
            Id = emailSendId,
            Status__c = success ? STATUS_BROADCAST_REQUESTED : STATUS_BROADCAST_FAILED,
            Error_Message__c = success ? null : (detail == null ? null : detail.abbreviate(4000))
        );
    }

    // ------------------------------------------------------------------
    // sync entry points
    // ------------------------------------------------------------------

    /**
     * Scheduled path: process up to SYNC_SCOPE open sends, oldest first.
     * Returns true when more open sends remain (caller may chain).
     * "Broadcast Failed" is included on purpose: a timed-out trigger callout
     * may still have executed, and a successful claim is the proof it did.
     */
    public static Boolean syncOpenSends() {
        List<Email_Send__c> sends = [
            SELECT Id, Email_Choice__c, Status__c, Sent_At__c, Flow_Run_Id__c,
                   List_Email_Id__c, Subject__c
            FROM Email_Send__c
            WHERE Status__c IN (:STATUS_QUEUED, :STATUS_BROADCAST_REQUESTED,
                                :STATUS_BROADCAST_FAILED, :STATUS_SYNCING)
            ORDER BY Sent_At__c ASC
            LIMIT :SYNC_SCOPE + 1
        ];
        Boolean hasMore = sends.size() > SYNC_SCOPE;
        while (sends.size() > SYNC_SCOPE) {
            sends.remove(sends.size() - 1);
        }
        if (!sends.isEmpty()) {
            syncSends(sends);
        }
        return hasMore;
    }

    /** On-demand path (Refresh Metrics button). Works on any status. */
    public static String syncSend(Id emailSendId) {
        List<Email_Send__c> sends = [
            SELECT Id, Email_Choice__c, Status__c, Sent_At__c, Flow_Run_Id__c,
                   List_Email_Id__c, Subject__c
            FROM Email_Send__c
            WHERE Id = :emailSendId
            LIMIT 1
        ];
        if (sends.isEmpty()) {
            throw new TrackingException('Email Send record not found.');
        }
        syncSends(sends);
        Email_Send__c refreshed = [
            SELECT Flow_Run_Id__c FROM Email_Send__c WHERE Id = :emailSendId
        ];
        if (String.isBlank(refreshed.Flow_Run_Id__c)) {
            return 'No engagement data found yet - Data Cloud usually lags a few '
                + 'minutes behind the send. Try again shortly.';
        }
        return 'Metrics refreshed from Data Cloud.';
    }

    // ------------------------------------------------------------------
    // core sync
    // ------------------------------------------------------------------

    private static void syncSends(List<Email_Send__c> sends) {
        // Recipients of every send in scope, keyed by send then contact.
        Map<Id, Map<Id, Email_Send_Recipient__c>> recipientsBySend =
            new Map<Id, Map<Id, Email_Send_Recipient__c>>();
        for (Email_Send__c send : sends) {
            recipientsBySend.put(send.Id, new Map<Id, Email_Send_Recipient__c>());
        }
        for (Email_Send_Recipient__c recipient : [
            SELECT Id, Email_Send__c, Contact__c, Flow_Run_Id__c, Status__c, Sent_At__c,
                   Opened_At__c, Clicked_At__c, Bounced_At__c, Open_Count__c,
                   Click_Count__c, Last_Click_URL__c, Bounce_Type__c, Bounce_Reason__c
            FROM Email_Send_Recipient__c
            WHERE Email_Send__c IN :recipientsBySend.keySet()
              AND Contact__c != NULL
        ]) {
            recipientsBySend.get(recipient.Email_Send__c)
                .put(recipient.Contact__c, recipient);
        }

        // (flowRunId | contactId) pairs claimed earlier in this same cycle.
        Set<String> claimedThisRun = new Set<String>();
        List<Email_Send__c> masterUpdates = new List<Email_Send__c>();
        Map<Id, Email_Send_Recipient__c> recipientUpdates =
            new Map<Id, Email_Send_Recipient__c>();
        Set<Id> recalcIds = new Set<Id>();

        for (Email_Send__c send : sends) {
            Map<Id, Email_Send_Recipient__c> recipients = recipientsBySend.get(send.Id);

            for (Email_Send_Recipient__c claimed
                    : claimRecipientRuns(send, recipients, claimedThisRun)) {
                recipientUpdates.put(claimed.Id, claimed);
            }

            Set<String> runIds = new Set<String>();
            for (Email_Send_Recipient__c recipient : recipients.values()) {
                if (String.isNotBlank(recipient.Flow_Run_Id__c)) {
                    runIds.add(recipient.Flow_Run_Id__c);
                }
            }

            if (runIds.isEmpty()) {
                // Nothing claimable yet. Give up only after the timeout.
                if (send.Status__c != STATUS_BROADCAST_FAILED
                        && send.Status__c != STATUS_NO_DATA
                        && send.Sent_At__c != null
                        && send.Sent_At__c < Datetime.now().addHours(-CLAIM_TIMEOUT_HOURS)) {
                    send.Status__c = STATUS_NO_DATA;
                    masterUpdates.add(send);
                }
                continue;
            }

            for (Email_Send_Recipient__c changed : applyEngagement(runIds, recipients)) {
                recipientUpdates.put(changed.Id, changed);
            }
            recalcIds.add(send.Id);

            send.Last_Synced_At__c = Datetime.now();
            send.Status__c = (send.Sent_At__c != null
                    && send.Sent_At__c < Datetime.now().addDays(-SYNC_WINDOW_DAYS))
                ? STATUS_COMPLETED : STATUS_SYNCING;
            masterUpdates.add(send);
        }

        if (!recipientUpdates.isEmpty()) {
            update recipientUpdates.values();
        }
        if (!masterUpdates.isEmpty()) {
            update masterUpdates;
        }
        recalcMetrics(recalcIds);
    }

    /**
     * Claims flow runs for this send's unclaimed recipients. One broadcast
     * stamps a distinct GUID per recipient, so each recipient independently
     * claims the EARLIEST unclaimed element-matched SEND_STATUS row of its
     * contact. Mutates recipients (Flow_Run_Id__c) and the send (representative
     * Flow_Run_Id__c, List_Email_Id__c, Subject__c) in memory.
     * Returns the recipients claimed in this pass.
     */
    private static List<Email_Send_Recipient__c> claimRecipientRuns(Email_Send__c send,
            Map<Id, Email_Send_Recipient__c> recipients, Set<String> claimedThisRun) {

        List<Email_Send_Recipient__c> newlyClaimed = new List<Email_Send_Recipient__c>();
        Set<Id> unclaimedContactIds = new Set<Id>();
        for (Email_Send_Recipient__c recipient : recipients.values()) {
            if (String.isBlank(recipient.Flow_Run_Id__c)) {
                unclaimedContactIds.add(recipient.Contact__c);
            }
        }
        if (send.Sent_At__c == null || unclaimedContactIds.isEmpty()) {
            return newlyClaimed;
        }
        String elementName = flowElementNameFor(send.Email_Choice__c);
        if (String.isBlank(elementName)) {
            return newlyClaimed;
        }

        List<InvestmentEmailModels.EngagementRow> candidates = gateway.fetchSendCandidates(
            unclaimedContactIds,
            send.Sent_At__c.addMinutes(-CLOCK_SKEW_MINUTES),
            send.Sent_At__c.addHours(CLAIM_TIMEOUT_HOURS));

        // Keep rows of the right send element, earliest first per contact.
        Map<Id, List<InvestmentEmailModels.EngagementRow>> rowsByContact =
            new Map<Id, List<InvestmentEmailModels.EngagementRow>>();
        Set<String> candidateRunIds = new Set<String>();
        String suffix = '#' + elementName;
        for (InvestmentEmailModels.EngagementRow row : candidates) {
            if (row.flowRunId == null || !row.flowRunId.endsWith(suffix)
                    || row.contactId == null) {
                continue;
            }
            if (!rowsByContact.containsKey(row.contactId)) {
                rowsByContact.put(row.contactId, new List<InvestmentEmailModels.EngagementRow>());
            }
            rowsByContact.get(row.contactId).add(row);
            candidateRunIds.add(row.flowRunId);
        }
        if (rowsByContact.isEmpty()) {
            return newlyClaimed;
        }

        // A (run, contact) pair already claimed by ANOTHER send's recipient is
        // taken - this is what keeps back-to-back sends of the same email from
        // stealing each other's events (oldest send is processed first).
        Set<String> takenPairs = new Set<String>(claimedThisRun);
        for (Email_Send_Recipient__c other : [
            SELECT Contact__c, Flow_Run_Id__c FROM Email_Send_Recipient__c
            WHERE Flow_Run_Id__c IN :candidateRunIds
              AND Email_Send__c != :send.Id
        ]) {
            takenPairs.add(pairKey(other.Flow_Run_Id__c, other.Contact__c));
        }

        for (Id contactId : rowsByContact.keySet()) {
            Email_Send_Recipient__c recipient = recipients.get(contactId);
            if (recipient == null || String.isNotBlank(recipient.Flow_Run_Id__c)) {
                continue;
            }
            // Earliest unclaimed row wins.
            InvestmentEmailModels.EngagementRow winner = null;
            for (InvestmentEmailModels.EngagementRow row : rowsByContact.get(contactId)) {
                if (takenPairs.contains(pairKey(row.flowRunId, contactId))) {
                    continue;
                }
                if (winner == null
                        || (row.engagedAt != null
                            && (winner.engagedAt == null || row.engagedAt < winner.engagedAt))) {
                    winner = row;
                }
            }
            if (winner == null) {
                continue;
            }
            recipient.Flow_Run_Id__c = winner.flowRunId;
            takenPairs.add(pairKey(winner.flowRunId, contactId));
            claimedThisRun.add(pairKey(winner.flowRunId, contactId));
            newlyClaimed.add(recipient);

            // First claim decorates the master with the representative run,
            // the ListEmail id and the real subject.
            if (String.isBlank(send.Flow_Run_Id__c)) {
                send.Flow_Run_Id__c = winner.flowRunId;
                send.List_Email_Id__c = winner.bulkEmailMessageId == null
                    ? null : winner.bulkEmailMessageId.abbreviate(18);
                String subject = gateway.fetchListEmailSubject(send.List_Email_Id__c);
                if (String.isNotBlank(subject)) {
                    send.Subject__c = subject.abbreviate(255);
                }
            }
        }
        return newlyClaimed;
    }

    private static String pairKey(String flowRunId, Id contactId) {
        return flowRunId + '|' + contactId;
    }

    /** CMDT lookup with a conventional fallback (Send_<Choice>_Email). */
    private static String flowElementNameFor(String emailChoice) {
        if (String.isBlank(emailChoice)) {
            return null;
        }
        Investment_Email_Option__mdt option =
            Investment_Email_Option__mdt.getInstance(emailChoice);
        if (option != null && String.isNotBlank(option.Flow_Element_Name__c)) {
            return option.Flow_Element_Name__c;
        }
        return 'Send_' + emailChoice + '_Email';
    }

    /**
     * Recomputes every claimed recipient's state from the full engagement of
     * its claimed run (idempotent: same events in, same fields out) and
     * returns only the rows that actually changed.
     */
    private static List<Email_Send_Recipient__c> applyEngagement(Set<String> runIds,
            Map<Id, Email_Send_Recipient__c> recipientsByContact) {

        Map<Id, ContactEngagement> stateByContact = new Map<Id, ContactEngagement>();
        for (InvestmentEmailModels.EngagementRow row : gateway.fetchRunsEngagement(runIds)) {
            Email_Send_Recipient__c recipient = row.contactId == null
                ? null : recipientsByContact.get(row.contactId);
            // Strict scoping: the event must belong to the run THIS recipient
            // claimed, so shared contacts in other sends can never bleed in.
            if (recipient == null || row.flowRunId != recipient.Flow_Run_Id__c) {
                continue;
            }
            ContactEngagement state = stateByContact.get(row.contactId);
            if (state == null) {
                state = new ContactEngagement();
                stateByContact.put(row.contactId, state);
            }
            state.absorb(row);
        }

        List<Email_Send_Recipient__c> changed = new List<Email_Send_Recipient__c>();
        for (Id contactId : stateByContact.keySet()) {
            Email_Send_Recipient__c recipient = recipientsByContact.get(contactId);
            if (stateByContact.get(contactId).applyTo(recipient)) {
                changed.add(recipient);
            }
        }
        return changed;
    }

    /** Fresh per-contact rollup of one run's engagement events. */
    private class ContactEngagement {
        Datetime sentAt;
        Datetime openedAt;
        Datetime clickedAt;
        Datetime bouncedAt;
        Datetime lastClickAt;
        Integer openCount = 0;
        Integer clickCount = 0;
        String lastClickUrl;
        String bounceType;
        String bounceReason;

        void absorb(InvestmentEmailModels.EngagementRow row) {
            if (String.isNotBlank(row.bounceType)) {
                if (bouncedAt == null || row.engagedAt < bouncedAt) {
                    bouncedAt = row.engagedAt;
                }
                bounceType = row.bounceType;
                bounceReason = row.bounceReason;
                return;
            }
            if (row.action == InvestmentEmailModels.ACTION_SEND_STATUS) {
                if ('SENT'.equalsIgnoreCase(row.sendStatus)
                        && (sentAt == null || row.engagedAt < sentAt)) {
                    sentAt = row.engagedAt;
                }
            } else if (row.action == InvestmentEmailModels.ACTION_OPEN) {
                openCount++;
                if (openedAt == null || row.engagedAt < openedAt) {
                    openedAt = row.engagedAt;
                }
            } else if (row.action == InvestmentEmailModels.ACTION_CLICK) {
                clickCount++;
                if (clickedAt == null || row.engagedAt < clickedAt) {
                    clickedAt = row.engagedAt;
                }
                if (lastClickAt == null || row.engagedAt >= lastClickAt) {
                    lastClickAt = row.engagedAt;
                    lastClickUrl = row.linkUrl;
                }
                // A click proves an open even when images were blocked.
                if (openedAt == null || row.engagedAt < openedAt) {
                    openedAt = row.engagedAt;
                }
            }
            // Other actions (e.g. MESSAGE_PROCESSING_TIME) are pipeline
            // telemetry, not recipient engagement - ignored.
        }

        String status() {
            if (bouncedAt != null) {
                return RECIPIENT_BOUNCED;
            }
            if (clickedAt != null) {
                return RECIPIENT_CLICKED;
            }
            if (openedAt != null) {
                return RECIPIENT_OPENED;
            }
            if (sentAt != null) {
                return RECIPIENT_SENT;
            }
            return RECIPIENT_PENDING;
        }

        /** Writes the computed state onto the recipient; true when it changed. */
        Boolean applyTo(Email_Send_Recipient__c recipient) {
            Boolean changed = false;
            String newStatus = status();
            if (recipient.Status__c != newStatus) {
                recipient.Status__c = newStatus;
                changed = true;
            }
            if (recipient.Sent_At__c != sentAt) {
                recipient.Sent_At__c = sentAt;
                changed = true;
            }
            if (recipient.Opened_At__c != openedAt) {
                recipient.Opened_At__c = openedAt;
                changed = true;
            }
            if (recipient.Clicked_At__c != clickedAt) {
                recipient.Clicked_At__c = clickedAt;
                changed = true;
            }
            if (recipient.Bounced_At__c != bouncedAt) {
                recipient.Bounced_At__c = bouncedAt;
                changed = true;
            }
            if (recipient.Open_Count__c != openCount) {
                recipient.Open_Count__c = openCount;
                changed = true;
            }
            if (recipient.Click_Count__c != clickCount) {
                recipient.Click_Count__c = clickCount;
                changed = true;
            }
            String clickUrl = lastClickUrl == null ? null : lastClickUrl.abbreviate(255);
            if (recipient.Last_Click_URL__c != clickUrl) {
                recipient.Last_Click_URL__c = clickUrl;
                changed = true;
            }
            String bType = bounceType == null ? null : bounceType.abbreviate(80);
            if (recipient.Bounce_Type__c != bType) {
                recipient.Bounce_Type__c = bType;
                changed = true;
            }
            String bReason = bounceReason == null ? null : bounceReason.abbreviate(255);
            if (recipient.Bounce_Reason__c != bReason) {
                recipient.Bounce_Reason__c = bReason;
                changed = true;
            }
            return changed;
        }
    }

    // ------------------------------------------------------------------
    // metrics rollup (same shape as SignatureRequestTracking.recalcMetrics)
    // ------------------------------------------------------------------

    public static void recalcMetrics(Set<Id> sendIds) {
        if (sendIds == null || sendIds.isEmpty()) {
            return;
        }
        Map<Id, Email_Send__c> sends = new Map<Id, Email_Send__c>();
        for (Id sendId : sendIds) {
            sends.put(sendId, new Email_Send__c(
                Id = sendId, Total_Recipients__c = 0, Sent_Count__c = 0,
                Opened_Count__c = 0, Clicked_Count__c = 0, Bounced_Count__c = 0));
        }
        for (Email_Send_Recipient__c recipient : [
            SELECT Email_Send__c, Status__c, Opened_At__c, Clicked_At__c
            FROM Email_Send_Recipient__c
            WHERE Email_Send__c IN :sendIds
        ]) {
            Email_Send__c send = sends.get(recipient.Email_Send__c);
            send.Total_Recipients__c++;
            if (recipient.Status__c == RECIPIENT_BOUNCED) {
                send.Bounced_Count__c++;
                continue;
            }
            if (recipient.Status__c == RECIPIENT_SENT
                    || recipient.Status__c == RECIPIENT_OPENED
                    || recipient.Status__c == RECIPIENT_CLICKED) {
                send.Sent_Count__c++;
            }
            if (recipient.Opened_At__c != null) {
                send.Opened_Count__c++;
            }
            if (recipient.Clicked_At__c != null) {
                send.Clicked_Count__c++;
            }
        }
        update sends.values();
    }

    public class TrackingException extends Exception {}
}
