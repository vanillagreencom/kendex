import { dirname, isAbsolute, resolve } from "node:path";
import { expandHome, piSettingsPaths, readPackageConfig, readSettingsFiles, type SettingsRecord } from "./package-config.js";

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

export function readRawkendexConfig(cwd?: string): SettingsRecord {
	return readPackageConfig(PACKAGE_ID, cwd);
}

export function settingsDiagnostics(cwd?: string): string[] {
	return readSettingsFiles(piSettingsPaths(cwd)).flatMap((file) => (file.kind === "malformed" ? [`${file.path}: ${file.error}`] : []));
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
	const raw = readRawkendexConfig(cwd);
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
