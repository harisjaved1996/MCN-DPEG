/**
 * Thin client over the Marketing Cloud Next Direct Email Send API.
 *
 *   POST {base}/messaging/email/v1/bulk?sendDefinitionId=...      send to many
 *   POST {base}/messaging/email/v1/preview?sendDefinitionId=...   render only
 *
 * Behaviour the API reference does not spell out, established by probing the
 * live endpoint:
 *
 *  - The envelope is HTTP 200 even when every recipient failed. Callers must
 *    read status per recipient, never the HTTP code alone.
 *  - "to" is mandatory. individualId alone yields MISSING_TO_ADDRESS.
 *  - individualId is mandatory but never validated. It only drives engagement
 *    correlation; consent is evaluated against the "to" address.
 *  - 5000 recipients per call succeed in roughly 18s. 10000 returns 503.
 *  - The token must be a JWT carrying the sfap_api scope, and the token request
 *    must NOT include a scope parameter ("scope parameter not supported").
 */
public with sharing class DirectEmailSendService {

    /** One recipient of a bulk send. */
    public class Recipient {
        public String individualId;   // bare Data Cloud individual id; prefix added on serialise
        public String emailAddress;
        public Recipient(String individualId, String emailAddress) {
            this.individualId = individualId;
            this.emailAddress = emailAddress;
        }
    }

    /** Outcome for a single recipient, parsed out of the response array. */
    public class SendResult {
        public String individualId;   // bare id, prefix stripped
        public String emailAddress;
        public String messageId;
        public String deliveryId;
        public String requestId;
        public Boolean isSuccess;
        public Boolean isConsentBlocked;
        public String reason;
    }

    public class DirectSendException extends Exception {}

    // ------------------------------------------------------------------ auth

    @TestVisible private static String cachedToken;

    /**
     * Client-credentials token. Deliberately omits the scope parameter, which
     * this flow rejects outright.
     */
    @TestVisible
    private static String getAccessToken() {
        if (cachedToken != null) {
            return cachedToken;
        }

        // Without this guard a blank key or secret reaches EncodingUtil.urlEncode
        // and surfaces in the UI as "Argument cannot be null", which tells the
        // admin nothing about what is actually missing.
        List<String> missing = new List<String>();
        if (String.isBlank(MarketingSendSettings.consumerKey())) {
            missing.add('Consumer Key');
        }
        if (String.isBlank(MarketingSendSettings.consumerSecret())) {
            missing.add('Consumer Secret');
        }
        if (String.isBlank(MarketingSendSettings.tokenEndpoint())) {
            missing.add('Token Endpoint');
        }
        if (!missing.isEmpty()) {
            throw new DirectSendException(
                String.join(missing, ' and ') + ' is not set. Add it in Setup under '
                + 'Custom Metadata Types, Marketing Send Setting, the Default record.');
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint(MarketingSendSettings.tokenEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setTimeout(120000);
        req.setBody(
            'grant_type=client_credentials'
            + '&client_id=' + EncodingUtil.urlEncode(MarketingSendSettings.consumerKey(), 'UTF-8')
            + '&client_secret=' + EncodingUtil.urlEncode(MarketingSendSettings.consumerSecret(), 'UTF-8')
        );

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new DirectSendException(
                'Could not obtain an access token (HTTP ' + res.getStatusCode() + '): ' + res.getBody());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        cachedToken = (String) body.get('access_token');
        if (String.isBlank(cachedToken)) {
            throw new DirectSendException('Token response contained no access_token.');
        }
        return cachedToken;
    }

    // ------------------------------------------------------------------ send

    /**
     * Sends one chunk. Callers keep the chunk at or below
     * MarketingSendSettings.chunkSize().
     */
    public static List<SendResult> sendBulk(String sendDefinitionId, List<Recipient> recipients) {
        if (recipients == null || recipients.isEmpty()) {
            return new List<SendResult>();
        }

        List<Object> payload = new List<Object>();
        for (Recipient r : recipients) {
            payload.add(new Map<String, Object>{
                'individualId' => 'Individual__dlm/' + r.individualId,
                'to' => r.emailAddress
            });
        }
        String body = JSON.serialize(new Map<String, Object>{ 'recipients' => payload });

        HttpResponse res = post(
            MarketingSendSettings.apiBaseUrl()
                + '/messaging/email/v1/bulk?sendDefinitionId=' + sendDefinitionId,
            body);

        return parseResults(res.getBody());
    }

    /** Renders the email without sending it, so a selection can be previewed. */
    public static Map<String, Object> preview(String sendDefinitionId, String individualId) {
        String body = JSON.serialize(new Map<String, Object>{
            'individualId' => 'Individual__dlm/' + individualId
        });
        HttpResponse res = post(
            MarketingSendSettings.apiBaseUrl()
                + '/messaging/email/v1/preview?sendDefinitionId=' + sendDefinitionId,
            body);

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Object response = parsed.get('response');
        return response instanceof Map<String, Object>
            ? (Map<String, Object>) response
            : parsed;
    }

    /**
     * Retries 429 and 5xx with exponential backoff, as the API guide asks. The
     * retry budget is small on purpose: Apex allows only 120s of cumulative
     * callout time per transaction and one 5000-recipient call already costs
     * roughly 18s of that.
     */
    private static HttpResponse post(String endpoint, String body) {
        Integer maxAttempts = 3;
        Integer backoffMs = 2000;
        HttpResponse last;

        for (Integer attempt = 1; attempt <= maxAttempts; attempt++) {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setMethod('POST');
            req.setHeader('Authorization', 'Bearer ' + getAccessToken());
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(120000);
            req.setBody(body);

            HttpResponse res = new Http().send(req);
            last = res;
            Integer code = res.getStatusCode();

            if (code == 200) {
                return res;
            }
            if (code == 401 && attempt < maxAttempts) {
                cachedToken = null;   // expired mid-run; retry with a fresh one
                continue;
            }
            if ((code == 429 || code >= 500) && attempt < maxAttempts) {
                pause(backoffMs);
                backoffMs = backoffMs * 2;
                continue;
            }
            throw new DirectSendException(
                'Direct Email Send API returned HTTP ' + code + ': ' + res.getBody());
        }

        // Retries exhausted on a retryable status.
        throw new DirectSendException(
            'Direct Email Send API did not succeed after ' + maxAttempts + ' attempts. Last status: '
            + (last == null ? 'no response' : String.valueOf(last.getStatusCode())));
    }

    /**
     * Apex has no sleep. Callout latency does not consume CPU time, so a short
     * spin is affordable against the 10s CPU ceiling. Kept deliberately brief.
     */
    private static void pause(Integer millis) {
        if (Test.isRunningTest()) {
            return;
        }
        Long target = System.currentTimeMillis() + millis;
        while (System.currentTimeMillis() < target) {
            // intentionally empty
        }
    }

    @TestVisible
    private static List<SendResult> parseResults(String responseBody) {
        List<SendResult> results = new List<SendResult>();
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        String requestId = (String) parsed.get('requestId');

        List<Object> recipients = (List<Object>) parsed.get('recipients');
        if (recipients == null) {
            return results;
        }

        for (Object o : recipients) {
            Map<String, Object> r = (Map<String, Object>) o;

            SendResult sr = new SendResult();
            sr.requestId = requestId;
            sr.emailAddress = (String) r.get('to');
            sr.messageId = (String) r.get('messageId');
            sr.individualId = stripPrefix((String) r.get('individualId'));

            Object props = r.get('properties');
            if (props instanceof Map<String, Object>) {
                sr.deliveryId = (String) ((Map<String, Object>) props).get('deliveryId');
            }

            sr.isSuccess = 'SUCCESS'.equalsIgnoreCase((String) r.get('status'));
            sr.reason = (String) r.get('reason');
            sr.isConsentBlocked = !sr.isSuccess
                && sr.reason != null
                && sr.reason.startsWith('CONSENT_NOT_GIVEN');

            results.add(sr);
        }
        return results;
    }

    private static String stripPrefix(String individualId) {
        if (String.isBlank(individualId)) {
            return null;
        }
        Integer slash = individualId.lastIndexOf('/');
        return slash >= 0 ? individualId.substring(slash + 1) : individualId;
    }
}
