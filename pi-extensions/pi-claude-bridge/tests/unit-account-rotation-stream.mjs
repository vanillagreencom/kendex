import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";

import {
	__testSetBridgeIntegrityState,
	__testGetBridgeIntegrityState,
	__testSetSdkQueryFactory,
	probeClaudeAccountProfile,
	streamClaudeAgentSdk,
} from "../src/index.ts";
import { RATE_LIMIT_TOKEN } from "../src/rate-limit.ts";
import { setExtensionApi } from "../src/bridge-state.ts";
import { CLAUDE_ACCOUNT_ROUTER_SYMBOL } from "../src/account-router.ts";
import { ctx, resetStack } from "../src/query-state.ts";

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

function textEvents(events) {
	return events.filter((event) => event.type === "text_delta").map((event) => event.delta);
}

let notifications;
let emittedRateLimitEvents;

beforeEach(() => {
	process.env.CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT = "0";
	// Legacy (no-router) paths gate on credential presence; an env token is an
	// existence-only signal that never gets read.
	process.env.CLAUDE_CODE_OAUTH_TOKEN = "test-token";
	resetStack();
	notifications = [];
	emittedRateLimitEvents = [];
	__testSetBridgeIntegrityState({
		sharedSession: null,
		ui: { notify: (message, level) => notifications.push({ message, level }) },
	});
	setExtensionApi({
		events: { emit: (name, payload) => emittedRateLimitEvents.push({ name, payload }) },
		appendEntry: () => {},
	});
});

afterEach(() => {
	delete process.env.CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT;
	delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
	delete globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL];
	__testSetSdkQueryFactory();
	setExtensionApi(undefined);
	resetStack();
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
});

const STREAMED_TEXT = (text) => [
	{ type: "stream_event", event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } } },
	{ type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } },
	{ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } } },
];

describe("legacy sessions (no account router)", () => {
	it("completes a rejected rate limit + streamed recovery exactly like a success", async () => {
		// The B1 regression: a rejected five_hour rate_limit_event followed by
		// the SDK's own fallback-model recovery must yield ONE rate-limit
		// notification, NO trailing error event, and a persisted session.
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "session-legacy" },
				{
					type: "rate_limit_event",
					rate_limit_info: {
						status: "rejected",
						rateLimitType: "five_hour",
						resetsAt: new Date(Date.now() + 60_000).toISOString(),
					},
				},
				...STREAMED_TEXT("recovered"),
				{ type: "result", subtype: "success", result: "recovered" },
			], "legacy", observedState());
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "legacy-recovery" }));
		assert.equal(calls, 1);
		assert.deepEqual(textEvents(events), ["recovered"]);
		assert.equal(events.filter((event) => event.type === "error").length, 0);
		assert.equal(events.filter((event) => event.type === "done").length, 1);
		const rateLimitNotifies = notifications.filter((n) => n.message.includes(RATE_LIMIT_TOKEN));
		assert.equal(rateLimitNotifies.length, 1, "exactly one rate-limit toast");
		assert.equal(emittedRateLimitEvents.length, 1, "exactly one vstack:rate-limit event");
		const { sharedSession } = __testGetBridgeIntegrityState();
		assert.equal(sharedSession?.sessionId, "session-legacy", "session persisted on success");
		assert.equal(sharedSession?.needsRebuild, undefined);
	});

	it("surfaces usage-limit copy once and still persists the session", async () => {
		__testSetSdkQueryFactory(() => fakeSdkQuery([
			{ type: "system", subtype: "init", session_id: "session-legacy" },
			{ type: "result", subtype: "error_during_execution", errors: ["You've hit your weekly limit · resets Thursday 4am"] },
		], "legacy", observedState()));

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "legacy-usage-limit" }));
		const errors = events.filter((event) => event.type === "error");
		assert.equal(errors.length, 1);
		assert.match(errors[0].error.errorMessage, /weekly limit/);
		const { sharedSession } = __testGetBridgeIntegrityState();
		assert.equal(sharedSession?.sessionId, "session-legacy", "session persisted after usage-limit error");
	});

	it("never replays deferred user messages after a terminal failure", async () => {
		// Surfacing a terminal failure ends the Pi stream. A continuation query
		// spawned after that would run with its output invisible while its tool
		// side effects still execute — so the deferred-replay loop must not run.
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return {
				async *[Symbol.asyncIterator]() {
					// Pi injected a steer mid-query; the provider path deferred it.
					ctx().deferredUserMessages.push("queued steer");
					yield { type: "system", subtype: "init", session_id: "session-legacy" };
					for (const message of STREAMED_TEXT("partial work")) yield message;
					yield { type: "result", subtype: "error_max_turns", errors: ["max turns exceeded"] };
				},
				close() {},
				async interrupt() {},
			};
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "deferred-terminal" }));
		assert.equal(calls, 1, "no continuation query may be spawned after a surfaced failure");
		assert.equal(events.filter((event) => event.type === "error").length, 1);
		const { sharedSession } = __testGetBridgeIntegrityState();
		assert.equal(sharedSession?.sessionId, "session-legacy", "session record still persisted");
	});

	it("surfaces other non-success result subtypes as an explicit error and persists the session", async () => {
		// S6: error_max_turns / error_during_execution used to end the turn
		// silently; they now surface — with session bookkeeping intact.
		__testSetSdkQueryFactory(() => fakeSdkQuery([
			{ type: "system", subtype: "init", session_id: "session-legacy" },
			...STREAMED_TEXT("partial work"),
			{ type: "result", subtype: "error_max_turns", errors: ["max turns exceeded"] },
		], "legacy", observedState()));

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "legacy-max-turns" }));
		const errors = events.filter((event) => event.type === "error");
		assert.equal(errors.length, 1);
		assert.match(errors[0].error.errorMessage, /max turns/);
		const { sharedSession } = __testGetBridgeIntegrityState();
		assert.equal(sharedSession?.sessionId, "session-legacy");
		assert.equal(sharedSession?.needsRebuild, undefined);
	});
});

describe("managed account stream rotation", () => {
	it("retries a rejected pre-output request on the next profile without leaking the first attempt", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory((input) => {
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
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "pi-session" }));
		assert.equal(calls, 2);
		assert.equal(observed.acquires.length, 2);
		assert.deepEqual(observed.acquires[1].excludedProfileIds, ["a"]);
		assert.deepEqual(observed.queryEnvs.map((env) => env.CLAUDE_CONFIG_DIR), [
			"/profiles/a", "/profiles/b",
		]);
		// Managed children never inherit the host's Claude OAuth token.
		assert.ok(observed.queryEnvs.every((env) => env.CLAUDE_CODE_OAUTH_TOKEN === undefined));
		assert.deepEqual(textEvents(events), ["ok-from-b"]);
		assert.equal(events.filter((event) => event.type === "error").length, 0);
		assert.equal(events.filter((event) => event.type === "start").length, 1);
		assert.equal(observed.rateLimits[0].profileId, "a");
		assert.deepEqual(observed.successes, ["b"]);
	});

	it("completes a rejected rate limit + in-place recovery without rotating or erroring", async () => {
		// Managed twin of the B1 legacy test: the CLI's own fallback recovery
		// clears the held failure; the router still learns the rate limit.
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
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
				...STREAMED_TEXT("recovered-managed"),
				{ type: "result", subtype: "success", result: "recovered-managed" },
			], "a", observed);
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "managed-recovery" }));
		assert.equal(calls, 1);
		assert.deepEqual(textEvents(events), ["recovered-managed"]);
		assert.equal(events.filter((event) => event.type === "error").length, 0);
		assert.equal(observed.rateLimits.length, 1);
		assert.deepEqual(observed.successes, ["a"]);
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
		assert.ok(textEvents(events).includes("network-recovered"));
		assert.equal(events.some((event) => event.type === "error"), false);
	});

	it("terminates the stream when an abort lands after a rotation retry was queued", async () => {
		// requestRotation discards the attempt buffer and nulls currentPiStream;
		// only the retry re-entry ends the outer stream. An abort in the window
		// between queueing the retry and starting it must still terminate the
		// stream — silently skipping the retry left the consumer hanging forever.
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		const controller = new AbortController();
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			const sdkQuery = fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "session-a" },
				new Error("socket timeout before response"),
			], "a", observed);
			const innerClose = sdkQuery.close.bind(sdkQuery);
			// The teardown between "retry queued" and "retry started" closes the
			// failed attempt's query — aborting there lands in exactly the window
			// under test.
			sdkQuery.close = () => {
				controller.abort();
				innerClose();
			};
			return sdkQuery;
		});

		const events = await collect(streamClaudeAgentSdk(model, context, {
			sessionId: "abort-after-queued-retry",
			signal: controller.signal,
		}));
		assert.equal(calls, 1, "the queued retry must not start after the abort");
		const last = events[events.length - 1];
		assert.equal(last?.type, "error");
		assert.equal(last?.reason, "aborted");
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
		assert.ok(textEvents(events).includes("recovered-without-local-billing-policy"));
		assert.equal(events.some((event) => event.type === "error"), false);
	});

	it("never replays after visible text has committed", async () => {
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return fakeSdkQuery([
				{ type: "system", subtype: "init", session_id: "session-a" },
				...STREAMED_TEXT("already-visible"),
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
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "pi-session" }));
		assert.equal(calls, 1);
		assert.equal(observed.acquires.length, 1);
		assert.ok(textEvents(events).includes("already-visible"));
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
				...STREAMED_TEXT("committed"),
				new Error("socket timeout after output"),
			], "a", observed);
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "post-output-network" }));
		assert.equal(calls, 1);
		assert.deepEqual(observed.failures, [{ profileId: "a", kind: "network" }]);
		assert.ok(textEvents(events).includes("committed"));
		assert.equal(events.filter((event) => event.type === "error").length, 1);
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

	it("still rotates when only a child-internal built-in (ToolSearch) ran before the failure", async () => {
		// B3: ToolSearch is pure plumbing with no account-visible side effect —
		// it must NOT mark the turn non-rotatable the way a connector call does.
		const observed = observedState();
		globalThis[CLAUDE_ACCOUNT_ROUTER_SYMBOL] = makeRouter(observed);
		let calls = 0;
		__testSetSdkQueryFactory(() => {
			calls += 1;
			return calls === 1
				? fakeSdkQuery([
					{ type: "system", subtype: "init", session_id: "session-a" },
					{ type: "stream_event", event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } } },
					{
						type: "stream_event",
						event: {
							type: "content_block_start",
							index: 0,
							content_block: { type: "tool_use", id: "search-1", name: "ToolSearch", input: {} },
						},
					},
					new Error("socket timeout after tool search"),
				], "a", observed)
				: fakeSdkQuery([
					{ type: "system", subtype: "init", session_id: "session-b" },
					{ type: "result", subtype: "success", result: "rotated-after-toolsearch" },
				], "b", observed);
		});

		const events = await collect(streamClaudeAgentSdk(model, context, { sessionId: "toolsearch-rotatable" }));
		assert.equal(calls, 2);
		assert.deepEqual(observed.failures, [{ profileId: "a", kind: "network" }]);
		assert.ok(textEvents(events).includes("rotated-after-toolsearch"));
		assert.equal(events.some((event) => event.type === "error"), false);
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
		assert.ok(textEvents(events).includes("opus-after-fable"));
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

describe("account host probe (probeProfile)", () => {
	it("settles within its deadline and kills a stalled probe child", async () => {
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

		const result = await probeClaudeAccountProfile({
			profile: { profileId: "a", label: "account-a" },
			cwd: process.cwd(),
			deadlineMs: 100,
		});
		assert.deepEqual(result, {});
		assert.equal(closed, true, "the expired probe must kill its child");
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
