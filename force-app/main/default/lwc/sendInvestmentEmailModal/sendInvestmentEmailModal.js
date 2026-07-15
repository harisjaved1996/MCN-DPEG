import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import getInvestors from '@salesforce/apex/InvestmentEmailController.getInvestors';
import sendEmail from '@salesforce/apex/InvestmentEmailController.sendEmail';

const EMAIL_OPTIONS = [
    {
        value: 'Distribution',
        title: 'Distribution Notice',
        description: 'Notify investors of an upcoming distribution payout.',
        icon: 'utility:moneybag'
    },
    {
        value: 'CapitalCall',
        title: 'Capital Call Notice',
        description: 'Request committed capital from your investors.',
        icon: 'utility:call'
    }
];

const AVATAR_PALETTE = 6; // number of avatar color variants in CSS

export default class SendInvestmentEmailModal extends LightningElement {
    @api recordId;

    emailOptions = EMAIL_OPTIONS;

    investmentName = '';
    investors = [];            // [{ id, name, email }]
    selectedIds = new Set();
    emailChoice = '';
    searchTerm = '';

    step = 'choose';           // 'choose' | 'review'
    isLoading = true;
    isSending = false;
    errorMessage = '';

    // ---- Data load ----
    @wire(getInvestors, { recordId: '$recordId' })
    wiredInvestors({ data, error }) {
        if (data) {
            this.investmentName = data.investmentName;
            this.investors = data.investors || [];
            // Everyone pre-selected by default.
            this.selectedIds = new Set(this.investors.map((i) => i.id));
            this.isLoading = false;
        } else if (error) {
            this.errorMessage = this.reduceError(error);
            this.isLoading = false;
        }
    }

    // ---- Steps ----
    get isChooseStep() {
        return this.step === 'choose';
    }
    get isReviewStep() {
        return this.step === 'review';
    }
    get step1Class() {
        return this.isChooseStep ? 'step step_active' : 'step step_done';
    }
    get step2Class() {
        return this.isReviewStep ? 'step step_active' : 'step';
    }

    // ---- Step 1 ----
    get optionsWithState() {
        return this.emailOptions.map((o) => ({
            ...o,
            selected: o.value === this.emailChoice,
            cardClass:
                o.value === this.emailChoice
                    ? 'option-card option-card_selected'
                    : 'option-card'
        }));
    }
    get nextDisabled() {
        return !this.emailChoice;
    }
    get chosenEmailLabel() {
        const opt = EMAIL_OPTIONS.find((o) => o.value === this.emailChoice);
        return opt ? opt.title : '';
    }

    // ---- Step 2 ----
    get hasInvestors() {
        return this.investors.length > 0;
    }
    get selectedCount() {
        return this.selectedIds.size;
    }
    get deselectedCount() {
        return this.investors.length - this.selectedIds.size;
    }
    get totalCount() {
        return this.investors.length;
    }
    get allSelected() {
        return this.hasInvestors && this.selectedIds.size === this.investors.length;
    }
    get selectAllLabel() {
        return this.allSelected ? 'Deselect all' : 'Select all';
    }
    get sendDisabled() {
        return this.isSending || this.selectedCount === 0;
    }

    // Filtered + decorated list for rendering.
    get displayInvestors() {
        const term = this.searchTerm.trim().toLowerCase();
        return this.investors
            .filter((i) => {
                if (!term) {
                    return true;
                }
                const name = (i.name || '').toLowerCase();
                const email = (i.email || '').toLowerCase();
                return name.includes(term) || email.includes(term);
            })
            .map((i) => {
                const selected = this.selectedIds.has(i.id);
                return {
                    ...i,
                    selected,
                    initials: this.initials(i.name),
                    avatarClass: 'avatar avatar_c' + this.colorIndex(i.name),
                    rowClass: selected
                        ? 'investor-row investor-row_selected'
                        : 'investor-row',
                    checkClass: selected ? 'check check_on' : 'check'
                };
            });
    }
    get noSearchResults() {
        return this.hasInvestors && this.displayInvestors.length === 0;
    }

    // ---- Handlers ----
    handleChoose(event) {
        this.emailChoice = event.currentTarget.dataset.value;
    }
    handleNext() {
        if (this.emailChoice) {
            this.step = 'review';
        }
    }
    handleBack() {
        this.step = 'choose';
    }
    handleSearch(event) {
        this.searchTerm = event.target.value;
    }
    handleToggle(event) {
        const id = event.currentTarget.dataset.id;
        const next = new Set(this.selectedIds);
        if (next.has(id)) {
            next.delete(id);
        } else {
            next.add(id);
        }
        this.selectedIds = next;
    }
    handleSelectAll() {
        if (this.allSelected) {
            this.selectedIds = new Set();
        } else {
            this.selectedIds = new Set(this.investors.map((i) => i.id));
        }
    }

    async handleSend() {
        this.isSending = true;
        this.errorMessage = '';

        const deselectedContactIds = this.investors
            .filter((i) => !this.selectedIds.has(i.id))
            .map((i) => i.id);

        try {
            const status = await sendEmail({
                recordId: this.recordId,
                investmentName: this.investmentName,
                emailChoice: this.emailChoice,
                deselectedContactIds
            });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Email queued',
                    message: status,
                    variant: 'success'
                })
            );
            this.close();
        } catch (error) {
            this.errorMessage = this.reduceError(error);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Send failed',
                    message: this.errorMessage,
                    variant: 'error'
                })
            );
        } finally {
            this.isSending = false;
        }
    }

    handleCancel() {
        this.close();
    }
    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // ---- Helpers ----
    initials(name) {
        if (!name) {
            return '?';
        }
        const parts = name.trim().split(/\s+/);
        if (parts.length === 1) {
            return parts[0].charAt(0).toUpperCase();
        }
        return (
            parts[0].charAt(0) + parts[parts.length - 1].charAt(0)
        ).toUpperCase();
    }
    colorIndex(name) {
        const key = name || '';
        let hash = 0;
        for (let i = 0; i < key.length; i++) {
            hash = (hash + key.charCodeAt(i)) % AVATAR_PALETTE;
        }
        return hash;
    }
    reduceError(error) {
        if (!error) {
            return 'Unknown error';
        }
        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (error.body && typeof error.body.message === 'string') {
            return error.body.message;
        }
        return typeof error.message === 'string' ? error.message : 'Unknown error';
    }
}
