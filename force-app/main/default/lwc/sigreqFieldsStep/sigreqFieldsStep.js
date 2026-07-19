import { LightningElement, api } from 'lwc';
import { newClientId } from 'c/sigreqUtils';

const COPY_OFFSET_POINTS = 12;

export default class SigreqFieldsStep extends LightningElement {
    @api document;
    @api fields = [];

    modalOpen = false;
    modalClientId = null;
    modalSelected = [];

    get isTemplate() {
        return this.document && this.document.sourceType === 'TEMPLATE';
    }
    get contentVersionId() {
        return this.document ? this.document.contentVersionId : null;
    }
    get documentName() {
        return this.document ? this.document.name : '';
    }

    // ---------- canvas events ----------
    handleDocMeta(event) {
        // bubble the page metadata up to the wizard container
        this.dispatchEvent(new CustomEvent('docmeta', { detail: event.detail }));
    }

    handleFieldAdd(event) {
        this.emitFields([...this.fields, event.detail.field]);
    }

    handleFieldMove(event) {
        const { clientId, x, y } = event.detail;
        this.emitFields(
            this.fields.map((f) => (f.clientId === clientId ? { ...f, x, y } : f))
        );
    }

    handleFieldAction(event) {
        const { action, clientId } = event.detail;
        const field = this.fields.find((f) => f.clientId === clientId);
        if (!field) {
            return;
        }
        if (action === 'delete') {
            this.emitFields(this.fields.filter((f) => f.clientId !== clientId));
        } else if (action === 'copy') {
            const copy = {
                ...field,
                clientId: newClientId(),
                x: field.x + COPY_OFFSET_POINTS,
                y: field.y + COPY_OFFSET_POINTS,
                entityTypes: [...(field.entityTypes || [])]
            };
            this.emitFields([...this.fields, copy]);
        } else if (action === 'specify') {
            this.modalClientId = clientId;
            this.modalSelected = [...(field.entityTypes || [])];
            this.modalOpen = true;
        }
    }

    // ---------- entity types modal ----------
    handleModalSave(event) {
        const { clientId, entityTypes } = event.detail;
        this.modalOpen = false;
        this.emitFields(
            this.fields.map((f) =>
                f.clientId === clientId ? { ...f, entityTypes: [...entityTypes] } : f
            )
        );
    }

    handleModalCancel() {
        this.modalOpen = false;
    }

    emitFields(fields) {
        this.dispatchEvent(new CustomEvent('fieldschange', { detail: { fields } }));
    }
}
