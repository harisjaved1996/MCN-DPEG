/**
 * Controller for the "Send Email With LWC" quick action (sendInvestmentEmailModal).
 *
 * This is a NEW, standalone controller so the existing Screen Flow path
 * (Send_Investment_Email_Button -> InvestmentEmailSender) is never touched.
 * It reproduces exactly what the flow does:
 *   1) resolve the investor Contacts via position__c -> Investing_Entity__c -> Contact
 *   2) record per-send Send_Exclusion__c rows for the deselected contacts
 *   3) fire the Marketing Cloud Broadcast Flow callout
 *
 * For the callout it REUSES the proven InvestmentEmailSender.BroadcastCalloutJob
 * Queueable (a public inner class) — so the broadcast behaves identically and
 * that class remains unmodified.
 */
public with sharing class InvestmentEmailController {

    /** Simple wire-friendly shape for the modal. */
    public class InvestorData {
        @AuraEnabled public String investmentName;
        @AuraEnabled public List<Investor> investors;
    }

    public class Investor {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String email;
    }

    /**
     * Returns the Investment name plus the distinct list of investor Contacts,
     * walking the same chain the flow uses:
     * Investment <- position__c -> Investing_Entity__c -> Contact.
     */
    @AuraEnabled(cacheable=true)
    public static InvestorData getInvestors(Id recordId) {
        InvestorData data = new InvestorData();
        data.investors = new List<Investor>();

        Investment__c inv = [
            SELECT Id, Name FROM Investment__c WHERE Id = :recordId LIMIT 1
        ];
        data.investmentName = inv.Name;

        // position__c -> Investing_Entity__c ids
        Set<Id> entityIds = new Set<Id>();
        for (position__c p : [
            SELECT Investing_Entity__c
            FROM position__c
            WHERE Investment__c = :recordId AND Investing_Entity__c != NULL
        ]) {
            entityIds.add(p.Investing_Entity__c);
        }

        if (entityIds.isEmpty()) {
            return data;
        }

        // Investing_Entity__c -> Contact ids
        Set<Id> contactIds = new Set<Id>();
        for (Investing_Entity__c e : [
            SELECT Contact__c
            FROM Investing_Entity__c
            WHERE Id IN :entityIds AND Contact__c != NULL
        ]) {
            contactIds.add(e.Contact__c);
        }

        if (contactIds.isEmpty()) {
            return data;
        }

        // Resolve Contact details
        for (Contact c : [
            SELECT Id, Name, Email
            FROM Contact
            WHERE Id IN :contactIds
            ORDER BY Name
        ]) {
            Investor i = new Investor();
            i.id = c.Id;
            i.name = c.Name;
            i.email = c.Email;
            data.investors.add(i);
        }

        return data;
    }

    /**
     * Records the deselected contacts as Send_Exclusion__c rows and queues the
     * broadcast callout. Mirrors InvestmentEmailSender.send but callable from LWC.
     *
     * Fail closed: if the exclusion insert throws, we never queue the callout.
     *
     * @return the statusMessage (same style as the flow), including the Run id.
     */
    @AuraEnabled
    public static String sendEmail(
            Id recordId,
            String investmentName,
            String emailChoice,
            List<Id> deselectedContactIds) {

        if (String.isBlank(emailChoice)) {
            throw new AuraHandledException('Please choose an email type before sending.');
        }

        // One unique id per send run (audit trail; never reused).
        String sendRunId = UUID.randomUUID().toString();

        try {
            if (deselectedContactIds != null && !deselectedContactIds.isEmpty()) {
                List<Send_Exclusion__c> exclusions = new List<Send_Exclusion__c>();
                for (Id contactId : deselectedContactIds) {
                    exclusions.add(new Send_Exclusion__c(
                        Contact__c     = contactId,
                        Investment__c  = recordId,
                        Send_Run_Id__c = sendRunId
                    ));
                }
                insert exclusions; // single bulk DML
            }

            // Callout in a separate transaction (avoids "uncommitted work pending").
            // Reuses the existing, proven Queueable — no change to InvestmentEmailSender.
            System.enqueueJob(new InvestmentEmailSender.BroadcastCalloutJob(
                investmentName, emailChoice, sendRunId
            ));

            return 'SUCCESS: Email send queued for ' + investmentName + '. Run: ' + sendRunId;
        } catch (Exception e) {
            // Nothing was queued — surface the failure to the LWC.
            throw new AuraHandledException(
                'Could not record exclusions, so no email was sent: ' + e.getMessage());
        }
    }
}
