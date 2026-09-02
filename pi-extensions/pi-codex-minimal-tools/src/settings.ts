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

/** Root-anchored as `crates/core/src/harness/pi.rs::pi_root_is_absolute_for`
 * means it, which `isAbsolute` is not: it calls a driveless `\root` absolute
 * where the renderer does not, putting the two on different roots. Hoisted, so
 * a circular import cannot reach it inside a temporal dead zone. */
function rootAnchored(path: string, windows: boolean): boolean { return windows ? /^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+)/.test(path) : path.startsWith("/"); }

export function piUserDir(): string {
	const override = expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "");
	return resolve(rootAnchored(override, process.platform === "win32") ? override : expandHome("~/.pi/agent"));
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


export function piSettingsPaths(cwd = process.cwd()): string[] {
	const user = join(piUserDir(), "settings.json");
	const project = projectSettingsPath(cwd);
	return projectSettingsTrusted(project) ? [user, project] : [user];
}

function asRecord(value: unknown): SettingsRecord | undefined {
	return value && typeof value === "object" && !Array.isArray(value) ? (value as SettingsRecord) : undefined;
}

export function readPackageConfig(packageId: string, cwd?: string): SettingsRecord {
	const merged: SettingsRecord = {};
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			settingsParseWarnings.delete(path);
			const config = asRecord(asRecord(asRecord(parsed?.kendex)?.extensionManager)?.config)?.[packageId];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch (error) {
			settingsParseWarnings.set(path, error instanceof Error ? error.message : String(error));
		}
	}
	return merged;
}

export function readRawkendexConfig(cwd?: string): SettingsRecord {
	return readPackageConfig(PACKAGE_ID, cwd);
}

export function settingsDiagnostics(cwd?: string): string[] {
	readRawkendexConfig(cwd);
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
