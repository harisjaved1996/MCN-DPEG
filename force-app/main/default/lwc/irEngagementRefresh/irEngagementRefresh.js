import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';

import refreshMetrics from '@salesforce/apex/NewOfferingLaunchController.refreshMetrics';

/**
 * Refreshes Data Cloud engagement for an IR broadcast Communication.
 *
 * Separate from the Send Campaign Email path's Refresh Metrics action, which
 * correlates engagement by message id. A broadcast flow returns no message id,
 * so this one goes through NewOfferingLaunchTracking, which claims engagement
 * by flow run id instead.
 */
export default class IrEngagementRefresh extends LightningElement {
    @api recordId;

    connectedCallback() {
        this.run();
    }

    async run() {
        try {
            const message = await refreshMetrics({ communicationId: this.recordId });
            // Repaint the record page so the new counters show without a reload.
            getRecordNotifyChange([{ recordId: this.recordId }]);
            this.toast('Engagement refreshed', message, 'success');
        } catch (e) {
            this.toast(
                'Could not refresh engagement',
                e?.body?.message || e?.message || 'Unexpected error.',
                'error'
            );
        } finally {
            this.dispatchEvent(new CloseActionScreenEvent());
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
