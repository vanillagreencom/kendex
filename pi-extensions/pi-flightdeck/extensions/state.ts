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
import { resolveActiveRunStatePath } from "./run-store.js";
import { normalizeConflictGraph, normalizeDecisionsLog, normalizeOwner } from "./state-normalizers.js";

export { findNewestTerminatedArchive, listTerminatedArchives } from "./state-archive.js";
export { resetRunStoreCacheForTests } from "./run-store.js";

export type TrackedState = "waiting" | "prompting" | "submitting" | "merge-ready" | "merged" | "aborted" | "dead" | "ready" | "complete" | "cancelled" | string;
export type TrackedKind = "adhoc" | "issue" | "workflow" | string;

export interface DecisionLogEntry {
	ts: string;
	prompt_tag: string;
	answer: string;
	[key: string]: unknown;
}

export interface TrackedSessionAdapter {
	pi_bridge_pid?: number | null;
	pi_bridge_socket?: string | null;
	pi_session_id?: string | null;
	oc_url?: string | null;
	oc_session_id?: string | null;
	oc_port?: number | null;
	cc_url?: string | null;
	cc_session_uuid?: string | null;
	cc_transcript?: string | null;
	cc_port?: number | null;
	cx_ws?: string | null;
	cx_thread_id?: string | null;
	[key: string]: unknown;
}

export interface TrackedIssueDomain {
	id: string;
	worktree?: string | null;
	pr_number?: number | null;
	scope_files_declared?: number | null;
	scope_files_actual?: number | null;
	orchestration_started?: boolean | null;
	merge_commit?: string | null;
	[key: string]: unknown;
}

export interface TrackedSessionDomain {
	issue?: TrackedIssueDomain;
	[key: string]: unknown;
}

export interface TrackedSessionLaunch {
	model?: string | null;
	effort?: string | null;
	cmd?: string | null;
	[key: string]: unknown;
}

export interface TrackedSession {
	id: string;
	title?: string | null;
	kind: TrackedKind;
	/** @deprecated Use id/title plus domain.issue when issue-mode metadata is needed. */
	issue: string;
	window?: string;
	pane_target?: string;
	harness?: string;
	cwd?: string | null;
	worktree?: string;
	pr_number?: number | null;
	// Immutable tmux pane id (`%N`) captured by `pane-registry init`.
	// `pane-registry reconcile` backfills it when an older entry is
	// missing the field.
	pane_id?: string | null;
	launch?: TrackedSessionLaunch | null;
	adapter?: TrackedSessionAdapter | null;
	domain?: TrackedSessionDomain | null;
	state?: TrackedState | null;
	substate?: string | null;
	unknown_since?: string | null;
	last_capture_hash?: string | null;
	last_response_at?: string | null;
	spawned_at?: string | null;
	last_polled_at?: string | null;
	orchestration_started?: boolean;
	scope_files_declared?: number | null;
	scope_files_actual?: number | null;
	decisions_log?: DecisionLogEntry[];
	// Captured by close-issue.md § 3 / merge-plan.md § 3 when a PR lands; the
	// post-completion dashboard surfaces it in Overview and the merge-history
	// pane of the Conflicts & merges tab.
	merge_commit?: string | null;
	[key: string]: unknown;
}

/** @deprecated Use TrackedState. Kept for one release cycle. */
export type IssueState = TrackedState;

/** @deprecated Use TrackedSession. Kept for one release cycle. */
export type IssueRecord = TrackedSession;

export function trackedIssueDomain(session: TrackedSession | undefined): TrackedIssueDomain | undefined {
	const domain = session?.domain?.issue;
	if (!domain || typeof domain !== "object" || Array.isArray(domain)) return undefined;
	const id = typeof domain.id === "string" && domain.id.trim() ? domain.id.trim() : undefined;
	return id ? { ...domain, id } : undefined;
}

export function isIssueSession(session: TrackedSession | undefined): boolean {
	return session?.kind === "issue" || Boolean(trackedIssueDomain(session));
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
	entries?: Record<string, TrackedSession>;
	issues: Record<string, TrackedSession>;
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
	// Set of pane ids currently alive in tmux (`tmux list-panes -a`).
	// Captured once per snapshot tick so the renderer can mark tracked
	// entries whose `pane_id` has been closed in tmux without forcing a
	// daemon respawn or manual archive. Empty set when not inside tmux
	// or when the lookup fails — callers treat absence as "unknown" and
	// must not flag entries as gone.
	livePaneIds: Set<string>;
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

export function resetTmuxContextCacheForTests(): void {
	TMUX_CONTEXT_CACHE = undefined;
	TMUX_CONTEXT_RESOLVED = false;
}

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
	// master state file, falsely showing "0 sessions" (#4 finding 3).
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

function isRecord(value: unknown): value is Record<string, unknown> {
	return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

function stringValue(value: unknown): string | undefined {
	return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function nullableString(value: unknown): string | null | undefined {
	if (value === null) return null;
	return stringValue(value);
}

function nullableNumber(value: unknown): number | null | undefined {
	if (value === null) return null;
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function nullableBoolean(value: unknown): boolean | null | undefined {
	if (value === null) return null;
	return typeof value === "boolean" ? value : undefined;
}

function normalizeIssueDomain(raw: unknown, fallbackId: string | undefined): TrackedIssueDomain | undefined {
	const source = isRecord(raw) ? raw : {};
	const id = stringValue(source.id) ?? fallbackId;
	if (!id) return undefined;
	return {
		...source,
		id,
		merge_commit: nullableString(source.merge_commit),
		orchestration_started: nullableBoolean(source.orchestration_started),
		pr_number: nullableNumber(source.pr_number),
		scope_files_actual: nullableNumber(source.scope_files_actual),
		scope_files_declared: nullableNumber(source.scope_files_declared),
		worktree: nullableString(source.worktree),
	};
}

function normalizeTrackedSession(key: string, value: Record<string, unknown>): TrackedSession {
	const id = stringValue(value.id) ?? key;
	const domainSource = isRecord(value.domain) ? value.domain : {};
	const issueDomain = normalizeIssueDomain(domainSource.issue, undefined);
	const domain = issueDomain ? { ...domainSource, issue: issueDomain } : Object.keys(domainSource).length > 0 ? domainSource : undefined;
	const kind = issueDomain ? "issue" : stringValue(value.kind) ?? "adhoc";
	const issue = issueDomain?.id ?? id;
	const record: TrackedSession = {
		...value,
		decisions_log: normalizeDecisionsLog(value.decisions_log),
		domain,
		id,
		issue,
		kind,
		state: nullableString(value.state) as TrackedState | null | undefined,
		title: nullableString(value.title),
	};
	if (issueDomain) {
		record.worktree = issueDomain.worktree ?? record.worktree;
		record.pr_number = issueDomain.pr_number ?? record.pr_number;
		record.scope_files_declared = issueDomain.scope_files_declared ?? record.scope_files_declared;
		record.scope_files_actual = issueDomain.scope_files_actual ?? record.scope_files_actual;
		record.orchestration_started = issueDomain.orchestration_started ?? record.orchestration_started;
		record.merge_commit = issueDomain.merge_commit ?? record.merge_commit;
	}
	return record;
}

function readEntriesRecord(raw: unknown): Record<string, TrackedSession> {
	const out: Record<string, TrackedSession> = {};
	if (Array.isArray(raw)) {
		for (const value of raw) {
			if (!isRecord(value)) continue;
			const id = stringValue(value.id);
			if (!id) continue;
			out[id] = normalizeTrackedSession(id, value);
		}
		return out;
	}
	if (!isRecord(raw)) return out;
	for (const [id, value] of Object.entries(raw)) {
		if (isRecord(value)) out[id] = normalizeTrackedSession(id, value);
	}
	return out;
}

function normalizeSessionMap(raw: Record<string, TrackedSession> | undefined): Record<string, TrackedSession> {
	const out: Record<string, TrackedSession> = {};
	for (const [id, value] of Object.entries(raw ?? {})) {
		if (isRecord(value)) out[id] = normalizeTrackedSession(id, value);
	}
	return out;
}

function projectIssuesFromEntries(entries: Record<string, TrackedSession>): Record<string, TrackedSession> {
	const issues: Record<string, TrackedSession> = {};
	for (const entry of Object.values(entries)) {
		const issueId = entry.domain?.issue?.id;
		if (issueId && !issues[issueId]) issues[issueId] = entry;
	}
	return issues;
}

export function readMasterState(path: string): { state?: MasterState; error?: string } {
	if (!existsSync(path)) return {};
	try {
		const text = readFileSync(path, "utf8");
		if (!text.trim()) return { state: emptyState() };
		const parsed = JSON.parse(text);
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return { error: "master state JSON is not an object" };
		const raw = parsed as Partial<MasterState> & { entries?: unknown; issues?: unknown };
		const entries = readEntriesRecord(raw.entries);
		// Pre-purge state files only have `.issues` (no `.entries`). Fail
		// loud rather than rendering an empty dashboard: the operator needs
		// to archive the file and let `flightdeck-session start` rewrite it
		// in the canonical shape.
		if (Object.keys(entries).length === 0 && isRecord(raw.issues) && Object.keys(raw.issues).length > 0) {
			return { error: "state file uses pre-purge `.issues` schema with no `.entries`; archive it manually and rerun `flightdeck session start`" };
		}
		const issues = projectIssuesFromEntries(entries);
		return {
			state: {
				conflict_graph: normalizeConflictGraph(raw.conflict_graph),
				entries,
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
		entries: {},
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
export function readOwnerVisibilityProbe(cwd: string, settings: SettingsLike, tmuxOverride?: TmuxContext): OwnerVisibilityProbe | undefined {
	const tmux = tmuxOverride ?? resolveTmuxContext();
	if (!tmux) return undefined;
	const projectRoot = resolveProjectRoot(cwd);
	const active = resolveActiveRunStatePath(projectRoot, tmux.sessionName);
	if (active.error) return { tmux };
	const path = active.statePath ?? masterStatePath(projectRoot, settings, tmux.sessionName);
	const { state } = readMasterState(path);
	return { ownerPaneId: state?.owner?.pane_id, tmux };
}

function readLivePaneIds(): Set<string> {
	if (!process.env.TMUX) return new Set();
	const r = spawnSync("tmux", ["list-panes", "-a", "-F", "#{pane_id}"], { encoding: "utf8", timeout: 1500 });
	const out = new Set<string>();
	if (r.status !== 0) return out;
	for (const line of (r.stdout ?? "").split("\n")) if (line) out.add(line);
	return out;
}

// True when the tracked entry has a `pane_id` but tmux no longer lists
// it as alive. Used by the dashboard to render a `pane gone` chip.
// Returns false when `livePaneIds` is empty
// (unknown / not inside tmux) so the chip never fires on cold startup.
export function isPaneGone(session: TrackedSession | undefined, snapshot: FlightdeckSnapshot | undefined): boolean {
	if (!session || !snapshot) return false;
	const paneId = typeof session.pane_id === "string" ? session.pane_id : "";
	if (!paneId) return false;
	const live = snapshot.livePaneIds;
	if (!live || live.size === 0) return false;
	return !live.has(paneId);
}

// Awaiting-watch should only count entries whose immutable tmux pane id is
// still present. Empty `livePaneIds` means the probe is unavailable/unknown, so
// keep legacy behavior and do not suppress the banner on lack of evidence.
export function readAwaitingWatchTrackedEntries(snapshot: FlightdeckSnapshot | undefined): TrackedSession[] {
	const entries = readTrackedEntries(snapshot?.master);
	const live = snapshot?.livePaneIds;
	if (!live || live.size === 0) return entries;
	return entries.filter((entry) => {
		const paneId = typeof entry.pane_id === "string" ? entry.pane_id.trim() : "";
		return !paneId || live.has(paneId);
	});
}

export function buildSnapshotFromInputs(inputs: BuildSnapshotInputs, settings: SettingsLike, options?: { logTailLines?: number; wakeEventsLines?: number }): FlightdeckSnapshot {
	const { projectRoot, stateDir, tmux } = inputs;
	const active = resolveActiveRunStatePath(projectRoot, tmux.sessionName);
	const liveStatePath = active.statePath ?? masterStatePath(projectRoot, settings, tmux.sessionName);
	let resolvedStatePath = liveStatePath;
	let archiveError = false;
	let { state, error } = active.error ? { state: undefined, error: active.error } : readMasterState(liveStatePath);
	if (active.error && active.diagnosticPath) resolvedStatePath = active.diagnosticPath;
	if (active.statePath && !state && !error && !existsSync(active.statePath)) {
		error = `active run state missing: ${active.statePath}`;
		resolvedStatePath = active.statePath;
	}
	// Archive fallback (issue #17 BLOCKER #1, refined in rounds 3 and 4).
	// When the live file is missing, walk the master-state directory's
	// terminated archives newest-first and serve the first VALID
	// `terminated: true` snapshot. STRICT validation: blank archives,
	// readable-but-non-terminated archives, malformed JSON, and IO
	// failures all count as failures with their own reason strings.
	// A non-ENOENT readdir error (permission denied / IO) also surfaces
	// as a diagnostic so the user sees "state was lost" instead of
	// silently falling back to inactive. Live state always wins when
	// present, so the fallback never shadows an in-flight session. The
	// durable active-run pointer also wins when present, even if its
	// current state is empty; archived runs are history, not live widget
	// input.
	if (!state && !error && !active.statePath) {
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
		livePaneIds: readLivePaneIds(),
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

// Normalization seam. The dashboard / render code reads tracked sessions
// via this helper instead of reaching into `state.entries` directly.
export function readTrackedEntries(state: MasterState | undefined): TrackedSession[] {
	return sortedTrackedEntries(state);
}

export function findTrackedEntry(state: MasterState | undefined, id: string | undefined | null): TrackedSession | undefined {
	const needle = typeof id === "string" ? id.trim() : "";
	if (!needle) return undefined;
	return readTrackedEntries(state).find((entry) => entry.id === needle || entry.issue === needle || entry.domain?.issue?.id === needle);
}

export function isFlightdeckActive(snapshot: FlightdeckSnapshot | undefined): boolean {
	if (!snapshot) return false;
	if (snapshot.master && !snapshot.master.terminated && readTrackedEntries(snapshot.master).length > 0) return true;
	if (snapshot.daemon.pidAlive) return true;
	return false;
}

// Terminated archive snapshots are preserved for explicit readers, but the
// Pi mini-dashboard is active-run-only. Completed history belongs in the Rust
// app/history surface, not in the default inline status widget.
// `state-error`: the live master-state file exists but failed to read or
// parse. Renders an error banner with the path/diagnostic instead of clearing
// the widget as inactive.
// `archive-error`: a terminated archive was selected but every candidate
// failed to parse. Renders an error banner with the diagnostic so the
// user sees "state was lost" instead of a blank "no session" view
// (BLOCK round 3).
// `awaiting-watch`: tracked sessions exist but the daemon has never
// been started for this tmux session (no pid file, no heartbeat file).
// Normal state between `session start` and `session watch`. Distinct
// from `stale` so the dashboard can show a friendly hint instead of a
// red "daemon dead" + "restart" framing that implies something broke.
export type FlightdeckSessionStatus = "live" | "awaiting-watch" | "stale" | "inactive" | "state-error" | "archive-error";

// True when the daemon has ever been started for this tmux session
// (pid file exists OR heartbeat file exists). Used by the daemon-health
// chip and the session-status predicate to distinguish "never started"
// from "started and died".
export function daemonEverStarted(snapshot: FlightdeckSnapshot | undefined): boolean {
	const d = snapshot?.daemon;
	if (!d) return false;
	if (d.pidAlive) return true;
	if (d.pid !== undefined && d.pid !== null) return true;
	if (d.heartbeatExists) return true;
	return false;
}

const TERMINAL_TRACKED_STATES = new Set<TrackedState>(["merged", "aborted", "dead", "complete", "cancelled"]);
const DASHBOARD_ENTRY_ID = "flightdeck-dashboard";

// Most recent `last_polled_at` (ms epoch) across non-terminal sessions. Used
// by both the stale-state predicate and the stale-hint renderer.
export function mostRecentPollMs(snapshot: FlightdeckSnapshot | undefined): number | undefined {
	let best: number | undefined;
	for (const entry of readTrackedEntries(snapshot?.master)) {
		if (entry.state && TERMINAL_TRACKED_STATES.has(entry.state)) continue;
		const t = Date.parse(entry.last_polled_at ?? "");
		if (!Number.isFinite(t)) continue;
		if (best === undefined || t > best) best = t;
	}
	return best;
}

// Classify a snapshot for the dashboard renderer. A state file with
// non-terminal sessions and no live daemon is treated as `stale` once the
// most recent poll is older than `staleAfterMin` minutes — past that
// window the daemon is not coming back on its own and the dashboard would
// otherwise render leftover data from a prior session. Pass
// `staleAfterMin: 0` to disable the staleness check entirely
// (matches `isFlightdeckActive` behavior, leftover-data tolerant).
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
	if (snapshot.masterError) return "state-error";
	const master = snapshot.master;
	const hasAnySessions = readTrackedEntries(master).length > 0;
	if (master?.terminated && hasAnySessions) return "inactive";
	const hasLiveSessions = !!master && !master.terminated && hasAnySessions;
	const daemonAlive = snapshot.daemon.pidAlive;
	if (!hasLiveSessions && !daemonAlive) return "inactive";
	if (daemonAlive) return "live";
	// Daemon never started for this tmux session — normal state between
	// `session start` and `session watch`. Don't flag as stale; the user
	// hasn't tried to supervise yet. But if tmux proves every tracked
	// pane_id is dead, the leftover state is stale-only and should not
	// render a misleading "start supervising" hint.
	if (!daemonEverStarted(snapshot)) return readAwaitingWatchTrackedEntries(snapshot).length > 0 ? "awaiting-watch" : "inactive";
	const staleAfterMin = options?.staleAfterMin ?? 5;
	if (staleAfterMin <= 0) return "live";
	const now = options?.now ?? Date.now();
	const latest = mostRecentPollMs(snapshot);
	if (latest === undefined) return "stale";
	const ageSec = Math.max(0, Math.floor((now - latest) / 1000));
	return ageSec > staleAfterMin * 60 ? "stale" : "live";
}

// Merged issue-mode sessions, newest-merge-first by `last_polled_at`, used by the
// Conflicts & merges tab to render a stable "Merge history" panel that
// outlives the live `merge_queue` (which drains as items land).
export function mergedIssueHistory(state: MasterState | undefined): TrackedSession[] {
	const merged = readTrackedEntries(state).filter((entry) => isIssueSession(entry) && entry.state === "merged");
	merged.sort((a, b) => {
		const at = Date.parse(a.last_polled_at ?? a.spawned_at ?? "");
		const bt = Date.parse(b.last_polled_at ?? b.spawned_at ?? "");
		if (Number.isFinite(at) && Number.isFinite(bt) && at !== bt) return bt - at;
		return sessionSortLabel(a).localeCompare(sessionSortLabel(b));
	});
	return merged;
}

export function sortedTrackedEntries(state: MasterState | undefined): TrackedSession[] {
	if (!state) return [];
	const entries = normalizeSessionMap(state.entries);
	return Object.entries(entries)
		.filter(([key, entry]) => key !== DASHBOARD_ENTRY_ID && entry.id !== DASHBOARD_ENTRY_ID)
		.map(([, entry]) => entry)
		.sort((a, b) => {
			const aTs = a.spawned_at ?? "";
			const bTs = b.spawned_at ?? "";
			if (aTs && bTs && aTs !== bTs) return aTs.localeCompare(bTs);
			return sessionSortLabel(a).localeCompare(sessionSortLabel(b));
		});
}


/** @deprecated Use sortedTrackedEntries/readTrackedEntries. */
export function sortedIssues(state: MasterState | undefined): TrackedSession[] {
	return sortedTrackedEntries(state);
}

function sessionSortLabel(entry: TrackedSession): string {
	return (typeof entry.title === "string" && entry.title.trim()) || entry.id || entry.issue;
}

export function flatDecisionsLog(state: MasterState | undefined, max = 200): Array<{ issue: string; session: string; ts: string; prompt_tag: string; answer: string }> {
	const out: Array<{ issue: string; session: string; ts: string; prompt_tag: string; answer: string }> = [];
	for (const session of readTrackedEntries(state)) {
		const label = sessionSortLabel(session);
		for (const entry of session.decisions_log ?? []) {
			out.push({ answer: entry.answer, issue: label, prompt_tag: entry.prompt_tag, session: label, ts: entry.ts });
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
