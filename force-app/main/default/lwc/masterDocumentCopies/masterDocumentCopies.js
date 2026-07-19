import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import CONTENT_DOCUMENT_ID_FIELD from '@salesforce/schema/Master_Document__c.Content_Document_Id__c';
import SOURCE_TYPE_FIELD from '@salesforce/schema/Master_Document__c.Source_Type__c';
import getCopies from '@salesforce/apex/SignatureRequestController.getCopies';
import refreshStatuses from '@salesforce/apex/SignatureRequestController.refreshStatuses';
import getCopyViewUrl from '@salesforce/apex/SignatureRequestController.getCopyViewUrl';
import resetAndResend from '@salesforce/apex/SignatureRequestController.resetAndResend';
import { reduceError } from 'c/sigreqUtils';

const DONE_STATUSES = new Set(['completed']);
const BAD_STATUSES = new Set(['declined', 'voided', 'failed']);

/**
 * Copies of a master document: which contact/investing entity received one,
 * its live DocuSign status, and per-copy actions (view in DocuSign,
 * reset & resend).
 */
export default class MasterDocumentCopies extends NavigationMixin(LightningElement) {
    @api recordId; // Master_Document__c id

    copies = [];
    isLoading = true;
    isRefreshing = false;
    errorMessage = '';
    confirmingCopyId = null;
    busyCopyId = null;

    @wire(getRecord, {
        recordId: '$recordId',
        fields: [CONTENT_DOCUMENT_ID_FIELD, SOURCE_TYPE_FIELD]
    })
    masterRecord;

    get masterContentDocumentId() {
        return getFieldValue(this.masterRecord.data, CONTENT_DOCUMENT_ID_FIELD);
    }
    get hasMasterFile() {
        return !!this.masterContentDocumentId;
    }
    get masterSourceType() {
        return getFieldValue(this.masterRecord.data, SOURCE_TYPE_FIELD);
    }

    connectedCallback() {
        this.load();
    }

    async load() {
        this.isLoading = true;
        this.errorMessage = '';
        try {
            const rows = await getCopies({ masterDocumentId: this.recordId });
            this.copies = rows;
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    get decoratedCopies() {
        return (this.copies || []).map((c) => {
            const statusLower = (c.status || '').toLowerCase();
            let badgeClass = 'slds-badge';
            if (DONE_STATUSES.has(statusLower)) {
                badgeClass += ' slds-theme_success';
            } else if (BAD_STATUSES.has(statusLower)) {
                badgeClass += ' slds-theme_error';
            } else if (statusLower === 'reset') {
                badgeClass += ' slds-badge_inverse';
            }
            let roleLabel;
            if (c.isPrimary) {
                roleLabel = 'Primary';
            } else if (c.recipientRole === 'Viewer') {
                roleLabel = 'Viewer';
            } else if (c.isRequiredSigner) {
                roleLabel = 'Signer';
            } else {
                roleLabel = c.recipientRole || '';
            }
            return {
                ...c,
                badgeClass,
                roleLabel,
                confirming: c.id === this.confirmingCopyId,
                busy: c.id === this.busyCopyId,
                rowClass: statusLower === 'reset' ? 'copy-row copy-row_reset' : 'copy-row'
            };
        });
    }

    get hasCopies() {
        return this.copies.length > 0;
    }
    get showEmpty() {
        return !this.isLoading && !this.hasCopies && !this.errorMessage;
    }

    // ---------- actions ----------
    async handleRefresh() {
        this.isRefreshing = true;
        this.errorMessage = '';
        try {
            this.copies = await refreshStatuses({ masterDocumentId: this.recordId });
            this.toast('Statuses refreshed', 'Latest DocuSign statuses loaded.', 'success');
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.isRefreshing = false;
        }
    }

    handleViewMaster() {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: this.masterContentDocumentId }
        });
    }

    async handleView(event) {
        const copyId = event.currentTarget.dataset.id;
        this.busyCopyId = copyId;
        // Open the tab synchronously (inside the click gesture) so popup
        // blockers allow it; point it at the DocuSign URL once it arrives.
        const docuSignWindow = window.open('about:blank', '_blank');
        try {
            const url = await getCopyViewUrl({ copyId });
            if (docuSignWindow) {
                docuSignWindow.location.href = url;
            } else {
                window.open(url, '_blank');
            }
        } catch (error) {
            if (docuSignWindow) {
                docuSignWindow.close();
            }
            this.toast('Could not open document', reduceError(error), 'error');
        } finally {
            this.busyCopyId = null;
        }
    }

    handleResetClick(event) {
        this.confirmingCopyId = event.currentTarget.dataset.id;
    }

    handleResetCancel() {
        this.confirmingCopyId = null;
    }

    async handleResetConfirm(event) {
        const copyId = event.currentTarget.dataset.id;
        this.confirmingCopyId = null;
        this.busyCopyId = copyId;
        try {
            await resetAndResend({ copyId });
            this.toast(
                'Copy reset',
                'The old envelope was voided (when possible) and a fresh copy is being sent.',
                'success'
            );
            await this.load();
        } catch (error) {
            this.toast('Reset failed', reduceError(error), 'error');
        } finally {
            this.busyCopyId = null;
        }
    }

    handleOpenContact(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: event.currentTarget.dataset.id,
                objectApiName: 'Contact',
                actionName: 'view'
            }
        });
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
