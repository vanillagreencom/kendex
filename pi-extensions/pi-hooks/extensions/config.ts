import { realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

import { readPackageConfigAt, recordSettingsTrust, settingsFileTrusted, settingsMemo, userAndProjectSettingsPaths } from "./package-config.js";

/** Package id used as the config namespace key in `.pi/settings.json`. */
export const CONFIG_ID = "@vanillagreen/pi-hooks";

export type kendexConfig = Record<string, unknown>;

/**
 * Conservative defaults. All hooks enabled. The 30s clippy budget keeps the
 * end-of-turn run slow but not unbounded.
 */
export const DEFAULTS = {
	enabled: true,
	blockBareCd: true,
	blockRepoCopy: true,
	preCommitCheck: true,
	taskCompletedCheck: true,
	sessionDriftCheck: true,
	clippyTimeoutMs: 30000,
	driftCheckTimeoutMs: 30000,
} as const;

export type HookKey = Exclude<keyof typeof DEFAULTS, "clippyTimeoutMs" | "driftCheckTimeoutMs">;

/**
 * The renderer's own set, copied from `crates/core/src/discover.rs` MARKER_DIRS
 * and `crates/core/src/lock.rs` LOCK_FILE, and held there by tests/hooks.test.ts.
 * It has to be that set: the renderer decides where the guards are written and
 * this decides where they are read, so a directory only one of them calls a
 * project is a guard rendered at one root and looked for at another — a command
 * allowed with nothing spawned and nothing said. `.git/` is not a marker, or a
 * vendored checkout would stop the walk short of the root holding the guards.
 *
 * `is_project`'s MARKER_FILES list is deliberately not here. The current-project
 * rule is `project_root_from` (its only caller is `current_project` in
 * `crates/cli/src/commands/mod.rs`), and it reads the marker directories and the
 * lock file alone; `is_project` answers which repositories a scan should offer.
 */
const PROJECT_MARKER_DIRS = [".claude", ".codex", ".opencode", ".cursor", ".pi", ".agents", ".gemini"] as const;
export const PROJECT_LOCK_FILE = ".kendex-lock.json";

/** A path with symlinks resolved, or its plain resolution when the filesystem
 * cannot answer. The home test below is a comparison, so both ends have to be
 * spelled the same way; `resolve` normalizes `.` and `..` and stops there. */
function realpathOrResolve(path: string): string {
	try {
		return realpathSync(path);
	} catch {
		return resolve(path);
	}
}

/**
 * The project this session is in, or `undefined` where it is in none —
 * `crates/core/src/discover.rs::project_root_from`, which is what kendex asks
 * before it renders anything: the walk stops at home, a `.kendex-lock.json`
 * wins, home's own included, otherwise the nearest ancestor carrying a marker
 * directory. Home itself is not a project however else it is marked, and
 * nothing above it answers for a start below it; a start outside home walks to
 * the filesystem root. Home carries `.pi/` for nearly everyone, and Pi's own
 * global root lives inside it.
 *
 * Walking rather than taking `cwd` is what makes a session started in a
 * subdirectory read the same settings and run the same guards as one at the
 * repository root — which is how Pi answers trust too: a saved decision applies
 * to the folder or any parent, held in `~/.pi/agent/trust.json`.
 *
 * Every hook event asks, so the answer is memoized per `cwd` for the settings
 * window, "no project" included: a stored `undefined` is an answer, not a miss.
 */
export function projectRoot(cwd: string): string | undefined {
	return settingsMemo(`project-root\0${cwd}`, () => walkProjectRoot(cwd));
}

function walkProjectRoot(cwd: string): string | undefined {
	const home = realpathOrResolve(homedir());
	let current: string | undefined = realpathOrResolve(cwd);
	while (current !== undefined) {
		if (isFile(join(current, PROJECT_LOCK_FILE))) return current;
		if (current === home) return undefined;
		if (PROJECT_MARKER_DIRS.some((marker) => isDir(join(current as string, marker)))) return current;
		const parent = dirname(current);
		current = parent === current ? undefined : parent;
	}
	return undefined;
}

/** A marker counts only in the shape the renderer tests for: `is_dir` for the
 * directories, `is_file` for the lock. A `.pi` FILE is not a project. */
function isDir(path: string): boolean {
	try {
		return statSync(path).isDirectory();
	} catch {
		return false;
	}
}

function isFile(path: string): boolean {
	try {
		return statSync(path).isFile();
	} catch {
		return false;
	}
}

function projectSettingsPath(project: string | undefined): string | undefined {
	return project === undefined ? undefined : join(project, ".pi", "settings.json");
}

/**
 * `project` is the caller's already-resolved project root, since the walk that
 * finds it costs an ancestor `stat` per level and a `tool_call` needs the same
 * answer three times over. Omitted, it is resolved from `ctx.cwd`.
 */
export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }, project?: string | undefined): void {
	if (!ctx.cwd) return;
	const settings = projectSettingsPath(project === undefined ? projectRoot(ctx.cwd) : project);
	if (settings === undefined) return;
	recordSettingsTrust(settings, ctx);
}

/**
 * Merge config from user-level `.pi/settings.json` and the project-level
 * settings file. Project keys win. `projectDir` is the caller's already
 * resolved project root, for the same reason `recordProjectTrust` takes one.
 */
export function readConfig(cwd: string, projectDir?: string | undefined): kendexConfig {
	const project = projectSettingsPath(projectDir === undefined ? projectRoot(cwd) : projectDir);
	const paths = userAndProjectSettingsPaths(project !== undefined && settingsFileTrusted(project) ? project : undefined);
	return readPackageConfigAt(CONFIG_ID, paths) as kendexConfig;
}

export function getBool(cfg: kendexConfig, key: HookKey | "enabled"): boolean {
	const v = cfg[key];
	return typeof v === "boolean" ? v : (DEFAULTS[key] as boolean);
}

export function getNumber(cfg: kendexConfig, key: "clippyTimeoutMs" | "driftCheckTimeoutMs"): number {
	const v = cfg[key];
	if (typeof v === "number" && Number.isFinite(v) && v > 0) return v;
	if (typeof v === "string") {
		const parsed = Number(v);
		if (Number.isFinite(parsed) && parsed > 0) return parsed;
	}
	return DEFAULTS[key];
}
