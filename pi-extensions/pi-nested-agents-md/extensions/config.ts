import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

/** Package id used as the config namespace key in `.pi/settings.json`. */
export const CONFIG_ID = "@vanillagreen/pi-nested-agents-md";

export type kendexConfig = Record<string, unknown>;

export const DEFAULTS = {
	enabled: true,
} as const;

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

/**
 * Anchored to a named root, the way the renderer means it
 * (`crates/core/src/harness/pi.rs::pi_root_is_absolute_for`): a drive letter or
 * a UNC `\\server\share` on Windows, a leading `/` on POSIX. `isAbsolute` calls
 * a driveless `\root` absolute on Windows and the renderer does not, so the two
 * would read settings under different roots for one value of the variable.
 */
export function rootAnchored(path: string, windows: boolean): boolean {
	if (!windows) return path.startsWith("/");
	return /^[A-Za-z]:[\\/]/.test(path) || /^[\\/]{2}[^\\/]+[\\/][^\\/]+/.test(path);
}

/**
 * Pi's global root: `~/.pi/agent`, or `PI_CODING_AGENT_DIR` when it names a
 * root-anchored path. The global scope is trusted without asking because it
 * holds the person's own files; a blank or relative override would make it
 * whichever directory the session sits in, so such a value takes the default.
 */
export function piUserDir(): string {
	const override = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "");
	return resolve(rootAnchored(override, process.platform === "win32") ? override : expandHome("~/.pi/agent"));
}

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
 * `crates/core/src/discover.rs::project_root_from`: a `.kendex-lock.json`
 * wins wherever it stands, home included, otherwise the nearest ancestor
 * carrying a marker directory, and home itself is not a project however else
 * it is marked, since home carries `.pi/` for nearly everyone.
 */
export function projectRoot(cwd: string): string | undefined {
	const home = realpathOrResolve(homedir());
	let current: string | undefined = realpathOrResolve(cwd);
	while (current !== undefined) {
		if (isFile(join(current, PROJECT_LOCK_FILE))) return current;
		if (current !== home && PROJECT_MARKER_DIRS.some((marker) => isDir(join(current as string, marker)))) {
			return current;
		}
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

const PROJECT_TRUST_SYMBOL = Symbol.for("kendex.pi.project-trust");

interface ProjectTrustRegistry {
	projectSettings?: Map<string, boolean>;
}

function projectTrustRegistry(): ProjectTrustRegistry {
	const host = globalThis as unknown as Record<PropertyKey, ProjectTrustRegistry | undefined>;
	const existing = host[PROJECT_TRUST_SYMBOL];
	if (existing) return existing;
	const created: ProjectTrustRegistry = {};
	host[PROJECT_TRUST_SYMBOL] = created;
	return created;
}

/**
 * Pi's answer to "has this person trusted this workspace". Only a plain `true`
 * counts: a Pi with no such method, or one that throws, is not trusted. This
 * gates reading the project's settings, which is safe to withhold.
 */
export function projectTrusted(ctx: { isProjectTrusted?: () => boolean }): boolean {
	try {
		return ctx.isProjectTrusted?.() === true;
	} catch {
		return false;
	}
}

/** `project` is the caller's already-resolved project root; omitted, it is
 * resolved from `ctx.cwd`. */
export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }, project?: string | undefined): void {
	if (!ctx.cwd) return;
	const settings = projectSettingsPath(project === undefined ? projectRoot(ctx.cwd) : project);
	if (settings === undefined) return;
	const trusted = projectTrusted(ctx);
	const registry = projectTrustRegistry();
	if (!registry.projectSettings) registry.projectSettings = new Map();
	registry.projectSettings.set(settings, trusted);
}

function projectSettingsTrusted(settingsPath: string): boolean {
	return projectTrustRegistry().projectSettings?.get(settingsPath) === true;
}

function loadJson(path: string): unknown {
	if (!existsSync(path)) return undefined;
	try {
		return JSON.parse(readFileSync(path, "utf8"));
	} catch {
		return undefined;
	}
}

/**
 * Merge config from user-level `.pi/settings.json` and the project-level
 * settings file. Project keys win. `projectDir` is the caller's already
 * resolved project root.
 */
export function readConfig(cwd: string, projectDir?: string | undefined): kendexConfig {
	const merged: kendexConfig = {};
	const project = projectSettingsPath(projectDir === undefined ? projectRoot(cwd) : projectDir);
	const paths = [
		join(piUserDir(), "settings.json"),
		...(project !== undefined && projectSettingsTrusted(project) ? [project] : []),
	];
	for (const path of paths) {
		const parsed = loadJson(path) as
			| { kendex?: { extensionManager?: { config?: Record<string, kendexConfig> } } }
			| undefined;
		const cfg = parsed?.kendex?.extensionManager?.config?.[CONFIG_ID];
		if (cfg && typeof cfg === "object" && !Array.isArray(cfg)) {
			Object.assign(merged, cfg);
		}
	}
	return merged;
}

export function getBool(cfg: kendexConfig, key: keyof typeof DEFAULTS): boolean {
	const v = cfg[key];
	return typeof v === "boolean" ? v : DEFAULTS[key];
}
