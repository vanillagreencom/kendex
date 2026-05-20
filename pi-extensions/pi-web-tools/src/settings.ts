import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { execFileSync } from "node:child_process";
import { dirname, isAbsolute, join, resolve } from "node:path";

export const PACKAGE_ID = "@vanillagreen/pi-web-tools";
export const WEB_PROVIDERS = ["auto", "exa", "perplexity", "gemini", "exa-mcp", "duckduckgo", "openai-native"] as const;
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

function mergeDeep(target: SettingsRecord, source: SettingsRecord): SettingsRecord {
	for (const [key, value] of Object.entries(source)) {
		const current = asRecord(target[key]);
		const incoming = asRecord(value);
		if (current && incoming) target[key] = mergeDeep({ ...current }, incoming);
		else target[key] = value;
	}
	return target;
}

export function readRawVstackConfig(cwd?: string): SettingsRecord {
	const merged: SettingsRecord = {};
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			settingsParseWarnings.delete(path);
			const config = asRecord(asRecord(asRecord(parsed?.vstack)?.extensionManager)?.config)?.[PACKAGE_ID];
			if (config && typeof config === "object" && !Array.isArray(config)) mergeDeep(merged, config as SettingsRecord);
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

function readJsonFile(path: string): SettingsRecord {
	if (!existsSync(path)) return {};
	const parsed = JSON.parse(readFileSync(path, "utf8"));
	return asRecord(parsed) ?? {};
}

function parseEnvFile(path: string): SettingsRecord {
	if (!existsSync(path)) return {};
	const parsed: SettingsRecord = {};
	for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
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
		if (existsSync(join(current, ".git")) || existsSync(join(current, ".vstack-lock.json")) || existsSync(join(current, ".pi"))) return [join(current, ".env"), join(current, ".env.local")];
		const parent = dirname(current);
		if (parent === current) return [join(resolve(cwd), ".env"), join(resolve(cwd), ".env.local")];
		current = parent;
	}
}

function readProjectEnvConfig(cwd: string): SettingsRecord {
	return projectEnvFiles(cwd).reduce((merged, path) => mergeDeep(merged, parseEnvFile(path)), {} as SettingsRecord);
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

function resolveSecretRef(value: string | undefined, name: string, warnings: string[]): string | undefined {
	if (!value || !value.startsWith("op://")) return value;
	try {
		return execFileSync("op", ["read", value], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
	} catch {
		warnings.push(`${name} is a 1Password reference but could not be resolved. Install/sign in to the op CLI and run: op read '${value}'`);
		return value;
	}
}

export function loadSettings(cwd = process.cwd()): WebToolsSettings {
	const raw = readRawVstackConfig(cwd);
	const warnings = settingsDiagnostics(cwd);
	const envFileConfig = readProjectEnvConfig(cwd);
	const privateConfigFile = resolveConfigPath(raw);
	let privateConfig: SettingsRecord = {};
	if (privateConfigFile) {
		try { privateConfig = readJsonFile(privateConfigFile); }
		catch (error) { warnings.push(`${privateConfigFile}: ${error instanceof Error ? error.message : String(error)}`); }
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
	return {
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
			exa: resolveSecretRef(exaKey, "EXA_API_KEY", warnings),
			perplexity: resolveSecretRef(perplexityKey, "PERPLEXITY_API_KEY", warnings),
			gemini: resolveSecretRef(geminiKey, "GEMINI_API_KEY", warnings),
			openai: resolveSecretRef(openAiKey, "OPENAI_API_KEY", warnings),
			jina: resolveSecretRef(jinaKey, "JINA_API_KEY", warnings),
		},
		privateConfigFile,
		warnings,
	};
}
