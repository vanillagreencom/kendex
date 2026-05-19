import { describe, expect, test } from "bun:test";
import { DEFAULT_POPUP_MAX_HEIGHT } from "../extensions/skills-manager/constants.ts";
import {
	BROWSE_NON_LIST_ROWS,
	browseWindow,
	normalizeListRows,
	pageBrowseSelection,
	resolveOverlayRows,
	responsiveBrowseListRows,
	responsiveBrowsePageSelection,
	responsiveBrowseWindow,
	sanitizePopupMaxHeight,
} from "../extensions/skills-manager/layout.ts";

describe("normalizeListRows", () => {
	test("floors configured rows and allows one-row lists", () => {
		expect(normalizeListRows(7.9)).toBe(7);
		expect(normalizeListRows(1)).toBe(1);
		expect(normalizeListRows(0)).toBe(14);
		expect(normalizeListRows(-4)).toBe(14);
	});

	test("falls back for missing or non-finite values", () => {
		expect(normalizeListRows(undefined, 14)).toBe(14);
		expect(normalizeListRows(Number.NaN, 14)).toBe(14);
		expect(normalizeListRows(Number.POSITIVE_INFINITY, 14)).toBe(14);
	});
});

describe("popup max height normalization", () => {
	test("keeps valid row and percent values", () => {
		expect(sanitizePopupMaxHeight(12.9)).toBe(12);
		expect(sanitizePopupMaxHeight("12")).toBe(12);
		expect(sanitizePopupMaxHeight("25%")).toBe("25%");
	});

	test("falls back for malformed, non-positive, and non-finite values", () => {
		for (const value of ["abc", "-5", "0", "0%", 0, -5, Number.NaN, Number.POSITIVE_INFINITY] as const) {
			expect(sanitizePopupMaxHeight(value)).toBe(DEFAULT_POPUP_MAX_HEIGHT);
			expect(resolveOverlayRows(80, value)).toBe(68);
		}
	});
});

describe("resolveOverlayRows", () => {
	test("guards missing or non-finite terminal rows with finite fallback", () => {
		expect(resolveOverlayRows(undefined)).toBe(20);
		expect(resolveOverlayRows(Number.NaN)).toBe(20);
		expect(resolveOverlayRows(Number.POSITIVE_INFINITY)).toBe(20);
	});

	test("resolves percent max height against terminal rows", () => {
		expect(resolveOverlayRows(40, "50%")).toBe(20);
	});

	test("clamps numeric max height to terminal rows", () => {
		expect(resolveOverlayRows(20, 80)).toBe(20);
		expect(resolveOverlayRows(80, 20)).toBe(20);
	});
});

describe("responsiveBrowseListRows", () => {
	test("documents browse chrome rows", () => {
		expect(BROWSE_NON_LIST_ROWS).toBe(6);
	});

	test("always returns finite integer >= 1 for bad terminal rows", () => {
		for (const terminalRows of [undefined, Number.NaN, Number.POSITIVE_INFINITY] as const) {
			const rows = responsiveBrowseListRows(14, terminalRows);
			expect(Number.isInteger(rows)).toBe(true);
			expect(Number.isFinite(rows)).toBe(true);
			expect(rows).toBe(14);
		}
	});

	test("keeps configured rows as upper bound on large terminals", () => {
		expect(responsiveBrowseListRows(14, 80)).toBe(14);
		expect(responsiveBrowseListRows(22, 80)).toBe(22);
	});

	test("shrinks rows on short terminals to leave popup chrome visible", () => {
		expect(responsiveBrowseListRows(14, 20)).toBe(11);
	});

	test("collapses to one row on tiny terminals", () => {
		expect(responsiveBrowseListRows(14, 4)).toBe(1);
	});

	test("respects explicit popup max height", () => {
		expect(responsiveBrowseListRows(14, 80, 12)).toBe(6);
		expect(responsiveBrowseListRows(14, 80, "25%")).toBe(14);
	});
});

describe("browse window", () => {
	function expectSelectedVisible(window: { startIndex: number; endIndex: number }, selectedDisplayIndex: number): void {
		expect(selectedDisplayIndex).toBeGreaterThanOrEqual(window.startIndex);
		expect(selectedDisplayIndex).toBeLessThan(window.endIndex);
	}

	test("centers selected item with exact representative rows", () => {
		expect(browseWindow(30, 20, 11)).toEqual({ listRows: 11, startIndex: 15, endIndex: 26 });
	});

	test("tiny terminals render one selected row", () => {
		const window = responsiveBrowseWindow(14, 4, 10, 6);
		expect(window).toEqual({ listRows: 1, startIndex: 6, endIndex: 7 });
		expectSelectedVisible(window, 6);
	});

	test("short terminals use responsive rows and keep selected item visible", () => {
		const window = responsiveBrowseWindow(14, 20, 30, 20);
		expect(window).toEqual({ listRows: 11, startIndex: 15, endIndex: 26 });
		expectSelectedVisible(window, 20);
	});

	test("large terminals preserve configured default row count", () => {
		const window = responsiveBrowseWindow(14, 80, 40, 20);
		expect(window).toEqual({ listRows: 14, startIndex: 13, endIndex: 27 });
		expectSelectedVisible(window, 20);
	});

	test("configured listRows remains upper bound on large terminals", () => {
		const window = responsiveBrowseWindow(22, 80, 40, 20);
		expect(window).toEqual({ listRows: 22, startIndex: 9, endIndex: 31 });
		expectSelectedVisible(window, 20);
	});

	test("selected item near end remains visible", () => {
		const window = responsiveBrowseWindow(14, 20, 30, 29);
		expect(window).toEqual({ listRows: 11, startIndex: 19, endIndex: 30 });
		expectSelectedVisible(window, 29);
	});
});

describe("page movement", () => {
	test("plain page movement clamps to selectable range", () => {
		expect(pageBrowseSelection(5, 30, -1, 11)).toBe(0);
		expect(pageBrowseSelection(25, 30, 1, 11)).toBe(30);
	});

	test("tiny terminal page step uses one responsive row", () => {
		expect(responsiveBrowsePageSelection(14, 4, 5, 30, 1)).toBe(6);
		expect(responsiveBrowsePageSelection(14, 4, 5, 30, -1)).toBe(4);
	});

	test("short terminal page step uses shortened responsive rows", () => {
		expect(responsiveBrowsePageSelection(14, 20, 10, 30, 1)).toBe(21);
		expect(responsiveBrowsePageSelection(14, 20, 10, 30, -1)).toBe(0);
	});

	test("large terminal page step uses configured upper-bound rows", () => {
		expect(responsiveBrowsePageSelection(22, 80, 3, 30, 1)).toBe(25);
		expect(responsiveBrowsePageSelection(22, 80, 20, 30, 1)).toBe(30);
	});
});
