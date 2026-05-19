import { DEFAULT_LIST_ROWS, DEFAULT_POPUP_MAX_HEIGHT } from "./constants.js";
import type { OverlaySize } from "./types.js";

export const BROWSE_FRAME_ROWS = 2;
export const BROWSE_SEARCH_ROWS = 1;
export const BROWSE_SEARCH_GAP_ROWS = 1;
export const BROWSE_FOOTER_GAP_ROWS = 1;
export const BROWSE_FOOTER_ROWS = 1;
export const BROWSE_NON_LIST_ROWS = BROWSE_FRAME_ROWS + BROWSE_SEARCH_ROWS + BROWSE_SEARCH_GAP_ROWS + BROWSE_FOOTER_GAP_ROWS + BROWSE_FOOTER_ROWS;

const DEFAULT_POPUP_MAX_HEIGHT_RATIO = 0.86;
const FALLBACK_TERMINAL_ROWS = Math.ceil((DEFAULT_LIST_ROWS + BROWSE_NON_LIST_ROWS) / DEFAULT_POPUP_MAX_HEIGHT_RATIO);

type ParsedPopupMaxHeight =
	| { kind: "rows"; rows: number }
	| { kind: "percent"; ratio: number; text: string };

export interface BrowseWindow {
	listRows: number;
	startIndex: number;
	endIndex: number;
}

function finiteFloor(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value) ? Math.floor(value) : undefined;
}

function positiveFiniteFloor(value: unknown): number | undefined {
	const floored = finiteFloor(value);
	return floored !== undefined && floored >= 1 ? floored : undefined;
}

function clamp(value: number, min: number, max: number): number {
	return Math.max(min, Math.min(max, value));
}

function parsePopupMaxHeight(maxHeight: OverlaySize | undefined): ParsedPopupMaxHeight | undefined {
	const rows = positiveFiniteFloor(maxHeight);
	if (rows !== undefined) return { kind: "rows", rows };
	if (typeof maxHeight !== "string") return undefined;

	const trimmed = maxHeight.trim();
	const percent = trimmed.match(/^(\d+(?:\.\d+)?)%$/);
	if (percent) {
		const value = Number(percent[1]);
		if (Number.isFinite(value) && value > 0) return { kind: "percent", ratio: value / 100, text: `${value}%` };
		return undefined;
	}

	if (/^\d+$/.test(trimmed)) {
		const value = Number(trimmed);
		if (Number.isFinite(value) && value >= 1) return { kind: "rows", rows: value };
	}

	return undefined;
}

function safeTerminalRows(terminalRows: unknown): number {
	return positiveFiniteFloor(terminalRows) ?? FALLBACK_TERMINAL_ROWS;
}

function resolvedPopupMaxHeight(maxHeight: OverlaySize | undefined): ParsedPopupMaxHeight {
	return parsePopupMaxHeight(maxHeight) ?? parsePopupMaxHeight(DEFAULT_POPUP_MAX_HEIGHT) ?? { kind: "percent", ratio: DEFAULT_POPUP_MAX_HEIGHT_RATIO, text: "86%" };
}

export function sanitizePopupMaxHeight(maxHeight: OverlaySize | undefined): OverlaySize {
	const parsed = parsePopupMaxHeight(maxHeight);
	if (parsed?.kind === "rows") return parsed.rows;
	if (parsed?.kind === "percent") return parsed.text;
	return DEFAULT_POPUP_MAX_HEIGHT;
}

export function normalizeListRows(rows: number | undefined, fallback = DEFAULT_LIST_ROWS): number {
	return positiveFiniteFloor(rows) ?? positiveFiniteFloor(fallback) ?? DEFAULT_LIST_ROWS;
}

export function resolveOverlayRows(terminalRows: number | undefined, maxHeight: OverlaySize | undefined = DEFAULT_POPUP_MAX_HEIGHT): number {
	const terminal = safeTerminalRows(terminalRows);
	const parsed = resolvedPopupMaxHeight(maxHeight);
	if (parsed.kind === "rows") return Math.max(1, Math.min(terminal, parsed.rows));
	return Math.max(1, Math.min(terminal, Math.floor(terminal * parsed.ratio)));
}

export function responsiveBrowseListRows(configuredRows: number | undefined, terminalRows: number | undefined, maxHeight: OverlaySize | undefined = DEFAULT_POPUP_MAX_HEIGHT): number {
	const configured = normalizeListRows(configuredRows);
	const overlayRows = resolveOverlayRows(terminalRows, maxHeight);
	const availableListRows = Math.max(1, overlayRows - BROWSE_NON_LIST_ROWS);
	return Math.max(1, Math.min(configured, availableListRows));
}

export function browseWindow(entryCount: number | undefined, selectedDisplayIndex: number | undefined, listRows: number | undefined): BrowseWindow {
	const rows = normalizeListRows(listRows);
	const count = Math.max(0, finiteFloor(entryCount) ?? 0);
	if (count === 0) return { listRows: rows, startIndex: 0, endIndex: 0 };

	const selected = clamp(finiteFloor(selectedDisplayIndex) ?? 0, 0, count - 1);
	const maxStartIndex = Math.max(0, count - rows);
	const startIndex = clamp(selected - Math.floor(rows / 2), 0, maxStartIndex);
	return { listRows: rows, startIndex, endIndex: Math.min(startIndex + rows, count) };
}

export function responsiveBrowseWindow(
	configuredRows: number | undefined,
	terminalRows: number | undefined,
	entryCount: number | undefined,
	selectedDisplayIndex: number | undefined,
	maxHeight: OverlaySize | undefined = DEFAULT_POPUP_MAX_HEIGHT,
): BrowseWindow {
	const listRows = responsiveBrowseListRows(configuredRows, terminalRows, maxHeight);
	return browseWindow(entryCount, selectedDisplayIndex, listRows);
}

export function pageBrowseSelection(selectedIndex: number | undefined, maxSelectedIndex: number | undefined, direction: -1 | 1, listRows: number | undefined): number {
	const selected = Math.max(0, finiteFloor(selectedIndex) ?? 0);
	const maxIndex = Math.max(0, finiteFloor(maxSelectedIndex) ?? 0);
	const step = normalizeListRows(listRows);
	return clamp(selected + direction * step, 0, maxIndex);
}

export function responsiveBrowsePageSelection(
	configuredRows: number | undefined,
	terminalRows: number | undefined,
	selectedIndex: number | undefined,
	maxSelectedIndex: number | undefined,
	direction: -1 | 1,
	maxHeight: OverlaySize | undefined = DEFAULT_POPUP_MAX_HEIGHT,
): number {
	return pageBrowseSelection(selectedIndex, maxSelectedIndex, direction, responsiveBrowseListRows(configuredRows, terminalRows, maxHeight));
}
