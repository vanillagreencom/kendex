import { describe, expect, test } from "bun:test";
import { normalizeListRows, resolveOverlayRows, responsiveBrowseListRows } from "../extensions/skills-manager/layout.ts";

describe("normalizeListRows", () => {
	test("floors configured rows and allows one-row lists", () => {
		expect(normalizeListRows(7.9)).toBe(7);
		expect(normalizeListRows(0)).toBe(1);
		expect(normalizeListRows(-4)).toBe(1);
	});

	test("falls back for non-finite values", () => {
		expect(normalizeListRows(Number.NaN, 14)).toBe(14);
		expect(normalizeListRows(Number.POSITIVE_INFINITY, 14)).toBe(14);
	});
});

describe("resolveOverlayRows", () => {
	test("resolves percent max height against terminal rows", () => {
		expect(resolveOverlayRows(40, "50%")).toBe(20);
	});

	test("clamps numeric max height to terminal rows", () => {
		expect(resolveOverlayRows(20, 80)).toBe(20);
		expect(resolveOverlayRows(80, 20)).toBe(20);
	});
});

describe("responsiveBrowseListRows", () => {
	test("keeps configured rows as upper bound on large terminals", () => {
		expect(responsiveBrowseListRows(14, 80)).toBe(14);
		expect(responsiveBrowseListRows(22, 80)).toBe(22);
	});

	test("shrinks rows on short terminals to leave popup chrome visible", () => {
		const rows = responsiveBrowseListRows(14, 20);
		expect(rows).toBeLessThan(14);
		expect(rows).toBeGreaterThanOrEqual(1);
	});

	test("collapses to one row on tiny terminals", () => {
		expect(responsiveBrowseListRows(14, 4)).toBe(1);
	});

	test("respects explicit popup max height", () => {
		expect(responsiveBrowseListRows(14, 80, 12)).toBe(4);
		expect(responsiveBrowseListRows(14, 80, "25%")).toBe(12);
	});
});
