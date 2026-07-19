// User-facing extension config. Legacy config is loaded from
// ~/.pi/agent/claude-bridge.json and .pi/claude-bridge.json. vstack extension
// manager config is loaded from settings.json and overrides legacy files.

import type { SettingSource } from "@anthropic-ai/claude-agent-sdk";
import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { dirname, join, resolve } from "path";

export const PACKAGE_ID = "@vanillagreen/pi-claude-bridge";

export type BridgeEffortLevel = "low" | "medium" | "high" | "xhigh" | "max";

const VALID_EFFORT_LEVELS = new Set<BridgeEffortLevel>(["low", "medium", "high", "xhigh", "max"]);

/**
 * Per-session control over claude.ai connector WRITE tools when connectors are
 * enabled. `deny` (default) hides Gmail/Calendar/Drive mutating tools so
 * connector chat sessions are read-only; `allow` exposes them (used only by the
 * one-shot approved-write executor). Reads are always available.
 */
export type ConnectorWriteMode = "deny" | "allow";

export interface Config {
	enabled?: boolean;
	/** Low-level Claude Agent SDK plumbing. Most users won't need these. */
	provider?: {
		appendSystemPrompt?: boolean;
		allowExtraUsage?: boolean;
		/** Enable Claude Code fast mode for bridge requests. */
		fastMode?: boolean;
		/** Force this Claude Code effort level for every bridge request. */
		forceEffort?: BridgeEffortLevel;
		/** Per-model Claude Code effort overrides keyed by model id (e.g. claude-opus-4-8). */
		modelEffortOverrides?: Record<string, BridgeEffortLevel>;
		settingSources?: SettingSource[];
		strictMcpConfig?: boolean;
		pathToClaudeCodeExecutable?: string;
		/**
		 * Expose the authenticated Claude account's claude.ai cloud MCP
		 * connectors (Gmail / Google Calendar / Google Drive, etc.) to the model.
		 * Off by default so Pi owns tool execution and tokens stay lean. Also
		 * settable via the CLAUDE_BRIDGE_ENABLE_CONNECTORS env var (env OR config
		 * enables it). See docs/plans/claude-bridge-google-connectors.md.
		 */
		enableConnectors?: boolean;
		/**
		 * When connectors are enabled, whether their WRITE tools
		 * (create/update/delete/label/etc.) are exposed. Defaults to `deny`
		 * (read-only), enforced two ways: known write tools are removed from the
		 * model's context (disallowedTools by exact id), and a PreToolUse hook
		 * blocks any connector write tool by name prefix at call time (covers
		 * future write tools). `allow` disables both — intended ONLY for a
		 * one-shot approved-write executor process. Also settable via
		 * CLAUDE_BRIDGE_CONNECTOR_WRITE=deny|allow (env wins over config). Any
		 * value but exact `allow` is treated as `deny`. Ignored when connectors
		 * are disabled.
		 */
		connectorWriteMode?: ConnectorWriteMode;
	};
	/** Extra Pi context forwarded to Claude Code on top of AGENTS.md + skills. */
	promptContext?: {
		includeAppendSystemPromptMd?: boolean;
		includeProjectAgentsHook?: boolean;
		includeTaskPanelHook?: boolean;
		includeCavemanHook?: boolean;
	};
}

type SettingsRecord = Record<string, unknown>;

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

/**
 * The Pi agent config dir: `PI_CODING_AGENT_DIR` when set, else `~/.pi/agent`.
 * Every bridge default that used to hardcode `~/.pi/agent` routes through this
 * so a host app that owns the agent dir owns those paths too.
 */
export function piUserDir(): string {
	return resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
}

/**
 * Isolated mode (`CLAUDE_BRIDGE_ISOLATED=1`): a host app embedding the bridge
 * declares that nothing outside its explicitly configured dirs may be read.
 * Disables every cwd/home discovery fallback — the cwd AGENTS.md walk, project
 * `.pi/` settings + claude-bridge.json, project APPEND_SYSTEM.md, and the
 * `$PATH` claude executable search. Reads stay confined to `piUserDir()` (i.e.
 * `PI_CODING_AGENT_DIR`) and the explicitly configured executable path.
 * Default (unset) behavior for normal pi CLI users is unchanged.
 */
export function isolatedFromEnv(): boolean {
	const v = (process.env.CLAUDE_BRIDGE_ISOLATED ?? "").trim().toLowerCase();
	return v === "1" || v === "true" || v === "yes" || v === "on";
}

function asRecord(value: unknown): SettingsRecord | undefined {
	return value && typeof value === "object" && !Array.isArray(value) ? value as SettingsRecord : undefined;
}

function mergeDeep<T extends SettingsRecord>(target: T, source: SettingsRecord): T {
	for (const [key, value] of Object.entries(source)) {
		const current = asRecord(target[key]);
		const incoming = asRecord(value);
		if (current && incoming) target[key as keyof T] = mergeDeep({ ...current }, incoming) as T[keyof T];
		else target[key as keyof T] = value as T[keyof T];
	}
	return target;
}

function projectSettingsPath(cwd: string): string {
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
	// Isolated mode never reads project config, so recording trust would only
	// run the cwd-ancestor `.pi/settings.json` walk (a filesystem probe outside
	// the host-owned dirs) for a result nothing consumes. Skip it entirely.
	if (isolatedFromEnv()) return;
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


function settingsPaths(cwd: string): string[] {
	const user = join(piUserDir(), "settings.json");
	if (isolatedFromEnv()) return [user];
	const project = projectSettingsPath(cwd);
	return projectSettingsTrusted(project) ? [user, project] : [user];
}

export function tryParseJson(path: string): Partial<Config> {
	if (!existsSync(path)) return {};
	try {
		return JSON.parse(readFileSync(path, "utf-8"));
	} catch {
		// Malformed optional config should not write raw terminal diagnostics;
		// stdout/stderr output can corrupt active Pi TUI widgets.
		return {};
	}
}

function readManagerConfig(cwd: string): SettingsRecord {
	const merged: SettingsRecord = {};
	for (const path of settingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			const configRoot = asRecord(asRecord(asRecord(parsed?.vstack)?.extensionManager)?.config);
			const config = asRecord(configRoot?.[PACKAGE_ID]);
			if (config) mergeDeep(merged, config);
		} catch {
			// Ignore malformed optional manager config; Pi will surface settings issues elsewhere.
		}
	}
	return merged;
}

function boolFrom(raw: SettingsRecord, key: string): boolean | undefined {
	return typeof raw[key] === "boolean" ? raw[key] as boolean : undefined;
}

function stringFrom(raw: SettingsRecord, key: string): string | undefined {
	const value = raw[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function hasOwn(raw: SettingsRecord, key: string): boolean {
	return Object.prototype.hasOwnProperty.call(raw, key);
}

export function normalizeConnectorWriteMode(value: unknown): ConnectorWriteMode | undefined {
	if (typeof value !== "string") return undefined;
	const normalized = value.trim().toLowerCase();
	if (normalized === "deny" || normalized === "allow") return normalized;
	return undefined;
}

export function normalizeEffortLevel(value: unknown): BridgeEffortLevel | undefined {
	if (typeof value !== "string") return undefined;
	const normalized = value.trim().toLowerCase();
	if (normalized === "" || normalized === "none" || normalized === "auto" || normalized === "default") return undefined;
	return VALID_EFFORT_LEVELS.has(normalized as BridgeEffortLevel) ? normalized as BridgeEffortLevel : undefined;
}

export function normalizeModelEffortOverrides(value: unknown): Record<string, BridgeEffortLevel> | undefined {
	let source: unknown = value;
	if (typeof source === "string") {
		const trimmed = source.trim();
		if (!trimmed || trimmed === "{}") return undefined;
		try {
			source = JSON.parse(trimmed);
		} catch {
			return undefined;
		}
	}
	const record = asRecord(source);
	if (!record) return undefined;

	const out: Record<string, BridgeEffortLevel> = {};
	for (const [modelId, rawEffort] of Object.entries(record)) {
		const key = modelId.trim();
		const effort = normalizeEffortLevel(rawEffort);
		if (key && effort) out[key] = effort;
	}
	return Object.keys(out).length > 0 ? out : undefined;
}

function normalizeProviderConfig(provider: Config["provider"] | undefined): Config["provider"] {
	if (!provider) return {};
	const raw = provider as SettingsRecord;
	const out: Config["provider"] = { ...provider };
	const forceEffort = normalizeEffortLevel(raw.forceEffort);
	if (forceEffort) out.forceEffort = forceEffort;
	else delete out.forceEffort;
	const modelEffortOverrides = normalizeModelEffortOverrides(raw.modelEffortOverrides);
	if (modelEffortOverrides) out.modelEffortOverrides = modelEffortOverrides;
	else delete out.modelEffortOverrides;
	// Fail closed: legacy config files are merged raw, so an unvalidated
	// connectorWriteMode (e.g. "Deny", "read-only", true) must not slip through as
	// a truthy non-"allow" value. Drop anything that isn't exactly deny/allow so
	// the resolver falls back to the default deny.
	const connectorWriteMode = normalizeConnectorWriteMode(raw.connectorWriteMode);
	if (connectorWriteMode) out.connectorWriteMode = connectorWriteMode;
	else delete out.connectorWriteMode;
	return out;
}

function managerToConfig(raw: SettingsRecord): Partial<Config> {
	const provider: Config["provider"] = {};
	const promptContext: Config["promptContext"] = {};

	const appendSystemPrompt = boolFrom(raw, "appendSystemPrompt");
	if (appendSystemPrompt !== undefined) provider.appendSystemPrompt = appendSystemPrompt;
	const allowExtraUsage = boolFrom(raw, "allowExtraUsage");
	if (allowExtraUsage !== undefined) provider.allowExtraUsage = allowExtraUsage;
	const fastMode = boolFrom(raw, "fastMode");
	if (fastMode !== undefined) provider.fastMode = fastMode;
	if (hasOwn(raw, "forceEffort")) {
		provider.forceEffort = normalizeEffortLevel(raw.forceEffort);
	}
	if (hasOwn(raw, "modelEffortOverrides")) {
		provider.modelEffortOverrides = normalizeModelEffortOverrides(raw.modelEffortOverrides);
	}
	const strictMcpConfig = boolFrom(raw, "strictMcpConfig");
	if (strictMcpConfig !== undefined) provider.strictMcpConfig = strictMcpConfig;
	const enableConnectors = boolFrom(raw, "enableConnectors");
	if (enableConnectors !== undefined) provider.enableConnectors = enableConnectors;
	const connectorWriteMode = normalizeConnectorWriteMode(raw.connectorWriteMode);
	if (connectorWriteMode) provider.connectorWriteMode = connectorWriteMode;
	const claudePath = stringFrom(raw, "pathToClaudeCodeExecutable");
	if (claudePath) provider.pathToClaudeCodeExecutable = claudePath;

	const includeAppendSystemPromptMd = boolFrom(raw, "includeAppendSystemPromptMd");
	if (includeAppendSystemPromptMd !== undefined) promptContext.includeAppendSystemPromptMd = includeAppendSystemPromptMd;
	const includeProjectAgentsHook = boolFrom(raw, "includeProjectAgentsHook");
	if (includeProjectAgentsHook !== undefined) promptContext.includeProjectAgentsHook = includeProjectAgentsHook;
	const includeTaskPanelHook = boolFrom(raw, "includeTaskPanelHook");
	if (includeTaskPanelHook !== undefined) promptContext.includeTaskPanelHook = includeTaskPanelHook;
	const includeCavemanHook = boolFrom(raw, "includeCavemanHook");
	if (includeCavemanHook !== undefined) promptContext.includeCavemanHook = includeCavemanHook;

	return {
		...(boolFrom(raw, "enabled") !== undefined ? { enabled: boolFrom(raw, "enabled") } : {}),
		...(Object.keys(provider).length ? { provider } : {}),
		...(Object.keys(promptContext).length ? { promptContext } : {}),
	};
}

export function loadConfig(cwd: string): Config {
	const global = tryParseJson(join(piUserDir(), "claude-bridge.json"));
	const isolated = isolatedFromEnv();
	const projectSettings = isolated ? undefined : projectSettingsPath(cwd);
	const trustedProject = projectSettings !== undefined && projectSettingsTrusted(projectSettings);
	const project = trustedProject ? tryParseJson(join(dirname(projectSettings), "claude-bridge.json")) : {};
	const manager = managerToConfig(readManagerConfig(cwd));
	const provider = normalizeProviderConfig({ ...global.provider, ...project.provider, ...manager.provider });
	return {
		enabled: manager.enabled ?? project.enabled ?? global.enabled ?? true,
		provider,
		promptContext: { ...global.promptContext, ...project.promptContext, ...manager.promptContext },
	};
}
