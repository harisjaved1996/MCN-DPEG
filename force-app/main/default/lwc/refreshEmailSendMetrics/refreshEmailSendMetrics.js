import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import refreshEmailSend from '@salesforce/apex/InvestmentEmailController.refreshEmailSend';

/**
 * Headless "Refresh Metrics" quick action on Email_Send__c: pulls the latest
 * engagement from Data Cloud into the record and its recipient rows.
 */
export default class RefreshEmailSendMetrics extends LightningElement {
    @api recordId;
    running = false;

    @api async invoke() {
        if (this.running) {
            return;
        }
        this.running = true;
        try {
            const message = await refreshEmailSend({ emailSendId: this.recordId });
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Refresh Metrics',
                    message,
                    variant: message.includes('No engagement data') ? 'info' : 'success'
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
