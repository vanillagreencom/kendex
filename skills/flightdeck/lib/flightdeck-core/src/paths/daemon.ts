// Port of scripts/lib/daemon-paths.sh — shared resolvers for daemon
// state files. Sourced by daemon, master-busy writer, freshness cache.

import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { inprocFlockAvailable, withInprocFlock } from "../shared/inproc-flock.ts";

// Memoize per-process: the resolve dir + mkdir + chmod ran on every
// path helper call (10× per pane tick), each spawning `id` when no
// XDG_RUNTIME_DIR was set. Cache by the inputs that can vary, so a
// test that mutates FD_STATE_DIR mid-process still picks up the new
// value.
let stateDirCacheKey = "";
let stateDirCacheVal = "";
export function fdResolveStateDir(): string {
	// Include process.cwd() in the cache key so a relative FD_STATE_DIR
	// is correctly recomputed when a long-lived process chdirs (rare,
	// but legal). Absolute paths skip cwd in the key since they're cwd-
	// independent.
	const rawDir = process.env.FD_STATE_DIR?.trim() ?? "";
	const cwdPart = rawDir && !isAbsolute(rawDir) ? `|${process.cwd()}` : "";
	const envKey = `${rawDir}|${process.env.XDG_RUNTIME_DIR ?? ""}${cwdPart}`;
	if (envKey === stateDirCacheKey && stateDirCacheVal) return stateDirCacheVal;
	let dir: string;
	if (rawDir) {
		dir = isAbsolute(rawDir) ? rawDir : resolve(process.cwd(), rawDir);
	} else if (process.env.XDG_RUNTIME_DIR && process.env.XDG_RUNTIME_DIR.trim()) {
		dir = join(process.env.XDG_RUNTIME_DIR.trim(), "flightdeck");
	} else {
		const r = spawnSync("id", ["-u"], { encoding: "utf8" });
		const uid = (r.stdout ?? "").trim() || String(process.getuid?.() ?? 0);
		dir = `/tmp/flightdeck-${uid}`;
	}
	try { mkdirSync(dir, { recursive: true }); } catch { /* ignore */ }
	try { chmodSync(dir, 0o700); } catch { /* ignore — fs may not support */ }
	stateDirCacheKey = envKey;
	stateDirCacheVal = dir;
	return dir;
}

export const fdBusyFile = (stateDir: string, sessionKey: string) => join(stateDir, `fd-master-${sessionKey}.busy`);
export const fdPidFile = (stateDir: string, sessionKey: string) => join(stateDir, `fd-daemon-${sessionKey}.pid`);
export const fdPidLock = (stateDir: string, sessionKey: string) => join(stateDir, `fd-daemon-${sessionKey}.lock`);
export const fdLogFile = (stateDir: string, sessionKey: string) => join(stateDir, `fd-daemon-${sessionKey}.log`);
export const fdSessionLock = (stateDir: string, sessionKey: string) => join(stateDir, `fd-daemon-${sessionKey}.session-lock`);
export const fdWakePending = (stateDir: string, sessionKey: string) => join(stateDir, `fd-wake-pending-${sessionKey}`);
export const fdEventsFile = (stateDir: string, sessionKey: string) => join(stateDir, `fd-daemon-events-${sessionKey}.jsonl`);
export const fdHeartbeatFile = (stateDir: string, sessionKey: string) => join(stateDir, `fd-daemon-${sessionKey}.heartbeat`);
export const fdWakeEventsLog = (stateDir: string, sessionKey: string) => join(stateDir, `fd-wake-events-${sessionKey}.log`);
// vstack#216: per-session snapshot of per-pane subscriber binding state,
// refreshed by the run loop each heartbeat. `flightdeck-daemon health`
// reads it to surface which panes are bound vs. silently unbound — the
// only way the operator can detect a bind-skip without tailing the log.
export const fdSubscriberStatusFile = (stateDir: string, sessionKey: string) => join(stateDir, `fd-daemon-${sessionKey}.subscribers.json`);
// vstack#213: daemon staleness metadata. Written at start, refreshed on
// every reconcile pass that mutates the subscriber set. Consulted by
// `flightdeck-session ensure_daemon_for_session` and by
// `flightdeck-daemon health` so callers can decide stale-vs-fresh
// without re-deriving from argv.
export const fdMetaFile = (stateDir: string, sessionKey: string) => join(stateDir, `fd-daemon-${sessionKey}.meta.json`);

export const fdAdapterFreshnessCacheFile = () => join(fdResolveStateDir(), "fd-adapter-freshness-cache.json");
export const fdAdapterFreshnessCacheLock = () => join(fdResolveStateDir(), "fd-adapter-freshness-cache.lock");

interface FreshnessEntry { ok: boolean; ts: number }

export function fdAdapterFreshnessCacheGet(key: string, ttlSec: number = Number.parseInt(process.env.FD_ADAPTER_FRESHNESS_TTL ?? "5", 10)): boolean | null {
	if (!Number.isFinite(ttlSec) || ttlSec <= 0) return null;
	const file = fdAdapterFreshnessCacheFile();
	if (!existsSync(file)) return null;
	let obj: Record<string, FreshnessEntry>;
	try { obj = JSON.parse(readFileSync(file, "utf8")); } catch { return null; }
	const row = obj[key];
	if (!row || typeof row.ts !== "number") return null;
	const age = Math.floor(Date.now() / 1000) - row.ts;
	if (age < 0 || age > ttlSec) return null;
	return row.ok === true;
}

function rotateCorruptCache(file: string): void {
	try {
		const stamp = Math.floor(Date.now() / 1000);
		renameSync(file, `${file}.corrupt.${stamp}`);
	} catch { /* missing OK */ }
}

function freshnessRMW(file: string, key: string, ok: boolean, ts: number): void {
	let obj: Record<string, FreshnessEntry> = {};
	if (existsSync(file)) {
		try {
			const raw = readFileSync(file, "utf8");
			const parsed = JSON.parse(raw);
			if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
				obj = parsed as Record<string, FreshnessEntry>;
			} else {
				rotateCorruptCache(file);
			}
		} catch {
			rotateCorruptCache(file);
		}
	}
	obj[key] = { ok, ts };
	const tmp = `${file}.tmp.${process.pid}`;
	try {
		writeFileSync(tmp, JSON.stringify(obj));
		renameSync(tmp, file);
	} catch { /* best-effort cache; failure is non-fatal */ }
}

export function fdAdapterFreshnessCacheSet(key: string, ok: boolean): void {
	const ttl = Number.parseInt(process.env.FD_ADAPTER_FRESHNESS_TTL ?? "5", 10);
	if (!Number.isFinite(ttl) || ttl <= 0) return;
	const file = fdAdapterFreshnessCacheFile();
	const lock = fdAdapterFreshnessCacheLock();
	const now = Math.floor(Date.now() / 1000);
	// Native R-M-W under flock(2) via bun:ffi. The previous bash path
	// cost 4 forks (flock + bash + jq -e + jq update) per cache miss;
	// the native path is zero forks. Falls back to the bash pattern
	// when bun:ffi can't dlopen libc (musl, exotic platforms).
	if (inprocFlockAvailable()) {
		try {
			withInprocFlock(lock, () => freshnessRMW(file, key, ok, now));
			return;
		} catch { /* fall through to subprocess */ }
	}
	const script = `
		set -e
		file="$1"; key="$2"; ok="$3"; ts="$4"
		tmp="$file.tmp.$$"
		jq --arg k "$key" --argjson ok "$ok" --argjson ts "$ts" \\
			'if type == "object" then . else {} end | .[$k] = {ok:$ok, ts:$ts}' \\
			"$file" 2>/dev/null > "$tmp" \\
			|| jq -n --arg k "$key" --argjson ok "$ok" --argjson ts "$ts" \\
				'{($k): {ok:$ok, ts:$ts}}' > "$tmp"
		mv "$tmp" "$file"
	`;
	spawnSync("flock", ["-x", lock, "bash", "-c", script, "_", file, key, String(ok), String(now)], { stdio: "ignore" });
}

// Derive session key from a tmux session_id ("$143" → "s143").
export function fdSessionKeyFromId(id: string): string {
	if (!id) return "";
	return `s${id.replace(/^\$/, "")}`;
}
