// Master-state CRUD on per-tmux-session JSON files.
// Mirrors scripts/flightdeck-state semantics: jq for filter execution,
// flock(1) for atomic write coordination, temp+rename for crash safety.

import { spawnSync } from "node:child_process";
import {
	existsSync,
	mkdirSync,
	readFileSync,
	readdirSync,
	statSync,
	unlinkSync,
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { activityArchivePathFromStatePath, activityPathFromStatePath } from "../activity/paths.ts";
import { resolveProjectRoot, loadDotEnvIntoProcess } from "../shared/project.ts";
import { lockedArchiveStateAndActivity, lockedJqUpdate } from "./locking.ts";

export interface FlightdeckOwner {
	harness: string;
	pane_id: string | null;
	pane_target: string | null;
	cwd: string;
	pid: number;
	pi_session_id: string | null;
	pi_bridge_socket: string | null;
	discovery_error: string | null;
}

export function resolveStateBase(): string {
	const root = resolveProjectRoot();
	loadDotEnvIntoProcess(root);
	const dir = process.env.FLIGHTDECK_STATE_DIR && process.env.FLIGHTDECK_STATE_DIR.trim()
		? process.env.FLIGHTDECK_STATE_DIR.trim()
		: "tmp";
	const base = resolve(root, dir);
	mkdirSync(base, { recursive: true });
	return base;
}

export function resolveSession(explicit?: string): string {
	if (explicit && explicit.trim()) return explicit.trim();
	if (!process.env.TMUX) {
		process.stderr.write("Error: no $TMUX session and no --session given\n");
		process.exit(2);
	}
	const r = spawnSync("tmux", ["display-message", "-p", "#S"], { encoding: "utf8" });
	const name = (r.stdout ?? "").trim();
	if (!name) {
		process.stderr.write("Error: tmux display-message returned empty session name\n");
		process.exit(2);
	}
	return name;
}

export function statePath(session: string): string {
	return join(resolveStateBase(), `flightdeck-state-${session}.json`);
}

// Bash accepts `terminated` as shorthand for `.terminated`; mirror it.
export function normalizePath(p: string): string {
	if (p.startsWith(".") || p.startsWith("(.")) return p;
	return `.${p}`;
}

function runJqRaw(filter: string, file: string): string {
	const r = spawnSync("jq", ["-r", filter, file], { encoding: "utf8" });
	if (r.status !== 0) {
		process.stderr.write(r.stderr ?? "");
		process.exit(r.status ?? 1);
	}
	return r.stdout ?? "";
}

// flock(1)-held read-modify-write of the state JSON. The lock is held
// for the whole jq + rename window, matching the bash update_state
// contract. Filter passes through bash positional args (no shell
// interpolation).
export function updateState(file: string, filter: string): void {
	const lock = `${file}.lock`;
	const r = lockedJqUpdate(lock, file, filter);
	if (r.status !== 0) {
		process.stderr.write(r.stderr || "");
		process.exit(r.status ?? 1);
	}
}

function nonEmptyEnv(name: string): string {
	const value = process.env[name];
	return typeof value === "string" && value.trim() ? value.trim() : "";
}

function tmuxDisplay(format: string): string {
	if (!process.env.TMUX) return "";
	const r = spawnSync("tmux", ["display-message", "-p", format], { encoding: "utf8" });
	return r.status === 0 ? (r.stdout ?? "").trim() : "";
}

function ownerPid(): number {
	const raw = nonEmptyEnv("FLIGHTDECK_OWNER_PID");
	if (/^[1-9][0-9]*$/.test(raw)) return Number.parseInt(raw, 10);
	if (Number.isFinite(process.ppid) && process.ppid > 0) return process.ppid;
	process.stderr.write("Warning: FLIGHTDECK_OWNER_PID unset and parent pid unavailable; using helper pid as owner.pid.\n");
	return process.pid;
}

function piBridgeMetadata(pid: number): { sessionId: string; socketPath: string; discoveryError: string } {
	const envSession = nonEmptyEnv("FLIGHTDECK_OWNER_PI_SESSION_ID") || nonEmptyEnv("PI_SESSION_ID");
	const envSocket = nonEmptyEnv("FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET") || nonEmptyEnv("PI_BRIDGE_SOCKET_PATH");
	if (envSession && envSocket) return { discoveryError: "", sessionId: envSession, socketPath: envSocket };
	let foundSession = "";
	let foundSocket = "";
	let discoveryError = "";
	const timeoutMs = Number.parseInt(nonEmptyEnv("FLIGHTDECK_PI_BRIDGE_DISCOVERY_TIMEOUT_MS") || "1000", 10);
	const timeout = Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : 1000;
	const r = spawnSync("pi-bridge", ["list", "--json", "--pid", String(pid)], { encoding: "utf8", timeout });
	if (r.error) {
		const code = (r.error as NodeJS.ErrnoException).code;
		discoveryError = code === "ENOENT" ? "pi_bridge_not_found" : code === "ETIMEDOUT" ? "pi_bridge_timeout" : `pi_bridge_error_${code ?? "unknown"}`;
	} else if (r.status !== 0) {
		discoveryError = `pi_bridge_exit_${r.status ?? "unknown"}`;
	} else if (!r.stdout.trim()) {
		discoveryError = "pi_bridge_empty_output";
	} else {
		const parsed = parsePiBridgeList(r.stdout);
		if (parsed.error) discoveryError = parsed.error;
		else {
			const match = parsed.instances.find((item) => String(item.pid ?? "") === String(pid));
			if (match) {
				foundSession = bridgeSessionId(match);
				foundSocket = bridgeSocket(match);
				if (!foundSession || !foundSocket) discoveryError = "pi_bridge_partial_metadata";
			} else {
				const fallback = piBridgeMetadataByCwd(nonEmptyEnv("FLIGHTDECK_OWNER_CWD") || process.cwd(), timeout);
				if (fallback.sessionId || fallback.socketPath || fallback.discoveryError !== "pi_bridge_no_instance_for_pid") {
					return {
						discoveryError: fallback.discoveryError,
						sessionId: envSession || fallback.sessionId,
						socketPath: envSocket || fallback.socketPath,
					};
				}
				discoveryError = "pi_bridge_no_instance_for_pid";
			}
		}
	}
	return { discoveryError, sessionId: envSession || foundSession, socketPath: envSocket || foundSocket };
}

function piBridgeMetadataByCwd(cwd: string, timeout: number): { sessionId: string; socketPath: string; discoveryError: string } {
	const r = spawnSync("pi-bridge", ["list", "--json"], { encoding: "utf8", timeout });
	if (r.error) {
		const code = (r.error as NodeJS.ErrnoException).code;
		return { discoveryError: code === "ETIMEDOUT" ? "pi_bridge_timeout" : `pi_bridge_error_${code ?? "unknown"}`, sessionId: "", socketPath: "" };
	}
	if (r.status !== 0) return { discoveryError: `pi_bridge_exit_${r.status ?? "unknown"}`, sessionId: "", socketPath: "" };
	if (!r.stdout.trim()) return { discoveryError: "pi_bridge_empty_output", sessionId: "", socketPath: "" };
	const parsed = parsePiBridgeList(r.stdout);
	if (parsed.error) return { discoveryError: parsed.error, sessionId: "", socketPath: "" };
	const matches = parsed.instances.filter((item) => typeof item.cwd === "string" && item.cwd === cwd);
	if (matches.length > 1) return { discoveryError: "pi_bridge_ambiguous_cwd", sessionId: "", socketPath: "" };
	const match = matches[0];
	if (!match) return { discoveryError: "pi_bridge_no_instance_for_pid", sessionId: "", socketPath: "" };
	const sessionId = bridgeSessionId(match);
	const socketPath = bridgeSocket(match);
	return {
		discoveryError: sessionId && socketPath ? "" : "pi_bridge_partial_metadata",
		sessionId,
		socketPath,
	};
}

function parsePiBridgeList(stdout: string): { instances: Record<string, unknown>[]; error?: string } {
	try {
		const parsed = JSON.parse(stdout) as unknown;
		if (!Array.isArray(parsed)) return { instances: [], error: "pi_bridge_json_not_array" };
		return { instances: parsed.filter((item): item is Record<string, unknown> => !!item && typeof item === "object" && !Array.isArray(item)) };
	} catch {
		return { instances: [], error: "pi_bridge_malformed_json" };
	}
}

function bridgeSessionId(match: Record<string, unknown>): string {
	return typeof match.sessionId === "string" ? match.sessionId : typeof match.session_id === "string" ? match.session_id : "";
}

function bridgeSocket(match: Record<string, unknown>): string {
	return typeof match.socketPath === "string" ? match.socketPath : typeof match.socket === "string" ? match.socket : "";
}

function detectOwnerHarness(piMeta: { sessionId: string; socketPath: string }): string {
	const explicit = nonEmptyEnv("FLIGHTDECK_OWNER_HARNESS");
	if (explicit) return explicit;
	if (piMeta.sessionId || piMeta.socketPath) return "pi";
	if (nonEmptyEnv("CLAUDE_SESSION_ID") || nonEmptyEnv("CLAUDE_CODE_SESSION_ID")) return "claude";
	if (nonEmptyEnv("OPENCODE_SESSION_ID") || nonEmptyEnv("OPENCODE_APP_INFO")) return "opencode";
	if (nonEmptyEnv("CODEX_SESSION_ID") || nonEmptyEnv("CODEX_SANDBOX")) return "codex";
	return "unknown";
}

export function resolveOwnerMetadata(): FlightdeckOwner {
	const pid = ownerPid();
	const explicitHarness = nonEmptyEnv("FLIGHTDECK_OWNER_HARNESS");
	const piMeta = explicitHarness && explicitHarness !== "pi"
		? { discoveryError: "", sessionId: "", socketPath: "" }
		: piBridgeMetadata(pid);
	const harness = detectOwnerHarness(piMeta);
	const discoveryError = harness === "pi" && (!piMeta.sessionId || !piMeta.socketPath)
		? (piMeta.discoveryError || "pi_bridge_partial_metadata")
		: "";
	if (discoveryError) {
		process.stderr.write(`Warning: pi-bridge metadata discovery failed (${discoveryError}); proceeding with null pi_session_id/pi_bridge_socket.\n`);
	}
	const paneId = nonEmptyEnv("FLIGHTDECK_OWNER_PANE_ID") || nonEmptyEnv("TMUX_PANE") || tmuxDisplay("#{pane_id}");
	const paneTarget = nonEmptyEnv("FLIGHTDECK_OWNER_PANE_TARGET") || tmuxDisplay("#S:#{window_index}.#{pane_index}");
	return {
		harness,
		pane_id: paneId || null,
		pane_target: paneTarget || null,
		cwd: nonEmptyEnv("FLIGHTDECK_OWNER_CWD") || process.cwd(),
		pid,
		pi_session_id: piMeta.sessionId || null,
		pi_bridge_socket: piMeta.socketPath || null,
		discovery_error: discoveryError || null,
	};
}

// Returns true when the existing state file is safe to auto-archive
// before a fresh session begins. Predicate:
//   1. `terminated == true` — prior session ran `terminate`; rolling
//      forward is always safe.
//   2. file has tracked entries but ZERO have a pane_id that's currently
//      alive in tmux — prior session's windows were all closed without
//      `terminate` or `session stop`. No live work to preserve.
// Designed to be called only from session-entry callers
// (`flightdeck-session start`), NOT from every `initState` invocation.
export function shouldAutoArchiveAtSessionStart(file: string): { archive: boolean; reason: string | null } {
	if (!existsSync(file)) return { archive: false, reason: null };
	let parsed: unknown;
	try {
		parsed = JSON.parse(readFileSync(file, "utf8"));
	} catch {
		return { archive: false, reason: null };
	}
	if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { archive: false, reason: null };
	const raw = parsed as Record<string, unknown>;
	if (raw.terminated === true) return { archive: true, reason: "terminated" };
	const entries = isRecord(raw.entries) ? raw.entries : {};
	const paneIds: string[] = [];
	for (const e of Object.values(entries)) if (isRecord(e) && typeof e.pane_id === "string" && e.pane_id) paneIds.push(e.pane_id);
	if (paneIds.length === 0) return { archive: false, reason: null };
	const alive = livePaneIds();
	for (const pid of paneIds) if (alive.has(pid)) return { archive: false, reason: null };
	return { archive: true, reason: "no-live-panes" };
}

function isRecord(v: unknown): v is Record<string, unknown> {
	return !!v && typeof v === "object" && !Array.isArray(v);
}

function livePaneIds(): Set<string> {
	if (!process.env.TMUX) return new Set();
	const r = spawnSync("tmux", ["list-panes", "-a", "-F", "#{pane_id}"], { encoding: "utf8" });
	const out = new Set<string>();
	if (r.status !== 0) return out;
	for (const line of (r.stdout ?? "").split("\n")) if (line) out.add(line);
	return out;
}

export function initState(file: string): void {
	gcTmpOrphans(file);
	const lock = `${file}.lock`;
	// idempotent: the locked jq filter writes the initial state only if
	// the file doesn't already exist. .empty preserves the existing
	// contents; the alternate branch builds the canonical init payload.
	// Locked under the same lock as updateState so concurrent init +
	// set are serialized correctly.
	const session = basename(file).replace(/^flightdeck-state-/, "").replace(/\.json$/, "");
	const startedAt = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
	const owner = resolveOwnerMetadata();
	const ownerJson = JSON.stringify(owner);
	const activityPath = activityPathFromStatePath(file);
	const initJson = JSON.stringify({
		activity_path: activityPath,
		activity_schema_version: 1,
		conflict_graph: { computed_at: null, edges: [] },
		entries: {},
		merge_queue: [],
		owner,
		paused_for_user: null,
		session_id: session,
		started_at: startedAt,
		terminated: false,
	});
	if (existsSync(file)) {
		try {
			const parsed = JSON.parse(readFileSync(file, "utf8")) as unknown;
			if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
				const raw = parsed as Record<string, unknown>;
				if (raw.owner !== null && raw.owner !== undefined
					&& raw.entries !== null && raw.entries !== undefined
					&& raw.activity_path !== null && raw.activity_path !== undefined
					&& raw.activity_schema_version !== null && raw.activity_schema_version !== undefined) return;
			}
		} catch {
			// Preserve idempotence for corrupt/partial existing files: init
			// must not clobber them.
			return;
		}
		const activityPathJson = JSON.stringify(activityPath);
		const backfillFilter = `if ((. // {}) | type == "object") then (if .owner? == null then . + {owner: ${ownerJson}} else . end) | (if .entries? == null then . + {entries: {}} else . end) | (if .activity_path? == null then . + {activity_path: ${activityPathJson}} else . end) | (if .activity_schema_version? == null then . + {activity_schema_version: 1} else . end) else . end`;
		const backfill = lockedJqUpdate(lock, file, backfillFilter);
		if (backfill.status !== 0) {
			process.stderr.write(backfill.stderr || "");
			process.exit(backfill.status ?? 1);
		}
		return;
	}
	// jq filter that prefers an existing object over the synthesized init.
	const initFilter = `if ((. // {}) | type == "object" and (.entries // null) != null) then (if .owner? == null then . + {owner: ${ownerJson}} else . end) else ${initJson} end`;
	const r = lockedJqUpdate(lock, file, initFilter);
	if (r.status !== 0) {
		process.stderr.write(r.stderr || "");
		process.exit(r.status ?? 1);
	}
}

export function archiveState(file: string): string | null {
	if (!existsSync(file)) return null;
	let ts = runJqRaw(".terminated_at // empty", file).trim();
	if (!ts) ts = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
	const safeTs = ts.replace(/:/g, "");
	const archive = `${file.replace(/\.json$/, "")}-${safeTs}.json.archive`;
	const activity = activityPathFromStatePath(file);
	const activityArchive = activityArchivePathFromStatePath(file, ts);
	const lock = `${file}.lock`;
	const activityLock = `${activity}.lock`;
	const r = lockedArchiveStateAndActivity(lock, file, archive, activity, activityArchive, activityLock);
	if (r.status !== 0) {
		process.stderr.write(r.stderr || "");
		process.exit(r.status ?? 1);
	}
	return archive;
}

function gcTmpOrphans(file: string): void {
	const dir = dirname(file);
	const base = basename(file);
	let entries: string[];
	try {
		entries = readdirSync(dir);
	} catch {
		return;
	}
	for (const entry of entries) {
		if (!entry.startsWith(`${base}.tmp.`)) continue;
		const pid = entry.slice(`${base}.tmp.`.length);
		if (!/^\d+$/.test(pid)) continue;
		try {
			process.kill(Number.parseInt(pid, 10), 0);
		} catch (e) {
			// ESRCH = no such process → safe to remove
			const code = (e as NodeJS.ErrnoException).code;
			if (code === "ESRCH") {
				try { unlinkSync(join(dir, entry)); } catch { /* ignore */ }
			}
		}
	}
}

export function readStateText(file: string): string | null {
	if (!existsSync(file)) return null;
	return readFileSync(file, "utf8");
}

export function getField(file: string, jqPath: string): string {
	return runJqRaw(jqPath, file);
}

// stat for caller convenience.
export function stateMtimeMs(file: string): number | null {
	try {
		return statSync(file).mtimeMs;
	} catch {
		return null;
	}
}
