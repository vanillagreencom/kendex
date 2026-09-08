import { expect, test } from "bun:test";
import { defaultNotifyMode, resolveNotifyMode } from "../extensions/wake-events.js";

test("default output notify mode", () => {
	const rows = [
		{ name: "pattern", pattern: "READY", expected: "first-match-only" },
		{ name: "missing pattern", pattern: undefined, expected: "transition" },
		{ name: "blank pattern", pattern: "   ", expected: "transition" },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length).toBeGreaterThan(0);
	for (const row of rows) expect(defaultNotifyMode(row.pattern), row.name).toBe(row.expected);
});

test("resolved output notify mode", () => {
	const rows = [
		{ name: "explicit always", mode: "always", pattern: undefined, expected: "always" },
		{ name: "explicit transition", mode: "transition", pattern: "READY", expected: "transition" },
		{ name: "explicit first match", mode: "first-match-only", pattern: undefined, expected: "first-match-only" },
		{ name: "pattern fallback", mode: undefined, pattern: "READY", expected: "first-match-only" },
		{ name: "missing fallback", mode: undefined, pattern: undefined, expected: "transition" },
		{ name: "invalid fallback", mode: "garbage", pattern: "READY", expected: "first-match-only" },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length).toBeGreaterThan(0);
	for (const row of rows) expect(resolveNotifyMode(row.mode, row.pattern), row.name).toBe(row.expected);
});
