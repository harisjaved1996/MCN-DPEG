import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import send from '@salesforce/apex/SignatureRequestController.send';
import { reduceError } from 'c/sigreqUtils';

const STEPS = [
    { value: '1', label: 'Documents' },
    { value: '2', label: 'Review + Add Fields' },
    { value: '3', label: 'Prospects' },
    { value: '4', label: 'Confirm' }
];

export default class AddSignatureRequest extends NavigationMixin(LightningElement) {
    @api recordId;

    steps = STEPS;
    step = 1;

    // wizard state (single source of truth)
    document = null;        // { sourceType, contentVersionId, contentDocumentId, templateId, name, pageCount, lastPageWidth, lastPageHeight }
    fields = [];            // PlacedField[] in PDF points
    prospects = [];         // association rows from getProspects
    selectedAssociationIds = [];
    emailSubject = '';
    emailMessage = '';

    isSending = false;
    sendReceipt = null;     // { asyncJobId, plannedCount }
    errorMessage = '';

    // ---------- step visibility ----------
    get currentStep() {
        return String(this.step);
    }
    get isStep1() {
        return this.step === 1 && !this.sendReceipt;
    }
    get isStep2() {
        return this.step === 2 && !this.sendReceipt;
    }
    get isStep3() {
        return this.step === 3 && !this.sendReceipt;
    }
    get isStep4() {
        return this.step === 4 && !this.sendReceipt;
    }
    get isDone() {
        return !!this.sendReceipt;
    }

    get showBack() {
        return this.step > 1 && !this.sendReceipt;
    }
    get showNext() {
        return this.step < 4 && !this.sendReceipt;
    }
    get nextDisabled() {
        if (this.step === 1) {
            return !this.document;
        }
        if (this.step === 3) {
            return this.selectedAssociationIds.length === 0;
        }
        return false;
    }

    get doneMessage() {
        const n = this.sendReceipt ? this.sendReceipt.plannedCount : 0;
        return `${n} signature request${n === 1 ? '' : 's'} queued for sending via DocuSign.`;
    }

    // ---------- child events ----------
    handleDocumentChange(event) {
        const previous = this.document;
        this.document = event.detail.document;
        // A different master document invalidates placed fields.
        if (
            previous &&
            this.document &&
            (previous.contentVersionId !== this.document.contentVersionId ||
                previous.templateId !== this.document.templateId)
        ) {
            this.fields = [];
        }
        if (this.document && !this.emailSubject) {
            this.emailSubject = `Signature requested: ${this.document.name || ''}`.trim();
        }
    }

    handleFieldsChange(event) {
        this.fields = event.detail.fields;
    }

    handleDocMeta(event) {
        if (this.document) {
            const { pageCount, lastPageWidth, lastPageHeight } = event.detail;
            this.document = { ...this.document, pageCount, lastPageWidth, lastPageHeight };
        }
    }

    handleSelectionChange(event) {
        this.selectedAssociationIds = event.detail.selectedAssociationIds;
        this.prospects = event.detail.prospects || this.prospects;
    }

    handleMetaChange(event) {
        const { emailSubject, emailMessage } = event.detail;
        if (emailSubject !== undefined) {
            this.emailSubject = emailSubject;
        }
        if (emailMessage !== undefined) {
            this.emailMessage = emailMessage;
        }
    }

    // ---------- navigation ----------
    handleBack() {
        if (this.step > 1) {
            this.step -= 1;
        }
    }

    handleNext() {
        if (this.step < 4) {
            this.step += 1;
        }
    }

    // ---------- send ----------
    async handleSend() {
        this.isSending = true;
        this.errorMessage = '';
        try {
            const payload = {
                investmentId: this.recordId,
                emailSubject: this.emailSubject,
                emailMessage: this.emailMessage,
                document: this.document,
                fields: this.document && this.document.sourceType === 'FILE' ? this.fields : [],
                selectedAssociationIds: this.selectedAssociationIds
            };
            const receipt = await send({ requestJson: JSON.stringify(payload) });
            this.sendReceipt = receipt;
            this.toast(
                'Signature requests queued',
                `${receipt.plannedCount} entity envelope(s) queued. You will get a notification when sending completes.`,
                'success'
            );
            (receipt.warnings || []).forEach((w) => this.toast('Heads up', w, 'warning'));
        } catch (error) {
            this.errorMessage = reduceError(error);
            this.toast('Send failed', this.errorMessage, 'error');
        } finally {
            this.isSending = false;
        }
    }

    handleViewMaster() {
        if (this.sendReceipt && this.sendReceipt.masterDocumentId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.sendReceipt.masterDocumentId,
                    objectApiName: 'Master_Document__c',
                    actionName: 'view'
                }
            });
        }
    }

    handleStartOver() {
        this.step = 1;
        this.document = null;
        this.fields = [];
        this.selectedAssociationIds = [];
        this.emailSubject = '';
        this.emailMessage = '';
        this.sendReceipt = null;
        this.errorMessage = '';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
