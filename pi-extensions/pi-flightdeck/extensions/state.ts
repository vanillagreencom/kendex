/**
 * Read-only model of flightdeck master state + daemon process state.
 *
 * Mirrors the path resolution in skills/flightdeck/scripts/lib/daemon-paths.sh
 * and flightdeck-state. We never write — writes belong to the daemon and the
 * master agent (via flightdeck-state CLI).
 */

import { spawnSync } from "node:child_process";
import { closeSync, existsSync, openSync, readdirSync, readFileSync, readSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { findNewestTerminatedArchive, listTerminatedArchives } from "./state-archive.js";
import { normalizeConflictGraph, normalizeDecisionsLog, normalizeOwner } from "./state-normalizers.js";

export { findNewestTerminatedArchive, listTerminatedArchives } from "./state-archive.js";

export type IssueState = "waiting" | "prompting" | "submitting" | "merge-ready" | "merged" | "aborted" | "dead";

export interface IssueRecord {
	issue: string;
	window?: string;
	pane_target?: string;
	harness?: string;
	worktree?: string;
	pr_number?: number | null;
	// Immutable tmux pane id (`%N`) captured by `pane-registry init`.
	// Optional for legacy registry entries written before pane_id support;
	// `pane-registry reconcile` backfills these opportunistically.
	pane_id?: string | null;
	launch?: { model?: string | null; effort?: string | null } | null;
	state?: IssueState;
	substate?: string | null;
	unknown_since?: string | null;
	last_capture_hash?: string | null;
	last_response_at?: string | null;
	spawned_at?: string;
	last_polled_at?: string;
	orchestration_started?: boolean;
	scope_files_declared?: number | null;
	scope_files_actual?: number | null;
	decisions_log?: Array<{ ts: string; prompt_tag: string; answer: string }>;
	// Captured by close-issue.md § 3 / merge-plan.md § 3 when a PR lands; the
	// post-completion dashboard surfaces it in Overview and the merge-history
	// pane of the Conflicts & merges tab.
	merge_commit?: string | null;
	[key: string]: unknown;
}

export interface PausedForUser {
	issue_id?: string;
	reason?: string;
	prompt_text?: string;
	[key: string]: unknown;
}

export interface MasterOwner {
	harness?: string;
	pane_id?: string | null;
	pane_target?: string | null;
	cwd?: string;
	pid?: number;
	pi_session_id?: string | null;
	pi_bridge_socket?: string | null;
	discovery_error?: string | null;
	[key: string]: unknown;
}

export interface MasterState {
	session_id?: string;
	started_at?: string;
	terminated?: boolean;
	terminated_at?: string;
	// `terminate.md § 5` writes the absolute or project-relative path to the
	// session summary markdown. Used by the dashboard to point users at the
	// post-mortem file without re-reading the disk.
	summary_path?: string;
	owner?: MasterOwner;
	issues: Record<string, IssueRecord>;
	merge_queue: string[];
	conflict_graph?: { edges?: Array<[string, string]>; computed_at?: string | null };
	paused_for_user?: PausedForUser | null;
}

export interface DaemonHealth {
	stateDir: string;
	sessionKey?: string;
	pidFile?: string;
	pid?: number;
	pidAlive: boolean;
	heartbeatPath?: string;
	heartbeatAgeSec?: number;
	heartbeatExists: boolean;
	busyPath?: string;
	busy?: { pid?: number; master_pane_id?: string; started_at?: string };
	wakePendingPath?: string;
	wakePending?: {
		delivered_at?: string;
		delivered_at_epoch?: number;
		master_pane_id?: string;
		daemon_pid?: number;
		in_flight?: Array<{ pane_id: string; hash: string; tag: string; is_bell?: boolean }>;
	};
	logPath?: string;
	logTail?: string[];
	wakeEventsPath?: string;
	wakeEventsRecent?: WakeEvent[];
	subscriberCounts: { opencode: number; claude: number; pi: number; codex: number };
	subscribers: SubscriberProcess[];
}

export interface SubscriberProcess {
	harness: "opencode" | "claude" | "pi" | "codex";
	paneId: string;
	pid: number;
	pidFile: string;
}

export interface WakeEvent {
	ts?: string;
	pane_id?: string;
	harness?: string;
	classifier_tag?: string;
	hash?: string;
	last_assistant_text?: string;
	event_type?: "question" | "subagent-completion" | string;
	request_id?: string;
	question?: unknown;
	completion?: unknown;
}

export interface DaemonEvent {
	ts?: string;
	pane_id?: string;
	hash?: string;
	tag?: string;
	reason?: string;
	stable_age_sec?: number;
	details?: unknown;
}

export interface TmuxContext {
	sessionName: string;
	sessionId: string;
	sessionKey: string;
	paneId?: string;
}

export interface FlightdeckSnapshot {
	tmux: TmuxContext;
	stateDir: string;
	masterStatePath?: string;
	master?: MasterState;
	masterError?: string;
	// Set when the archive-fallback path produced the masterError
	// (every candidate archive failed strict validation, or the master-
	// state directory itself was unreadable). Drives the `archive-error`
	// status arm. Always implies `masterError` is set and `master` is
	// unset; the distinct flag avoids brittle string-matching in the
	// status predicate and lets non-archive failures (live read errors)
	// stay in their own bucket.
	masterArchiveError?: boolean;
	daemon: DaemonHealth;
	wakeEvents: WakeEvent[];
	pendingEvents: DaemonEvent[];
}

export interface SettingsLike {
	stateDir?: string;
	flightdeckStateDir?: string;
	logTailLines?: number;
	wakeEventsLines?: number;
}

const DEFAULT_LOG_TAIL = 200;
const DEFAULT_WAKE_TAIL = 200;

function expandHome(input: string): string {
	if (!input) return input;
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

function nonEmpty(value: unknown): string | undefined {
	if (typeof value !== "string") return undefined;
	const trimmed = value.trim();
	return trimmed ? trimmed : undefined;
}

// Tmux context (session name/id + current pane id) is stable for the
// life of the pi process. Cache the lookup after the first call to skip
// a tmux subprocess per poll tick (perf review finding #2).
let TMUX_CONTEXT_CACHE: TmuxContext | undefined;
let TMUX_CONTEXT_RESOLVED = false;

export function resolveTmuxContext(): TmuxContext | undefined {
	if (TMUX_CONTEXT_RESOLVED) return TMUX_CONTEXT_CACHE;
	if (!process.env.TMUX) {
		TMUX_CONTEXT_RESOLVED = true;
		return undefined;
	}
	const result = spawnSync("tmux", ["display-message", "-p", "#S\t#{session_id}\t#{pane_id}"], {
		encoding: "utf8",
		timeout: 1500,
	});
	if (result.status !== 0) {
		TMUX_CONTEXT_RESOLVED = true;
		return undefined;
	}
	const [name, id, pane] = (result.stdout ?? "").trim().split("\t");
	if (!name || !id) {
		TMUX_CONTEXT_RESOLVED = true;
		return undefined;
	}
	const sessionKey = id.startsWith("$") ? `s${id.slice(1)}` : id;
	TMUX_CONTEXT_CACHE = { sessionName: name, sessionId: id, sessionKey, paneId: pane || undefined };
	TMUX_CONTEXT_RESOLVED = true;
	return TMUX_CONTEXT_CACHE;
}

export function resolveStateDir(settings?: SettingsLike): string {
	const override = nonEmpty(settings?.stateDir) ?? nonEmpty(process.env.FD_STATE_DIR);
	if (override) return resolve(expandHome(override));
	const xdg = nonEmpty(process.env.XDG_RUNTIME_DIR);
	if (xdg) return join(xdg, "flightdeck");
	const uid = typeof process.getuid === "function" ? process.getuid() : 0;
	return `/tmp/flightdeck-${uid}`;
}

// Per-cwd project root cache. Cwd changes infrequently (only on cd /
// session switch) so caching avoids a git subprocess per tick.
const PROJECT_ROOT_CACHE = new Map<string, string>();

export function resolveProjectRoot(cwd: string): string {
	const cached = PROJECT_ROOT_CACHE.get(cwd);
	if (cached !== undefined) return cached;
	const resolved = resolveProjectRootUncached(cwd);
	PROJECT_ROOT_CACHE.set(cwd, resolved);
	return resolved;
}

function resolveProjectRootUncached(cwd: string): string {
	// Inside a git worktree, prefer the main repo root (the parent of
	// `--git-common-dir`) so flightdeck state lookup resolves to the
	// canonical `<main-root>/tmp/flightdeck-state-*.json` instead of the
	// worktree's own (non-existent) tmp dir. Without this, the overlay
	// rendered inside a worktree pane would correctly detect the daemon
	// (daemon files are uid-scoped, not cwd-scoped) but fail to load the
	// master state file, falsely showing "0 issues" (#4 finding 3).
	const worktreeRoot = gitMainWorktreeRoot(cwd);
	if (worktreeRoot) return worktreeRoot;
	let current = resolve(cwd);
	const markers = [".vstack-lock.json", ".pi", ".git"];
	while (true) {
		for (const marker of markers) {
			if (existsSync(join(current, marker))) return current;
		}
		const parent = dirname(current);
		if (parent === current) return resolve(cwd);
		current = parent;
	}
}

function gitMainWorktreeRoot(cwd: string): string | undefined {
	const result = spawnSync("git", ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"], {
		encoding: "utf8",
		timeout: 1500,
	});
	if (result.status !== 0) return undefined;
	const gitDir = (result.stdout ?? "").trim();
	if (!gitDir) return undefined;
	const main = resolve(gitDir, "..");
	return existsSync(main) ? main : undefined;
}

export function masterStatePath(projectRoot: string, settings: SettingsLike, sessionName: string): string {
	const dir = nonEmpty(settings.flightdeckStateDir) ?? "tmp";
	return join(projectRoot, dir, `flightdeck-state-${sessionName}.json`);
}

export function masterStateDir(projectRoot: string, settings: SettingsLike): string {
	const dir = nonEmpty(settings.flightdeckStateDir) ?? "tmp";
	return join(projectRoot, dir);
}



export interface DaemonPaths {
	pid: string;
	lock: string;
	log: string;
	heartbeat: string;
	busy: string;
	wakePending: string;
	events: string;
	wakeEvents: string;
}

export function daemonPaths(stateDir: string, sessionKey: string): DaemonPaths {
	return {
		busy: join(stateDir, `fd-master-${sessionKey}.busy`),
		events: join(stateDir, `fd-daemon-events-${sessionKey}.jsonl`),
		heartbeat: join(stateDir, `fd-daemon-${sessionKey}.heartbeat`),
		lock: join(stateDir, `fd-daemon-${sessionKey}.lock`),
		log: join(stateDir, `fd-daemon-${sessionKey}.log`),
		pid: join(stateDir, `fd-daemon-${sessionKey}.pid`),
		wakeEvents: join(stateDir, `fd-wake-events-${sessionKey}.log`),
		wakePending: join(stateDir, `fd-wake-pending-${sessionKey}`),
	};
}

function readJsonFile<T>(path: string): T | undefined {
	try {
		const text = readFileSync(path, "utf8");
		if (!text.trim()) return undefined;
		return JSON.parse(text) as T;
	} catch {
		return undefined;
	}
}

export function readMasterState(path: string): { state?: MasterState; error?: string } {
	if (!existsSync(path)) return {};
	try {
		const text = readFileSync(path, "utf8");
		if (!text.trim()) return { state: emptyState() };
		const parsed = JSON.parse(text);
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { error: "master state JSON is not an object" };
		const raw = parsed as Partial<MasterState>;
		const issues: Record<string, IssueRecord> = {};
		if (raw.issues && typeof raw.issues === "object" && !Array.isArray(raw.issues)) {
			for (const [issue, value] of Object.entries(raw.issues as Record<string, unknown>)) {
				if (value && typeof value === "object" && !Array.isArray(value)) {
					const record = { issue, ...(value as Record<string, unknown>) } as IssueRecord;
					// Malformed `decisions_log` (non-array or wrong-shape items)
					// would otherwise throw inside the Decisions tab / dashboard
					// child-row renderer. Normalize defensively so a corrupt
					// archive renders as empty-but-stable, not as a popup crash.
					record.decisions_log = normalizeDecisionsLog(record.decisions_log);
					issues[issue] = record;
				}
			}
		}
		return {
			state: {
				conflict_graph: normalizeConflictGraph(raw.conflict_graph),
				issues,
				merge_queue: Array.isArray(raw.merge_queue) ? raw.merge_queue.filter((v): v is string => typeof v === "string") : [],
				owner: normalizeOwner(raw.owner),
				paused_for_user: raw.paused_for_user ?? null,
				session_id: raw.session_id,
				started_at: raw.started_at,
				summary_path: typeof raw.summary_path === "string" ? raw.summary_path : undefined,
				terminated: raw.terminated ?? false,
				terminated_at: raw.terminated_at,
			},
		};
	} catch (error) {
		return { error: error instanceof Error ? error.message : String(error) };
	}
}



function emptyState(): MasterState {
	return {
		conflict_graph: { edges: [], computed_at: null },
		issues: {},
		merge_queue: [],
		paused_for_user: null,
		terminated: false,
	};
}

function readPidFile(path: string): number | undefined {
	if (!existsSync(path)) return undefined;
	const text = (() => {
		try {
			return readFileSync(path, "utf8").trim();
		} catch {
			return "";
		}
	})();
	const pid = Number.parseInt(text, 10);
	return Number.isFinite(pid) && pid > 0 ? pid : undefined;
}

function isPidAlive(pid: number | undefined): boolean {
	if (!pid) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		const code = typeof error === "object" && error && "code" in error ? (error as { code?: string }).code : undefined;
		// EPERM means the process exists but we can't signal it — still alive.
		return code === "EPERM";
	}
}

function fileMtimeSec(path: string): number | undefined {
	try {
		return Math.floor(statSync(path).mtimeMs / 1000);
	} catch {
		return undefined;
	}
}

// Bounded tail read: only the last ~maxLines*estLineLength bytes are
// pulled from disk per call, so per-tick cost stays roughly constant as
// daemon logs grow into MBs over long sessions (perf review finding #1).
// readFileSync on a 50MB log every 1.5s tick is the original failure
// mode — here we cap the byte read and grow on a miss.
function readLastLines(path: string, maxLines: number): string[] {
	const est = 256; // bytes/line heuristic
	let budget = Math.max(8192, maxLines * est);
	for (let attempt = 0; attempt < 3; attempt += 1) {
		const chunk = readTailChunk(path, budget);
		if (chunk === undefined) return [];
		// First chunk may start mid-line; drop the leading partial unless we
		// read the entire file (offset reached 0).
		const lines = chunk.text.split(/\r?\n/);
		if (!chunk.atStart && lines.length > 0) lines.shift();
		while (lines.length && !lines[lines.length - 1]) lines.pop();
		if (lines.length >= maxLines || chunk.atStart) {
			return lines.length <= maxLines ? lines : lines.slice(lines.length - maxLines);
		}
		// Didn't get enough lines; double the read budget and retry.
		budget *= 4;
	}
	// Final fallback to a full read — only hit when the file's lines are
	// pathologically long (avg > ~4 KB) which the daemon log shouldn't
	// produce.
	try {
		const text = readFileSync(path, "utf8");
		const lines = text.split(/\r?\n/);
		while (lines.length && !lines[lines.length - 1]) lines.pop();
		return lines.length <= maxLines ? lines : lines.slice(lines.length - maxLines);
	} catch {
		return [];
	}
}

function readTailChunk(path: string, budgetBytes: number): { text: string; atStart: boolean } | undefined {
	let fd: number | undefined;
	try {
		const size = statSync(path).size;
		const readBytes = Math.min(size, budgetBytes);
		const start = size - readBytes;
		if (readBytes === 0) return { text: "", atStart: true };
		fd = openSync(path, "r");
		const buf = Buffer.allocUnsafe(readBytes);
		const got = readSync(fd, buf, 0, readBytes, start);
		return { text: buf.toString("utf8", 0, got), atStart: start === 0 };
	} catch {
		return undefined;
	} finally {
		if (fd !== undefined) {
			try { closeSync(fd); } catch { /* ignore */ }
		}
	}
}

function readJsonLines(path: string, maxLines: number): unknown[] {
	const lines = readLastLines(path, maxLines);
	const out: unknown[] = [];
	for (const line of lines) {
		const trimmed = line.trim();
		if (!trimmed) continue;
		try {
			out.push(JSON.parse(trimmed));
		} catch {
			// Skip malformed lines; daemon truncation/race produces them rarely.
		}
	}
	return out;
}

function readSubscribers(stateDir: string, sessionKey: string | undefined): { counts: DaemonHealth["subscriberCounts"]; subscribers: SubscriberProcess[] } {
	const counts = { opencode: 0, claude: 0, pi: 0, codex: 0 };
	const subscribers: SubscriberProcess[] = [];
	let entries: string[];
	try {
		entries = readdirSync(stateDir);
	} catch {
		return { counts, subscribers };
	}
	// Subscriber pid filenames are scoped by session key:
	// `fd-<type>-subscriber-<session_key>-<pane_safe>.pid`. Filtering keeps
	// the overlay's count specific to the current flightdeck session and
	// avoids overcounting when multiple daemons share the state dir.
	// We also verify the recorded pid is alive so a stale pid file from a
	// crashed subscriber doesn't inflate the count (cross-harness verify
	// follow-up): the daemon's per-tick watchdog removes those eventually,
	// but the dashboard ticks faster than the watchdog can act, so the UI
	// can show a phantom subscriber for one render cycle without this.
	const infix = sessionKey ? `-${sessionKey}-` : "";
	for (const entry of entries) {
		if (!entry.endsWith(".pid")) continue;
		if (!entry.includes(infix)) continue;
		let bucket: SubscriberProcess["harness"] | undefined;
		let prefix = "";
		if (entry.startsWith("fd-subscriber-")) { bucket = "opencode"; prefix = "fd-subscriber-"; }
		else if (entry.startsWith("fd-cc-subscriber-")) { bucket = "claude"; prefix = "fd-cc-subscriber-"; }
		else if (entry.startsWith("fd-pi-subscriber-")) { bucket = "pi"; prefix = "fd-pi-subscriber-"; }
		else if (entry.startsWith("fd-cx-subscriber-")) { bucket = "codex"; prefix = "fd-cx-subscriber-"; }
		if (!bucket || !prefix) continue;
		const path = join(stateDir, entry);
		const pid = readPidFile(path);
		if (!isPidAlive(pid) || !pid) continue;
		counts[bucket] += 1;
		let paneSafe = entry.slice(prefix.length, -".pid".length);
		if (sessionKey && paneSafe.startsWith(`${sessionKey}-`)) paneSafe = paneSafe.slice(sessionKey.length + 1);
		const paneId = paneSafe.startsWith("%") ? paneSafe : `%${paneSafe}`;
		subscribers.push({ harness: bucket, paneId, pid, pidFile: path });
	}
	return { counts, subscribers };
}

export function readDaemonHealth(
	stateDir: string,
	sessionKey: string,
	logTail: number = DEFAULT_LOG_TAIL,
	wakeTail: number = DEFAULT_WAKE_TAIL,
): DaemonHealth {
	const paths = daemonPaths(stateDir, sessionKey);
	const pid = readPidFile(paths.pid);
	const pidAlive = isPidAlive(pid);
	const heartbeatExists = existsSync(paths.heartbeat);
	const heartbeatAgeSec = heartbeatExists
		? Math.max(0, Math.floor(Date.now() / 1000) - (fileMtimeSec(paths.heartbeat) ?? 0))
		: undefined;
	const busy = readJsonFile<{ pid?: number; master_pane_id?: string; started_at?: string }>(paths.busy);
	const wakePending = readJsonFile<DaemonHealth["wakePending"]>(paths.wakePending);
	const logTailLines = readLastLines(paths.log, logTail);
	const wakeEventsRecent = readJsonLines(paths.wakeEvents, wakeTail) as WakeEvent[];
	const subscriberSnapshot = readSubscribers(stateDir, sessionKey);
	return {
		busy,
		busyPath: paths.busy,
		heartbeatAgeSec,
		heartbeatExists,
		heartbeatPath: paths.heartbeat,
		logPath: paths.log,
		logTail: logTailLines,
		pid,
		pidAlive,
		pidFile: paths.pid,
		sessionKey,
		stateDir,
		subscriberCounts: subscriberSnapshot.counts,
		subscribers: subscriberSnapshot.subscribers,
		wakeEventsPath: paths.wakeEvents,
		wakeEventsRecent,
		wakePending,
		wakePendingPath: paths.wakePending,
	};
}

export function readPendingEvents(stateDir: string, sessionKey: string, maxLines: number = DEFAULT_LOG_TAIL): DaemonEvent[] {
	const paths = daemonPaths(stateDir, sessionKey);
	return readJsonLines(paths.events, maxLines) as DaemonEvent[];
}

// Strict archive read for the post-terminate fallback. Distinguishes:
//   * blank file (0 bytes / whitespace-only) — partial-write corruption
//   * non-object root (`[]`, scalar) — rejected by `readMasterState`
//   * non-terminated payload — readable but not the post-mortem record
//   * malformed JSON — rejected by `readMasterState`
//   * IO error — propagated
// Without these, a blank or non-terminated archive collapsed silently
// to `inactive` and hid corruption from the user (BLOCK round 4).
type ReadArchiveResult = { kind: "ok"; state: MasterState } | { kind: "error"; message: string };

function readArchiveStrict(path: string): ReadArchiveResult {
	let text: string;
	try {
		text = readFileSync(path, "utf8");
	} catch (e) {
		return { kind: "error", message: `read failed: ${(e as Error).message ?? String(e)}` };
	}
	if (!text.trim()) return { kind: "error", message: "blank archive" };
	const read = readMasterState(path);
	if (read.error) return { kind: "error", message: read.error };
	if (!read.state) return { kind: "error", message: "archive yielded no state" };
	if (!read.state.terminated) return { kind: "error", message: "archive missing terminated:true" };
	return { kind: "ok", state: read.state };
}

// Test seam — production code calls `buildSnapshot`. Tests inject a
// fully resolved (projectRoot, stateDir, tmux) so they don't have to
// stand up a real tmux session or git worktree just to exercise the
// post-terminate read path (issue #17 BLOCKER #2).
export interface BuildSnapshotInputs {
	projectRoot: string;
	stateDir: string;
	tmux: TmuxContext;
}

export interface OwnerVisibilityProbe {
	tmux: TmuxContext;
	ownerPaneId?: string | null;
}

// Cheap preflight for non-owner widget suppression. Reads only tmux context
// + the live master state's owner pane before `buildSnapshot` tails daemon
// logs, wake events, subscribers, and terminated archives.
export function readOwnerVisibilityProbe(cwd: string, settings: SettingsLike): OwnerVisibilityProbe | undefined {
	const tmux = resolveTmuxContext();
	if (!tmux) return undefined;
	const projectRoot = resolveProjectRoot(cwd);
	const path = masterStatePath(projectRoot, settings, tmux.sessionName);
	const { state } = readMasterState(path);
	return { ownerPaneId: state?.owner?.pane_id, tmux };
}

export function buildSnapshotFromInputs(inputs: BuildSnapshotInputs, settings: SettingsLike, options?: { logTailLines?: number; wakeEventsLines?: number }): FlightdeckSnapshot {
	const { projectRoot, stateDir, tmux } = inputs;
	const liveStatePath = masterStatePath(projectRoot, settings, tmux.sessionName);
	let resolvedStatePath = liveStatePath;
	let archiveError = false;
	let { state, error } = readMasterState(liveStatePath);
	// Archive fallback (issue #17 BLOCKER #1, refined in rounds 3 and 4).
	// When the live file is missing, walk the master-state directory's
	// terminated archives newest-first and serve the first VALID
	// `terminated: true` snapshot. STRICT validation: blank archives,
	// readable-but-non-terminated archives, malformed JSON, and IO
	// failures all count as failures with their own reason strings.
	// A non-ENOENT readdir error (permission denied / IO) also surfaces
	// as a diagnostic so the user sees "state was lost" instead of
	// silently falling back to inactive. Live state always wins when
	// present, so the fallback never shadows an in-flight session.
	if (!state && !error) {
		const dir = masterStateDir(projectRoot, settings);
		const listing = listTerminatedArchives(dir, tmux.sessionName);
		const failures: Array<{ path: string; reason: string }> = [];
		for (const candidate of listing.archives) {
			const reason = readArchiveStrict(candidate);
			if (reason.kind === "ok") {
				state = reason.state;
				resolvedStatePath = candidate;
				break;
			}
			failures.push({ path: candidate, reason: reason.message });
		}
		if (!state) {
			if (failures.length > 0) {
				const latest = failures[0]!;
				error = `no readable terminated archive: ${failures.length} candidate${failures.length === 1 ? "" : "s"} failed (latest ${latest.path}: ${latest.reason})`;
				resolvedStatePath = latest.path;
				archiveError = true;
			} else if (listing.error) {
				error = `archive directory unreadable: ${listing.error.code} ${listing.error.path}: ${listing.error.message}`;
				resolvedStatePath = listing.error.path;
				archiveError = true;
			}
		}
	}
	const daemon = readDaemonHealth(
		stateDir,
		tmux.sessionKey,
		options?.logTailLines ?? DEFAULT_LOG_TAIL,
		options?.wakeEventsLines ?? DEFAULT_WAKE_TAIL,
	);
	const pendingEvents = readPendingEvents(stateDir, tmux.sessionKey, options?.logTailLines ?? DEFAULT_LOG_TAIL);
	return {
		daemon,
		master: state,
		masterArchiveError: archiveError || undefined,
		masterError: error,
		masterStatePath: resolvedStatePath,
		pendingEvents,
		stateDir,
		tmux,
		wakeEvents: daemon.wakeEventsRecent ?? [],
	};
}

export function buildSnapshot(cwd: string, settings: SettingsLike, options?: { logTailLines?: number; wakeEventsLines?: number }): FlightdeckSnapshot | undefined {
	const tmux = resolveTmuxContext();
	if (!tmux) return undefined;
	const stateDir = resolveStateDir(settings);
	const projectRoot = resolveProjectRoot(cwd);
	return buildSnapshotFromInputs({ projectRoot, stateDir, tmux }, settings, options);
}

// Normalization seam (BLOCKER #4 from review). The dashboard / render
// code reads tracked issues via this helper instead of touching
// `.issues` directly. When the registry-reframe lands (`.entries` /
// `.tracked`), the migration changes only this seam, not the renderer.
export function readTrackedEntries(state: MasterState | undefined): IssueRecord[] {
	return sortedIssues(state);
}

export function isFlightdeckActive(snapshot: FlightdeckSnapshot | undefined): boolean {
	if (!snapshot) return false;
	if (snapshot.master && !snapshot.master.terminated && Object.keys(snapshot.master.issues).length > 0) return true;
	if (snapshot.daemon.pidAlive) return true;
	return false;
}

// `terminated`: master flagged the session complete via `terminate.md § 5`
// and `.issues` is still populated. The dashboard keeps rendering the
// completed session (Overview / Decisions / Conflicts & merges all read
// the preserved history) until the user dismisses the widget. Without
// this third arm, terminated sessions fell into `inactive` and the
// post-completion summary was hidden from the user (issue #17).
// `archive-error`: a terminated archive was selected but every candidate
// failed to parse. Renders an error banner with the diagnostic so the
// user sees "state was lost" instead of a blank "no session" view
// (BLOCK round 3).
export type FlightdeckSessionStatus = "live" | "stale" | "inactive" | "terminated" | "archive-error";

const TERMINAL_ISSUE_STATES = new Set<IssueState>(["merged", "aborted", "dead"]);

// Most recent `last_polled_at` (ms epoch) across non-terminal issues. Used
// by both the stale-state predicate and the stale-hint renderer.
export function mostRecentPollMs(snapshot: FlightdeckSnapshot | undefined): number | undefined {
	const issues = snapshot?.master?.issues;
	if (!issues) return undefined;
	let best: number | undefined;
	for (const issue of Object.values(issues)) {
		if (issue.state && TERMINAL_ISSUE_STATES.has(issue.state)) continue;
		const t = Date.parse(issue.last_polled_at ?? "");
		if (!Number.isFinite(t)) continue;
		if (best === undefined || t > best) best = t;
	}
	return best;
}

// Classify a snapshot for the dashboard renderer. A state file with
// non-terminal issues and no live daemon is treated as `stale` once the
// most recent poll is older than `staleAfterMin` minutes — past that
// window the daemon is not coming back on its own and the dashboard would
// otherwise render leftover data from a prior session. Pass
// `staleAfterMin: 0` to disable the staleness check entirely (legacy
// `isFlightdeckActive` behavior).
export function flightdeckSessionStatus(
	snapshot: FlightdeckSnapshot | undefined,
	options?: { staleAfterMin?: number; now?: number },
): FlightdeckSessionStatus {
	if (!snapshot) return "inactive";
	// Archive lookup tried but every candidate was malformed (or the
	// master-state directory itself was unreadable). Render the
	// diagnostic banner instead of falling through to `inactive` — the
	// user otherwise can't tell a corrupted archive from a missing one.
	if (snapshot.masterArchiveError) return "archive-error";
	const master = snapshot.master;
	const hasAnyIssues = !!master && Object.keys(master.issues).length > 0;
	// terminated + issues preserved → read-only completion view. Issue #17
	// was the regression where `pane-registry remove-merged` ran inside
	// `terminate.md § 5` and left `.issues == {}` on a terminated file, so
	// this branch was unreachable and the dashboard collapsed.
	if (master?.terminated && hasAnyIssues) return "terminated";
	const hasLiveIssues = !!master && !master.terminated && hasAnyIssues;
	const daemonAlive = snapshot.daemon.pidAlive;
	if (!hasLiveIssues && !daemonAlive) return "inactive";
	if (daemonAlive) return "live";
	const staleAfterMin = options?.staleAfterMin ?? 5;
	if (staleAfterMin <= 0) return "live";
	const now = options?.now ?? Date.now();
	const latest = mostRecentPollMs(snapshot);
	if (latest === undefined) return "stale";
	const ageSec = Math.max(0, Math.floor((now - latest) / 1000));
	return ageSec > staleAfterMin * 60 ? "stale" : "live";
}

// Merged issues, newest-merge-first by `last_polled_at`, used by the
// Conflicts & merges tab to render a stable "Merge history" panel that
// outlives the live `merge_queue` (which drains as items land).
export function mergedIssueHistory(state: MasterState | undefined): IssueRecord[] {
	if (!state) return [];
	const merged = Object.values(state.issues).filter((issue) => issue.state === "merged");
	merged.sort((a, b) => {
		const at = Date.parse(a.last_polled_at ?? a.spawned_at ?? "");
		const bt = Date.parse(b.last_polled_at ?? b.spawned_at ?? "");
		if (Number.isFinite(at) && Number.isFinite(bt) && at !== bt) return bt - at;
		return a.issue.localeCompare(b.issue);
	});
	return merged;
}

export function sortedIssues(state: MasterState | undefined): IssueRecord[] {
	if (!state) return [];
	return Object.values(state.issues).sort((a, b) => {
		const aTs = a.spawned_at ?? "";
		const bTs = b.spawned_at ?? "";
		if (aTs && bTs && aTs !== bTs) return aTs.localeCompare(bTs);
		return a.issue.localeCompare(b.issue);
	});
}

export function flatDecisionsLog(state: MasterState | undefined, max = 200): Array<{ issue: string; ts: string; prompt_tag: string; answer: string }> {
	if (!state) return [];
	const out: Array<{ issue: string; ts: string; prompt_tag: string; answer: string }> = [];
	for (const issue of Object.values(state.issues)) {
		for (const entry of issue.decisions_log ?? []) {
			out.push({ answer: entry.answer, issue: issue.issue, prompt_tag: entry.prompt_tag, ts: entry.ts });
		}
	}
	out.sort((a, b) => b.ts.localeCompare(a.ts));
	return out.slice(0, max);
}

export function ageSecondsSince(iso: string | undefined | null): number | undefined {
	if (!iso) return undefined;
	const t = Date.parse(iso);
	if (!Number.isFinite(t)) return undefined;
	return Math.max(0, Math.floor((Date.now() - t) / 1000));
}

export function formatAge(seconds: number | undefined): string {
	if (seconds === undefined) return "—";
	if (seconds < 60) return `${seconds}s`;
	if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
	if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h`;
	return `${Math.floor(seconds / 86_400)}d`;
}

export interface ConversationTurn {
	ts: string;
	pane_id: string;
	harness?: string;
	tag?: string;
	hash?: string;
	excerpt: string;
}

function normalizeConversationExcerpt(text: string): string {
	return text
		.replace(/\s+/g, " ")
		.replace(/[\s`'"“”‘’.,;:!?…]+$/g, "")
		.trim();
}

function turnTimeMs(turn: ConversationTurn): number {
	const parsed = Date.parse(turn.ts);
	return Number.isFinite(parsed) ? parsed : 0;
}

function turnTimeDiffMs(a: ConversationTurn, b: ConversationTurn): number {
	return Math.abs(turnTimeMs(a) - turnTimeMs(b));
}

function nearDuplicateWindow(a: ConversationTurn, b: ConversationTurn): boolean {
	return turnTimeDiffMs(a, b) <= 5 * 60 * 1000;
}

function nearStreamingWindow(a: ConversationTurn, b: ConversationTurn): boolean {
	const diff = Math.abs(turnTimeMs(a) - turnTimeMs(b));
	return diff <= 30 * 1000;
}

function shouldMergeConversationTurn(previous: ConversationTurn, next: ConversationTurn): "replace" | "keep" | "append" {
	if (previous.hash && next.hash && previous.hash === next.hash) return "keep";
	if (!nearDuplicateWindow(previous, next)) return "append";

	const before = normalizeConversationExcerpt(previous.excerpt);
	const after = normalizeConversationExcerpt(next.excerpt);
	if (!before || !after) return "append";

	if (before === after) return next.excerpt.length > previous.excerpt.length ? "replace" : "keep";
	// Pi bridge streams message_update events before message_end. Those partials
	// share the same pane and near-identical timestamp but have different hashes
	// as the assistant text grows. Collapse prefix/suffix variants so
	// Conversations show one finalized turn instead of a stack of partials. Keep
	// the streaming window tight so two separate turns that happen to start with
	// similar boilerplate do not merge minutes apart.
	if (nearStreamingWindow(previous, next) && after.startsWith(before) && before.length >= 12) return "replace";
	if (nearStreamingWindow(previous, next) && before.startsWith(after) && after.length >= 12) return "keep";
	return "append";
}

function pushConversationTurn(list: ConversationTurn[], turn: ConversationTurn, maxPerPane: number): void {
	const last = list[list.length - 1];
	if (last) {
		const action = shouldMergeConversationTurn(last, turn);
		if (action === "keep") return;
		if (action === "replace") {
			list[list.length - 1] = turn;
			return;
		}
	}
	list.push(turn);
	while (list.length > maxPerPane) list.shift();
}

/**
 * Fold the latest wake events into a per-pane conversation history.
 * Best-effort — events get drained by the master ack, so this represents
 * whatever has appeared since the last drain, plus what the buffer carried
 * over.
 */
export function foldWakeEventsIntoConversations(
	previous: Map<string, ConversationTurn[]>,
	events: WakeEvent[],
	maxPerPane: number,
	maxChars: number,
): Map<string, ConversationTurn[]> {
	const next = new Map<string, ConversationTurn[]>();
	for (const [k, v] of previous) {
		const compacted: ConversationTurn[] = [];
		for (const turn of v) pushConversationTurn(compacted, turn, maxPerPane);
		next.set(k, compacted);
	}
	for (const ev of events) {
		const pane = ev.pane_id;
		if (!pane) continue;
		const text = typeof ev.last_assistant_text === "string" ? ev.last_assistant_text.trim() : "";
		if (!text) continue;
		const list = next.get(pane) ?? [];
		pushConversationTurn(list, {
			excerpt: text.length > maxChars ? `${text.slice(0, maxChars)}…` : text,
			harness: ev.harness,
			hash: ev.hash,
			pane_id: pane,
			tag: ev.classifier_tag,
			ts: ev.ts ?? new Date().toISOString(),
		}, maxPerPane);
		next.set(pane, list);
	}
	return next;
}
