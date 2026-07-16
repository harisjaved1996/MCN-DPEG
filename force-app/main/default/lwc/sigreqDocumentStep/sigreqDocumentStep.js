import { LightningElement, api } from 'lwc';
import getFiles from '@salesforce/apex/SignatureRequestController.getFiles';
import getTemplates from '@salesforce/apex/SignatureRequestController.getTemplates';
import { reduceError } from 'c/sigreqUtils';

const SOURCES = [
    { value: 'FILES', label: 'Salesforce Files' },
    { value: 'TEMPLATES', label: 'DocuSign Templates' },
    { value: 'UPLOAD', label: 'Upload' }
];

export default class SigreqDocumentStep extends LightningElement {
    @api recordId;
    @api document; // currently selected master document (or null)

    source = 'FILES';
    files = [];
    templates = [];
    templatesLoaded = false;
    isLoadingFiles = false;
    isLoadingTemplates = false;
    errorMessage = '';

    connectedCallback() {
        this.loadFiles();
    }

    // ---------- getters ----------
    get sourceOptions() {
        return SOURCES.map((s) => ({
            ...s,
            variant: s.value === this.source ? 'brand' : 'neutral'
        }));
    }
    get isFilesSource() {
        return this.source === 'FILES';
    }
    get isTemplatesSource() {
        return this.source === 'TEMPLATES';
    }
    get isUploadSource() {
        return this.source === 'UPLOAD';
    }
    get acceptedFormats() {
        return ['.pdf'];
    }
    get hasFiles() {
        return this.files.length > 0;
    }
    get hasTemplates() {
        return this.templates.length > 0;
    }
    get showNoFiles() {
        return !this.isLoadingFiles && !this.hasFiles;
    }
    get showNoTemplates() {
        return this.templatesLoaded && !this.isLoadingTemplates && !this.hasTemplates;
    }

    get decoratedFiles() {
        const selectedId = this.document ? this.document.contentVersionId : null;
        return this.files.map((f) => ({
            ...f,
            meta: `${f.sizeKb} KB`,
            rowClass:
                f.contentVersionId === selectedId
                    ? 'doc-row slds-box slds-box_x-small doc-row_selected'
                    : 'doc-row slds-box slds-box_x-small',
            iconName: f.contentVersionId === selectedId ? 'utility:check' : 'utility:file'
        }));
    }

    get decoratedTemplates() {
        const selectedId = this.document ? this.document.templateId : null;
        return this.templates.map((t) => ({
            ...t,
            rowClass:
                t.templateId === selectedId
                    ? 'doc-row slds-box slds-box_x-small doc-row_selected'
                    : 'doc-row slds-box slds-box_x-small',
            iconName: t.templateId === selectedId ? 'utility:check' : 'utility:layout'
        }));
    }

    // ---------- data ----------
    async loadFiles() {
        this.isLoadingFiles = true;
        this.errorMessage = '';
        try {
            this.files = await getFiles({ recordId: this.recordId });
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.isLoadingFiles = false;
        }
    }

    async loadTemplates() {
        this.isLoadingTemplates = true;
        this.errorMessage = '';
        try {
            this.templates = await getTemplates();
            this.templatesLoaded = true;
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.isLoadingTemplates = false;
        }
    }

    // ---------- handlers ----------
    handleSourceClick(event) {
        this.source = event.currentTarget.dataset.value;
        if (this.source === 'TEMPLATES' && !this.templatesLoaded && !this.isLoadingTemplates) {
            this.loadTemplates();
        }
    }

    handleFileClick(event) {
        const id = event.currentTarget.dataset.id;
        const file = this.files.find((f) => f.contentVersionId === id);
        if (file) {
            this.emitDocument({
                sourceType: 'FILE',
                contentVersionId: file.contentVersionId,
                contentDocumentId: file.contentDocumentId,
                templateId: null,
                name: `${file.title}.${file.extension}`
            });
        }
    }

    handleTemplateClick(event) {
        const id = event.currentTarget.dataset.id;
        const template = this.templates.find((t) => t.templateId === id);
        if (template) {
            this.emitDocument({
                sourceType: 'TEMPLATE',
                contentVersionId: null,
                contentDocumentId: null,
                templateId: template.templateId,
                name: template.name
            });
        }
    }

    async handleUploadFinished(event) {
        const uploaded = event.detail.files || [];
        await this.loadFiles();
        if (uploaded.length > 0) {
            const match = this.files.find((f) => f.contentDocumentId === uploaded[0].documentId);
            if (match) {
                this.emitDocument({
                    sourceType: 'FILE',
                    contentVersionId: match.contentVersionId,
                    contentDocumentId: match.contentDocumentId,
                    templateId: null,
                    name: `${match.title}.${match.extension}`
                });
            }
        }
        this.source = 'FILES';
    }

    emitDocument(doc) {
        this.dispatchEvent(new CustomEvent('documentchange', { detail: { document: doc } }));
    }
}
