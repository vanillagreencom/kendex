// vstack#108: rate-limit retry-with-backoff watchdog for subagent panes.
// The integration test injects deterministic clock + scheduler so the
// per-pane attempt counter, retry-at scheduling, steer dispatch, and
// exhaustion fallback all surface synchronously.

import { describe, expect, test } from "bun:test";

import {
	createSubagentRateLimitWatchdog,
	type RateLimitOutcome,
	type SubagentRateLimitWatchdogDeps,
} from "../extensions/subagent/rate-limit-watchdog.js";
import { buildSubagentActivity } from "../extensions/subagent/activity.js";

const CANONICAL_RATE_LIMIT_MESSAGE_END = {
	message: {
		api: "claude-bridge",
		content: [
			{
				text: "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited",
				type: "text",
			},
		],
		errorMessage:
			"Claude Code returned an error result: API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited",
		role: "assistant",
		stopReason: "error",
	},
	type: "message_end",
};

const HEALTHY_MESSAGE_END = {
	message: {
		content: [{ text: "Done.", type: "text" }],
		role: "assistant",
		stopReason: "stop",
	},
	type: "message_end",
};

const USER_STEER_ECHO_MESSAGE_END = {
	message: {
		content: [{ text: "API rate limit was detected. Try to continue from where you left off.", type: "text" }],
		role: "user",
	},
	type: "message_end",
};

const ASSISTANT_NO_STOP_REASON_MESSAGE_END = {
	message: {
		content: [{ text: "Still working.", type: "text" }],
		role: "assistant",
	},
	type: "message_end",
};

const ASSISTANT_ERROR_NO_RATE_LIMIT_PROSE_MESSAGE_END = {
	message: {
		content: [{ text: "Tool output attached below.", type: "text" }],
		errorMessage: "Tool execution failed",
		role: "assistant",
		stopReason: "error",
	},
	type: "message_end",
};

function makeDeps(overrides: Partial<SubagentRateLimitWatchdogDeps> = {}): {
	deps: SubagentRateLimitWatchdogDeps;
	scheduled: Array<{ delayMs: number; fn: () => void; cancelled: boolean }>;
	steerCalls: string[];
	activity: Array<{ event: string; payload: Record<string, unknown> }>;
	exhausted: Array<{ paneId: string; attempt: number; reason: string }>;
	warnings: string[];
	clockMs: { value: number };
} {
	const scheduled: Array<{ delayMs: number; fn: () => void; cancelled: boolean }> = [];
	const steerCalls: string[] = [];
	const activity: Array<{ event: string; payload: Record<string, unknown> }> = [];
	const exhausted: Array<{ paneId: string; attempt: number; reason: string }> = [];
	const warnings: string[] = [];
	const clockMs = { value: 0 };
	const deps: SubagentRateLimitWatchdogDeps = {
		backoffLadderSec: () => [1, 2, 4],
		emitActivity: (event, payload) => activity.push({ event, payload }),
		isEnabled: () => true,
		logWarn: (message) => warnings.push(message),
		maxAttempts: () => 3,
		now: () => clockMs.value,
		onExhausted: (paneId, attempt, reason) => exhausted.push({ attempt, paneId, reason }),
		scheduleAfter: (delayMs, fn) => {
			const entry = { cancelled: false, delayMs, fn };
			scheduled.push(entry);
			return { cancel: () => { entry.cancelled = true; } };
		},
		sendUserMessage: (message) => steerCalls.push(message),
		...overrides,
	};
	return { activity, clockMs, deps, exhausted, scheduled, steerCalls, warnings };
}

describe("subagent rate-limit watchdog (vstack#108)", () => {
	test("rate-limit skipped broker event maps to noisy debug activity", () => {
		expect(buildSubagentActivity("subagents:rate_limit_skipped", {
			agent: "rust",
			paneId: "%41",
			reason: "no-prose",
			taskId: "task-1",
		})).toMatchObject({
			details: {
				event_name: "subagents:rate_limit_skipped",
				pane_id: "%41",
				reason: "no-prose",
			},
			importance: "noisy",
			refs: { agent: "rust", task_id: "task-1" },
			severity: "debug",
			source: "pi-agents",
			summary: "rust rate-limit skipped: no-prose",
			type: "agent.rate_limit_skipped",
		});
	});

	for (const { event, reason } of [
		{ event: USER_STEER_ECHO_MESSAGE_END, reason: "non-assistant" },
		{ event: ASSISTANT_NO_STOP_REASON_MESSAGE_END, reason: "no-stopreason" },
		{ event: HEALTHY_MESSAGE_END, reason: "stopreason-mismatch" },
		{ event: ASSISTANT_ERROR_NO_RATE_LIMIT_PROSE_MESSAGE_END, reason: "no-prose" },
	] as const) {
		test(`classifier rejection emits subagents:rate_limit_skipped (${reason})`, () => {
			const ctx = makeDeps();
			const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
			const outcome = watchdog.onMessageEnd(event, "rust", "rust", "task-1");
			expect(outcome).toEqual({ kind: "not-rate-limited", reason });
			expect(ctx.activity).toHaveLength(1);
			expect(ctx.activity[0]).toEqual({
				event: "subagents:rate_limit_skipped",
				payload: {
					agent: "rust",
					paneId: "rust",
					reason,
					taskId: "task-1",
				},
			});
		});
	}

	test("first rate-limit detection schedules a retry and emits agent.rate_limited", () => {
		const ctx = makeDeps();
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		ctx.clockMs.value = 1_000;

		const outcome = watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust", "rust", "task-1");
		expect(outcome.kind).toBe("scheduled-retry");
		if (outcome.kind !== "scheduled-retry") throw new Error("expected scheduled-retry");
		expect(outcome.attempt).toBe(1);
		// First ladder step is 1s.
		expect(outcome.at).toBe(1_000 + 1_000);
		expect(watchdog.isAwaitingRetry("rust")).toBe(true);
		expect(ctx.scheduled).toHaveLength(1);
		expect(ctx.scheduled[0]!.delayMs).toBe(1_000);
		expect(ctx.activity[0]?.event).toBe("subagents:rate_limited");
		expect(ctx.activity[0]?.payload.attempt).toBe(1);
		expect(ctx.activity[0]?.payload.next_retry_at).toBe(2_000);
	});

	test("scheduled steer fires the canonical recovery prose", () => {
		const ctx = makeDeps();
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		expect(watchdog.fireRetryNow("rust")).toBe(true);
		expect(ctx.steerCalls).toEqual([
			"API rate limit was detected. Try to continue from where you left off.",
		]);
		expect(watchdog.isAwaitingRetry("rust")).toBe(false);
	});

	test("counter advances and second detection emits agent.rate_limit_retry", () => {
		const ctx = makeDeps();
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		watchdog.fireRetryNow("rust");
		ctx.clockMs.value = 5_000;
		const second = watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		expect(second.kind).toBe("scheduled-retry");
		if (second.kind !== "scheduled-retry") throw new Error("expected scheduled-retry");
		expect(second.attempt).toBe(2);
		// Ladder[1]=2s
		expect(second.at).toBe(5_000 + 2_000);
		const events = ctx.activity.map((entry) => entry.event);
		expect(events).toContain("subagents:rate_limited");
		expect(events).toContain("subagents:rate_limit_retry");
	});

	test("exhaustion fires agent.rate_limit_exhausted and onExhausted handler", () => {
		const ctx = makeDeps();
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		// Burn through all three retries.
		for (let i = 0; i < 3; i += 1) {
			watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
			watchdog.fireRetryNow("rust");
		}
		// 4th detection exhausts.
		const outcome = watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust", "rust", "task-1");
		expect(outcome.kind).toBe("exhausted");
		if (outcome.kind !== "exhausted") throw new Error("expected exhausted");
		expect(outcome.attempt).toBe(3);
		expect(ctx.exhausted).toEqual([{ attempt: 3, paneId: "rust", reason: outcome.reason }]);
		const exhaustedEvent = ctx.activity.find((entry) => entry.event === "subagents:rate_limit_exhausted");
		expect(exhaustedEvent).toBeDefined();
		expect(exhaustedEvent!.payload.attempt).toBe(3);
		expect(watchdog.isAwaitingRetry("rust")).toBe(false);
	});

	test("healthy turn after rate-limit emits agent.rate_limit_resolved and resets counter", () => {
		const ctx = makeDeps();
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		watchdog.fireRetryNow("rust"); // pending cleared
		ctx.activity.length = 0;
		const outcome: RateLimitOutcome = watchdog.onMessageEnd(HEALTHY_MESSAGE_END, "rust");
		expect(outcome.kind).toBe("resolved");
		if (outcome.kind !== "resolved") throw new Error("expected resolved");
		expect(outcome.previousAttempt).toBe(1);
		expect(ctx.activity.map((entry) => entry.event)).toEqual([
			"subagents:rate_limit_skipped",
			"subagents:rate_limit_resolved",
		]);
		expect(ctx.activity[0]?.payload.reason).toBe("stopreason-mismatch");
		// Counter reset → a subsequent rate-limit starts at attempt 1 again.
		const second = watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		if (second.kind !== "scheduled-retry") throw new Error("expected scheduled-retry");
		expect(second.attempt).toBe(1);
	});

	test("user-role steer echo does not resolve or reset the retry ladder", () => {
		const ctx = makeDeps();
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		watchdog.fireRetryNow("rust"); // pending cleared, attempt remains 1
		ctx.activity.length = 0;
		const echo = watchdog.onMessageEnd(USER_STEER_ECHO_MESSAGE_END, "rust");
		expect(echo.kind).toBe("not-rate-limited");
		expect(ctx.activity).toHaveLength(1);
		expect(ctx.activity[0]).toMatchObject({
			event: "subagents:rate_limit_skipped",
			payload: { reason: "non-assistant" },
		});
		const second = watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		if (second.kind !== "scheduled-retry") throw new Error("expected scheduled-retry");
		expect(second.attempt).toBe(2);
	});

	test("non-rate-limit message_end leaves state untouched", () => {
		const ctx = makeDeps();
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		const outcome = watchdog.onMessageEnd(HEALTHY_MESSAGE_END, "rust");
		expect(outcome.kind).toBe("not-rate-limited");
		expect(ctx.scheduled).toHaveLength(0);
		expect(ctx.activity).toHaveLength(1);
		expect(ctx.activity[0]).toMatchObject({
			event: "subagents:rate_limit_skipped",
			payload: { reason: "stopreason-mismatch" },
		});
		expect(watchdog.isAwaitingRetry("rust")).toBe(false);
	});

	test("disabled watchdog short-circuits with skipped-disabled", () => {
		const ctx = makeDeps({ isEnabled: () => false });
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		const outcome = watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		expect(outcome.kind).toBe("skipped-disabled");
		expect(ctx.scheduled).toHaveLength(0);
		expect(ctx.activity).toHaveLength(0);
	});

	test("cancel clears the pending retry and resets the counter", () => {
		const ctx = makeDeps();
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		expect(watchdog.isAwaitingRetry("rust")).toBe(true);
		expect(watchdog.cancel("rust")).toBe(true);
		expect(watchdog.isAwaitingRetry("rust")).toBe(false);
		expect(ctx.scheduled[0]!.cancelled).toBe(true);
		// Subsequent detection restarts at attempt 1.
		const outcome = watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		if (outcome.kind !== "scheduled-retry") throw new Error("expected scheduled-retry");
		expect(outcome.attempt).toBe(1);
	});

	test("steer dispatch errors are swallowed (best-effort recovery)", () => {
		const ctx = makeDeps({
			sendUserMessage: () => {
				throw new Error("bridge socket gone");
			},
		});
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		expect(() => watchdog.fireRetryNow("rust")).not.toThrow();
		expect(ctx.warnings.some((line) => line.includes("steer dispatch failed"))).toBe(true);
	});

	test("async steer dispatch rejections are logged (best-effort recovery)", async () => {
		const ctx = makeDeps({
			sendUserMessage: () => Promise.reject(new Error("agent still streaming")),
		});
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust");
		expect(() => watchdog.fireRetryNow("rust")).not.toThrow();
		await Promise.resolve();
		expect(ctx.warnings.some((line) => line.includes("steer dispatch failed") && line.includes("agent still streaming"))).toBe(true);
	});

	test("activity emit errors are swallowed (best-effort recovery)", () => {
		const ctx = makeDeps({
			emitActivity: () => {
				throw new Error("broker offline");
			},
		});
		const watchdog = createSubagentRateLimitWatchdog(ctx.deps);
		expect(() => watchdog.onMessageEnd(CANONICAL_RATE_LIMIT_MESSAGE_END, "rust")).not.toThrow();
		expect(ctx.warnings.some((line) => line.includes("activity emit failed"))).toBe(true);
	});
});
