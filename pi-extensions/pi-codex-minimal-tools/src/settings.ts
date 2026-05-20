import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";

export const PACKAGE_ID = "@vanillagreen/pi-codex-minimal-tools";

export interface CodexMinimalToolsSettings {
	enabled: boolean;
	glyphStyle: "unicode" | "ascii";
	autoEnable: boolean;
	nativeProviderTools: boolean;
	imageGeneration: boolean;
	imageOutputDir: string;
	imageModel: "gpt-image-2" | "gpt-image-1.5" | "gpt-image-1";
	directImageApiFallback: boolean;
	viewImage: boolean;
	viewImageWorkspaceOnly: boolean;
	applyPatchEnabled: boolean;
	strictPatchMode: boolean;
	allowAbsolutePatchPaths: boolean;
	deferApplyPatchRendering: boolean;
}

export const DEFAULT_SETTINGS: CodexMinimalToolsSettings = {
	enabled: true,
	glyphStyle: "unicode",
	autoEnable: true,
	nativeProviderTools: true,
	imageGeneration: true,
	imageOutputDir: ".pi/openai-codex-images",
	imageModel: "gpt-image-2",
	directImageApiFallback: false,
	viewImage: false,
	viewImageWorkspaceOnly: false,
	applyPatchEnabled: true,
	strictPatchMode: false,
	allowAbsolutePatchPaths: false,
	deferApplyPatchRendering: true,
};

type SettingsRecord = Record<string, unknown>;
const settingsParseWarnings = new Map<string, string>();

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

export function piUserDir(): string {
	return resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
}

export function projectSettingsPath(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi", "settings.json");
		if (existsSync(candidate)) return candidate;
		if (existsSync(join(current, ".pi")) || existsSync(join(current, ".git")) || existsSync(join(current, ".vstack-lock.json"))) return candidate;
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
}

export function piSettingsPaths(cwd = process.cwd()): string[] {
	return [join(piUserDir(), "settings.json"), projectSettingsPath(cwd)];
}

function asRecord(value: unknown): SettingsRecord | undefined {
	return value && typeof value === "object" && !Array.isArray(value) ? (value as SettingsRecord) : undefined;
}

export function readRawVstackConfig(cwd?: string): SettingsRecord {
	const merged: SettingsRecord = {};
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			settingsParseWarnings.delete(path);
			const config = asRecord(asRecord(asRecord(parsed?.vstack)?.extensionManager)?.config)?.[PACKAGE_ID];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch (error) {
			settingsParseWarnings.set(path, error instanceof Error ? error.message : String(error));
		}
	}
	return merged;
}

export function settingsDiagnostics(cwd?: string): string[] {
	readRawVstackConfig(cwd);
	return piSettingsPaths(cwd).flatMap((path) => {
		const warning = settingsParseWarnings.get(path);
		return warning ? [`${path}: ${warning}`] : [];
	});
}

function boolSetting(raw: SettingsRecord, key: keyof CodexMinimalToolsSettings): boolean {
	const fallback = DEFAULT_SETTINGS[key];
	const value = raw[key as string];
	return typeof value === "boolean" ? value : Boolean(fallback);
}

function stringSetting(raw: SettingsRecord, key: keyof CodexMinimalToolsSettings): string {
	const fallback = String(DEFAULT_SETTINGS[key]);
	const value = raw[key as string];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

function imageModelSetting(raw: SettingsRecord): CodexMinimalToolsSettings["imageModel"] {
	const value = raw.imageModel;
	return value === "gpt-image-2" || value === "gpt-image-1.5" || value === "gpt-image-1" ? value : DEFAULT_SETTINGS.imageModel;
}

function glyphStyleSetting(raw: SettingsRecord): CodexMinimalToolsSettings["glyphStyle"] {
	const value = raw.glyphStyle;
	return value === "ascii" || value === "unicode" ? value : DEFAULT_SETTINGS.glyphStyle;
}

export function loadSettings(cwd?: string): CodexMinimalToolsSettings {
	const raw = readRawVstackConfig(cwd);
	return {
		enabled: boolSetting(raw, "enabled"),
		glyphStyle: glyphStyleSetting(raw),
		autoEnable: boolSetting(raw, "autoEnable"),
		nativeProviderTools: boolSetting(raw, "nativeProviderTools"),
		imageGeneration: boolSetting(raw, "imageGeneration"),
		imageOutputDir: stringSetting(raw, "imageOutputDir"),
		imageModel: imageModelSetting(raw),
		directImageApiFallback: boolSetting(raw, "directImageApiFallback"),
		viewImage: boolSetting(raw, "viewImage"),
		viewImageWorkspaceOnly: boolSetting(raw, "viewImageWorkspaceOnly"),
		applyPatchEnabled: boolSetting(raw, "applyPatchEnabled"),
		strictPatchMode: boolSetting(raw, "strictPatchMode"),
		allowAbsolutePatchPaths: boolSetting(raw, "allowAbsolutePatchPaths"),
		deferApplyPatchRendering: boolSetting(raw, "deferApplyPatchRendering"),
	};
}

export function resolveSettingsRelativePath(value: string, settingsPath: string): string {
	const expanded = expandHome(value.trim());
	return isAbsolute(expanded) ? expanded : resolve(dirname(settingsPath), expanded);
}
