/**
 * Shared helpers/catalogs for the Add Signature Request wizard.
 */

let clientIdCounter = 0;

/** Unique id per placed field; doubles as the DocuSign tab dataLabel. */
export function newClientId() {
    clientIdCounter += 1;
    return `f_${Date.now().toString(36)}_${clientIdCounter}`;
}

/** Normalizes LWC/Apex error shapes into a readable message. */
export function reduceError(error) {
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

/** Default tab footprint in PDF points (72dpi). */
export const FIELD_DEFAULTS = {
    TEXT: { width: 120, height: 16 },
    CHECKBOX: { width: 14, height: 14 },
    SIGNATURE: { width: 96, height: 36 },
    STAMP: { width: 96, height: 24 }
};

export const ENTRY_FIELDS = [
    { entryKind: 'REQUIRED_TEXT', label: 'Required Text', sizeKey: 'TEXT' },
    { entryKind: 'OPTIONAL_TEXT', label: 'Optional Text', sizeKey: 'TEXT' },
    { entryKind: 'CHECKBOX', label: 'Checkbox', sizeKey: 'CHECKBOX' }
];

export const RECIPIENT_FIELDS = [
    { recipientKind: 'SIGNATURE', label: 'Primary Signature', sizeKey: 'SIGNATURE' },
    { recipientKind: 'DATE_SIGNED', label: 'Date Signed', sizeKey: 'STAMP' },
    { recipientKind: 'FULL_NAME', label: 'Full Name', sizeKey: 'STAMP' },
    { recipientKind: 'EMAIL', label: 'Email Address', sizeKey: 'STAMP' }
];

/** Builds a PlacedField from a palette descriptor + drop point (PDF points). */
export function buildPlacedField(descriptor, page, x, y) {
    const sizeKey = descriptor.sizeKey || 'TEXT';
    const size = FIELD_DEFAULTS[sizeKey] || FIELD_DEFAULTS.TEXT;
    return {
        clientId: newClientId(),
        category: descriptor.category,
        objectApiName: descriptor.objectApiName || null,
        fieldApiName: descriptor.fieldApiName || null,
        entryKind: descriptor.entryKind || null,
        recipientKind: descriptor.recipientKind || null,
        label: descriptor.label,
        entityTypes: [],
        page,
        x: Math.max(0, Math.round(x * 100) / 100),
        y: Math.max(0, Math.round(y * 100) / 100),
        width: size.width,
        height: size.height
    };
}
