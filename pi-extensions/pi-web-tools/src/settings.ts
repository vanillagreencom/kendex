import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, isAbsolute, join, resolve } from "node:path";

import { expandHome, packageConfigIn, piSettingsPaths, projectSettingsTrustedForCwd, readSettingsFiles, settingsMemo, type SettingsRecord } from "./package-config.js";

export const PACKAGE_ID = "@vanillagreen/pi-web-tools";
export const WEB_PROVIDERS = ["auto", "exa", "perplexity", "gemini", "exa-mcp", "duckduckgo", "openai-native"] as const;
const DEFAULT_OP_READ_TIMEOUT_MS = 1500;
const OP_READ_TIMEOUT_ENV = "PI_WEB_TOOLS_OP_READ_TIMEOUT_MS";
export type WebProvider = (typeof WEB_PROVIDERS)[number];
export type ResolvedWebProvider = Exclude<WebProvider, "auto">;

export interface WebToolsSettings {
	enabled: boolean;
	glyphStyle: "unicode" | "ascii";
	autoEnable: boolean;
	defaultProvider: WebProvider;
	enabledProviders: ResolvedWebProvider[];
	nativeOpenAiWebSearch: boolean;
	openAiExternalWebAccess: boolean;
	exaDeepResearchEnabled: boolean;
	exaAdvancedEnabled: boolean;
	compatibilityTools: boolean;
	exaResearchModes: Record<string, Record<string, unknown>>;
	browserCookieAccess: boolean;
	githubClone: { enabled: boolean; maxRepoSizeMB: number; cloneTimeoutSeconds: number; cacheMaxAgeHours: number };
	htmlExtraction: { jinaFallback: boolean };
	pdfOcr: { enabled: boolean; maxPages: number; dpi: number };
	browserCookies: { preferredBrowser: "auto" | "firefox" | "zen" | "chrome" | "chromium"; profile?: string };
	video: { enabled: boolean };
	apiKeys: Partial<Record<Exclude<ResolvedWebProvider, "exa-mcp" | "duckduckgo"> | "openai" | "jina", string>>;
	privateConfigFile?: string;
	warnings: string[];
}

export const DEFAULT_SETTINGS: Omit<WebToolsSettings, "apiKeys" | "warnings" | "privateConfigFile"> = {
	enabled: true,
	glyphStyle: "unicode",
	autoEnable: true,
	defaultProvider: "auto",
	enabledProviders: ["exa", "perplexity", "gemini", "exa-mcp", "duckduckgo", "openai-native"],
	nativeOpenAiWebSearch: true,
	openAiExternalWebAccess: true,
	exaDeepResearchEnabled: true,
	exaAdvancedEnabled: false,
	compatibilityTools: false,
	exaResearchModes: {},
	browserCookieAccess: false,
	githubClone: { enabled: true, maxRepoSizeMB: 350, cloneTimeoutSeconds: 60, cacheMaxAgeHours: 24 },
	htmlExtraction: { jinaFallback: true },
	pdfOcr: { enabled: true, maxPages: 5, dpi: 150 },
	browserCookies: { preferredBrowser: "auto" },
	video: { enabled: true },
};

function asRecord(value: unknown): SettingsRecord | undefined {
	return value && typeof value === "object" && !Array.isArray(value) ? (value as SettingsRecord) : undefined;
}

function mergeDeep(target: SettingsRecord, source: SettingsRecord): SettingsRecord {
	for (const [key, value] of Object.entries(source)) {
		const current = asRecord(target[key]);
		const incoming = asRecord(value);
		if (current && incoming) target[key] = mergeDeep({ ...current }, incoming);
		else target[key] = value;
	}
	return target;
}

/** This package's config, merged deeply: a nested object in a later file
 * overrides the earlier file's key by key, not whole. */
export function readRawkendexConfig(cwd?: string): SettingsRecord {
	const merged: SettingsRecord = {};
	for (const file of readSettingsFiles(piSettingsPaths(cwd))) {
		if (file.kind !== "parsed") continue;
		const config = packageConfigIn(file.settings, PACKAGE_ID);
		if (config) mergeDeep(merged, config);
	}
	return merged;
}

export function settingsDiagnostics(cwd?: string): string[] {
	return readSettingsFiles(piSettingsPaths(cwd)).flatMap((file) => (file.kind === "malformed" ? [`${file.path}: ${file.error}`] : []));
}

function boolSetting(raw: SettingsRecord, key: keyof typeof DEFAULT_SETTINGS): boolean {
	const fallback = DEFAULT_SETTINGS[key];
	const value = raw[key as string];
	return typeof value === "boolean" ? value : Boolean(fallback);
}

function numberSetting(raw: SettingsRecord, key: string, fallback: number, min = 0, max = Number.MAX_SAFE_INTEGER): number {
	const value = raw[key];
	const number = typeof value === "number" ? value : typeof value === "string" && value.trim() ? Number(value) : fallback;
	return Number.isFinite(number) ? Math.min(max, Math.max(min, number)) : fallback;
}

function stringSetting(raw: SettingsRecord, key: string, fallback: string): string {
	const value = raw[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

function providerSetting(raw: SettingsRecord): WebProvider {
	const value = raw.defaultProvider;
	return WEB_PROVIDERS.includes(value as WebProvider) ? value as WebProvider : DEFAULT_SETTINGS.defaultProvider;
}

function glyphStyleSetting(raw: SettingsRecord): WebToolsSettings["glyphStyle"] {
	const value = raw.glyphStyle;
	return value === "ascii" || value === "unicode" ? value : DEFAULT_SETTINGS.glyphStyle;
}

function enabledProvidersSetting(raw: SettingsRecord): ResolvedWebProvider[] {
	const value = raw.enabledProviders;
	const rawList = Array.isArray(value) ? value : typeof value === "string" ? value.split(",") : DEFAULT_SETTINGS.enabledProviders;
	const allowed = new Set<ResolvedWebProvider>();
	for (const item of rawList) {
		const provider = String(item).trim() as ResolvedWebProvider;
		if (provider === "exa" || provider === "perplexity" || provider === "gemini" || provider === "exa-mcp" || provider === "duckduckgo" || provider === "openai-native") allowed.add(provider);
	}
	return allowed.size > 0 ? [...allowed] : [...DEFAULT_SETTINGS.enabledProviders];
}

function nested(raw: SettingsRecord, key: string): SettingsRecord {
	return asRecord(raw[key]) ?? {};
}

function recordOfRecords(raw: SettingsRecord, key: string): Record<string, Record<string, unknown>> {
	let rawValue = raw[key];
	if (typeof rawValue === "string" && rawValue.trim()) {
		try { rawValue = JSON.parse(rawValue); }
		catch { return {}; }
	}
	const value = asRecord(rawValue);
	if (!value) return {};
	const output: Record<string, Record<string, unknown>> = {};
	for (const [name, record] of Object.entries(value)) {
		const nestedRecord = asRecord(record);
		if (nestedRecord) output[name] = nestedRecord;
	}
	return output;
}

function parseEnvFile(text: string): SettingsRecord {
	const parsed: SettingsRecord = {};
	for (const line of text.split(/\r?\n/)) {
		const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
		if (!match) continue;
		let value = match[2] ?? "";
		if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
		parsed[match[1]!] = value;
	}
	return parsed;
}

function projectEnvFiles(cwd: string): string[] {
	let current = resolve(cwd);
	while (true) {
		if (existsSync(join(current, ".git")) || existsSync(join(current, ".kendex-lock.json")) || existsSync(join(current, ".pi"))) return [join(current, ".env"), join(current, ".env.local")];
		const parent = dirname(current);
		if (parent === current) return [join(resolve(cwd), ".env"), join(resolve(cwd), ".env.local")];
		current = parent;
	}
}


function resolveConfigPath(raw: SettingsRecord): string | undefined {
	const candidate = typeof raw.webToolsConfigFile === "string" ? raw.webToolsConfigFile : typeof raw.configFile === "string" ? raw.configFile : process.env.PI_WEB_TOOLS_CONFIG_FILE;
	if (!candidate || !candidate.trim()) return undefined;
	const expanded = expandHome(candidate.trim());
	return isAbsolute(expanded) ? expanded : resolve(process.cwd(), expanded);
}

function secretFrom(raw: SettingsRecord, keys: string[]): string | undefined {
	for (const key of keys) {
		const value = raw[key];
		if (typeof value === "string" && value.trim()) return value.trim();
	}
	return undefined;
}

function opReadTimeoutMs(): number {
	const raw = process.env[OP_READ_TIMEOUT_ENV];
	const parsed = raw && raw.trim() ? Number(raw) : NaN;
	return Number.isFinite(parsed) && parsed > 0 ? Math.min(Math.max(Math.trunc(parsed), 100), 10000) : DEFAULT_OP_READ_TIMEOUT_MS;
}

/** The warnings one resolution collects, and whether any `op://` reference in
 * it failed to resolve. */
interface Resolution {
	warnings: string[];
	secretFailed: boolean;
}

function addSecretWarning(resolution: Resolution, name: string, reason: string): void {
	resolution.secretFailed = true;
	resolution.warnings.push(`${name} is a 1Password reference but could not be resolved ${reason}; treating it as unset.`);
}

function resolveSecretRef(value: string | undefined, name: string, resolution: Resolution): string | undefined {
	if (!value || !value.startsWith("op://")) return value;
	const timeout = opReadTimeoutMs();
	const result = spawnSync("op", ["read", value], {
		encoding: "utf8",
		stdio: ["ignore", "pipe", "ignore"],
		timeout,
		killSignal: "SIGTERM",
	});
	const errorCode = result.error && "code" in result.error ? String(result.error.code) : undefined;
	if (errorCode === "ETIMEDOUT") {
		addSecretWarning(resolution, name, `within ${timeout}ms`);
		return undefined;
	}
	if (result.error) {
		addSecretWarning(resolution, name, "because the op CLI is unavailable or failed to start");
		return undefined;
	}
	if (result.status !== 0 || result.signal) {
		addSecretWarning(resolution, name, "because op read exited unsuccessfully");
		return undefined;
	}
	const resolved = result.stdout.trim();
	if (!resolved) {
		addSecretWarning(resolution, name, "because op read returned an empty value");
		return undefined;
	}
	return resolved;
}

/** What a file read gave: its text, nothing where it does not exist, or the
 * error that stopped the read. */
type FileRead = { kind: "absent" } | { kind: "text"; text: string } | { kind: "failed"; error: string };

function readFile(path: string): FileRead {
	try {
		return { kind: "text", text: readFileSync(path, "utf8") };
	} catch (error) {
		const code = (error as { code?: unknown } | null)?.code;
		if (code === "ENOENT" || code === "ENOTDIR") return { kind: "absent" };
		return { kind: "failed", error: error instanceof Error ? error.message : String(error) };
	}
}

/** Every input `loadSettings` resolves from, read raw: the merged package
 * config, the settings-file diagnostics, the trusted project's `.env` files, the
 * private config file. With the trust answer, the process cwd and the
 * environment variables `loadSettings` keys on, two equal inputs resolve to the
 * same settings. */
interface SettingsInputs {
	raw: SettingsRecord;
	diagnostics: string[];
	envFiles: Array<{ path: string; read: FileRead }>;
	privateConfigFile: string | undefined;
	privateConfig: FileRead | undefined;
}

const INPUT_ENV_KEYS = ["EXA_API_KEY", "PERPLEXITY_API_KEY", "GEMINI_API_KEY", "OPENAI_API_KEY", "JINA_API_KEY", "PI_WEB_TOOLS_CONFIG_FILE", OP_READ_TIMEOUT_ENV] as const;

function readSettingsInputs(cwd: string): SettingsInputs {
	const raw = readRawkendexConfig(cwd);
	const privateConfigFile = resolveConfigPath(raw);
	return {
		raw,
		diagnostics: settingsDiagnostics(cwd),
		envFiles: projectSettingsTrustedForCwd(cwd) ? projectEnvFiles(cwd).map((path) => ({ path, read: readFile(path) })) : [],
		privateConfigFile,
		privateConfig: privateConfigFile === undefined ? undefined : readFile(privateConfigFile),
	};
}

/**
 * The resolved settings for `cwd`. Every provider request asks, and resolving
 * an `op://` key runs the 1Password CLI, so the resolved object is memoized:
 * served for the settings window, then kept for as long as every raw input
 * reads the same, and dropped with every other memoized setting on a settings
 * change or a new session. A resolution in which an `op://` reference failed
 * is served for its window only, so a locked or absent 1Password is asked
 * again once per window rather than never. The project's trust and the
 * `INPUT_ENV_KEYS` variables are read on every call and key the memo, so a
 * change to any of them applies at once. Frozen, since every caller shares it.
 */
export function loadSettings(cwd = process.cwd()): WebToolsSettings {
	const key = JSON.stringify(["web-tools-settings", cwd, projectSettingsTrustedForCwd(cwd), process.cwd(), INPUT_ENV_KEYS.map((name) => process.env[name] ?? null)]);
	let inputs: SettingsInputs | undefined;
	let secretFailed = false;
	return settingsMemo(
		key,
		() => {
			const resolution: Resolution = { warnings: [], secretFailed: false };
			const settings = resolveSettings(inputs ?? readSettingsInputs(cwd), resolution);
			secretFailed = resolution.secretFailed;
			return settings;
		},
		() => {
			inputs = readSettingsInputs(cwd);
			return JSON.stringify(inputs);
		},
		() => !secretFailed,
	);
}

function resolveSettings(inputs: SettingsInputs, resolution: Resolution): WebToolsSettings {
	const { raw, privateConfigFile } = inputs;
	const warnings = resolution.warnings;
	warnings.push(...inputs.diagnostics);
	const envFileConfig: SettingsRecord = {};
	for (const { path, read } of inputs.envFiles) {
		if (read.kind === "text") mergeDeep(envFileConfig, parseEnvFile(read.text));
		else if (read.kind === "failed") warnings.push(`${path}: ${read.error}`);
	}
	let privateConfig: SettingsRecord = {};
	if (privateConfigFile && inputs.privateConfig?.kind === "text") {
		try { privateConfig = asRecord(JSON.parse(inputs.privateConfig.text)) ?? {}; }
		catch (error) { warnings.push(`${privateConfigFile}: ${error instanceof Error ? error.message : String(error)}`); }
	} else if (privateConfigFile && inputs.privateConfig?.kind === "failed") {
		warnings.push(`${privateConfigFile}: ${inputs.privateConfig.error}`);
	}
	const githubClone = nested(raw, "githubClone");
	const htmlExtraction = nested(raw, "htmlExtraction");
	const pdfOcr = nested(raw, "pdfOcr");
	const browserCookies = nested(raw, "browserCookies");
	const video = nested(raw, "video");
	const sharedSecrets = ["exaApiKey", "perplexityApiKey", "geminiApiKey", "openaiApiKey"].filter((key) => typeof raw[key] === "string");
	if (sharedSecrets.length > 0) warnings.push(`API keys in shared Pi settings are supported for compatibility but env vars or PI_WEB_TOOLS_CONFIG_FILE are preferred: ${sharedSecrets.join(", ")}`);
	const secrets = { ...envFileConfig, ...raw, ...privateConfig };
	const exaKey = process.env.EXA_API_KEY || secretFrom(secrets, ["EXA_API_KEY", "exaApiKey"]);
	const perplexityKey = process.env.PERPLEXITY_API_KEY || secretFrom(secrets, ["PERPLEXITY_API_KEY", "perplexityApiKey"]);
	const geminiKey = process.env.GEMINI_API_KEY || secretFrom(secrets, ["GEMINI_API_KEY", "geminiApiKey"]);
	const openAiKey = process.env.OPENAI_API_KEY || secretFrom(secrets, ["OPENAI_API_KEY", "openaiApiKey"]);
	const jinaKey = process.env.JINA_API_KEY || secretFrom(secrets, ["JINA_API_KEY", "jinaApiKey"]);
	return Object.freeze({
		enabled: boolSetting(raw, "enabled"),
		glyphStyle: glyphStyleSetting(raw),
		autoEnable: boolSetting(raw, "autoEnable"),
		defaultProvider: providerSetting(raw),
		enabledProviders: enabledProvidersSetting(raw),
		nativeOpenAiWebSearch: boolSetting(raw, "nativeOpenAiWebSearch"),
		openAiExternalWebAccess: boolSetting(raw, "openAiExternalWebAccess"),
		exaDeepResearchEnabled: boolSetting(raw, "exaDeepResearchEnabled"),
		exaAdvancedEnabled: boolSetting(raw, "exaAdvancedEnabled"),
		compatibilityTools: boolSetting(raw, "compatibilityTools"),
		exaResearchModes: recordOfRecords(raw, "exaResearchModes"),
		browserCookieAccess: boolSetting(raw, "browserCookieAccess"),
		githubClone: {
			enabled: typeof githubClone.enabled === "boolean" ? githubClone.enabled : DEFAULT_SETTINGS.githubClone.enabled,
			maxRepoSizeMB: numberSetting(githubClone, "maxRepoSizeMB", DEFAULT_SETTINGS.githubClone.maxRepoSizeMB, 1),
			cloneTimeoutSeconds: numberSetting(githubClone, "cloneTimeoutSeconds", DEFAULT_SETTINGS.githubClone.cloneTimeoutSeconds, 5, 600),
			cacheMaxAgeHours: numberSetting(githubClone, "cacheMaxAgeHours", DEFAULT_SETTINGS.githubClone.cacheMaxAgeHours, 0, 8760),
		},
		htmlExtraction: {
			jinaFallback: typeof htmlExtraction.jinaFallback === "boolean" ? htmlExtraction.jinaFallback : DEFAULT_SETTINGS.htmlExtraction.jinaFallback,
		},
		pdfOcr: {
			enabled: typeof pdfOcr.enabled === "boolean" ? pdfOcr.enabled : DEFAULT_SETTINGS.pdfOcr.enabled,
			maxPages: numberSetting(pdfOcr, "maxPages", DEFAULT_SETTINGS.pdfOcr.maxPages, 1, 20),
			dpi: numberSetting(pdfOcr, "dpi", DEFAULT_SETTINGS.pdfOcr.dpi, 72, 300),
		},
		browserCookies: {
			preferredBrowser: (["auto", "firefox", "zen", "chrome", "chromium"] as const).includes((browserCookies.preferredBrowser as any)) ? (browserCookies.preferredBrowser as any) : DEFAULT_SETTINGS.browserCookies.preferredBrowser,
			profile: typeof browserCookies.profile === "string" && browserCookies.profile.trim() ? browserCookies.profile.trim() : undefined,
		},
		video: { enabled: typeof video.enabled === "boolean" ? video.enabled : DEFAULT_SETTINGS.video.enabled },
		apiKeys: {
			exa: resolveSecretRef(exaKey, "EXA_API_KEY", resolution),
			perplexity: resolveSecretRef(perplexityKey, "PERPLEXITY_API_KEY", resolution),
			gemini: resolveSecretRef(geminiKey, "GEMINI_API_KEY", resolution),
			openai: resolveSecretRef(openAiKey, "OPENAI_API_KEY", resolution),
			jina: resolveSecretRef(jinaKey, "JINA_API_KEY", resolution),
		},
		privateConfigFile,
		warnings,
	});
}
