/**
 * Eager on the extension startup path: index.ts imports rate-limit-watchdog.ts
 * statically, so every module in that transitive static closure loads at
 * startup and none of them may take a node:* import. Pi 0.80.3's binary TS
 * loader resolves transpiled TS through data: URLs and a large module with
 * node:* imports trips Bun/JITI NameTooLong there. The provider fetch that
 * needs node:fs is rate-limit-quota.ts, dynamically imported. Not enforced.
 */

import type { QuotaSnapshot, QuotaWindow } from "./rate-limit-decision.js";
import {
	RESET_AT_KEYS,
	RESET_AT_MS_KEYS,
	coerceResetTimestampMs,
	extractAssistantErrorText,
	isRecord,
	readAssistantMessage,
} from "./rate-limit-reset.js";

type UsageResetCandidate = {
	limitReached: boolean;
	path: string;
	resetAtMs: number;
	title: string;
	utilization: number;
};

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
	// A reset timestamp is the whole context a window needs. Also demanding
	// usedPercent or a limit flag dropped the reset-only windows
	// collectCodexQuotaWindows emits, losing the usage-endpoint reset.
	if (resetAtMs === null) return [];
	return [{ id, limitReached: limitReached ?? undefined, resetAtMs, title, usedPercent, ...(windowSeconds ? { windowSeconds } : {}) }];
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

