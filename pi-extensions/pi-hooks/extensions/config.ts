import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

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
	hookTimeoutMs: 60000,
} as const;

export type HookKey = Exclude<keyof typeof DEFAULTS, "clippyTimeoutMs" | "driftCheckTimeoutMs" | "hookTimeoutMs">;

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

/**
 * Anchored to a named root, the way the renderer means it
 * (`crates/core/src/harness/pi.rs::pi_root_is_absolute_for`): a drive letter or
 * a UNC `\\server\share` on Windows, a leading `/` on POSIX.
 *
 * `isAbsolute` is the wrong test. Node calls a driveless `\root` absolute on
 * Windows, and the renderer does not, so the two would render and read the
 * global guards under different roots for one value of the variable — the
 * carrier finding no script there, and allowing the command. It is cwd
 * dependence either way: `\root` resolves against whichever drive the session
 * sits on, which is the thing this rule refuses.
 */
export function rootAnchored(path: string, windows: boolean): boolean {
	if (!windows) return path.startsWith("/");
	return /^[A-Za-z]:[\\/]/.test(path) || /^[\\/]{2}[^\\/]+[\\/][^\\/]+/.test(path);
}

/**
 * Pi's global root: `~/.pi/agent`, or `PI_CODING_AGENT_DIR` when it names a
 * root-anchored path.
 *
 * The global scope is trusted without asking, because it holds the person's own
 * files rather than a checkout's. A blank or relative override breaks that: the
 * root becomes whichever directory the session happens to sit in, so an
 * untrusted clone's own `kendex/hooks/<name>.sh` would be spawned through the
 * branch that never consults Pi's trust answer. Such a value takes the default.
 */
export function piUserDir(): string {
	const override = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "");
	return resolve(rootAnchored(override, process.platform === "win32") ? override : expandHome("~/.pi/agent"));
}

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
export const PROJECT_MARKER_DIRS = [".claude", ".codex", ".opencode", ".cursor", ".pi", ".agents", ".gemini"] as const;
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
 * before it renders anything: a `.kendex-lock.json` wins wherever it stands,
 * home included, otherwise the nearest ancestor carrying a marker directory,
 * and home itself is not a project however else it is marked. Home carries
 * `.pi/` for nearly everyone, and Pi's own global root lives inside it.
 *
 * Walking rather than taking `cwd` is what makes a session started in a
 * subdirectory read the same settings and run the same guards as one at the
 * repository root — which is how Pi answers trust too: a saved decision applies
 * to the folder or any parent, held in `~/.pi/agent/trust.json`.
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

function projectSettingsPath(cwd: string): string | undefined {
	const root = projectRoot(cwd);
	return root === undefined ? undefined : join(root, ".pi", "settings.json");
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
 * gates reading the project's settings and running the project's own scripts,
 * and both of those are safe to withhold and unsafe to grant by accident.
 */
export function projectTrusted(ctx: { isProjectTrusted?: () => boolean }): boolean {
	try {
		return ctx.isProjectTrusted?.() === true;
	} catch {
		return false;
	}
}

export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }): void {
	if (!ctx.cwd) return;
	const settings = projectSettingsPath(ctx.cwd);
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
 * settings file resolved from `cwd`. Project keys win.
 */
export function readConfig(cwd: string): kendexConfig {
	const merged: kendexConfig = {};
	const project = projectSettingsPath(cwd);
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

export function getBool(cfg: kendexConfig, key: HookKey | "enabled"): boolean {
	const v = cfg[key];
	return typeof v === "boolean" ? v : (DEFAULTS[key] as boolean);
}

export function getNumber(cfg: kendexConfig, key: "clippyTimeoutMs" | "driftCheckTimeoutMs" | "hookTimeoutMs"): number {
	const v = cfg[key];
	if (typeof v === "number" && Number.isFinite(v) && v > 0) return v;
	if (typeof v === "string") {
		const parsed = Number(v);
		if (Number.isFinite(parsed) && parsed > 0) return parsed;
	}
	return DEFAULTS[key];
}
