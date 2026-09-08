import { expect, test } from "bun:test";
import {
	browseWindow, normalizeListRows, pageBrowseSelection, resolveOverlayRows,
	responsiveBrowseListRows, responsiveBrowsePageSelection, responsiveBrowseWindow,
	sanitizePopupMaxHeight,
} from "../extensions/skills-manager/layout.ts";

for (const [name, value, expected] of [
	["fraction floors", 7.9, 7], ["one row", 1, 1], ["zero falls back", 0, 14],
	["negative falls back", -4, 14], ["missing falls back", undefined, 14],
	["NaN falls back", Number.NaN, 14], ["infinity falls back", Number.POSITIVE_INFINITY, 14],
] as const) {
	test(`normalizeListRows: ${name}`, () => expect(normalizeListRows(value)).toBe(expected));
}

for (const [name, value, expected] of [
	["fraction floors", 12.9, 12], ["row string", "12", 12], ["percent", "25%", "25%"],
	["text", "abc", "86%"], ["negative string", "-5", "86%"], ["zero string", "0", "86%"],
	["zero percent", "0%", "86%"], ["zero", 0, "86%"], ["negative", -5, "86%"],
	["NaN", Number.NaN, "86%"], ["infinity", Number.POSITIVE_INFINITY, "86%"],
] as const) {
	test(`sanitizePopupMaxHeight: ${name}`, () => expect(sanitizePopupMaxHeight(value)).toBe(expected));
}

for (const [name, terminal, maxHeight, expected] of [
	["missing terminal", undefined, undefined, 20], ["NaN terminal", Number.NaN, undefined, 20],
	["infinite terminal", Number.POSITIVE_INFINITY, undefined, 20], ["percent", 40, "50%", 20],
	["clamp to terminal", 20, 80, 20], ["clamp to configured rows", 80, 20, 20],
	["text height", 80, "abc", 68], ["negative string height", 80, "-5", 68],
	["zero string height", 80, "0", 68], ["zero percent height", 80, "0%", 68],
	["zero height", 80, 0, 68], ["negative height", 80, -5, 68],
	["NaN height", 80, Number.NaN, 68], ["infinite height", 80, Number.POSITIVE_INFINITY, 68],
] as const) {
	test(`resolveOverlayRows: ${name}`, () => expect(resolveOverlayRows(terminal, maxHeight)).toBe(expected));
}

for (const [name, configured, terminal, maxHeight, expected] of [
	["missing terminal", 14, undefined, undefined, 14], ["NaN terminal", 14, Number.NaN, undefined, 14],
	["infinite terminal", 14, Number.POSITIVE_INFINITY, undefined, 14],
	["configured default", 14, 80, undefined, 14], ["configured larger", 22, 80, undefined, 22],
	["short terminal", 14, 20, undefined, 11], ["tiny terminal", 14, 4, undefined, 1],
	["six chrome rows remain", 14, 80, 12, 6], ["percent height", 14, 80, "25%", 14],
] as const) {
	test(`responsiveBrowseListRows: ${name}`, () => {
		const rows = responsiveBrowseListRows(configured, terminal, maxHeight);
		expect(rows).toBe(expected);
		expect(Number.isInteger(rows)).toBe(true);
		expect(Number.isFinite(rows)).toBe(true);
	});
}

test("browseWindow centers the selected item", () => {
	expect(browseWindow(30, 20, 11)).toEqual({ listRows: 11, startIndex: 15, endIndex: 26 });
});

for (const [name, configured, terminal, count, selected, expected] of [
	["tiny terminal", 14, 4, 10, 6, { listRows: 1, startIndex: 6, endIndex: 7 }],
	["short terminal", 14, 20, 30, 20, { listRows: 11, startIndex: 15, endIndex: 26 }],
	["default rows", 14, 80, 40, 20, { listRows: 14, startIndex: 13, endIndex: 27 }],
	["larger rows", 22, 80, 40, 20, { listRows: 22, startIndex: 9, endIndex: 31 }],
	["near end", 14, 20, 30, 29, { listRows: 11, startIndex: 19, endIndex: 30 }],
] as const) {
	test(`responsiveBrowseWindow: ${name}`, () => {
		const window = responsiveBrowseWindow(configured, terminal, count, selected);
		expect(window).toEqual(expected);
		expect(selected).toBeGreaterThanOrEqual(window.startIndex);
		expect(selected).toBeLessThan(window.endIndex);
	});
}

for (const [name, selected, direction, expected] of [
	["lower bound", 5, -1, 0], ["upper bound", 25, 1, 30],
] as const) {
	test(`pageBrowseSelection: ${name}`, () => expect(pageBrowseSelection(selected, 30, direction, 11)).toBe(expected));
}

for (const [name, configured, terminal, selected, direction, expected] of [
	["tiny forward", 14, 4, 5, 1, 6], ["tiny backward", 14, 4, 5, -1, 4],
	["short forward", 14, 20, 10, 1, 21], ["short backward", 14, 20, 10, -1, 0],
	["large step", 22, 80, 3, 1, 25], ["large clamp", 22, 80, 20, 1, 30],
] as const) {
	test(`responsiveBrowsePageSelection: ${name}`, () => expect(responsiveBrowsePageSelection(configured, terminal, selected, 30, direction)).toBe(expected));
}
