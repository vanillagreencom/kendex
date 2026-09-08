import { expect, test } from "bun:test";
import { DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES, DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES } from "../extensions/constants.js";
import { wouldExhaustOutputWakeBudget } from "../extensions/wake-events.js";

test("output wake budget limits", () => {
	const limits = { maxWakes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_WAKES, maxBytes: DEFAULT_OUTPUT_WAKE_BUDGET_MAX_BYTES };
	const rows = [
		{ name: "wake count cap", budget: { wakes: limits.maxWakes, bytes: 0, exhausted: false, announcedAt: null }, limits, nextBytes: 0, expected: true },
		{ name: "byte cap", budget: { wakes: 0, bytes: limits.maxBytes, exhausted: false, announcedAt: null }, limits, nextBytes: 1, expected: true },
		{ name: "disabled caps", budget: { wakes: 100, bytes: 1_000_000, exhausted: false, announcedAt: null }, limits: { maxWakes: 0, maxBytes: 0 }, nextBytes: 1_000, expected: false },
		{ name: "remaining capacity", budget: { wakes: 0, bytes: 0, exhausted: false, announcedAt: null }, limits, nextBytes: 1, expected: false },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length).toBeGreaterThan(0);
	for (const row of rows) expect(wouldExhaustOutputWakeBudget(row.budget, row.limits, row.nextBytes), row.name).toBe(row.expected);
});
