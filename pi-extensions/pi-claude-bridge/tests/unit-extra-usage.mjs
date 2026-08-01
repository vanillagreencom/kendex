/**
 * Tests for extra-usage detection helpers.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
	__testSetSdkQueryFactory,
	formatResetTimestamp,
	isExtraUsageRequiredMessage,
	isUsageLimitMessage,
	runExtraUsageCommand,
	uniqueNonEmptyLines,
} from "../src/index.ts";
import { CLAUDE_ACCOUNT_ROUTER_SYMBOL } from "../src/account-router.ts";

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

describe("Extra Usage command boundary", () => {
	it("blocks execution when disabled and targets the selected managed profile when enabled", async () => {
		const root = mkdtempSync(path.join(tmpdir(), "claude-extra-command-"));
		const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
		const previousIsolated = process.env.CLAUDE_BRIDGE_ISOLATED;
		const previousApiKey = process.env.ANTHROPIC_API_KEY;
		const notifications = [];
		const ctx = {
			cwd: root,
			model: { id: "claude-opus-5", provider: "pi-claude" },
			sessionManager: { getSessionId: () => "extra-session" },
			ui: { notify(message, level) { notifications.push({ message, level }); } },
		};
		try {
			process.env.PI_CODING_AGENT_DIR = root;
			process.env.CLAUDE_BRIDGE_ISOLATED = "1";
			process.env.ANTHROPIC_API_KEY = "must-not-leak";
			writeFileSync(path.join(root, "claude-bridge.json"), JSON.stringify({ provider: { allowExtraUsage: false } }));
			let calls = 0;
			__testSetSdkQueryFactory(() => {
				calls += 1;
				throw new Error("disabled command must not spawn");
			});
			await runExtraUsageCommand(ctx);
			assert.equal(calls, 0);
			assert.ok(notifications.some((entry) => /blocked/.test(entry.message)));

			writeFileSync(path.join(root, "claude-bridge.json"), JSON.stringify({ provider: { allowExtraUsage: true } }));
			globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = {
				version: 1,
				current() { return { profileId: "selected", label: "selected", configDir: "/profiles/selected" }; },
				acquire() { throw new Error("current route should win"); },
			};
			let helperEnv;
			__testSetSdkQueryFactory((input) => {
				calls += 1;
				helperEnv = input.options.env;
				return {
					async *[Symbol.asyncIterator]() {
						yield { type: "result", subtype: "success", result: "done" };
					},
					close() {},
				};
			});
			await runExtraUsageCommand(ctx);
			assert.equal(calls, 1);
			assert.equal(helperEnv.CLAUDE_CONFIG_DIR, "/profiles/selected");
			assert.equal(helperEnv.ANTHROPIC_API_KEY, undefined);
		} finally {
			__testSetSdkQueryFactory();
			delete globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL];
			if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
			if (previousIsolated === undefined) delete process.env.CLAUDE_BRIDGE_ISOLATED;
			else process.env.CLAUDE_BRIDGE_ISOLATED = previousIsolated;
			if (previousApiKey === undefined) delete process.env.ANTHROPIC_API_KEY;
			else process.env.ANTHROPIC_API_KEY = previousApiKey;
			rmSync(root, { recursive: true, force: true });
		}
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
