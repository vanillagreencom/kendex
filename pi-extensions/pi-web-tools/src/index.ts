import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { computeNextActiveTools, statusLines } from "./active-tools.js";
import { INSTALL_SYMBOL } from "./activation.js";
import { rewriteNativeOpenAiWebSearch } from "./native-openai.js";
import { resolveWebProvider } from "./provider-selection.js";
import { installSettingsCacheRefresh, recordProjectTrust } from "./package-config.js";
import { loadSettings, WEB_PROVIDERS, type WebProvider, type WebToolsSettings } from "./settings.js";
import { restoreStoredContent } from "./storage.js";
import { createCodeSearchToolDefinition } from "./tools/code-search.js";
import { createGetWebContentToolDefinition } from "./tools/get-web-content.js";
import { createWebAnswerToolDefinition } from "./tools/web-answer.js";
import { createWebFetchToolDefinition } from "./tools/web-fetch.js";
import { createWebFindSimilarToolDefinition } from "./tools/web-find-similar.js";
import { createWebResearchToolDefinition } from "./tools/web-research.js";
import { createWebSearchToolDefinition } from "./tools/web-search.js";

type ModelLike = { provider?: string; id?: string; name?: string };
let providerOverride: WebProvider | undefined;

function currentSettings(cwd?: string): WebToolsSettings {
	const settings = loadSettings(cwd);
	return providerOverride ? { ...settings, defaultProvider: providerOverride } : settings;
}

function contextModel(ctx: ExtensionContext): ModelLike | undefined {
	return ctx.model as ModelLike | undefined;
}

function registerTools(pi: ExtensionAPI): void {
	pi.registerTool(createWebSearchToolDefinition(pi, currentSettings) as never);
	pi.registerTool(createWebFetchToolDefinition(pi, currentSettings) as never);
	pi.registerTool(createWebResearchToolDefinition(pi, currentSettings) as never);
	pi.registerTool(createWebAnswerToolDefinition(pi, currentSettings) as never);
	pi.registerTool(createWebFindSimilarToolDefinition(pi, currentSettings) as never);
	pi.registerTool(createCodeSearchToolDefinition(pi, currentSettings) as never);
	pi.registerTool(createGetWebContentToolDefinition() as never);
}

let compatibilityToolsRegistered = false;
function registerCompatibilityTools(pi: ExtensionAPI): void {
	if (compatibilityToolsRegistered) return;
	compatibilityToolsRegistered = true;
	pi.registerTool(createWebFetchToolDefinition(pi, currentSettings, "fetch_content") as never);
	pi.registerTool(createGetWebContentToolDefinition("get_search_content") as never);
	pi.registerTool(createWebSearchToolDefinition(pi, currentSettings, "web_search_exa", "exa") as never);
	pi.registerTool(createWebFetchToolDefinition(pi, currentSettings, "web_fetch_exa") as never);
	pi.registerTool(createWebResearchToolDefinition(pi, currentSettings, "web_research_exa") as never);
	pi.registerTool(createWebAnswerToolDefinition(pi, currentSettings, "web_answer_exa") as never);
	pi.registerTool(createWebFindSimilarToolDefinition(pi, currentSettings, "web_find_similar_exa") as never);
}

function registerConfiguredCompatibilityTools(pi: ExtensionAPI, cwd?: string): void {
	if (currentSettings(cwd).compatibilityTools) registerCompatibilityTools(pi);
}

function syncActiveTools(pi: ExtensionAPI, ctx: ExtensionContext): void {
	const settings = currentSettings(ctx.cwd);
	const active = pi.getActiveTools?.() ?? [];
	const next = computeNextActiveTools(active, contextModel(ctx), settings);
	if (next.join("\0") !== active.join("\0")) pi.setActiveTools(next);
}

function registerDiagnosticCommand(pi: ExtensionAPI): void {
	const showStatus = (ctx: ExtensionCommandContext) => {
		const settings = currentSettings(ctx.cwd);
		const lines = statusLines(contextModel(ctx as ExtensionContext), settings);
		if (settings.warnings.length) lines.push("warnings:", ...settings.warnings.map((line) => `- ${line}`));
		ctx.ui.notify(lines.join("\n"), "info");
	};
	const tryOpenExtensionManagerSettings = async (ctx: ExtensionCommandContext): Promise<boolean> => {
		const host = globalThis as unknown as Record<PropertyKey, unknown>;
		const openQuickSettings = host[Symbol.for("kendex.pi.extension-manager.open-quick-settings")];
		if (typeof openQuickSettings !== "function") return false;
		try {
			await (openQuickSettings as (ctx: ExtensionCommandContext, hint?: string) => Promise<void>)(ctx, "@vanillagreen/pi-web-tools");
			return true;
		} catch {
			return false;
		}
	};
	const setProvider = (next: WebProvider, ctx: ExtensionCommandContext) => {
		if (!WEB_PROVIDERS.includes(next)) {
			ctx.ui.notify(`Unknown provider: ${next}. Use ${WEB_PROVIDERS.join(", ")}.`, "error");
			return;
		}
		providerOverride = next;
		syncActiveTools(pi, ctx as ExtensionContext);
		ctx.ui.notify(`Web Tools provider set to ${next} for this session. Persist via kendex.extensionManager.config[\"@vanillagreen/pi-web-tools\"].defaultProvider.`, "info");
	};
	pi.registerCommand("web-tools", {
		description: "Open Web Tools settings (or status/provider). Usage: /web-tools | /web-tools:doctor | /web-tools:provider:<name>",
		handler: async (args: string, ctx) => {
			const parts = args.trim().split(/\s+/).filter(Boolean);
			if (parts[0] === "provider" && parts[1]) {
				setProvider(parts[1] as WebProvider, ctx);
				return;
			}
			if (parts.length === 0) {
				if (await tryOpenExtensionManagerSettings(ctx)) return;
				showStatus(ctx);
				return;
			}
			showStatus(ctx);
		},
	});
	pi.registerCommand("web-tools:doctor", {
		description: "Show Web Tools status and diagnostics",
		handler: async (_args: string, ctx) => showStatus(ctx),
	});
	for (const provider of WEB_PROVIDERS) {
		pi.registerCommand(`web-tools:provider:${provider}`, {
			description: `Set web search provider to ${provider} (session)`,
			handler: async (_args: string, ctx) => setProvider(provider, ctx),
		});
	}
}

export default function webTools(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;

	registerDiagnosticCommand(pi);
	registerTools(pi);

	installSettingsCacheRefresh(pi);
	pi.on("session_start", async (_event, ctx) => {
		recordProjectTrust(ctx);
		registerConfiguredCompatibilityTools(pi, ctx.cwd);
		restoreStoredContent(ctx);
		syncActiveTools(pi, ctx);
	});
	pi.on("model_select", async (_event, ctx) => {
		recordProjectTrust(ctx);
		registerConfiguredCompatibilityTools(pi, ctx.cwd);
		syncActiveTools(pi, ctx);
	});
	pi.on("thinking_level_select", async (_event, ctx) => {
		recordProjectTrust(ctx);
		registerConfiguredCompatibilityTools(pi, ctx.cwd);
		syncActiveTools(pi, ctx);
	});

	pi.on("before_provider_request", (event, ctx) => {
		recordProjectTrust(ctx);
		const settings = currentSettings(ctx.cwd);
		if (!settings.enabled || !settings.nativeOpenAiWebSearch) return undefined;
		const resolution = resolveWebProvider(undefined, settings, contextModel(ctx));
		if (resolution.provider !== "openai-native") return undefined;
		const result = rewriteNativeOpenAiWebSearch(event.payload, { externalWebAccess: settings.openAiExternalWebAccess });
		return result.rewritten.length > 0 ? result.payload : undefined;
	});
}
