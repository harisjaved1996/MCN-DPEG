import { LightningElement, api, wire } from 'lwc';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import INVESTING_ENTITY_OBJECT from '@salesforce/schema/Investing_Entity__c';
import ENTITY_TYPE_FIELD from '@salesforce/schema/Investing_Entity__c.Entity_Type__c';

/**
 * "Specify Entity Types" modal: restricts a placed merge field to selected
 * Investing Entity types. An empty selection (= "All Entities") means the
 * field is visible on every recipient's copy.
 */
export default class SigreqEntityTypesModal extends LightningElement {
    @api clientId;

    _selected = new Set();
    picklistValues = [];
    loadError = false;

    @api
    get selected() {
        return [...this._selected];
    }
    set selected(value) {
        this._selected = new Set(value || []);
    }

    @wire(getObjectInfo, { objectApiName: INVESTING_ENTITY_OBJECT })
    objectInfo;

    @wire(getPicklistValues, {
        recordTypeId: '$objectInfo.data.defaultRecordTypeId',
        fieldApiName: ENTITY_TYPE_FIELD
    })
    wiredPicklist({ data, error }) {
        if (data) {
            this.picklistValues = data.values.map((v) => v.value);
        } else if (error) {
            this.loadError = true;
        }
    }

    get allChecked() {
        return this._selected.size === 0;
    }

    get rows() {
        return this.picklistValues.map((value) => ({
            value,
            checked: this._selected.has(value)
        }));
    }

    handleAllChange(event) {
        if (event.target.checked) {
            this._selected = new Set();
        }
    }

    handleTypeChange(event) {
        const value = event.target.dataset.value;
        const next = new Set(this._selected);
        if (event.target.checked) {
            next.add(value);
        } else {
            next.delete(value);
        }
        this._selected = next;
    }

    handleSave() {
        this.dispatchEvent(
            new CustomEvent('save', {
                detail: { clientId: this.clientId, entityTypes: [...this._selected] }
            })
        );
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }
}
