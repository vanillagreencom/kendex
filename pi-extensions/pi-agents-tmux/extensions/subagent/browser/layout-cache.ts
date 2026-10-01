import type { Theme } from "@earendil-works/pi-coding-agent";

type Layout = { kind: string; text: string; width: number; theme: Theme; lines: string[]; bytes: number };
const layouts: Layout[] = [];
const MAX_BYTES = 4 * 1024 * 1024;
let bytes = 0;

/** Share bounded popup layout work across scrolling frames, never across a theme invalidation. */
export function cachedPopupLayout(kind: string, text: string, width: number, theme: Theme, render: () => string[]): string[] {
	const index = layouts.findIndex((entry) => entry.kind === kind && entry.text === text && entry.width === width && entry.theme === theme);
	if (index !== -1) {
		const [entry] = layouts.splice(index, 1);
		layouts.push(entry);
		return entry.lines;
	}
	const lines = render();
	const size = Buffer.byteLength(text) + lines.reduce((sum, line) => sum + Buffer.byteLength(line), 0);
	if (size > MAX_BYTES) return lines;
	while (layouts.length && (layouts.length >= 16 || bytes + size > MAX_BYTES)) {
		bytes -= layouts.shift()!.bytes;
	}
	layouts.push({ kind, text, width, theme, lines, bytes: size });
	bytes += size;
	return lines;
}

/** Pi calls invalidate on theme changes, including mutations of the current theme object. */
export function clearPopupLayouts(): void {
	layouts.length = 0;
	bytes = 0;
}
