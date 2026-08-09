import { fileURLToPath, pathToFileURL } from "node:url";
import { basename, isAbsolute, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { extractGitHubUrl } from "../extract/github.js";
import { fetchHttpContent, isProbablyPdf } from "../extract/http.js";
import { extractLocalVideo, isLocalVideoPath } from "../extract/video.js";
import { extractYouTubeUrl, isTranscriptPrompt, parseYouTubeUrl } from "../extract/youtube.js";
import { readFile as fsReadFile } from "node:fs/promises";
import { fetchLocalPdfText, fetchPdfText, extractPdfTextBest } from "../extract/pdf.js";
import { looksLikeScannedPdf, rasterizePdfPages, type PdfPageImage } from "../extract/pdf-pages.js";
import { ExaClient } from "../providers/exa.js";
import type { WebToolsSettings } from "../settings.js";
import { storeWebContent, type StoredWebContent } from "../storage.js";
import { truncateText } from "../utils/format.js";
import { accent, emptyComponent, errorSummary, firstText, muted, providerLabel, successSummary, textComponent, tree, webCallText } from "../utils/render.js";

export const webFetchSchema = Type.Object({
	url: Type.Optional(Type.String()),
	urls: Type.Optional(Type.Array(Type.String())),
	filePath: Type.Optional(Type.String({ description: "Local file path to extract. Currently supports PDFs. Relative paths resolve against ctx.cwd; leading @ is stripped." })),
	filePaths: Type.Optional(Type.Array(Type.String({ description: "Local file paths to extract. Currently supports PDFs." }))),
	textMaxCharacters: Type.Optional(Type.Number({ description: "Preview character cap for direct/GitHub/PDF fetches and provider extraction cap for Exa fallback/override. Direct fetches still store the full extracted text in session storage before preview truncation. Multi-URL calls otherwise cap the aggregate `content[0].text` (16 KB for 2–5 URLs, 25 KB for 6+ URLs with a manifest); passing this flag opts back into larger per-URL previews." })),
	provider: Type.Optional(Type.Union([Type.Literal("auto"), Type.Literal("http"), Type.Literal("exa")])),
	prompt: Type.Optional(Type.String({ description: "Optional prompt for video/YouTube extraction. Transcript requests use native YouTube captions; other video prompts use Gemini Web/API. Ignored for non-video URLs." })),
	videoMode: Type.Optional(Type.Union([Type.Literal("auto"), Type.Literal("transcript"), Type.Literal("understand")], { description: "YouTube handling mode. auto detects transcript requests from prompt; transcript fetches complete native captions; understand uses Gemini for audio/visual analysis." })),
	transcriptLanguage: Type.Optional(Type.String({ description: "Preferred YouTube caption language (BCP 47 code). When omitted, uses YouTube's first available caption track. Used only for native transcript extraction." })),
});
export type WebFetchInput = Static<typeof webFetchSchema>;

export const DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS = 4000;

// Multi-URL aggregate caps for `content[0].text` so a single tool call can't blow the model's input window.
// Single-URL fetches and callers passing `textMaxCharacters` explicitly bypass these caps.
export const MULTI_URL_AGGREGATE_CAP_SMALL_BATCH = 16 * 1024;
export const MULTI_URL_AGGREGATE_CAP_LARGE_BATCH = 25 * 1024;
export const MULTI_URL_LARGE_BATCH_THRESHOLD = 6;
export const MULTI_URL_LARGE_BATCH_PER_URL_HEAD = 512;
export const WEB_FETCH_FAILURE_MESSAGE_MAX_CHARACTERS = 1024;
export const WEB_FETCH_FAILURE_ROW_MAX_CHARACTERS = 1536;
export const WEB_FETCH_FAILURE_BLOCK_MAX_CHARACTERS = 8 * 1024;
export const DEFAULT_YOUTUBE_EXTRACTION_TIMEOUT_MS = 120_000;

interface WebFetchPreviewItem {
	id: string;
	shownCharacters: number;
	fullCharacters: number;
	truncated: boolean;
}

interface WebFetchPreviewDetails {
	maxCharacters: number;
	shownCharacters: number;
	fullCharacters: number;
	truncated: boolean;
	items: WebFetchPreviewItem[];
	perUrlMaxCharacters?: number;
	aggregateCap?: number;
	manifest?: boolean;
	explicitMaxCharacters?: boolean;
}

export interface BuildWebFetchToolResultOptions {
	maxCharacters?: number;
	explicit?: boolean;
	/** Original requested item count; used only to retain a stable aggregate output cap after partial failures. */
	batchSize?: number;
	pageImages?: Array<{ type: "image"; mimeType: string; data: string; pageNumber?: number }>;
}

export interface WebFetchDependencies {
	extractYouTubeUrl?: typeof extractYouTubeUrl;
	fetchHttpContent?: typeof fetchHttpContent;
	createExaClient?: (apiKey: string | undefined) => ExaClient;
}

function fallbackTitle(url: string | undefined, fallback = "content"): string {
	if (!url) return fallback;
	try {
		const parsed = new URL(url);
		const leaf = parsed.pathname.split("/").filter(Boolean).pop();
		return leaf || parsed.hostname || url;
	} catch {
		return url.split("/").filter(Boolean).pop() || url || fallback;
	}
}

function displayTitle(item: { title?: string; url?: string; id?: string }): string {
	return item.title?.trim() || fallbackTitle(item.url, item.id || "content");
}

function urls(params: WebFetchInput): string[] {
	const items = [...(params.urls ?? []), ...(params.filePaths ?? [])];
	if (params.url) items.unshift(params.url);
	if (params.filePath) items.unshift(params.filePath);
	return items.map((url) => url.trim()).filter(Boolean);
}

function cleanPath(path: string): string {
	return path.startsWith("@") ? path.slice(1) : path;
}

function isLocalFileInput(input: string): boolean {
	if (input.startsWith("file://")) return true;
	const cleaned = cleanPath(input);
	if (isAbsolute(cleaned)) return true;
	if (/^[a-z][a-z0-9+.-]*:\/\//i.test(cleaned)) return false;
	return isProbablyPdf(cleaned);
}

function resolveLocalFilePath(cwd: string, input: string): string {
	if (input.startsWith("file://")) return fileURLToPath(input);
	const cleaned = cleanPath(input);
	return isAbsolute(cleaned) ? cleaned : resolve(cwd, cleaned);
}

function fetchProviderForLabel(requested: unknown, actual?: unknown): string {
	const requestedValue = String(requested ?? "auto").trim().toLowerCase() || "auto";
	const actualValue = String(actual ?? requestedValue).trim().toLowerCase() || requestedValue;
	return actualValue;
}

function pendingFetchProviderForLabel(requested: unknown): string {
	return String(requested ?? "auto").trim().toLowerCase() === "auto" ? "resolving…" : fetchProviderForLabel(requested);
}

function storedProviderLabel(item: any): string {
	const provider = String(item?.metadata?.provider ?? "").trim().toLowerCase();
	const chain = Array.isArray(item?.metadata?.extractionChain) ? item.metadata.extractionChain.map((x: unknown) => String(x).toLowerCase()) : [];
	const usedJina = chain.includes("jina");
	if (provider === "http" && usedJina) return "http+jina";
	if (provider === "local") return "local";
	return provider || "http";
}

function storedProvider(stored: any[]): string {
	const labels = Array.from(new Set(stored.map(storedProviderLabel).filter(Boolean)));
	if (labels.length === 0) return "http";
	return labels.length === 1 ? labels[0]! : "mixed";
}

function previewLimit(params: WebFetchInput): { maxCharacters: number; explicit: boolean } {
	const raw = params.textMaxCharacters;
	const explicit = raw != null && Number.isFinite(raw);
	const max = explicit ? Math.max(0, Math.floor(raw as number)) : DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS;
	return { maxCharacters: max, explicit };
}

function formatBytesApprox(chars: number): string {
	if (chars < 1024) return `${chars} chars`;
	return `${(chars / 1024).toFixed(1)} KB`;
}

function urlExtension(url: string | undefined): string {
	if (!url) return "";
	try {
		const leaf = new URL(url).pathname.split("/").filter(Boolean).pop() ?? "";
		const dot = leaf.lastIndexOf(".");
		return dot > 0 ? leaf.slice(dot) : "";
	} catch {
		const leaf = url.split("/").filter(Boolean).pop() ?? "";
		const dot = leaf.lastIndexOf(".");
		return dot > 0 ? leaf.slice(dot) : "";
	}
}

function manifestRow(item: StoredWebContent): string {
	const target = item.url || displayTitle(item);
	const ext = urlExtension(item.url);
	const extPart = ext ? `, ${ext}` : "";
	return `- ${item.id}  ${target} (${formatBytesApprox(item.content.length)}${extPart})`;
}

// vstack#185: id-only fallback row when the full manifest cannot fit the
// aggregate cap. Caller can still resolve every content id via
// get_web_content; URL/extension/byte metadata is dropped to keep rows
// short and predictable in length.
function manifestIdOnlyRow(item: StoredWebContent): string {
	return `- ${item.id}`;
}

function failureMessage(error: unknown): string {
	const message = (error instanceof Error ? error.message : String(error)).replace(/\s+/g, " ").trim();
	return boundedText(message, WEB_FETCH_FAILURE_MESSAGE_MAX_CHARACTERS, "… [failure truncated]");
}

function isAbortError(error: unknown, signal: AbortSignal | undefined): boolean {
	return Boolean(signal?.aborted || (error && typeof error === "object" && "name" in error && (error as { name?: unknown }).name === "AbortError"));
}

function boundedText(text: string, maxCharacters: number | undefined, marker: string): string {
	if (maxCharacters === undefined || text.length <= maxCharacters) return text;
	if (maxCharacters <= marker.length) return marker.slice(0, Math.max(0, maxCharacters));
	return text.slice(0, Math.max(0, maxCharacters - marker.length)) + marker;
}

function failureRow(failure: { url: string; error: unknown; provider?: string }): string {
	const row = `- ${failure.url}${failure.provider ? ` [${failure.provider}]` : ""}: ${failureMessage(failure.error)}`;
	return boundedText(row, WEB_FETCH_FAILURE_ROW_MAX_CHARACTERS, "… [row truncated]");
}

function aggregateFailureMessage(failures: Array<{ url: string; error: unknown; provider?: string }>, maxCharacters?: number): string {
	const rows = failures.map(failureRow);
	const message = `Fetch failed for ${failures.length} URL(s):\n${rows.join("\n")}`;
	const cap = Math.min(maxCharacters ?? WEB_FETCH_FAILURE_BLOCK_MAX_CHARACTERS, WEB_FETCH_FAILURE_BLOCK_MAX_CHARACTERS);
	return boundedText(message, cap, "\n[error details truncated]");
}

function addPartialFailures(result: ReturnType<typeof buildWebFetchToolResult>, failures: Array<{ url: string; error: unknown; provider?: string }>) {
	const rows = failures.map(failureRow);
	const textItem = result.content.find((item) => item.type === "text");
	if (textItem?.type === "text") {
		const failureBlock = boundedText(`\n\nFailed ${failures.length} URL(s):\n${rows.join("\n")}`, WEB_FETCH_FAILURE_BLOCK_MAX_CHARACTERS, "\n\n[failure details truncated]");
		const aggregateCap = result.details.preview.aggregateCap;
		if (typeof aggregateCap === "number" && textItem.text.length + failureBlock.length > aggregateCap) {
			const compact = `\n\n[partial result: ${failures.length} URL(s) failed; full failure details are available in tool metadata]`;
			textItem.text = textItem.text.slice(0, Math.max(0, aggregateCap - compact.length)) + compact;
		} else {
			textItem.text += failureBlock;
		}
	}
	return {
		...result,
		details: {
			...result.details,
			partial: true,
			failures: failures.map((failure) => ({ url: failure.url, provider: failure.provider, error: failureMessage(failure.error) })),
		},
	};
}

function renderManifestHeader(count: number, totalFullChars: number): string {
	return `Fetched ${count} URLs (${formatBytesApprox(totalFullChars)} total, stored as ${count} content ids):`;
}

interface AggregatePolicy {
	perUrlMax: number;
	aggregateCap?: number;
	useManifest: boolean;
}

function aggregatePolicy(count: number, requested: number, explicit: boolean): AggregatePolicy {
	if (explicit || count <= 1) return { perUrlMax: requested, aggregateCap: undefined, useManifest: false };
	if (count < MULTI_URL_LARGE_BATCH_THRESHOLD) {
		return {
			perUrlMax: Math.min(requested, Math.max(0, Math.floor(MULTI_URL_AGGREGATE_CAP_SMALL_BATCH / count))),
			aggregateCap: MULTI_URL_AGGREGATE_CAP_SMALL_BATCH,
			useManifest: false,
		};
	}
	return {
		perUrlMax: Math.min(requested, MULTI_URL_LARGE_BATCH_PER_URL_HEAD),
		aggregateCap: MULTI_URL_AGGREGATE_CAP_LARGE_BATCH,
		useManifest: true,
	};
}

function normalizedUrlKey(input: string | undefined): string {
	if (!input) return "";
	try {
		const url = new URL(input);
		const hostname = url.hostname.toLowerCase().replace(/^www\./, "");
		const pathname = url.pathname === "/" ? "/" : url.pathname.replace(/\/+$/, "");
		return `${hostname}${url.port ? `:${url.port}` : ""}${pathname}${url.search}`;
	} catch {
		return input.replace(/\/$/, "");
	}
}

function exaStatusFailure(raw: unknown, url: string): string {
	const statuses = Array.isArray((raw as any)?.statuses) ? (raw as any).statuses : [];
	const key = normalizedUrlKey(url);
	const status = statuses.find((item: any) => normalizedUrlKey(item?.url) === key) ?? statuses.find((item: any) => normalizedUrlKey(item?.id) === key);
	if (!status) return "Exa returned no content for this URL.";
	const statusName = typeof status.status === "string" ? status.status.trim().toLowerCase() : "";
	if (["success", "completed", "complete", "ok"].includes(statusName) && !status.error) return "Exa reported success without text or summary.";
	for (const value of [status.error, status.message, status.status]) {
		if (typeof value === "string" && value.trim()) return value.trim();
		if (value && typeof value === "object") {
			try { return JSON.stringify(value); } catch { /* use generic fallback */ }
		}
	}
	return "Exa returned no content for this URL.";
}

function previewStats(content: string, maxCharacters: number): WebFetchPreviewItem {
	const fullCharacters = content.length;
	return {
		id: "",
		shownCharacters: Math.min(fullCharacters, Math.max(0, maxCharacters)),
		fullCharacters,
		truncated: fullCharacters > maxCharacters,
	};
}

export function buildWebFetchToolResult(
	stored: StoredWebContent[],
	provider: string,
	optionsOrMaxCharacters: BuildWebFetchToolResultOptions | number = {},
	legacyPageImages: Array<{ type: "image"; mimeType: string; data: string; pageNumber?: number }> = []
) {
	const options: BuildWebFetchToolResultOptions = typeof optionsOrMaxCharacters === "number"
		? { maxCharacters: optionsOrMaxCharacters, pageImages: legacyPageImages }
		: optionsOrMaxCharacters;
	const requestedMax = options.maxCharacters ?? DEFAULT_WEB_FETCH_PREVIEW_CHARACTERS;
	const explicit = options.explicit ?? false;
	const pageImages = options.pageImages ?? legacyPageImages ?? [];

	const presentationPolicy = aggregatePolicy(stored.length, requestedMax, explicit);
	const aggregateCap = aggregatePolicy(options.batchSize ?? stored.length, requestedMax, explicit).aggregateCap;
	const policy = { ...presentationPolicy, aggregateCap };

	const previewItems = stored.map((item) => {
		const stats = previewStats(item.content, policy.perUrlMax);
		const { text } = truncateText(item.content, policy.perUrlMax);
		return { item, text, stats: { ...stats, id: item.id } };
	});
	const preview: WebFetchPreviewDetails = {
		maxCharacters: policy.perUrlMax,
		shownCharacters: previewItems.reduce((sum, item) => sum + item.stats.shownCharacters, 0),
		fullCharacters: previewItems.reduce((sum, item) => sum + item.stats.fullCharacters, 0),
		truncated: previewItems.some((item) => item.stats.truncated),
		items: previewItems.map((item) => item.stats),
		perUrlMaxCharacters: policy.perUrlMax,
		aggregateCap: policy.aggregateCap,
		manifest: policy.useManifest,
		explicitMaxCharacters: explicit,
	};
	const ids = stored.map((item) => item.id).join(", ");
	const previewBlocks = previewItems.map(({ item, text, stats }) => {
		const label = displayTitle(item);
		const meta = `preview ${stats.shownCharacters}/${stats.fullCharacters} chars${stats.truncated ? "; full text stored" : ""}`;
		return `- ${item.id}: ${label}\n[${meta}]\n${text}`;
	}).join("\n\n");
	const previewMeta = preview.truncated ? ` (${preview.shownCharacters}/${preview.fullCharacters} chars shown)` : "";
	const totalFull = stored.reduce((sum, item) => sum + item.content.length, 0);

	let head: string;
	let body: string;
	let tail: string;
	if (policy.useManifest) {
		const manifestRows = stored.map(manifestRow).join("\n");
		head = `${renderManifestHeader(stored.length, totalFull)}\n${manifestRows}`;
		const capNote = `Per-URL preview heads capped at ${policy.perUrlMax} chars to fit the multi-URL aggregate cap. Pass textMaxCharacters to opt back into larger inlined previews.`;
		body = previewBlocks ? `\n\n${capNote}\n\n${previewBlocks}` : `\n\n${capNote}`;
		tail = `\n\nCall get_web_content <id> [offset] [maxCharacters] to load full stored text per id.`;
	} else {
		head = `Fetched ${stored.length} URL(s). Preview returned${previewMeta}. Full extracted text is stored under content id(s): ${ids || "none"}.`;
		body = previewBlocks ? `\n\n${previewBlocks}` : "";
		tail = `\n\nUse get_web_content with the content id for stored full text.`;
	}

	let combined: string;
	if (policy.aggregateCap !== undefined) {
		const truncationMarker = `\n\n[multi-URL preview truncated to fit aggregate cap; use get_web_content with content ids for full stored text]`;
		const bodyBudget = Math.max(0, policy.aggregateCap - head.length - tail.length - truncationMarker.length);
		if (body.length > bodyBudget) {
			body = body.slice(0, bodyBudget) + truncationMarker;
		}
		combined = head + body + tail;
		if (combined.length > policy.aggregateCap) {
			// vstack#185: head + body + tail still exceeds the cap, usually
			// because the manifest itself (head) has too many or too-long
			// rows. Rebuild head with id-only rows so every content id stays
			// resolvable through get_web_content, drop the preview body
			// entirely, and replace it with a recovery note pointing at
			// get_web_content. Pre-fix the original slice would silently
			// drop manifest rows mid-text and leave the caller no way to
			// recover the missing ids.
			const idOnlyRows = stored.map(manifestIdOnlyRow).join("\n");
			const idOnlyHead = `${renderManifestHeader(stored.length, totalFull)}\n${idOnlyRows}`;
			const idOnlyNote = `\n\n[manifest rendered as id-only rows to fit aggregate cap; ${stored.length} ids preserved. Use get_web_content with any id for full stored text.]`;
			combined = idOnlyHead + idOnlyNote + tail;
			if (combined.length > policy.aggregateCap) {
				// Even id-only rows do not fit. Surface the count so caller
				// knows to split the batch; do not silently drop ids.
				const overflowNote = `\n\n[ERROR: ${stored.length} content ids do not fit in the ${policy.aggregateCap}-byte aggregate cap even as id-only rows. Reduce batch size or call get_web_content for ids reported elsewhere.]`;
				const idsCompact = stored.map((item) => item.id).join(" ");
				combined = `${renderManifestHeader(stored.length, totalFull)}\n${idsCompact}${overflowNote}`;
			}
		}
	} else {
		combined = head + body + tail;
	}

	const imagesNote = pageImages.length ? `\n\n[${pageImages.length} scanned PDF page image${pageImages.length === 1 ? "" : "s"} attached for vision OCR]` : "";
	const finalText = combined + imagesNote;
	const content: Array<{ type: "text"; text: string } | { type: "image"; mimeType: string; data: string }> = [
		{ type: "text", text: finalText },
	];
	for (const image of pageImages) content.push({ type: "image", mimeType: image.mimeType, data: image.data });
	return {
		content,
		details: { provider, stored, preview, pageImageCount: pageImages.length },
	};
}

export function createWebFetchToolDefinition(pi: ExtensionAPI, getSettings: (cwd?: string) => WebToolsSettings, name = "web_fetch", dependencies: WebFetchDependencies = {}) {
	const youtubeExtractor = dependencies.extractYouTubeUrl ?? extractYouTubeUrl;
	const httpExtractor = dependencies.fetchHttpContent ?? fetchHttpContent;
	const createExaClient = dependencies.createExaClient ?? ((apiKey: string | undefined) => new ExaClient({ apiKey }));
	return {
		renderShell: "self" as const,
		name,
		label: name === "web_fetch" ? "Web Fetch" : "Fetch Content",
		description: "Fetch known URL or local PDF content and store full extracted text for get_web_content. Auto handles GitHub, PDF, HTML/text/JSON, with Exa contents fallback/override for URLs. Direct/GitHub/PDF fetches store full extracted text; the tool result is only a preview.",
		promptSnippet: "Fetch and store known URL or local PDF content; use the returned content id with get_web_content for full stored text.",
		parameters: webFetchSchema,
		renderCall(args: WebFetchInput, theme: any, context: any) {
			if (context?.executionStarted && !context?.isPartial) return emptyComponent();
			const list = urls(args);
			return textComponent(webCallText(theme, providerLabel(name === "web_fetch" ? "Web Fetch" : name, pendingFetchProviderForLabel(args?.provider)), list[0] ?? "url", list.length > 1 ? `+${list.length - 1} urls` : undefined));
		},
		renderResult(result: any, options: any, theme: any, context: any) {
			if (options?.isPartial) return emptyComponent();
			if (context?.isError) return textComponent(errorSummary(theme, providerLabel(name === "web_fetch" ? "Web Fetch" : name, fetchProviderForLabel(context?.args?.provider)), firstText(result) || "failed"));
			const stored = Array.isArray(result?.details?.stored) ? result.details.stored : [];
			const failures = Array.isArray(result?.details?.failures) ? result.details.failures : [];
			const provider = fetchProviderForLabel(context?.args?.provider, result?.details?.provider);
			const preview = result?.details?.preview;
			const meta = [`${stored.length} stored`, failures.length ? `${failures.length} failed` : undefined, preview?.truncated ? `preview ${preview.shownCharacters}/${preview.fullCharacters} chars` : undefined].filter(Boolean).join(" · ");
			const target = context?.args?.url || context?.args?.urls?.[0] || context?.args?.filePath || context?.args?.filePaths?.[0] || "content";
			const lines = [successSummary(theme, providerLabel(name === "web_fetch" ? "Web Fetch" : name, provider), target, meta)];
			for (let index = 0; index < stored.slice(0, 3).length; index++) {
				const item = stored[index]!;
				const itemPreview = Array.isArray(preview?.items) ? preview.items.find((candidate: any) => candidate?.id === item.id) : undefined;
				const suppressLeafPreview = stored.length === 1 && preview?.truncated;
				const previewMeta = !suppressLeafPreview && itemPreview?.truncated ? `preview ${itemPreview.shownCharacters}/${itemPreview.fullCharacters} chars` : "";
				const cachePath = typeof item?.metadata?.cachePath === "string" ? item.metadata.cachePath : undefined;
				const itemMeta = [item.url, previewMeta || undefined].filter(Boolean).join(" · ");
				const hasCache = Boolean(cachePath);
				const connector = index === stored.length - 1 && !hasCache ? "└" : "├";
				lines.push(`${tree(theme, connector)}${accent(theme, displayTitle(item))}${itemMeta ? muted(theme, ` · ${itemMeta}`) : ""}`);
				if (cachePath) lines.push(`${tree(theme, index === stored.length - 1 ? "└" : "├")}${muted(theme, "cached at ")}${accent(theme, cachePath)}`);
			}
			if (stored.length > 3) lines.push(`${tree(theme, "└")}${muted(theme, `… ${stored.length - 3} more`)}`);
			return textComponent(lines.join("\n"));
		},
		async execute(_toolCallId: string, params: WebFetchInput, signal: AbortSignal | undefined, _onUpdate: unknown, ctx: ExtensionContext) {
			const settings = getSettings(ctx.cwd);
			const list = urls(params);
			if (list.length === 0) throw new Error(`${name} requires url/urls or filePath/filePaths.`);
			const requestedPreview = previewLimit(params);
			const failureAggregateCap = aggregatePolicy(list.length, requestedPreview.maxCharacters, requestedPreview.explicit).aggregateCap;
			const thrownErrorMessageCap = failureAggregateCap === undefined ? undefined : Math.max(0, failureAggregateCap - "Error: ".length);
			const transcriptUrls = list.filter((url) => parseYouTubeUrl(url) && (params.videoMode === "transcript" || (params.videoMode !== "understand" && isTranscriptPrompt(params.prompt))));
			const transcriptUrlSet = new Set(transcriptUrls);
			const transcriptConflict = transcriptUrls.length && params.provider === "exa"
				? "YouTube transcript extraction is incompatible with provider=exa. Use provider=auto or provider=http."
				: transcriptUrls.length && !settings.video.enabled
					? "YouTube transcript extraction is disabled by the video.enabled setting."
					: undefined;
			if (transcriptConflict && transcriptUrls.length === list.length) throw new Error(transcriptConflict);
			const transcriptConflictUrls = new Set(transcriptConflict ? transcriptUrls : []);
			const transcriptConflictFailures = transcriptConflict
				? transcriptUrls.map((url) => ({ url, provider: "youtube", error: transcriptConflict }))
				: [];
			if (params.provider === "exa" && list.some(isLocalFileInput)) throw new Error("provider=exa can only fetch remote URLs. Use provider=auto or provider=http for local PDF paths.");
			async function fetchWithExa(failedUrls: string[]) {
				const client = createExaClient(settings.apiKeys.exa);
				// vstack#185: Exa /contents stores excerpts (default 6k chars).
				// Tag each stored item with the provider cap so `get_web_content`
				// and operator-facing docs can distinguish Exa excerpts from
				// direct/GitHub/PDF/HTTP full-text fetches.
				const providerTextMaxCharacters = params.textMaxCharacters ?? 6000;
				const response = await client.contents({ urls: failedUrls, textMaxCharacters: providerTextMaxCharacters }, signal);
				const stored: StoredWebContent[] = [];
				const requested = failedUrls.map((url, index) => ({ url, index, key: normalizedUrlKey(url) }));
				const satisfiedRequestIndices = new Set<number>();
				const assignments = new Map<number, number>();
				const contentResults: Array<{ index: number; result: (typeof response.results)[number]; content: string; keys: string[] }> = [];
				const resultKeys = (result: (typeof response.results)[number]) => Array.from(new Set([normalizedUrlKey(result.url), normalizedUrlKey(result.id)].filter(Boolean)));
				for (let index = 0; index < response.results.length; index++) {
					const result = response.results[index]!;
					const content = result.text?.trim() ? result.text : result.summary?.trim() ? result.summary : "";
					if (!content) continue;
					contentResults.push({ index, result, content, keys: resultKeys(result) });
				}
				for (const entry of contentResults) {
					const matches = requested.filter((item) => !satisfiedRequestIndices.has(item.index) && entry.keys.includes(item.key));
					if (!matches.length) continue;
					assignments.set(entry.index, matches[0]!.index);
					for (const match of matches) satisfiedRequestIndices.add(match.index);
				}
				const identityPositionsPreserved = response.results.every((result, index) => {
					const keys = resultKeys(result);
					return keys.length === 0 || (index < requested.length && keys.includes(requested[index]!.key));
				});
				if (response.results.length === failedUrls.length && identityPositionsPreserved) {
					for (const entry of contentResults) {
						if (assignments.has(entry.index) || entry.keys.length !== 0 || satisfiedRequestIndices.has(entry.index)) continue;
						assignments.set(entry.index, entry.index);
						satisfiedRequestIndices.add(entry.index);
					}
				}
				const remainingAnonymous = contentResults.filter((entry) => entry.keys.length === 0 && !assignments.has(entry.index));
				const remainingRequests = requested.filter((item) => !satisfiedRequestIndices.has(item.index));
				if (remainingAnonymous.length === 1 && remainingRequests.length === 1) {
					assignments.set(remainingAnonymous[0]!.index, remainingRequests[0]!.index);
					satisfiedRequestIndices.add(remainingRequests[0]!.index);
				}
				for (const entry of contentResults) {
					const requestIndex = assignments.get(entry.index);
					if (requestIndex === undefined) continue;
					const requestedUrl = failedUrls[requestIndex]!;
					const returnedUrl = entry.result.url?.trim();
					const returnedId = entry.result.id?.trim();
					stored.push(storeWebContent(pi, {
						title: entry.result.title?.trim() || fallbackTitle(requestedUrl),
						url: requestedUrl,
						content: entry.content,
						metadata: {
							provider: "exa",
							tool: name,
							contentKind: "excerpt",
							providerTextMaxCharacters,
							...(returnedUrl && returnedUrl !== requestedUrl ? { exaResultUrl: returnedUrl } : {}),
							...(returnedId ? { exaResultId: returnedId } : {}),
						},
					}));
				}
				const failures = requested
					.filter((item) => !satisfiedRequestIndices.has(item.index))
					.map((item) => ({ url: item.url, provider: "exa", error: exaStatusFailure(response.raw, item.url) }));
				return { stored, failures };
			}
			if (params.provider !== "exa") {
				const stored = [];
				const pageImages: PdfPageImage[] = [];
				const failed: Array<{ url: string; error: unknown; provider?: string; allowExaFallback: boolean }> = transcriptConflictFailures.map((failure) => ({ ...failure, allowExaFallback: false }));
				async function handlePdfBuffer(buffer: Buffer | ArrayBuffer | Uint8Array, source: { provider: "http" | "local"; url: string; title: string; localPath?: string }) {
					const bufferLike = Buffer.isBuffer(buffer) ? buffer : Buffer.from(buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer));
					let text = "";
					let textMeta: Record<string, unknown> = {};
					try {
						const result = await extractPdfTextBest(bufferLike);
						text = result.text;
						textMeta = result.metadata;
					} catch (error) {
						textMeta = { extraction: "pdf-empty", textError: error instanceof Error ? error.message : String(error) };
					}
					let rasterized: { pageCount: number; truncated: boolean } | undefined;
					if (settings.pdfOcr.enabled && looksLikeScannedPdf(text, bufferLike.byteLength)) {
						try {
							const result = await rasterizePdfPages(bufferLike, { maxPages: settings.pdfOcr.maxPages, dpi: settings.pdfOcr.dpi });
							rasterized = { pageCount: result.pageCount, truncated: result.truncated };
							for (const image of result.images) pageImages.push(image);
						} catch (error) {
							textMeta = { ...textMeta, ocrError: error instanceof Error ? error.message : String(error) };
						}
					}
					const content = text || (rasterized ? `[Scanned PDF: ${rasterized.pageCount} pages, ${pageImages.length} attached as images${rasterized.truncated ? ` (truncated to ${settings.pdfOcr.maxPages})` : ""}]` : "[Empty PDF: no extractable text]");
					const metadata = { provider: source.provider, tool: name, ...textMeta, ...(source.localPath ? { localPath: source.localPath } : {}), ...(rasterized ? { pdfPageCount: rasterized.pageCount, pdfPagesRasterized: pageImages.length, pdfPagesTruncated: rasterized.truncated } : {}) };
					stored.push(storeWebContent(pi, { title: source.title, url: source.url, content, metadata }));
				}
				for (const url of list) {
					if (transcriptConflictUrls.has(url)) continue;
					let youtubeExtractionAttempted = false;
					try {
						if (isLocalFileInput(url)) {
							const localPath = resolveLocalFilePath(ctx.cwd, url);
							if (settings.video.enabled && isLocalVideoPath(localPath)) {
								const video = await extractLocalVideo(localPath, { prompt: params.prompt, geminiApiKey: settings.apiKeys.gemini, signal });
								stored.push(storeWebContent(pi, { title: video.title, url: pathToFileURL(localPath).href, content: video.content, metadata: { tool: name, localPath, ...video.metadata } }));
								continue;
							}
							if (!isProbablyPdf(localPath)) throw new Error(`Local file extraction currently supports PDFs and videos only: ${localPath}`);
							const buffer = await fsReadFile(localPath);
							await handlePdfBuffer(buffer, { provider: "local", url: pathToFileURL(localPath).href, title: basename(localPath), localPath });
							continue;
						}
						const github = await extractGitHubUrl(url, { signal, cloneEnabled: settings.githubClone.enabled, maxRepoSizeMB: settings.githubClone.maxRepoSizeMB, cloneTimeoutSeconds: settings.githubClone.cloneTimeoutSeconds, maxAgeHours: settings.githubClone.cacheMaxAgeHours }).catch((error) => ({ error }));
						if (github && !("error" in github)) {
							stored.push(storeWebContent(pi, { title: github.title, url, content: github.content, metadata: github.metadata }));
							continue;
						}
						const youtube = settings.video.enabled ? parseYouTubeUrl(url) : undefined;
						if (youtube) {
							youtubeExtractionAttempted = true;
							const yt = await youtubeExtractor(url, { prompt: params.prompt, mode: params.videoMode, transcriptLanguage: params.transcriptLanguage, geminiApiKey: settings.apiKeys.gemini, browserCookies: { preferredBrowser: settings.browserCookies.preferredBrowser, profile: settings.browserCookies.profile }, signal, timeoutMs: DEFAULT_YOUTUBE_EXTRACTION_TIMEOUT_MS });
							if (yt) {
								stored.push(storeWebContent(pi, { title: yt.title, url: yt.url, content: yt.content, metadata: { tool: name, ...yt.metadata } }));
								continue;
							}
						}
						if (isProbablyPdf(url)) {
							const response = await fetch(url, { signal });
							if (!response.ok) throw new Error(`PDF fetch failed (${response.status}) for ${url}`);
							const buffer = await response.arrayBuffer();
							await handlePdfBuffer(buffer, { provider: "http", url, title: url.split("/").pop() || url });
							continue;
						}
						const extracted = await httpExtractor(url, { signal, jinaFallback: settings.htmlExtraction.jinaFallback, jinaApiKey: settings.apiKeys.jina });
						stored.push(storeWebContent(pi, { title: extracted.title, url: extracted.url, content: extracted.content, metadata: { provider: "http", tool: name, ...extracted.metadata } }));
					} catch (error) {
						if (isAbortError(error, signal)) throw error;
						failed.push({ url, error, provider: youtubeExtractionAttempted ? "youtube" : "direct", allowExaFallback: !transcriptUrlSet.has(url) });
					}
				}
				if (failed.length) {
					const terminalFailures = failed.filter((item) => isLocalFileInput(item.url) || !item.allowExaFallback || params.provider === "http" || !settings.apiKeys.exa);
					const exaFallbackFailures = failed.filter((item) => !terminalFailures.includes(item));
					if (exaFallbackFailures.length) {
						try {
							const exaResult = await fetchWithExa(exaFallbackFailures.map((item) => item.url));
							stored.push(...exaResult.stored);
							terminalFailures.push(...exaResult.failures.map((item) => ({ ...item, allowExaFallback: false })));
						} catch (error) {
							if (isAbortError(error, signal)) throw error;
							terminalFailures.push(...exaFallbackFailures.map((item) => ({ ...item, provider: "exa", error })));
						}
					}
					if (terminalFailures.length) {
						if (stored.length === 0) {
							throw new Error(aggregateFailureMessage(terminalFailures, thrownErrorMessageCap));
						}
						const actualProvider = storedProvider(stored);
						const { maxCharacters, explicit } = previewLimit(params);
						return addPartialFailures(buildWebFetchToolResult(stored, actualProvider, { maxCharacters, explicit, batchSize: list.length, pageImages }), terminalFailures);
					}
				}
				const actualProvider = storedProvider(stored);
				const { maxCharacters, explicit } = previewLimit(params);
				return buildWebFetchToolResult(stored, actualProvider, { maxCharacters, explicit, batchSize: list.length, pageImages });
			}
			const exaResult = await fetchWithExa(list.filter((url) => !transcriptConflictUrls.has(url)));
			const failures = [...transcriptConflictFailures, ...exaResult.failures];
			const { maxCharacters, explicit } = previewLimit(params);
			if (exaResult.stored.length === 0 && failures.length) throw new Error(aggregateFailureMessage(failures, thrownErrorMessageCap));
			const result = buildWebFetchToolResult(exaResult.stored, "exa", { maxCharacters, explicit, batchSize: list.length });
			return failures.length ? addPartialFailures(result, failures) : result;
		},
	};
}
