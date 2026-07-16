import { LightningElement, wire } from 'lwc';
import getMergeFields from '@salesforce/apex/SignatureRequestController.getMergeFields';
import { ENTRY_FIELDS, RECIPIENT_FIELDS, reduceError } from 'c/sigreqUtils';

const COLLAPSED_PER_GROUP = 4;

export default class SigreqFieldPalette extends LightningElement {
    mergeGroups = [];
    errorMessage = '';
    showAllMerge = false;

    entryFields = ENTRY_FIELDS.map((f) => ({
        ...f,
        key: f.entryKind,
        payload: JSON.stringify({ category: 'ENTRY', ...f })
    }));

    recipientFields = RECIPIENT_FIELDS.map((f) => ({
        ...f,
        key: f.recipientKind,
        payload: JSON.stringify({ category: 'RECIPIENT', ...f })
    }));

    @wire(getMergeFields)
    wiredMergeFields({ data, error }) {
        if (data) {
            this.mergeGroups = data;
            this.errorMessage = '';
        } else if (error) {
            this.errorMessage = reduceError(error);
        }
    }

    get decoratedMergeGroups() {
        return (this.mergeGroups || []).map((g) => {
            const all = (g.fields || []).map((f) => ({
                key: `${g.objectApiName}.${f.fieldApiName}`,
                label: f.label,
                payload: JSON.stringify({
                    category: 'MERGE',
                    objectApiName: g.objectApiName,
                    fieldApiName: f.fieldApiName,
                    label: f.label,
                    sizeKey: 'TEXT'
                })
            }));
            return {
                objectApiName: g.objectApiName,
                objectLabel: g.objectLabel,
                fields: this.showAllMerge ? all : all.slice(0, COLLAPSED_PER_GROUP),
                truncated: !this.showAllMerge && all.length > COLLAPSED_PER_GROUP
            };
        });
    }

    get toggleLabel() {
        return this.showAllMerge ? 'Show Less' : 'Show All';
    }

    handleToggleMerge() {
        this.showAllMerge = !this.showAllMerge;
    }

    handleDragStart(event) {
        event.dataTransfer.setData('text/plain', event.currentTarget.dataset.payload);
        event.dataTransfer.effectAllowed = 'copy';
    }
}
