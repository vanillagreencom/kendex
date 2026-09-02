import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import type { QuotaSnapshot, QuotaSourceFailure, QuotaSourceResult } from "./rate-limit-decision.js";
import { normalizeQuotaSnapshot, quotaSourceFailureSummary } from "./rate-limit-quota-normalize.js";

/**
 * Provider quota lookup for the subagent rate-limit watchdog.
 *
 * The one rate-limit module off the extension startup path: the watchdog
 * reaches it through a dynamic import after a rate-limit event. That is what
 * lets it take node:* imports at all. Pi 0.80.3's binary extension loader
 * resolves transpiled TS modules through data: URLs, and a large module with
 * node:* imports can trip Bun/JITI NameTooLong at startup, so everything in
 * the transitive static closure of index.ts -> rate-limit-watchdog.ts stays
 * free of them. Each module in that closure says so in its own header.
 */

type FetchLike = (input: string, init?: Record<string, unknown>) => Promise<{
	ok: boolean;
	status: number;
	json: () => Promise<unknown>;
}>;

export function rateLimitUsageSnapshotFromEnv(env: NodeJS.ProcessEnv = process.env): QuotaSourceResult {
	const raw = env.KENDEX_RATE_LIMIT_USAGE_JSON?.trim();
	if (!raw) return null;
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch (error) {
		return quotaSourceFailure("unknown", "usage-endpoint", "invalid-env-json", undefined, "KENDEX_RATE_LIMIT_USAGE_JSON", error);
	}
	if (quotaSourceFailureSummary(parsed)) return parsed as QuotaSourceFailure;
	const snapshot = normalizeQuotaSnapshot("unknown", "usage-endpoint", parsed, Date.now(), "env-json");
	return snapshot.windows.length > 0
		? snapshot
		: quotaSourceFailure("unknown", "usage-endpoint", "unrecognized-env-schema", undefined, "KENDEX_RATE_LIMIT_USAGE_JSON");
}

export async function fetchClaudeUsageSnapshotFromEnv(
	env: NodeJS.ProcessEnv = process.env,
	fetchImpl: FetchLike | undefined = (globalThis as unknown as { fetch?: FetchLike }).fetch,
): Promise<QuotaSourceResult> {
	const inline = rateLimitUsageSnapshotFromEnv(env);
	if (inline) return inline;
	if (!fetchImpl) return null;
	const timeoutMs = parsePositiveInt(env.KENDEX_RATE_LIMIT_USAGE_FETCH_TIMEOUT_MS, 3_000);
	const cacheMs = parsePositiveInt(env.KENDEX_RATE_LIMIT_USAGE_CACHE_MS, 60_000);
	const oauthToken = firstNonEmptyEnv(env, [
		"KENDEX_ANTHROPIC_OAUTH_ACCESS_TOKEN",
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
	const orgId = firstNonEmptyEnv(env, ["KENDEX_CLAUDE_ORG_ID", "CLAUDE_AI_ORG_ID", "CLAUDE_ORG_ID"]);
	const cookie = firstNonEmptyEnv(env, ["KENDEX_CLAUDE_AI_COOKIE", "CLAUDE_AI_COOKIE", "CLAUDE_COOKIE"]);
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
	const timeoutMs = parsePositiveInt(env.KENDEX_RATE_LIMIT_USAGE_FETCH_TIMEOUT_MS, 3_000);
	const cacheMs = parsePositiveInt(env.KENDEX_RATE_LIMIT_USAGE_CACHE_MS, 60_000);
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

function codexAuthTokenFromEnv(env: NodeJS.ProcessEnv): string | null {
	const envToken = firstNonEmptyEnv(env, ["KENDEX_CODEX_ACCESS_TOKEN", "CODEX_ACCESS_TOKEN", "OPENAI_CHATGPT_ACCESS_TOKEN"]);
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

function isRecord(value: unknown): value is Record<string, unknown> {
	return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
