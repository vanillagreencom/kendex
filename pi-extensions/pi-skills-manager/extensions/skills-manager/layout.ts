import { DEFAULT_LIST_ROWS, DEFAULT_POPUP_MAX_HEIGHT } from "./constants.js";
import type { OverlaySize } from "./types.js";

const BROWSE_CHROME_ROWS = 8;

export function normalizeListRows(rows: number, fallback = DEFAULT_LIST_ROWS): number {
	const value = Number.isFinite(rows) ? rows : fallback;
	return Math.max(1, Math.floor(value));
}

export function resolveOverlayRows(terminalRows: number, maxHeight: OverlaySize = DEFAULT_POPUP_MAX_HEIGHT): number {
	const terminal = Math.max(1, Math.floor(terminalRows));
	if (typeof maxHeight === "number" && Number.isFinite(maxHeight)) return Math.max(1, Math.min(terminal, Math.floor(maxHeight)));
	if (typeof maxHeight === "string") {
		const trimmed = maxHeight.trim();
		const percent = trimmed.match(/^(\d+(?:\.\d+)?)%$/);
		if (percent) return Math.max(1, Math.min(terminal, Math.floor(terminal * (Number(percent[1]) / 100))));
		if (/^\d+$/.test(trimmed)) return Math.max(1, Math.min(terminal, Number(trimmed)));
	}
	return terminal;
}

export function responsiveBrowseListRows(configuredRows: number, terminalRows: number, maxHeight: OverlaySize = DEFAULT_POPUP_MAX_HEIGHT): number {
	const configured = normalizeListRows(configuredRows);
	const overlayRows = resolveOverlayRows(terminalRows, maxHeight);
	const availableListRows = Math.max(1, overlayRows - BROWSE_CHROME_ROWS);
	return Math.max(1, Math.min(configured, availableListRows));
}