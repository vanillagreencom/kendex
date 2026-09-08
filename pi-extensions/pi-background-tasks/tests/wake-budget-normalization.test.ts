import { describe, expect, test } from "bun:test";
import type { OutputWakeBudgetState } from "../extensions/types.js";
import { normalizeOutputWakeBudget } from "../extensions/wake-events.js";

describe("output wake budget normalization", () => {
	test("normalizes each input into independent budget state", () => {
		const rows: Array<{ name: string; input: unknown; expected: OutputWakeBudgetState }> = [
			{
				name: "undefined budget", input: undefined,
				expected: { wakes: 0, bytes: 0, exhausted: false, announcedAt: null },
			},
			{
				name: "null budget", input: null,
				expected: { wakes: 0, bytes: 0, exhausted: false, announcedAt: null },
			},
			{
				name: "malformed wake count preserves other fields",
				input: { wakes: "garbage", bytes: 100, exhausted: true, announcedAt: 999 },
				expected: { wakes: 0, bytes: 100, exhausted: true, announcedAt: 999 },
			},
			{
				name: "negative byte count preserves other fields",
				input: { wakes: 3, bytes: -5, exhausted: true, announcedAt: 999 },
				expected: { wakes: 3, bytes: 0, exhausted: true, announcedAt: 999 },
			},
			{
				name: "malformed exhausted flag preserves other fields",
				input: { wakes: 3, bytes: 100, exhausted: "yes", announcedAt: 999 },
				expected: { wakes: 3, bytes: 100, exhausted: false, announcedAt: 999 },
			},
			{
				name: "malformed announcement time preserves other fields",
				input: { wakes: 3, bytes: 100, exhausted: true, announcedAt: "later" },
				expected: { wakes: 3, bytes: 100, exhausted: true, announcedAt: null },
			},
			{
				name: "normalized budget does not share the source object",
				input: { wakes: 3, bytes: 100, exhausted: true, announcedAt: 999 },
				expected: { wakes: 3, bytes: 100, exhausted: true, announcedAt: 999 },
			},
			{
				name: "JSON budget round trip retains every field",
				input: JSON.parse(JSON.stringify({ wakes: 7, bytes: 1234, exhausted: true, announcedAt: 555 })),
				expected: { wakes: 7, bytes: 1234, exhausted: true, announcedAt: 555 },
			},
			{
				name: "combined malformed budget fields",
				input: { wakes: "garbage", bytes: -5, exhausted: "yes", announcedAt: "later" },
				expected: { wakes: 0, bytes: 0, exhausted: false, announcedAt: null },
			},
		];
		expect.assertions(rows.length + 1);
		expect(rows.length, "wake budget normalization table must contain cases").toBeGreaterThan(0);
		for (const row of rows) {
			const sourceBefore = row.input && typeof row.input === "object" ? { ...row.input } : row.input;
			const normalized = normalizeOutputWakeBudget(row.input);
			const normalizedBeforeMutation = { ...normalized };
			Object.assign(normalized, { wakes: 7, bytes: 222, exhausted: false, announcedAt: 123 });
			expect({ normalized: normalizedBeforeMutation, source: row.input }, row.name).toStrictEqual({ normalized: row.expected, source: sourceBefore });
		}
	});
});
