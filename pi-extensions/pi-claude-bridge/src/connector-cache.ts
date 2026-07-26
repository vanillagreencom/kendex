// Cross-PROCESS cache of the connector inventory (vstack#870).
//
// #868 primes the inventory at provider registration, but the fetch takes ~1.5s
// while the first query is built at ~0.5-0.8s, so turn 1 of a cold sidecar goes
// out with no declarations and gets exactly the #832 bug it was meant to fix.
//
// An in-process cache cannot help the consumer that needs it most. drovr builds
// a sidecar lazily on the first bridge round and, since their sidecars are
// per-SESSION, that is a fresh process for every new chat — so their exposure is
// once per chat, indefinitely, and every one of those is a cold process. The
// cache therefore has to survive process boundaries.
//
// Keyed by credential scope, because that is what selects the account: the org
// UUID in the inventory request is ignored and only the credential decides whose
// connectors come back. Two accounts on one host must not share a cache entry.
//
// Everything here is best-effort. A missing, unreadable, corrupt, stale, or
// wrong-version cache returns undefined and the caller falls back to today's
// behaviour — the same fail-open contract as the inventory call itself.
//
// The ON-DISK FORMAT HAS AN EXTERNAL READER (vstack#892). drovr quarantines this
// bundle to its sidecar process, so rather than calling `listAccountConnectors`
// in-process it re-implements the reader half — path
// `<piUserDir()>/connector-cache/<sha256(CLAUDE_CONFIG_DIR).hex[0..16]>.json`,
// payload `{version, scope, savedAt, connectors}`, 7-day max age — as the
// "is this connector installed" half of its write gate.
//
// That coupling fails OPEN on drift by design, so a format change degrades them
// from two gates to one rather than breaking them. It is still worth making the
// change knowingly: bump CACHE_VERSION so their staleness check rejects rather
// than misreads, and say so in the changelog. `unit-connector-cache.mjs` pins
// the path shape and payload keys.
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { piUserDir } from "./config.js";
import type { ConnectorEntry } from "./connector-inventory.js";

const CACHE_VERSION = 1;
/** Long enough to be useful across a machine's lifetime, short enough that a
 *  removed connector stops being declared without needing a manual purge. A
 *  stale entry is not dangerous — a connector that no longer resolves simply
 *  fails to connect, which is the fail-open path — so this is hygiene, not a
 *  correctness boundary. */
const MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

export function connectorCacheScopeKey(env: NodeJS.ProcessEnv = process.env): string {
	return env.CLAUDE_CONFIG_DIR?.trim() || "<default>";
}

/**
 * Our own state directory, not the Claude config dir. The credential directory
 * belongs to the CLI; the scope is encoded in the filename instead so we never
 * write into someone else's tree. Hashed rather than escaped because a config
 * dir is an arbitrary absolute path.
 */
export function connectorCachePath(scopeKey: string = connectorCacheScopeKey()): string {
	const digest = createHash("sha256").update(scopeKey).digest("hex").slice(0, 16);
	return join(piUserDir(), "connector-cache", `${digest}.json`);
}

/**
 * Synchronous by design. The query path has no await boundary to hang a read on
 * — `streamClaudeAgentSdk` returns its stream and claims the SDK query handle in
 * the same tick — which is the whole reason the in-memory prime loses the race.
 * A single small `readFileSync` is what makes turn 1 reachable at all.
 */
export function readCachedConnectors(
	scopeKey: string = connectorCacheScopeKey(),
	now: number = Date.now(),
): ConnectorEntry[] | undefined {
	let raw: string;
	try {
		raw = readFileSync(connectorCachePath(scopeKey), "utf8");
	} catch {
		return undefined;
	}
	let parsed: any;
	try {
		parsed = JSON.parse(raw);
	} catch {
		return undefined;
	}
	if (parsed?.version !== CACHE_VERSION) return undefined;
	// Scope is stored as well as hashed into the path: a hash collision or a
	// hand-copied file would otherwise hand one account another's connectors,
	// which is the exact failure the token-scoping note in connector-inventory.ts
	// warns about.
	if (parsed?.scope !== scopeKey) return undefined;
	const savedAt = typeof parsed?.savedAt === "number" ? parsed.savedAt : 0;
	if (!savedAt || now - savedAt > MAX_AGE_MS || savedAt > now) return undefined;
	if (!Array.isArray(parsed?.connectors)) return undefined;
	const connectors = parsed.connectors.filter(
		(entry: any) => entry && typeof entry.name === "string" && entry.name.trim(),
	);
	return connectors.length > 0 ? (connectors as ConnectorEntry[]) : undefined;
}

/** Best-effort write; a failure here must never affect the turn. */
export function writeCachedConnectors(
	connectors: ConnectorEntry[],
	scopeKey: string = connectorCacheScopeKey(),
	now: number = Date.now(),
): boolean {
	if (!Array.isArray(connectors) || connectors.length === 0) return false;
	const path = connectorCachePath(scopeKey);
	try {
		mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
		writeFileSync(
			path,
			JSON.stringify({ version: CACHE_VERSION, scope: scopeKey, savedAt: now, connectors }),
			{ mode: 0o600 },
		);
		return true;
	} catch {
		return false;
	}
}
