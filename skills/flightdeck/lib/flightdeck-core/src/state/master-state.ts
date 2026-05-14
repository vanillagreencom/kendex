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
	writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { resolveProjectRoot, loadDotEnvIntoProcess } from "../shared/project.ts";
import { lockedJqUpdate, lockedRename } from "./locking.ts";
import { FLIGHTDECK_SCHEMA_VERSION } from "./types.ts";

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
	const r = spawnSync("pi-bridge", ["list", "--json", "--pid", String(pid)], { encoding: "utf8", timeout: Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : 1000 });
	if (r.error) {
		const code = (r.error as NodeJS.ErrnoException).code;
		discoveryError = code === "ENOENT" ? "pi_bridge_not_found" : code === "ETIMEDOUT" ? "pi_bridge_timeout" : `pi_bridge_error_${code ?? "unknown"}`;
	} else if (r.status !== 0) {
		discoveryError = `pi_bridge_exit_${r.status ?? "unknown"}`;
	} else if (!r.stdout.trim()) {
		discoveryError = "pi_bridge_empty_output";
	} else {
		try {
			const parsed = JSON.parse(r.stdout) as unknown;
			if (Array.isArray(parsed)) {
				const match = parsed.find((item) => {
					if (!item || typeof item !== "object") return false;
					return String((item as { pid?: unknown }).pid ?? "") === String(pid);
				}) as Record<string, unknown> | undefined;
				if (match) {
					foundSession = typeof match.sessionId === "string" ? match.sessionId : typeof match.session_id === "string" ? match.session_id : "";
					foundSocket = typeof match.socketPath === "string" ? match.socketPath : typeof match.socket === "string" ? match.socket : "";
					if (!foundSession || !foundSocket) discoveryError = "pi_bridge_partial_metadata";
				}
				if (!match) discoveryError = "pi_bridge_no_instance_for_pid";
			} else {
				discoveryError = "pi_bridge_json_not_array";
			}
		} catch (e) {
			discoveryError = "pi_bridge_malformed_json";
		}
	}
	return { discoveryError, sessionId: envSession || foundSession, socketPath: envSocket || foundSocket };
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
	const piMeta = piBridgeMetadata(pid);
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
	const schemaVersionJson = JSON.stringify(FLIGHTDECK_SCHEMA_VERSION);
	const initJson = JSON.stringify({
		conflict_graph: { computed_at: null, edges: [] },
		entries: {},
		issues: {},
		merge_queue: [],
		owner,
		paused_for_user: null,
		schema_version: FLIGHTDECK_SCHEMA_VERSION,
		session_id: session,
		started_at: startedAt,
		terminated: false,
	});
	if (existsSync(file)) {
		try {
			const parsed = JSON.parse(readFileSync(file, "utf8")) as unknown;
			if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
				const raw = parsed as Record<string, unknown>;
				if (raw.owner !== null && raw.owner !== undefined && raw.schema_version !== null && raw.schema_version !== undefined && raw.entries !== null && raw.entries !== undefined) return;
			}
		} catch {
			// Preserve legacy idempotence for corrupt/partial existing files:
			// init must not clobber them.
			return;
		}
		const backfillFilter = `if ((. // {}) | type == "object") then (if .owner? == null then . + {owner: ${ownerJson}} else . end) | (if .schema_version? == null then . + {schema_version: ${schemaVersionJson}} else . end) | (if .entries? == null then . + {entries: {}} else . end) else . end`;
		const backfill = lockedJqUpdate(lock, file, backfillFilter);
		if (backfill.status !== 0) {
			process.stderr.write(backfill.stderr || "");
			process.exit(backfill.status ?? 1);
		}
		return;
	}
	// jq filter that prefers an existing object over the synthesized init.
	// Existing pre-owner/schema state is preserved and backfilled with the additive owner/schema blocks.
	const initFilter = `if ((. // {}) | type == "object" and (.issues // null) != null) then (if .owner? == null then . + {owner: ${ownerJson}} else . end) | (if .schema_version? == null then . + {schema_version: ${schemaVersionJson}} else . end) | (if .entries? == null then . + {entries: {}} else . end) else ${initJson} end`;
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
	const lock = `${file}.lock`;
	const r = lockedRename(lock, file, archive);
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
