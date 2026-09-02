import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { piGlobalRoot, piProjectRoot } from "./pi-root.js";
import { CONFIG_ID } from "./constants.js";

export type kendexConfig = Record<string, unknown>;

export function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

export function projectSettingsPath(cwd: string): string {
	return join(piProjectRoot(cwd) ?? resolve(cwd), ".pi", "settings.json");
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


export function piSettingsPaths(cwd = process.cwd()): string[] {
	const userDir = piGlobalRoot();
	const user = join(userDir, "settings.json");
	const project = projectSettingsPath(cwd);
	return projectSettingsTrusted(project) ? [user, project] : [user];
}

export function readkendexConfig(cwd?: string): kendexConfig {
	const merged: kendexConfig = {};
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			const config = parsed?.kendex?.extensionManager?.config?.[CONFIG_ID];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return merged;
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
