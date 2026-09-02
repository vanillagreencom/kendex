import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { CONFIG_ID } from "./constants.js";

export type kendexConfig = Record<string, unknown>;

export function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

export function projectSettingsPath(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi", "settings.json");
		if (existsSync(candidate)) return candidate;
		if (existsSync(join(current, ".pi")) || existsSync(join(current, ".git")) || existsSync(join(current, ".kendex-lock.json"))) return candidate;
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
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

/** Root-anchored as `crates/core/src/harness/pi.rs::pi_root_is_absolute_for`
 * means it, which `isAbsolute` is not: it calls a driveless `\root` absolute
 * where the renderer does not, putting the two on different roots. Hoisted, so
 * a circular import cannot reach it inside a temporal dead zone. */
function rootAnchored(path: string, windows: boolean): boolean { return windows ? /^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+)/.test(path) : path.startsWith("/"); }

export function piSettingsPaths(cwd = process.cwd()): string[] {
	const override = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "");
	const userDir = resolve(rootAnchored(override, process.platform === "win32") ? override : expandHome("~/.pi/agent"));
	const user = join(userDir, "settings.json");
	const project = projectSettingsPath(cwd);
	return projectSettingsTrusted(project) ? [user, project] : [user];
}

export function readPackageConfig(packageId: string, cwd?: string): Record<string, unknown> {
	const merged: Record<string, unknown> = {};
	for (const settingsPath of piSettingsPaths(cwd)) {
		if (!existsSync(settingsPath)) continue;
		try {
			const parsed = JSON.parse(readFileSync(settingsPath, "utf8"));
			const config = parsed?.kendex?.extensionManager?.config?.[packageId];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return merged;
}

export function readkendexConfig(cwd?: string): kendexConfig {
	return readPackageConfig(CONFIG_ID, cwd) as kendexConfig;
}

export function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

export function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

export function settingStringAllowEmpty(key: string, fallback: string, cwd?: string): string {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" ? value.trim() : fallback;
}

export function newlineFallbackKey(cwd?: string): "ctrl+j" | "none" {
	const configured = settingString("newlineFallbackKey", "ctrl+j", cwd).toLowerCase();
	return configured === "none" ? "none" : "ctrl+j";
}

export function settingNumber(key: string, fallback: number, cwd?: string): number {
	const value = readkendexConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

export function boundedSettingNumber(key: string, fallback: number, min: number, max: number, cwd?: string): number {
	return Math.max(min, Math.min(max, Math.floor(settingNumber(key, fallback, cwd))));
}
