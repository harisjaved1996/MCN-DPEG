import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import PDFJS from '@salesforce/resourceUrl/pdfjs';
import getDocumentPreview from '@salesforce/apex/SignatureRequestController.getDocumentPreview';
import { buildPlacedField, reduceError } from 'c/sigreqUtils';

const RENDER_SCALE = 1.5;

/**
 * Renders the master PDF with pdf.js (static resource, LWS-safe) and hosts
 * the drag-drop field layer.
 *
 * Coordinate contract: everything stored/emitted is PDF points (72dpi,
 * top-left origin) — identical to DocuSign absolute tab positions. The
 * conversion uses the overlay's live bounding rect so CSS/devicePixelRatio
 * drift cannot skew placement:
 *   points = (clientXY - rect.corner) * pagePoints / rect.size
 */
export default class SigreqPdfCanvas extends LightningElement {
    @api contentVersionId;
    @api fields = [];

    pageModels = [];
    isLoading = true;
    loadingLabel = 'Loading document…';
    errorMessage = '';
    rotationWarning = false;
    menuVisible = false;
    menuStyle = '';
    menuClientId = null;

    _initialized = false;
    _pdfDoc = null;
    _renderedPages = new Set();
    _observer = null;
    _drag = null;
    _boundDismiss = null;
    _boundKeydown = null;

    connectedCallback() {
        this._boundDismiss = () => this.hideMenu();
        this._boundKeydown = (e) => {
            if (e.key === 'Escape') {
                this.hideMenu();
            }
        };
        window.addEventListener('click', this._boundDismiss);
        window.addEventListener('keydown', this._boundKeydown);
    }

    disconnectedCallback() {
        window.removeEventListener('click', this._boundDismiss);
        window.removeEventListener('keydown', this._boundKeydown);
        if (this._observer) {
            this._observer.disconnect();
            this._observer = null;
        }
        if (this._pdfDoc) {
            this._pdfDoc.destroy();
            this._pdfDoc = null;
        }
    }

    renderedCallback() {
        if (!this._initialized) {
            this._initialized = true;
            this.init();
            return;
        }
        // Pages just rendered into the DOM: start observing for lazy render.
        if (this.pageModels.length && !this._observer && this._pdfDoc) {
            this.observePages();
        }
    }

    // ------------------------------------------------------------------
    // document loading
    // ------------------------------------------------------------------

    async init() {
        try {
            await loadScript(this, PDFJS + '/pdf.min.js');
            const lib = window.pdfjsLib;
            if (!lib) {
                throw new Error('pdf.js failed to initialize');
            }
            lib.GlobalWorkerOptions.workerSrc = PDFJS + '/pdf.worker.min.js';

            const bytes = await this.fetchBytes();

            let doc;
            try {
                doc = await lib.getDocument({ data: bytes.slice(0) }).promise;
            } catch (workerError) {
                // Worker blocked: load the worker script on the main thread so
                // pdf.js falls back to its "fake worker" and retry once.
                // eslint-disable-next-line no-console
                console.warn('pdf.js worker fallback engaged', workerError);
                await loadScript(this, PDFJS + '/pdf.worker.min.js');
                doc = await lib.getDocument({ data: bytes.slice(0) }).promise;
            }
            this._pdfDoc = doc;

            const models = [];
            for (let num = 1; num <= doc.numPages; num++) {
                // eslint-disable-next-line no-await-in-loop
                const page = await doc.getPage(num);
                if (page.rotate % 360 !== 0) {
                    this.rotationWarning = true;
                }
                const viewport = page.getViewport({ scale: 1 });
                const cssWidth = Math.round(viewport.width * RENDER_SCALE);
                const cssHeight = Math.round(viewport.height * RENDER_SCALE);
                models.push({
                    num,
                    pointsWidth: viewport.width,
                    pointsHeight: viewport.height,
                    cssWidth,
                    cssHeight,
                    wrapStyle: `width:${cssWidth}px; height:${cssHeight}px;`,
                    canvasStyle: `width:${cssWidth}px; height:${cssHeight}px;`
                });
            }
            this.pageModels = models;
            this.isLoading = false;
        } catch (error) {
            this.isLoading = false;
            this.errorMessage = reduceError(error);
        }
    }

    /** Same-origin file servlet first; Apex base64 fallback for small files. */
    async fetchBytes() {
        try {
            const response = await fetch(
                `/sfc/servlet.shepherd/version/download/${this.contentVersionId}`,
                { credentials: 'same-origin' }
            );
            if (!response.ok) {
                throw new Error(`download servlet returned ${response.status}`);
            }
            const buffer = await response.arrayBuffer();
            if (buffer.byteLength === 0) {
                throw new Error('download servlet returned no data');
            }
            return new Uint8Array(buffer);
        } catch (fetchError) {
            // eslint-disable-next-line no-console
            console.warn('shepherd fetch failed, using Apex preview fallback', fetchError);
            this.loadingLabel = 'Loading document (fallback)…';
            const base64 = await getDocumentPreview({ contentVersionId: this.contentVersionId });
            const binary = atob(base64);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
            }
            return bytes;
        }
    }

    observePages() {
        this._observer = new IntersectionObserver(
            (entries) => {
                entries.forEach((entry) => {
                    if (entry.isIntersecting) {
                        const num = parseInt(entry.target.dataset.page, 10);
                        this.renderPage(num);
                    }
                });
            },
            { root: this.template.querySelector('.canvas-scroll'), rootMargin: '400px 0px' }
        );
        this.template.querySelectorAll('.page-wrap').forEach((el) => this._observer.observe(el));
    }

    async renderPage(num) {
        if (this._renderedPages.has(num) || !this._pdfDoc) {
            return;
        }
        this._renderedPages.add(num);
        try {
            const page = await this._pdfDoc.getPage(num);
            const canvas = this.template.querySelector(`canvas[data-page="${num}"]`);
            if (!canvas) {
                this._renderedPages.delete(num);
                return;
            }
            const viewport = page.getViewport({ scale: RENDER_SCALE });
            const dpr = window.devicePixelRatio || 1;
            canvas.width = Math.floor(viewport.width * dpr);
            canvas.height = Math.floor(viewport.height * dpr);
            const context = canvas.getContext('2d');
            await page.render({
                canvasContext: context,
                viewport,
                transform: dpr !== 1 ? [dpr, 0, 0, dpr, 0, 0] : null
            }).promise;
        } catch (error) {
            this._renderedPages.delete(num);
            // eslint-disable-next-line no-console
            console.error(`failed to render page ${num}`, error);
        }
    }

    // ------------------------------------------------------------------
    // rendering model
    // ------------------------------------------------------------------

    get decoratedPages() {
        const fields = this.fields || [];
        return this.pageModels.map((m) => ({
            ...m,
            chips: fields
                .filter((f) => f.page === m.num)
                .map((f) => {
                    let chipClass = 'chip';
                    if (f.category === 'MERGE') {
                        chipClass += ' chip_merge';
                    } else if (f.category === 'ENTRY') {
                        chipClass += ' chip_entry';
                    } else {
                        chipClass += ' chip_recipient';
                    }
                    const width = (f.width || 120) * RENDER_SCALE;
                    const height = (f.height || 16) * RENDER_SCALE;
                    return {
                        ...f,
                        chipClass,
                        hasFilter: !!(f.entityTypes && f.entityTypes.length),
                        style:
                            `left:${f.x * RENDER_SCALE}px; top:${f.y * RENDER_SCALE}px; ` +
                            `width:${width}px; min-height:${height}px;`
                    };
                })
        }));
    }

    get showCanvas() {
        return !this.isLoading && !this.errorMessage;
    }

    // ------------------------------------------------------------------
    // palette drop -> new field
    // ------------------------------------------------------------------

    handleDragOver(event) {
        event.preventDefault();
        event.dataTransfer.dropEffect = 'copy';
    }

    handleDrop(event) {
        event.preventDefault();
        const raw = event.dataTransfer.getData('text/plain');
        if (!raw) {
            return;
        }
        let descriptor;
        try {
            descriptor = JSON.parse(raw);
        } catch (e) {
            return;
        }
        const overlay = event.currentTarget;
        const pageNum = parseInt(overlay.dataset.page, 10);
        const model = this.pageModels.find((m) => m.num === pageNum);
        if (!model) {
            return;
        }
        const rect = overlay.getBoundingClientRect();
        const x = ((event.clientX - rect.left) * model.pointsWidth) / rect.width;
        const y = ((event.clientY - rect.top) * model.pointsHeight) / rect.height;
        const field = buildPlacedField(descriptor, pageNum, x, y);
        this.dispatchEvent(new CustomEvent('fieldadd', { detail: { field } }));
    }

    // ------------------------------------------------------------------
    // chip reposition (pointer events)
    // ------------------------------------------------------------------

    handleChipPointerDown(event) {
        if (event.button !== 0) {
            return; // right-click is the context menu
        }
        event.preventDefault();
        event.stopPropagation();
        const chip = event.currentTarget;
        const clientId = chip.dataset.id;
        const field = (this.fields || []).find((f) => f.clientId === clientId);
        const overlay = chip.closest('.overlay');
        if (!field || !overlay) {
            return;
        }
        const pageNum = parseInt(overlay.dataset.page, 10);
        const model = this.pageModels.find((m) => m.num === pageNum);
        this._drag = {
            chip,
            field,
            model,
            overlayRect: overlay.getBoundingClientRect(),
            startClientX: event.clientX,
            startClientY: event.clientY,
            moved: false
        };
        chip.setPointerCapture(event.pointerId);
        chip.addEventListener('pointermove', this.handleChipPointerMove);
        chip.addEventListener('pointerup', this.handleChipPointerUp);
    }

    handleChipPointerMove = (event) => {
        if (!this._drag) {
            return;
        }
        const dx = event.clientX - this._drag.startClientX;
        const dy = event.clientY - this._drag.startClientY;
        if (Math.abs(dx) + Math.abs(dy) > 2) {
            this._drag.moved = true;
        }
        this._drag.chip.style.transform = `translate(${dx}px, ${dy}px)`;
    };

    handleChipPointerUp = (event) => {
        const drag = this._drag;
        this._drag = null;
        if (!drag) {
            return;
        }
        drag.chip.removeEventListener('pointermove', this.handleChipPointerMove);
        drag.chip.removeEventListener('pointerup', this.handleChipPointerUp);
        drag.chip.style.transform = '';
        if (!drag.moved) {
            return;
        }
        const { model, overlayRect, field } = drag;
        const dxPoints = ((event.clientX - drag.startClientX) * model.pointsWidth) / overlayRect.width;
        const dyPoints = ((event.clientY - drag.startClientY) * model.pointsHeight) / overlayRect.height;
        const width = field.width || 120;
        const height = field.height || 16;
        const x = Math.min(Math.max(0, field.x + dxPoints), model.pointsWidth - width);
        const y = Math.min(Math.max(0, field.y + dyPoints), model.pointsHeight - height);
        this.dispatchEvent(
            new CustomEvent('fieldmove', {
                detail: {
                    clientId: field.clientId,
                    x: Math.round(x * 100) / 100,
                    y: Math.round(y * 100) / 100
                }
            })
        );
    };

    // ------------------------------------------------------------------
    // context menu
    // ------------------------------------------------------------------

    handleChipContextMenu(event) {
        event.preventDefault();
        event.stopPropagation();
        const clientId = event.currentTarget.dataset.id;
        const field = (this.fields || []).find((f) => f.clientId === clientId);
        const host = this.template.querySelector('.canvas-scroll');
        if (!field || !host) {
            return;
        }
        const rect = host.getBoundingClientRect();
        const x = event.clientX - rect.left + host.scrollLeft;
        const y = event.clientY - rect.top + host.scrollTop;
        this.menuClientId = clientId;
        this.menuStyle = `left:${x}px; top:${y}px;`;
        this.menuVisible = true;
    }

    handleMenuClick(event) {
        event.stopPropagation();
        const action = event.currentTarget.dataset.action;
        const clientId = this.menuClientId;
        this.hideMenu();
        this.dispatchEvent(new CustomEvent('fieldaction', { detail: { action, clientId } }));
    }

    hideMenu() {
        if (this.menuVisible) {
            this.menuVisible = false;
            this.menuClientId = null;
        }
    }
}
