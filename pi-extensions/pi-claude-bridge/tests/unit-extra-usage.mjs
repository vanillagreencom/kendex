/**
 * Tests for extra-usage detection helpers.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { formatResetTimestamp, isExtraUsageRequiredMessage, isUsageLimitMessage, uniqueNonEmptyLines } from "../src/index.ts";

describe("isExtraUsageRequiredMessage", () => {
	it("detects Claude Code extra-usage rate-limit text", () => {
		assert.equal(isExtraUsageRequiredMessage("Fast mode requires extra usage billing — /extra-usage to enable"), true);
		assert.equal(isExtraUsageRequiredMessage({ message: "Extra usage is required for 1M context" }), true);
		assert.equal(isExtraUsageRequiredMessage(new Error("overage not provisioned")), true);
	});

	it("ignores normal rate-limit text", () => {
		assert.equal(isExtraUsageRequiredMessage("Claude rate limited; resets at 12:00"), false);
	});

	it("deduplicates repeated Claude Code error lines", () => {
		assert.deepEqual(uniqueNonEmptyLines(["You're out of extra usage", "You're out of extra usage", " other "]), [
			"You're out of extra usage",
			"other",
		]);
	});

	it("formats reset timestamps with timezone context", () => {
		const formatted = formatResetTimestamp("2026-05-23T13:19:55Z");
		assert.match(formatted, /2026|May|23|13|1|UTC|GMT|AM|PM/i);
		assert.equal(formatResetTimestamp("not a date"), "unknown");
	});
});

describe("isUsageLimitMessage", () => {
	it("matches the CLI's own usage-limit copy that the extra-usage regex never did", () => {
		// The under-match the audit called out: a plain weekly-limit rejection.
		assert.equal(isUsageLimitMessage("You've hit your weekly limit · resets Thursday 4am"), true);
		assert.equal(isExtraUsageRequiredMessage("You've hit your weekly limit · resets Thursday 4am"), false);
		assert.equal(isUsageLimitMessage("You've reached your session limit"), true);
		assert.equal(isUsageLimitMessage("You're out of usage credits"), true);
	});

	it("matches extra-usage variants of the official prefixes too", () => {
		assert.equal(isUsageLimitMessage("You're out of extra usage"), true);
		assert.equal(isUsageLimitMessage("Your seat type doesn't include extra usage"), true);
	});

	it("matches text embedded in a result payload's errors array", () => {
		const resultMessage = {
			type: "result",
			subtype: "error_during_execution",
			errors: ["You've hit your weekly limit · resets Thursday 4am"],
		};
		assert.equal(isUsageLimitMessage(resultMessage), true);
	});

	it("ignores unrelated errors and non-limit rate-limit prose", () => {
		assert.equal(isUsageLimitMessage("Claude rate limited; resets at 12:00"), false);
		assert.equal(isUsageLimitMessage(new Error("ECONNRESET")), false);
		assert.equal(isUsageLimitMessage(undefined), false);
	});
});
