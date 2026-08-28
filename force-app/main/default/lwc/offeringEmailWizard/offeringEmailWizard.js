import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';

import OFFERING_NAME from '@salesforce/schema/Offering__c.Name';

import getPublishedEmails from '@salesforce/apex/OfferingEmailController.getPublishedEmails';
import getAudiencePage from '@salesforce/apex/OfferingEmailController.getAudiencePage';
import getConsentSummary from '@salesforce/apex/OfferingEmailController.getConsentSummary';
import previewEmail from '@salesforce/apex/OfferingEmailController.previewEmail';
import startSend from '@salesforce/apex/OfferingEmailController.startSend';

const PAGE_SIZE = 10;
const EMAIL_PAGE_SIZE = 5;
const SEARCH_DEBOUNCE_MS = 350;
const AVATAR_VARIANTS = 6;

export default class OfferingEmailWizard extends NavigationMixin(LightningElement) {
    @api recordId;

    offeringName = '';

    // step 1
    emails = [];
    emailSearch = '';
    emailTotal = 0;
    emailHasMore = false;
    emailNextCursor = null;
    emailCursorStack = [];
    selectedContentId = '';
    selectedEmailName_x = '';
    previewHtml = '';
    previewSubject = '';
    isPreviewOpen = false;
    isPreviewLoading = false;

    // step 2
    page = null;
    pageNumber = 1;
    searchTerm = '';
    consent = null;
    // Selection is stored as exclusions. An audience of 20k must never require
    // the browser to hold 20k ids, and "everyone" is the default.
    excludedIds = new Set();
    skipWithoutConsent = true;

    step = 1;
    isLoadingEmails = true;
    isLoadingAudience = false;
    isSending = false;
    errorMessage = '';

    _searchTimer;
    _emailSearchTimer;

    // ---------------------------------------------------------------- wires

    @wire(getRecord, { recordId: '$recordId', fields: [OFFERING_NAME] })
    wiredOffering({ data, error }) {
        if (data) {
            this.offeringName = getFieldValue(data, OFFERING_NAME) || '';
        } else if (error) {
            this.errorMessage = this.reduceError(error);
        }
    }

    connectedCallback() {
        this.loadEmails();
    }

    /**
     * Emails are fetched a page at a time with a keyset cursor. Cursors only
     * move forward, so each one is pushed onto a stack to make Previous work
     * without re-querying from the top.
     */
    async loadEmails(cursor) {
        this.isLoadingEmails = true;
        try {
            const page = await getPublishedEmails({
                searchTerm: this.emailSearch,
                cursor: cursor || null,
                pageSize: EMAIL_PAGE_SIZE
            });
            this.emails = page.emails || [];
            this.emailTotal = page.totalCount || 0;
            this.emailHasMore = page.hasMore === true;
            this.emailNextCursor = page.nextCursor;
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoadingEmails = false;
        }
    }

    @wire(getConsentSummary)
    wiredConsent({ data, error }) {
        if (data) {
            this.consent = data;
        } else if (error) {
            this.errorMessage = this.reduceError(error);
        }
    }

    // ------------------------------------------------------------ step state

    get isStepOne() {
        return this.step === 1;
    }
    get isStepTwo() {
        return this.step === 2;
    }
    get stepOneClass() {
        return this.step === 1 ? 'step step_active' : 'step step_done';
    }
    get stepTwoClass() {
        return this.step === 2 ? 'step step_active' : 'step';
    }
    get connectorClass() {
        return this.step === 2 ? 'connector connector_filled' : 'connector';
    }

    // ------------------------------------------------------------- step one

    get emailCards() {
        return this.emails.map((e) => {
            const selected = e.managedContentId === this.selectedContentId;
            return {
                ...e,
                selected,
                rowClass: selected ? 'row row_selected' : 'row',
                radioClass: selected ? 'radio radio_on' : 'radio',
                readyLabel: e.sendDefinitionId ? 'Ready to send' : 'First use',
                readyClass: e.sendDefinitionId ? 'tag tag_ready' : 'tag tag_new',
                createdLabel: this.formatDate(e.createdDate)
            };
        });
    }

    get hasEmails() {
        return this.emailTotal > 0;
    }
    get hasVisibleEmails() {
        return this.emails.length > 0;
    }
    get showEmailPager() {
        return this.emailTotal > EMAIL_PAGE_SIZE;
    }
    get isFirstEmailPage() {
        return this.emailCursorStack.length === 0;
    }
    get isLastEmailPage() {
        return !this.emailHasMore;
    }
    get emailRangeLabel() {
        if (this.emailTotal === 0) {
            return 'No emails';
        }
        const from = this.emailCursorStack.length * EMAIL_PAGE_SIZE + 1;
        const to = from + this.emails.length - 1;
        return `${from}-${to} of ${this.emailTotal}`;
    }
    get emailCountLabel() {
        return this.emailSearch.trim()
            ? `${this.emailTotal} matching`
            : `${this.emailTotal} published`;
    }

    handleEmailSearch(event) {
        const value = event.target.value;
        window.clearTimeout(this._emailSearchTimer);
        this._emailSearchTimer = window.setTimeout(() => {
            this.emailSearch = value;
            // A narrowed list invalidates every cursor collected so far.
            this.emailCursorStack = [];
            this.emailNextCursor = null;
            this.loadEmails();
        }, SEARCH_DEBOUNCE_MS);
    }

    handleEmailNext() {
        if (this.emailHasMore && this.emailNextCursor) {
            this.emailCursorStack = [...this.emailCursorStack, this.emailNextCursor];
            this.loadEmails(this.emailNextCursor);
        }
    }

    handleEmailPrevious() {
        if (this.emailCursorStack.length === 0) {
            return;
        }
        // Pop this page's cursor; the one beneath it re-fetches the page before.
        const stack = this.emailCursorStack.slice(0, -1);
        this.emailCursorStack = stack;
        this.loadEmails(stack.length ? stack[stack.length - 1] : null);
    }

    formatDate(value) {
        if (!value) {
            return 'unknown';
        }
        return new Date(value).toLocaleDateString(undefined, {
            day: 'numeric',
            month: 'short',
            year: 'numeric'
        });
    }
    get nextDisabled() {
        return !this.selectedContentId;
    }
    get selectedEmailName() {
        return this.selectedEmailName_x || '';
    }

    /**
     * The name is captured on selection rather than looked up in `emails`,
     * because paging replaces that array and the chosen email may no longer be
     * on the visible page.
     */
    handleSelectEmail(event) {
        const id = event.currentTarget.dataset.id;
        this.selectedContentId = id;
        const chosen = this.emails.find((e) => e.managedContentId === id);
        this.selectedEmailName_x = chosen ? chosen.name : '';
    }

    async handlePreview(event) {
        event.stopPropagation();
        const contentId = event.currentTarget.dataset.id;
        const email = this.emails.find((e) => e.managedContentId === contentId);

        this.isPreviewOpen = true;
        this.isPreviewLoading = true;
        this.previewHtml = '';
        this.previewSubject = '';

        try {
            const result = await previewEmail({
                managedContentId: contentId,
                emailName: email ? email.name : ''
            });
            this.previewSubject = result.subject || '';
            this.previewHtml = result.body || result.text || '';
        } catch (error) {
            this.errorMessage = this.reduceError(error);
            this.isPreviewOpen = false;
        } finally {
            this.isPreviewLoading = false;
        }
    }

    closePreview() {
        this.isPreviewOpen = false;
    }

    /** Keeps a click inside the preview panel from dismissing it. */
    stopPropagation(event) {
        event.stopPropagation();
    }

    // ------------------------------------------------------------- step two

    async loadAudience() {
        this.isLoadingAudience = true;
        try {
            this.page = await getAudiencePage({
                searchTerm: this.searchTerm,
                pageNumber: this.pageNumber,
                pageSize: PAGE_SIZE
            });
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoadingAudience = false;
        }
    }

    get rows() {
        if (!this.page || !this.page.members) {
            return [];
        }
        return this.page.members.map((m) => {
            const included = !this.excludedIds.has(m.individualId);
            const blocked = this.skipWithoutConsent && !m.sendable;
            return {
                ...m,
                included,
                initials: this.initials(m.name),
                avatarClass: `avatar avatar_v${this.variantFor(m.name)}`,
                rowClass: included ? 'row' : 'row row_excluded',
                boxClass: included ? 'box box_on' : 'box',
                consentLabel: this.consentLabel(m.consentStatus),
                consentClass: this.consentClass(m.consentStatus),
                willSend: included && !blocked
            };
        });
    }

    get hasRows() {
        return this.rows.length > 0;
    }
    get totalCount() {
        return this.page ? this.page.totalCount : 0;
    }
    get excludedCount() {
        return this.excludedIds.size;
    }
    get browseLimitReached() {
        return this.page && this.page.browseLimitReached;
    }
    get isFirstPage() {
        return this.pageNumber <= 1;
    }
    get isLastPage() {
        return !this.page || !this.page.hasMore;
    }
    get rangeLabel() {
        if (!this.page || this.totalCount === 0) {
            return 'No matches';
        }
        const from = (this.pageNumber - 1) * PAGE_SIZE + 1;
        const to = Math.min(from + this.rows.length - 1, this.totalCount);
        return `${from}-${to} of ${this.totalCount.toLocaleString()}`;
    }

    /** Headline number: what the send is actually expected to deliver. */
    get projectedRecipients() {
        if (!this.consent) {
            return 0;
        }
        const base = this.skipWithoutConsent ? this.consent.optedIn : this.consent.total;
        return Math.max(0, base - this.excludedIds.size);
    }
    get blockedCount() {
        return this.consent ? this.consent.blocked : 0;
    }
    get hasBlocked() {
        return this.blockedCount > 0;
    }
    get blockedBannerClass() {
        return this.skipWithoutConsent ? 'banner banner_info' : 'banner banner_warn';
    }
    get blockedMessage() {
        const n = this.blockedCount.toLocaleString();
        return this.skipWithoutConsent
            ? `${n} individuals have no opt-in on their address and will be left out of this send.`
            : `${n} individuals have no opt-in. Marketing Cloud Next will reject them, and each one will be recorded as blocked.`;
    }
    get sendDisabled() {
        return this.isSending || this.projectedRecipients === 0;
    }
    get sendLabel() {
        if (this.isSending) {
            return 'Starting...';
        }
        return `Send to ${this.projectedRecipients.toLocaleString()}`;
    }

    handleSearch(event) {
        const value = event.target.value;
        window.clearTimeout(this._searchTimer);
        this._searchTimer = window.setTimeout(() => {
            this.searchTerm = value;
            this.pageNumber = 1;
            this.loadAudience();
        }, SEARCH_DEBOUNCE_MS);
    }

    handleToggleRow(event) {
        const id = event.currentTarget.dataset.id;
        const next = new Set(this.excludedIds);
        if (next.has(id)) {
            next.delete(id);
        } else {
            next.add(id);
        }
        this.excludedIds = next;
    }

    handleToggleConsentFilter(event) {
        this.skipWithoutConsent = event.target.checked;
    }

    handleResetSelection() {
        this.excludedIds = new Set();
    }

    handlePrevious() {
        if (!this.isFirstPage) {
            this.pageNumber -= 1;
            this.loadAudience();
        }
    }
    handleNextPage() {
        if (!this.isLastPage) {
            this.pageNumber += 1;
            this.loadAudience();
        }
    }

    // ----------------------------------------------------------- navigation

    handleNext() {
        if (!this.selectedContentId) {
            return;
        }
        this.step = 2;
        if (!this.page) {
            this.loadAudience();
        }
    }
    handleBack() {
        this.step = 1;
    }

    async handleSend() {
        this.isSending = true;
        this.errorMessage = '';
        try {
            const communicationId = await startSend({
                offeringId: this.recordId,
                managedContentId: this.selectedContentId,
                emailName: this.selectedEmailName,
                searchTerm: this.searchTerm,
                excludedIndividualIds: Array.from(this.excludedIds),
                skipWithoutConsent: this.skipWithoutConsent
            });

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Send started',
                    message: `${this.selectedEmailName} is going out to ${this.projectedRecipients.toLocaleString()} recipients. Track progress on the Communication record.`,
                    variant: 'success'
                })
            );
            this.close();
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: communicationId, actionName: 'view' }
            });
        } catch (error) {
            this.errorMessage = this.reduceError(error);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not start the send',
                    message: this.errorMessage,
                    variant: 'error'
                })
            );
            this.isSending = false;
        }
    }

    handleCancel() {
        this.close();
    }
    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // --------------------------------------------------------------- helpers

    consentLabel(status) {
        if (status === 'OPT_IN') return 'Opted in';
        if (status === 'OPT_OUT') return 'Opted out';
        return 'No consent';
    }
    consentClass(status) {
        if (status === 'OPT_IN') return 'pill pill_in';
        if (status === 'OPT_OUT') return 'pill pill_out';
        return 'pill pill_none';
    }
    initials(name) {
        if (!name) {
            return '?';
        }
        const parts = name.trim().split(/\s+/);
        if (parts.length === 1) {
            return parts[0].charAt(0).toUpperCase();
        }
        return (parts[0].charAt(0) + parts[parts.length - 1].charAt(0)).toUpperCase();
    }
    variantFor(name) {
        let hash = 0;
        const key = name || '';
        for (let i = 0; i < key.length; i++) {
            hash = (hash + key.charCodeAt(i)) % AVATAR_VARIANTS;
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
