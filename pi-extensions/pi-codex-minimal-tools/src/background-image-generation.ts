import { readFile } from "node:fs/promises";
import { extname, isAbsolute, resolve } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext, Theme } from "@earendil-works/pi-coding-agent";
import type { Api, Model } from "@earendil-works/pi-ai";
import { type Component, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { supportsImageInput, type ModelLike } from "./capabilities.js";
import { frameGlyphs, glyphs, treeGlyph } from "./glyphs.js";
import { loadSettings } from "./settings.js";
import {
	buildGeneratedImageDisplayText,
	IMAGE_SAVE_DISPLAY_MESSAGE_TYPE,
	saveOpenAICodexGeneratedImage,
} from "./provider-shim.js";

const DEFAULT_CODEX_BASE_URL = "https://chatgpt.com/backend-api";
const JWT_CLAIM_PATH = "https://api.openai.com/auth";
const BACKGROUND_IMAGE_INSTRUCTIONS = "Generate or edit images with the hosted image_generation tool. Use the user's prompt and any provided reference images. Return the image_generation_call result.";
const IMAGE_GEN_STATUS_KEY = "codex-image-gen";
const IMAGE_GEN_ERROR_MESSAGE_TYPE = "codex-image-generation-error";
const PANEL_BAR_COLOR = "borderAccent";
const PANEL_TITLE_COLOR = "customMessageLabel";
const PANEL_RULE_COLOR = "muted";
const PANEL_CARD_PADDING_X = 1;
const OPENAI_CODEX_PROVIDER = "openai-codex";
const OPENAI_CODEX_MODEL_PROBE_IDS = ["gpt-5.5", "gpt-5.4", "gpt-5.3-codex", "gpt-5.2", "gpt-5.1", "gpt-5", "gpt-4.1", "o4-mini"];

interface ActiveImageJob {
	id: string;
	startedAt: number;
	prompt: string;
	referenceCount: number;
	imageModel: string;
}

const activeImageJobs = new Map<string, ActiveImageJob>();
let activeStatusCtx: ExtensionCommandContext | undefined;
let statusTimer: ReturnType<typeof setInterval> | undefined;

export interface ParsedImageGenCommand {
	prompt: string;
	imagePaths: string[];
}

interface ReferenceImage {
	path: string;
	mimeType: string;
	base64: string;
}

interface CodexImageResult {
	id: string;
	result: string;
	outputFormat?: string;
	revisedPrompt?: string;
	imageModel?: string;
}

interface ImageGenerationErrorDetails {
	message: string;
	prompt?: string;
	imageModel?: string;
	referenceCount?: number;
}

interface ModelRegistryLike {
	getAll?: () => unknown;
	getAvailable?: () => unknown;
	find?: (provider: string, id: string) => unknown;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isModelLike(value: unknown): value is ModelLike {
	return isRecord(value) && typeof value.provider === "string" && (typeof value.id === "string" || typeof value.name === "string");
}

function registryModels(registry: ModelRegistryLike | undefined): ModelLike[] {
	if (!registry) return [];
	for (const method of [registry.getAll, registry.getAvailable]) {
		if (typeof method !== "function") continue;
		try {
			const value = method.call(registry);
			if (Array.isArray(value)) return value.filter(isModelLike);
		} catch {
			// Try the next registry shape.
		}
	}
	return [];
}

function isOpenAiCodexImageModel(model: ModelLike | undefined): boolean {
	return model?.provider === OPENAI_CODEX_PROVIDER && supportsImageInput(model);
}

export function selectCodexImageModel(currentModel: ModelLike | undefined, registry: ModelRegistryLike | undefined): ModelLike | undefined {
	if (isOpenAiCodexImageModel(currentModel)) return currentModel;
	const discovered = registryModels(registry).find(isOpenAiCodexImageModel);
	if (discovered) return discovered;
	for (const id of OPENAI_CODEX_MODEL_PROBE_IDS) {
		const candidate = registry?.find?.(OPENAI_CODEX_PROVIDER, id);
		if (isModelLike(candidate) && isOpenAiCodexImageModel(candidate)) return candidate;
	}
	return undefined;
}

function tokenizeArgs(input: string): string[] {
	const tokens: string[] = [];
	let current = "";
	let quote: '"' | "'" | undefined;
	let escaped = false;
	for (const ch of input) {
		if (escaped) {
			current += ch;
			escaped = false;
			continue;
		}
		if (ch === "\\") {
			escaped = true;
			continue;
		}
		if (quote) {
			if (ch === quote) quote = undefined;
			else current += ch;
			continue;
		}
		if (ch === '"' || ch === "'") {
			quote = ch;
			continue;
		}
		if (/\s/.test(ch)) {
			if (current) tokens.push(current);
			current = "";
			continue;
		}
		current += ch;
	}
	if (current) tokens.push(current);
	return tokens;
}

function isSupportedImagePathToken(token: string): boolean {
	const normalized = token.replace(/^file:\/\//, "").replace(/[),.;:]+$/, "");
	if (/^https?:\/\//i.test(normalized) || normalized.startsWith("data:")) return false;
	return /\.(?:png|jpe?g|webp)$/i.test(normalized);
}

function padAnsi(text: string, width: number): string {
	const truncated = truncateToWidth(text, width, "");
	return `${truncated}${" ".repeat(Math.max(0, width - visibleWidth(truncated)))}`;
}

function panelFrameContentWidth(width: number): number {
	return Math.max(1, width - 2 - PANEL_CARD_PADDING_X * 2);
}

function panelFrame(lines: string[], width: number, theme: Theme): string[] {
	const safeWidth = Math.max(1, width);
	if (safeWidth < 8) return lines.map((line) => truncateToWidth(line, safeWidth, ""));
	const inner = Math.max(1, safeWidth - 2);
	const contentWidth = panelFrameContentWidth(safeWidth);
	const border = (text: string) => theme.fg(PANEL_BAR_COLOR, text);
	const frame = frameGlyphs();
	return [
		`${border(frame.tl)}${border(frame.h.repeat(inner))}${border(frame.tr)}`,
		...lines.map((line) => `${border(frame.v)}${" ".repeat(PANEL_CARD_PADDING_X)}${padAnsi(line, contentWidth)}${" ".repeat(PANEL_CARD_PADDING_X)}${border(frame.v)}`),
		`${border(frame.bl)}${border(frame.h.repeat(inner))}${border(frame.br)}`,
	].map((line) => truncateToWidth(line, safeWidth, ""));
}

function panelBranch(theme: Theme, branch: "├" | "└" | "│"): string {
	return theme.fg(PANEL_RULE_COLOR, treeGlyph(branch));
}

function renderStatusHeader(jobs: ActiveImageJob[], theme: Theme): string {
	const oldest = jobs[0];
	const elapsed = oldest ? Math.max(0, Math.round((Date.now() - oldest.startedAt) / 1000)) : 0;
	const imageModels = [...new Set(jobs.map((job) => job.imageModel))];
	const modelText = imageModels.length === 1 ? imageModels[0] : `${imageModels.length} models`;
	const refs = jobs.reduce((total, job) => total + job.referenceCount, 0);
	const refText = refs > 0 ? ` · ${refs} ref${refs === 1 ? "" : "s"}` : "";
	return `${theme.fg(PANEL_TITLE_COLOR, theme.bold("Image Generation"))} ${theme.fg("muted", `${jobs.length} running · ${modelText}${refText} · ${elapsed}s`)}`;
}

function renderJobLines(theme: Theme, width: number): string[] {
	const jobs = Array.from(activeImageJobs.values()).sort((a, b) => a.startedAt - b.startedAt);
	if (jobs.length === 0) return [];
	const dot = theme.fg("dim", glyphs().dot);
	const lines = [renderStatusHeader(jobs, theme)];
	const shown = jobs.slice(0, 4);
	for (const [index, job] of shown.entries()) {
		const ageSeconds = Math.max(0, Math.round((Date.now() - job.startedAt) / 1000));
		const isLast = index === shown.length - 1 && jobs.length <= shown.length;
		const refs = job.referenceCount > 0 ? `${dot}${theme.fg("dim", `${job.referenceCount} ref${job.referenceCount === 1 ? "" : "s"}`)}` : "";
		const promptWidth = Math.max(16, width - 36);
		lines.push(`${panelBranch(theme, isLast ? "└" : "├")}${theme.fg("accent", glyphs().bullet.trim())} ${theme.fg("accent", truncateToWidth(job.prompt, promptWidth, glyphs().ellipsis))}${dot}${theme.fg("muted", job.imageModel)}${refs}${dot}${theme.fg("dim", `${ageSeconds}s`)}`);
	}
	const hidden = jobs.length - shown.length;
	if (hidden > 0) lines.push(`${panelBranch(theme, "└")}${theme.fg("muted", `${glyphs().ellipsis} ${hidden} more`)}`);
	return panelFrame(lines, width, theme);
}

function createImageGenWidgetFactory(): (_tui: unknown, theme: Theme) => Component {
	return (_tui, theme) => ({
		invalidate() {},
		render(width: number): string[] {
			return renderJobLines(theme, width);
		},
	});
}

function ensureStatusTimer(): void {
	if (statusTimer) return;
	statusTimer = setInterval(() => {
		if (!activeStatusCtx || activeImageJobs.size === 0) {
			if (statusTimer) clearInterval(statusTimer);
			statusTimer = undefined;
			return;
		}
		updateImageGenStatus(activeStatusCtx);
	}, 1000);
	statusTimer.unref?.();
}

function updateImageGenStatus(ctx: ExtensionCommandContext): void {
	activeStatusCtx = ctx;
	const count = activeImageJobs.size;
	ctx.ui.setStatus(IMAGE_GEN_STATUS_KEY, count > 0 ? `image-gen ${count}` : undefined);
	ctx.ui.setWidget(IMAGE_GEN_STATUS_KEY, count > 0 ? createImageGenWidgetFactory() : undefined, { placement: "aboveEditor" });
	if (count > 0) ensureStatusTimer();
}

function startImageJob(ctx: ExtensionCommandContext, parsed: ParsedImageGenCommand, imageModel: string): ActiveImageJob {
	const job: ActiveImageJob = {
		id: `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
		startedAt: Date.now(),
		prompt: parsed.prompt,
		referenceCount: parsed.imagePaths.length,
		imageModel,
	};
	activeImageJobs.set(job.id, job);
	updateImageGenStatus(ctx);
	return job;
}

function finishImageJob(ctx: ExtensionCommandContext, jobId: string): void {
	activeImageJobs.delete(jobId);
	updateImageGenStatus(ctx);
}

export function parseImageGenCommandArgs(input: string): ParsedImageGenCommand {
	const imagePaths: string[] = [];
	const promptParts: string[] = [];
	for (const token of tokenizeArgs(input.trim())) {
		if (token.startsWith("@") && token.length > 1) imagePaths.push(token.slice(1));
		else if (isSupportedImagePathToken(token)) imagePaths.push(token.replace(/^file:\/\//, "").replace(/[),.;:]+$/, ""));
		else promptParts.push(token);
	}
	return { prompt: promptParts.join(" ").trim(), imagePaths };
}

function mimeTypeForPath(path: string): string {
	const ext = extname(path).toLowerCase();
	if (ext === ".jpg" || ext === ".jpeg") return "image/jpeg";
	if (ext === ".webp") return "image/webp";
	if (ext === ".png") return "image/png";
	throw new Error(`Unsupported reference image type: ${path}. Use PNG, JPEG, or WebP.`);
}

async function loadReferenceImage(cwd: string, rawPath: string): Promise<ReferenceImage> {
	const path = isAbsolute(rawPath) ? rawPath : resolve(cwd, rawPath);
	const buffer = await readFile(path);
	return { path, mimeType: mimeTypeForPath(path), base64: buffer.toString("base64") };
}

function resolveCodexUrl(baseUrl: string | undefined): string {
	const raw = baseUrl && baseUrl.trim().length > 0 ? baseUrl : DEFAULT_CODEX_BASE_URL;
	const normalized = raw.replace(/\/+$/, "");
	if (normalized.endsWith("/codex/responses")) return normalized;
	if (normalized.endsWith("/codex")) return `${normalized}/responses`;
	return `${normalized}/codex/responses`;
}

function extractAccountId(token: string): string {
	try {
		const parts = token.split(".");
		if (parts.length !== 3) throw new Error("Invalid token");
		const payload = JSON.parse(Buffer.from(parts[1] ?? "", "base64").toString("utf8"));
		const accountId = payload?.[JWT_CLAIM_PATH]?.chatgpt_account_id;
		if (!accountId) throw new Error("No account ID in token");
		return accountId;
	} catch {
		throw new Error("Failed to extract accountId from Codex OAuth token");
	}
}

function buildHeaders(model: Model<Api>, apiKey: string, extraHeaders?: Record<string, string>): Headers {
	const headers = new Headers(model.headers);
	for (const [key, value] of Object.entries(extraHeaders ?? {})) headers.set(key, value);
	headers.set("Authorization", `Bearer ${apiKey}`);
	headers.set("chatgpt-account-id", extractAccountId(apiKey));
	headers.set("originator", "pi");
	headers.set("OpenAI-Beta", "responses=experimental");
	headers.set("accept", "text/event-stream");
	headers.set("content-type", "application/json");
	return headers;
}

export function buildBackgroundImageRequest(options: {
	prompt: string;
	referenceImages: ReferenceImage[];
	responsesModel: string;
	imageModel: string;
}): Record<string, unknown> {
	const content: Array<Record<string, unknown>> = [
		{ type: "input_text", text: options.referenceImages.length > 0 ? `Edit the provided image(s): ${options.prompt}` : options.prompt },
		...options.referenceImages.map((image) => ({
			type: "input_image",
			detail: "auto",
			image_url: `data:${image.mimeType};base64,${image.base64}`,
		})),
	];
	return {
		model: options.responsesModel,
		store: false,
		stream: true,
		instructions: BACKGROUND_IMAGE_INSTRUCTIONS,
		input: [{ role: "user", content }],
		tools: [{
			type: "image_generation",
			model: options.imageModel,
			output_format: "png",
			action: options.referenceImages.length > 0 ? "edit" : "generate",
		}],
		tool_choice: { type: "image_generation" },
	};
}

async function* parseSseEvents(response: Response): AsyncIterable<Record<string, unknown>> {
	if (!response.body) return;
	const reader = response.body.getReader();
	const decoder = new TextDecoder();
	let buffer = "";
	while (true) {
		const { done, value } = await reader.read();
		if (done) break;
		buffer += decoder.decode(value, { stream: true });
		let boundary: number;
		while ((boundary = buffer.indexOf("\n\n")) >= 0) {
			const raw = buffer.slice(0, boundary);
			buffer = buffer.slice(boundary + 2);
			for (const line of raw.split(/\r?\n/)) {
				if (!line.startsWith("data:")) continue;
				const data = line.slice(5).trim();
				if (!data || data === "[DONE]") continue;
				yield JSON.parse(data) as Record<string, unknown>;
			}
		}
	}
}

function collectImageResult(results: CodexImageResult[], item: unknown, fallbackImageModel: string): void {
	if (!item || typeof item !== "object") return;
	const candidate = item as Record<string, unknown>;
	if (candidate.type !== "image_generation_call" || typeof candidate.result !== "string") return;
	const id = typeof candidate.id === "string" ? candidate.id : `ig_${results.length}`;
	if (results.some((result) => result.id === id)) return;
	results.push({
		id,
		result: candidate.result,
		outputFormat: typeof candidate.output_format === "string" ? candidate.output_format : "png",
		revisedPrompt: typeof candidate.revised_prompt === "string" ? candidate.revised_prompt : undefined,
		imageModel: typeof candidate.model === "string" ? candidate.model : fallbackImageModel,
	});
}

function collectResponseText(value: unknown, out: string[]): void {
	if (!value || typeof value !== "object") return;
	const item = value as Record<string, unknown>;
	for (const key of ["text", "refusal", "summary_text", "message"] as const) {
		const text = item[key];
		if (typeof text === "string" && text.trim()) out.push(text.trim());
	}
	for (const key of ["content", "output", "summary"] as const) {
		const child = item[key];
		if (Array.isArray(child)) for (const part of child) collectResponseText(part, out);
	}
}

export function summarizeNonImageResponse(response: Record<string, unknown> | undefined): string {
	if (!response) return "No image was returned by Codex.";
	const status = typeof response.status === "string" ? response.status : undefined;
	const error = response.error && typeof response.error === "object" ? response.error as Record<string, unknown> : undefined;
	const errorMessage = typeof error?.message === "string" ? error.message : undefined;
	const texts: string[] = [];
	collectResponseText(response, texts);
	const text = [...new Set(texts)].join(" ").replace(/\s+/g, " ").trim();
	const details = [status && status !== "completed" ? `status ${status}` : undefined, errorMessage, text].filter(Boolean).join(" · ");
	return details ? `No image was returned by Codex: ${details}` : "No image was returned by Codex.";
}

function renderImageGenError(details: ImageGenerationErrorDetails, theme: Theme): Component {
	return {
		invalidate() {},
		render(width: number): string[] {
			const safeWidth = Math.max(1, width);
			const message = details.message || "Image generation failed.";
			const promptWidth = Math.max(16, safeWidth - 28);
			const lines = [
				`${theme.fg("error", "● ")}${theme.fg("text", theme.bold("Image Generation "))}${theme.fg("error", "failed")}`,
			];
			if (details.imageModel) lines.push(`${panelBranch(theme, "├")}${theme.fg("text", "Model ")}${theme.fg("muted", details.imageModel)}`);
			if (details.referenceCount && details.referenceCount > 0) lines.push(`${panelBranch(theme, "├")}${theme.fg("text", "Refs ")}${theme.fg("muted", `${details.referenceCount}`)}`);
			if (details.prompt) lines.push(`${panelBranch(theme, "├")}${theme.fg("text", "Prompt ")}${theme.fg("muted", truncateToWidth(details.prompt, promptWidth, "…"))}`);
			lines.push(`${panelBranch(theme, "└")}${theme.fg("error", truncateToWidth(message, Math.max(16, safeWidth - 5), "…"))}`);
			return lines.map((line) => truncateToWidth(line, safeWidth, ""));
		},
	};
}

async function runBackgroundImageGeneration(pi: ExtensionAPI, ctx: ExtensionCommandContext, parsed: ParsedImageGenCommand): Promise<void> {
	const settings = loadSettings(ctx.cwd);
	const model = selectCodexImageModel(ctx.model as ModelLike | undefined, ctx.modelRegistry as ModelRegistryLike | undefined) as Model<Api> | undefined;
	if (!model) throw new Error("No image-capable openai-codex model is available. Update Pi's model registry or select an openai-codex image-capable model.");
	const auth = await ctx.modelRegistry.getApiKeyAndHeaders(model);
	if (!auth.ok) throw new Error(auth.error);
	if (!auth.apiKey) throw new Error("No Codex OAuth token is configured. Run /login openai-codex.");
	const referenceImages = await Promise.all(parsed.imagePaths.map((path) => loadReferenceImage(ctx.cwd, path)));
	const body = buildBackgroundImageRequest({
		prompt: parsed.prompt,
		referenceImages,
		responsesModel: model.id,
		imageModel: settings.imageModel,
	});
	const response = await fetch(resolveCodexUrl(model.baseUrl), {
		method: "POST",
		headers: buildHeaders(model, auth.apiKey, auth.headers),
		body: JSON.stringify(body),
	});
	if (!response.ok) throw new Error(`Codex image generation failed: ${response.status} ${await response.text()}`);
	const results: CodexImageResult[] = [];
	let responseId: string | undefined;
	let lastResponse: Record<string, unknown> | undefined;
	for await (const event of parseSseEvents(response)) {
		if (event.type === "response.created" && event.response && typeof event.response === "object") {
			lastResponse = event.response as Record<string, unknown>;
			const id = (event.response as { id?: unknown }).id;
			if (typeof id === "string") responseId = id;
		}
		if (event.type === "response.output_item.done") collectImageResult(results, event.item, settings.imageModel);
		if ((event.type === "response.completed" || event.type === "response.done") && event.response && typeof event.response === "object") {
			lastResponse = event.response as Record<string, unknown>;
			const responseOutput = (event.response as { output?: unknown }).output;
			if (Array.isArray(responseOutput)) for (const item of responseOutput) collectImageResult(results, item, settings.imageModel);
		}
	}
	if (results.length === 0) throw new Error(summarizeNonImageResponse(lastResponse));
	const savedImages = [];
	for (const result of results) {
		savedImages.push(await saveOpenAICodexGeneratedImage(ctx.cwd, {
			responseId,
			callId: result.id,
			result: result.result,
			outputFormat: result.outputFormat,
			imageModel: result.imageModel,
			revisedPrompt: result.revisedPrompt ?? parsed.prompt,
		}));
	}
	pi.sendMessage({
		customType: IMAGE_SAVE_DISPLAY_MESSAGE_TYPE,
		content: [{ type: "text", text: buildGeneratedImageDisplayText(savedImages[0], { expanded: false }) }],
		display: true,
		details: { savedImages },
	}, { triggerTurn: false });
}

export function registerBackgroundImageGenerationCommand(pi: ExtensionAPI): void {
	pi.registerMessageRenderer<ImageGenerationErrorDetails>(IMAGE_GEN_ERROR_MESSAGE_TYPE, (message, _options, theme) => {
		const rawContent = typeof message.content === "string"
			? message.content
			: message.content
					.filter((item) => item.type === "text")
					.map((item) => item.text)
					.join("\n");
		const details: ImageGenerationErrorDetails = {
			message: message.details?.message ?? rawContent.replace(/^Image generation failed:\s*/i, "") ?? "Image generation failed.",
			prompt: message.details?.prompt,
			imageModel: message.details?.imageModel,
			referenceCount: message.details?.referenceCount,
		};
		return renderImageGenError(details, theme);
	});

	pi.registerCommand("image-gen", {
		description: "Generate or edit an image in the background with Codex OAuth. Usage: /image-gen prompt text [@reference.png]",
		handler: async (args, ctx) => {
			const parsed = parseImageGenCommandArgs(args);
			if (!parsed.prompt) {
				ctx.ui.notify("Usage: /image-gen prompt text [@reference.png]", "warning");
				return;
			}
			const settings = loadSettings(ctx.cwd);
			const job = startImageJob(ctx, parsed, settings.imageModel);
			ctx.ui.notify(`Queued image generation with ${settings.imageModel}${parsed.imagePaths.length ? ` (${parsed.imagePaths.length} reference image${parsed.imagePaths.length === 1 ? "" : "s"})` : ""}.`, "info");
			void runBackgroundImageGeneration(pi, ctx, parsed)
				.catch((error) => {
					const message = error instanceof Error ? error.message : String(error);
					pi.sendMessage({
						customType: IMAGE_GEN_ERROR_MESSAGE_TYPE,
						content: `Image generation failed: ${message}`,
						display: true,
						details: { message, prompt: parsed.prompt, imageModel: settings.imageModel, referenceCount: parsed.imagePaths.length } satisfies ImageGenerationErrorDetails,
					}, { triggerTurn: false });
				})
				.finally(() => finishImageJob(ctx, job.id));
		},
	});
}
