import { CONFIG_ID } from "./constants.js";
import { piSettingsPaths, readPackageConfig, readSettingsFiles } from "./package-config.js";

export type kendexConfig = Record<string, unknown>;

/** Pi core's `compaction.enabled` over the files QOL reads its own config
 * from, resolved as Pi's `SettingsManager.getCompactionEnabled` resolves it:
 * the last file that sets the key decides, a key no file sets is Pi's default,
 * true, and any falsy value turns compaction off. */
export function piCompactionEnabled(cwd?: string): boolean {
	let enabled: unknown;
	for (const file of readSettingsFiles(piSettingsPaths(cwd))) {
		if (file.kind !== "parsed") continue;
		const compaction = file.settings.compaction as { enabled?: unknown } | null | undefined;
		if (compaction && typeof compaction === "object" && !Array.isArray(compaction) && compaction.enabled !== undefined) enabled = compaction.enabled;
	}
	return Boolean(enabled ?? true);
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
