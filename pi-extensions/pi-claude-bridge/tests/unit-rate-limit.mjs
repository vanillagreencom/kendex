/**
 * Tests for Claude SDK rate-limit event rendering.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { classifyClaudeFailure } from "../src/account-router.ts";
import {
	DEFAULT_STREAM_IDLE_TIMEOUT_MS,
	STREAM_IDLE_BACKOFF_HINT_MS,
	buildStreamIdleTimeoutErrorMessage,
	createStreamIdleWatchdog,
	formatAllowedRateLimitWarning,
	formatResetTimestamp,
	normalizeRateLimitUtilization,
	resetTimestampMs,
	streamIdleTimeoutMsFromEnv,
} from "../src/index.ts";

describe("rate-limit reset timestamps", () => {
	// SDKRateLimitInfo.resetsAt is a bare number in epoch SECONDS. Treating it
	// as milliseconds rendered "resets Jan 21, 1970" for a Jul 2026 reset.
	const JUL_30_2026_SECONDS = 1785412800;

	it("treats a bare numeric resetsAt as epoch seconds", () => {
		assert.equal(resetTimestampMs(JUL_30_2026_SECONDS), JUL_30_2026_SECONDS * 1000);
		assert.match(formatResetTimestamp(JUL_30_2026_SECONDS), /2026/);
		assert.doesNotMatch(formatResetTimestamp(JUL_30_2026_SECONDS), /1970/);
	});

	it("passes epoch milliseconds through unchanged", () => {
		assert.equal(resetTimestampMs(JUL_30_2026_SECONDS * 1000), JUL_30_2026_SECONDS * 1000);
		assert.match(formatResetTimestamp(JUL_30_2026_SECONDS * 1000), /2026/);
	});

	it("parses ISO strings and rejects garbage", () => {
		assert.equal(resetTimestampMs("2026-07-30T11:00:00Z"), Date.parse("2026-07-30T11:00:00Z"));
		assert.equal(resetTimestampMs("not a date"), undefined);
		assert.equal(resetTimestampMs(undefined), undefined);
		assert.equal(formatResetTimestamp(undefined), "unknown");
	});
});

describe("rate_limit_event allowed_warning", () => {
	it("warns only when SDK utilization reaches the threshold", () => {
		for (const [utilization, expected] of [[0.01, undefined], [1, ["seven_day", "/usage"]], [0.91, ["seven_day", "/usage"]]]) {
			const warning = formatAllowedRateLimitWarning({ status: "allowed_warning", rateLimitType: "seven_day", utilization });
			assert.deepEqual(warning?.match(/seven_day|\/usage/g), expected, String(utilization));
		}
	});

	it("normalizes SDK fractional and percent utilization", () => {
		for (const [input, expected] of [
			[0, 0], [0.5, 50], [1, 100], [1.5, 1.5], [100, 100],
			[101, undefined], [NaN, undefined], [-1, undefined],
			["91", undefined], [undefined, undefined], [0.91, 91], [91, 91],
		]) {
			assert.equal(normalizeRateLimitUtilization(input), expected, String(input));
		}
	});
});

describe("stream-idle timeout", () => {
	it("parses env timeout with seconds default and disable value", () => {
		for (const [env, expected] of [
			[{}, DEFAULT_STREAM_IDLE_TIMEOUT_MS],
			[{ CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "45" }, 45_000],
			[{ CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "250ms" }, 250],
			[{ CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "2m" }, 120_000],
			[{ CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "0" }, 0],
			[{ CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "bogus" }, DEFAULT_STREAM_IDLE_TIMEOUT_MS],
		]) {
			assert.equal(streamIdleTimeoutMsFromEnv(env), expected, JSON.stringify(env));
		}
	});

	it("builds an error that existing rate-limit classifiers can detect", () => {
		const message = buildStreamIdleTimeoutErrorMessage(90_000);
		assert.equal(classifyClaudeFailure(message), "rate-limit");
		assert.match(message, /\b529\b/);
		assert.match(message, /\b90s\b/);
		assert.match(message, new RegExp(`\\b${STREAM_IDLE_BACKOFF_HINT_MS / 1000}s\\b`));
	});

	it("fires only while a Pi stream is waiting for first assistant output", () => {
		let now = 0;
		const timers = [];
		const state = {
			activeQuery: {},
			currentPiStream: {},
			turnOutput: { timestamp: 0 },
			turnSawStreamEvent: false,
			turnStarted: false,
		};
		const timeouts = [];
		const watchdog = createStreamIdleWatchdog({
			clearTimer: (timer) => { timer.cancelled = true; },
			getState: () => state,
			now: () => now,
			onTimeout: (info) => timeouts.push(info),
			setTimer: (fn, delayMs) => {
				const timer = { cancelled: false, delayMs, fn };
				timers.push(timer);
				return timer;
			},
			timeoutMs: 1_000,
		});

		watchdog.refresh();
		assert.equal(timers.at(-1).delayMs, 1_000);
		now = 400;
		watchdog.noteChunk();
		assert.equal(timers.at(-1).delayMs, 1_000);
		now = 1_399;
		timers.at(-1).fn();
		assert.equal(timeouts.length, 0);
		assert.equal(timers.at(-1).delayMs, 1);
		now = 1_400;
		timers.at(-1).fn();
		assert.deepEqual(timeouts, [{ idleMs: 1_000, timeoutMs: 1_000 }]);
		assert.equal(watchdog.timedOut(), true);
	});

	it("does not fire after visible stream output starts", () => {
		let now = 0;
		let timer;
		const state = {
			activeQuery: {},
			currentPiStream: {},
			turnOutput: { timestamp: 0 },
			turnSawStreamEvent: false,
			turnStarted: false,
		};
		const timeouts = [];
		const watchdog = createStreamIdleWatchdog({
			clearTimer: (handle) => { handle.cancelled = true; },
			getState: () => state,
			now: () => now,
			onTimeout: (info) => timeouts.push(info),
			setTimer: (fn, delayMs) => {
				timer = { cancelled: false, delayMs, fn };
				return timer;
			},
			timeoutMs: 1_000,
		});
		watchdog.refresh();
		state.turnSawStreamEvent = true;
		now = 1_000;
		timer.fn();
		assert.equal(timeouts.length, 0);
		assert.equal(timer.cancelled, true);
	});
});
