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

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const RATE_LIMIT_STEER_MESSAGE =
	"API rate limit was detected. Try to continue from where you left off." as const;

export const RATE_LIMIT_DEFAULT_MAX_ATTEMPTS = 5;
export const RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC = [60, 120, 300, 600, 1800] as const;
export const RATE_LIMIT_RESET_MARGIN_MS = 5_000;
export const RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS = 10 * 60_000;

export const RATE_LIMIT_ERROR_REGEX =
	/(temporarily limiting requests|rate[\s_-]?limit(?:ed)?|429|too many requests|(?:you(?:['’]?ve|\s+have)\s+hit\s+your\s+(?:session|usage)\s+limit)|\b(?:session|usage)\s+limit\b|[·•]\s*resets\b|\bresets?\s+(?:at\s+)?\d{1,2}(?::\d{2}){0,2}\s*(?:am|pm)?)/i;

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

export function rateLimitUsageSnapshotFromEnv(env: NodeJS.ProcessEnv = process.env): QuotaSourceResult {
	const raw = env.VSTACK_RATE_LIMIT_USAGE_JSON?.trim();
	if (!raw) return null;
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch (error) {
		return quotaSourceFailure("unknown", "usage-endpoint", "invalid-env-json", undefined, "VSTACK_RATE_LIMIT_USAGE_JSON", error);
	}
	if (quotaSourceFailureSummary(parsed)) return parsed as QuotaSourceFailure;
	const snapshot = normalizeQuotaSnapshot("unknown", "usage-endpoint", parsed, Date.now(), "env-json");
	return snapshot.windows.length > 0
		? snapshot
		: quotaSourceFailure("unknown", "usage-endpoint", "unrecognized-env-schema", undefined, "VSTACK_RATE_LIMIT_USAGE_JSON");
}

type FetchLike = (input: string, init?: Record<string, unknown>) => Promise<{
	ok: boolean;
	status: number;
	json: () => Promise<unknown>;
}>;

export async function fetchClaudeUsageSnapshotFromEnv(
	env: NodeJS.ProcessEnv = process.env,
	fetchImpl: FetchLike | undefined = (globalThis as unknown as { fetch?: FetchLike }).fetch,
): Promise<QuotaSourceResult> {
	const inline = rateLimitUsageSnapshotFromEnv(env);
	if (inline) return inline;
	if (!fetchImpl) return null;
	const timeoutMs = parsePositiveInt(env.VSTACK_RATE_LIMIT_USAGE_FETCH_TIMEOUT_MS, 3_000);
	const cacheMs = parsePositiveInt(env.VSTACK_RATE_LIMIT_USAGE_CACHE_MS, 60_000);
	const oauthToken = firstNonEmptyEnv(env, [
		"VSTACK_ANTHROPIC_OAUTH_ACCESS_TOKEN",
		"ANTHROPIC_ACCESS_TOKEN",
		"ANTHROPIC_AUTH_TOKEN",
		"CLAUDE_CODE_OAUTH_TOKEN",
		"CLAUDE_CODE_ACCESS_TOKEN",
	]);
	if (oauthToken) {
		return cachedQuotaSnapshot(`claude:oauth:${oauthToken.slice(-8)}`, cacheMs, () => fetchUsageEndpoint(fetchImpl, "claude", "https://api.anthropic.com/api/oauth/usage", {
			"anthropic-version": "2023-06-01",
			Authorization: `Bearer ${oauthToken}`,
		}, timeoutMs));
	}
	const orgId = firstNonEmptyEnv(env, ["VSTACK_CLAUDE_ORG_ID", "CLAUDE_AI_ORG_ID", "CLAUDE_ORG_ID"]);
	const cookie = firstNonEmptyEnv(env, ["VSTACK_CLAUDE_AI_COOKIE", "CLAUDE_AI_COOKIE", "CLAUDE_COOKIE"]);
	if (orgId && cookie) {
		return cachedQuotaSnapshot(`claude:web:${orgId}:${hashString(cookie)}`, cacheMs, () => fetchUsageEndpoint(fetchImpl, "claude", `https://claude.ai/api/organizations/${encodeURIComponent(orgId)}/usage`, {
			Cookie: cookie,
		}, timeoutMs));
	}
	return null;
}

export async function fetchCodexUsageSnapshotFromEnv(
	env: NodeJS.ProcessEnv = process.env,
	fetchImpl: FetchLike | undefined = (globalThis as unknown as { fetch?: FetchLike }).fetch,
): Promise<QuotaSourceResult> {
	const inline = rateLimitUsageSnapshotFromEnv(env);
	if (inline) return inline;
	if (!fetchImpl) return null;
	const token = codexAuthTokenFromEnv(env);
	if (!token) return fetchCodexCliRpcQuotaSnapshotFromEnv(env);
	const timeoutMs = parsePositiveInt(env.VSTACK_RATE_LIMIT_USAGE_FETCH_TIMEOUT_MS, 3_000);
	const cacheMs = parsePositiveInt(env.VSTACK_RATE_LIMIT_USAGE_CACHE_MS, 60_000);
	return cachedQuotaSnapshot(`codex:wham:${token.slice(-8)}`, cacheMs, () => fetchUsageEndpoint(fetchImpl, "codex", "https://chatgpt.com/backend-api/wham/usage", {
		Authorization: `Bearer ${token}`,
	}, timeoutMs));
}

export async function fetchCodexCliRpcQuotaSnapshotFromEnv(_env: NodeJS.ProcessEnv = process.env): Promise<QuotaSnapshot | null> {
	// Source seam for a bounded `codex -s read-only -a untrusted app-server`
	// JSON-RPC client. Intentionally not spawned in this PR; CLI lifecycle,
	// timeout, and token/account redaction deserve separate focused coverage.
	return null;
}

export async function fetchProviderQuotaSnapshotFromEnv(
	event: unknown,
	env: NodeJS.ProcessEnv = process.env,
	fetchImpl: FetchLike | undefined = (globalThis as unknown as { fetch?: FetchLike }).fetch,
): Promise<QuotaSourceResult> {
	const inline = rateLimitUsageSnapshotFromEnv(env);
	if (inline) return inline;
	const provider = providerFromRateLimitEvent(event);
	if (provider === "codex" || provider === "openai") return fetchCodexUsageSnapshotFromEnv(env, fetchImpl);
	if (provider === "claude") return fetchClaudeUsageSnapshotFromEnv(env, fetchImpl);
	return null;
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
				// `retry_after` / `retryAfter` are conventionally seconds on
				// HTTP 429 responses; everything ending in `_ms` / `Ms` is
				// milliseconds. Normalise to ms.
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

export function extractResetAtMs(event: unknown, now: number = Date.now()): number | null {
	const structured = extractStructuredResetAtMs(event);
	if (structured !== null) return structured;

	const message = readAssistantMessage(event);
	if (!message) return null;
	return extractResetAtMsFromText(extractAssistantErrorText(message), now);
}

export interface RateLimitScheduleBasis {
	delayMs: number;
	resetAtMs: number | null;
	resetSource: RateLimitResetSource;
	degradedResetSource: boolean;
}

export function chooseRateLimitScheduleBasis(input: RateLimitWatchdogInput, ladderMs: number): RateLimitScheduleBasis {
	const usageReset = selectQuotaSnapshotReset(input.usageSnapshot, input.event, input.now);
	if (usageReset !== null) {
		return {
			degradedResetSource: false,
			delayMs: Math.max(0, usageReset.resetAtMs + RATE_LIMIT_RESET_MARGIN_MS - input.now),
			resetAtMs: usageReset.resetAtMs,
			resetSource: usageReset.resetSource,
		};
	}

	const sdkResetAtMs = extractStructuredResetAtMs(input.event);
	const explicitMs = extractRetryAfterMs(input.event);
	if (sdkResetAtMs !== null) {
		return {
			degradedResetSource: false,
			delayMs: Math.max(ladderMs, Math.max(0, sdkResetAtMs + RATE_LIMIT_RESET_MARGIN_MS - input.now), explicitMs ?? 0),
			resetAtMs: sdkResetAtMs,
			resetSource: "sdk-rate-limit-event",
		};
	}
	if (explicitMs !== null) {
		return {
			degradedResetSource: false,
			delayMs: Math.max(ladderMs, explicitMs),
			resetAtMs: null,
			resetSource: "sdk-rate-limit-event",
		};
	}

	const message = readAssistantMessage(input.event);
	const proseResetAtMs = message ? extractResetAtMsFromText(extractAssistantErrorText(message), input.now) : null;
	if (proseResetAtMs !== null) {
		return {
			degradedResetSource: true,
			delayMs: Math.max(ladderMs, Math.max(0, proseResetAtMs + RATE_LIMIT_RESET_MARGIN_MS - input.now)),
			resetAtMs: proseResetAtMs,
			resetSource: "prose-fallback",
		};
	}

	return { degradedResetSource: true, delayMs: ladderMs, resetAtMs: null, resetSource: "backoff-only" };
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
	const delayMs = basis.delayMs;
	const at = input.now + delayMs;
	const nextAttempt = input.attempt + 1;
	const hash = `${input.paneId}:${nextAttempt}:${at}`;
	return {
		at,
		attempt: nextAttempt,
		degradedResetSource: basis.degradedResetSource,
		hash,
		kind: "retry-at",
		...(basis.resetAtMs !== null ? { resetAtMs: basis.resetAtMs } : {}),
		resetSource: basis.resetSource,
		steerMessage: RATE_LIMIT_STEER_MESSAGE,
	};
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object";
}

interface UsageResetCandidate {
	path: string;
	title: string;
	limitReached: boolean;
	resetAtMs: number;
	utilization: number;
}

export function extractUsageEndpointResetAtMs(snapshot: unknown, event: unknown, now: number = Date.now()): number | null {
	return selectQuotaSnapshotReset(snapshot, event, now)?.resetAtMs ?? null;
}

export function selectQuotaSnapshotReset(
	snapshot: unknown,
	event: unknown,
	now: number = Date.now(),
): { resetAtMs: number; resetSource: "usage-endpoint" | "cli-rpc" } | null {
	const quota = normalizeQuotaSnapshotFromUnknown(snapshot, now);
	if (!quota) return null;
	const candidates = quota.windows
		.filter((window) => window.resetAtMs !== null && window.resetAtMs > now)
		.map((window) => ({
			limitReached: window.limitReached === true,
			path: window.id,
			resetAtMs: window.resetAtMs!,
			title: window.title,
			utilization: window.usedPercent === null ? 0 : window.usedPercent / 100,
		}));
	if (candidates.length === 0) return null;
	const typeHint = normalizeQuotaHint(extractRateLimitType(event));
	const modelHint = normalizeQuotaHint(readAssistantMessage(event)?.model);
	const typeMatching = candidates.filter((candidate) => quotaCandidateMatchesType(candidate, typeHint));
	const modelMatching = candidates.filter((candidate) => quotaCandidateMatchesModel(candidate, modelHint));
	const matched = typeMatching.length > 0 ? typeMatching : modelMatching.length > 0 ? modelMatching : candidates;
	const eligible = isSessionOrUsageCapEvent(event) && !hasNegatedSessionOrUsageLimit(event)
		? matched
		: matched.filter((candidate) => quotaCandidateSaturated(candidate));
	if (eligible.length === 0) return null;
	const selected = chooseUsageResetCandidate(eligible);
	return selected ? { resetAtMs: selected.resetAtMs, resetSource: quota.source } : null;
}

export function normalizeQuotaSnapshot(
	provider: string,
	source: "usage-endpoint" | "cli-rpc",
	raw: unknown,
	fetchedAtMs: number = Date.now(),
	rawShapeVersion = "provider-quota-v1",
): QuotaSnapshot {
	const existing = normalizeQuotaSnapshotFromUnknown(raw, fetchedAtMs, source, provider);
	if (existing) return existing;
	return { fetchedAtMs, provider, rawShapeVersion, source, windows: collectProviderQuotaWindows(provider, raw, fetchedAtMs) };
}

function normalizeQuotaSnapshotFromUnknown(
	snapshot: unknown,
	now: number,
	fallbackSource: "usage-endpoint" | "cli-rpc" = "usage-endpoint",
	fallbackProvider = "unknown",
): QuotaSnapshot | null {
	if (snapshot === null || snapshot === undefined) return null;
	if (isRecord(snapshot) && Array.isArray(snapshot.windows)) {
		const hasTrustedSource = snapshot.source === "cli-rpc" || snapshot.source === "usage-endpoint";
		const provider = typeof snapshot.provider === "string" && snapshot.provider ? snapshot.provider : fallbackProvider;
		const hasTrustedProvider = provider !== "unknown";
		if (!hasTrustedSource && !hasTrustedProvider) return null;
		const source = snapshot.source === "cli-rpc" ? "cli-rpc" : snapshot.source === "usage-endpoint" ? "usage-endpoint" : fallbackSource;
		return {
			fetchedAtMs: coerceFiniteNumber(snapshot.fetchedAtMs) ?? now,
			provider,
			rawShapeVersion: typeof snapshot.rawShapeVersion === "string" ? snapshot.rawShapeVersion : undefined,
			source,
			windows: snapshot.windows.flatMap((window, index) => normalizeQuotaWindow(window, index)),
		};
	}
	if (isRecord(snapshot) && (snapshot.source === "usage-endpoint" || snapshot.source === "cli-rpc") && "data" in snapshot) {
		const provider = typeof snapshot.provider === "string" ? snapshot.provider : fallbackProvider;
		return normalizeQuotaSnapshot(provider, snapshot.source, snapshot.data, coerceFiniteNumber(snapshot.fetchedAtMs) ?? now);
	}
	const windows = collectProviderQuotaWindows(fallbackProvider, snapshot, now);
	return windows.length > 0
		? { fetchedAtMs: now, provider: fallbackProvider, rawShapeVersion: "provider-quota-v1", source: fallbackSource, windows }
		: null;
}

function normalizeQuotaWindow(window: unknown, index: number): QuotaWindow[] {
	if (!isRecord(window)) return [];
	const directResetAtMs = window.resetAtMs !== undefined || window.reset_at_ms !== undefined || window.resetsAtMs !== undefined || window.resets_at_ms !== undefined
		? coerceResetTimestampMs(window.resetAtMs ?? window.reset_at_ms ?? window.resetsAtMs ?? window.resets_at_ms, true)
		: coerceResetTimestampMs(window.resetAt ?? window.reset_at ?? window.resetsAt ?? window.resets_at, false);
	const resetAfterMs = coerceFiniteNumber(window.resetAfterMs ?? window.reset_after_ms);
	const resetAfterSeconds = coerceFiniteNumber(window.resetAfterSeconds ?? window.reset_after_seconds);
	const resetAtMs = directResetAtMs ?? (resetAfterMs !== null ? Date.now() + resetAfterMs : resetAfterSeconds !== null ? Date.now() + resetAfterSeconds * 1000 : null);
	const usedPercentRaw = coerceFiniteNumber(window.usedPercent ?? window.used_percent ?? window.utilization ?? window.percent ?? window.percentage);
	const usedPercent = usedPercentRaw === null ? null : (usedPercentRaw <= 1 ? usedPercentRaw * 100 : usedPercentRaw);
	const id = typeof window.id === "string" && window.id ? window.id : `window_${index}`;
	const title = typeof window.title === "string" && window.title ? window.title : id;
	const windowSeconds = coerceFiniteNumber(window.windowSeconds ?? window.window_seconds ?? window.limit_window_seconds) ?? undefined;
	const limitReached = readLimitReached(window);
	if (resetAtMs === null || !quotaWindowHasContext(id, title, usedPercent, limitReached, windowSeconds)) return [];
	return [{ id, limitReached: limitReached ?? undefined, resetAtMs, title, usedPercent, ...(windowSeconds ? { windowSeconds } : {}) }];
}

function quotaWindowHasContext(
	id: string,
	title: string,
	usedPercent: number | null,
	limitReached: boolean | null | undefined,
	windowSeconds: number | undefined,
): boolean {
	return usedPercent !== null
		|| limitReached !== null && limitReached !== undefined
		|| windowSeconds !== undefined;
}

function collectProviderQuotaWindows(provider: string, snapshot: unknown, now: number): QuotaWindow[] {
	const normalized = provider.toLowerCase();
	if (normalized.includes("claude") || normalized.includes("anthropic")) return collectClaudeQuotaWindows(snapshot, now);
	if (normalized.includes("codex") || normalized.includes("openai")) return collectCodexQuotaWindows(snapshot, now);
	return [];
}

function collectClaudeQuotaWindows(snapshot: unknown, now: number): QuotaWindow[] {
	const out: QuotaWindow[] = [];
	const seen = new Set<unknown>();
	const stack: Array<{ node: unknown; path: string }> = [{ node: snapshot, path: "" }];
	while (stack.length > 0) {
		const { node, path } = stack.pop()!;
		if (!isRecord(node) || seen.has(node)) continue;
		seen.add(node);
		if (isClaudeQuotaWindowPath(path)) {
			const resetAtMs = readResetTimestampFromRecord(node, now);
			const utilization = readUsageUtilization(node);
			if (resetAtMs !== null && utilization !== null) {
				out.push({
					id: path,
					limitReached: readLimitReached(node) ?? utilization >= 1,
					resetAtMs,
					title: path.replace(/[._-]+/g, " "),
					usedPercent: utilization * 100,
				});
			}
		}
		for (const [key, value] of Object.entries(node)) {
			if (value && typeof value === "object") stack.push({ node: value, path: path ? `${path}.${key}` : key });
		}
	}
	return out;
}

function isClaudeQuotaWindowPath(path: string): boolean {
	const normalized = path.split(".").pop()?.toLowerCase() ?? path.toLowerCase();
	return /^five_hour(?:_|$)|^seven_day(?:_|$)/.test(normalized);
}

function collectCodexQuotaWindows(snapshot: unknown, now: number): QuotaWindow[] {
	if (!isRecord(snapshot)) return [];
	const out: QuotaWindow[] = [];
	const rootRateLimit = snapshot.rate_limit;
	if (isRecord(rootRateLimit)) out.push(...codexRateLimitWindows("rate_limit", "Codex", rootRateLimit, now));
	const additional = snapshot.additional_rate_limits;
	if (Array.isArray(additional)) {
		for (const [index, item] of additional.entries()) {
			if (!isRecord(item)) continue;
			const nested = item.rate_limit;
			if (!isRecord(nested)) continue;
			const label = [item.limit_name, item.metered_feature]
				.filter((value): value is string => typeof value === "string" && value.trim().length > 0)
				.join(" ") || `additional ${index}`;
			out.push(...codexRateLimitWindows(`additional_rate_limits.${index}.rate_limit`, label, nested, now));
		}
	}
	return out;
}

function codexRateLimitWindows(prefix: string, titlePrefix: string, rateLimit: Record<string, unknown>, now: number): QuotaWindow[] {
	const out: QuotaWindow[] = [];
	const parentLimitReached = readLimitReached(rateLimit);
	for (const key of ["primary_window", "secondary_window"] as const) {
		const window = rateLimit[key];
		if (!isRecord(window)) continue;
		const resetAtMs = readResetTimestampFromRecord(window, now);
		if (resetAtMs === null) continue;
		const utilization = readUsageUtilization(window);
		const limitReached = readLimitReached(window) ?? parentLimitReached ?? undefined;
		out.push({
			id: `${prefix}.${key}`,
			limitReached,
			resetAtMs,
			title: `${titlePrefix} ${key.replace("_", " ")}`,
			usedPercent: utilization === null ? null : utilization * 100,
			...(firstFiniteRecordNumber(window, ["windowSeconds", "window_seconds", "limit_window_seconds"]) !== null
				? { windowSeconds: firstFiniteRecordNumber(window, ["windowSeconds", "window_seconds", "limit_window_seconds"])! }
				: {}),
		});
	}
	return out;
}

function collectQuotaWindows(snapshot: unknown, now: number): QuotaWindow[] {
	const out: QuotaWindow[] = [];
	const seen = new Set<unknown>();
	const stack: Array<{ node: unknown; path: string; title: string }> = [{ node: snapshot, path: "", title: "" }];
	while (stack.length > 0) {
		const { node, path, title } = stack.pop()!;
		if (!isRecord(node) || seen.has(node)) continue;
		seen.add(node);
		const resetAtMs = readResetTimestampFromRecord(node, now);
		if (resetAtMs !== null) {
			const utilization = readUsageUtilization(node);
			const windowSeconds = firstFiniteRecordNumber(node, ["windowSeconds", "window_seconds", "limit_window_seconds"]);
			out.push({
				id: path || `window_${out.length}`,
				limitReached: readLimitReached(node) ?? undefined,
				resetAtMs,
				title: title || path || `window ${out.length + 1}`,
				usedPercent: utilization === null ? null : utilization * 100,
				...(windowSeconds !== null ? { windowSeconds } : {}),
			});
		}
		for (const [key, value] of Object.entries(node)) {
			if (value && typeof value === "object") {
				const label = typeof node.limit_name === "string"
					? node.limit_name
					: typeof node.metered_feature === "string"
						? node.metered_feature
						: typeof node.name === "string"
							? node.name
							: title;
				stack.push({ node: value, path: path ? `${path}.${key}` : key, title: [label, key].filter(Boolean).join(" ") });
			}
		}
	}
	return out;
}

function chooseUsageResetCandidate(candidates: UsageResetCandidate[]): UsageResetCandidate | null {
	return [...candidates].sort((a, b) => {
		if (a.limitReached !== b.limitReached) return a.limitReached ? -1 : 1;
		const byUtilization = b.utilization - a.utilization;
		if (Math.abs(byUtilization) > 0.000001) return byUtilization;
		return b.resetAtMs - a.resetAtMs;
	})[0] ?? null;
}

function quotaCandidateSaturated(candidate: UsageResetCandidate): boolean {
	return candidate.limitReached || candidate.utilization >= 0.95;
}

function isSessionOrUsageCapEvent(event: unknown): boolean {
	if (hasNegatedSessionOrUsageLimit(event)) return false;
	const message = readAssistantMessage(event);
	const text = message ? extractAssistantErrorText(message).toLowerCase() : "";
	if (/\b(?:you(?:['’]?ve|\s+have)\s+hit\s+your\s+)?session\s+limit\b/.test(text)) return true;
	if (/\b(?:you(?:['’]?ve|\s+have)\s+hit\s+your\s+)?usage\s+limit\b/.test(text)) return true;
	if (/\bextra\s+usage\b|\busage\s+cap\b|\bsession\s+cap\b/.test(text)) return true;
	const typeHint = normalizeQuotaHint(extractRateLimitType(event));
	return typeHint === "session" || typeHint === "usage" || typeHint?.includes("session") === true || typeHint?.includes("usage") === true;
}

function hasNegatedSessionOrUsageLimit(event: unknown): boolean {
	const message = readAssistantMessage(event);
	const text = message ? extractAssistantErrorText(message).toLowerCase() : "";
	return /\bnot\s+(?:your\s+)?(?:session|usage)\s+limit\b/.test(text);
}

function quotaCandidateMatchesType(candidate: UsageResetCandidate, typeHint: string | null): boolean {
	const path = normalizeQuotaHint(`${candidate.path} ${candidate.title}`) ?? "";
	if (typeHint && path.includes(typeHint)) return true;
	if (typeHint === "fivehour" && (path.includes("5hour") || path.includes("5h"))) return true;
	if (typeHint === "sevenday" && (path.includes("7day") || path.includes("7d"))) return true;
	return false;
}

function quotaCandidateMatchesModel(candidate: UsageResetCandidate, modelHint: string | null): boolean {
	const path = normalizeQuotaHint(`${candidate.path} ${candidate.title}`) ?? "";
	if (modelHint && path.includes(modelHint)) return true;
	return false;
}

function normalizeQuotaHint(value: unknown): string | null {
	if (typeof value !== "string") return null;
	const normalized = value.toLowerCase().replace(/claude|anthropic|rate|limit|window|tokens/g, "").replace(/[^a-z0-9]+/g, "");
	if (!normalized) return null;
	if (normalized === "5h" || normalized === "5hour" || normalized === "5hours") return "fivehour";
	if (normalized === "7d" || normalized === "7day" || normalized === "7days") return "sevenday";
	return normalized;
}

function extractRateLimitType(event: unknown): string | null {
	const seen = new Set<unknown>();
	const stack: unknown[] = [event];
	while (stack.length > 0) {
		const node = stack.pop();
		if (!isRecord(node) || seen.has(node)) continue;
		seen.add(node);
		for (const key of ["rateLimitType", "rate_limit_type", "limitType", "limit_type", "window", "quotaWindow"]) {
			const value = node[key];
			if (typeof value === "string" && value.trim()) return value;
		}
		for (const value of Object.values(node)) {
			if (value && typeof value === "object") stack.push(value);
		}
	}
	return null;
}

function readResetTimestampFromRecord(record: Record<string, unknown>, now: number): number | null {
	for (const [key, value] of Object.entries(record)) {
		if (RESET_AT_MS_KEYS.has(key)) {
			const parsed = coerceResetTimestampMs(value, true);
			if (parsed !== null) return parsed;
		}
		if (RESET_AT_KEYS.has(key)) {
			const parsed = coerceResetTimestampMs(value, false);
			if (parsed !== null) return parsed;
		}
		if (key === "reset_after_ms" || key === "resetAfterMs") {
			const parsed = coerceFiniteNumber(value);
			if (parsed !== null && parsed > 0) return now + parsed;
		}
		if (key === "reset_after_seconds" || key === "resetAfterSeconds") {
			const parsed = coerceFiniteNumber(value);
			if (parsed !== null && parsed > 0) return now + parsed * 1000;
		}
	}
	return null;
}

function readUsageUtilization(record: Record<string, unknown>): number | null {
	for (const key of ["utilization", "usage", "used_fraction", "usedFraction"]) {
		const parsed = coerceFiniteNumber(record[key]);
		if (parsed !== null) return normalizeUtilization(parsed);
	}
	for (const key of ["percent", "percentage", "used_percent", "usedPercent", "percent_used", "percentUsed", "usage_percent", "usagePercent"]) {
		const parsed = coerceFiniteNumber(record[key]);
		if (parsed !== null) return normalizeUtilization(parsed > 1 ? parsed / 100 : parsed);
	}
	const used = firstFiniteRecordNumber(record, ["used", "used_tokens", "usedTokens", "consumed", "current"]);
	const limit = firstFiniteRecordNumber(record, ["limit", "max", "quota", "allowed", "total"]);
	if (used !== null && limit !== null && limit > 0) return Math.max(0, used / limit);
	const remaining = firstFiniteRecordNumber(record, ["remaining", "remaining_tokens", "remainingTokens"]);
	if (remaining !== null && limit !== null && limit > 0) return Math.max(0, 1 - remaining / limit);
	if (readLimitReached(record) === true) return 1;
	return null;
}

function readLimitReached(record: Record<string, unknown>): boolean | null {
	for (const key of ["exceeded", "is_exceeded", "isExceeded", "limit_reached", "limitReached", "isLimitReached", "saturated"] as const) {
		if (record[key] === true) return true;
		if (record[key] === false) return false;
	}
	return null;
}

function firstFiniteRecordNumber(record: Record<string, unknown>, keys: readonly string[]): number | null {
	for (const key of keys) {
		const parsed = coerceFiniteNumber(record[key]);
		if (parsed !== null) return parsed;
	}
	return null;
}

function coerceFiniteNumber(value: unknown): number | null {
	if (typeof value === "number" && Number.isFinite(value)) return value;
	if (typeof value === "string" && /^[0-9]+(?:\.[0-9]+)?$/.test(value.trim())) {
		const parsed = Number(value);
		return Number.isFinite(parsed) ? parsed : null;
	}
	return null;
}

function normalizeUtilization(value: number): number {
	if (!Number.isFinite(value)) return 0;
	return Math.max(0, value);
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
	const parsed = raw ? Number(raw) : Number.NaN;
	return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : fallback;
}

function firstNonEmptyEnv(env: NodeJS.ProcessEnv, keys: readonly string[]): string | null {
	for (const key of keys) {
		const value = env[key]?.trim();
		if (value) return value;
	}
	return null;
}

const quotaSnapshotCache = new Map<string, { expiresAt: number; promise: Promise<QuotaSourceResult> }>();

function cachedQuotaSnapshot(
	key: string,
	cacheMs: number,
	fetcher: () => Promise<QuotaSourceResult>,
): Promise<QuotaSourceResult> {
	const now = Date.now();
	const cached = quotaSnapshotCache.get(key);
	if (cached && cached.expiresAt > now) return cached.promise;
	const promise = fetcher().catch((error) => quotaSourceFailure("unknown", "usage-endpoint", "exception", undefined, undefined, error));
	quotaSnapshotCache.set(key, { expiresAt: now + Math.max(0, cacheMs), promise });
	return promise;
}

function hashString(value: string): string {
	let hash = 2166136261;
	for (let i = 0; i < value.length; i += 1) {
		hash ^= value.charCodeAt(i);
		hash = Math.imul(hash, 16777619);
	}
	return (hash >>> 0).toString(16);
}

function providerFromRateLimitEvent(event: unknown): string {
	const message = readAssistantMessage(event);
	const haystack = [message?.api, message?.provider, message?.model]
		.filter((value): value is string => typeof value === "string")
		.join(" ")
		.toLowerCase();
	if (haystack.includes("claude") || haystack.includes("anthropic")) return "claude";
	if (haystack.includes("codex")) return "codex";
	if (haystack.includes("openai") || haystack.includes("gpt")) return "openai";
	return "unknown";
}

function codexAuthTokenFromEnv(env: NodeJS.ProcessEnv): string | null {
	const envToken = firstNonEmptyEnv(env, ["VSTACK_CODEX_ACCESS_TOKEN", "CODEX_ACCESS_TOKEN", "OPENAI_CHATGPT_ACCESS_TOKEN"]);
	if (envToken) return envToken;
	for (const file of codexAuthFiles(env)) {
		try {
			if (!existsSync(file)) continue;
			const parsed = JSON.parse(readFileSync(file, "utf8"));
			const token = findAccessToken(parsed);
			if (token) return token;
		} catch {
			continue;
		}
	}
	return null;
}

function codexAuthFiles(env: NodeJS.ProcessEnv): string[] {
	const out: string[] = [];
	const codexHome = env.CODEX_HOME?.trim();
	if (codexHome) out.push(join(codexHome, "auth.json"));
	out.push(join(homedir(), ".codex", "auth.json"));
	return [...new Set(out)];
}

function findAccessToken(value: unknown): string | null {
	const seen = new Set<unknown>();
	const stack: unknown[] = [value];
	while (stack.length > 0) {
		const node = stack.pop();
		if (!isRecord(node) || seen.has(node)) continue;
		seen.add(node);
		for (const key of ["accessToken", "access_token", "bearerToken", "bearer_token"] as const) {
			const token = node[key];
			if (typeof token === "string" && token.length > 20) return token;
		}
		for (const child of Object.values(node)) {
			if (child && typeof child === "object") stack.push(child);
		}
	}
	return null;
}

async function fetchUsageEndpoint(
	fetchImpl: FetchLike,
	provider: string,
	endpoint: string,
	headers: Record<string, string>,
	timeoutMs: number,
): Promise<QuotaSourceResult> {
	const abortController = typeof AbortController !== "undefined" ? new AbortController() : null;
	const timer = abortController ? setTimeout(() => abortController.abort(), timeoutMs) : null;
	try {
		const response = await fetchImpl(endpoint, {
			headers: { Accept: "application/json", ...headers },
			method: "GET",
			...(abortController ? { signal: abortController.signal } : {}),
		});
		if (!response.ok) return quotaSourceFailure(provider, "usage-endpoint", `http-${response.status}`, response.status, endpoint);
		let body: unknown;
		try {
			body = await response.json();
		} catch (error) {
			return quotaSourceFailure(provider, "usage-endpoint", "invalid-json", undefined, endpoint, error);
		}
		const snapshot = normalizeQuotaSnapshot(provider, "usage-endpoint", body, Date.now(), endpoint);
		return snapshot.windows.length > 0 ? snapshot : quotaSourceFailure(provider, "usage-endpoint", "unrecognized-schema", undefined, endpoint);
	} catch (error) {
		return quotaSourceFailure(provider, "usage-endpoint", "fetch-failed", undefined, endpoint, error);
	} finally {
		if (timer) clearTimeout(timer);
	}
}

function quotaSourceFailure(
	provider: string,
	resetSource: "usage-endpoint" | "cli-rpc",
	reason: string,
	status?: number,
	endpoint?: string,
	_error?: unknown,
): QuotaSourceFailure {
	return {
		...(endpoint ? { endpoint } : {}),
		provider,
		reason: sanitizeQuotaFailureReason(reason),
		resetSource,
		source: "quota-source-error",
		...(status !== undefined ? { status } : {}),
	};
}

function sanitizeQuotaFailureReason(reason: string): string {
	return reason.replace(/bearer\s+[A-Za-z0-9._~+/-]+/gi, "bearer [redacted]").replace(/[A-Za-z0-9._~+/-]{24,}/g, "[redacted]");
}

export function quotaSourceFailureSummary(value: unknown): string | null {
	if (!isRecord(value) || value.source !== "quota-source-error") return null;
	const provider = typeof value.provider === "string" ? value.provider : "unknown";
	const resetSource = typeof value.resetSource === "string" ? value.resetSource : "unknown";
	const reason = typeof value.reason === "string" ? sanitizeQuotaFailureReason(value.reason) : "unknown";
	const status = typeof value.status === "number" ? ` status=${value.status}` : "";
	const endpoint = typeof value.endpoint === "string" ? ` endpoint=${value.endpoint}` : "";
	return `provider=${provider} source=${resetSource} reason=${reason}${status}${endpoint}`;
}

const RESET_AT_MS_KEYS = new Set(["resetAtMs", "reset_at_ms", "resetsAtMs", "resets_at_ms"]);
const RESET_AT_KEYS = new Set(["resetAt", "reset_at", "resetsAt", "resets_at"]);

function extractStructuredResetAtMs(event: unknown): number | null {
	const seen = new Set<unknown>();
	const stack: unknown[] = [event];
	while (stack.length > 0) {
		const node = stack.pop();
		if (!isRecord(node) || seen.has(node)) continue;
		seen.add(node);
		for (const [key, value] of Object.entries(node)) {
			if (RESET_AT_MS_KEYS.has(key)) {
				const parsed = coerceResetTimestampMs(value, true);
				if (parsed !== null) return parsed;
			} else if (RESET_AT_KEYS.has(key)) {
				const parsed = coerceResetTimestampMs(value, false);
				if (parsed !== null) return parsed;
			}
			if (value && typeof value === "object") stack.push(value);
		}
	}
	return null;
}

function coerceResetTimestampMs(value: unknown, knownMilliseconds: boolean): number | null {
	if (typeof value === "number" && Number.isFinite(value) && value > 0) {
		const milliseconds = knownMilliseconds || value >= 1_000_000_000_000 ? value : value * 1000;
		return Math.floor(milliseconds);
	}
	if (typeof value !== "string") return null;
	const trimmed = value.trim();
	if (!trimmed) return null;
	if (/^[0-9]+(?:\.[0-9]+)?$/.test(trimmed)) {
		const parsed = Number(trimmed);
		if (!Number.isFinite(parsed) || parsed <= 0) return null;
		const milliseconds = knownMilliseconds || parsed >= 1_000_000_000_000 ? parsed : parsed * 1000;
		return Math.floor(milliseconds);
	}
	const parsedDate = Date.parse(trimmed);
	return Number.isFinite(parsedDate) ? parsedDate : null;
}

function extractResetAtMsFromText(text: string, now: number): number | null {
	const resetMatch = text.match(/\bresets?\s+(?:at\s+)?([^\n]+)/i);
	if (!resetMatch) return null;
	const tail = (resetMatch[1] ?? "").trim();
	if (!tail) return null;

	const absolute = parseAbsoluteResetTail(tail);
	if (absolute !== null) return absolute;

	const clockMatch = tail.match(/^(?<clock>\d{1,2}(?::\d{2}){0,2}\s*(?:am|pm)?)(?:\s*\((?<timeZone>[^)]+)\))?/i);
	const clock = parseClockTime(clockMatch?.groups?.clock ?? "");
	if (!clock) return null;
	const timeZone = clockMatch?.groups?.timeZone?.trim();
	if (timeZone) return nextClockOccurrenceInTimeZone(clock, timeZone, now);
	return nextClockOccurrenceInLocalTime(clock, now);
}

function parseAbsoluteResetTail(tail: string): number | null {
	const withoutIanaZone = tail
		.replace(/[.;]\s*$/, "")
		.replace(/\s*\([A-Za-z_][A-Za-z0-9_+\-/.]+\)\s*$/, "")
		.trim();
	if (!/(\d{4}|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b|[+-]\d{2}:?\d{2}\b|\b(?:UTC|GMT|[A-Z]{2,4})\b)/i.test(withoutIanaZone)) {
		return null;
	}
	const parsed = Date.parse(withoutIanaZone);
	return Number.isFinite(parsed) ? parsed : null;
}

function parseClockTime(raw: string): { hour: number; minute: number; second: number } | null {
	const match = raw.trim().match(/^(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(am|pm)?$/i);
	if (!match) return null;
	let hour = Number(match[1]);
	const minute = match[2] === undefined ? 0 : Number(match[2]);
	const second = match[3] === undefined ? 0 : Number(match[3]);
	const meridiem = match[4]?.toLowerCase();
	if (!Number.isInteger(hour) || !Number.isInteger(minute) || !Number.isInteger(second)) return null;
	if (minute < 0 || minute > 59 || second < 0 || second > 59) return null;
	if (meridiem) {
		if (hour < 1 || hour > 12) return null;
		if (hour === 12) hour = 0;
		if (meridiem === "pm") hour += 12;
	} else if (hour < 0 || hour > 23) {
		return null;
	}
	return { hour, minute, second };
}

function nextClockOccurrenceInLocalTime(
	clock: { hour: number; minute: number; second: number },
	now: number,
): number {
	const candidate = new Date(now);
	candidate.setHours(clock.hour, clock.minute, clock.second, 0);
	if (candidate.getTime() > now) {
		const previous = new Date(candidate);
		previous.setDate(previous.getDate() - 1);
		if (now - previous.getTime() <= RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS) return previous.getTime();
		return candidate.getTime();
	}
	if (candidate.getTime() <= now) {
		const elapsedMs = now - candidate.getTime();
		if (elapsedMs <= RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS) return candidate.getTime();
		candidate.setDate(candidate.getDate() + 1);
	}
	return candidate.getTime();
}

function nextClockOccurrenceInTimeZone(
	clock: { hour: number; minute: number; second: number },
	timeZone: string,
	now: number,
): number | null {
	const nowParts = zonedDateParts(now, timeZone);
	if (!nowParts) return null;
	const previousDate = new Date(Date.UTC(nowParts.year, nowParts.month - 1, nowParts.day - 1));
	const previousCandidate = zonedLocalTimeToUtcMs(
		previousDate.getUTCFullYear(),
		previousDate.getUTCMonth() + 1,
		previousDate.getUTCDate(),
		clock.hour,
		clock.minute,
		clock.second,
		timeZone,
	);
	if (previousCandidate !== null && previousCandidate <= now && now - previousCandidate <= RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS) {
		return previousCandidate;
	}
	for (let dayOffset = 0; dayOffset < 3; dayOffset += 1) {
		const date = new Date(Date.UTC(nowParts.year, nowParts.month - 1, nowParts.day + dayOffset));
		const candidate = zonedLocalTimeToUtcMs(
			date.getUTCFullYear(),
			date.getUTCMonth() + 1,
			date.getUTCDate(),
			clock.hour,
			clock.minute,
			clock.second,
			timeZone,
		);
		if (candidate === null) continue;
		if (candidate > now) return candidate;
		if (now - candidate <= RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS) return candidate;
	}
	return null;
}

function zonedDateParts(utcMs: number, timeZone: string): { year: number; month: number; day: number } | null {
	const parts = formatZonedParts(utcMs, timeZone);
	if (!parts) return null;
	return { day: parts.day, month: parts.month, year: parts.year };
}

function zonedLocalTimeToUtcMs(
	year: number,
	month: number,
	day: number,
	hour: number,
	minute: number,
	second: number,
	timeZone: string,
): number | null {
	const localAsUtc = Date.UTC(year, month - 1, day, hour, minute, second);
	const firstOffset = timeZoneOffsetMs(timeZone, localAsUtc);
	if (firstOffset === null) return null;
	let candidate = localAsUtc - firstOffset;
	const secondOffset = timeZoneOffsetMs(timeZone, candidate);
	if (secondOffset === null) return null;
	if (secondOffset !== firstOffset) candidate = localAsUtc - secondOffset;
	return candidate;
}

function timeZoneOffsetMs(timeZone: string, utcMs: number): number | null {
	const parts = formatZonedParts(utcMs, timeZone);
	if (!parts) return null;
	const zonedAsUtc = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
	return zonedAsUtc - utcMs;
}

function formatZonedParts(
	utcMs: number,
	timeZone: string,
): { year: number; month: number; day: number; hour: number; minute: number; second: number } | null {
	try {
		const formatter = new Intl.DateTimeFormat("en-US", {
			day: "2-digit",
			hour: "2-digit",
			hourCycle: "h23",
			minute: "2-digit",
			month: "2-digit",
			second: "2-digit",
			timeZone,
			year: "numeric",
		});
		const values = Object.fromEntries(
			formatter
				.formatToParts(new Date(utcMs))
				.filter((part) => part.type !== "literal")
				.map((part) => [part.type, Number(part.value)]),
		) as Record<string, number>;
		const { day, hour, minute, month, second, year } = values;
		if (![day, hour, minute, month, second, year].every((value) => Number.isFinite(value))) return null;
		return { day, hour, minute, month, second, year };
	} catch {
		return null;
	}
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

// CLI entry: `printf '%s' "$event_json" | bun rate-limit-watchdog.ts decide --pane <id> --attempt <n> [--now <ms>]`
// Used by the bash pi subscriber (Layer B) so it can route rate-limit
// events through the same decision module without re-implementing the
// ladder math. Outputs the decision as JSON on stdout, exits 0.
// `--event` remains accepted for manual debugging; production callers
// should omit it so event JSON is read from stdin instead of process argv.
if (import.meta.main) {
	const args = process.argv.slice(2);
	const action = args.shift();
	if (action !== "decide") {
		process.stderr.write("Usage: rate-limit-watchdog.ts decide --pane <id> --attempt <n> [--now <ms>] < event.json\n");
		process.exit(2);
	}
	let eventJson = "";
	let paneId = "";
	let attempt = 0;
	let now = Date.now();
	for (let i = 0; i < args.length; i += 1) {
		const flag = args[i];
		switch (flag) {
			case "--event": eventJson = args[++i] ?? ""; break;
			case "--pane": paneId = args[++i] ?? ""; break;
			case "--attempt": attempt = Number(args[++i] ?? "0") || 0; break;
			case "--now": now = Number(args[++i] ?? `${Date.now()}`) || Date.now(); break;
			default:
				process.stderr.write(`Unknown flag: ${flag}\n`);
				process.exit(2);
		}
	}
	if (!eventJson) {
		eventJson = await Bun.stdin.text();
	}
	let event: unknown;
	try {
		event = JSON.parse(eventJson);
	} catch (error) {
		process.stderr.write(`invalid --event JSON: ${(error as Error).message}\n`);
		process.exit(2);
	}
	const usageSnapshot = classifyRateLimitEvent(event).isRateLimitEvent
		? await fetchProviderQuotaSnapshotFromEnv(event).catch(() => null)
		: null;
	const quotaFailureSummary = quotaSourceFailureSummary(usageSnapshot);
	if (quotaFailureSummary) {
		process.stderr.write(`quota-source-error ${quotaFailureSummary}\n`);
	}
	const decision = decideRateLimitRetry({ attempt, event, lastRetryAt: null, now, paneId, usageSnapshot });
	process.stdout.write(`${JSON.stringify(quotaFailureSummary ? { ...decision, quotaSourceFailureSummary: quotaFailureSummary } : decision)}\n`);
	process.exit(0);
}
