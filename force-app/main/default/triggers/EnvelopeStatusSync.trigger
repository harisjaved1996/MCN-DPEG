/**
 * Mirrors DocuSign envelope status updates (written by the dfsle package via
 * DocuSign Connect or StatusService polling) onto Document_Copy__c tracking
 * records and recalculates the master document metrics.
 */
trigger EnvelopeStatusSync on dfsle__EnvelopeStatus__c (after insert, after update) {
    SignatureRequestTracking.syncStatuses(Trigger.new);
}
