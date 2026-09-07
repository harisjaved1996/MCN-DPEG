import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import getLaunchEmail from '@salesforce/apex/NewOfferingLaunchController.getLaunchEmail';
import getAudiencePage from '@salesforce/apex/NewOfferingLaunchController.getAudiencePage';
import getAudienceCount from '@salesforce/apex/NewOfferingLaunchController.getAudienceCount';
import startSend from '@salesforce/apex/NewOfferingLaunchController.startSend';

const PAGE_SIZE = 25;
const SEARCH_DEBOUNCE_MS = 350;

/** Matches NewOfferingLaunchController.MODE_ALL_EXCEPT / MODE_ONLY. */
const MODE_ALL_EXCEPT = 'All Except Listed';
const MODE_ONLY = 'Only Listed';

/**
 * IR_Communication__mdt record driving this action. Everything else about the
 * campaign - workspace, email, flow, name prefix, audience filter - is read
 * from that record, so another campaign needs only a new record and a new
 * flow, with this one line pointed at it.
 */
const CONFIG_NAME = 'IR_New_Launch';

export default class NewOfferingLaunchWizard extends LightningElement {
    @api recordId;

    step = 1;

    // ---- step 1 ----------------------------------------------------------
    email;
    emailError;
    loadingEmail = true;

    // ---- step 2 ----------------------------------------------------------
    rows = [];
    pageNumber = 1;
    totalCount = 0;
    hasMore = false;
    browseLimitReached = false;
    searchTerm = '';
    filteredCount = 0;
    loadingAudience = false;
    audienceError;

    /**
     * Selection is stored as a mode plus a set of exceptions, never as a list
     * of everyone selected. With "all except", the set holds who was unticked;
     * with "only listed", it holds who was ticked. Either way the set stays
     * small, so a 10,000-strong audience costs the browser nothing and the
     * request body stays tiny in both directions.
     */
    selectAllMode = true;
    exceptions = new Set();

    sending = false;
    _searchTimer;

    // ---------------------------------------------------------------- setup

    connectedCallback() {
        this.loadEmail();
    }

    async loadEmail() {
        this.loadingEmail = true;
        try {
            this.email = await getLaunchEmail({ configName: CONFIG_NAME });
            this.emailError = undefined;
        } catch (e) {
            this.emailError = this.messageOf(e);
        } finally {
            this.loadingEmail = false;
        }
    }

    async loadAudience() {
        this.loadingAudience = true;
        try {
            const [page, count] = await Promise.all([
                getAudiencePage({
                    configName: CONFIG_NAME,
                    searchTerm: this.searchTerm,
                    pageNumber: this.pageNumber,
                    pageSize: PAGE_SIZE
                }),
                getAudienceCount({ configName: CONFIG_NAME, searchTerm: this.searchTerm })
            ]);
            this.rows = page.members || [];
            this.hasMore = page.hasMore;
            this.browseLimitReached = page.browseLimitReached;
            this.filteredCount = count;
            if (!this.searchTerm) {
                this.totalCount = count;
            }
            this.audienceError = undefined;
        } catch (e) {
            this.audienceError = this.messageOf(e);
            this.rows = [];
        } finally {
            this.loadingAudience = false;
        }
    }

    // ------------------------------------------------------------ step flow

    handleNext() {
        this.step = 2;
        if (!this.rows.length) {
            this.loadAudience();
        }
    }

    handleBack() {
        this.step = 1;
    }

    // ------------------------------------------------------------- searching

    handleSearch(event) {
        const value = event.target.value;
        window.clearTimeout(this._searchTimer);
        this._searchTimer = window.setTimeout(() => {
            this.searchTerm = value;
            this.pageNumber = 1;
            this.loadAudience();
        }, SEARCH_DEBOUNCE_MS);
    }

    handlePrev() {
        if (this.pageNumber > 1) {
            this.pageNumber -= 1;
            this.loadAudience();
        }
    }

    handleNextPage() {
        if (this.hasMore) {
            this.pageNumber += 1;
            this.loadAudience();
        }
    }

    // ------------------------------------------------------------ selection

    handleRowToggle(event) {
        const id = event.target.dataset.id;
        const checked = event.target.checked;
        const next = new Set(this.exceptions);

        // In "all except" mode the set tracks who is OFF; in "only listed" it
        // tracks who is ON. Flipping a row therefore adds in one mode and
        // removes in the other.
        const shouldBeInSet = this.selectAllMode ? !checked : checked;
        if (shouldBeInSet) {
            next.add(id);
        } else {
            next.delete(id);
        }
        this.exceptions = next;
    }

    handleSelectAll() {
        this.selectAllMode = true;
        this.exceptions = new Set();
    }

    handleDeselectAll() {
        this.selectAllMode = false;
        this.exceptions = new Set();
    }

    // ----------------------------------------------------------------- send

    async handleSend() {
        if (this.selectedCount === 0) {
            return;
        }
        this.sending = true;
        try {
            const communicationId = await startSend({
                offeringId: this.recordId,
                configName: CONFIG_NAME,
                selectionMode: this.selectAllMode ? MODE_ALL_EXCEPT : MODE_ONLY,
                individualIds: Array.from(this.exceptions)
            });

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Send started',
                    message: `${this.selectedCount} recipient${
                        this.selectedCount === 1 ? '' : 's'
                    } queued. Engagement appears on the Communication in 5-15 minutes.`,
                    variant: 'success'
                })
            );
            // Deliberately no navigation: the sender stays on the Offering.
            // The toast names the Communication so it can be opened from the
            // Offering's related list when they actually want it.
            this.dispatchEvent(new CloseActionScreenEvent());
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'The send could not be started',
                    message: this.messageOf(e),
                    variant: 'error',
                    mode: 'sticky'
                })
            );
        } finally {
            this.sending = false;
        }
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // ------------------------------------------------------------- getters

    get isStepOne() {
        return this.step === 1;
    }

    get isStepTwo() {
        return this.step === 2;
    }

    get stepOneClass() {
        return this.step === 1 ? 'crumb crumb_current' : 'crumb crumb_done';
    }

    get stepTwoClass() {
        return this.step === 2 ? 'crumb crumb_current' : 'crumb';
    }

    /** Rows decorated with their live checkbox state. */
    get decoratedRows() {
        return this.rows.map((r) => {
            const inSet = this.exceptions.has(r.individualId);
            const selected = this.selectAllMode ? !inSet : inSet;
            return {
                ...r,
                selected,
                rowClass: selected ? 'row row_on' : 'row',
                emailDisplay: r.email || 'No email address',
                emailClass: r.email ? 'cell-sub' : 'cell-sub cell-sub_muted'
            };
        });
    }

    get selectedCount() {
        return this.selectAllMode
            ? Math.max(this.totalCount - this.exceptions.size, 0)
            : this.exceptions.size;
    }

    get noneSelected() {
        return this.selectedCount === 0;
    }

    /** Templates cannot negate, so the disabled state is exposed directly. */
    get proceedDisabled() {
        return !this.email || !!this.emailError || this.loadingEmail || this.notPublished;
    }

    /**
     * A broadcast flow refuses unpublished content at send time, so this is
     * caught here rather than surfacing as a failed send minutes later.
     */
    get notPublished() {
        return !!this.email && this.email.isPublished !== true;
    }

    get statusLabel() {
        return this.notPublished ? 'Not published' : 'Published';
    }

    get statusClass() {
        return this.notPublished ? 'pill pill_bad' : 'pill pill_good';
    }

    get sendDisabled() {
        return this.noneSelected || this.sending || this.loadingAudience;
    }

    get selectionSummary() {
        const total = this.totalCount;
        return `${this.selectedCount} of ${total} selected`;
    }

    get searchSummary() {
        if (!this.searchTerm) {
            return null;
        }
        return `${this.filteredCount} match${this.filteredCount === 1 ? '' : 'es'} for "${
            this.searchTerm
        }"`;
    }

    get prevDisabled() {
        return this.pageNumber <= 1 || this.loadingAudience;
    }

    get nextDisabled() {
        return !this.hasMore || this.loadingAudience;
    }

    get pageLabel() {
        return `Page ${this.pageNumber}`;
    }

    get showEmptyState() {
        return !this.loadingAudience && !this.audienceError && this.rows.length === 0;
    }

    get emptyMessage() {
        return this.searchTerm
            ? `No individuals match "${this.searchTerm}".`
            : 'No individuals were found in Data Cloud.';
    }

    // ------------------------------------------------------------- helpers

    messageOf(error) {
        return (
            error?.body?.message ||
            error?.body?.pageErrors?.[0]?.message ||
            error?.message ||
            'Unexpected error.'
        );
    }
}
