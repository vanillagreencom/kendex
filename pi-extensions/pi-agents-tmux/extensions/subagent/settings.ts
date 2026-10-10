import * as path from "node:path";
import { stat } from "node:fs/promises";
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

export const DEFAULT_BG_TASK_TIMEOUT_MS = 2 * 60 * 60 * 1000;

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

export type AgentModelRegistry = Pick<ExtensionContext["modelRegistry"], "refresh" | "getError" | "getAvailable">;
type ModelCapture = (command: string, args: string[], options: { cwd: string; env: NodeJS.ProcessEnv; input?: string }) => Promise<{ code: number; stdout: string; stderr: string; error?: unknown }>;
let modelWarningEmitted = false;

/** Release the session's warning receipt when the extension session ends. */
export function resetModelWarning(): void { modelWarningEmitted = false; }

/** Resolve raw child intent through core at the effective child directory. */
export async function resolveAgentModel(
	agent: AgentConfig, parentModel: string | undefined, cwd: string,
	registry: AgentModelRegistry | undefined, capture: ModelCapture,
): Promise<string | undefined> {
	try {
		return await resolveAgentModelAttempt(agent, parentModel, cwd, registry, capture);
	} catch (error) {
		if (agent.callModelFallback === undefined) throw error;
		if (!modelWarningEmitted) {
			console.warn(`model-resolution: requested=${agent.model} fallback=${agent.callModelFallback.model ?? "inherit"} cause=${String(error)}`);
			modelWarningEmitted = true;
		}
		// The launcher's effort chooser must read the fallback's raw suffix too.
		agent.model = agent.callModelFallback.model;
		delete agent.callModelFallback;
		return resolveAgentModelAttempt(agent, parentModel, cwd, registry, capture);
	}
}

async function resolveAgentModelAttempt(
	agent: AgentConfig, parentModel: string | undefined, cwd: string,
	registry: AgentModelRegistry | undefined, capture: ModelCapture,
): Promise<string | undefined> {
	const raw = selectedModelForAgent(agent, parentModel, cwd);
	const request = agent.model === undefined || subagentModelSource(cwd) === "parent"
		? "inherit" : modelWithoutEffortSuffix(raw) ?? raw ?? "inherit";
	const account = "pi-session";
	const host = "pi-process";
	let available: ReturnType<AgentModelRegistry["getAvailable"]> = [];
	let models: unknown = { tag: "unsupported", source: "pi:modelRegistry" };
	if (registry !== undefined) {
		let source = "pi:modelRegistry.refresh";
		try {
			const refreshed = await registry.refresh({ allowNetwork: false });
			if (refreshed.aborted) throw new Error("registry refresh aborted");
			if (refreshed.errors.size > 0) throw new Error([...refreshed.errors].map(([provider, error]) => `${provider}: ${error.message}`).join("; "));
			const registryError = registry.getError();
			if (registryError !== undefined) throw new Error(registryError);
			source = "pi:modelRegistry.getAvailable";
			available = registry.getAvailable();
			models = { tag: "complete", source: "pi:modelRegistry.getAvailable", account, host,
				models: available.map(model => ({ provider: model.provider, id: model.id, nativeSelector: `${model.provider}/${model.id}`, allowed: true, chat: true, isDefault: false })) };
		} catch (error) {
			models = { tag: "failed", source, cause: String(error) };
		}
	}
	const parent = available.find(model => `${model.provider}/${model.id}` === parentModel);
	const context = { protocol: "model-resolution-v1", harness: "pi", account, host,
		providers: [...new Set(available.map(model => model.provider))], currentProvider: parent?.provider ?? null,
		models, default: parentModel === undefined ? { tag: "native-default" } : {
			tag: "observed-session-or-default", selector: parentModel, provider: parent?.provider ?? null,
			id: parent?.id ?? null, account, host, source: "pi:parent-model" },
		capacity: available.filter(model => Number.isSafeInteger(model.contextWindow) && model.contextWindow > 0).map(model => ({
			tag: "known", selector: `${model.provider}/${model.id}`, account, host,
			source: "pi:modelRegistry.getAvailable", context_window: model.contextWindow })), rejected: [] };
	const result = await capture("kendex", ["tier-model", "pi", "--model", request, "--runtime-context-stdin", "--json"], { cwd, env: { ...process.env }, input: JSON.stringify(context) });
	if (result.error instanceof Error && "code" in result.error && result.error.code === "ENOENT") {
		if (!(await stat(cwd)).isDirectory()) throw new Error("model-resolution: invalid=child-directory");
		if (request === "inherit") return parentModel;
		const exact = available.filter(model => `${model.provider}/${model.id}` === request || (!request.includes("/") && model.id === request));
		if (exact.length === 1) return `${exact[0].provider}/${exact[0].id}`;
		throw new Error("resolver-missing: command=kendex\nInstall kendex to resolve this model request.");
	}
	if (result.code !== 0 || result.error !== undefined) throw new Error(`model-resolution: core-exit=${result.code} cause=${result.stderr || String(result.error)}`);
	const response = modelObject(JSON.parse(result.stdout));
	if (response.protocol !== "model-resolution-v1" || response.harness !== "pi") throw new Error("model-resolution: invalid=protocol");
	const decision = modelObject(response.resolution);
	let selector: string | undefined;
	switch (decision.tag) {
		case "selected": selector = modelSelector(modelObject(decision.selection).nativeSelector); break;
		case "harness-default": {
			const fallback = modelObject(decision.path);
			switch (fallback.tag) {
				case "native-default": selector = parentModel; break;
				case "observed-session-or-default": selector = modelSelector(fallback.selector); break;
				default: throw new Error("model-resolution: invalid=default-path");
			}
			break;
		}
		case "inherit": selector = parentModel; break;
		default: throw new Error("model-resolution: invalid=child-result");
	}
	if (decision.diagnostics !== undefined) {
		if (!Array.isArray(decision.diagnostics)) throw new Error("model-resolution: invalid=diagnostics");
		const diagnostics = decision.diagnostics.map(modelObject);
		const codes = diagnostics.map(d => modelSelector(d.code));
		if (decision.diagnostics.length > 0 && !modelWarningEmitted) {
			console.warn(`model-resolution: requested=${request} selected=${selector ?? "native-default"} causes=${codes.join(",")} source=${diagnostics.map(d => d.source ?? "").join(",")} cause=${diagnostics.map(d => d.cause ?? "").join(";")}`);
			modelWarningEmitted = true;
		}
	}
	// A core-selected model reaches Pi with effort supplied by --thinking.
	if (decision.tag === "selected") return selector;
	// Native defaults and inherited models keep the caller's thinking suffix.
	const effort = effortFromModelId(raw);
	return selector && effort ? `${modelWithoutEffortSuffix(selector)}:${effort}` : selector;
}

function modelObject(value: unknown): Record<string, unknown> {
	if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("model-resolution: invalid=record");
	return value as Record<string, unknown>;
}

function modelSelector(value: unknown): string {
	if (typeof value !== "string" || value.length === 0) throw new Error("model-resolution: invalid=selector");
	return value;
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
	const configured = Math.floor(settingNumber("bgTaskTimeoutMs", DEFAULT_BG_TASK_TIMEOUT_MS, cwd));
	if (configured <= 0) console.warn(`bg-task-timeout: legacy-value=${configured}\nNonpositive timeouts now use the default deadline.`);
	return configured > 0 ? configured : DEFAULT_BG_TASK_TIMEOUT_MS;
}

export function splitResultLimits(total: ResultLimits, parts: number): ResultLimits {
	const count = Math.max(1, parts);
	return {
		maxBytes: Math.max(1024, Math.floor(total.maxBytes / count)),
		maxLines: Math.max(40, Math.floor(total.maxLines / count)),
	};
}
