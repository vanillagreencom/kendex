import { realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

import { readPackageConfigAt, recordSettingsTrust, settingsFileTrusted, settingsMemo, userAndProjectSettingsPaths } from "./package-config.js";

/** Package id used as the config namespace key in `.pi/settings.json`. */
export const CONFIG_ID = "@vanillagreen/pi-nested-agents-md";

export type kendexConfig = Record<string, unknown>;

export const DEFAULTS = {
	enabled: true,
} as const;

/**
 * The renderer's own set, `crates/core/src/discover.rs` MARKER_DIRS and
 * `crates/core/src/lock.rs` LOCK_FILE, as pi-hooks carries it. The root this
 * finds is the bound on the walk, so it has to be the root kendex rendered
 * into. `.git/` is not a marker, or a vendored checkout would stop the walk
 * short of the project.
 */
export const PROJECT_MARKER_DIRS = [".claude", ".codex", ".opencode", ".cursor", ".pi", ".agents", ".gemini"] as const;
export const PROJECT_LOCK_FILE = ".kendex-lock.json";

/** A path with symlinks resolved, or its plain resolution when the filesystem
 * cannot answer. The home test below is a comparison, so both ends have to be
 * spelled the same way. */
function realpathOrResolve(path: string): string {
	try {
		return realpathSync(path);
	} catch {
		return resolve(path);
	}
}

/**
 * The project this session is in, or `undefined` where it is in none —
 * `crates/core/src/discover.rs::project_root_from`: the walk stops at home,
 * a `.kendex-lock.json` wins, home's own included, otherwise the nearest
 * ancestor carrying a marker directory. Home itself is not a project however
 * else it is marked, since home carries `.pi/` for nearly everyone, and
 * nothing above it answers for a start below it; a start outside home walks
 * to the filesystem root.
 *
 * Every successful `read` asks, so the answer is memoized per `cwd` for the
 * settings window, "no project" included: a stored `undefined` is an answer,
 * not a miss.
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

/** `project` is the caller's already-resolved project root; omitted, it is
 * resolved from `ctx.cwd`. */
export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }, project?: string | undefined): void {
	if (!ctx.cwd) return;
	const settings = projectSettingsPath(project === undefined ? projectRoot(ctx.cwd) : project);
	if (settings === undefined) return;
	recordSettingsTrust(settings, ctx);
}

/**
 * Merge config from user-level `.pi/settings.json` and the project-level
 * settings file. Project keys win. `projectDir` is the caller's already
 * resolved project root.
 */
export function readConfig(cwd: string, projectDir?: string | undefined): kendexConfig {
	const project = projectSettingsPath(projectDir === undefined ? projectRoot(cwd) : projectDir);
	const paths = userAndProjectSettingsPaths(project !== undefined && settingsFileTrusted(project) ? project : undefined);
	return readPackageConfigAt(CONFIG_ID, paths) as kendexConfig;
}

export function getBool(cfg: kendexConfig, key: keyof typeof DEFAULTS): boolean {
	const v = cfg[key];
	return typeof v === "boolean" ? v : DEFAULTS[key];
}
