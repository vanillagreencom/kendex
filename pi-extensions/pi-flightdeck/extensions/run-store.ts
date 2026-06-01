import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, lstatSync, readFileSync, readdirSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";

// Read-only mirror of skills/flightdeck/lib/flightdeck-core/src/state/run-store.ts.
// pi-flightdeck must not shell to `flightdeck-state path` because that creates
// active runs as a side effect. Keep this module fail-closed and read-only:
// validate project identity, storage perms, symlinks, active pointer, run
// metadata, and canonical containment before returning an active state path.

const RUN_STORE_SCHEMA_VERSION = 1;
const STORE_FILE_MODE = 0o600;

type StoreOwnershipPolicy = "strict" | "ancestor";

interface ProjectIdentity {
	project_id: string;
	name: string;
	root_path: string;
	root_hash: string;
	remote_url: string | null;
	id_source: "git-remote+root" | "root";
}

interface ProjectIndex extends ProjectIdentity {
	schema_version: 1;
	created_at: string;
	last_seen_at: string;
}

interface ActiveRunPointer {
	schema_version: 1;
	project_id: string;
	run_id: string;
	tmux_session: string;
	state_path: string;
	activity_path: string;
	updated_at: string;
}

interface RunMetadata {
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

interface ProjectRunPaths {
	store_root: string;
	project_dir: string;
	project_json: string;
	active_runs_dir: string;
	active_run_json: string;
	runs_dir: string;
}

interface RunPaths {
	run_dir: string;
	metadata_json: string;
	state_json: string;
	activity_jsonl: string;
	snapshots_dir: string;
}

export interface ActiveRunStateResolution {
	statePath?: string;
	diagnosticPath?: string;
	error?: string;
}

const PROJECT_ID_CACHE = new Map<string, string>();
const DOT_ENV_CACHE = new Map<string, { values?: Map<string, string>; error?: string }>();

export function resetRunStoreCacheForTests(): void {
	PROJECT_ID_CACHE.clear();
	DOT_ENV_CACHE.clear();
}

function sha256(value: string): string {
	return createHash("sha256").update(value).digest("hex");
}

function safeSegment(value: string, fallback = "project"): string {
	const cleaned = value.trim().toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48);
	return cleaned || fallback;
}

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

function parseDotEnvNonExecuting(text: string, path: string): Map<string, string> {
	const values = new Map<string, string>();
	const assignmentLines = new Map<string, number>();
	const unsupported = new Map<string, string>();
	let lastEnvDirectiveLine = 0;
	let lineNumber = 0;
	for (const rawLine of text.split(/\r?\n/)) {
		lineNumber += 1;
		const line = rawLine.trim();
		if (!line || line.startsWith("#")) continue;
		const stripped = line.replace(/^export\s+/, "").trim();
		if (hasEnvMutatingDirective(stripped)) {
			lastEnvDirectiveLine = lineNumber;
			const reason = `unsupported env-mutating directive at ${path}:${lineNumber}`;
			values.delete("FLIGHTDECK_RUN_STORE_ROOT");
			assignmentLines.delete("FLIGHTDECK_RUN_STORE_ROOT");
			unsupported.set("FLIGHTDECK_RUN_STORE_ROOT", reason);
		}
		const hasRunStoreAssignment = /(?:^|[;\s])(?:export\s+)?FLIGHTDECK_RUN_STORE_ROOT(?:\s*(?:\[|\+?=)|\S*=)/.test(stripped);
		const eq = stripped.indexOf("=");
		if (eq <= 0) {
			if (hasRunStoreAssignment) throw new Error(`unsupported FLIGHTDECK_RUN_STORE_ROOT assignment at ${path}:${lineNumber}`);
			throw new Error(`unsupported .env directive at ${path}:${lineNumber}`);
		}
		const rawKey = stripped.slice(0, eq);
		const rawValue = stripped.slice(eq + 1);
		const key = rawKey.trim();
		const hasAssignmentWhitespace = rawKey !== key || /^\s/.test(rawValue);
		if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
			const unsupportedKey = unsupportedAssignmentVariable(key);
			if (unsupportedKey) {
				const reason = `unsupported assignment for ${unsupportedKey} at ${path}:${lineNumber}`;
				values.delete(unsupportedKey);
				assignmentLines.delete(unsupportedKey);
				unsupported.set(unsupportedKey, reason);
				throw new Error(reason);
			}
			if (hasRunStoreAssignment) throw new Error(`unsupported FLIGHTDECK_RUN_STORE_ROOT assignment at ${path}:${lineNumber}`);
			throw new Error(`unsupported .env assignment at ${path}:${lineNumber}`);
		}
		if (key !== "FLIGHTDECK_RUN_STORE_ROOT" && hasRunStoreAssignment) {
			throw new Error(`unsupported FLIGHTDECK_RUN_STORE_ROOT assignment at ${path}:${lineNumber}`);
		}
		if (hasAssignmentWhitespace) {
			const reason = `unsupported whitespace around assignment at ${path}:${lineNumber}`;
			values.delete(key);
			assignmentLines.delete(key);
			unsupported.set(key, reason);
			throw new Error(reason);
		}
		const valueText = rawValue.trim();
		try {
			const value = parseDotEnvValue(valueText, (ref) => {
				const unsupportedReason = unsupported.get(ref);
				if (unsupportedReason) throw new Error(`unsupported variable reference ${ref}: ${unsupportedReason}`);
				const assignmentLine = assignmentLines.get(ref);
				if (assignmentLine !== undefined) {
					if (assignmentLine <= lastEnvDirectiveLine) {
						throw new Error(`unsupported variable reference ${ref}: env-mutating directive at ${path}:${lastEnvDirectiveLine}`);
					}
					return values.get(ref);
				}
				if (lastEnvDirectiveLine > 0) {
					throw new Error(`unsupported variable reference ${ref}: env-mutating directive at ${path}:${lastEnvDirectiveLine}`);
				}
				return process.env[ref];
			}, path, lineNumber);
			values.set(key, value);
			assignmentLines.set(key, lineNumber);
			unsupported.delete(key);
		} catch (error) {
			const reason = error instanceof Error ? error.message : String(error);
			values.delete(key);
			assignmentLines.delete(key);
			unsupported.set(key, reason);
			throw error;
		}
	}
	const runStoreError = unsupported.get("FLIGHTDECK_RUN_STORE_ROOT");
	if (runStoreError) throw new Error(runStoreError);
	return values.has("FLIGHTDECK_RUN_STORE_ROOT") ? new Map([["FLIGHTDECK_RUN_STORE_ROOT", values.get("FLIGHTDECK_RUN_STORE_ROOT") ?? ""]]) : new Map();
}

function hasEnvMutatingDirective(stripped: string): boolean {
	return /(?:^|[;\s])(?:source|\.)(?:\s+\S+|\$\{?IFS\}?\S*)/.test(stripped);
}

function unsupportedAssignmentVariable(key: string): string | undefined {
	let match = /^([A-Za-z_][A-Za-z0-9_]*)\+$/.exec(key);
	if (match) return match[1];
	match = /^([A-Za-z_][A-Za-z0-9_]*)\[.*\]\+$/.exec(key);
	if (match) return match[1];
	match = /^([A-Za-z_][A-Za-z0-9_]*)\[.*\]$/.exec(key);
	return match?.[1];
}

function parseDotEnvValue(raw: string, lookup: (key: string) => string | undefined, path: string, lineNumber: number): string {
	if (raw === "") return "";
	if (raw.includes("\\")) throw new Error(`unsupported escape syntax at ${path}:${lineNumber}`);
	let text = raw;
	let expand = true;
	if (raw.startsWith("'")) {
		if (!raw.endsWith("'") || raw.length < 2) throw new Error(`unterminated single-quoted value at ${path}:${lineNumber}`);
		text = raw.slice(1, -1);
		if (text.includes("'")) throw new Error(`unsupported trailing tokens after quoted value at ${path}:${lineNumber}`);
		expand = false;
	} else if (raw.startsWith('"')) {
		if (!raw.endsWith('"') || raw.length < 2) throw new Error(`unterminated double-quoted value at ${path}:${lineNumber}`);
		text = raw.slice(1, -1);
		if (text.includes('"')) throw new Error(`unsupported trailing tokens after quoted value at ${path}:${lineNumber}`);
	} else if (/[`;&|<>$]/.test(raw)) {
		if (!raw.includes("$(") && !/[`;&|<>]/.test(raw) && /\s/.test(raw)) {
			throw new Error(`unsupported whitespace in value at ${path}:${lineNumber}`);
		}
		text = raw;
	} else if (/\s/.test(raw)) {
		throw new Error(`unsupported whitespace in value at ${path}:${lineNumber}`);
	}
	if (/[`;&|<>()]/.test(text) || text.includes("$")) {
		// Only non-executing variable expansion is supported. Command
		// substitution, source directives, separators, pipes, and redirects
		// are rejected rather than executed during dashboard polling.
		if (!isSupportedNonExecutingExpansion(text)) {
			throw new Error(`unsupported shell expansion at ${path}:${lineNumber}`);
		}
	}
	if (!expand) {
		if (text === "~" || text.startsWith("~/")) throw new Error(`unsupported tilde expansion at ${path}:${lineNumber}`);
		return text;
	}
	const expanded = expandEnvValue(text, lookup, path, lineNumber);
	if (expanded === "~" || expanded.startsWith("~/")) throw new Error(`unsupported tilde expansion at ${path}:${lineNumber}`);
	return expanded;
}

function isSupportedNonExecutingExpansion(text: string): boolean {
	let i = 0;
	while (i < text.length) {
		const char = text[i];
		if (char === "`" || char === ";" || char === "&" || char === "|" || char === "<" || char === ">" || char === "(" || char === ")") return false;
		if (char !== "$") {
			i += 1;
			continue;
		}

		const next = text[i + 1];
		if (next === "{") {
			let j = i + 2;
			if (!isEnvNameStart(text[j] ?? "")) return false;
			j += 1;
			while (j < text.length && isEnvNameChar(text[j] ?? "")) j += 1;
			if (text[j] !== "}") return false;
			i = j + 1;
			continue;
		}

		if (!isEnvNameStart(next ?? "")) return false;
		i += 2;
		while (i < text.length && isEnvNameChar(text[i] ?? "")) i += 1;
	}
	return true;
}

function isEnvNameStart(char: string): boolean {
	if (!char) return false;
	const code = char.charCodeAt(0);
	return char === "_" || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function isEnvNameChar(char: string): boolean {
	if (!char) return false;
	const code = char.charCodeAt(0);
	return isEnvNameStart(char) || (code >= 48 && code <= 57);
}

function expandEnvValue(text: string, lookup: (key: string) => string | undefined, path: string, lineNumber: number): string {
	return text.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g, (_match, braced: string | undefined, bare: string | undefined) => {
		const key = braced ?? bare ?? "";
		const value = lookup(key);
		if (value === undefined) throw new Error(`undefined variable ${key} at ${path}:${lineNumber}`);
		return value;
	});
}

function loadProjectDotEnvValues(projectRoot: string): Map<string, string> {
	const root = resolve(projectRoot);
	const cached = DOT_ENV_CACHE.get(root);
	if (cached?.error) throw new Error(cached.error);
	if (cached?.values) return cached.values;
	const envLocal = join(root, ".env.local");
	const envBase = join(root, ".env");
	const target = existsSync(envLocal) ? envLocal : existsSync(envBase) ? envBase : "";
	if (!target) {
		const values = new Map<string, string>();
		DOT_ENV_CACHE.set(root, { values });
		return values;
	}
	let text = "";
	try {
		text = readFileSync(target, "utf8");
	} catch (error) {
		const message = `.env read failed: ${error instanceof Error ? error.message : String(error)}`;
		DOT_ENV_CACHE.set(root, { error: message });
		throw new Error(message);
	}
	try {
		const values = parseDotEnvNonExecuting(text, target);
		DOT_ENV_CACHE.set(root, { values });
		return values;
	} catch (error) {
		const message = `.env load failed: ${error instanceof Error ? error.message : String(error)}`;
		DOT_ENV_CACHE.set(root, { error: message });
		throw new Error(message);
	}
}

function runStoreRoot(projectRoot: string): string {
	const envValues = loadProjectDotEnvValues(projectRoot);
	const override = envValues.has("FLIGHTDECK_RUN_STORE_ROOT")
		? nonEmpty(envValues.get("FLIGHTDECK_RUN_STORE_ROOT"))
		: nonEmpty(process.env.FLIGHTDECK_RUN_STORE_ROOT);
	if (override) return resolve(expandHome(override));
	const home = typeof process.env.HOME === "string" && process.env.HOME.trim() ? process.env.HOME.trim() : homedir();
	return join(home, ".vstack", "flightdeck");
}

function gitRemoteUrl(projectRoot: string): string | null {
	const origin = spawnSync("git", ["-C", projectRoot, "config", "--get", "remote.origin.url"], { encoding: "utf8", timeout: 1500 });
	if (origin.status === 0 && origin.stdout.trim()) return origin.stdout.trim();
	const first = spawnSync("git", ["-C", projectRoot, "remote"], { encoding: "utf8", timeout: 1500 });
	const remote = (first.stdout ?? "").split("\n").map((line) => line.trim()).find(Boolean);
	if (!remote) return null;
	const value = spawnSync("git", ["-C", projectRoot, "config", "--get", `remote.${remote}.url`], { encoding: "utf8", timeout: 1500 });
	return value.status === 0 && value.stdout.trim() ? value.stdout.trim() : null;
}

function remoteRepoName(remoteUrl: string): string {
	const stripped = remoteUrl.trim().replace(/[?#].*$/, "").replace(/\.git$/, "");
	const parts = stripped.split(/[/:]/).filter(Boolean);
	return parts[parts.length - 1] || "project";
}

function projectIdentity(projectRoot: string): ProjectIdentity {
	const root = resolve(projectRoot);
	const cached = PROJECT_ID_CACHE.get(root);
	if (cached) {
		const remoteUrl = gitRemoteUrl(root);
		const rootHash = sha256(root);
		const name = remoteUrl ? remoteRepoName(remoteUrl) : basename(root) || "project";
		return { id_source: remoteUrl ? "git-remote+root" : "root", name, project_id: cached, remote_url: remoteUrl, root_hash: rootHash, root_path: root };
	}
	const remoteUrl = gitRemoteUrl(root);
	const rootHash = sha256(root);
	const name = remoteUrl ? remoteRepoName(remoteUrl) : basename(root) || "project";
	const identityMaterial = remoteUrl ? `${remoteUrl}\n${rootHash}` : rootHash;
	const projectId = `${safeSegment(name)}-${sha256(identityMaterial).slice(0, 16)}`;
	PROJECT_ID_CACHE.set(root, projectId);
	return {
		id_source: remoteUrl ? "git-remote+root" : "root",
		name,
		project_id: projectId,
		remote_url: remoteUrl,
		root_hash: rootHash,
		root_path: root,
	};
}

function projectRunPaths(identity: ProjectIdentity): ProjectRunPaths {
	const root = runStoreRoot(identity.root_path);
	const projectDir = join(root, "projects", identity.project_id);
	return {
		active_run_json: join(projectDir, "active-run.json"),
		active_runs_dir: join(projectDir, "active-runs"),
		project_dir: projectDir,
		project_json: join(projectDir, "project.json"),
		runs_dir: join(projectDir, "runs"),
		store_root: root,
	};
}

function runPaths(paths: ProjectRunPaths, runId: string): RunPaths {
	const runDir = join(paths.runs_dir, safeRunId(runId));
	return {
		activity_jsonl: join(runDir, "activity.jsonl"),
		metadata_json: join(runDir, "metadata.json"),
		run_dir: runDir,
		snapshots_dir: join(runDir, "snapshots"),
		state_json: join(runDir, "state.json"),
	};
}

export function resolveActiveRunStatePath(projectRoot: string, tmuxSession: string): ActiveRunStateResolution {
	try {
		const session = safeLegacySessionName(tmuxSession);
		const identity = projectIdentity(projectRoot);
		const paths = projectRunPaths(identity);
		if (!assertSafeExistingStoreRoot(paths.store_root)) return {};
		if (!assertStorageDirectoryIfExists(join(paths.store_root, "projects"), "run-store projects dir", "ancestor")) return {};
		if (!assertStorageDirectoryIfExists(paths.project_dir, "project directory")) return {};
		const project = readProjectIndex(paths.project_json);
		if (!project) {
			if (hasDurableProjectArtifacts(paths, session)) return { diagnosticPath: paths.project_json, error: `project index missing while durable run artifacts exist: ${paths.project_json}` };
			return {};
		}
		validateProjectIndexIdentity(project, identity, paths.project_json);

		const activeRead = readActivePointerForSession(paths, session);
		if (!activeRead) return {};
		validateActivePointerProject(activeRead.active, identity.project_id, activeRead.path);
		if (activeRead.active.tmux_session !== session) {
			return { diagnosticPath: activeRead.path, error: `active run pointer tmux_session mismatch: ${activeRead.active.tmux_session} != ${session}` };
		}
		const activePaths = runPaths(paths, activeRead.active.run_id);
		const metadata = readRunMetadataForRun(activePaths, identity.project_id, activeRead.active.run_id, identity.root_path);
		if (!metadata) return { diagnosticPath: activePaths.metadata_json, error: `active run metadata missing: ${activePaths.metadata_json}` };
		if (metadata.tmux_session !== session) {
			return { diagnosticPath: activePaths.metadata_json, error: `run metadata tmux_session mismatch: ${metadata.tmux_session} != ${session}` };
		}
		assertMetadataPath(activeRead.path, "state_path", activeRead.active.state_path, activePaths.state_json);
		if (!existsSync(activePaths.state_json)) return { diagnosticPath: activePaths.state_json, error: `active run state missing: ${activePaths.state_json}` };
		assertRunStorageFile(activePaths, activePaths.state_json, "run state");
		return { diagnosticPath: activeRead.path, statePath: activePaths.state_json };
	} catch (error) {
		return { error: error instanceof Error ? error.message : String(error) };
	}
}

function hasDurableProjectArtifacts(paths: ProjectRunPaths, session: string): boolean {
	if (assertStorageFileIfExists(paths.active_run_json, "active run pointer")) return true;
	if (assertStorageDirectoryIfExists(paths.active_runs_dir, "active runs directory")) {
		if (assertStorageFileIfExists(join(paths.active_runs_dir, `${session}.json`), "active run pointer")) return true;
		if (safeDirectoryEntries(paths.active_runs_dir).some((entry) => isSafeBasename(entry))) return true;
	}
	if (assertStorageDirectoryIfExists(paths.runs_dir, "runs directory")) {
		if (safeDirectoryEntries(paths.runs_dir).some((entry) => isSafeBasename(entry))) return true;
	}
	return false;
}

function safeDirectoryEntries(path: string): string[] {
	try {
		return readdirSync(path);
	} catch (error) {
		throw new Error(`failed to read directory ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
}

function readActivePointerForSession(paths: ProjectRunPaths, session: string): { active: ActiveRunPointer; path: string } | undefined {
	assertStorageDirectoryIfExists(paths.active_runs_dir, "active runs directory");
	const sessionPath = join(paths.active_runs_dir, `${session}.json`);
	const sessionActive = readActivePointer(sessionPath);
	if (sessionActive) return { active: sessionActive, path: sessionPath };
	const legacyActive = readActivePointer(paths.active_run_json);
	if (!legacyActive || legacyActive.tmux_session !== session) return undefined;
	return { active: legacyActive, path: paths.active_run_json };
}

function assertSafeExistingStoreRoot(root: string): boolean {
	if (!isAbsolute(root)) throw new Error(`invalid run-store root ${root}: must be an absolute path`);
	const segments = root.split("/").filter(Boolean);
	let current = "/";
	for (const segment of segments) {
		current = current === "/" ? `/${segment}` : `${current}/${segment}`;
		let stat: ReturnType<typeof lstatSync>;
		try {
			stat = lstatSync(current);
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
			throw new Error(`failed to inspect run-store root ${current}: ${error instanceof Error ? error.message : String(error)}`);
		}
		if (stat.isSymbolicLink()) throw new Error(`invalid run-store root ${root}: ancestor ${current} is a symlink`);
		if (!stat.isDirectory()) throw new Error(`invalid run-store root ${root}: ancestor ${current} is not a directory`);
	}
	assertStoreOwnership(lstatSync(root), root, "run-store root", "ancestor");
	return true;
}

function assertStorageDirectoryIfExists(path: string, label: string, policy: StoreOwnershipPolicy = "ancestor"): boolean {
	let stat: ReturnType<typeof lstatSync>;
	try {
		stat = lstatSync(path);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
		throw new Error(`failed to inspect ${label} ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (stat.isSymbolicLink()) throw new Error(`invalid ${label} ${path}: symlinks are not allowed`);
	if (!stat.isDirectory()) throw new Error(`invalid ${label} ${path}: expected directory`);
	assertStoreOwnership(stat, path, label, policy);
	return true;
}

function assertStorageFileIfExists(path: string, label: string): boolean {
	let stat: ReturnType<typeof lstatSync>;
	try {
		stat = lstatSync(path);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
		throw new Error(`failed to inspect ${label} ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (stat.isSymbolicLink()) throw new Error(`invalid ${label} ${path}: symlinks are not allowed`);
	if (!stat.isFile()) throw new Error(`invalid ${label} ${path}: expected regular file`);
	assertStoreOwnership(stat, path, label, "strict");
	return true;
}

function assertStoreOwnership(stat: { uid?: number; mode: number; isDirectory?: () => boolean }, path: string, label: string, policy: StoreOwnershipPolicy): void {
	const uid = typeof process.getuid === "function" ? process.getuid() : null;
	if (uid !== null && typeof stat.uid === "number" && stat.uid !== uid) {
		throw new Error(`invalid ${label} ${path}: owned by uid ${stat.uid}, not ${uid}`);
	}
	const masked = stat.mode & 0o777;
	const isDir = typeof stat.isDirectory === "function" && stat.isDirectory();
	if ((masked & 0o022) !== 0) throw new Error(`invalid ${label} ${path}: group/other write bits set (mode=${masked.toString(8)})`);
	if (policy === "ancestor" || isDir) return;
	if (masked !== STORE_FILE_MODE) throw new Error(`invalid ${label} ${path}: mode=${masked.toString(8)} expected ${STORE_FILE_MODE.toString(8)}`);
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

function assertPathContained(root: string, candidate: string, label: string): void {
	const realRoot = realpathSync(root);
	const realCandidate = realpathSync(candidate);
	if (!isPathInside(realRoot, realCandidate)) throw new Error(`invalid ${label} ${candidate}: path escapes ${root}`);
}

function readProjectIndex(path: string): ProjectIndex | undefined {
	const raw = readStorageJsonObject(path, "project index");
	if (!raw) return undefined;
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

function readActivePointer(path: string): ActiveRunPointer | undefined {
	const raw = readStorageJsonObject(path, "active run pointer");
	if (!raw) return undefined;
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

function readRunMetadata(path: string): RunMetadata | undefined {
	const raw = readStorageJsonObject(path, "run metadata");
	if (!raw) return undefined;
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

function readRunMetadataForRun(paths: RunPaths, expectedProjectId: string, expectedRunId: string, expectedProjectRoot: string): RunMetadata | undefined {
	assertRunStoragePaths(paths);
	const metadata = readRunMetadata(paths.metadata_json);
	if (!metadata) return undefined;
	validateRunMetadataIdentity(metadata, paths.metadata_json, expectedProjectId, expectedRunId);
	validateRunMetadataPaths(metadata, paths.metadata_json, expectedProjectRoot, paths);
	return metadata;
}

function readStorageJsonObject(path: string, label: string): Record<string, unknown> | undefined {
	if (!assertStorageFileIfExists(path, label)) return undefined;
	const raw = readJsonObject(path, label);
	assertStorageFileIfExists(path, label);
	return raw;
}

function readJsonObject(path: string, label: string): Record<string, unknown> {
	let text: string;
	try {
		text = readFileSync(path, "utf8");
	} catch (error) {
		throw new Error(`failed to read JSON ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
	let value: unknown;
	try {
		value = JSON.parse(text);
	} catch (error) {
		throw new Error(`invalid JSON in ${path}: ${error instanceof Error ? error.message : String(error)}`);
	}
	if (!isRecord(value)) throw new Error(`invalid ${label} JSON ${path}: expected object`);
	return value;
}

function validateProjectIndexIdentity(project: ProjectIndex, identity: ProjectIdentity, path: string): void {
	if (project.project_id !== identity.project_id) throw new Error(`invalid project index JSON ${path}: project_id ${project.project_id} does not match current project ${identity.project_id}`);
	if (resolve(project.root_path) !== identity.root_path) throw new Error(`invalid project index JSON ${path}: root_path ${project.root_path} does not match current project ${identity.root_path}`);
	if (project.root_hash !== identity.root_hash) throw new Error(`invalid project index JSON ${path}: root_hash ${project.root_hash} does not match current project ${identity.root_hash}`);
	if (project.remote_url !== identity.remote_url) throw new Error(`invalid project index JSON ${path}: remote_url ${String(project.remote_url)} does not match current project ${String(identity.remote_url)}`);
	if (project.id_source !== identity.id_source) throw new Error(`invalid project index JSON ${path}: id_source ${project.id_source} does not match current project ${identity.id_source}`);
	if (project.name !== identity.name) throw new Error(`invalid project index JSON ${path}: name ${project.name} does not match current project ${identity.name}`);
}

function validateActivePointerProject(active: ActiveRunPointer, expectedProjectId: string, path: string): void {
	if (active.project_id !== expectedProjectId) throw new Error(`invalid active run pointer JSON ${path}: project_id ${active.project_id} does not match project ${expectedProjectId}`);
}

function validateRunMetadataIdentity(metadata: RunMetadata, path: string, expectedProjectId: string, expectedRunId: string): void {
	if (metadata.project_id !== expectedProjectId) throw new Error(`invalid run metadata JSON ${path}: project_id ${metadata.project_id} does not match project ${expectedProjectId}`);
	if (metadata.run_id !== expectedRunId) throw new Error(`invalid run metadata JSON ${path}: run_id ${metadata.run_id} does not match requested run ${expectedRunId}`);
}

function validateRunMetadataPaths(metadata: RunMetadata, path: string, expectedProjectRoot: string, paths: RunPaths): void {
	assertMetadataPath(path, "project_root", metadata.project_root, expectedProjectRoot);
	assertMetadataPath(path, "state_path", metadata.state_path, paths.state_json);
	assertMetadataPath(path, "activity_path", metadata.activity_path, paths.activity_jsonl);
	assertMetadataPath(path, "snapshots_path", metadata.snapshots_path, paths.snapshots_dir);
}

function assertMetadataPath(metadataPath: string, field: string, actual: string, expected: string): void {
	if (resolve(actual) !== resolve(expected)) throw new Error(`invalid run metadata JSON ${metadataPath}: ${field} ${actual} does not match canonical path ${expected}`);
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

function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function isPathInside(parent: string, child: string): boolean {
	const rel = relative(parent, child);
	return rel === "" || (!!rel && !rel.startsWith("..") && !isAbsolute(rel));
}
