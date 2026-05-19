import { spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import {
	copyFileSync,
	existsSync,
	mkdirSync,
	readdirSync,
	readFileSync,
	renameSync,
	rmSync,
	statSync,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { activityPathForSession } from "../activity/paths.ts";

export const RUN_STORE_SCHEMA_VERSION = 1;

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

export interface LegacyImportResult {
	project: ProjectIndex;
	state_dir: string;
	imported: RunMetadata[];
	skipped: RunMetadata[];
}

interface ProjectIdentity {
	project_id: string;
	name: string;
	root_path: string;
	root_hash: string;
	remote_url: string | null;
	id_source: "git-remote+root" | "root";
}

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
	const home = process.env.HOME && process.env.HOME.trim() ? process.env.HOME.trim() : homedir();
	return home;
}

export function flightdeckRunStoreRoot(): string {
	return join(storeHome(), ".vstack", "flightdeck");
}

export function resolveProjectRunPaths(project: ProjectIndex | ProjectIdentity): ProjectRunPaths {
	const storeRoot = flightdeckRunStoreRoot();
	const projectDir = join(storeRoot, "projects", project.project_id);
	return {
		active_run_json: join(projectDir, "active-run.json"),
		project_dir: projectDir,
		project_json: join(projectDir, "project.json"),
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
	const raw = stateDir && stateDir.trim()
		? stateDir.trim()
		: process.env.FLIGHTDECK_STATE_DIR && process.env.FLIGHTDECK_STATE_DIR.trim()
			? process.env.FLIGHTDECK_STATE_DIR.trim()
			: "tmp";
	return isAbsolute(raw) ? resolve(raw) : resolve(projectRoot, raw);
}

export function legacyStatePath(projectRoot: string, tmuxSession: string, stateDir?: string): string {
	return join(legacyStateDir(projectRoot, stateDir), `flightdeck-state-${tmuxSession}.json`);
}

export function legacyActivityPath(projectRoot: string, tmuxSession: string, stateDir?: string): string {
	return activityPathForSession(tmuxSession, legacyStateDir(projectRoot, stateDir));
}

export function resolveProjectIdentity(projectRoot: string): ProjectIdentity {
	const rootPath = resolve(projectRoot);
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

export function ensureProjectIndex(projectRoot: string, timestamp = nowIso()): { project: ProjectIndex; paths: ProjectRunPaths } {
	const identity = resolveProjectIdentity(projectRoot);
	const paths = resolveProjectRunPaths(identity);
	mkdirSync(paths.runs_dir, { recursive: true });
	const existing = readJsonIfExists<ProjectIndex>(paths.project_json);
	const createdAt = existing?.created_at && typeof existing.created_at === "string" ? existing.created_at : timestamp;
	const project: ProjectIndex = {
		created_at: createdAt,
		id_source: identity.id_source,
		last_seen_at: timestamp,
		name: identity.name,
		project_id: identity.project_id,
		remote_url: identity.remote_url,
		root_hash: identity.root_hash,
		root_path: identity.root_path,
		schema_version: RUN_STORE_SCHEMA_VERSION,
	};
	writeJsonAtomic(paths.project_json, project);
	return { paths, project };
}

export function loadProjectIndex(projectRoot: string): { project: ProjectIndex; paths: ProjectRunPaths } | null {
	const identity = resolveProjectIdentity(projectRoot);
	const paths = resolveProjectRunPaths(identity);
	const project = readJsonIfExists<ProjectIndex>(paths.project_json);
	if (!project) return null;
	return { paths, project };
}

export function createRun(projectRoot: string, tmuxSession: string): RunCreateResult {
	const session = requireNonEmpty(tmuxSession, "tmux session");
	const timestamp = nowIso();
	const { project, paths: projectPaths } = ensureProjectIndex(projectRoot, timestamp);
	const runId = newRunId(timestamp);
	const paths = resolveRunPaths(projectPaths, runId);
	mkdirSync(paths.snapshots_dir, { recursive: true });
	const liveState = legacyStatePath(project.root_path, session);
	const liveActivity = legacyActivityPath(project.root_path, session);
	const state = readJsonIfExists<Record<string, unknown>>(liveState) ?? initialRunState(session, timestamp, paths.activity_jsonl);
	state.activity_path = paths.activity_jsonl;
	writeJsonAtomic(paths.state_json, state);
	if (existsSync(liveActivity)) copyFileSync(liveActivity, paths.activity_jsonl);
	else writeFileAtomic(paths.activity_jsonl, "");
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

export function readActiveRun(projectRoot: string): { project: ProjectIndex; active: ActiveRunPointer; metadata: RunMetadata | null } | null {
	const loaded = loadProjectIndex(projectRoot);
	if (!loaded || !existsSync(loaded.paths.active_run_json)) return null;
	const active = readJsonIfExists<ActiveRunPointer>(loaded.paths.active_run_json);
	if (!active) return null;
	const runPaths = resolveRunPaths(loaded.paths, active.run_id);
	return { active, metadata: readJsonIfExists<RunMetadata>(runPaths.metadata_json), project: loaded.project };
}

export function listRuns(projectRoot: string): { project: ProjectIndex; runs: RunMetadata[] } {
	const loaded = loadProjectIndex(projectRoot) ?? ensureProjectIndex(projectRoot);
	const runs: RunMetadata[] = [];
	if (existsSync(loaded.paths.runs_dir)) {
		for (const entry of readdirSync(loaded.paths.runs_dir)) {
			const metadata = readJsonIfExists<RunMetadata>(join(loaded.paths.runs_dir, entry, "metadata.json"));
			if (metadata) runs.push(metadata);
		}
	}
	runs.sort((a, b) => (b.started_at || "").localeCompare(a.started_at || ""));
	return { project: loaded.project, runs };
}

export function showRun(projectRoot: string, runId: string, snapshot?: string): RunShowResult {
	const loaded = loadProjectIndex(projectRoot);
	if (!loaded) throw new Error("project has no Flightdeck run store");
	const paths = resolveRunPaths(loaded.paths, safeRunId(runId));
	const metadata = readJsonIfExists<RunMetadata>(paths.metadata_json);
	if (!metadata) throw new Error(`run not found: ${runId}`);
	const snapshotName = snapshot ? safeSnapshotName(snapshot) : null;
	const statePath = snapshotName ? join(paths.snapshots_dir, snapshotName) : paths.state_json;
	if (!existsSync(statePath)) throw new Error(snapshotName ? `snapshot not found: ${snapshot}` : `state not found for run: ${runId}`);
	return {
		activity_path: metadata.activity_path,
		metadata,
		snapshot: snapshotName,
		snapshots: listSnapshotFiles(paths.snapshots_dir),
		state: JSON.parse(readFileSync(statePath, "utf8")) as unknown,
	};
}

export function terminateRun(projectRoot: string, runId: string): RunTerminateResult {
	const loaded = loadProjectIndex(projectRoot);
	if (!loaded) throw new Error("project has no Flightdeck run store");
	const paths = resolveRunPaths(loaded.paths, safeRunId(runId));
	const metadata = readJsonIfExists<RunMetadata>(paths.metadata_json);
	if (!metadata) throw new Error(`run not found: ${runId}`);
	const timestamp = metadata.terminated_at ?? nowIso();
	const nextMetadata: RunMetadata = {
		...metadata,
		last_seen_at: timestamp,
		terminated: true,
		terminated_at: timestamp,
	};
	mkdirSync(paths.snapshots_dir, { recursive: true });
	const state = readJsonIfExists<Record<string, unknown>>(paths.state_json) ?? initialRunState(metadata.tmux_session, metadata.started_at, paths.activity_jsonl);
	state.terminated = true;
	state.terminated_at = timestamp;
	writeJsonAtomic(paths.state_json, state);
	const snapshotPath = join(paths.snapshots_dir, `${safeArchiveTimestamp(timestamp)}.json`);
	writeJsonAtomic(snapshotPath, state);
	let activitySnapshotPath: string | null = null;
	if (existsSync(paths.activity_jsonl)) {
		activitySnapshotPath = join(paths.snapshots_dir, `${safeArchiveTimestamp(timestamp)}.activity.jsonl`);
		copyFileSync(paths.activity_jsonl, activitySnapshotPath);
	}
	writeJsonAtomic(paths.metadata_json, nextMetadata);
	const active = readJsonIfExists<ActiveRunPointer>(loaded.paths.active_run_json);
	let activeCleared = false;
	if (active?.run_id === metadata.run_id) {
		rmSync(loaded.paths.active_run_json, { force: true });
		activeCleared = true;
	}
	return { active_cleared: activeCleared, activity_snapshot_path: activitySnapshotPath, metadata: nextMetadata, snapshot_path: snapshotPath };
}

export function importLegacyArchives(projectRoot: string, stateDir?: string): LegacyImportResult {
	const timestamp = nowIso();
	const { project, paths: projectPaths } = ensureProjectIndex(projectRoot, timestamp);
	const dir = legacyStateDir(project.root_path, stateDir);
	const imported: RunMetadata[] = [];
	const skipped: RunMetadata[] = [];
	if (!existsSync(dir)) return { imported, project, skipped, state_dir: dir };
	for (const entry of readdirSync(dir).sort()) {
		if (!/^flightdeck-state-.+\.json\.archive$/.test(entry)) continue;
		const archivePath = join(dir, entry);
		const state = readJsonIfExists<Record<string, unknown>>(archivePath);
		if (!state) continue;
		const session = typeof state.session_id === "string" && state.session_id ? state.session_id : sessionFromArchiveName(entry);
		const startedAt = typeof state.started_at === "string" && state.started_at ? state.started_at : fileMtimeIso(archivePath);
		const terminatedAt = typeof state.terminated_at === "string" && state.terminated_at ? state.terminated_at : archiveTimestampFromName(entry) ?? startedAt;
		const runId = importedRunId(project.project_id, session, terminatedAt, entry);
		const paths = resolveRunPaths(projectPaths, runId);
		const existing = readJsonIfExists<RunMetadata>(paths.metadata_json);
		if (existing) {
			skipped.push(existing);
			continue;
		}
		mkdirSync(paths.snapshots_dir, { recursive: true });
		const legacyActivity = resolveLegacyActivityArchive(state, archivePath, session, terminatedAt);
		const normalizedState = { ...state, activity_path: paths.activity_jsonl, activity_archive_path: legacyActivity ? paths.activity_jsonl : null };
		writeJsonAtomic(paths.state_json, normalizedState);
		writeJsonAtomic(join(paths.snapshots_dir, `${safeArchiveTimestamp(terminatedAt)}.json`), normalizedState);
		if (legacyActivity) {
			copyFileSync(legacyActivity, paths.activity_jsonl);
			copyFileSync(legacyActivity, join(paths.snapshots_dir, `${safeArchiveTimestamp(terminatedAt)}.activity.jsonl`));
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
			terminated_at: terminatedAt,
			tmux_session: session,
		};
		writeJsonAtomic(paths.metadata_json, metadata);
		imported.push(metadata);
	}
	return { imported, project, skipped, state_dir: dir };
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
	if (!/^[A-Za-z0-9._-]+$/.test(clean)) throw new Error("run id must match ^[A-Za-z0-9._-]+$");
	return clean;
}

function requireNonEmpty(value: string, label: string): string {
	const clean = value.trim();
	if (!clean) throw new Error(`${label} must be non-empty`);
	return clean;
}

function newRunId(timestamp: string): string {
	return `run-${safeArchiveTimestamp(timestamp).replace(/[^0-9TZ-]/g, "")}-${randomBytes(4).toString("hex")}`;
}

function importedRunId(projectId: string, session: string, terminatedAt: string, archiveName: string): string {
	const suffix = sha256(`${projectId}\n${session}\n${terminatedAt}\n${archiveName}`).slice(0, 8);
	return `imported-${safeSegment(session, "session")}-${safeArchiveTimestamp(terminatedAt).replace(/[^0-9TZ-]/g, "")}-${suffix}`;
}

function safeArchiveTimestamp(ts: string): string {
	return ts.replace(/:/g, "");
}

function safeSnapshotName(value: string): string {
	const clean = value.trim();
	if (!/^[A-Za-z0-9._-]+\.json$/.test(clean)) return `${safeArchiveTimestamp(clean)}.json`;
	return clean;
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
	return readdirSync(snapshotsDir).filter((entry) => entry.endsWith(".json")).sort().reverse();
}

function sessionFromArchiveName(entry: string): string {
	const body = entry.replace(/^flightdeck-state-/, "").replace(/\.json\.archive$/, "");
	const match = body.match(/^(.*)-\d{4}-\d{2}-\d{2}T\d{6}Z$/);
	return match?.[1] || body;
}

function archiveTimestampFromName(entry: string): string | null {
	const match = entry.match(/-(\d{4}-\d{2}-\d{2}T\d{6}Z)\.json\.archive$/);
	if (!match) return null;
	const raw = match[1]!;
	return raw.replace(/T(\d{2})(\d{2})(\d{2})Z$/, "T$1:$2:$3Z");
}

function resolveLegacyActivityArchive(state: Record<string, unknown>, archivePath: string, session: string, terminatedAt: string): string | null {
	const explicit = typeof state.activity_archive_path === "string" && state.activity_archive_path ? state.activity_archive_path : "";
	if (explicit && existsSync(explicit)) return explicit;
	const stateDir = dirname(archivePath);
	const derived = join(stateDir, `flightdeck-activity-${session}-${safeArchiveTimestamp(terminatedAt)}.jsonl.archive`);
	if (existsSync(derived)) return derived;
	return null;
}

function fileMtimeIso(file: string): string {
	try {
		return statSync(file).mtime.toISOString().replace(/\.\d{3}Z$/, "Z");
	} catch {
		return nowIso();
	}
}

function readJsonIfExists<T>(path: string): T | null {
	if (!existsSync(path)) return null;
	try {
		return JSON.parse(readFileSync(path, "utf8")) as T;
	} catch {
		return null;
	}
}

function writeJsonAtomic(path: string, value: unknown): void {
	writeFileAtomic(path, `${JSON.stringify(value, null, 2)}\n`);
}

function writeFileAtomic(path: string, text: string): void {
	mkdirSync(dirname(path), { recursive: true });
	const tmp = `${path}.tmp.${process.pid}.${randomBytes(4).toString("hex")}`;
	writeFileSync(tmp, text, "utf8");
	renameSync(tmp, path);
}
