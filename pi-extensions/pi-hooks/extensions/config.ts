import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

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

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

/**
 * Pi's global root: `~/.pi/agent`, or `PI_CODING_AGENT_DIR` when it names an
 * absolute path.
 *
 * The global scope is trusted without asking, because it holds the person's own
 * files rather than a checkout's. A blank or relative override breaks that: the
 * root becomes whichever directory the session happens to sit in, so an
 * untrusted clone's own `kendex/hooks/<name>.sh` would be spawned through the
 * branch that never consults Pi's trust answer. Such a value takes the default.
 */
function piUserDir(): string {
	const override = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "");
	return resolve(isAbsolute(override) ? override : expandHome("~/.pi/agent"));
}

/** Pi roots the carrier may read or execute from. Project content requires Pi
 * trust; the global root is always the person's own. */
export function piRoots(cwd: string, trusted: boolean): { global: string; project?: string } {
	return {
		global: piUserDir(),
		project: trusted ? join(resolve(cwd), ".pi") : undefined,
	};
}

function projectSettingsPath(cwd: string): string {
	return join(resolve(cwd), ".pi", "settings.json");
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
	const projectSettings = projectSettingsPath(cwd);
	const roots = piRoots(cwd, projectSettingsTrusted(projectSettings));
	const paths = [
		join(roots.global, "settings.json"),
		...(roots.project ? [join(roots.project, "settings.json")] : []),
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

export function getNumber(cfg: kendexConfig, key: "clippyTimeoutMs" | "driftCheckTimeoutMs"): number {
	const v = cfg[key];
	if (typeof v === "number" && Number.isFinite(v) && v > 0) return v;
	if (typeof v === "string") {
		const parsed = Number(v);
		if (Number.isFinite(parsed) && parsed > 0) return parsed;
	}
	return DEFAULTS[key];
}
