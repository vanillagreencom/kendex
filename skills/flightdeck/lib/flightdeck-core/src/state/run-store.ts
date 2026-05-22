import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
	copyFileSync,
	existsSync,
	lstatSync,
	mkdirSync,
	readdirSync,
	readFileSync,
	realpathSync,
	renameSync,
	rmSync,
	statSync,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { loadDotEnvIntoProcess, resolveProjectRoot } from "../shared/project.ts";
import { lockedMigrateLegacyIntoRun, withFlockHeldSync } from "./locking.ts";

export const RUN_STORE_SCHEMA_VERSION = 1;
export const MAX_LEGACY_ACTIVITY_ARCHIVE_BYTES = 50 * 1024 * 1024;

export interface ProjectIndex {
	schema_version: 1;
	project_id: string;
	name: string;
	root_path: string;
	root_hash: string;
	remote_url: string | null;
	id_source: "git-remote+root" | "root";
	created_at: string;
	last_seen_at: string;
}

export interface ActiveRunPointer {
	schema_version: 1;
	project_id: string;
	run_id: string;
	tmux_session: string;
	state_path: string;
	activity_path: string;
	updated_at: string;
}

export interface RunMetadata {
	schema_version: 1;
	project_id: string;
	run_id: string;
	project_root: string;
	tmux_session: string;
	state_path: string;
	activity_path: string;
	summary_path: string | null;
	snapshots_path: string;
	started_at: string;
	last_seen_at: string;
	terminated: boolean;
	terminated_at: string | null;
	imported: boolean;
	imported_from: string | null;
	legacy_activity_path: string | null;
}

export interface ProjectRunPaths {
	store_root: string;
	project_dir: string;
	project_json: string;
	active_run_json: string;
	runs_dir: string;
	project_lock: string;
}

export interface RunPaths {
	run_dir: string;
	metadata_json: string;
	state_json: string;
	activity_jsonl: string;
	summary_md: string;
	snapshots_dir: string;
}

export interface RunCreateResult {
	project: ProjectIndex;
	active: ActiveRunPointer;
	metadata: RunMetadata;
	paths: RunPaths;
}

export interface RunShowResult {
	metadata: RunMetadata;
	state: unknown;
	activity_path: string;
	snapshot: string | null;
	snapshots: string[];
}

export interface RunTerminateResult {
	metadata: RunMetadata;
	active_cleared: boolean;
	snapshot_path: string;
	activity_snapshot_path: string | null;
}

export interface RunEnsureResult {
	project: ProjectIndex;
	active: ActiveRunPointer;
	metadata: RunMetadata;
	paths: RunPaths;
	action: "created" | "reused" | "created-after-terminated" | "created-after-stale";
	previous_run_id: string | null;
	previous_termination: RunTerminateResult | null;
	legacy_archive_path: string | null;
}

export interface ActiveRunTerminateResult {
	project: ProjectIndex | null;
	active: ActiveRunPointer | null;
	terminated: RunTerminateResult | null;
	reason: "terminated" | "no-active-run" | "session-mismatch";
	diagnostic?: string;
}

export interface RunTerminateOptions {
	stateDir?: string;
	summaryPath?: string;
	syncLegacy?: boolean;
	tmuxSession?: string;
}

interface StaleActiveRunCheck {
	stale: boolean;
	reason: "no-entries" | "no-pane-ids" | "all-panes-missing" | "live-pane-found" | "tmux-query-failed";
	paneIds: string[];
	error?: string;
}

interface LivePaneIdsResult {
	ok: boolean;
	panes: Set<string>;
	error?: string;
}

interface StagedSummaryCopy {
	finalPath: string;
	stagedPath: string;
}

export interface LegacyImportResult {
	project: ProjectIndex;
	state_dir: string;
	imported: RunMetadata[];
	skipped: RunMetadata[];
	diagnostics: string[];
}

interface ProjectIdentity {
	project_id: string;
	name: string;
	root_path: string;
	root_hash: string;
	remote_url: string | null;
	id_source: "git-remote+root" | "root";
}

interface ProjectLockContext {
	identity: ProjectIdentity;
	paths: ProjectRunPaths;
	root: string;
}

interface NormalizedTimestamp {
	basename: string;
	iso: string;
}

interface LegacyArchiveName {
	session: string;
	terminatedAt: string;
}

const JSON_MISSING = Symbol("json-missing");
type JsonMissing = typeof JSON_MISSING;

function nowIso(): string {
	return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

function sha256(value: string): string {
	return createHash("sha256").update(value).digest("hex");
}

function safeSegment(value: string, fallback = "project"): string {
	const cleaned = value.trim().toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48);
	return cleaned || fallback;
}

function storeHome(): string {
	return process.env.HOME && process.env.HOME.trim() ? process.env.HOME.trim() : homedir();
}

// vstack#227: tests can override the run-store root with
// FLIGHTDECK_RUN_STORE_ROOT to point at an isolated tmpdir. Production
// callers leave it unset and use `$HOME/.vstack/flightdeck`.
//
// The override is absolutized before use so a relative path doesn't
// silently redirect writes into the current working directory. Ancestor
// symlinks/permissions are validated lazily by
// `ensureStoreDirSecurity()` when paths are created or touched (see
// `withProjectLock`).
export function flightdeckRunStoreRoot(): string {
	const override = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	if (typeof override === "string" && override.trim()) return resolve(override.trim());
	return join(storeHome(), ".vstack", "flightdeck");
}

// vstack#227: store directories are private (0700) and files are 0600.
// We also fail closed if an existing directory is a symlink, owned by a
// different uid, or readable/writable by group or other. These checks
// also catch a project/env-controlled override that redirects writes
// outside the intended root by way of a symlinked ancestor.
const STORE_DIR_MODE = 0o700;
const STORE_FILE_MODE = 0o600;

function currentUidOrNull(): number | null {
	const fn = (process as unknown as { getuid?: () => number }).getuid;
	return typeof fn === "function" ? fn.call(process) : null;
}

// vstack#227 round-2: store mode policy. We create everything at
// strict perms (`0700` dirs, `0600` files). Reads enforce:
//   - Files (strict): exact `0600` + uid ownership. Token-bearing
//     payloads (`state.json`, `activity.jsonl`, lock files) must
//     never relax to group/other-readable.
//   - Dirs (ancestor): uid ownership + no group/other WRITE bits.
//     Read bits are tolerated because the inner files are still
//     `0600`, and dev installations from before this commit had
//     `0755` dirs created under the default umask — refusing those
//     would break every existing project on first contact.
//
// Tampering (group/other write on any path) still fails closed.
type StoreOwnershipPolicy = "strict" | "ancestor";

function assertStoreOwnership(stat: { uid?: number; mode: number; isFile?: () => boolean; isDirectory?: () => boolean }, path: string, label: string, policy: StoreOwnershipPolicy = "strict"): void {
	const uid = currentUidOrNull();
	if (uid !== null && typeof stat.uid === "number" && stat.uid !== uid) {
		throw new Error(`invalid ${label} ${path}: owned by uid ${stat.uid}, not ${uid}`);
	}
	const masked = stat.mode & 0o777;
	const isDir = typeof stat.isDirectory === "function" ? stat.isDirectory() : false;
	// All paths: reject group/other WRITE (CWE-732).
	if ((masked & 0o022) !== 0) {
		throw new Error(`invalid ${label} ${path}: group/other write bits set (mode=${masked.toString(8)})`);
	}
	if (policy === "ancestor" || isDir) {
		// Dir or wrapper: ownership + no-write is sufficient.
		return;
	}
	// File strict path: require exact 0600 (CWE-276). Read bits on
	// state.json or activity.jsonl would expose cc_channel_token,
	// transcripts, and other sensitive payloads.
	if (masked !== STORE_FILE_MODE) {
		throw new Error(`invalid ${label} ${path}: mode=${masked.toString(8)} expected ${STORE_FILE_MODE.toString(8)}`);
	}
}

function ensureStoreDir(path: string, label: string, policy: StoreOwnershipPolicy = "strict"): void {
	let stat: ReturnType<typeof lstatSync> | null = null;
	try {
		stat = lstatSync(path);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
	}
	if (stat) {
		if (stat.isSymbolicLink()) throw new Error(`invalid ${label} ${path}: symlinks are not allowed`);
		if (!stat.isDirectory()) throw new Error(`invalid ${label} ${path}: expected directory`);
		assertStoreOwnership(stat, path, label, policy);
		return;
	}
	mkdirSync(path, { mode: STORE_DIR_MODE, recursive: false });
	chmodSyncSafe(path, STORE_DIR_MODE);
	try {
		const created = lstatSync(path);
		const masked = created.mode & 0o777;
		if (masked !== STORE_DIR_MODE) {
			throw new Error(`invalid ${label} ${path}: mode=${masked.toString(8)} expected ${STORE_DIR_MODE.toString(8)} (chmod did not take effect)`);
		}
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
	}
}

function ensureStoreFile(path: string, label: string): void {
	let stat: ReturnType<typeof lstatSync> | null = null;
	try {
		stat = lstatSync(path);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
		throw error;
	}
	if (!stat) return;
	if (stat.isSymbolicLink()) throw new Error(`invalid ${label} ${path}: symlinks are not allowed`);
	if (!stat.isFile()) throw new Error(`invalid ${label} ${path}: expected regular file`);
	// vstack#227 round-2: strict mode/ownership check. We do NOT
	// auto-chmod existing files here — wider perms are treated as
	// tampering and surfaced to the operator (CWE-732/CWE-276).
	assertStoreOwnership(stat, path, label);
}

function chmodSyncSafe(path: string, mode: number): void {
	try {
		(require("node:fs") as typeof import("node:fs")).chmodSync(path, mode);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
		throw error;
	}
}

// vstack#227 round-2: create the run-store root + `projects/` chain
// under strict ownership/perm checks so the per-project lock acquired
// below cannot be redirected via a symlinked ancestor (CWE-22/CWE-59).
//
// Algorithm:
//   1. Walk every ancestor of `root` from `/` downward with `lstat`.
//      Reject any symlink in the chain — `mkdir -p` would otherwise
//      follow the symlink and silently redirect writes.
//   2. Create missing components one at a time with `0700`, NOT
//      `recursive: true`.
//   3. Apply strict ownership/mode checks to `root`, `root/projects`,
//      and (if it already exists) `projectDir`.
function ensureStoreRootChain(projectDir: string): void {
	const root = flightdeckRunStoreRoot();
	ensureSafeAncestorChain(root, "run-store root");
	createOneAtATime(root, "run-store root");
	// `root` (e.g. `~/.vstack/flightdeck`) and `<root>/projects/` are
	// the wrapper dirs — they may pre-exist at the user's default
	// umask (`0755`). Enforce ownership + no-group/other-write
	// strictly, but tolerate read bits. The leaf dirs that hold tokens
	// (`projects/<id>/runs/<run-id>/`) are still required to be
	// exactly `0700`.
	ensureStoreDir(root, "run-store root", "ancestor");
	const projects = join(root, "projects");
	createOneAtATime(projects, "run-store projects dir");
	ensureStoreDir(projects, "run-store projects dir", "ancestor");
	const realRoot = realpathSync(root);
	const realProjects = realpathSync(projects);
	if (!isPathInside(realRoot, realProjects)) {
		throw new Error(`invalid run-store projects dir ${projects}: escapes ${root}`);
	}
	if (existsSync(projectDir)) {
		const realProject = realpathSync(projectDir);
		if (!isPathInside(realProjects, realProject)) {
			throw new Error(`invalid project directory ${projectDir}: escapes ${projects}`);
		}
	}
}

// Walk every existing ancestor of `target` from the filesystem root
// downward and reject any symlink. Stops at the first missing
// component; `createOneAtATime` then creates the remainder under
// `0700` with each new component re-validated.
function ensureSafeAncestorChain(target: string, label: string): void {
	if (!isAbsolute(target)) throw new Error(`invalid ${label} ${target}: must be an absolute path`);
	const segments = target.split("/").filter((s) => s.length > 0);
	let current = "/";
	for (const segment of segments) {
		current = current === "/" ? `/${segment}` : `${current}/${segment}`;
		let stat: ReturnType<typeof lstatSync> | null = null;
		try {
			stat = lstatSync(current);
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
			throw error;
		}
		if (stat.isSymbolicLink()) {
			throw new Error(`invalid ${label} ${target}: ancestor ${current} is a symlink (CWE-22/CWE-59)`);
		}
		if (!stat.isDirectory()) {
			throw new Error(`invalid ${label} ${target}: ancestor ${current} is not a directory`);
		}
	}
}

function createOneAtATime(target: string, label: string): void {
	if (!isAbsolute(target)) throw new Error(`invalid ${label} ${target}: must be an absolute path`);
	const segments = target.split("/").filter((s) => s.length > 0);
	let current = "/";
	for (const segment of segments) {
		current = current === "/" ? `/${segment}` : `${current}/${segment}`;
		let stat: ReturnType<typeof lstatSync> | null = null;
		try {
			stat = lstatSync(current);
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
		}
		if (stat) {
			if (stat.isSymbolicLink()) {
				throw new Error(`invalid ${label} ${target}: ancestor ${current} is a symlink`);
			}
			continue;
		}
		mkdirSync(current, { mode: STORE_DIR_MODE });
		chmodSyncSafe(current, STORE_DIR_MODE);
	}
}

export function canonicalProjectRoot(projectRoot: string = process.cwd()): string {
	const root = resolveProjectRoot(resolve(projectRoot));
	loadDotEnvIntoProcess(root);
	return root;
}

export function resolveProjectRunPaths(project: ProjectIndex | ProjectIdentity): ProjectRunPaths {
	const storeRoot = flightdeckRunStoreRoot();
	const projectDir = join(storeRoot, "projects", project.project_id);
	return {
		active_run_json: join(projectDir, "active-run.json"),
		project_dir: projectDir,
		project_json: join(projectDir, "project.json"),
		project_lock: join(projectDir, ".project.lock"),
		runs_dir: join(projectDir, "runs"),
		store_root: storeRoot,
	};
}

export function resolveRunPaths(paths: ProjectRunPaths, runId: string): RunPaths {
	const runDir = join(paths.runs_dir, safeRunId(runId));
	return {
		activity_jsonl: join(runDir, "activity.jsonl"),
		metadata_json: join(runDir, "metadata.json"),
		run_dir: runDir,
		snapshots_dir: join(runDir, "snapshots"),
		state_json: join(runDir, "state.json"),
		summary_md: join(runDir, "summary.md"),
	};
}

export function legacyStateDir(projectRoot: string, stateDir?: string): string {
	const root = canonicalProjectRoot(projectRoot);
	return legacyStateDirForRoot(root, stateDir);
}

export function legacyStatePath(projectRoot: string, tmuxSession: string, stateDir?: string): string {
	return join(legacyStateDir(projectRoot, stateDir), `flightdeck-state-${safeLegacySessionName(tmuxSession)}.json`);
}

export function legacyActivityPath(projectRoot: string, tmuxSession: string, stateDir?: string): string {
	// vstack#227: explicitly returns the prefixed legacy form so callers
	// migrating off project-local tmp/ files still find them. The unified
	// path is `<run-dir>/activity.jsonl`; resolveActivityPath / the
	// active-run pointer expose that.
	return join(legacyStateDir(projectRoot, stateDir), `flightdeck-activity-${safeLegacySessionName(tmuxSession)}.jsonl`);
}

export function resolveProjectIdentity(projectRoot: string): ProjectIdentity {
	return projectIdentityForRoot(canonicalProjectRoot(projectRoot));
}

export function ensureProjectIndex(projectRoot: string, timestamp = nowIso()): { project: ProjectIndex; paths: ProjectRunPaths } {
	return withProjectLock(projectRoot, (ctx) => ensureProjectIndexLocked(ctx, timestamp));
}

export function loadProjectIndex(projectRoot: string): { project: ProjectIndex; paths: ProjectRunPaths } | null {
	return withProjectLock(projectRoot, (ctx) => loadProjectIndexLocked(ctx));
}

export function createRun(projectRoot: string, tmuxSession: string, stateDir?: string): RunCreateResult {
	const session = safeLegacySessionName(requireNonEmpty(tmuxSession, "tmux session"));
	return withProjectLock(projectRoot, (ctx) => createRunLocked(ctx, session, stateDir));
}

export interface EnsureActiveRunOptions {
	stateDir?: string;
	// vstack#227: lifecycle callers (flightdeck-session start, attach)
	// run the tmux pane-liveness check to detect orphan runs. Helper
	// callers (statePath/getField/setField from CLI verbs) skip it so
	// that a normal `flightdeck-state get` on a session whose tracked
	// panes are no longer alive doesn't surprise-rotate the run.
	checkStale?: boolean;
}

export function ensureActiveRun(projectRoot: string, tmuxSession: string, optionsOrStateDir?: EnsureActiveRunOptions | string): RunEnsureResult {
	const options = typeof optionsOrStateDir === "string"
		? { stateDir: optionsOrStateDir }
		: optionsOrStateDir ?? {};
	const stateDir = options.stateDir;
	const checkStale = options.checkStale === true;
	const session = safeLegacySessionName(requireNonEmpty(tmuxSession, "tmux session"));
	return withProjectLock(projectRoot, (ctx) => {
		const timestamp = nowIso();
		const loaded = ensureProjectIndexLocked(ctx, timestamp);
		const active = readActivePointer(loaded.paths.active_run_json);
		if (active === JSON_MISSING) {
			return ensureResult(createRunLocked(ctx, session, stateDir, timestamp), "created", null, null, null);
		}
		validateActivePointerProject(active, ctx.identity.project_id, loaded.paths.active_run_json);
		const activePaths = resolveRunPaths(loaded.paths, active.run_id);
		const metadata = readRunMetadataForRun(activePaths, ctx.identity.project_id, active.run_id, loaded.project.root_path);
		if (metadata === JSON_MISSING) {
			throw new Error(activeRunMissingMetadataMessage(loaded.paths.active_run_json, active, activePaths.metadata_json, loaded.project.root_path));
		}
		if (metadata.terminated) {
			markLegacyStateMigratedIfPresent(loaded.project.root_path, metadata.tmux_session, stateDir);
			return ensureResult(createRunLocked(ctx, session, stateDir, timestamp), "created-after-terminated", metadata.run_id, null, null);
		}
		if (active.tmux_session !== session || metadata.tmux_session !== session) {
			throw new Error(activeRunSessionMismatchMessage(loaded.paths.active_run_json, active, metadata, session));
		}
		if (checkStale) {
			const stale = checkActiveRunStale(loaded.project.root_path, metadata, activePaths, stateDir);
			if (stale.reason === "tmux-query-failed") {
				throw new Error(activeRunLivenessUnknownMessage(loaded.paths.active_run_json, metadata, session, stale));
			}
			if (stale.stale) {
				const terminated = terminateRunLocked(ctx, loaded, metadata.run_id, { stateDir, syncLegacy: true, tmuxSession: metadata.tmux_session });
				markLegacyStateMigratedIfPresent(loaded.project.root_path, metadata.tmux_session, stateDir);
				return ensureResult(createRunLocked(ctx, session, stateDir, timestamp), "created-after-stale", metadata.run_id, terminated, null);
			}
		}
		// vstack#227 migration shim: for live (non-stale) runs that
		// existed pre-change, the legacy `<project>/tmp/flightdeck-
		// state-<session>.json` may have continued receiving writes
		// while the run's state.json stayed at create-time content.
		// Copy newer legacy state/activity into the run dir, then mark
		// the legacy file as `.migrated` so we never re-import. The
		// rename is idempotent: subsequent calls find no legacy file.
		migrateLegacyStateIntoActiveRun(loaded.project.root_path, metadata.tmux_session, activePaths, stateDir);
		return ensureResult({ active, metadata, paths: activePaths, project: loaded.project }, "reused", metadata.run_id, null, null);
	});
}

export function readActiveRun(projectRoot: string): { project: ProjectIndex; active: ActiveRunPointer; metadata: RunMetadata | null } | null {
	return withProjectLock(projectRoot, (ctx) => {
		const loaded = loadProjectIndexLocked(ctx);
		if (!loaded) return null;
		const active = readActivePointer(loaded.paths.active_run_json);
		if (active === JSON_MISSING) return null;
		validateActivePointerProject(active, ctx.identity.project_id, loaded.paths.active_run_json);
		const runPaths = resolveRunPaths(loaded.paths, active.run_id);
		const metadata = readRunMetadataForRun(runPaths, ctx.identity.project_id, active.run_id, loaded.project.root_path);
		return { active, metadata: metadata === JSON_MISSING ? null : metadata, project: loaded.project };
	});
}

export function listRuns(projectRoot: string): { project: ProjectIndex; runs: RunMetadata[] } {
	return withProjectLock(projectRoot, (ctx) => {
		const loaded = loadProjectIndexLocked(ctx) ?? ensureProjectIndexLocked(ctx);
		const runs: RunMetadata[] = [];
		if (existsSync(loaded.paths.runs_dir)) {
			assertStorageDirectory(loaded.paths.runs_dir, "runs directory");
			for (const entry of readdirSync(loaded.paths.runs_dir)) {
				if (!isSafeBasename(entry)) continue;
				const metadata = readRunMetadataForRun(resolveRunPaths(loaded.paths, entry), ctx.identity.project_id, entry, loaded.project.root_path);
				if (metadata !== JSON_MISSING) runs.push(metadata);
			}
		}
		runs.sort((a, b) => (b.started_at || "").localeCompare(a.started_at || ""));
		return { project: loaded.project, runs };
	});
}

export function showRun(projectRoot: string, runId: string, snapshot?: string): RunShowResult {
	return withProjectLock(projectRoot, (ctx) => {
		const loaded = loadProjectIndexLocked(ctx);
		if (!loaded) throw new Error("project has no Flightdeck run store");
		const requestedRunId = safeRunId(runId);
		const paths = resolveRunPaths(loaded.paths, requestedRunId);
		const metadata = readRunMetadataForRun(paths, ctx.identity.project_id, requestedRunId, loaded.project.root_path);
		if (metadata === JSON_MISSING) throw new Error(`run not found: ${runId}`);
		const snapshotName = snapshot ? safeSnapshotName(snapshot) : null;
		const statePath = snapshotName ? safeSnapshotPath(paths.snapshots_dir, snapshotName) : paths.state_json;
		if (!existsSync(statePath)) throw new Error(snapshotName ? `snapshot not found: ${snapshot}` : `state not found for run: ${runId}`);
		assertRunStorageFile(paths, statePath, snapshotName ? "run snapshot" : "run state");
		const state = readStateObject(statePath, "run state");
		if (state === JSON_MISSING) throw new Error(snapshotName ? `snapshot not found: ${snapshot}` : `state not found for run: ${runId}`);
		return {
			activity_path: paths.activity_jsonl,
			metadata,
			snapshot: snapshotName,
			snapshots: listSnapshotFiles(paths.snapshots_dir),
			state,
		};
	});
}

export function terminateRun(projectRoot: string, runId: string, options: RunTerminateOptions = {}): RunTerminateResult {
	return withProjectLock(projectRoot, (ctx) => {
		const loaded = loadProjectIndexLocked(ctx);
		if (!loaded) throw new Error("project has no Flightdeck run store");
		return terminateRunLocked(ctx, loaded, runId, options);
	});
}

export function terminateActiveRun(projectRoot: string, tmuxSession: string, options: RunTerminateOptions = {}): ActiveRunTerminateResult {
	const session = safeLegacySessionName(requireNonEmpty(tmuxSession, "tmux session"));
	return withProjectLock(projectRoot, (ctx) => {
		const loaded = loadProjectIndexLocked(ctx);
		if (!loaded) return { active: null, project: null, reason: "no-active-run", terminated: null };
		const active = readActivePointer(loaded.paths.active_run_json);
		if (active === JSON_MISSING) return { active: null, project: loaded.project, reason: "no-active-run", terminated: null };
		validateActivePointerProject(active, ctx.identity.project_id, loaded.paths.active_run_json);
		const activePaths = resolveRunPaths(loaded.paths, active.run_id);
		const metadata = readRunMetadataForRun(activePaths, ctx.identity.project_id, active.run_id, loaded.project.root_path);
		if (metadata === JSON_MISSING) throw new Error(`run not found: ${active.run_id}`);
		if (active.tmux_session !== session) {
			return { active, diagnostic: `active pointer tmux_session=${active.tmux_session} requested_tmux_session=${session}`, project: loaded.project, reason: "session-mismatch", terminated: null };
		}
		if (metadata.tmux_session !== session) {
			return { active, diagnostic: runTmuxSessionMismatchMessage(metadata, session), project: loaded.project, reason: "session-mismatch", terminated: null };
		}
		const terminated = terminateRunLocked(ctx, loaded, active.run_id, { ...options, syncLegacy: true, tmuxSession: session });
		return { active, project: loaded.project, reason: "terminated", terminated };
	});
}

export function importLegacyArchives(projectRoot: string, stateDir?: string): LegacyImportResult {
	return withProjectLock(projectRoot, (ctx) => {
		const timestamp = nowIso();
		const { project, paths: projectPaths } = ensureProjectIndexLocked(ctx, timestamp);
		const dir = legacyStateDirForRoot(project.root_path, stateDir);
		const imported: RunMetadata[] = [];
		const skipped: RunMetadata[] = [];
		const diagnostics: string[] = [];
		if (!existsSync(dir)) return { diagnostics, imported, project, skipped, state_dir: dir };
		for (const entry of readdirSync(dir).sort()) {
			const parsedName = parseLegacyArchiveName(entry);
			if (!parsedName) continue;
			const archivePath = join(dir, entry);
			const state = readLegacyArchiveJson(archivePath, diagnostics);
			if (!state) continue;
			let session: string;
			let terminatedAt: NormalizedTimestamp;
			try {
				session = safeLegacySessionName(typeof state.session_id === "string" && state.session_id ? state.session_id : parsedName.session);
				const terminatedRaw = typeof state.terminated_at === "string" && state.terminated_at ? state.terminated_at : parsedName.terminatedAt;
				terminatedAt = normalizeTimestamp(terminatedRaw, `terminated_at in ${archivePath}`);
			} catch (error) {
				diagnostics.push(`skipped ${archivePath}: ${error instanceof Error ? error.message : String(error)}`);
				continue;
			}
			const startedAt = typeof state.started_at === "string" && state.started_at ? state.started_at : fileMtimeIso(archivePath);
			const runId = importedRunId(project.project_id, session, terminatedAt.iso, entry);
			const paths = resolveRunPaths(projectPaths, runId);
			const existing = readRunMetadataForRun(paths, project.project_id, runId, project.root_path);
			if (existing !== JSON_MISSING) {
				skipped.push(existing);
				continue;
			}
			ensureRunStorageDirectories(paths);
			const legacyActivity = resolveLegacyActivityArchive(state, archivePath, session, terminatedAt.basename, diagnostics);
			const normalizedState = { ...state, activity_path: paths.activity_jsonl, activity_archive_path: legacyActivity ? paths.activity_jsonl : null, session_id: session };
			writeJsonAtomic(paths.state_json, normalizedState);
			writeJsonAtomic(safeSnapshotPath(paths.snapshots_dir, `${terminatedAt.basename}.json`), normalizedState);
			if (legacyActivity) {
				copyFileAtomic(legacyActivity, paths.activity_jsonl);
				copyFileAtomic(legacyActivity, safeSnapshotPath(paths.snapshots_dir, `${terminatedAt.basename}.activity.jsonl`));
			} else {
				writeFileAtomic(paths.activity_jsonl, "");
			}
			const metadata: RunMetadata = {
				activity_path: paths.activity_jsonl,
				imported: true,
				imported_from: archivePath,
				last_seen_at: timestamp,
				legacy_activity_path: legacyActivity,
				project_id: project.project_id,
				project_root: project.root_path,
				run_id: runId,
				schema_version: RUN_STORE_SCHEMA_VERSION,
				snapshots_path: paths.snapshots_dir,
				started_at: startedAt,
				state_path: paths.state_json,
				summary_path: typeof state.summary_path === "string" && state.summary_path ? state.summary_path : null,
				terminated: true,
				terminated_at: terminatedAt.iso,
				tmux_session: session,
			};
			writeJsonAtomic(paths.metadata_json, metadata);
			imported.push(metadata);
		}
		return { diagnostics, imported, project, skipped, state_dir: dir };
	});
}

function withProjectLock<T>(projectRoot: string, fn: (ctx: ProjectLockContext) => T): T {
	const root = canonicalProjectRoot(projectRoot);
	const identity = projectIdentityForRoot(root);
	const paths = resolveProjectRunPaths(identity);
	// vstack#227: validate the run-store root + projects/ ancestors as
	// real (non-symlinked) user-owned directories before mkdir'ing the
	// per-project leaf. Prevents a symlinked ancestor from redirecting
	// state writes outside the intended root (CWE-22 / CWE-59).
	ensureStoreRootChain(paths.project_dir);
	mkdirSync(paths.project_dir, { mode: STORE_DIR_MODE, recursive: true });
	ensureStoreDir(paths.project_dir, "project directory");
	assertStorageDirectory(paths.project_dir, "project directory");
	return withFlockHeldSync(paths.project_lock, () => fn({ identity, paths, root }));
}

function ensureProjectIndexLocked(ctx: ProjectLockContext, timestamp = nowIso()): { project: ProjectIndex; paths: ProjectRunPaths } {
	mkdirSync(ctx.paths.runs_dir, { recursive: true });
	assertStorageDirectory(ctx.paths.project_dir, "project directory");
	assertStorageDirectory(ctx.paths.runs_dir, "runs directory");
	const existing = readProjectIndex(ctx.paths.project_json);
	if (existing !== JSON_MISSING) validateProjectIndexIdentity(existing, ctx.identity, ctx.paths.project_json);
	const createdAt = existing !== JSON_MISSING ? existing.created_at : timestamp;
	const project: ProjectIndex = {
		created_at: createdAt,
		id_source: ctx.identity.id_source,
		last_seen_at: timestamp,
		name: ctx.identity.name,
		project_id: ctx.identity.project_id,
		remote_url: ctx.identity.remote_url,
		root_hash: ctx.identity.root_hash,
		root_path: ctx.identity.root_path,
		schema_version: RUN_STORE_SCHEMA_VERSION,
	};
	writeJsonAtomic(ctx.paths.project_json, project);
	return { paths: ctx.paths, project };
}

function loadProjectIndexLocked(ctx: ProjectLockContext): { project: ProjectIndex; paths: ProjectRunPaths } | null {
	assertStorageDirectory(ctx.paths.project_dir, "project directory");
	const project = readProjectIndex(ctx.paths.project_json);
	if (project === JSON_MISSING) return null;
	validateProjectIndexIdentity(project, ctx.identity, ctx.paths.project_json);
	return { paths: ctx.paths, project };
}

function createRunLocked(ctx: ProjectLockContext, session: string, stateDir?: string, timestamp = nowIso()): RunCreateResult {
	const { project, paths: projectPaths } = ensureProjectIndexLocked(ctx, timestamp);
	const runId = newRunId(timestamp);
	const paths = resolveRunPaths(projectPaths, runId);
	ensureRunStorageDirectories(paths);
	const liveStateDir = legacyStateDirForRoot(project.root_path, stateDir);
	const liveState = join(liveStateDir, `flightdeck-state-${session}.json`);
	// NB: explicit legacy path; the public activityPathForSession helper
	// now collapses to `<run-dir>/activity.jsonl` for run-shaped bases.
	const liveActivity = legacyActivityPathInDir(session, liveStateDir);
	// vstack#227 round-2: route the legacy seed through the locked
	// migration helper so the copy+rename happens inside flock on the
	// legacy state and activity locks. This closes the create-time
	// race where a concurrent writer could squeeze a write between the
	// previous unlocked read and rename. The helper is only invoked
	// when a legacy file actually exists, so a clean session start
	// doesn't pollute `<project>/tmp/` with empty lock files.
	if (existsSync(liveState) || existsSync(liveActivity)) {
		mkdirSync(liveStateDir, { recursive: true });
		const migrateResult = lockedMigrateLegacyIntoRun(
			`${liveState}.lock`,
			`${liveActivity}.lock`,
			liveState,
			liveActivity,
			paths.state_json,
			paths.activity_jsonl,
		);
		if (migrateResult.status !== 0 && migrateResult.status !== 2) {
			const stderr = migrateResult.stderr.trim() || "<no stderr>";
			throw new Error(`legacy state migration during run create failed (status=${migrateResult.status}): ${stderr}`);
		}
	}
	// Fill in defaults for any path the migration left unwritten (i.e.
	// no legacy file existed).
	let state: Record<string, unknown>;
	if (existsSync(paths.state_json)) {
		const parsed = readStateObject(paths.state_json, "run state");
		state = parsed === JSON_MISSING ? initialRunState(session, timestamp, paths.activity_jsonl) : parsed;
	} else {
		state = initialRunState(session, timestamp, paths.activity_jsonl);
	}
	state.activity_path = paths.activity_jsonl;
	writeJsonAtomic(paths.state_json, state);
	if (!existsSync(paths.activity_jsonl)) writeFileAtomic(paths.activity_jsonl, "");
	const metadata: RunMetadata = {
		activity_path: paths.activity_jsonl,
		imported: false,
		imported_from: null,
		last_seen_at: timestamp,
		legacy_activity_path: null,
		project_id: project.project_id,
		project_root: project.root_path,
		run_id: runId,
		schema_version: RUN_STORE_SCHEMA_VERSION,
		snapshots_path: paths.snapshots_dir,
		started_at: timestamp,
		state_path: paths.state_json,
		summary_path: null,
		terminated: false,
		terminated_at: null,
		tmux_session: session,
	};
	writeJsonAtomic(paths.metadata_json, metadata);
	const active: ActiveRunPointer = {
		activity_path: paths.activity_jsonl,
		project_id: project.project_id,
		run_id: runId,
		schema_version: RUN_STORE_SCHEMA_VERSION,
		state_path: paths.state_json,
		tmux_session: session,
		updated_at: timestamp,
	};
	writeJsonAtomic(projectPaths.active_run_json, active);
	return { active, metadata, paths, project };
}

function terminateRunLocked(ctx: ProjectLockContext, loaded: { project: ProjectIndex; paths: ProjectRunPaths }, runId: string, options: RunTerminateOptions = {}): RunTerminateResult {
	const requestedRunId = safeRunId(runId);
	const paths = resolveRunPaths(loaded.paths, requestedRunId);
	const metadata = readRunMetadataForRun(paths, ctx.identity.project_id, requestedRunId, loaded.project.root_path);
	if (metadata === JSON_MISSING) throw new Error(`run not found: ${runId}`);
	const requestedTmuxSession = options.tmuxSession !== undefined
		? safeLegacySessionName(requireNonEmpty(options.tmuxSession, "tmux session"))
		: null;
	if (requestedTmuxSession && metadata.tmux_session !== requestedTmuxSession) {
		throw new Error(runTmuxSessionMismatchMessage(metadata, requestedTmuxSession));
	}
	const active = readActivePointer(loaded.paths.active_run_json);
	if (active !== JSON_MISSING) validateActivePointerProject(active, ctx.identity.project_id, loaded.paths.active_run_json);
	if (active !== JSON_MISSING && active.run_id === requestedRunId) {
		if (active.tmux_session !== metadata.tmux_session) throw new Error(activePointerTerminateMismatchMessage(active, metadata, requestedTmuxSession));
		if (requestedTmuxSession && active.tmux_session !== requestedTmuxSession) throw new Error(activePointerTerminateMismatchMessage(active, metadata, requestedTmuxSession));
	}
	ensureRunStorageDirectories(paths);
	assertRunStorageFile(paths, paths.state_json, "run state");
	let state = readStateObject(paths.state_json, "run state");
	if (state === JSON_MISSING) throw new Error(`state not found for run: ${runId}`);
	let summaryStage = options.summaryPath && options.summaryPath.trim()
		? stageSummaryIfAvailable(loaded.project.root_path, paths, options.summaryPath, state)
		: null;
	// vstack#227 round-2: route the optional legacy sync through the
	// locked migration helper so the copy+rename happens under flock
	// on both the legacy state and activity locks. The previous
	// `readRunStateFromLegacy` path could race an in-flight legacy
	// writer between read and copy. The migration runs AFTER the
	// explicit-summary-path stage so a stage failure leaves the
	// pre-existing run state/activity untouched.
	if (options.syncLegacy === true || requestedTmuxSession) {
		const session = safeLegacySessionName(requestedTmuxSession ?? metadata.tmux_session);
		const dir = legacyStateDirForRoot(loaded.project.root_path, options.stateDir);
		const legacyState = join(dir, `flightdeck-state-${session}.json`);
		const legacyActivity = legacyActivityPathInDir(session, dir);
		if (existsSync(legacyState) || existsSync(legacyActivity)) {
			mkdirSync(dir, { recursive: true });
			const r = lockedMigrateLegacyIntoRun(
				`${legacyState}.lock`,
				`${legacyActivity}.lock`,
				legacyState,
				legacyActivity,
				paths.state_json,
				paths.activity_jsonl,
			);
			if (r.status !== 0 && r.status !== 2) {
				const stderr = r.stderr.trim() || "<no stderr>";
				throw new Error(`legacy state migration during terminate failed (status=${r.status}): ${stderr}`);
			}
			// Re-read state after the locked migration so subsequent
			// snapshot writes pick up the latest legacy content.
			const refreshed = readStateObject(paths.state_json, "run state");
			if (refreshed !== JSON_MISSING) state = refreshed;
		}
	}
	// Prefer the timestamp the caller already wrote into state via
	// `flightdeck-state set terminated_at "..."`, falling back to run
	// metadata or `now` for fresh terminations.
	const preferredTimestamp = typeof state.terminated_at === "string" && state.terminated_at.trim()
		? state.terminated_at.trim()
		: metadata.terminated_at ?? nowIso();
	const timestamp = normalizeTimestamp(preferredTimestamp, "terminated_at");
	state.activity_path = paths.activity_jsonl;
	state.terminated = true;
	state.terminated_at = timestamp.iso;
	if (!summaryStage) summaryStage = stageSummaryIfAvailable(loaded.project.root_path, paths, undefined, state);
	const summaryPath = commitStagedSummary(summaryStage);
	writeJsonAtomic(paths.state_json, state);
	const snapshotPath = safeSnapshotPath(paths.snapshots_dir, `${timestamp.basename}.json`);
	writeJsonAtomic(snapshotPath, state);
	let activitySnapshotPath: string | null = null;
	if (existsSync(paths.activity_jsonl)) {
		assertRunStorageFile(paths, paths.activity_jsonl, "run activity");
		activitySnapshotPath = safeSnapshotPath(paths.snapshots_dir, `${timestamp.basename}.activity.jsonl`);
		copyFileAtomic(paths.activity_jsonl, activitySnapshotPath);
	}
	const nextMetadata: RunMetadata = {
		...metadata,
		last_seen_at: timestamp.iso,
		summary_path: summaryPath ?? metadata.summary_path,
		terminated: true,
		terminated_at: timestamp.iso,
	};
	writeJsonAtomic(paths.metadata_json, nextMetadata);
	let activeCleared = false;
	if (active !== JSON_MISSING && active.project_id === ctx.identity.project_id && active.run_id === requestedRunId) {
		rmSync(loaded.paths.active_run_json, { force: true });
		activeCleared = true;
	}
	// vstack#227 round-2: the locked migration block above already
	// renamed any active legacy file. This call covers terminate paths
	// that DIDN'T request syncLegacy (e.g. explicit `run terminate`
	// without `--tmux-session`) but still want any surviving legacy
	// file out of the way.
	if (options.syncLegacy !== true && !requestedTmuxSession) {
		markLegacyStateMigratedIfPresent(loaded.project.root_path, metadata.tmux_session, options.stateDir);
	}
	return { active_cleared: activeCleared, activity_snapshot_path: activitySnapshotPath, metadata: nextMetadata, snapshot_path: snapshotPath };
}

function ensureResult(reused: RunCreateResult, action: RunEnsureResult["action"], previousRunId: string | null, previousTermination: RunTerminateResult | null, legacyArchivePath: string | null): RunEnsureResult {
	return {
		action,
		active: reused.active,
		legacy_archive_path: legacyArchivePath,
		metadata: reused.metadata,
		paths: reused.paths,
		previous_run_id: previousRunId,
		previous_termination: previousTermination,
		project: reused.project,
	};
}

function activeRunMissingMetadataMessage(activeRunPath: string, active: ActiveRunPointer, metadataPath: string, projectRoot: string): string {
	return [
		`active Flightdeck run metadata is missing: ${metadataPath}`,
		`active_run_json=${activeRunPath}`,
		`run_id=${active.run_id}`,
		`active_tmux_session=${active.tmux_session}`,
		`requested recovery: inspect the active pointer and either restore/import the missing run metadata or explicitly terminate/remove the stale pointer for project ${projectRoot}; refusing to overwrite active-run.json automatically`,
	].join("; ");
}

function activeRunLivenessUnknownMessage(activeRunPath: string, metadata: RunMetadata, requestedSession: string, stale: StaleActiveRunCheck): string {
	return [
		`cannot verify active Flightdeck run liveness: ${stale.error ?? "tmux liveness query failed"}`,
		`active_run_json=${activeRunPath}`,
		`run_id=${metadata.run_id}`,
		`active_tmux_session=${metadata.tmux_session}`,
		`requested_tmux_session=${requestedSession}`,
		`recorded_pane_ids=${stale.paneIds.join(",") || "<none>"}`,
		"requested recovery: retry when tmux liveness is available, or explicitly terminate/archive the old run after verifying no panes are alive",
	].join("; ");
}

function activeRunSessionMismatchMessage(activeRunPath: string, active: ActiveRunPointer, metadata: RunMetadata, requestedSession: string): string {
	return [
		"active Flightdeck run belongs to a different tmux session and is not proven stale",
		`active_run_json=${activeRunPath}`,
		`run_id=${metadata.run_id}`,
		`active_pointer_tmux_session=${active.tmux_session}`,
		`metadata_tmux_session=${metadata.tmux_session}`,
		`requested_tmux_session=${requestedSession}`,
		"requested recovery: return to the owning tmux session, terminate/archive that run, or verify all recorded panes are gone before starting a replacement",
	].join("; ");
}

function runTmuxSessionMismatchMessage(metadata: RunMetadata, requestedSession: string): string {
	return [
		"Flightdeck run metadata tmux session does not match requested termination session",
		`run_id=${metadata.run_id}`,
		`metadata_tmux_session=${metadata.tmux_session}`,
		`requested_tmux_session=${requestedSession}`,
		"requested recovery: terminate from the owning tmux session or inspect the active pointer and run metadata before retrying",
	].join("; ");
}

function activePointerTerminateMismatchMessage(active: ActiveRunPointer, metadata: RunMetadata, requestedSession: string | null): string {
	return [
		"active Flightdeck run pointer tmux session does not match run termination metadata",
		`run_id=${metadata.run_id}`,
		`active_pointer_tmux_session=${active.tmux_session}`,
		`metadata_tmux_session=${metadata.tmux_session}`,
		`requested_tmux_session=${requestedSession ?? "<none>"}`,
		"requested recovery: inspect active-run.json and run metadata before retrying; refusing to mutate run state or clear active pointer",
	].join("; ");
}

function legacyStateDirForRoot(projectRoot: string, stateDir?: string): string {
	const raw = stateDir && stateDir.trim()
		? stateDir.trim()
		: process.env.FLIGHTDECK_STATE_DIR && process.env.FLIGHTDECK_STATE_DIR.trim()
			? process.env.FLIGHTDECK_STATE_DIR.trim()
			: "tmp";
	return isAbsolute(raw) ? resolve(raw) : resolve(projectRoot, raw);
}

function checkActiveRunStale(projectRoot: string, metadata: RunMetadata, paths: RunPaths, stateDir?: string): StaleActiveRunCheck {
	const liveState = readStateObject(join(legacyStateDirForRoot(projectRoot, stateDir), `flightdeck-state-${metadata.tmux_session}.json`), "live state");
	const durableState = liveState === JSON_MISSING ? readStateObject(paths.state_json, "run state") : liveState;
	if (durableState === JSON_MISSING) return { paneIds: [], reason: "no-entries", stale: false };
	const entries = isRecord(durableState.entries) ? durableState.entries : {};
	const entryValues = Object.values(entries).filter(isRecord);
	if (entryValues.length === 0) return { paneIds: [], reason: "no-entries", stale: false };
	const paneIds = entryValues.map((entry) => typeof entry.pane_id === "string" ? entry.pane_id : "").filter(Boolean);
	if (paneIds.length === 0) return { paneIds, reason: "no-pane-ids", stale: false };
	const live = livePaneIds();
	if (!live.ok) return { error: live.error ?? "tmux list-panes failed", paneIds, reason: "tmux-query-failed", stale: false };
	const stale = paneIds.every((paneId) => !live.panes.has(paneId));
	return { paneIds, reason: stale ? "all-panes-missing" : "live-pane-found", stale };
}

function livePaneIds(): LivePaneIdsResult {
	const r = spawnSync("tmux", ["list-panes", "-a", "-F", "#{pane_id}"], { encoding: "utf8", env: process.env as NodeJS.ProcessEnv });
	if (r.error) return { error: `tmux list-panes -a spawn failed: ${r.error.message}`, ok: false, panes: new Set() };
	if (r.status !== 0) {
		const stderr = (r.stderr ?? "").trim();
		return { error: `tmux list-panes -a failed (status=${r.status ?? "unknown"})${stderr ? `: ${stderr}` : ""}`, ok: false, panes: new Set() };
	}
	const panes = new Set<string>();
	for (const line of (r.stdout ?? "").split("\n")) if (line) panes.add(line);
	return { ok: true, panes };
}

// vstack#227: when a run has been terminated or replaced, rotate the
// legacy project-local state file out of the way so dashboards/daemons
// stop reading it. The durable run snapshot already preserves the
// archive history under `runs/<run-id>/`; this helper just makes the
// stale project-local copy non-readable by ordinary scan paths.
//
// Failure mode: the state-file rename is load-bearing; if it fails
// (race, perms, etc.) we throw so callers do not return success while
// the legacy file is still live. The lock + activity sidecars are
// non-critical: their rename failures warn to stderr but don't abort
// the parent operation.
function markLegacyStateMigratedIfPresent(projectRoot: string, tmuxSession: string, stateDir?: string): void {
	const dir = legacyStateDirForRoot(projectRoot, stateDir);
	const statePath = join(dir, `flightdeck-state-${safeLegacySessionName(tmuxSession)}.json`);
	const activityPath = legacyActivityPathInDir(tmuxSession, dir);
	markLegacyStatePathMigrated(statePath, activityPath);
}

function markLegacyStatePathMigrated(statePath: string, activityPath: string): void {
	// State path is load-bearing: callers that reach here expect the
	// legacy file to stop being read after migration. Surface failures
	// loudly so we never silently return with a live legacy state.
	renameOrThrow(statePath, `${statePath}.migrated`, "legacy state");
	// Lock + activity sidecars: warn-only. Operators can clean these up
	// manually after verification.
	tryRenameWarn(`${statePath}.lock`, `${statePath}.lock.migrated`, "legacy state lock");
	renameOrThrow(activityPath, `${activityPath}.migrated`, "legacy activity");
	tryRenameWarn(`${activityPath}.lock`, `${activityPath}.lock.migrated`, "legacy activity lock");
	tryRenameWarn(`${activityPath}.archived`, `${activityPath}.archived.migrated`, "legacy activity .archived sentinel");
}

function renameOrThrow(from: string, to: string, label: string): void {
	if (!existsSync(from)) return;
	try {
		renameSync(from, to);
	} catch (error) {
		throw new Error(`failed to rename ${label} ${from} -> ${to}: ${error instanceof Error ? error.message : String(error)}`);
	}
}

function tryRenameWarn(from: string, to: string, label: string): void {
	if (!existsSync(from)) return;
	try {
		renameSync(from, to);
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		process.stderr.write(`Warning: failed to rename ${label} ${from} -> ${to}: ${message}\n`);
	}
}

// vstack#227 migration shim: for live runs whose state.json predates
// the cutover, fold any pending writes from the legacy `tmp/flightdeck-
// state-<S>.json` (and matching activity sidecar) into the run dir
// before downstream consumers read state.json. Idempotent: once the
// legacy paths are renamed to `.migrated`, this is a no-op.
//
// The migration runs under the legacy state-lock + activity-lock so
// concurrent legacy writers can't race with the copy+rename. The
// shell-side script (see locking.ts::lockedMigrateLegacyIntoRun)
// performs the work atomically and exits:
//   * 0  → migration succeeded (state and/or activity moved)
//   * 2  → no-op (no legacy files present)
//   * other → failure; we surface stderr and abort so callers do not
//     proceed against a half-migrated layout.
function migrateLegacyStateIntoActiveRun(projectRoot: string, tmuxSession: string, paths: RunPaths, stateDir?: string): void {
	const dir = legacyStateDirForRoot(projectRoot, stateDir);
	const legacyState = join(dir, `flightdeck-state-${safeLegacySessionName(tmuxSession)}.json`);
	const legacyActivity = legacyActivityPathInDir(tmuxSession, dir);
	const legacyStateExists = existsSync(legacyState);
	const legacyActivityExists = existsSync(legacyActivity);
	if (!legacyStateExists && !legacyActivityExists) return;
	mkdirSync(dir, { recursive: true });
	const r = lockedMigrateLegacyIntoRun(
		`${legacyState}.lock`,
		`${legacyActivity}.lock`,
		legacyState,
		legacyActivity,
		paths.state_json,
		paths.activity_jsonl,
	);
	if (r.status === 0 || r.status === 2) return;
	const stderr = r.stderr.trim();
	throw new Error(`legacy state migration failed (status=${r.status}): ${stderr || "<no stderr>"}`);
}

// Legacy activity path inside an arbitrary state directory. Distinct
// from the public activityPathForSession helper, which now treats
// run-directory stateBases as the canonical layout and returns a
// non-prefixed `activity.jsonl`.
function legacyActivityPathInDir(session: string, dir: string): string {
	return join(dir, `flightdeck-activity-${safeLegacySessionName(session)}.jsonl`);
}

function stageSummaryIfAvailable(projectRoot: string, paths: RunPaths, explicitSummaryPath: string | undefined, state: Record<string, unknown>): StagedSummaryCopy | null {
	const explicit = explicitSummaryPath && explicitSummaryPath.trim() ? explicitSummaryPath.trim() : "";
	const raw = explicit || (typeof state.summary_path === "string" && state.summary_path.trim() ? state.summary_path.trim() : "");
	if (!raw) return null;
	const source = isAbsolute(raw) ? resolve(raw) : resolve(projectRoot, raw);
	const explicitLabel = explicit ? "explicit --summary-path" : "state.summary_path";
	const stagedPath = `${paths.summary_md}.tmp.${process.pid}.${randomBytes(4).toString("hex")}`;
	try {
		const lst = lstatSync(source);
		if (lst.isSymbolicLink()) throw new Error("symlinks are not allowed");
		const st = statSync(source);
		if (!st.isFile()) throw new Error("not a regular file");
		const realRoot = realpathSync(projectRoot);
		const realSource = realpathSync(source);
		if (!isPathInside(realRoot, realSource)) throw new Error(`path escapes project root: ${source}`);
		const existingDestination = existsSync(paths.summary_md) ? lstatSync(paths.summary_md) : null;
		if (existingDestination && !existingDestination.isFile()) throw new Error(`summary destination is not a regular file: ${paths.summary_md}`);
		copyFileAtomic(realSource, stagedPath);
		return { finalPath: paths.summary_md, stagedPath };
	} catch (error) {
		rmSync(stagedPath, { force: true });
		const message = error instanceof Error ? error.message : String(error);
		if (explicit) throw new Error(`invalid ${explicitLabel} ${raw}: ${message}`);
		process.stderr.write(`Warning: ignored ${explicitLabel} ${raw}: ${message}\n`);
		return null;
	}
}

function commitStagedSummary(stage: StagedSummaryCopy | null): string | null {
	if (!stage) return null;
	renameSync(stage.stagedPath, stage.finalPath);
	return stage.finalPath;
}

function projectIdentityForRoot(rootPath: string): ProjectIdentity {
	const remoteUrl = gitRemoteUrl(rootPath);
	const rootHash = sha256(rootPath);
	const name = remoteUrl ? remoteRepoName(remoteUrl) : basename(rootPath) || "project";
	const idSource: ProjectIdentity["id_source"] = remoteUrl ? "git-remote+root" : "root";
	const identityMaterial = remoteUrl ? `${remoteUrl}\n${rootHash}` : rootHash;
	return {
		id_source: idSource,
		name,
		project_id: `${safeSegment(name)}-${sha256(identityMaterial).slice(0, 16)}`,
		remote_url: remoteUrl,
		root_hash: rootHash,
		root_path: rootPath,
	};
}

function gitRemoteUrl(projectRoot: string): string | null {
	const origin = spawnSync("git", ["-C", projectRoot, "config", "--get", "remote.origin.url"], { encoding: "utf8" });
	if (origin.status === 0 && origin.stdout.trim()) return origin.stdout.trim();
	const first = spawnSync("git", ["-C", projectRoot, "remote"], { encoding: "utf8" });
	const remote = (first.stdout ?? "").split("\n").map((line) => line.trim()).find(Boolean);
	if (!remote) return null;
	const value = spawnSync("git", ["-C", projectRoot, "config", "--get", `remote.${remote}.url`], { encoding: "utf8" });
	return value.status === 0 && value.stdout.trim() ? value.stdout.trim() : null;
}

function remoteRepoName(remoteUrl: string): string {
	const stripped = remoteUrl.trim().replace(/[?#].*$/, "").replace(/\.git$/, "");
	const parts = stripped.split(/[/:]/).filter(Boolean);
	return parts[parts.length - 1] || "project";
}

function safeRunId(runId: string): string {
	const clean = runId.trim();
	if (!/^[A-Za-z0-9._-]+$/.test(clean) || clean === "." || clean === "..") throw new Error("run id must match ^[A-Za-z0-9._-]+$ and not be . or ..");
	return clean;
}

function safeLegacySessionName(session: string): string {
	const clean = session.trim();
	if (!isSafeBasename(clean)) throw new Error("tmux session must be a safe basename");
	return clean;
}

function isSafeBasename(value: string): boolean {
	return !!value && value !== "." && value !== ".." && !value.includes("/") && !value.includes("\\");
}

function requireNonEmpty(value: string, label: string): string {
	const clean = value.trim();
	if (!clean) throw new Error(`${label} must be non-empty`);
	return clean;
}

function newRunId(timestamp: string): string {
	return `run-${normalizeTimestamp(timestamp, "run timestamp").basename}-${randomBytes(4).toString("hex")}`;
}

function importedRunId(projectId: string, session: string, terminatedAt: string, archiveName: string): string {
	const suffix = sha256(`${projectId}\n${session}\n${terminatedAt}\n${archiveName}`).slice(0, 8);
	return `imported-${safeSegment(session, "session")}-${normalizeTimestamp(terminatedAt, "terminated_at").basename}-${suffix}`;
}

function normalizeTimestamp(value: string, label: string): NormalizedTimestamp {
	const clean = value.trim();
	if (!isSafeBasename(clean)) throw new Error(`${label} must not contain path separators or be . or ..`);
	const match = clean.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}):?(\d{2}):?(\d{2})Z$/);
	if (!match) throw new Error(`${label} must match YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DDTHHMMSSZ`);
	return { basename: `${match[1]}T${match[2]}${match[3]}${match[4]}Z`, iso: `${match[1]}T${match[2]}:${match[3]}:${match[4]}Z` };
}

function safeSnapshotName(value: string): string {
	const clean = value.trim();
	if (!isSafeBasename(clean)) throw new Error("snapshot must be a safe basename or ISO timestamp");
	if (clean.endsWith(".json")) {
		if (!/^\d{4}-\d{2}-\d{2}T\d{6}Z\.json$/.test(clean)) throw new Error("snapshot filename must match YYYY-MM-DDTHHMMSSZ.json");
		return clean;
	}
	return `${normalizeTimestamp(clean, "snapshot").basename}.json`;
}

function safeSnapshotPath(snapshotsDir: string, fileName: string): string {
	if (!isSafeBasename(fileName)) throw new Error("snapshot filename must be a safe basename");
	if (!/^(\d{4}-\d{2}-\d{2}T\d{6}Z\.json|\d{4}-\d{2}-\d{2}T\d{6}Z\.activity\.jsonl)$/.test(fileName)) {
		throw new Error("snapshot filename has invalid format");
	}
	const root = resolve(snapshotsDir);
	const target = resolve(root, fileName);
	if (!isPathInside(root, target)) throw new Error("snapshot path escapes snapshots directory");
	return target;
}

function isPathInside(parent: string, child: string): boolean {
	const rel = relative(resolve(parent), resolve(child));
	return rel === "" || (!!rel && !rel.startsWith("..") && !isAbsolute(rel));
}

function initialRunState(session: string, startedAt: string, activityPath: string): Record<string, unknown> {
	return {
		activity_path: activityPath,
		activity_schema_version: 1,
		conflict_graph: { computed_at: null, edges: [] },
		entries: {},
		merge_queue: [],
		paused_for_user: null,
		session_id: session,
		started_at: startedAt,
		terminated: false,
	};
}

function listSnapshotFiles(snapshotsDir: string): string[] {
	if (!existsSync(snapshotsDir)) return [];
	assertStorageDirectory(snapshotsDir, "snapshots directory");
	return readdirSync(snapshotsDir).filter((entry) => /^\d{4}-\d{2}-\d{2}T\d{6}Z\.json$/.test(entry)).sort().reverse();
}

function parseLegacyArchiveName(entry: string): LegacyArchiveName | null {
	const match = entry.match(/^flightdeck-state-(.+)-(\d{4}-\d{2}-\d{2}T\d{6}Z)\.json\.archive$/);
	if (!match) return null;
	const session = match[1]!;
	if (!isSafeBasename(session)) return null;
	const terminatedAt = normalizeTimestamp(match[2]!, `timestamp in ${entry}`).iso;
	return { session, terminatedAt };
}

function resolveLegacyActivityArchive(state: Record<string, unknown>, archivePath: string, session: string, timestampBase: string, diagnostics: string[]): string | null {
	const stateDir = dirname(archivePath);
	const expectedBase = `flightdeck-activity-${session}-${timestampBase}.jsonl.archive`;
	const candidates: string[] = [join(stateDir, expectedBase)];
	const explicit = typeof state.activity_archive_path === "string" && state.activity_archive_path ? state.activity_archive_path : "";
	if (explicit) {
		const explicitPath = isAbsolute(explicit) ? explicit : resolve(stateDir, explicit);
		if (!candidates.includes(explicitPath)) candidates.push(explicitPath);
	}
	for (const candidate of candidates) {
		if (!existsSync(candidate)) continue;
		const valid = validateLegacyActivityArchive(candidate, stateDir, expectedBase, diagnostics);
		if (valid) return valid;
	}
	return null;
}

function validateLegacyActivityArchive(candidate: string, stateDir: string, expectedBase: string, diagnostics: string[]): string | null {
	try {
		if (basename(candidate) !== expectedBase) {
			diagnostics.push(`skipped legacy activity ${candidate}: expected basename ${expectedBase}`);
			return null;
		}
		const lst = lstatSync(candidate);
		if (lst.isSymbolicLink()) {
			diagnostics.push(`skipped legacy activity ${candidate}: symlinks are not allowed`);
			return null;
		}
		const st = statSync(candidate);
		if (!st.isFile()) {
			diagnostics.push(`skipped legacy activity ${candidate}: not a regular file`);
			return null;
		}
		if (st.size > MAX_LEGACY_ACTIVITY_ARCHIVE_BYTES) {
			diagnostics.push(`skipped legacy activity ${candidate}: file exceeds ${MAX_LEGACY_ACTIVITY_ARCHIVE_BYTES} bytes`);
			return null;
		}
		const realStateDir = realpathSync(stateDir);
		const realCandidate = realpathSync(candidate);
		if (!isPathInside(realStateDir, realCandidate)) {
			diagnostics.push(`skipped legacy activity ${candidate}: path escapes legacy state dir`);
			return null;
		}
		return realCandidate;
	} catch (error) {
		diagnostics.push(`skipped legacy activity ${candidate}: ${error instanceof Error ? error.message : String(error)}`);
		return null;
	}
}

function readLegacyArchiveJson(path: string, diagnostics: string[]): Record<string, unknown> | null {
	try {
		const lst = lstatSync(path);
		if (lst.isSymbolicLink()) throw new Error("symlinks are not allowed");
		const st = statSync(path);
		if (!st.isFile()) throw new Error("not a regular file");
		const archive = readJsonObject(path, "legacy state archive");
		return archive === JSON_MISSING ? null : archive;
	} catch (error) {
		diagnostics.push(`skipped ${path}: ${error instanceof Error ? error.message : String(error)}`);
		return null;
	}
}

function fileMtimeIso(file: string): string {
	try {
		return statSync(file).mtime.toISOString().replace(/\.\d{3}Z$/, "Z");
	} catch {
		return nowIso();
	}
}

function ensureRunStorageDirectories(paths: RunPaths): void {
	assertStorageDirectory(dirname(paths.run_dir), "runs directory");
	mkdirSync(paths.run_dir, { recursive: true });
	assertStorageDirectory(paths.run_dir, "run directory");
	mkdirSync(paths.snapshots_dir, { recursive: true });
	assertStorageDirectory(paths.snapshots_dir, "snapshots directory");
	assertPathContained(paths.run_dir, paths.snapshots_dir, "snapshots directory");
}

function assertRunStoragePaths(paths: RunPaths): void {
	assertStorageDirectoryIfExists(dirname(paths.run_dir), "runs directory");
	if (!assertStorageDirectoryIfExists(paths.run_dir, "run directory")) return;
	assertStorageFileIfExists(paths.metadata_json, "run metadata");
	assertStorageFileIfExists(paths.state_json, "run state");
	assertStorageFileIfExists(paths.activity_jsonl, "run activity");
	assertStorageDirectoryIfExists(paths.snapshots_dir, "snapshots directory");
	for (const candidate of [paths.metadata_json, paths.state_json, paths.activity_jsonl, paths.snapshots_dir]) {
		if (existsSync(candidate)) assertPathContained(paths.run_dir, candidate, candidate === paths.snapshots_dir ? "snapshots directory" : "run file");
	}
}

function assertRunStorageFile(paths: RunPaths, file: string, label: string): void {
	assertRunStoragePaths(paths);
	assertStorageFileIfExists(file, label);
	assertPathContained(paths.run_dir, file, label);
}

function assertStorageDirectoryIfExists(path: string, label: string): boolean {
	let stat;
	try {
		stat = lstatSync(path);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
		throw new Error(`failed to inspect ${label} ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (stat.isSymbolicLink()) throw new Error(`invalid ${label} ${path}: symlinks are not allowed`);
	if (!stat.isDirectory()) throw new Error(`invalid ${label} ${path}: expected directory`);
	return true;
}

function assertStorageDirectory(path: string, label: string): void {
	if (!assertStorageDirectoryIfExists(path, label)) throw new Error(`invalid ${label} ${path}: missing directory`);
}

function assertStorageFileIfExists(path: string, label: string): boolean {
	let stat;
	try {
		stat = lstatSync(path);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
		throw new Error(`failed to inspect ${label} ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (stat.isSymbolicLink()) throw new Error(`invalid ${label} ${path}: symlinks are not allowed`);
	if (!stat.isFile()) throw new Error(`invalid ${label} ${path}: expected regular file`);
	// vstack#227 round-3 P2.1: enforce strict 0600 + uid ownership on
	// EVERY read path. Pre-existing wider perms or foreign-uid
	// ownership now fail closed — they could indicate a previously-
	// trusted file that's been chmod'd or chown'd out from under us.
	// (CWE-732 / CWE-276)
	assertStoreOwnership(stat, path, label, "strict");
	return true;
}

function assertPathContained(root: string, candidate: string, label: string): void {
	const realRoot = realpathSync(root);
	const realCandidate = realpathSync(candidate);
	if (!isPathInside(realRoot, realCandidate)) throw new Error(`invalid ${label} ${candidate}: path escapes ${root}`);
}

function readProjectIndex(path: string): ProjectIndex | JsonMissing {
	const raw = readStorageJsonObject(path, "project index");
	if (raw === JSON_MISSING) return JSON_MISSING;
	return {
		created_at: expectString(raw, "created_at", path, "project index"),
		id_source: expectEnum(raw, "id_source", path, "project index", ["git-remote+root", "root"]),
		last_seen_at: expectString(raw, "last_seen_at", path, "project index"),
		name: expectString(raw, "name", path, "project index"),
		project_id: safeRunId(expectString(raw, "project_id", path, "project index")),
		remote_url: expectNullableString(raw, "remote_url", path, "project index"),
		root_hash: expectString(raw, "root_hash", path, "project index"),
		root_path: expectString(raw, "root_path", path, "project index"),
		schema_version: expectSchemaVersion(raw, path, "project index"),
	};
}

function readActivePointer(path: string): ActiveRunPointer | JsonMissing {
	const raw = readStorageJsonObject(path, "active run pointer");
	if (raw === JSON_MISSING) return JSON_MISSING;
	return {
		activity_path: expectString(raw, "activity_path", path, "active run pointer"),
		project_id: safeRunId(expectString(raw, "project_id", path, "active run pointer")),
		run_id: safeRunId(expectString(raw, "run_id", path, "active run pointer")),
		schema_version: expectSchemaVersion(raw, path, "active run pointer"),
		state_path: expectString(raw, "state_path", path, "active run pointer"),
		tmux_session: safeLegacySessionName(expectString(raw, "tmux_session", path, "active run pointer")),
		updated_at: expectString(raw, "updated_at", path, "active run pointer"),
	};
}

function readRunMetadata(path: string): RunMetadata | JsonMissing {
	const raw = readStorageJsonObject(path, "run metadata");
	if (raw === JSON_MISSING) return JSON_MISSING;
	return {
		activity_path: expectString(raw, "activity_path", path, "run metadata"),
		imported: expectBoolean(raw, "imported", path, "run metadata"),
		imported_from: expectNullableString(raw, "imported_from", path, "run metadata"),
		last_seen_at: expectString(raw, "last_seen_at", path, "run metadata"),
		legacy_activity_path: expectNullableString(raw, "legacy_activity_path", path, "run metadata"),
		project_id: safeRunId(expectString(raw, "project_id", path, "run metadata")),
		project_root: expectString(raw, "project_root", path, "run metadata"),
		run_id: safeRunId(expectString(raw, "run_id", path, "run metadata")),
		schema_version: expectSchemaVersion(raw, path, "run metadata"),
		snapshots_path: expectString(raw, "snapshots_path", path, "run metadata"),
		started_at: expectString(raw, "started_at", path, "run metadata"),
		state_path: expectString(raw, "state_path", path, "run metadata"),
		summary_path: expectNullableString(raw, "summary_path", path, "run metadata"),
		terminated: expectBoolean(raw, "terminated", path, "run metadata"),
		terminated_at: expectNullableString(raw, "terminated_at", path, "run metadata"),
		tmux_session: safeLegacySessionName(expectString(raw, "tmux_session", path, "run metadata")),
	};
}

function readRunMetadataForRun(paths: RunPaths, expectedProjectId: string, expectedRunId: string, expectedProjectRoot: string): RunMetadata | JsonMissing {
	assertRunStoragePaths(paths);
	const metadata = readRunMetadata(paths.metadata_json);
	if (metadata === JSON_MISSING) return JSON_MISSING;
	validateRunMetadataIdentity(metadata, paths.metadata_json, expectedProjectId, expectedRunId);
	validateRunMetadataPaths(metadata, paths.metadata_json, expectedProjectRoot, paths);
	return canonicalRunMetadata(metadata, expectedProjectRoot, paths);
}

function validateRunMetadataIdentity(metadata: RunMetadata, path: string, expectedProjectId: string, expectedRunId: string): void {
	if (metadata.project_id !== expectedProjectId) {
		throw new Error(`invalid run metadata JSON ${path}: project_id ${metadata.project_id} does not match project ${expectedProjectId}`);
	}
	if (metadata.run_id !== expectedRunId) {
		throw new Error(`invalid run metadata JSON ${path}: run_id ${metadata.run_id} does not match requested run ${expectedRunId}`);
	}
}

function validateRunMetadataPaths(metadata: RunMetadata, path: string, expectedProjectRoot: string, paths: RunPaths): void {
	assertMetadataPath(path, "project_root", metadata.project_root, expectedProjectRoot);
	assertMetadataPath(path, "state_path", metadata.state_path, paths.state_json);
	assertMetadataPath(path, "activity_path", metadata.activity_path, paths.activity_jsonl);
	assertMetadataPath(path, "snapshots_path", metadata.snapshots_path, paths.snapshots_dir);
}

function assertMetadataPath(metadataPath: string, field: string, actual: string, expected: string): void {
	if (resolve(actual) !== resolve(expected)) {
		throw new Error(`invalid run metadata JSON ${metadataPath}: ${field} ${actual} does not match canonical path ${expected}`);
	}
}

function canonicalRunMetadata(metadata: RunMetadata, expectedProjectRoot: string, paths: RunPaths): RunMetadata {
	return {
		...metadata,
		activity_path: paths.activity_jsonl,
		project_root: expectedProjectRoot,
		snapshots_path: paths.snapshots_dir,
		state_path: paths.state_json,
	};
}

function validateProjectIndexIdentity(project: ProjectIndex, identity: ProjectIdentity, path: string): void {
	if (project.project_id !== identity.project_id) {
		throw new Error(`invalid project index JSON ${path}: project_id ${project.project_id} does not match current project ${identity.project_id}`);
	}
	if (project.root_path !== identity.root_path) {
		throw new Error(`invalid project index JSON ${path}: root_path ${project.root_path} does not match current project ${identity.root_path}`);
	}
	if (project.root_hash !== identity.root_hash) {
		throw new Error(`invalid project index JSON ${path}: root_hash ${project.root_hash} does not match current project ${identity.root_hash}`);
	}
	if (project.remote_url !== identity.remote_url) {
		throw new Error(`invalid project index JSON ${path}: remote_url ${String(project.remote_url)} does not match current project ${String(identity.remote_url)}`);
	}
	if (project.id_source !== identity.id_source) {
		throw new Error(`invalid project index JSON ${path}: id_source ${project.id_source} does not match current project ${identity.id_source}`);
	}
	if (project.name !== identity.name) {
		throw new Error(`invalid project index JSON ${path}: name ${project.name} does not match current project ${identity.name}`);
	}
}

function validateActivePointerProject(active: ActiveRunPointer, expectedProjectId: string, path: string): void {
	if (active.project_id !== expectedProjectId) {
		throw new Error(`invalid active run pointer JSON ${path}: project_id ${active.project_id} does not match project ${expectedProjectId}`);
	}
}

function readStateObject(path: string, label: string): Record<string, unknown> | JsonMissing {
	return readJsonObject(path, label);
}

function readStorageJsonObject(path: string, label: string): Record<string, unknown> | JsonMissing {
	if (!assertStorageFileIfExists(path, label)) return JSON_MISSING;
	const raw = readJsonObject(path, label);
	if (raw !== JSON_MISSING) assertStorageFileIfExists(path, label);
	return raw;
}

function readJsonObject(path: string, label: string): Record<string, unknown> | JsonMissing {
	const value = readJsonValue(path);
	if (value === JSON_MISSING) return JSON_MISSING;
	if (!isRecord(value)) throw new Error(`invalid ${label} JSON ${path}: expected object`);
	return value;
}

function readJsonValue(path: string): unknown | JsonMissing {
	let text: string;
	try {
		text = readFileSync(path, "utf8");
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return JSON_MISSING;
		throw new Error(`failed to read JSON ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
	try {
		return JSON.parse(text) as unknown;
	} catch (error) {
		throw new Error(`invalid JSON in ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function expectSchemaVersion(raw: Record<string, unknown>, path: string, label: string): 1 {
	if (raw.schema_version !== RUN_STORE_SCHEMA_VERSION) throw new Error(`invalid ${label} JSON ${path}: schema_version must be ${RUN_STORE_SCHEMA_VERSION}`);
	return RUN_STORE_SCHEMA_VERSION;
}

function expectString(raw: Record<string, unknown>, field: string, path: string, label: string): string {
	const value = raw[field];
	if (typeof value !== "string" || !value.trim()) throw new Error(`invalid ${label} JSON ${path}: ${field} must be a non-empty string`);
	return value;
}

function expectNullableString(raw: Record<string, unknown>, field: string, path: string, label: string): string | null {
	const value = raw[field];
	if (value === null) return null;
	if (typeof value === "string") return value;
	throw new Error(`invalid ${label} JSON ${path}: ${field} must be a string or null`);
}

function expectBoolean(raw: Record<string, unknown>, field: string, path: string, label: string): boolean {
	const value = raw[field];
	if (typeof value !== "boolean") throw new Error(`invalid ${label} JSON ${path}: ${field} must be a boolean`);
	return value;
}

function expectEnum<T extends string>(raw: Record<string, unknown>, field: string, path: string, label: string, allowed: readonly T[]): T {
	const value = raw[field];
	if (typeof value !== "string" || !allowed.includes(value as T)) throw new Error(`invalid ${label} JSON ${path}: ${field} must be ${allowed.join("|")}`);
	return value as T;
}

function writeJsonAtomic(path: string, value: unknown): void {
	writeFileAtomic(path, `${JSON.stringify(value, null, 2)}\n`);
}

function writeFileAtomic(path: string, text: string): void {
	mkdirSync(dirname(path), { mode: STORE_DIR_MODE, recursive: true });
	assertStorageDirectory(dirname(path), "destination directory");
	ensureStoreFile(path, "destination file");
	const tmp = `${path}.tmp.${process.pid}.${randomBytes(4).toString("hex")}`;
	try {
		writeFileSync(tmp, text, { encoding: "utf8", mode: STORE_FILE_MODE });
		// writeFileSync respects mode only on file creation; force the
		// tightened bits explicitly in case of umask quirks.
		chmodSyncSafe(tmp, STORE_FILE_MODE);
		assertStorageFileIfExists(tmp, "temporary file");
		assertStorageDirectory(dirname(path), "destination directory");
		ensureStoreFile(path, "destination file");
		renameSync(tmp, path);
	} catch (error) {
		rmSync(tmp, { force: true });
		throw error;
	}
}

function copyFileAtomic(src: string, dst: string): void {
	mkdirSync(dirname(dst), { mode: STORE_DIR_MODE, recursive: true });
	assertStorageDirectory(dirname(dst), "destination directory");
	ensureStoreFile(dst, "destination file");
	const tmp = `${dst}.tmp.${process.pid}.${randomBytes(4).toString("hex")}`;
	try {
		copyFileSync(src, tmp);
		chmodSyncSafe(tmp, STORE_FILE_MODE);
		assertStorageFileIfExists(tmp, "temporary file");
		assertStorageDirectory(dirname(dst), "destination directory");
		ensureStoreFile(dst, "destination file");
		renameSync(tmp, dst);
	} catch (error) {
		rmSync(tmp, { force: true });
		throw error;
	}
}
