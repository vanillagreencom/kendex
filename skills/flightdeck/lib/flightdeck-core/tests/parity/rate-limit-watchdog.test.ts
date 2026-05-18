// vstack#108: pure-function regression coverage for the rate-limit
// watchdog decision module. Same decision module is consumed by Layer A
// (pi-agents-tmux subagent watchdog) and Layer B (bash subscriber wake
// branch); both layers must observe identical transitions for identical
// inputs.

import { describe, expect, test } from "bun:test";

import * as canonicalDecision from "../../src/daemon/rate-limit-watchdog.ts";
import * as vendoredDecision from "../../../../../../pi-extensions/pi-agents-tmux/extensions/subagent/rate-limit-decision.ts";

const {
	RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC,
	RATE_LIMIT_DEFAULT_MAX_ATTEMPTS,
	RATE_LIMIT_ERROR_REGEX,
	RATE_LIMIT_STEER_MESSAGE,
	classifyRateLimitEvent,
	decideRateLimitRetry,
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
		]) {
			const input = { attempt: 0, event, lastRetryAt: null, now: 10_000, paneId: "%41" };
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
