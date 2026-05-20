import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { getCapabilities, Image, Text, type Component } from "@earendil-works/pi-tui";
import { hasOpenAiModelsLoaded } from "./activation.js";
import { registerBackgroundImageGenerationCommand } from "./background-image-generation.js";
import { computeNextActiveTools, computeToolCapabilities, modelKey, PACKAGE_TOOL_NAMES, type ModelLike } from "./capabilities.js";
import { registerOpenAICodexCustomProvider } from "./provider-shim.js";
import { rewriteNativeOpenAiTools } from "./provider-native-tools.js";
import { loadSettings, settingsDiagnostics } from "./settings.js";
import { createApplyPatchToolDefinition } from "./tools/apply-patch.js";
import { createImageGenerationToolDefinition } from "./tools/image-generation.js";
import { viewImage, viewImageToolSchema, type ValidatedImage, type ViewImageInput } from "./tools/view-image.js";
import { glyphs } from "./glyphs.js";

const INSTALL_SYMBOL = Symbol.for("vstack.pi-codex-minimal-tools.installed");

function terminalImageProtocol(): "kitty" | "iterm2" | null {
	return getCapabilities().images ?? null;
}

function formatBytes(bytes: number): string {
	if (!Number.isFinite(bytes) || bytes < 0) return "unknown size";
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${Math.round(bytes / 102.4) / 10}K`;
	return `${Math.round(bytes / (1024 * 102.4)) / 10}M`;
}

function viewImageCallText(args: ViewImageInput | undefined, theme: any): string {
	const path = typeof args?.path === "string" ? args.path : "image";
	const detail = args?.detail && args.detail !== "auto" ? ` ${theme.fg("dim", `${glyphs().dot.trim()} ${args.detail}`)}` : "";
	return `${theme.fg("accent", glyphs().bullet)}${theme.fg("text", theme.bold("View Image "))}${theme.fg("accent", path)}${detail}`;
}

function viewImageResultText(details: ValidatedImage | undefined, theme: any): string {
	if (!details) return `${theme.fg("accent", glyphs().bullet)}${theme.fg("text", theme.bold("View Image"))}${theme.fg("dim", `${glyphs().dot}image loaded`)}`;
	const type = details.mimeType.replace(/^image\//, "").toUpperCase();
	const protocol = terminalImageProtocol();
	const preview = protocol ? theme.fg("success", `inline ${protocol}`) : theme.fg("warning", "fallback");
	return `${theme.fg("accent", glyphs().bullet)}${theme.fg("text", theme.bold("View Image "))}${theme.fg("accent", details.displayPath)}${theme.fg("dim", glyphs().dot)}${theme.fg("success", type)}${theme.fg("dim", `${glyphs().dot}${formatBytes(details.sizeBytes)}${glyphs().dot}`)}${preview}`;
}

function emptyComponent(): Component {
	return { invalidate() {}, render: () => [] };
}

function textComponent(text: string): Component {
	return new Text(text, 0, 0);
}

function viewImageResultComponent(result: any, options: any, theme: any, context: any): Component {
	if (options?.isPartial) return emptyComponent();
	const details = result?.details as ValidatedImage | undefined;
	const imagePart = result?.content?.find?.((part: any) => part?.type === "image" && typeof part.data === "string" && typeof part.mimeType === "string");
	const header = textComponent(viewImageResultText(details, theme));
	if (!imagePart) return header;
	const imageTheme = { fallbackColor: (text: string) => theme.fg("dim", text) };
	const maxHeightCells = options?.expanded ? 28 : 18;
	const image = new Image(imagePart.data, imagePart.mimeType, imageTheme, { maxWidthCells: 80, maxHeightCells, filename: details?.displayPath });
	return {
		invalidate() {
			header.invalidate();
			image.invalidate();
		},
		render(width: number): string[] {
			return [...header.render(width), ...image.render(width)];
		},
	};
}

function contextModel(ctx: ExtensionContext): ModelLike | undefined {
	return ctx.model as ModelLike | undefined;
}

function removePackageToolsIfPresent(pi: ExtensionAPI): void {
	const active = pi.getActiveTools?.() ?? [];
	const next = active.filter((name) => !PACKAGE_TOOL_NAMES.includes(name as never));
	if (next.length !== active.length) pi.setActiveTools(next);
}

function syncActiveTools(pi: ExtensionAPI, ctx: ExtensionContext, toolsRegistered: boolean): void {
	if (!toolsRegistered || !hasOpenAiModelsLoaded(ctx)) {
		removePackageToolsIfPresent(pi);
		return;
	}
	const settings = loadSettings(ctx.cwd);
	const active = pi.getActiveTools?.() ?? [];
	const next = computeNextActiveTools(active, contextModel(ctx), settings);
	if (next.activeTools.join("\0") !== active.join("\0")) pi.setActiveTools(next.activeTools);
}

function statusLines(pi: ExtensionAPI, ctx: ExtensionContext): string[] {
	const settings = loadSettings(ctx.cwd);
	const model = contextModel(ctx);
	const capabilities = computeToolCapabilities(model, settings);
	const active = new Set(pi.getActiveTools?.() ?? []);
	return [
		"Codex Minimal Tools",
		`model: ${modelKey(model)}`,
		`openai models loaded: ${hasOpenAiModelsLoaded(ctx)}`,
		`enabled: ${settings.enabled}`,
		`autoEnable: ${settings.autoEnable}`,
		`nativeProviderTools: ${settings.nativeProviderTools}`,
		`native provider shim: ${settings.enabled && settings.nativeProviderTools ? "registered" : "disabled"}`,
		"tools:",
		...Object.entries(capabilities).map(([name, capability]) => `- ${name}: ${capability.enabled ? "supported" : "disabled"}${active.has(name) ? ", active" : ""} — ${capability.reason}`),
	];
}

function registerDiagnosticCommand(pi: ExtensionAPI): void {
	const showDoctor = (ctx: ExtensionCommandContext) => {
		const settings = loadSettings(ctx.cwd);
		const lines = statusLines(pi, ctx as ExtensionContext);
		lines.push(`image output dir: ${settings.imageOutputDir}`);
		lines.push(`OPENAI_API_KEY: ${process.env.OPENAI_API_KEY ? "present" : "not set"}`);
		const diagnostics = settingsDiagnostics(ctx.cwd);
		if (diagnostics.length > 0) lines.push("settings diagnostics:", ...diagnostics.map((line) => `- ${line}`));
		ctx.ui.notify(lines.join("\n"), "info");
	};
	const tryOpenExtensionManagerSettings = async (ctx: ExtensionCommandContext): Promise<boolean> => {
		const host = globalThis as unknown as Record<PropertyKey, unknown>;
		const openQuickSettings = host[Symbol.for("vstack.pi.extension-manager.open-quick-settings")];
		if (typeof openQuickSettings !== "function") return false;
		try {
			await (openQuickSettings as (ctx: ExtensionCommandContext, hint?: string) => Promise<void>)(ctx, "@vanillagreen/pi-codex-minimal-tools");
			return true;
		} catch {
			return false;
		}
	};
	pi.registerCommand("codex-minimal-tools", {
		description: "Open Codex Minimal Tools settings (or status). Usage: /codex-minimal-tools | /codex-minimal-tools:doctor",
		handler: async (args: string, ctx) => {
			const subcommand = args.trim().split(/\s+/, 1)[0]?.toLowerCase();
			if (subcommand === "doctor") {
				showDoctor(ctx);
				return;
			}
			if (!subcommand) {
				if (await tryOpenExtensionManagerSettings(ctx)) return;
				ctx.ui.notify(statusLines(pi, ctx as ExtensionContext).join("\n"), "info");
				return;
			}
			ctx.ui.notify(statusLines(pi, ctx as ExtensionContext).join("\n"), "info");
		},
	});
	pi.registerCommand("codex-minimal-tools:doctor", {
		description: "Run lightweight self-checks",
		handler: async (_args: string, ctx) => showDoctor(ctx),
	});
}

function registerTools(pi: ExtensionAPI): void {
	pi.registerTool(createImageGenerationToolDefinition({ loadSettings }) as never);
	pi.registerTool({
		renderShell: "self",
		name: "view_image",
		label: "View Image",
		description: "Inspect a local image file by returning image content to the model. Relative paths resolve against ctx.cwd; a leading @ is accepted.",
		promptSnippet: "Inspect local image files by path.",
		promptGuidelines: ["Use view_image when you need to inspect a local image file; pass the path in the path argument."],
		parameters: viewImageToolSchema,
		async execute(_toolCallId: string, params: ViewImageInput, _signal: AbortSignal | undefined, _onUpdate: unknown, ctx: ExtensionContext) {
			const settings = loadSettings(ctx.cwd);
			return viewImage(params, ctx.cwd, { workspaceOnly: settings.viewImageWorkspaceOnly }) as never;
		},
		renderCall(args: ViewImageInput, theme: any, context: any) {
			if (context?.executionStarted && !context?.isPartial) return emptyComponent();
			return textComponent(viewImageCallText(args, theme));
		},
		renderResult(result: any, options: any, theme: any, context: any) {
			return viewImageResultComponent(result, options, theme, context);
		},
	} as never);
	pi.registerTool(createApplyPatchToolDefinition({
		allowAbsolutePaths: (cwd) => loadSettings(cwd).allowAbsolutePatchPaths,
		deferRendering: loadSettings().deferApplyPatchRendering,
	}) as never);
}

export default function codexMinimalTools(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;

	let currentCwd = process.cwd();
	let toolsRegistered = false;
	const ensureToolsRegistered = (ctx: ExtensionContext): boolean => {
		currentCwd = ctx.cwd;
		if (toolsRegistered) return true;
		const settings = loadSettings(ctx.cwd);
		if (!settings.enabled || !hasOpenAiModelsLoaded(ctx)) return false;
		registerTools(pi);
		toolsRegistered = true;
		return true;
	};

	const initialSettings = loadSettings(currentCwd);
	if (initialSettings.enabled && initialSettings.nativeProviderTools) {
		registerOpenAICodexCustomProvider(pi, { getCurrentCwd: () => currentCwd });
		registerBackgroundImageGenerationCommand(pi);
	}

	registerDiagnosticCommand(pi);

	pi.on("session_start", async (_event, ctx) => syncActiveTools(pi, ctx, ensureToolsRegistered(ctx)));
	pi.on("model_select", async (_event, ctx) => syncActiveTools(pi, ctx, ensureToolsRegistered(ctx)));
	pi.on("thinking_level_select", async (_event, ctx) => syncActiveTools(pi, ctx, ensureToolsRegistered(ctx)));

	pi.on("before_provider_request", (event, ctx) => {
		currentCwd = ctx.cwd;
		const settings = loadSettings(ctx.cwd);
		if (!settings.enabled || !settings.nativeProviderTools || !hasOpenAiModelsLoaded(ctx) || contextModel(ctx)?.provider !== "openai-codex") return undefined;
		const result = rewriteNativeOpenAiTools(event.payload, { imageModel: settings.imageModel });
		return result.rewritten.length > 0 ? result.payload : undefined;
	});
}
