import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";

import {
	__testSetBridgeIntegrityState,
	__testSetSdkQueryFactory,
	streamClaudeAgentSdk,
} from "../src/index.ts";
import { CLAUDE_ACCOUNT_ROUTER_SYMBOL } from "../src/account-router.ts";
import { resetStack } from "../src/query-state.ts";

const model = {
	id: "claude-haiku-4-5",
	name: "Claude Haiku",
	api: "claude-bridge",
	provider: "claude-bridge",
	baseUrl: "claude-bridge",
	reasoning: true,
	input: ["text", "image"],
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	contextWindow: 200000,
	maxTokens: 8192,
};
const context = { messages: [{ role: "user", content: "hello", timestamp: Date.now() }] };

function fakeSdkQuery(messages, accountLabel, observed) {
	let closed = false;
	return {
		async *[Symbol.asyncIterator]() {
			for (const message of messages) {
				if (closed) break;
				if (message instanceof Error) throw message;
				yield message;
			}
		},
		close() { closed = true; },
		async interrupt() { closed = true; },
		async accountInfo() {
			return { email: `${accountLabel}@example.com`, subscriptionType: "max" };
		},
		async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET() {
			observed.usageProbes.push(accountLabel);
			return { subscription_type: "max", rate_limits_available: true, rate_limits: null };
		},
	};
}

function makeRouter(observed, options = {}) {
	const accounts = [
		{ profileId: "a", label: "account-a", configDir: "/profiles/a" },
		{ profileId: "b", label: "account-b", configDir: "/profiles/b" },
	];
	return {
		version: 1,
		acquire(input) {
			observed.acquires.push(input);
			if (options.unavailable) {
				const error = new Error("No Claude subscription account is available");
				if (options.resetAtMs) Object.assign(error, { resetAtMs: options.resetAtMs, rateLimitType: "all_accounts" });
				throw error;
			}
			const excluded = new Set(input.excludedProfileIds ?? []);
			const selected = accounts.find((account) => !excluded.has(account.profileId));
			if (!selected) throw new Error("All Claude accounts are cooling down");
			return selected;
		},
		recordIdentity(profileId, identity) { observed.identities.push({ profileId, identity }); },
		recordUsage(profileId) { observed.usageRecords.push(profileId); },
		recordRateLimit(profileId, info) {
			observed.rateLimits.push({ profileId, info });
			return Date.now() + 60_000;
		},
		recordFailure(profileId, kind) { observed.failures.push({ profileId, kind }); },
		recordSuccess(profileId) { observed.successes.push(profileId); },
		current() { return undefined; },
	};
}

function observedState() {
	return {
		acquires: [],
		queryEnvs: [],
		usageProbes: [],
		usageRecords: [],
		identities: [],
		rateLimits: [],
		failures: [],
		successes: [],
	};
}

async function collect(stream) {
	const events = [];
	for await (const event of stream) events.push(event);
	return events;
}

beforeEach(() => {
	process.env.CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT = "0";
	resetStack();
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
});

afterEach(() => {
	delete process.env.CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT;
	delete globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL];
	__testSetSdkQueryFactory();
	resetStack();
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
});

describe("managed account stream rotation", () => {
	it("retries a rejected pre-output request on the next profile without leaking the first attempt", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(((input) => {
			observed.queryEnvs.push(input.options.env);
			calls += 1;
			if (calls === 1) {
				return fakeSdkQuery([
					{ type: "system", subtype: "init", session_id: "session-a" },
					{
						type: "rate_limit_event",
						rate_limit_info: {
							status: "rejected",
							rateLimitType: "five_hour",
							resetsAt: new Date(Date.now() + 60_000).toISOString(),
						},
					},
					{
						type: "assistant",
						error: "rate_limit",
						message: {
							model: "<synthetic>",
							content: [{ type: "text", text: "You've hit your session limit" }],
							usage: { input_tokens: 0, output_tokens: 0 },
						},
					},
					{ type: "result", subtype: "success", result: "You've hit your session limit" },
				], "a", observed);
			}
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "session-b" },
				{ type: "result", subtype: "success", result: "ok-from-b" },
			], "b", observed);
		}));

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "pi-session" }));
		assert.equal(calls, 2);
		assert.equal(observed.acquires.length, 2);
		assert.deepEqual(observed.acquires[1].excludedProfileIds, ["a"]);
		assert.deepEqual(observed.queryEnvs.map((env) => env.CLAUDE_CONFIG_DIR), [
			"/profiles/a", "/profiles/b",
		]);
		assert.deepEqual(
			events.filter((event) => event.type === "text_delta").map((event) => event.delta),
			["ok-from-b"],
		);
		assert.equal(events.filter((event) => event.type === "error").length, 0);
		assert.equal(events.filter((event) => event.type === "start").length, 1);
		assert.equal(observed.rateLimits[0].profileId, "a");
		assert.deepEqual(observed.successes, ["b"]);
	});

	it("rotates on a pre-output network failure", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory((input) => {
			observed.queryEnvs.push(input.options.env);
			calls += 1;
			return calls === 1
				? fakeSdkQuery([
					{ type: "system", subtype: "init", session_id: "session-a" },
					new Error("socket timeout before response"),
				], "a", observed)
				: fakeSdkQuery([
					{ type: "system", subtype: "init", session_id: "session-b" },
					{ type: "result", subtype: "success", result: "network-recovered" },
				], "b", observed);
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "network-session" }));
		assert.equal(calls, 2);
		assert.deepEqual(observed.failures, [{ profileId: "a", kind: "network" }]);
		assert.ok(events.some((event) => event.type === "text_delta" && event.delta === "network-recovered"));
		assert.equal(events.some((event) => event.type === "error"), false);
	});

	it("never replays after visible text has committed", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(((input) => {
			calls += 1;
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "session-a" },
				{
					type: "stream_event",
					event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } },
				},
				{
					type: "stream_event",
					event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
				},
				{
					type: "stream_event",
					event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "already-visible" } },
				},
				{
					type: "assistant",
					error: "rate_limit",
					message: { model: model.id, content: [{ type: "text", text: "already-visible" }], usage: { input_tokens: 1, output_tokens: 1 } },
				},
				{
					type: "rate_limit_event",
					rate_limit_info: {
						status: "rejected",
						rateLimitType: "five_hour",
						resetsAt: new Date(Date.now() + 60_000).toISOString(),
					},
				},
				{ type: "result", subtype: "error_during_execution", errors: ["rate limit"] },
			], "a", observed);
		}));

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "pi-session" }));
		assert.equal(calls, 1);
		assert.equal(observed.acquires.length, 1);
		assert.ok(events.some((event) => event.type === "text_delta" && event.delta === "already-visible"));
		assert.equal(events.filter((event) => event.type === "error").length, 1);
	});

	it("uses Opus only after the account router reports every Fable allowance spent", async () => {
		const observed = observedState();
		const fableModel = { ...model, id: "claude-fable-5", name: "Claude Fable 5" };
		const router = makeRouter(observed);
		router.acquire = (input) => {
			observed.acquires.push(input);
			return {
				profileId: "b",
				label: "account-b",
				configDir: "/profiles/b",
				modelId: "claude-opus-5",
				fallbackReason: "fable-quota",
			};
		};
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = router;
		let queryOptions;
		__testSetSdkQueryFactory((input) => {
			queryOptions = input.options;
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "opus-session" },
				{ type: "result", subtype: "success", result: "opus-after-fable" },
			], "b", observed);
		});

		const events = await collect(streamClaudeAgentSdk(fableModel, context, { sessionId: "fable-spent" }));
		assert.equal(queryOptions.model, "claude-opus-5");
		assert.equal(queryOptions.fallbackModel, "claude-opus-4-8");
		assert.equal(queryOptions.env.CLAUDE_CONFIG_DIR, "/profiles/b");
		assert.ok(events.some((event) => event.type === "text_delta" && event.delta === "opus-after-fable"));
	});

	it("does not let SDK model fallback skip another managed Fable account", async () => {
		const observed = observedState();
		const fableModel = { ...model, id: "claude-fable-5", name: "Claude Fable 5" };
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let queryOptions;
		__testSetSdkQueryFactory((input) => {
			queryOptions = input.options;
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "fable-session" },
				{ type: "result", subtype: "success", result: "fable-first" },
			], "a", observed);
		});

		await collect(streamClaudeAgentSdk(fableModel, context, { sessionId: "fable-ready" }));
		assert.equal(queryOptions.model, "claude-fable-5");
		assert.equal(queryOptions.fallbackModel, undefined);
	});

	it("surfaces an unavailable pool without starting Claude Code", async () => {
		const observed = observedState();
		const resetAtMs = Date.now() + 60_000;
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed, { unavailable: true, resetAtMs });
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			throw new Error("must not start");
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "pi-session" }));
		assert.equal(calls, 0);
		assert.equal(events.length, 1);
		assert.equal(events[0].type, "error");
		assert.match(events[0].error.errorMessage, /No Claude subscription account/);
		assert.equal(events[0].error.resetAtMs, resetAtMs);
		assert.equal(events[0].error.rateLimitType, "all_accounts");
	});

	it("reports an already-aborted request without rotating", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "session-a" },
				{ type: "result", subtype: "success", result: "must-not-render" },
			], "a", observed);
		});
		const controller = new AbortController();
		controller.abort();
		const events = await collect(streamClaudeAgentSdk(model, context, {
			sessionId: "aborted-session",
			signal: controller.signal,
		}));
		assert.equal(calls, 1);
		assert.equal(observed.acquires.length, 1);
		assert.equal(events.filter((event) => event.type === "error").length, 1);
		assert.equal(events.find((event) => event.type === "error")?.reason, "aborted");
	});

	it("does not rotate an unclassified invalid request", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "session-a" },
				{ type: "result", subtype: "error_during_execution", errors: ["invalid request shape"] },
			], "a", observed);
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "pi-session" }));
		assert.equal(calls, 1);
		assert.equal(observed.acquires.length, 1);
		assert.equal(events.filter((event) => event.type === "error").length, 1);
	});
});
