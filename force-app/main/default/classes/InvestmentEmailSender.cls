public with sharing class InvestmentEmailSender {

    public class Request {
        @InvocableVariable(required=true label='Investment Name')
        public String investmentName;

        @InvocableVariable(required=true label='Email Choice')
        public String emailChoice;

        @InvocableVariable(label='Deselected Contact Ids')
        public List<Id> deselectedContactIds;

        @InvocableVariable(label='Investment Record Id')
        public Id investmentRecordId;
    }

    public class Result {
        @InvocableVariable(label='Status Message')
        public String statusMessage;
    }

    @InvocableMethod(label='Send Investment Email' description='Records per-send exclusions then queues the Investment Broadcast Flow callout')
    public static List<Result> send(List<Request> requests) {
        List<Result> results = new List<Result>();

        for (Request req : requests) {
            Result r = new Result();

            // One unique id per send run. Ties the exclusion rows to this
            // specific broadcast; rows are never reused (audit trail).
            String sendRunId = UUID.randomUUID().toString();

            try {
                // 1) Record the exclusions FIRST, synchronously.
                //    Fail closed: if this DML throws we fall into catch and never
                //    queue the callout, so we can never email someone who should
                //    have been skipped but whose exclusion row failed to save.
                if (req.deselectedContactIds != null && !req.deselectedContactIds.isEmpty()) {
                    List<Send_Exclusion__c> exclusions = new List<Send_Exclusion__c>();
                    for (Id contactId : req.deselectedContactIds) {
                        exclusions.add(new Send_Exclusion__c(
                            Contact__c     = contactId,
                            Investment__c  = req.investmentRecordId, // optional audit context
                            Send_Run_Id__c = sendRunId
                        ));
                    }
                    insert exclusions; // single bulk DML
                }

                // 2) Do the callout from a SEPARATE transaction.
                //    A callout AFTER DML in the same transaction throws
                //    "You have uncommitted work pending". Enqueuing a Queueable
                //    lets the exclusion insert commit first; the callout then runs
                //    in its own async context. Queueable is chosen over @future
                //    because it carries typed constructor state cleanly and is
                //    easy to observe/assert in tests. enqueueJob is not a callout,
                //    so it is safe to call right after the insert above.
                System.enqueueJob(new BroadcastCalloutJob(
                    req.investmentName, req.emailChoice, sendRunId
                ));

                r.statusMessage = 'SUCCESS: Email send queued for '
                    + req.investmentName + '. Run: ' + sendRunId;
            } catch (Exception e) {
                // Exclusion insert (or enqueue) failed -> nothing was queued.
                // Surface it so the flow/user sees the send did NOT go out.
                r.statusMessage = 'EXCEPTION: ' + e.getMessage();
            }

            results.add(r);
        }
        return results;
    }

    /**
     * Performs the Marketing Cloud Broadcast Flow callout in its own async
     * transaction, after the exclusion rows have committed.
     *
     * Auth: uses the OwnOrg Named Credential (callout:OwnOrg) so the platform
     * injects the authorization header. We deliberately do NOT use
     * UserInfo.getSessionId(): it is unavailable/invalid from flow and async
     * contexts (the whole reason this callout was moved here).
     */
    public class BroadcastCalloutJob implements Queueable, Database.AllowsCallouts {
        private final String investmentName;
        private final String emailChoice;
        private final String sendRunId;

        public BroadcastCalloutJob(String investmentName, String emailChoice, String sendRunId) {
            this.investmentName = investmentName;
            this.emailChoice    = emailChoice;
            this.sendRunId      = sendRunId;
        }

        public void execute(QueueableContext ctx) {
            try {
                // Payload keys match the Investment_Broadcast_Flow input variables EXACTLY.
                Map<String, Object> inputs = new Map<String, Object>{
                    'InvestmentNameInput' => investmentName,
                    'EmailChoiceInput'    => emailChoice,
                    'SendRunIdInput'      => sendRunId
                };
                Map<String, Object> body = new Map<String, Object>{
                    'inputs' => new List<Object>{ inputs }
                };

                HttpRequest httpReq = new HttpRequest();
                httpReq.setEndpoint('callout:OwnOrg/services/data/v62.0/actions/custom/flow/Investment_Broadcast_Flow');
                httpReq.setMethod('POST');
                httpReq.setHeader('Content-Type', 'application/json');
                httpReq.setBody(JSON.serialize(body));
                httpReq.setTimeout(120000); // 120s, the Apex maximum (default is 10s)

                HttpResponse res = new Http().send(httpReq);

                if (res.getStatusCode() == 200) {
                    System.debug(LoggingLevel.INFO,
                        'Broadcast initiated for ' + investmentName + '. Run: ' + sendRunId);
                } else {
                    System.debug(LoggingLevel.ERROR,
                        'Broadcast callout failed (' + res.getStatusCode() + ') Run: '
                        + sendRunId + ' Body: ' + res.getBody());
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Broadcast callout exception Run: ' + sendRunId + ' - ' + e.getMessage());
            }
        }
    }
}
