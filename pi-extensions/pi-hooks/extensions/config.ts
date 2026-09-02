import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";

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

/** Pi roots the carrier may read or execute from. Project content requires Pi
 * trust. Global content requires the default root or an absolute override. */
export function piRoots(cwd: string, trusted: boolean): { global?: string; project?: string } {
	const project = trusted ? join(projectRoot(cwd), ".pi") : undefined;
	const configured = process.env.PI_CODING_AGENT_DIR?.trim();
	if (!configured) return { global: resolve(homedir(), ".pi", "agent"), project };
	const expanded = configured === "~"
		? homedir()
		: configured.startsWith("~/")
			? join(homedir(), configured.slice(2))
			: configured;
	return { global: isAbsolute(expanded) ? resolve(expanded) : undefined, project };
}

/**
 * Walk up from `cwd` to the nearest Pi project marker. A nested session must
 * find the same project settings and hooks as a session at the project root.
 */
export function projectRoot(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		if (existsSync(join(current, ".pi", "settings.json"))) return current;
		if (
			existsSync(join(current, ".pi")) ||
			existsSync(join(current, ".git")) ||
			existsSync(join(current, ".kendex-lock.json"))
		) {
			return current;
		}
		const parent = dirname(current);
		if (parent === current) return resolve(cwd);
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
	const projectSettings = projectSettingsPath(cwd);
	const roots = piRoots(cwd, projectSettingsTrusted(projectSettings));
	const paths = [
		...(roots.global ? [join(roots.global, "settings.json")] : []),
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
