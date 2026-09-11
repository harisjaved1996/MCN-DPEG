/**
 * Tests for OfferingEmailSender.
 *
 * Deliberately self-contained — it builds its own data rather than calling TestDataFactory, because
 * TestDataFactory references a large slice of the DPEG schema that is not present in every org this
 * class deploys to, and a shared factory dependency would make this class undeployable wherever that
 * schema is missing.
 *
 * HOW THE SEND PATH IS ASSERTED. Messaging.sendEmail neither delivers nor exposes the built messages in
 * a test context, so there is no way to read back a rendered subject or body. The send path is therefore
 * asserted on the EmailInvocations governor counter — 1 proves a send happened and was batched, 0 proves
 * a guard clause skipped it — while the rendering itself is asserted directly against the two public
 * token methods, which are pure functions. Between them every branch is covered without a test-only
 * backdoor into the class.
 */
@IsTest
private class OfferingEmailSenderTest {
    private static final String OFFERING_NAME = 'Riverside Plaza Retail Center';

    /**
     * A real User row is unnecessary — setTargetObjectId only needs a valid Id, and the in-memory record
     * carries FirstName for the token substitution. Reusing the running user's Id keeps these tests free
     * of User-creation permissions and of the org's licence availability.
     */
    private static User buildRecipient(String firstName) {
        return new User(Id = UserInfo.getUserId(), FirstName = firstName);
    }

    private static OfferingEmailSender.Request buildRequest(List<User> recipients, String subject, String body) {
        OfferingEmailSender.Request request = new OfferingEmailSender.Request();
        request.recipients = recipients;
        request.subject = subject;
        request.htmlBody = body;
        return request;
    }

    private static Integer sendAndCountInvocations(List<OfferingEmailSender.Request> requests) {
        Test.startTest();
        OfferingEmailSender.send(requests);
        Integer invocations = Limits.getEmailInvocations();
        Test.stopTest();
        return invocations;
    }

    // ---------------------------------------------------------------------------------------------
    // Send path
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void sendsWhenSubjectAndBodyArePassedInline() {
        OfferingEmailSender.Request request = buildRequest(
            new List<User>{ buildRecipient('Haris') },
            'New Offering awaiting review: %%RECORDNAME%%',
            '<p>Hi %%FIRSTNAME%%,</p><p>An Offering is waiting.</p>'
        );
        request.recordName = OFFERING_NAME;

        Integer invocations = sendAndCountInvocations(
            new List<OfferingEmailSender.Request>{ request }
        );

        System.assertEquals(1, invocations, 'Inline subject and body must produce exactly one send.');
    }

    @IsTest
    static void batchesEveryRecipientIntoASingleInvocation() {
        // The governor allows only 10 sendEmail calls per transaction, so the class must batch. A queue
        // with more than 10 members is the realistic case this protects.
        List<User> recipients = new List<User>();
        for (Integer i = 0; i < 25; i++) {
            recipients.add(buildRecipient('Member' + i));
        }

        Integer invocations = sendAndCountInvocations(
            new List<OfferingEmailSender.Request>{
                buildRequest(recipients, 'Subject', '<p>Hi %%FIRSTNAME%%,</p>')
            }
        );

        System.assertEquals(1, invocations, '25 recipients must still be one sendEmail invocation, not 25.');
    }

    @IsTest
    static void batchesMultipleRequestsIntoASingleInvocation() {
        List<OfferingEmailSender.Request> requests = new List<OfferingEmailSender.Request>{
            buildRequest(new List<User>{ buildRecipient('Haris') }, 'First', '<p>One</p>'),
            buildRequest(new List<User>{ buildRecipient('Ali') }, 'Second', '<p>Two</p>')
        };

        Integer invocations = sendAndCountInvocations(requests);

        System.assertEquals(1, invocations, 'Separate requests must still collapse into one send.');
    }

    @IsTest
    static void sendsUsingTheStoredTemplateWhenDeveloperNameIsGiven() {
        EmailTemplate stored = insertTemplate(
            'New Offering awaiting review: %%RECORDNAME%%',
            '<h1>%%RECORDNAME%%</h1><p>Hi %%FIRSTNAME%%,</p><a href="%%BASEURL%%/%%RECORDID%%">Review</a>'
        );

        OfferingEmailSender.Request request = buildRequest(
            new List<User>{ buildRecipient('Haris') }, null, null
        );
        request.templateDeveloperName = stored.DeveloperName;
        request.recordId = UserInfo.getUserId();
        request.recordName = OFFERING_NAME;

        Integer invocations = sendAndCountInvocations(
            new List<OfferingEmailSender.Request>{ request }
        );

        System.assertEquals(
            1, invocations,
            'A request naming an existing template must send, with Subject and HtmlValue taken from it.'
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Guard clauses — every one of these must skip quietly rather than throw, because an exception here
    // would roll back the record save of the flow that called us.
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void toleratesNullAndEmptyInput() {
        Test.startTest();
        OfferingEmailSender.send(null);
        OfferingEmailSender.send(new List<OfferingEmailSender.Request>());
        Integer invocations = Limits.getEmailInvocations();
        Test.stopTest();

        System.assertEquals(0, invocations, 'Null or empty input must be a no-op, not an exception.');
    }

    @IsTest
    static void skipsRequestsWithNoUsableRecipients() {
        List<OfferingEmailSender.Request> requests = new List<OfferingEmailSender.Request>{
            null,
            buildRequest(null, 'Subject', '<p>Body</p>'),
            buildRequest(new List<User>(), 'Subject', '<p>Body</p>')
        };

        Integer invocations = sendAndCountInvocations(requests);

        System.assertEquals(0, invocations, 'A request with no recipients must not trigger a send.');
    }

    @IsTest
    static void skipsRequestsWithBlankSubjectOrBody() {
        List<OfferingEmailSender.Request> requests = new List<OfferingEmailSender.Request>{
            buildRequest(new List<User>{ buildRecipient('Haris') }, '', '<p>Body</p>'),
            buildRequest(new List<User>{ buildRecipient('Haris') }, 'Subject', null)
        };

        Integer invocations = sendAndCountInvocations(requests);

        System.assertEquals(0, invocations, 'A blank subject or body must not trigger a send.');
    }

    @IsTest
    static void skipsRecipientsWithoutAnId() {
        // A Flow collection can contain a User variable that was never populated.
        List<User> recipients = new List<User>{ null, new User(FirstName = 'No Id') };

        Integer invocations = sendAndCountInvocations(
            new List<OfferingEmailSender.Request>{
                buildRequest(recipients, 'Subject', '<p>Hi %%FIRSTNAME%%,</p>')
            }
        );

        System.assertEquals(0, invocations, 'Recipients without an Id must be skipped, leaving nothing to send.');
    }

    @IsTest
    static void skipsSendWhenNamedTemplateIsMissing() {
        // The realistic cause is deploying the metadata to a new org without running
        // load-lightning-email-templates.apex. This must not throw.
        OfferingEmailSender.Request request = buildRequest(
            new List<User>{ buildRecipient('Haris') }, null, null
        );
        request.templateDeveloperName = 'Template_That_Does_Not_Exist_' + String.valueOf(Crypto.getRandomInteger());
        request.recordName = OFFERING_NAME;

        Integer invocations = sendAndCountInvocations(
            new List<OfferingEmailSender.Request>{ request }
        );

        System.assertEquals(0, invocations, 'A missing template must skip the send, not throw.');
    }

    // ---------------------------------------------------------------------------------------------
    // Token merging — asserted directly, since a built message cannot be read back in a test context.
    // ---------------------------------------------------------------------------------------------

    @IsTest
    static void mergesEveryRecordToken() {
        String merged = OfferingEmailSender.applyRecordTokens(
            '<h1>%%RECORDNAME%%</h1><a href="%%BASEURL%%/%%RECORDID%%">Review %%RECORDNAME%%</a>',
            OFFERING_NAME,
            'a31Hn000003BwMpIAK',
            'https://example.my.salesforce.com'
        );

        System.assertEquals(
            '<h1>Riverside Plaza Retail Center</h1>' +
            '<a href="https://example.my.salesforce.com/a31Hn000003BwMpIAK">Review Riverside Plaza Retail Center</a>',
            merged,
            'Every record token must be merged, including a token that appears more than once.'
        );
    }

    @IsTest
    static void mergesTheRecordNameIntoASubject() {
        // A subject carries only %%RECORDNAME%%, so it runs one replace rather than the body's three.
        String merged = OfferingEmailSender.applyRecordName(
            'New Offering awaiting review: %%RECORDNAME%%', OFFERING_NAME
        );

        System.assertEquals(
            'New Offering awaiting review: Riverside Plaza Retail Center',
            merged,
            'The record name must be merged into the subject.'
        );
    }

    @IsTest
    static void leavesBodyOnlyTokensAloneInASubject() {
        // Documents the deliberate limit: %%RECORDID%% and %%BASEURL%% exist to build a link, which a
        // subject cannot carry. If this assert ever needs to change, the class header table changes too.
        String merged = OfferingEmailSender.applyRecordName(
            '%%RECORDNAME%% (%%RECORDID%%) %%BASEURL%%', OFFERING_NAME
        );

        System.assertEquals(
            'Riverside Plaza Retail Center (%%RECORDID%%) %%BASEURL%%',
            merged,
            'A subject must merge the name only — the link tokens are body-only by design.'
        );
    }

    @IsTest
    static void mergesNullRecordNameAsEmptyText() {
        System.assertEquals(
            'Offering: ',
            OfferingEmailSender.applyRecordName('Offering: %%RECORDNAME%%', null),
            'A null record name must merge as empty text, never the literal word "null".'
        );
    }

    @IsTest
    static void mergesNullRecordValuesAsEmptyText() {
        String merged = OfferingEmailSender.applyRecordTokens(
            'Name[%%RECORDNAME%%] Id[%%RECORDID%%] Url[%%BASEURL%%]', null, null, null
        );

        System.assertEquals(
            'Name[] Id[] Url[]', merged,
            'A null value must merge as empty text — never the literal word "null" in an inbox.'
        );
    }

    @IsTest
    static void leavesRecipientTokenForTheRecipientLoop() {
        String merged = OfferingEmailSender.applyRecordTokens(
            '<p>Hi %%FIRSTNAME%%,</p><p>%%RECORDNAME%%</p>', OFFERING_NAME, null, null
        );

        System.assert(
            merged.contains('%%FIRSTNAME%%'),
            '%%FIRSTNAME%% must survive record merging so it can be resolved per recipient.'
        );
    }

    @IsTest
    static void mergesRecipientFirstName() {
        String merged = OfferingEmailSender.applyRecipientTokens('<p>Hi %%FIRSTNAME%%,</p>', 'Haris');

        System.assertEquals('<p>Hi Haris,</p>', merged, 'The recipient first name must be merged.');
    }

    @IsTest
    static void fallsBackToAFriendlyGreetingWhenFirstNameIsMissing() {
        System.assertEquals(
            '<p>Hi there,</p>',
            OfferingEmailSender.applyRecipientTokens('<p>Hi %%FIRSTNAME%%,</p>', null),
            'A null first name must greet the recipient rather than read "Hi ,".'
        );
        System.assertEquals(
            '<p>Hi there,</p>',
            OfferingEmailSender.applyRecipientTokens('<p>Hi %%FIRSTNAME%%,</p>', '   '),
            'A whitespace-only first name must be treated the same as a missing one.'
        );
    }

    @IsTest
    static void returnsBlankTextUntouched() {
        System.assertEquals(null, OfferingEmailSender.applyRecordName(null, 'A'));
        System.assertEquals('', OfferingEmailSender.applyRecordName('', 'A'));
        System.assertEquals(null, OfferingEmailSender.applyRecordTokens(null, 'A', 'B', 'C'));
        System.assertEquals('', OfferingEmailSender.applyRecordTokens('', 'A', 'B', 'C'));
        System.assertEquals(null, OfferingEmailSender.applyRecipientTokens(null, 'Haris'));
        System.assertEquals('', OfferingEmailSender.applyRecipientTokens('', 'Haris'));
    }

    // ---------------------------------------------------------------------------------------------

    /**
     * Creates a Lightning (SFX) template in the running user's personal folder — a User Id is a valid
     * FolderId for that folder, which avoids needing an org Email folder to exist in the test context.
     * The DeveloperName is randomised because EmailTemplate.DeveloperName is unique org-wide.
     */
    private static EmailTemplate insertTemplate(String subject, String htmlValue) {
        EmailTemplate stored = new EmailTemplate(
            Name = 'Offering Email Sender Test Template',
            DeveloperName = 'Offering_Email_Sender_Test_' + String.valueOf(Crypto.getRandomInteger()).replace('-', 'x'),
            FolderId = UserInfo.getUserId(),
            TemplateType = 'custom',
            UiType = 'SFX',
            TemplateStyle = 'none',
            Subject = subject,
            HtmlValue = htmlValue,
            Encoding = 'UTF-8',
            IsActive = true
        );
        insert stored;
        return stored;
    }
}
