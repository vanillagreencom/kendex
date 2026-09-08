import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { __testSetSdkQueryFactory, probeClaudeAccountProfile } from "../src/index.ts";
import { fakeSdkQuery } from "./lib/fake-sdk-query.mjs";

afterEach(() => __testSetSdkQueryFactory());

describe("account host probe (probeProfile)", () => {
	it("settles within its deadline and kills a stalled probe child", async (t) => {
		t.mock.timers.enable({ apis: ["setTimeout"] });
		// probeProfile is a published entry point and `signal` is optional: a
		// wedged child (never ends, even after close) must not hang the returned
		// promise forever.
		let closed = false;
		__testSetSdkQueryFactory(() => ({
			async *[Symbol.asyncIterator]() {
				yield { type: "system", subtype: "init", session_id: "probe-session" };
				await new Promise(() => {});
			},
			close() { closed = true; },
			async interrupt() {},
			async accountInfo() {
				return { email: "a@example.com", subscriptionType: "max" };
			},
			async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET() {
				return { subscription_type: "max" };
			},
		}));

		const pending = probeClaudeAccountProfile({
			profile: { profileId: "a", label: "account-a" },
			cwd: process.cwd(),
			deadlineMs: 100,
		});
		t.mock.timers.tick(99);
		assert.equal(closed, false, "the child stays open before its deadline");
		t.mock.timers.tick(1);
		const result = await pending;
		assert.deepEqual(result, {});
		assert.equal(closed, true, "the expired probe must kill its child");
	});

	it("spawns the probe child with tool isolation AND a deny-all PreToolUse hook", async () => {
		// The probe runs /usage under bypassPermissions, so tool containment is
		// the only gate — it must carry both layers (C12).
		let probeOptions;
		__testSetSdkQueryFactory((input) => {
			probeOptions = input.options;
			return fakeSdkQuery([{ type: "system", subtype: "init", session_id: "probe-session" }], "a", { usageProbes: [] });
		});

		await probeClaudeAccountProfile({
			profile: { profileId: "a", label: "account-a" },
			cwd: process.cwd(),
			deadlineMs: 500,
		});
		assert.deepEqual(probeOptions.tools, [], "built-in tool set removed");
		assert.ok(probeOptions.disallowedTools.includes("Bash"), "built-ins disallowed");
		const hook = probeOptions.hooks?.PreToolUse?.[0]?.hooks?.[0];
		assert.equal(typeof hook, "function", "deny-all PreToolUse hook registered");
		const out = await hook({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {} }, "t1", { signal: new AbortController().signal });
		assert.equal(out.hookSpecificOutput.permissionDecision, "deny", "every tool call is denied");
	});

	it("returns identity and usage when the probe completes before the deadline", async () => {
		__testSetSdkQueryFactory(() => {
			let closed = false;
			return {
				async *[Symbol.asyncIterator]() {
					if (!closed) yield { type: "system", subtype: "init", session_id: "probe-session" };
				},
				close() { closed = true; },
				async interrupt() { closed = true; },
				async accountInfo() {
					return { email: "a@example.com", organization: "Org", subscriptionType: "max" };
				},
				async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET() {
					return { subscription_type: "max" };
				},
			};
		});

		const result = await probeClaudeAccountProfile({
			profile: { profileId: "a", label: "account-a" },
			cwd: process.cwd(),
		});
		assert.equal(result.identity?.email, "a@example.com");
		assert.deepEqual(result.usage, { subscription_type: "max" });
	});
});
