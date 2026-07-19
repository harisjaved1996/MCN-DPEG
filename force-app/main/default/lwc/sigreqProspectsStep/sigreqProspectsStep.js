import { LightningElement, api } from 'lwc';
import getProspects from '@salesforce/apex/SignatureRequestController.getProspects';
import { reduceError } from 'c/sigreqUtils';

const COLUMNS = [
    { label: 'Name', fieldName: 'name', type: 'text' },
    { label: 'Email', fieldName: 'email', type: 'email' },
    { label: 'Phone', fieldName: 'phone', type: 'phone' },
    { label: 'Investing Entity', fieldName: 'entityName', type: 'text' },
    { label: 'Entity Type', fieldName: 'entityType', type: 'text' },
    { label: 'Primary', fieldName: 'isPrimary', type: 'boolean', initialWidth: 90 },
    { label: 'Required Signer', fieldName: 'isRequiredSigner', type: 'boolean', initialWidth: 120 }
];

/**
 * Step 3: investors associated (via Associated Contacts) to any investing
 * entity holding a position in this investment. One row per association —
 * an entity's investors share ONE envelope; the primary fills the input
 * fields, required signers sign, the rest receive a view-only copy.
 */
export default class SigreqProspectsStep extends LightningElement {
    @api recordId;
    @api selectedAssociationIds = [];

    columns = COLUMNS;
    prospects = [];
    investmentName = '';
    skippedNoEmailCount = 0;
    selectedRowIds = [];
    isLoading = true;
    errorMessage = '';

    connectedCallback() {
        this.load();
    }

    async load() {
        this.isLoading = true;
        this.errorMessage = '';
        try {
            const result = await getProspects({ recordId: this.recordId });
            this.prospects = result.prospects || [];
            this.investmentName = result.investmentName;
            this.skippedNoEmailCount = result.skippedNoEmailCount || 0;

            // Everyone pre-selected by default; keep an earlier selection when
            // the user navigates back to this step.
            const previous = (this.selectedAssociationIds || []).filter((id) =>
                this.prospects.some((p) => p.associationId === id)
            );
            this.selectedRowIds =
                previous.length > 0 ? previous : this.prospects.map((p) => p.associationId);
            this.emitSelection(this.selectedRowIds);
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    get headline() {
        return `Investors of ${this.investmentName || 'this investment'}`;
    }
    get counter() {
        return `${this.selectedRowIds.length} of ${this.prospects.length} selected`;
    }
    get hasProspects() {
        return this.prospects.length > 0;
    }
    get showEmpty() {
        return !this.isLoading && !this.hasProspects && !this.errorMessage;
    }
    get showSkipped() {
        return this.skippedNoEmailCount > 0;
    }
    get skippedNote() {
        return `${this.skippedNoEmailCount} associated investor(s) hidden because they have no email address.`;
    }

    handleRowSelection(event) {
        const ids = event.detail.selectedRows.map((row) => row.associationId);
        this.selectedRowIds = ids;
        this.emitSelection(ids);
    }

    emitSelection(ids) {
        this.dispatchEvent(
            new CustomEvent('selectionchange', {
                detail: { selectedAssociationIds: ids, prospects: this.prospects }
            })
        );
    }
}
