/**
 * Rate-limit retry decision. The event and quota-snapshot readers it needs
 * live in rate-limit-reset.ts and rate-limit-quota-normalize.ts; this module
 * is the decision itself.
 *
 * Eager on the extension startup path: index.ts imports rate-limit-watchdog.ts
 * statically, which imports this. Every module in that transitive static
 * closure, including the two this file pulls in, must take no node:* import.
 * Pi 0.80.3's binary TS loader resolves transpiled TS through data: URLs and a
 * large module with node:* imports trips Bun/JITI NameTooLong there. The
 * provider fetch that needs node:fs is rate-limit-quota.ts, imported
 * dynamically after a rate-limit event. Documented, not enforced.
 */

import {
	extractAssistantErrorText,
	extractResetAtMs,
	extractRetryAfterMs,
	extractStructuredResetAtMs,
	readAssistantMessage,
	readAssistantStopReason,
} from "./rate-limit-reset.js";
import { quotaSourceFailureSummary, selectQuotaSnapshotReset } from "./rate-limit-quota-normalize.js";

export { quotaSourceFailureSummary };

export const RATE_LIMIT_STEER_MESSAGE =
	"API rate limit was detected. Try to continue from where you left off." as const;

export const RATE_LIMIT_DEFAULT_MAX_ATTEMPTS = 5;
export const RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC = [60, 120, 300, 600, 1800] as const;
export const RATE_LIMIT_RESET_MARGIN_MS = 5_000;

export const RATE_LIMIT_ERROR_REGEX =
	/(temporarily limiting requests|rate[\s_-]?limit(?:ed)?|429|529|too many requests|overload(?:ed|ing)?|resource exhausted|stream idle timeout|(?:you(?:['’]?ve|\s+have)\s+hit\s+your\s+(?:session|usage)\s+limit)|\b(?:session|usage)\s+limit\b|[·•]\s*resets\b|\bresets?\s+(?:at\s+)?\d{1,2}(?::\d{2}){0,2}\s*(?:am|pm)?)/i;

export interface RateLimitWatchdogInput {
	event: unknown;
	paneId: string;
	attempt: number;
	lastRetryAt: number | null;
	now: number;
	usageSnapshot?: unknown;
}

export type RateLimitResetSource = "usage-endpoint" | "cli-rpc" | "sdk-rate-limit-event" | "prose-fallback" | "backoff-only";

export interface QuotaWindow {
	id: string;
	title: string;
	usedPercent: number | null;
	resetAtMs: number | null;
	windowSeconds?: number;
	limitReached?: boolean;
}

export interface QuotaSnapshot {
	provider: "claude" | "codex" | "openai" | string;
	source: "usage-endpoint" | "cli-rpc";
	fetchedAtMs: number;
	windows: QuotaWindow[];
	rawShapeVersion?: string;
}

export type RateLimitUsageEndpointSnapshot = QuotaSnapshot;

export interface QuotaSourceFailure {
	source: "quota-source-error";
	provider: string;
	resetSource: "usage-endpoint" | "cli-rpc";
	reason: string;
	status?: number;
	endpoint?: string;
}

export type QuotaSourceResult = QuotaSnapshot | QuotaSourceFailure | null;

export type RateLimitSkipReason = "non-assistant" | "no-stopreason" | "stopreason-mismatch" | "no-prose";

export type RateLimitEventClassification =
	| { isRateLimitEvent: true }
	| { isRateLimitEvent: false; reason: RateLimitSkipReason };

export type RateLimitWatchdogDecision =
	| { kind: "not-rate-limited"; reason: RateLimitSkipReason }
	| {
		kind: "retry-at";
		at: number;
		attempt: number;
		degradedResetSource: boolean;
		hash: string;
		resetAtMs?: number;
		resetSource: RateLimitResetSource;
		steerMessage: typeof RATE_LIMIT_STEER_MESSAGE;
	}
	| { kind: "exhausted"; attempt: number; reason: string };

export interface RateLimitWatchdogEnv {
	maxAttempts?: number;
	backoffLadderSec?: readonly number[];
	enabled?: boolean;
}

interface RateLimitScheduleBasis {
	delayMs: number;
	degradedResetSource: boolean;
	resetAtMs?: number;
	resetSource: RateLimitResetSource;
}

export function rateLimitWatchdogEnabledFromEnv(env: NodeJS.ProcessEnv = process.env): boolean {
	const raw = env.KENDEX_RATE_LIMIT_WATCHDOG?.trim();
	if (raw === undefined || raw === "") return true;
	return raw !== "0" && raw.toLowerCase() !== "false" && raw.toLowerCase() !== "off";
}

export function rateLimitMaxAttemptsFromEnv(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.KENDEX_RATE_LIMIT_MAX_ATTEMPTS?.trim();
	const parsed = raw ? Number(raw) : Number.NaN;
	if (!Number.isFinite(parsed) || parsed < 1) return RATE_LIMIT_DEFAULT_MAX_ATTEMPTS;
	return Math.floor(parsed);
}

export function rateLimitBackoffLadderFromEnv(env: NodeJS.ProcessEnv = process.env): number[] {
	const raw = env.KENDEX_RATE_LIMIT_BACKOFF_LADDER?.trim();
	if (!raw) return [...RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC];
	const parts = raw
		.split(",")
		.map((part) => part.trim())
		.filter(Boolean)
		.map((part) => Number(part))
		.filter((value) => Number.isFinite(value) && value > 0)
		.map((value) => Math.floor(value));
	return parts.length > 0 ? parts : [...RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC];
}

export function classifyRateLimitEvent(event: unknown): RateLimitEventClassification {
	const message = readAssistantMessage(event);
	if (!message) return { isRateLimitEvent: false, reason: "non-assistant" };
	const stopReason = readAssistantStopReason(message);
	if (!stopReason) return { isRateLimitEvent: false, reason: "no-stopreason" };
	if (stopReason !== "error") return { isRateLimitEvent: false, reason: "stopreason-mismatch" };
	const text = extractAssistantErrorText(message);
	if (!text || !RATE_LIMIT_ERROR_REGEX.test(text)) return { isRateLimitEvent: false, reason: "no-prose" };
	return { isRateLimitEvent: true };
}

export function isRateLimitEvent(event: unknown): boolean {
	return classifyRateLimitEvent(event).isRateLimitEvent;
}

export function isAssistantMessageEvent(event: unknown): boolean {
	return readAssistantMessage(event) !== null;
}

export function chooseRateLimitScheduleBasis(input: RateLimitWatchdogInput, ladderMs: number): RateLimitScheduleBasis {
	const usageReset = selectQuotaSnapshotReset(input.usageSnapshot, input.event, input.now);
	if (usageReset) {
		return {
			delayMs: Math.max(0, usageReset.resetAtMs + RATE_LIMIT_RESET_MARGIN_MS - input.now),
			degradedResetSource: false,
			resetAtMs: usageReset.resetAtMs,
			resetSource: usageReset.resetSource,
		};
	}
	const explicitMs = extractRetryAfterMs(input.event);
	const sdkResetAtMs = extractStructuredResetAtMs(input.event);
	if (explicitMs !== null || sdkResetAtMs !== null) {
		return {
			delayMs: Math.max(ladderMs, Math.max(0, (sdkResetAtMs ?? input.now) + RATE_LIMIT_RESET_MARGIN_MS - input.now), explicitMs ?? 0),
			degradedResetSource: false,
			...(sdkResetAtMs !== null ? { resetAtMs: sdkResetAtMs } : {}),
			resetSource: "sdk-rate-limit-event",
		};
	}
	const proseResetAtMs = extractResetAtMs(input.event, input.now);
	if (proseResetAtMs !== null) {
		return {
			delayMs: Math.max(ladderMs, Math.max(0, proseResetAtMs + RATE_LIMIT_RESET_MARGIN_MS - input.now)),
			degradedResetSource: true,
			resetAtMs: proseResetAtMs,
			resetSource: "prose-fallback",
		};
	}
	return { delayMs: ladderMs, degradedResetSource: true, resetSource: "backoff-only" };
}

export function decideRateLimitRetry(
	input: RateLimitWatchdogInput,
	envOverride: RateLimitWatchdogEnv = {},
): RateLimitWatchdogDecision {
	const classification = classifyRateLimitEvent(input.event);
	if (!classification.isRateLimitEvent) return { kind: "not-rate-limited", reason: classification.reason };

	const maxAttempts = envOverride.maxAttempts ?? rateLimitMaxAttemptsFromEnv();
	if (input.attempt >= maxAttempts) {
		return {
			attempt: input.attempt,
			kind: "exhausted",
			reason: `rate-limit retries exhausted after ${input.attempt} attempt${input.attempt === 1 ? "" : "s"}`,
		};
	}

	const ladder = envOverride.backoffLadderSec ?? rateLimitBackoffLadderFromEnv();
	const ladderIndex = Math.min(input.attempt, ladder.length - 1);
	const ladderMs = Math.max(0, Math.floor(ladder[ladderIndex]! * 1000));
	const basis = chooseRateLimitScheduleBasis(input, ladderMs);
	const at = input.now + basis.delayMs;
	const nextAttempt = input.attempt + 1;
	return {
		kind: "retry-at",
		at,
		attempt: nextAttempt,
		degradedResetSource: basis.degradedResetSource,
		hash: `${input.paneId}:${nextAttempt}:${at}`,
		...(basis.resetAtMs !== undefined ? { resetAtMs: basis.resetAtMs } : {}),
		resetSource: basis.resetSource,
		steerMessage: RATE_LIMIT_STEER_MESSAGE,
	};
}
