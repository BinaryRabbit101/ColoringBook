/**
 * Rendering the server's ISO-8601 timestamps for the authoring screens.
 *
 * The operator's question is always "when did this last ship", answered by
 * glancing at a list, so the format is short and local. `undefined` as the
 * locale means the browser's own, which is the right answer for a
 * single-operator tool that runs on one person's machine.
 */
export function formatDateTime(iso: string | null): string {
    if (!iso) {
        return '—';
    }

    const date = new Date(iso);

    if (Number.isNaN(date.getTime())) {
        return '—';
    }

    return date.toLocaleString(undefined, {
        year: 'numeric',
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
    });
}
