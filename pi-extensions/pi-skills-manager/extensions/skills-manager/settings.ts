import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { PACKAGE_ID } from "./constants.js";
import { detectExtensionInstallScope, projectSettingsPath, projectSettingsTrusted, readPackageConfig, userPiDir } from "./paths.js";
import type { ExtensionInstallScope, OverlaySize, SettingsFile } from "./types.js";

export function readJsonObject(path: string): SettingsFile {
	if (!existsSync(path)) return { path, json: {}, exists: false };
	const text = readFileSync(path, "utf8");
	if (!text.trim()) return { path, json: {}, exists: true };
	const parsed = JSON.parse(text);
	return { path, json: parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : {}, exists: true };
}

export function writeJsonFile(file: SettingsFile): void {
	mkdirSync(dirname(file.path), { recursive: true });
	writeFileSync(file.path, `${JSON.stringify(file.json, null, 2)}\n`, "utf8");
	file.exists = true;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
	return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
}

function getOrCreateRecord(parent: Record<string, unknown>, key: string): Record<string, unknown> {
	const current = asRecord(parent[key]);
	if (current) return current;
	const created: Record<string, unknown> = {};
	parent[key] = created;
	return created;
}

function piSettingsFiles(cwd = process.cwd()): SettingsFile[] {
	const user = readJsonObject(join(userPiDir(), "settings.json"));
	return projectSettingsTrusted(cwd) ? [user, readJsonObject(projectSettingsPath(cwd))] : [user];
}

function packageConfigFromFile(file: SettingsFile): Record<string, unknown> | undefined {
	return asRecord(asRecord(asRecord(file.json.kendex)?.extensionManager)?.config)?.[PACKAGE_ID] as Record<string, unknown> | undefined;
}

// One reader for this package, in paths.ts, the way the other packages do it.
// piSettingsFiles below stays for the write path, which needs the parsed file
// and must throw on malformed JSON rather than overwrite it.
function readkendexConfig(cwd = process.cwd()): Record<string, unknown> {
	return readPackageConfig(PACKAGE_ID, cwd);
}

export function settingBoolean(key: string, fallback: boolean, cwd = process.cwd()): boolean {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

export function settingString(key: string, fallback: string, cwd = process.cwd()): string {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

export function settingNumber(key: string, fallback: number, cwd = process.cwd()): number {
	const value = readkendexConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

export function settingOverlaySize(key: string, fallback: OverlaySize, cwd = process.cwd()): OverlaySize {
	const value = readkendexConfig(cwd)[key];
	if (typeof value === "number" && Number.isFinite(value)) return value;
	if (typeof value === "string" && value.trim()) {
		const trimmed = value.trim();
		if (/^\d+$/.test(trimmed)) return Number(trimmed);
		return trimmed;
	}
	return fallback;
}

function writeScopeForConfigKey(cwd: string, key: string): ExtensionInstallScope {
	const [user, project] = piSettingsFiles(cwd);
	if (project && packageConfigFromFile(project)?.[key] !== undefined) return "project";
	if (packageConfigFromFile(user)?.[key] !== undefined) return "global";
	const detected = detectExtensionInstallScope(cwd);
	return detected === "project" && !projectSettingsTrusted(cwd) ? "global" : detected;
}

export function updatePackageConfig(cwd: string, updates: Record<string, unknown>, scope?: ExtensionInstallScope): void {
	const firstKey = Object.keys(updates)[0] ?? "enabled";
	const targetScope = scope ?? writeScopeForConfigKey(cwd, firstKey);
	const path = targetScope === "global" ? join(userPiDir(), "settings.json") : projectSettingsPath(cwd);
	const file = readJsonObject(path);
	const kendex = getOrCreateRecord(file.json, "kendex");
	const extensionManager = getOrCreateRecord(kendex, "extensionManager");
	const config = getOrCreateRecord(extensionManager, "config");
	const packageConfig = getOrCreateRecord(config, PACKAGE_ID);
	Object.assign(packageConfig, updates);
	writeJsonFile(file);
}
