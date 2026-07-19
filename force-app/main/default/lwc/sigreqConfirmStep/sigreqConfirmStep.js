import { LightningElement, api } from 'lwc';

export default class SigreqConfirmStep extends LightningElement {
    @api document;
    @api fields = [];
    @api prospects = [];
    @api selectedAssociationIds = [];
    @api emailSubject = '';
    @api emailMessage = '';
    @api isSending = false;

    get documentName() {
        return this.document ? this.document.name : '';
    }
    get documentSourceLabel() {
        if (!this.document) {
            return '';
        }
        return this.document.sourceType === 'TEMPLATE' ? 'DocuSign template' : 'Salesforce file';
    }
    get selectedProspects() {
        const ids = new Set(this.selectedAssociationIds || []);
        return (this.prospects || [])
            .filter((p) => ids.has(p.associationId))
            .map((p) => ({
                ...p,
                roleLabel: p.isPrimary
                    ? 'Primary (fills fields, signs last)'
                    : p.isRequiredSigner
                      ? 'Required signer (signs first)'
                      : 'Viewer (copy only)'
            }));
    }
    get recipientCount() {
        return this.selectedProspects.length;
    }
    get envelopeCount() {
        const entities = new Set(this.selectedProspects.map((p) => p.entityId));
        return entities.size;
    }
    get fieldSummary() {
        if (this.document && this.document.sourceType === 'TEMPLATE') {
            return 'Fields come from the DocuSign template.';
        }
        const fields = this.fields || [];
        const merge = fields.filter((f) => f.category === 'MERGE').length;
        const entry = fields.filter((f) => f.category === 'ENTRY').length;
        const recipient = fields.filter((f) => f.category === 'RECIPIENT').length;
        const restricted = fields.filter((f) => f.entityTypes && f.entityTypes.length).length;
        let summary = `${fields.length} field(s): ${merge} merge, ${entry} entry, ${recipient} recipient.`;
        if (restricted > 0) {
            summary += ` ${restricted} restricted by entity type.`;
        }
        return summary;
    }
    get sendDisabled() {
        return this.isSending || this.recipientCount === 0;
    }
    get sendLabel() {
        return this.isSending ? 'Sending…' : 'Send';
    }

    handleSubjectChange(event) {
        this.dispatchEvent(
            new CustomEvent('metachange', { detail: { emailSubject: event.target.value } })
        );
    }
    handleMessageChange(event) {
        this.dispatchEvent(
            new CustomEvent('metachange', { detail: { emailMessage: event.target.value } })
        );
    }
    handleSend() {
        this.dispatchEvent(new CustomEvent('send'));
    }
}
