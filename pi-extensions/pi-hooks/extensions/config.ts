import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";

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
 * Pi's global root, resolved the way the Pi adapter resolves it
 * (`crates/core/src/harness/pi.rs::default_global_root`):
 * `PI_CODING_AGENT_DIR` when the variable is DEFINED, an empty value included,
 * else `~/.pi/agent`.
 *
 * The adapter reads the variable through `std::env::var(k).ok()`
 * (`crates/core/src/env.rs`), so an empty value reaches it as `Some("")` and
 * roots the global scope at the process cwd. This has to read it the same way.
 * Empty-means-unset is the nicer reading, but it made the two halves disagree:
 * kendex rendered the global guards under one root while this carrier searched
 * another, found no script there, and allowed the command. A hook that is not
 * found is allowed, so a disagreement about where the guards live is a silent
 * allow, and that is the defect here rather than what an empty value ought to
 * mean. An empty value is a strange root either way; it is now the same strange
 * root on both sides.
 *
 * `resolve("")` is the process cwd, which is as close as this can come: the
 * adapter's empty root is a relative path, resolved by whatever cwd the kendex
 * process had when it wrote. The two name one directory whenever the Pi session
 * and the kendex run share a cwd, which is the ordinary case, and was true of
 * no case at all before.
 */
export function piUserDir(): string {
	const override = process.env.PI_CODING_AGENT_DIR;
	if (override !== undefined) return resolve(override);
	const home = homedir();
	if (!home) return resolve(".pi", "agent");
	return resolve(home, ".pi", "agent");
}

/**
 * Pi's global root when the carrier may act on what is in it, and `undefined`
 * when it may not. Acting means reading this package's settings out of it or
 * spawning a script from it; both take the contents on trust.
 *
 * `piUserDir` follows the renderer wherever the variable points, the cwd
 * included, and for naming a path that is the right answer. It is the wrong
 * answer for a decision to read or run, because the global scope is trusted
 * unconditionally: it is where the person's own files live, never a checkout's.
 * An empty or relative `PI_CODING_AGENT_DIR` breaks that, because the directory
 * it names is then whichever one the session happens to sit in. Pi launched
 * inside an untrusted clone reached that clone's own `kendex/hooks/<name>.sh`
 * through the global branch, which never asks about trust, and spawning a hook
 * is executing it.
 *
 * Two path tests, and nothing else. The variable must name a directory of its
 * own: unset, or absolute. And where the workspace is untrusted the root must
 * fall outside it, since a person who points the variable into a clone they
 * have not trusted has still not trusted it. No uid is read and no parent is
 * walked: ownership beyond these two questions is a second security model, and
 * one of those in the carrier is enough.
 *
 * The second test is decided on canonical paths, and the root that comes back
 * is the canonical one. `resolve` normalizes `.` and `..` and stops there, so a
 * comparison against its output is a comparison of spelling, while the spawn
 * that follows is the filesystem dereferencing symlinks. An absolute root that
 * is a symlink into the workspace reads as outside it and lands inside it.
 * Returning what was actually compared closes the gap between the two as well:
 * the path this answers with is the path the caller opens.
 *
 * A path that cannot be canonicalized withholds the global scope, whatever the
 * reason — it does not exist yet, only part of it does, a component denies
 * access, a symlink loops. None of those is evidence of an attack and none is
 * evidence of safety, and this can only say the root is outside the workspace
 * when both sides resolve. The ordinary case costs nothing: a root that does
 * not resolve holds no script to spawn and no settings.json to read, so
 * withholding it and searching it come to the same answer. Resolving to the
 * nearest existing ancestor instead would be the parent walk this does not do,
 * and would judge a path other than the one the filesystem will follow.
 *
 * Withholding the global scope is the safe direction on both sides. For a hook
 * it reads as a hook kendex did not install here, which allows the command and
 * is the answer this carrier already gives for that. For settings it leaves
 * DEFAULTS, and every default in this package is on.
 */
export function actionableUserDir(workspace: string | undefined, trusted: boolean): string | undefined {
	const override = process.env.PI_CODING_AGENT_DIR;
	if (override !== undefined && !isAbsolute(override)) return undefined;
	const root = canonicalPath(piUserDir());
	if (root === undefined) return undefined;
	if (trusted || workspace === undefined) return root;
	const project = canonicalPath(projectRoot(workspace));
	if (project === undefined) return undefined;
	if (root === project || root.startsWith(project + sep)) return undefined;
	return root;
}

/** A path with every symlink and `..` resolved, or `undefined` where the
 * filesystem cannot answer. The caller decides what an unanswerable path
 * means; here it is always withholding. */
function canonicalPath(path: string): string | undefined {
	try {
		return realpathSync(path);
	} catch {
		return undefined;
	}
}

/** The directories kendex treats as a harness marker, and the lock file that
 * outranks them. Copied from `crates/core/src/discover.rs` MARKER_DIRS and
 * `crates/core/src/lock.rs` LOCK_FILE, and held there by
 * tests/renderer-parity.test.ts, which reads those files and fails when this
 * list stops matching. Two carrier-side copies of a renderer rule have drifted
 * on this branch already; a third hand-copied list with nothing holding it
 * would be the same defect waiting. */
export const PROJECT_MARKER_DIRS = [
	".claude",
	".codex",
	".opencode",
	".cursor",
	".pi",
	".agents",
	".gemini",
] as const;
export const PROJECT_LOCK_FILE = ".kendex-lock.json";

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

/**
 * Walk up from `cwd` to the directory holding the project, the way kendex
 * itself does it in `crates/core/src/discover.rs::project_root_from`: a
 * `.kendex-lock.json` wins wherever it stands, otherwise the nearest ancestor
 * carrying one of the harness marker directories, and home does not count as a
 * project however it is marked. Nothing found is `cwd`.
 *
 * Everything that reads or runs something of the project's resolves from here,
 * and it is also the boundary `actionableUserDir` measures the global root
 * against, so both directions of a mismatch cost something. A root this misses
 * is a project whose rendered hooks are never looked for, which is a guard that
 * does not run and says nothing; and it is a workspace an absolute global root
 * can be symlinked into while still reading as outside it. A root this invents
 * is the same in reverse.
 *
 * `project_root_from` is the operative rule and this mirrors it.
 * `HarnessAdapter::project_markers` looks like the rule and is not: it is
 * declared per harness and called from nowhere in `crates/`, so a carrier
 * following it would match a list nothing executes and would miss the five
 * marker directories other harnesses own — a project marked only `.claude/`
 * still gets `<project>/.pi/kendex/hooks/` rendered into it when pi is
 * installed, because the project was found before any harness was consulted.
 *
 * The walk runs on canonical paths, as the renderer's does. The home test is a
 * comparison, so both ends have to be spelled the same way, and the boundary
 * this returns is compared against a canonicalized global root.
 */
export function projectRoot(cwd: string): string {
	const start = canonicalPath(cwd) ?? resolve(cwd);
	const home = canonicalPath(homedir()) ?? resolve(homedir());
	let current = start;
	while (true) {
		if (isFile(join(current, PROJECT_LOCK_FILE))) return current;
		// Home carries a marker directory for nearly everyone, and calling it a
		// project would make every session outside a real one measure the global
		// root against the directory the global root lives in.
		if (current !== home && PROJECT_MARKER_DIRS.some((marker) => isDir(join(current, marker)))) {
			return current;
		}
		const parent = dirname(current);
		if (parent === current) return start;
		current = parent;
	}
}

function projectSettingsPath(cwd: string): string {
	return join(projectRoot(cwd), ".pi", "settings.json");
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
	const trusted = projectTrusted(ctx);
	const registry = projectTrustRegistry();
	if (!registry.projectSettings) registry.projectSettings = new Map();
	registry.projectSettings.set(projectSettingsPath(ctx.cwd), trusted);
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
	const trusted = projectSettingsTrusted(project);
	// The user scope is read only from a root the carrier may act on. Without
	// that test an empty or relative PI_CODING_AGENT_DIR put the user scope
	// inside the session's own cwd, so a checkout could ship a settings.json
	// switching every guard off — the same hole as spawning its script, reached
	// by reading instead of running.
	const global = actionableUserDir(cwd, trusted);
	const user = global === undefined ? undefined : join(global, "settings.json");
	const paths = [...(user === undefined ? [] : [user]), ...(trusted ? [project] : [])];
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

export function getNumber(cfg: kendexConfig, key: "clippyTimeoutMs" | "driftCheckTimeoutMs"): number {
	const v = cfg[key];
	if (typeof v === "number" && Number.isFinite(v) && v > 0) return v;
	if (typeof v === "string") {
		const parsed = Number(v);
		if (Number.isFinite(parsed) && parsed > 0) return parsed;
	}
	return DEFAULTS[key];
}
