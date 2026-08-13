import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

/** Package id used as the config namespace key in `.pi/settings.json`. */
export const CONFIG_ID = "@vanillagreen/pi-hooks";

export type VstackConfig = Record<string, unknown>;

/**
 * Conservative defaults. All hooks enabled. The 30s clippy budget matches the
 * `timeout: 30` declared in `hooks/post-edit-lint.sh` so behavior stays
 * consistent across harnesses; per-call clippy must be considered "slow" but
 * not unbounded.
 */
export const DEFAULTS = {
	enabled: true,
	blockBareCd: true,
	blockRepoCopy: true,
	preCommitCheck: true,
	postEditLint: true,
	taskCompletedCheck: true,
	clippyTimeoutMs: 30000,
} as const;

export type HookKey = Exclude<keyof typeof DEFAULTS, "clippyTimeoutMs">;

function piUserDir(): string {
	const home = homedir();
	if (!home) return resolve(".pi", "agent");
	return resolve(home, ".pi", "agent");
}

/**
 * Walk up from `cwd` looking for an existing `.pi/settings.json`. Falls back to
 * a sibling `.pi/`, `.git/`, or `.vstack-lock.json` marker, then to the cwd
 * itself. Mirrors the pi-output-policy resolution to keep behavior identical
 * across the vstack pi extensions.
 */
function projectSettingsPath(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi", "settings.json");
		if (existsSync(candidate)) return candidate;
		if (
			existsSync(join(current, ".pi")) ||
			existsSync(join(current, ".git")) ||
			existsSync(join(current, ".vstack-lock.json"))
		) {
			return candidate;
		}
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
}

const PROJECT_TRUST_SYMBOL = Symbol.for("vstack.pi.project-trust");

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

export function recordProjectTrust(ctx: { cwd?: string; isProjectTrusted?: () => boolean }): void {
	if (!ctx.cwd) return;
	let trusted = true;
	try {
		trusted = ctx.isProjectTrusted?.() === true;
	} catch {
		trusted = false;
	}
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
export function readConfig(cwd: string): VstackConfig {
	const merged: VstackConfig = {};
	const user = join(piUserDir(), "settings.json");
	const project = projectSettingsPath(cwd);
	const paths = projectSettingsTrusted(project) ? [user, project] : [user];
	for (const path of paths) {
		const parsed = loadJson(path) as
			| { vstack?: { extensionManager?: { config?: Record<string, VstackConfig> } } }
			| undefined;
		const cfg = parsed?.vstack?.extensionManager?.config?.[CONFIG_ID];
		if (cfg && typeof cfg === "object" && !Array.isArray(cfg)) {
			Object.assign(merged, cfg);
		}
	}
	return merged;
}

export function getBool(cfg: VstackConfig, key: HookKey | "enabled"): boolean {
	const v = cfg[key];
	return typeof v === "boolean" ? v : (DEFAULTS[key] as boolean);
}

export function getNumber(cfg: VstackConfig, key: "clippyTimeoutMs"): number {
	const v = cfg[key];
	if (typeof v === "number" && Number.isFinite(v) && v > 0) return v;
	if (typeof v === "string") {
		const parsed = Number(v);
		if (Number.isFinite(parsed) && parsed > 0) return parsed;
	}
	return DEFAULTS[key];
}
