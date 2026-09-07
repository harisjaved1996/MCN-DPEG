import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

/** API name of the deployed screen flow this page hosts. */
const FLOW_API_NAME = 'IR_Add_Investor_Investing_Entity';

/**
 * Dialog title. Kept in JS rather than as template text so the ampersand needs no HTML entity
 * escaping and stays in sync with the WebLink's masterLabel.
 */
const MODAL_TITLE = 'Add Investor & Investing Entity';

const CLOSE_ALTERNATIVE_TEXT = 'Close and return to Contacts';
const EXIT_LABEL = 'Back to Contacts';
const ERROR_HEADING = 'This form could not be opened';
const LAUNCH_ERROR =
    'The "Add Investor & Investing Entity" flow could not be started. It may be inactive, or you may not have permission to run it. Please contact your Salesforce administrator.';

/**
 * `lightning-flow` onstatuschange values this page reacts to. Read off the event via
 * `detail.flowStatus || detail.status` - the two spellings are not interchangeable across the docs
 * and the Aura predecessor used `status`, so both are probed rather than trusted. Getting this wrong
 * would silently no-op every branch below and let the runtime restart the interview on submit.
 */
const FLOW_STATUS = Object.freeze({
    STARTED: 'STARTED',
    FINISHED: 'FINISHED',
    FINISHED_SCREEN: 'FINISHED_SCREEN',
    ERROR: 'ERROR'
});

const CONTACT_OBJECT_API_NAME = 'Contact';

const ESCAPE_KEY = 'Escape';

/** Focus targets, resolved against `this.template` when a render settles. */
const SELECTOR = Object.freeze({
    CLOSE_BUTTON: '.aie-modal__close',
    EXIT_BUTTON: '.aie-modal__exit',
    ALERT: '.aie-alert'
});

/**
 * addInvestorEntityModal
 *
 * URL-addressable page that presents the `IR_Add_Investor_Investing_Entity` screen flow inside an
 * SLDS-styled modal dialog, replacing the bare full-page `/flow/...` experience the Contact list
 * view button used to open.
 *
 * WHY A PAGE AND NOT A REAL MODAL: the entry point is a list view WebLink, which can only perform
 * URL navigation - it cannot open an overlay on top of the list. The standard platform workaround is
 * this one: navigate to a URL-addressable component (`lightning__UrlAddressable`, reachable at
 * `/lightning/cmp/c__addInvestorEntityModal`) whose markup is dressed as a centred modal card over a
 * backdrop. Everything below therefore behaves like a modal visually while being a page technically.
 *
 * NO APEX AND NO INPUT VARIABLES: every variable on the flow is `isInput=false`, so no
 * `flow-input-variables` are passed. All record creation happens inside the flow itself.
 *
 * FINISH HANDLING - `FINISHED` vs `FINISHED_SCREEN`:
 * The flow ends on one of seven terminal screens - `Screen_Success`, five validation screens
 * (duplicate email, duplicate entity name, no entity selected, invalid entity, signing order in use)
 * and `Screen_Error_General`. Those screens exist purely to TELL the user what happened, so
 * navigating away the instant the runtime reports `FINISHED_SCREEN` would bounce the user to the
 * Contact list without ever showing them the outcome - including the error cases. This page therefore
 * navigates away only on `FINISHED` (the user has read the terminal screen and clicked Finish) and,
 * on `FINISHED_SCREEN`, keeps the dialog open and reveals an explicit "Back to Contacts" button.
 * That footer button also makes the exit path independent of exactly which of the two statuses the
 * runtime emits, which removes the usual `lightning-flow` trap where an unhandled finish silently
 * restarts the interview from screen one.
 *
 * `showsTerminalScreen` is cleared again on `STARTED`. The five validation screens all carry
 * `allowBack=true` (only `Screen_Success` and `Screen_Error_General` do not), so the user can step
 * back out of a terminal screen into a live interview; without the reset the footer would linger
 * and - worse - Escape would stay armed over a form that is editable again.
 *
 * ABANDONING THE INTERVIEW: the header close button and the footer button both navigate straight to
 * the Contact list. Nothing is committed until the flow's own create elements run, so abandoning a
 * part-filled interview leaves no partial records behind.
 *
 * DISMISSAL AFFORDANCES - deliberately narrower than a stock SLDS modal:
 * - Backdrop click never dismisses. This is a page dressed as a dialog, so there is no underlying
 *   context a stray click should be able to fall back to.
 * - Escape dismisses ONLY once the interview has reached a terminal or failed state, where there is
 *   nothing left to lose. Mid-interview it is intentionally inert, so a reflexive Escape cannot
 *   throw away a part-filled multi-screen form that has no undo - and so Escape inside a flow
 *   picklist or lookup still belongs to that control rather than closing the whole dialog.
 *
 * FOCUS TRAP: `aria-modal="true"` promises focus cannot leave the dialog, so it is enforced with
 * zero-size sentinel elements bracketing the card. Tabbing off the end lands on the trailing
 * sentinel, which bounces focus to the close button (genuinely the first focusable in the dialog);
 * Shift+Tab off the top lands on the leading sentinel, which bounces to the exit button when the
 * footer is up, otherwise back to the close button. The second case is an approximation - the true
 * last focusable during an interview lives inside `lightning-flow`'s shadow root, which this
 * component cannot query - so reverse-wrapping past the top of the dialog is a no-op rather than a
 * wrap. Focus still never escapes, which is the property `aria-modal` actually asserts.
 */
export default class AddInvestorEntityModal extends NavigationMixin(LightningElement) {
    flowApiName = FLOW_API_NAME;
    modalTitle = MODAL_TITLE;
    closeAlternativeText = CLOSE_ALTERNATIVE_TEXT;
    exitLabel = EXIT_LABEL;
    errorHeading = ERROR_HEADING;

    /** Populated only when the interview fails to launch; suppresses the flow and shows an alert. */
    errorMessage;

    /** Raw runtime text behind an error, shown de-emphasised under the curated message. */
    errorDetail;

    /** True while the interview is sitting on one of the flow's terminal screens. */
    showsTerminalScreen = false;

    /**
     * Selector of the element that should receive focus after the next render, or null when focus is
     * already where it belongs. State-aware rather than a one-shot latch, so swapping the flow out
     * for the error alert can recover focus instead of dropping it on `<body>`.
     */
    pendingFocusSelector = SELECTOR.CLOSE_BUTTON;

    get hasError() {
        return Boolean(this.errorMessage);
    }

    get hasErrorDetail() {
        return Boolean(this.errorDetail);
    }

    get showFlow() {
        return !this.hasError;
    }

    get showExitFooter() {
        return this.hasError || this.showsTerminalScreen;
    }

    /**
     * Moves focus to whatever the current state nominated - the close button on arrival (which also
     * makes assistive technology announce the dialog and its title), or the alert when the flow has
     * been replaced by an error. Clears the request once satisfied so ordinary re-renders never
     * steal focus back from the user.
     */
    renderedCallback() {
        if (!this.pendingFocusSelector) {
            return;
        }
        const target = this.template.querySelector(this.pendingFocusSelector);
        if (!target) {
            return;
        }
        this.pendingFocusSelector = null;
        target.focus();
    }

    /**
     * Reacts to the hosted flow's lifecycle.
     * @param {CustomEvent} event `statuschange` from `lightning-flow`, carrying the interview status
     *                            as STARTED / PAUSED / FINISHED / FINISHED_SCREEN / ERROR.
     */
    handleStatusChange(event) {
        const detail = (event && event.detail) || {};
        const status = detail.flowStatus || detail.status;

        if (status === FLOW_STATUS.FINISHED) {
            this.navigateToContactList();
            return;
        }

        if (status === FLOW_STATUS.FINISHED_SCREEN) {
            // Terminal screen is on display - leave it up and give the user a deliberate exit.
            this.showsTerminalScreen = true;
            return;
        }

        if (status === FLOW_STATUS.STARTED) {
            // Back into a live, editable interview - retract the exit footer and disarm Escape.
            this.showsTerminalScreen = false;
            return;
        }

        if (status === FLOW_STATUS.ERROR) {
            this.errorMessage = LAUNCH_ERROR;
            this.errorDetail = this.resolveErrorDetail(detail);
            this.pendingFocusSelector = SELECTOR.ALERT;
        }
    }

    handleClose() {
        this.navigateToContactList();
    }

    /**
     * Escape closes the dialog only when there is no in-progress interview to discard - see the
     * class header. Bound on the dialog element rather than `window` so there is no global listener
     * to unregister; key events raised inside the flow's own shadow tree still reach it by bubbling
     * through the composed path.
     * @param {KeyboardEvent} event keydown raised anywhere inside the dialog
     */
    handleKeyDown(event) {
        if (event.key !== ESCAPE_KEY || !this.showExitFooter) {
            return;
        }
        event.preventDefault();
        event.stopPropagation();
        this.navigateToContactList();
    }

    /**
     * Bounces focus back into the dialog when the user Shift+Tabs off the top. See the class header
     * for why the exit button, not the flow's genuinely-last focusable, is the wrap target.
     */
    handleLeadingSentinelFocus() {
        const target =
            this.template.querySelector(SELECTOR.EXIT_BUTTON) ||
            this.template.querySelector(SELECTOR.CLOSE_BUTTON);
        if (target) {
            target.focus();
        }
    }

    /** Bounces focus back to the first focusable in the dialog when the user Tabs off the end. */
    handleTrailingSentinelFocus() {
        const target = this.template.querySelector(SELECTOR.CLOSE_BUTTON);
        if (target) {
            target.focus();
        }
    }

    /**
     * Pulls whatever raw text the runtime supplied about a launch failure. It is shown only as a
     * secondary line beneath the curated LAUNCH_ERROR guidance - raw runtime strings are not written
     * for end users, so they never lead (ARCHITECTURE.md: user-safe messages at the UI boundary).
     * @param {object} detail the `statuschange` event detail for an ERROR status
     * @returns {string|undefined} runtime text, or undefined when none was supplied
     */
    resolveErrorDetail(detail) {
        const nestedMessage = detail.error && detail.error.message;
        return nestedMessage || detail.message || undefined;
    }

    /**
     * Returns to the Contact list view. `filterName` is intentionally omitted so the platform opens
     * the user's default/last-used list view - matching the `/lightning/o/Contact/list` retURL the
     * WebLink used before this page existed. `replace = true` keeps a finished interview out of the
     * browser history, so Back does not re-enter a completed form.
     */
    navigateToContactList() {
        this[NavigationMixin.Navigate](
            {
                type: 'standard__objectPage',
                attributes: {
                    objectApiName: CONTACT_OBJECT_API_NAME,
                    actionName: 'list'
                }
            },
            true
        );
    }
}
