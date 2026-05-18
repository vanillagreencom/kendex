/**
 * Vendored mirror of skills/flightdeck/lib/flightdeck-core/src/daemon/
 * rate-limit-watchdog.ts (vstack#108). The canonical reference lives in
 * flightdeck-core and is parity-tested there; pi-extensions ship as
 * standalone npm-style packages so a relative import outside the
 * package boundary will not resolve post-install. Keep this file in
 * lock-step with the canonical module — parity tests in both packages
 * exercise the same decision shape so drift surfaces quickly.
 *
 * Functional copy: identical inputs must produce identical decisions.
 */

export const RATE_LIMIT_STEER_MESSAGE =
	"API rate limit was detected. Try to continue from where you left off." as const;

export const RATE_LIMIT_DEFAULT_MAX_ATTEMPTS = 5;
export const RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC = [60, 120, 300, 600, 1800] as const;

export const RATE_LIMIT_ERROR_REGEX =
	/(temporarily limiting requests|rate[\s_-]?limit(?:ed)?|429|too many requests)/i;

export interface RateLimitWatchdogInput {
	event: unknown;
	paneId: string;
	attempt: number;
	lastRetryAt: number | null;
	now: number;
}

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
		hash: string;
		steerMessage: typeof RATE_LIMIT_STEER_MESSAGE;
	}
	| { kind: "exhausted"; attempt: number; reason: string };

export interface RateLimitWatchdogEnv {
	maxAttempts?: number;
	backoffLadderSec?: readonly number[];
	enabled?: boolean;
}

export function rateLimitWatchdogEnabledFromEnv(env: NodeJS.ProcessEnv = process.env): boolean {
	const raw = env.VSTACK_RATE_LIMIT_WATCHDOG?.trim();
	if (raw === undefined || raw === "") return true;
	return raw !== "0" && raw.toLowerCase() !== "false" && raw.toLowerCase() !== "off";
}

export function rateLimitMaxAttemptsFromEnv(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.VSTACK_RATE_LIMIT_MAX_ATTEMPTS?.trim();
	const parsed = raw ? Number(raw) : Number.NaN;
	if (!Number.isFinite(parsed) || parsed < 1) return RATE_LIMIT_DEFAULT_MAX_ATTEMPTS;
	return Math.floor(parsed);
}

export function rateLimitBackoffLadderFromEnv(env: NodeJS.ProcessEnv = process.env): number[] {
	const raw = env.VSTACK_RATE_LIMIT_BACKOFF_LADDER?.trim();
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

export function extractRetryAfterMs(event: unknown): number | null {
	const seen = new Set<unknown>();
	const stack: unknown[] = [event];
	while (stack.length > 0) {
		const node = stack.pop();
		if (!node || typeof node !== "object" || seen.has(node)) continue;
		seen.add(node);
		const record = node as Record<string, unknown>;
		for (const key of ["retry_after_ms", "retryAfterMs", "retryAfter", "retry_after"]) {
			const value = record[key];
			if (typeof value === "number" && Number.isFinite(value) && value > 0) {
				if (key === "retry_after_ms" || key === "retryAfterMs") return Math.floor(value);
				return Math.floor(value * 1000);
			}
			if (typeof value === "string" && /^[0-9]+(?:\.[0-9]+)?$/.test(value)) {
				const parsed = Number(value);
				if (key === "retry_after_ms" || key === "retryAfterMs") return Math.floor(parsed);
				return Math.floor(parsed * 1000);
			}
		}
		for (const child of Object.values(record)) {
			if (child && typeof child === "object") stack.push(child);
		}
	}
	return null;
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
	const explicitMs = extractRetryAfterMs(input.event);
	const delayMs = explicitMs !== null ? Math.max(ladderMs, explicitMs) : ladderMs;
	const at = input.now + delayMs;
	const nextAttempt = input.attempt + 1;
	const hash = `${input.paneId}:${nextAttempt}:${at}`;
	return { at, attempt: nextAttempt, hash, kind: "retry-at", steerMessage: RATE_LIMIT_STEER_MESSAGE };
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object";
}

function readAssistantMessage(event: unknown): Record<string, unknown> | null {
	if (!isRecord(event)) return null;
	const directMessage = event.message;
	if (isRecord(directMessage) && directMessage.role === "assistant") return directMessage;
	const data = event.data;
	if (isRecord(data)) {
		const dataMessage = data.message;
		if (isRecord(dataMessage) && dataMessage.role === "assistant") return dataMessage;
	}
	return null;
}

function extractAssistantErrorText(message: Record<string, unknown>): string {
	const parts: string[] = [];
	for (const key of ["errorMessage", "error_message"]) {
		const value = message[key];
		if (typeof value === "string" && value) parts.push(value);
	}
	const content = message.content;
	if (Array.isArray(content)) {
		for (const item of content) {
			if (!isRecord(item)) continue;
			const text = item.text;
			if (typeof text === "string" && text) parts.push(text);
		}
	}
	return parts.join("\n");
}

function readAssistantStopReason(message: Record<string, unknown>): string | null {
	const value = message.stopReason;
	return typeof value === "string" ? value : null;
}
