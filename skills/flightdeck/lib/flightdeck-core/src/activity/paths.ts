import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

const STATE_PREFIX = "flightdeck-state-";
const ACTIVITY_PREFIX = "flightdeck-activity-";
const RESOLVE_CACHE_TTL_MS = 5000;
const RESOLVE_CACHE_MAX_ENTRIES = 64;

interface ActivityPathContext {
	stateFile: string;
	sessionId?: string;
	tmuxSession?: string;
	stateDir?: string;
}

const resolveCache = new Map<string, { expiresAt: number; path: string | null }>();

// vstack#227: stateBase is the active run's run_dir in the canonical
// layout (`runs/<run-id>/`). Activity lives alongside state as
// `activity.jsonl`. Legacy callers passing a project-tmp directory
// still get the prefixed name.
export function activityPathForSession(session: string, stateBase: string): string {
	if (isRunDirectory(stateBase)) return join(stateBase, "activity.jsonl");
	return join(stateBase, `${ACTIVITY_PREFIX}${session}.jsonl`);
}

// vstack#227: state.json next to activity.jsonl in the run dir is the
// canonical form. The flightdeck-state-<S>.json layout is still
// handled for the migration shim and for tests that exercise the
// legacy path directly.
export function activityPathFromStatePath(stateFile: string): string {
	const base = basename(stateFile);
	if (base === "state.json") return join(dirname(stateFile), "activity.jsonl");
	if (base.startsWith(STATE_PREFIX) && base.endsWith(".json")) {
		const session = base.slice(STATE_PREFIX.length, -".json".length);
		return join(dirname(stateFile), `${ACTIVITY_PREFIX}${session}.jsonl`);
	}
	return `${stateFile}.activity.jsonl`;
}

export function resolveActivityPath(ctx: ActivityPathContext): string | null {
	const key = [ctx.stateFile, ctx.stateDir ?? "", ctx.tmuxSession ?? "", ctx.sessionId ?? ""].join("\0");
	const now = Date.now();
	const cached = resolveCache.get(key);
	if (cached && cached.expiresAt > now) return cached.path;
	let path: string | null = null;
	let stateSession = "";
	// vstack#227: in the unified layout, the activity file always sits
	// next to the state file. Prefer the on-disk relationship over the
	// in-state `activity_path` field (which can be stale across run
	// rotations). Only fall back to the JSON field if the sibling file
	// doesn't exist.
	if (ctx.stateFile) {
		const sibling = activityPathFromStatePath(ctx.stateFile);
		if (existsSync(sibling)) {
			path = sibling;
		} else if (existsSync(ctx.stateFile)) {
			try {
				const parsed = JSON.parse(readFileSync(ctx.stateFile, "utf8")) as unknown;
				if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
					const raw = parsed as Record<string, unknown>;
					if (typeof raw.activity_path === "string" && raw.activity_path.trim()) path = raw.activity_path;
					if (typeof raw.session_id === "string" && raw.session_id.trim()) stateSession = raw.session_id;
				}
				// If the sibling doesn't exist yet but a state file does, prefer
				// the sibling path so the first append creates it in the right
				// place. activity_path is only used as a final-fallback hint.
				if (!path) path = sibling;
			} catch {
				path = sibling;
			}
		}
	}
	if (!path && ctx.stateDir) {
		const session = ctx.tmuxSession || ctx.sessionId || stateSession;
		if (session) path = activityPathForSession(session, ctx.stateDir);
	}
	rememberResolvedActivityPath(key, { expiresAt: now + RESOLVE_CACHE_TTL_MS, path }, now);
	return path;
}

// Heuristic: a run dir's basename starts with `run-` or `imported-`,
// while a project's tmp dir does not. Used to decide between
// `state.json`/`activity.jsonl` (run-dir layout) and the legacy
// `flightdeck-state-<S>.json`/`flightdeck-activity-<S>.jsonl` layout.
function isRunDirectory(stateBase: string): boolean {
	const base = basename(stateBase);
	return base.startsWith("run-") || base.startsWith("imported-");
}

function rememberResolvedActivityPath(key: string, value: { expiresAt: number; path: string | null }, now = Date.now()): void {
	for (const [cachedKey, cached] of resolveCache) {
		if (cached.expiresAt <= now) resolveCache.delete(cachedKey);
	}
	if (resolveCache.has(key)) resolveCache.delete(key);
	resolveCache.set(key, value);
	while (resolveCache.size > RESOLVE_CACHE_MAX_ENTRIES) {
		const oldest = resolveCache.keys().next().value as string | undefined;
		if (!oldest) break;
		resolveCache.delete(oldest);
	}
}

export function activityArchivePathFromStatePath(stateFile: string, terminatedAt: string): string {
	const activity = activityPathFromStatePath(stateFile);
	return activity.replace(/\.jsonl$/, `-${safeArchiveTimestamp(terminatedAt)}.jsonl.archive`);
}

export function safeArchiveTimestamp(ts: string): string {
	return ts.replace(/:/g, "");
}
