// vstack#108: pure-function regression coverage for the rate-limit
// watchdog decision module. Same decision module is consumed by Layer A
// (pi-agents-tmux subagent watchdog) and Layer B (bash subscriber wake
// branch); both layers must observe identical transitions for identical
// inputs.

import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as canonicalDecision from "../../src/daemon/rate-limit-watchdog.ts";
import * as vendoredDecision from "../../../../../../pi-extensions/pi-agents-tmux/extensions/subagent/rate-limit-decision.ts";

const {
	RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC,
	RATE_LIMIT_DEFAULT_MAX_ATTEMPTS,
	RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS,
	RATE_LIMIT_ERROR_REGEX,
	RATE_LIMIT_RESET_MARGIN_MS,
	RATE_LIMIT_STEER_MESSAGE,
	classifyRateLimitEvent,
	decideRateLimitRetry,
	extractResetAtMs,
	extractRetryAfterMs,
	isRateLimitEvent,
	rateLimitBackoffLadderFromEnv,
	rateLimitMaxAttemptsFromEnv,
	rateLimitWatchdogEnabledFromEnv,
} = canonicalDecision;

const DECISION_MODULES: Array<{ name: string; module: typeof canonicalDecision }> = [
	{ module: canonicalDecision, name: "flightdeck-core canonical" },
	{ module: vendoredDecision, name: "pi-agents-tmux vendored" },
];

function fakeFetch(response: { ok: boolean; status: number; body?: unknown; jsonError?: Error }, calls: Array<{ input: string; init?: Record<string, unknown> }> = []) {
	return async (input: string, init?: Record<string, unknown>) => {
		calls.push({ input, init });
		return {
			ok: response.ok,
			status: response.status,
			json: async () => {
				if (response.jsonError) throw response.jsonError;
				return response.body;
			},
		};
	};
}

// Canonical message_end-style envelope produced by pi-coding-agent for a
// rate-limited assistant turn. Snapshot taken from a real session under
// ~/.pi/agent/vstack/sessions/<id>/pi-agents-tmux/sessions/rust.jsonl.
const CANONICAL_RATE_LIMIT_EVENT = {
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
		model: "claude-opus-4-7",
		provider: "claude-bridge",
		role: "assistant",
		stopReason: "error",
		timestamp: 1_778_998_215_269,
	},
	type: "message",
};

const CLAUDE_SESSION_LIMIT_EVENT = {
	message: {
		api: "claude-bridge",
		errorMessage:
			"Claude Code returned an error result: You've hit your session limit · resets 7:50pm (America/Los_Angeles)",
		model: "claude-opus-4-8",
		provider: "claude-bridge",
		role: "assistant",
		stopReason: "error",
	},
	type: "message",
};

const CLAUDE_USAGE_LIMIT_EVENT = {
	message: {
		errorMessage: "You've hit your usage limit",
		role: "assistant",
		stopReason: "error",
	},
	type: "message",
};

const OPENAI_CODEX_RATE_LIMIT_EVENT = {
	message: {
		api: "openai-codex",
		errorMessage: "Rate limited",
		model: "GPT-5.3-Codex-Spark",
		provider: "openai-codex",
		role: "assistant",
		stopReason: "error",
	},
	type: "message",
};

const SESSION_LIMIT_NOW = Date.UTC(2026, 4, 31, 1, 54, 56);
const SESSION_LIMIT_RESET_AT = Date.UTC(2026, 4, 31, 2, 50, 0);
const STRUCTURED_USAGE_RESET_AT = Date.UTC(2026, 4, 31, 3, 30, 0);
const SESSION_LIMIT_JUST_AFTER_RESET = SESSION_LIMIT_RESET_AT + 1_000;
const MIDNIGHT_BOUNDARY_NOW = Date.UTC(2026, 4, 31, 7, 0, 1);
const MIDNIGHT_BOUNDARY_RESET_AT = Date.UTC(2026, 4, 31, 6, 59, 0);

const CLAUDE_USAGE_RESPONSE = {
	five_hour: { utilization: 1, resets_at: new Date(STRUCTURED_USAGE_RESET_AT).toISOString() },
	seven_day: { utilization: 0.2, resets_at: new Date(STRUCTURED_USAGE_RESET_AT + 86_400_000).toISOString() },
};

const LOW_UTILIZATION_CLAUDE_USAGE_RESPONSE = {
	five_hour: { utilization: 0.1, resets_at: new Date(STRUCTURED_USAGE_RESET_AT).toISOString() },
	seven_day: { utilization: 0.2, resets_at: new Date(STRUCTURED_USAGE_RESET_AT + 86_400_000).toISOString() },
	seven_day_opus: { utilization: 0.2, resets_at: new Date(STRUCTURED_USAGE_RESET_AT + 2 * 86_400_000).toISOString() },
};

const CODEX_WHAM_USAGE = {
	plan_type: "prolite",
	rate_limit: {
		allowed: false,
		limit_reached: true,
		primary_window: { limit_window_seconds: 18_000, reset_after_seconds: 120, used_percent: 85 },
		secondary_window: { limit_window_seconds: 604_800, reset_after_seconds: 600, used_percent: 95 },
	},
};

const CODEX_WHAM_MODEL_USAGE = {
	...CODEX_WHAM_USAGE,
	additional_rate_limits: [
		{
			limit_name: "GPT-5.3-Codex-Spark",
			metered_feature: "gpt-5.3-codex-spark",
			rate_limit: {
				limit_reached: true,
				primary_window: { reset_after_seconds: 900, used_percent: 100 },
				secondary_window: { reset_after_seconds: 1_800, used_percent: 80 },
			},
		},
	],
};

const CLAUDE_MIDNIGHT_BOUNDARY_SESSION_LIMIT_EVENT = {
	message: {
		errorMessage:
			"Claude Code returned an error result: You've hit your session limit · resets 11:59pm (America/Los_Angeles)",
		role: "assistant",
		stopReason: "error",
	},
	type: "message",
};

describe("decideRateLimitRetry — canonical detection (vstack#108)", () => {
	test("returns not-rate-limited for an unrelated assistant turn", () => {
		const decision = decideRateLimitRetry({
			attempt: 0,
			event: { message: { role: "assistant", stopReason: "stop" }, type: "message" },
			lastRetryAt: null,
			now: 1_000_000,
			paneId: "%41",
		});
		expect(decision).toEqual({ kind: "not-rate-limited", reason: "stopreason-mismatch" });
	});

	test("returns not-rate-limited when prose mentions 'rate' but stopReason is not 'error'", () => {
		// A normal turn whose assistant text legitimately discusses rate
		// limiting must NOT trigger recovery. stopReason==='error' gates it.
		const decision = decideRateLimitRetry({
			attempt: 0,
			event: {
				message: {
					content: [{ text: "rate-limited inputs need throttling", type: "text" }],
					role: "assistant",
					stopReason: "stop",
				},
				type: "message",
			},
			lastRetryAt: null,
			now: 1_000_000,
			paneId: "%41",
		});
		expect(decision.kind).toBe("not-rate-limited");
		expect(decision).toEqual({ kind: "not-rate-limited", reason: "stopreason-mismatch" });
	});

	test("schedules a retry-at on first detection using the default ladder", () => {
		const decision = decideRateLimitRetry({
			attempt: 0,
			event: CANONICAL_RATE_LIMIT_EVENT,
			lastRetryAt: null,
			now: 1_000_000,
			paneId: "%41",
		});
		expect(decision.kind).toBe("retry-at");
		if (decision.kind !== "retry-at") throw new Error("expected retry-at");
		expect(decision.attempt).toBe(1);
		// First step of the ladder is 60s.
		expect(decision.at).toBe(1_000_000 + 60_000);
		expect(decision.steerMessage).toBe(RATE_LIMIT_STEER_MESSAGE);
		expect(decision.hash).toContain("%41");
		expect(decision.resetSource).toBe("backoff-only");
		expect(decision.degradedResetSource).toBe(true);
	});

	test("ladder advances with the attempt counter", () => {
		const base = {
			event: CANONICAL_RATE_LIMIT_EVENT,
			lastRetryAt: null,
			now: 2_000_000,
			paneId: "%41",
		} as const;
		const ladderMs = RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC.map((s) => s * 1_000);
		for (let attempt = 0; attempt < RATE_LIMIT_DEFAULT_MAX_ATTEMPTS; attempt += 1) {
			const decision = decideRateLimitRetry({ ...base, attempt });
			expect(decision.kind).toBe("retry-at");
			if (decision.kind !== "retry-at") throw new Error("expected retry-at");
			expect(decision.attempt).toBe(attempt + 1);
			const expectedDelay = ladderMs[Math.min(attempt, ladderMs.length - 1)]!;
			expect(decision.at).toBe(base.now + expectedDelay);
		}
	});

	test("returns exhausted once attempt reaches the configured max", () => {
		const decision = decideRateLimitRetry({
			attempt: RATE_LIMIT_DEFAULT_MAX_ATTEMPTS,
			event: CANONICAL_RATE_LIMIT_EVENT,
			lastRetryAt: 0,
			now: 5_000_000,
			paneId: "%41",
		});
		expect(decision.kind).toBe("exhausted");
		if (decision.kind !== "exhausted") throw new Error("expected exhausted");
		expect(decision.attempt).toBe(RATE_LIMIT_DEFAULT_MAX_ATTEMPTS);
		expect(decision.reason).toMatch(/exhausted/i);
	});

	test("explicit retry_after_ms in the event wins over the ladder when larger", () => {
		const withRetryAfter = {
			...CANONICAL_RATE_LIMIT_EVENT,
			message: { ...CANONICAL_RATE_LIMIT_EVENT.message, retry_after_ms: 90_000 },
		};
		const decision = decideRateLimitRetry({
			attempt: 0,
			event: withRetryAfter,
			lastRetryAt: null,
			now: 10_000,
			paneId: "%99",
		});
		expect(decision.kind).toBe("retry-at");
		if (decision.kind !== "retry-at") throw new Error("expected retry-at");
		// Ladder[0]=60s ⇒ 60_000ms; explicit=90_000ms ⇒ wins.
		expect(decision.at).toBe(10_000 + 90_000);
		expect(decision.resetSource).toBe("sdk-rate-limit-event");
		expect(decision.degradedResetSource).toBe(false);
	});

	test("explicit retry_after in seconds wins over a smaller ladder step", () => {
		const withRetryAfter = {
			...CANONICAL_RATE_LIMIT_EVENT,
			message: { ...CANONICAL_RATE_LIMIT_EVENT.message, retry_after: 180 },
		};
		const decision = decideRateLimitRetry({
			attempt: 0,
			event: withRetryAfter,
			lastRetryAt: null,
			now: 0,
			paneId: "%1",
		});
		if (decision.kind !== "retry-at") throw new Error("expected retry-at");
		expect(decision.at).toBe(180_000);
	});

	test("Claude session-limit prose schedules only as a degraded reset fallback", () => {
		expect(classifyRateLimitEvent(CLAUDE_SESSION_LIMIT_EVENT)).toEqual({ isRateLimitEvent: true });
		expect(extractResetAtMs(CLAUDE_SESSION_LIMIT_EVENT, SESSION_LIMIT_NOW)).toBe(SESSION_LIMIT_RESET_AT);
		const decision = decideRateLimitRetry({
			attempt: 0,
			event: CLAUDE_SESSION_LIMIT_EVENT,
			lastRetryAt: null,
			now: SESSION_LIMIT_NOW,
			paneId: "%41",
		});
		expect(decision.kind).toBe("retry-at");
		if (decision.kind !== "retry-at") throw new Error("expected retry-at");
		expect(decision.at).toBe(SESSION_LIMIT_RESET_AT + RATE_LIMIT_RESET_MARGIN_MS);
		expect(decision.resetSource).toBe("prose-fallback");
		expect(decision.degradedResetSource).toBe(true);
	});

	test("Claude usage endpoint reset wins over localized prose reset", () => {
		for (const { module, name } of DECISION_MODULES) {
			const decision = module.decideRateLimitRetry(
				{
					attempt: 0,
					event: CLAUDE_SESSION_LIMIT_EVENT,
					lastRetryAt: null,
					now: SESSION_LIMIT_NOW,
					paneId: "%41",
					usageSnapshot: module.normalizeQuotaSnapshot("claude", "usage-endpoint", CLAUDE_USAGE_RESPONSE, SESSION_LIMIT_NOW),
				},
				{ backoffLadderSec: [1], maxAttempts: 3 },
			);
			expect(decision.kind).toBe("retry-at");
			if (decision.kind !== "retry-at") throw new Error(`expected retry-at for ${name}`);
			expect(decision.at).toBe(STRUCTURED_USAGE_RESET_AT + RATE_LIMIT_RESET_MARGIN_MS);
			expect(decision.resetSource).toBe("usage-endpoint");
			expect(decision.degradedResetSource).toBe(false);
		}
	});

	test("transient not-your-usage-limit events ignore low-utilization usage windows", () => {
		for (const { module, name } of DECISION_MODULES) {
			const decision = module.decideRateLimitRetry(
				{
					attempt: 0,
					event: CANONICAL_RATE_LIMIT_EVENT,
					lastRetryAt: null,
					now: 1_000,
					paneId: "%41",
					usageSnapshot: module.normalizeQuotaSnapshot("claude", "usage-endpoint", LOW_UTILIZATION_CLAUDE_USAGE_RESPONSE, 1_000),
				},
				{ backoffLadderSec: [1], maxAttempts: 3 },
			);
			expect(decision.kind).toBe("retry-at");
			if (decision.kind !== "retry-at") throw new Error(`expected retry-at for ${name}`);
			expect(decision.at).toBe(2_000);
			expect(decision.resetSource).toBe("backoff-only");
			expect(decision.degradedResetSource).toBe(true);
		}
	});

	test("transient not-your-usage-limit events ignore low-utilization model-matching windows", () => {
		const event = {
			...CANONICAL_RATE_LIMIT_EVENT,
			message: { ...CANONICAL_RATE_LIMIT_EVENT.message, model: "claude-opus-4-8" },
		};
		for (const { module, name } of DECISION_MODULES) {
			const decision = module.decideRateLimitRetry(
				{
					attempt: 0,
					event,
					lastRetryAt: null,
					now: 1_000,
					paneId: "%41",
					usageSnapshot: module.normalizeQuotaSnapshot("claude", "usage-endpoint", LOW_UTILIZATION_CLAUDE_USAGE_RESPONSE, 1_000),
				},
				{ backoffLadderSec: [1], maxAttempts: 3 },
			);
			expect(decision.kind).toBe("retry-at");
			if (decision.kind !== "retry-at") throw new Error(`expected retry-at for ${name}`);
			expect(decision.at).toBe(2_000);
			expect(decision.resetSource).toBe("backoff-only");
		}
	});

	test("transient not-your-usage-limit events ignore low-utilization type-hint windows", () => {
		for (const rateLimitType of ["five_hour", "usage"] as const) {
			const event = { ...CANONICAL_RATE_LIMIT_EVENT, rateLimitType };
			for (const { module, name } of DECISION_MODULES) {
				const decision = module.decideRateLimitRetry(
					{
						attempt: 0,
						event,
						lastRetryAt: null,
						now: 1_000,
						paneId: "%41",
						usageSnapshot: module.normalizeQuotaSnapshot("claude", "usage-endpoint", LOW_UTILIZATION_CLAUDE_USAGE_RESPONSE, 1_000),
					},
					{ backoffLadderSec: [1], maxAttempts: 3 },
				);
				expect(decision.kind).toBe("retry-at");
				if (decision.kind !== "retry-at") throw new Error(`expected retry-at for ${name} ${rateLimitType}`);
				expect(decision.at).toBe(2_000);
				expect(decision.resetSource).toBe("backoff-only");
			}
		}
	});

	test("malformed usage-shaped payloads are not authoritative quota windows", () => {
		for (const { module, name } of DECISION_MODULES) {
			const decision = module.decideRateLimitRetry(
				{
					attempt: 0,
					event: CLAUDE_USAGE_LIMIT_EVENT,
					lastRetryAt: null,
					now: 1_000,
					paneId: "%41",
					usageSnapshot: { not_usage: { reset_at: "2099-01-01T00:00:00Z" } },
				},
				{ backoffLadderSec: [1], maxAttempts: 3 },
			);
			expect(decision.kind).toBe("retry-at");
			if (decision.kind !== "retry-at") throw new Error(`expected retry-at for ${name}`);
			expect(decision.at).toBe(2_000);
			expect(decision.resetSource).toBe("backoff-only");
		}
	});

	test("top-level windows without trusted source or real quota fields are ignored", () => {
		for (const { module, name } of DECISION_MODULES) {
			const decision = module.decideRateLimitRetry(
				{
					attempt: 0,
					event: CLAUDE_USAGE_LIMIT_EVENT,
					lastRetryAt: null,
					now: 1_000,
					paneId: "%41",
					usageSnapshot: { windows: [{ id: "not_usage", reset_at: "2099-01-01T00:00:00Z" }] },
				},
				{ backoffLadderSec: [1], maxAttempts: 3 },
			);
			expect(decision.kind).toBe("retry-at");
			if (decision.kind !== "retry-at") throw new Error(`expected retry-at for ${name}`);
			expect(decision.at).toBe(2_000);
			expect(decision.resetSource).toBe("backoff-only");
		}
	});

	test("Codex wham usage primary/secondary windows select highest utilization future reset", () => {
		for (const { module, name } of DECISION_MODULES) {
			const decision = module.decideRateLimitRetry(
				{
					attempt: 0,
					event: OPENAI_CODEX_RATE_LIMIT_EVENT,
					lastRetryAt: null,
					now: 1_000,
					paneId: "%99",
					usageSnapshot: module.normalizeQuotaSnapshot("codex", "usage-endpoint", CODEX_WHAM_USAGE, 1_000),
				},
				{ backoffLadderSec: [1], maxAttempts: 3 },
			);
			expect(decision.kind).toBe("retry-at");
			if (decision.kind !== "retry-at") throw new Error(`expected retry-at for ${name}`);
			expect(decision.at).toBe(1_000 + 600_000 + RATE_LIMIT_RESET_MARGIN_MS);
			expect(decision.resetSource).toBe("usage-endpoint");
		}
	});

	test("Codex additional_rate_limits model window wins when model matches", () => {
		for (const { module, name } of DECISION_MODULES) {
			const decision = module.decideRateLimitRetry(
				{
					attempt: 0,
					event: OPENAI_CODEX_RATE_LIMIT_EVENT,
					lastRetryAt: null,
					now: 1_000,
					paneId: "%99",
					usageSnapshot: module.normalizeQuotaSnapshot("codex", "usage-endpoint", CODEX_WHAM_MODEL_USAGE, 1_000),
				},
				{ backoffLadderSec: [1], maxAttempts: 3 },
			);
			expect(decision.kind).toBe("retry-at");
			if (decision.kind !== "retry-at") throw new Error(`expected retry-at for ${name}`);
			expect(decision.at).toBe(1_000 + 900_000 + RATE_LIMIT_RESET_MARGIN_MS);
			expect(decision.resetSource).toBe("usage-endpoint");
		}
	});

	test("clock-only reset prose just after reset stays in the current reset window", () => {
		expect(extractResetAtMs(CLAUDE_SESSION_LIMIT_EVENT, SESSION_LIMIT_JUST_AFTER_RESET)).toBe(SESSION_LIMIT_RESET_AT);
		const decision = decideRateLimitRetry(
			{
				attempt: 0,
				event: CLAUDE_SESSION_LIMIT_EVENT,
				lastRetryAt: null,
				now: SESSION_LIMIT_JUST_AFTER_RESET,
				paneId: "%41",
			},
			{ backoffLadderSec: [1], maxAttempts: 3 },
		);
		expect(decision.kind).toBe("retry-at");
		if (decision.kind !== "retry-at") throw new Error("expected retry-at");
		expect(decision.at).toBe(SESSION_LIMIT_RESET_AT + RATE_LIMIT_RESET_MARGIN_MS);
	});

	test("clock-only reset prose beyond the past tolerance rolls to the next day", () => {
		const now = SESSION_LIMIT_RESET_AT + RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS + 1;
		expect(extractResetAtMs(CLAUDE_SESSION_LIMIT_EVENT, now)).toBe(SESSION_LIMIT_RESET_AT + 86_400_000);
	});

	test("canonical and vendored reset parser check previous local day at midnight boundary", () => {
		for (const { module, name } of DECISION_MODULES) {
			expect(module.extractResetAtMs(CLAUDE_MIDNIGHT_BOUNDARY_SESSION_LIMIT_EVENT, MIDNIGHT_BOUNDARY_NOW)).toBe(MIDNIGHT_BOUNDARY_RESET_AT);
			const decision = module.decideRateLimitRetry(
				{
					attempt: 0,
					event: CLAUDE_MIDNIGHT_BOUNDARY_SESSION_LIMIT_EVENT,
					lastRetryAt: null,
					now: MIDNIGHT_BOUNDARY_NOW,
					paneId: "%41",
				},
				{ backoffLadderSec: [1], maxAttempts: 3 },
			);
			expect(decision.kind).toBe("retry-at");
			if (decision.kind !== "retry-at") throw new Error(`expected retry-at for ${name}`);
			expect(decision.at).toBe(MIDNIGHT_BOUNDARY_NOW + 1_000);
		}
	});

	test("structured reset timestamps win over the backoff ladder when later", () => {
		const resetAtMs = 200_000;
		const withStructuredReset = {
			...CLAUDE_USAGE_LIMIT_EVENT,
			message: { ...CLAUDE_USAGE_LIMIT_EVENT.message, rate_limit_info: { resetsAt: new Date(resetAtMs).toISOString() } },
		};
		const decision = decideRateLimitRetry(
			{
				attempt: 0,
				event: withStructuredReset,
				lastRetryAt: null,
				now: 0,
				paneId: "%41",
			},
			{ backoffLadderSec: [1], maxAttempts: 3 },
		);
		expect(decision.kind).toBe("retry-at");
		if (decision.kind !== "retry-at") throw new Error("expected retry-at");
		expect(decision.at).toBe(resetAtMs + RATE_LIMIT_RESET_MARGIN_MS);
		expect(decision.resetSource).toBe("sdk-rate-limit-event");
		expect(decision.degradedResetSource).toBe(false);
	});

	test("ladder still wins when explicit retry_after is smaller (don't retry too early)", () => {
		const withRetryAfter = {
			...CANONICAL_RATE_LIMIT_EVENT,
			message: { ...CANONICAL_RATE_LIMIT_EVENT.message, retryAfterMs: 1_000 },
		};
		const decision = decideRateLimitRetry({
			attempt: 0,
			event: withRetryAfter,
			lastRetryAt: null,
			now: 0,
			paneId: "%1",
		});
		if (decision.kind !== "retry-at") throw new Error("expected retry-at");
		// Ladder[0]=60_000ms, explicit=1_000ms ⇒ ladder wins (Math.max).
		expect(decision.at).toBe(60_000);
	});

	test("environment overrides shorten the ladder", () => {
		const decision = decideRateLimitRetry(
			{
				attempt: 0,
				event: CANONICAL_RATE_LIMIT_EVENT,
				lastRetryAt: null,
				now: 1_000,
				paneId: "%1",
			},
			{ backoffLadderSec: [5], maxAttempts: 2 },
		);
		if (decision.kind !== "retry-at") throw new Error("expected retry-at");
		expect(decision.at).toBe(1_000 + 5_000);
	});

	test("environment override caps max attempts", () => {
		const decision = decideRateLimitRetry(
			{
				attempt: 2,
				event: CANONICAL_RATE_LIMIT_EVENT,
				lastRetryAt: 0,
				now: 5_000,
				paneId: "%1",
			},
			{ backoffLadderSec: [5], maxAttempts: 2 },
		);
		expect(decision.kind).toBe("exhausted");
	});
});

describe("rate-limit decision parity — false-positive regression coverage (vstack#120)", () => {
	const toolResultMentionsRateLimit = {
		message: {
			content: [{ text: "see § 9.2 — Rate limit (429) handling", type: "text" }],
			role: "toolResult",
		},
		type: "message_end",
	};

	const steerEchoUserMessage = {
		message: {
			content: [{ text: RATE_LIMIT_STEER_MESSAGE, type: "text" }],
			role: "user",
		},
		type: "message_end",
	};

	const assistantStopMentions429 = {
		message: {
			content: [{ text: "The API returned 429 last time but I retried and it worked.", type: "text" }],
			role: "assistant",
			stopReason: "stop",
		},
		type: "message_end",
	};

	const assistantErrorWithNestedToolTextOnly = {
		message: {
			content: [{ text: "Tool output attached below.", type: "text" }],
			errorMessage: "Tool execution failed",
			role: "assistant",
			stopReason: "error",
		},
		type: "message_end",
		toolResult: {
			content: [{ text: "Normal docs mention Rate limit (429)", type: "text" }],
		},
	};

	const regressionEvents = [
		{
			assistant: false,
			event: toolResultMentionsRateLimit,
			name: "toolResult message_end whose content mentions rate limit",
			reason: "non-assistant",
		},
		{
			assistant: false,
			event: steerEchoUserMessage,
			name: "user message_end echoing the steer text",
			reason: "non-assistant",
		},
		{
			assistant: true,
			event: assistantStopMentions429,
			name: "assistant message_end with stopReason=stop mentioning 429",
			reason: "stopreason-mismatch",
		},
		{
			assistant: true,
			event: assistantErrorWithNestedToolTextOnly,
			name: "assistant error whose rate-limit prose exists only outside the assistant envelope",
			reason: "no-prose",
		},
	] as const satisfies ReadonlyArray<{
		assistant: boolean;
		event: unknown;
		name: string;
		reason: "non-assistant" | "no-stopreason" | "stopreason-mismatch" | "no-prose";
	}>;

	const rejectionReasonEvents = [
		...regressionEvents,
		{
			assistant: true,
			event: { message: { content: [{ text: "Still working.", type: "text" }], role: "assistant" }, type: "message_end" },
			name: "assistant message_end with no stopReason",
			reason: "no-stopreason",
		},
	] as const;

	for (const { module, name } of DECISION_MODULES) {
		for (const { assistant, event, name: eventName, reason } of rejectionReasonEvents) {
			test(`${name}: ${eventName} returns not-rate-limited`, () => {
				expect(module.isAssistantMessageEvent(event)).toBe(assistant);
				expect(module.isRateLimitEvent(event)).toBe(false);
				expect(module.classifyRateLimitEvent(event)).toEqual({ isRateLimitEvent: false, reason });
				expect(
					module.decideRateLimitRetry({
						attempt: 0,
						event,
						lastRetryAt: null,
						now: 1_000,
						paneId: "%41",
					}),
				).toEqual({ kind: "not-rate-limited", reason });
			});
		}
	}

	test("canonical and vendored decision modules stay behaviorally identical", () => {
		for (const { event } of [
			...rejectionReasonEvents,
			{ event: CANONICAL_RATE_LIMIT_EVENT, name: "canonical rate-limit event" },
			{ event: CLAUDE_SESSION_LIMIT_EVENT, name: "Claude session-limit event" },
			{ event: CLAUDE_USAGE_LIMIT_EVENT, name: "Claude usage-limit event" },
		]) {
			const input = { attempt: 0, event, lastRetryAt: null, now: SESSION_LIMIT_NOW, paneId: "%41" };
			expect(vendoredDecision.decideRateLimitRetry(input)).toEqual(canonicalDecision.decideRateLimitRetry(input));
		}
	});
});

describe("isRateLimitEvent — defensive shape matching", () => {
	test("rejects top-level data.error prose without an assistant message envelope", () => {
		const event = {
				data: {
					error: {
						message: "API Error: Server is temporarily limiting requests · Rate limited",
					},
				},
				stopReason: "error",
				type: "agent_end",
			};
		expect(isRateLimitEvent(event)).toBe(false);
		expect(classifyRateLimitEvent(event)).toEqual({ isRateLimitEvent: false, reason: "non-assistant" });
	});

	test("matches the canonical regex with several phrasings", () => {
		for (const text of [
			"API Error: Server is temporarily limiting requests",
			"Rate limited (try again later)",
			"HTTP 429 too many requests",
			"rate_limit_exceeded",
			"Claude Code returned an error result: You've hit your session limit · resets 7:50pm (America/Los_Angeles)",
			"You've hit your usage limit",
			"session limit",
			"usage limit",
			"· resets 7:50pm",
		]) {
			expect(RATE_LIMIT_ERROR_REGEX.test(text)).toBe(true);
		}
	});

	test("rejects empty / object-only events", () => {
		expect(isRateLimitEvent(null)).toBe(false);
		expect(isRateLimitEvent({})).toBe(false);
		expect(isRateLimitEvent({ type: "message", message: { role: "assistant" } })).toBe(false);
	});
});

describe("extractRetryAfterMs — recursive payload walk", () => {
	test("returns null when no retry-after hint is present", () => {
		expect(extractRetryAfterMs({ message: { role: "assistant" }, type: "message" })).toBeNull();
	});

	test("finds retry_after seconds nested under data.error", () => {
		expect(
			extractRetryAfterMs({
				data: { error: { retry_after: 30 } },
				type: "agent_end",
			}),
		).toBe(30_000);
	});

	test("finds retryAfterMs at top level", () => {
		expect(extractRetryAfterMs({ retryAfterMs: 12_345 })).toBe(12_345);
	});
});

describe("extractResetAtMs — Claude session cap reset parsing", () => {
	test("parses Claude Code session-limit prose with IANA timezone", () => {
		expect(extractResetAtMs(CLAUDE_SESSION_LIMIT_EVENT, SESSION_LIMIT_NOW)).toBe(SESSION_LIMIT_RESET_AT);
	});

	test("parses nested resetsAt ISO values", () => {
		expect(
			extractResetAtMs({
				message: {
					rate_limit_info: { resetsAt: "2026-05-31T02:50:00.000Z" },
					role: "assistant",
					stopReason: "error",
				},
				type: "message",
			}),
		).toBe(SESSION_LIMIT_RESET_AT);
	});

	test("returns null when no reset hint is present", () => {
		expect(extractResetAtMs(CLAUDE_USAGE_LIMIT_EVENT, SESSION_LIMIT_NOW)).toBeNull();
	});
});

describe("structured quota fetchers", () => {
	test("provider quota fetch returns null when auth is unavailable", async () => {
		const calls: Array<{ input: string; init?: Record<string, unknown> }> = [];
		const result = await canonicalDecision.fetchProviderQuotaSnapshotFromEnv(
			CLAUDE_SESSION_LIMIT_EVENT,
			{} as NodeJS.ProcessEnv,
			fakeFetch({ body: CLAUDE_USAGE_RESPONSE, ok: true, status: 200 }, calls),
		);
		expect(result).toBeNull();
		expect(calls).toHaveLength(0);
	});

	test("Claude usage fetch handles 401 without leaking bearer token", async () => {
		const token = "sk-ant-oauth-secret-token-1234567890";
		const calls: Array<{ input: string; init?: Record<string, unknown> }> = [];
		const result = await canonicalDecision.fetchClaudeUsageSnapshotFromEnv(
			{ VSTACK_ANTHROPIC_OAUTH_ACCESS_TOKEN: token, VSTACK_RATE_LIMIT_USAGE_CACHE_MS: "0" } as NodeJS.ProcessEnv,
			fakeFetch({ body: { error: "unauthorized" }, ok: false, status: 401 }, calls),
		);
		expect(result).toMatchObject({ provider: "claude", reason: "http-401", source: "quota-source-error", status: 401 });
		expect(canonicalDecision.quotaSourceFailureSummary(result)).toContain("http-401");
		expect(JSON.stringify(result)).not.toContain(token);
		expect(canonicalDecision.quotaSourceFailureSummary(result)).not.toContain(token);
		expect(calls).toHaveLength(1);
		expect(calls[0]!.input).toBe("https://api.anthropic.com/api/oauth/usage");
		expect(JSON.stringify(calls[0]!.init)).toContain("Bearer");
	});

	test("malformed Claude usage response falls back without token leakage", async () => {
		const token = "sk-ant-oauth-secret-token-abcdefghi";
		const result = await canonicalDecision.fetchClaudeUsageSnapshotFromEnv(
			{ VSTACK_ANTHROPIC_OAUTH_ACCESS_TOKEN: token, VSTACK_RATE_LIMIT_USAGE_CACHE_MS: "0" } as NodeJS.ProcessEnv,
			fakeFetch({ jsonError: new Error(`bad json ${token}`), ok: true, status: 200 }),
		);
		expect(result).toMatchObject({ provider: "claude", reason: "invalid-json", source: "quota-source-error" });
		expect(JSON.stringify(result)).not.toContain(token);
		expect(canonicalDecision.quotaSourceFailureSummary(result)).not.toContain(token);
	});

	test("unrecognized quota schema reports sanitized failure and falls back", async () => {
		const token = "sk-ant-oauth-secret-token-schema123456";
		const result = await canonicalDecision.fetchClaudeUsageSnapshotFromEnv(
			{ VSTACK_ANTHROPIC_OAUTH_ACCESS_TOKEN: token, VSTACK_RATE_LIMIT_USAGE_CACHE_MS: "0" } as NodeJS.ProcessEnv,
			fakeFetch({ body: { not_usage: { reset_at: "2099-01-01T00:00:00Z" } }, ok: true, status: 200 }),
		);
		expect(result).toMatchObject({ provider: "claude", reason: "unrecognized-schema", source: "quota-source-error" });
		expect(JSON.stringify(result)).not.toContain(token);
	});

	test("Codex auth.json token enables wham usage fetch without persisting token in snapshot", async () => {
		const dir = mkdtempSync(join(tmpdir(), "fd-codex-auth-"));
		const token = "codex-secret-token-123456789012345";
		try {
			mkdirSync(dir, { recursive: true });
			writeFileSync(join(dir, "auth.json"), JSON.stringify({ tokens: { access_token: token }, plan_type: "prolite" }));
			const calls: Array<{ input: string; init?: Record<string, unknown> }> = [];
			const result = await canonicalDecision.fetchCodexUsageSnapshotFromEnv(
				{ CODEX_HOME: dir, VSTACK_RATE_LIMIT_USAGE_CACHE_MS: "0" } as NodeJS.ProcessEnv,
				fakeFetch({ body: CODEX_WHAM_USAGE, ok: true, status: 200 }, calls),
			);
			if (!result || result.source === "quota-source-error") {
				throw new Error(`expected codex quota snapshot, got ${JSON.stringify(result)}`);
			}
			expect(result.provider).toBe("codex");
			expect(result.windows.length).toBeGreaterThan(0);
			expect(calls[0]!.input).toBe("https://chatgpt.com/backend-api/wham/usage");
			expect(JSON.stringify(result)).not.toContain(token);
		} finally {
			rmSync(dir, { force: true, recursive: true });
		}
	});
});

describe("env parsers", () => {
	test("watchdog enabled defaults to true; honors 0/false/off", () => {
		expect(rateLimitWatchdogEnabledFromEnv({} as NodeJS.ProcessEnv)).toBe(true);
		expect(rateLimitWatchdogEnabledFromEnv({ VSTACK_RATE_LIMIT_WATCHDOG: "0" } as any)).toBe(false);
		expect(rateLimitWatchdogEnabledFromEnv({ VSTACK_RATE_LIMIT_WATCHDOG: "false" } as any)).toBe(false);
		expect(rateLimitWatchdogEnabledFromEnv({ VSTACK_RATE_LIMIT_WATCHDOG: "off" } as any)).toBe(false);
		expect(rateLimitWatchdogEnabledFromEnv({ VSTACK_RATE_LIMIT_WATCHDOG: "1" } as any)).toBe(true);
	});

	test("max attempts defaults to 5 and clamps garbage", () => {
		expect(rateLimitMaxAttemptsFromEnv({} as NodeJS.ProcessEnv)).toBe(RATE_LIMIT_DEFAULT_MAX_ATTEMPTS);
		expect(rateLimitMaxAttemptsFromEnv({ VSTACK_RATE_LIMIT_MAX_ATTEMPTS: "3" } as any)).toBe(3);
		expect(rateLimitMaxAttemptsFromEnv({ VSTACK_RATE_LIMIT_MAX_ATTEMPTS: "garbage" } as any)).toBe(
			RATE_LIMIT_DEFAULT_MAX_ATTEMPTS,
		);
		expect(rateLimitMaxAttemptsFromEnv({ VSTACK_RATE_LIMIT_MAX_ATTEMPTS: "0" } as any)).toBe(
			RATE_LIMIT_DEFAULT_MAX_ATTEMPTS,
		);
	});

	test("backoff ladder defaults to 60,120,300,600,1800 and parses overrides", () => {
		expect(rateLimitBackoffLadderFromEnv({} as NodeJS.ProcessEnv)).toEqual([60, 120, 300, 600, 1800]);
		expect(
			rateLimitBackoffLadderFromEnv({ VSTACK_RATE_LIMIT_BACKOFF_LADDER: "5,10" } as any),
		).toEqual([5, 10]);
		expect(
			rateLimitBackoffLadderFromEnv({ VSTACK_RATE_LIMIT_BACKOFF_LADDER: "garbage" } as any),
		).toEqual([60, 120, 300, 600, 1800]);
	});
});
