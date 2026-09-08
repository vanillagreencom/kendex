/**
 * Tests for usage-limit message helpers. (The narrow extra-usage detector and
 * its /extra-usage helper flow were removed in 3.0 — Extra Usage is owned by
 * the claude.ai account settings.)
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { formatResetTimestamp, isUsageLimitMessage, uniqueNonEmptyLines } from "../src/index.ts";

describe("Claude usage-limit messages", () => {
	it("deduplicates repeated Claude Code error lines", () => {
		assert.deepEqual(uniqueNonEmptyLines(["You're out of extra usage", "You're out of extra usage", " other "]), [
			"You're out of extra usage",
			"other",
		]);
	});

	it("formats reset timestamps with timezone context", () => {
		const originalTimezone = process.env.TZ;
		process.env.TZ = "UTC";
		try {
			const formatted = formatResetTimestamp("2026-05-23T13:19:55Z");
			for (const [field, pattern] of [
				["year", /2026/], ["day", /\b23\b/], ["minute and second", /:19:55/],
				["time zone", /(?:UTC|GMT)$/],
			]) {
				assert.match(formatted, pattern, field);
			}
			assert.equal(formatResetTimestamp("not a date"), "unknown");
		} finally {
			if (originalTimezone === undefined) delete process.env.TZ;
			else process.env.TZ = originalTimezone;
		}
	});

	it("classifies CLI usage-limit inputs independently", () => {
		// The CLI emits these strings directly and in result.errors.
		for (const [name, input, expected] of [
			["weekly plan", "You've hit your weekly limit · resets Thursday 4am", true],
			["session plan", "You've reached your session limit", true],
			["credits", "You're out of usage credits", true],
			["extra usage", "You're out of extra usage", true],
			["seat type", "Your seat type doesn't include extra usage", true],
			["result errors", { type: "result", subtype: "error_during_execution", errors: ["You've hit your weekly limit · resets Thursday 4am"] }, true],
			["generic rate limit", "Claude rate limited; resets at 12:00", false],
			["network error", new Error("ECONNRESET"), false],
			["absent", undefined, false],
		]) {
			assert.equal(isUsageLimitMessage(input), expected, name);
		}
	});
});
