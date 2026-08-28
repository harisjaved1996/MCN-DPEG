import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import refreshMetrics from '@salesforce/apex/OfferingEmailController.refreshMetrics';

/**
 * Headless "Refresh Metrics" quick action on Communication__c: pulls the latest
 * engagement from Data Cloud onto the record and its recipient rows.
 *
 * Implemented as a headless action with invoke() rather than a ScreenAction
 * driven from connectedCallback. The platform sets recordId before calling
 * invoke(), whereas connectedCallback can run before @api properties are
 * populated, which sent a null id to Apex and failed the refresh.
 */
export default class CommunicationMetricsRefresh extends LightningElement {
    @api recordId;
    running = false;

    @api async invoke() {
        if (this.running) {
            return;
        }
        this.running = true;
        try {
            const message = await refreshMetrics({ communicationId: this.recordId });
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Refresh Metrics',
                    message,
                    variant: message.includes('still running') ? 'info' : 'success'
                })
            );
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Refresh Metrics failed',
                    message: error?.body?.message || error?.message || 'Unknown error',
                    variant: 'error'
                })
            );
        } finally {
            this.running = false;
        }
    }
}
