import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";

import {
	__testGetBridgeIntegrityState,
	__testSetBridgeIntegrityState,
	__testSetSdkQueryFactory,
	streamClaudeAgentSdk,
} from "../src/index.ts";
import { CLAUDE_ACCOUNT_ROUTER_SYMBOL } from "../src/account-router.ts";
import { setExtensionApi } from "../src/bridge-state.ts";
import { ctx, resetStack } from "../src/query-state.ts";
import { RATE_LIMIT_AUTO_RESUME_EVENT } from "../src/rate-limit.ts";

const model = {
	id: "claude-haiku-4-5",
	name: "Claude Haiku",
	api: "claude-bridge",
	provider: "pi-claude",
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
	setExtensionApi(undefined);
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
});

afterEach(() => {
	delete process.env.CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT;
	delete globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL];
	__testSetSdkQueryFactory();
	resetStack();
	setExtensionApi(undefined);
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

	it("treats an Extra Usage rejection as a model limit and rotates accounts", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return calls === 1
				? fakeSdkQuery([
					{ type: "system", subtype: "init", session_id: "session-a" },
					{ type: "assistant", error: "extra_usage_disabled" },
					{ type: "result", subtype: "success", result: "Extra usage is disabled" },
				], "a", observed)
				: fakeSdkQuery([
					{ type: "system", subtype: "init", session_id: "session-b" },
					{ type: "result", subtype: "success", result: "recovered-without-local-billing-policy" },
				], "b", observed);
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "extra-usage-session" }));
		assert.equal(calls, 2);
		assert.deepEqual(observed.failures, [{ profileId: "a", kind: "rate-limit" }]);
		assert.ok(events.some((event) => event.type === "text_delta" && event.delta === "recovered-without-local-billing-policy"));
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

	it("uses the attempt buffer as a replay guard if context commit state is disturbed", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return {
				async *[Symbol.asyncIterator]() {
					yield { type: "system", subtype: "init", session_id: "buffer-guard-session" };
					yield { type: "stream_event", event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } } };
					yield { type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } };
					yield { type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "committed-by-buffer" } } };
					// Model the old reentrancy race: a different live context received the
					// commit stamp, leaving this attempt context falsely replayable.
					ctx().committedOutput = false;
					throw new Error("socket timeout after buffered output");
				},
				close() {},
				async interrupt() {},
				async accountInfo() { return {}; },
				async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET() { return {}; },
			};
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "buffer-replay-guard" }));
		assert.equal(calls, 1);
		assert.equal(observed.acquires.length, 1);
		assert.ok(events.some((event) => event.type === "text_delta" && event.delta === "committed-by-buffer"));
		assert.equal(events.filter((event) => event.type === "error").length, 1);
	});

	it("records a post-output transport failure without replaying the request", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "session-a" },
				{ type: "stream_event", event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } } },
				{ type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } },
				{ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "committed" } } },
				new Error("socket timeout after output"),
			], "a", observed);
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "post-output-network" }));
		assert.equal(calls, 1);
		assert.deepEqual(observed.failures, [{ profileId: "a", kind: "network" }]);
		assert.ok(events.some((event) => event.type === "text_delta" && event.delta === "committed"));
		assert.equal(events.filter((event) => event.type === "error").length, 1);
	});

	it("rotates after child-internal ToolSearch plumbing fails before visible output", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return calls === 1
				? fakeSdkQuery([
					{ type: "system", subtype: "init", session_id: "tool-search-session" },
					{ type: "stream_event", event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } } },
					{
						type: "stream_event",
						event: {
							type: "content_block_start",
							index: 0,
							content_block: { type: "tool_use", id: "tool-search-1", name: "ToolSearch", input: {} },
						},
					},
					new Error("socket timeout after internal tool search"),
				], "a", observed)
				: fakeSdkQuery([
					{ type: "system", subtype: "init", session_id: "recovered-session" },
					{ type: "result", subtype: "success", result: "recovered-after-tool-search" },
				], "b", observed);
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "tool-search-replay-boundary" }));
		assert.equal(calls, 2);
		assert.deepEqual(observed.failures, [{ profileId: "a", kind: "network" }]);
		assert.ok(events.some((event) => event.type === "text_delta" && event.delta === "recovered-after-tool-search"));
		assert.equal(events.some((event) => event.type === "error"), false);
	});

	it("never replays after a child-executed connector call starts", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "connector-session" },
				{ type: "stream_event", event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } } },
				{
					type: "stream_event",
					event: {
						type: "content_block_start",
						index: 0,
						content_block: { type: "tool_use", id: "connector-1", name: "mcp__claude_ai_Gmail__search_threads", input: {} },
					},
				},
				new Error("socket timeout after connector dispatch"),
			], "a", observed);
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "connector-replay-boundary" }));
		assert.equal(calls, 1);
		assert.equal(observed.acquires.length, 1);
		assert.deepEqual(observed.failures, [{ profileId: "a", kind: "network" }]);
		assert.equal(events.filter((event) => event.type === "error").length, 1);
	});

	it("clears mid-turn rebuild flags after a successful managed completion", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		__testSetBridgeIntegrityState({
			sharedSession: {
				sessionId: "existing-session",
				cursor: 0,
				cwd: process.cwd(),
				modelId: model.id,
				accountProfileId: "a",
				claudeConfigDir: "/profiles/a",
			},
		});
		__testSetSdkQueryFactory(() => ({
			async *[Symbol.asyncIterator]() {
				yield { type: "system", subtype: "init", session_id: "successful-session" };
				const state = __testGetBridgeIntegrityState().sharedSession;
				if (state) {
					__testSetBridgeIntegrityState({
						sharedSession: { ...state, needsRebuild: true, forceRotate: true },
					});
				}
				yield { type: "result", subtype: "success", result: "success-clears-flags" };
			},
			close() {},
			async interrupt() {},
			async accountInfo() { return { email: "a@example.com", subscriptionType: "max" }; },
			async usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET() { return {}; },
		}));

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "clear-flags" }));
		assert.ok(events.some((event) => event.type === "text_delta" && event.delta === "success-clears-flags"));
		const state = __testGetBridgeIntegrityState().sharedSession;
		assert.equal(state?.sessionId, "successful-session");
		assert.equal(state?.needsRebuild, undefined);
		assert.equal(state?.forceRotate, undefined);
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

describe("legacy account path", () => {
	it("lets Claude's successful fallback recover a rejected rate-limit event", async () => {
		const previousToken = process.env.CLAUDE_CODE_OAUTH_TOKEN;
		process.env.CLAUDE_CODE_OAUTH_TOKEN = "test-only";
		const notifications = [];
		const autoResumeEvents = [];
		setExtensionApi({
			events: {
				emit(name, payload) {
					if (name === RATE_LIMIT_AUTO_RESUME_EVENT) autoResumeEvents.push(payload);
				},
			},
		});
		__testSetBridgeIntegrityState({
			sharedSession: null,
			ui: { notify(message, level) { notifications.push({ message, level }); } },
		});
		__testSetSdkQueryFactory(() => fakeSdkQuery([
			{ type: "system", subtype: "init", session_id: "legacy-fallback-session" },
			{
				type: "rate_limit_event",
				rate_limit_info: {
					status: "rejected",
					rateLimitType: "five_hour",
					resetsAt: new Date(Date.now() + 60_000).toISOString(),
				},
			},
			{ type: "stream_event", event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } } },
			{ type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } },
			{ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "fallback-recovered" } } },
			{ type: "stream_event", event: { type: "content_block_stop", index: 0 } },
			{ type: "stream_event", event: { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } } },
			{ type: "stream_event", event: { type: "message_stop" } },
			{ type: "result", subtype: "success", result: "fallback-recovered" },
		], "legacy", observedState()));

		try {
			const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "legacy-session" }));
			assert.deepEqual(
				events.filter((event) => event.type === "text_delta").map((event) => event.delta),
				["fallback-recovered"],
			);
			assert.equal(events.some((event) => event.type === "error"), false);
			assert.equal(notifications.filter(({ message }) => message.includes("[rate-limit]")).length, 1);
			assert.equal(autoResumeEvents.length, 1);
			const state = __testGetBridgeIntegrityState().sharedSession;
			assert.equal(state?.sessionId, "legacy-fallback-session");
			assert.equal(state?.needsRebuild, undefined);
			assert.equal(state?.forceRotate, undefined);
		} finally {
			setExtensionApi(undefined);
			if (previousToken === undefined) delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
			else process.env.CLAUDE_CODE_OAUTH_TOKEN = previousToken;
		}
	});

	it("preserves legacy silent handling for unrelated non-success results", async () => {
		const previousToken = process.env.CLAUDE_CODE_OAUTH_TOKEN;
		process.env.CLAUDE_CODE_OAUTH_TOKEN = "test-only";
		__testSetSdkQueryFactory(() => fakeSdkQuery([
			{ type: "system", subtype: "init", session_id: "legacy-non-success" },
			{ type: "result", subtype: "error_max_turns", errors: ["maximum turns reached"] },
		], "legacy", observedState()));

		try {
			const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "legacy-non-success" }));
			assert.equal(events.some((event) => event.type === "error"), false);
		} finally {
			if (previousToken === undefined) delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
			else process.env.CLAUDE_CODE_OAUTH_TOKEN = previousToken;
		}
	});
});
