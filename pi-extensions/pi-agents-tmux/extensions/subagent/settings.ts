import * as path from "node:path";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { AgentConfig } from "./agents.js";
import { safeFileName } from "./names.js";
import {
	CONFIG_ID,
	DEFAULT_RESULT_MAX_BYTES,
	DEFAULT_RESULT_MAX_LINES,
	PACKAGE_ID,
	type ResultLimits,
	type kendexConfig,
} from "./types.js";
import { glyphStyle } from "./glyphs.js";
import { piUserDir, readPackageConfig } from "./package-config.js";

export const DEFAULT_BG_TASK_TIMEOUT_MS = 30 * 60 * 1000;

export function sessionIdForContext(ctx: ExtensionContext): string {
	const id = ctx.sessionManager.getSessionId();
	if (id && id.trim()) return id;
	const file = ctx.sessionManager.getSessionFile();
	if (file) return path.basename(file, path.extname(file));
	return `ephemeral-${process.pid}`;
}

export function runtimeSessionId(ctx: ExtensionContext): string {
	const parentSessionId = process.env.PI_SUBAGENT_PARENT_SESSION_ID?.trim();
	// Only child pane processes should inherit the parent runtime scope. If a normal
	// parent Pi process has this environment variable accidentally set, using it
	// would make pane registries and bridge targeting bleed across sessions.
	if (process.env.PI_SUBAGENT_CHILD_AGENT && parentSessionId) return parentSessionId;
	return sessionIdForContext(ctx);
}

export function sessionRuntimeDir(sessionId: string): string {
	return path.join(piUserDir(), "kendex", "sessions", safeFileName(sessionId), PACKAGE_ID);
}


export function runtimeDirForContext(ctx: ExtensionContext): string {
	return sessionRuntimeDir(runtimeSessionId(ctx));
}

export function readkendexConfig(cwd?: string): kendexConfig {
	return readPackageConfig(CONFIG_ID, cwd) as kendexConfig;
}

export function settingNumber(key: string, fallback: number, cwd?: string): number {
	const value = readkendexConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

export function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

export function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readkendexConfig(cwd)[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

export function subagentModelSource(cwd?: string): "frontmatter" | "parent" {
	return settingString("subagentModelSource", "frontmatter", cwd) === "parent" ? "parent" : "frontmatter";
}

const REASONING_EFFORT_LEVELS = new Set(["off", "minimal", "low", "medium", "high", "xhigh", "max"]);

export function normalizeReasoningEffort(value: unknown): string | undefined {
	if (typeof value !== "string") return undefined;
	const normalized = value.trim().toLowerCase();
	return REASONING_EFFORT_LEVELS.has(normalized) ? normalized : undefined;
}

export function effortFromModelId(model: string | undefined): string | undefined {
	const trimmed = model?.trim();
	if (!trimmed) return undefined;
	const colon = trimmed.lastIndexOf(":");
	if (colon < 0) return undefined;
	return normalizeReasoningEffort(trimmed.slice(colon + 1));
}

export function modelWithoutEffortSuffix(model: string | undefined): string | undefined {
	const trimmed = model?.trim();
	if (!trimmed) return undefined;
	const effort = effortFromModelId(trimmed);
	if (!effort) return trimmed;
	return trimmed.slice(0, trimmed.lastIndexOf(":")) || trimmed;
}

export function selectedEffortForAgent(agent: AgentConfig, selectedModel: string | undefined, selectedThinking: string | undefined): string | undefined {
	return normalizeReasoningEffort(selectedThinking) ?? effortFromModelId(selectedModel) ?? normalizeReasoningEffort(agent.effort);
}

export function selectedModelForAgent(agent: AgentConfig, parentModel: string | undefined, cwd?: string): string | undefined {
	return subagentModelSource(cwd) === "parent" ? (parentModel ?? agent.model) : (agent.model ?? parentModel);
}

export function subagentThinkingSource(cwd?: string): "frontmatter" | "parent" {
	return settingString("subagentThinkingSource", "frontmatter", cwd) === "parent" ? "parent" : "frontmatter";
}

// When source is "frontmatter" the parent's level is not consulted: the
// agent's model `:effort` suffix or its `effort` key governs the child's
// thinking level (`selectedEffortForAgent`).
export function selectedThinkingLevelForAgent(parentThinkingLevel: string | undefined, cwd?: string): string | undefined {
	return subagentThinkingSource(cwd) === "parent" ? parentThinkingLevel : undefined;
}

export function normalizedPiToolName(tool: string): string {
	return tool.trim().toLowerCase().replace(/-/g, "_");
}

export function selectedToolsForAgent(agent: AgentConfig, cwd: string | undefined, extraTools: string[] = [], activeTools?: string[]): string[] | undefined {
	void cwd;
	const baseTools = activeTools ?? [];
	const denied = new Set((agent.denyTools ?? []).map(normalizedPiToolName));
	const tools = [...baseTools, ...extraTools]
		.map((tool) => tool.trim())
		.filter((tool) => tool && !denied.has(normalizedPiToolName(tool)));
	return tools.length > 0 ? [...new Set(tools)] : undefined;
}

export function dashboardEnabled(cwd?: string): boolean {
	return settingBoolean("dashboard", true, cwd);
}

export function quietInline(cwd?: string): boolean {
	return settingBoolean("quietInlineWhenDashboard", true, cwd);
}

export function dashboardMaxItems(cwd?: string): number {
	return Math.max(1, Math.floor(settingNumber("dashboardMaxItems", 6, cwd)));
}

export function dashboardDefaultCollapsed(cwd?: string): boolean {
	return settingBoolean("dashboardCollapsed", false, cwd);
}

export function animateSpinnersEnabled(cwd?: string): boolean {
	return settingBoolean("animateSpinners", true, cwd);
}

export function dashboardShortcut(cwd?: string): string {
	return settingString("dashboardShortcut", "alt+a", cwd);
}

export function popupShortcut(cwd?: string): string {
	return settingString("popupShortcut", "alt+shift+a", cwd);
}

export function formatShortcutHint(shortcut: string): string {
	return shortcut.toLowerCase();
}

export function subagentTreeStyle(cwd?: string): "unicode" | "ascii" {
	return glyphStyle(cwd);
}

export function resultLimits(cwd?: string): ResultLimits {
	return {
		maxBytes: Math.max(1, Math.floor(settingNumber("resultMaxBytes", DEFAULT_RESULT_MAX_BYTES, cwd))),
		maxLines: Math.max(1, Math.floor(settingNumber("resultMaxLines", DEFAULT_RESULT_MAX_LINES, cwd))),
	};
}

export function bgTaskTimeoutMs(cwd?: string): number {
	return Math.max(0, Math.floor(settingNumber("bgTaskTimeoutMs", DEFAULT_BG_TASK_TIMEOUT_MS, cwd)));
}

export function splitResultLimits(total: ResultLimits, parts: number): ResultLimits {
	const count = Math.max(1, parts);
	return {
		maxBytes: Math.max(1024, Math.floor(total.maxBytes / count)),
		maxLines: Math.max(40, Math.floor(total.maxLines / count)),
	};
}
