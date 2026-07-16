import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getMasterDocuments from '@salesforce/apex/SignatureRequestController.getMasterDocuments';
import { reduceError } from 'c/sigreqUtils';

/**
 * Master documents sent from this investment, with sent/opened/completed
 * metrics. Clicking a name opens the master document record (copies +
 * statuses live there); the file icon previews the master document itself.
 */
export default class SigreqMasterDocuments extends NavigationMixin(LightningElement) {
    @api recordId;

    masters = [];
    isLoading = true;
    errorMessage = '';

    connectedCallback() {
        this.load();
    }

    async load() {
        this.isLoading = true;
        this.errorMessage = '';
        try {
            const rows = await getMasterDocuments({ recordId: this.recordId });
            this.masters = rows.map((m) => ({
                ...m,
                sourceLabel: m.sourceType === 'TEMPLATE' ? 'DocuSign template' : 'Salesforce file',
                hasFile: !!m.contentDocumentId,
                hasFailures: (m.failedCount || 0) > 0
            }));
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    get hasMasters() {
        return this.masters.length > 0;
    }
    get showEmpty() {
        return !this.isLoading && !this.hasMasters && !this.errorMessage;
    }

    handleRefresh() {
        this.load();
    }

    handleOpenMaster(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: event.currentTarget.dataset.id,
                objectApiName: 'Master_Document__c',
                actionName: 'view'
            }
        });
    }

    handlePreviewFile(event) {
        event.stopPropagation();
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: event.currentTarget.dataset.docid }
        });
    }
}
