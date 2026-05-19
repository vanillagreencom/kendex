import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { loadSettings } from "./settings.js";
import { saveBase64Image } from "./utils/images.js";
import { Box, Container, getCapabilities, getImageDimensions, Image, Spacer, Text } from "@earendil-works/pi-tui";
import {
	createAssistantMessageEventStream,
	appendAssistantMessageDiagnostic,
	clampThinkingLevel,
	createAssistantMessageDiagnostic,
	getEnvApiKey,
	type Api,
	type AssistantMessage,
	type AssistantMessageEventStream,
	type Context,
	type Model,
	type SimpleStreamOptions,
} from "@earendil-works/pi-ai";
import type { ResponseCreateParamsStreaming } from "openai/resources/responses/responses.js";
import {
	convertResponsesMessages,
	convertResponsesTools,
	processResponsesStream,
} from "./providers/openai-responses-shared.js";

const DEFAULT_CODEX_BASE_URL = "https://chatgpt.com/backend-api";
const JWT_CLAIM_PATH = "https://api.openai.com/auth";
export const IMAGE_SAVE_DISPLAY_MESSAGE_TYPE = "codex-image-generation-display";
export const WEB_SEARCH_ACTIVITY_MESSAGE_TYPE = "codex-web-search-activity";
const OPENAI_CODEX_IMAGE_DIR = ".pi/openai-codex-images";
const OPENAI_CODEX_LATEST_IMAGE_NAME = "latest.png";
const MAX_RETRIES = 3;
const BASE_DELAY_MS = 1000;
const CODEX_TOOL_CALL_PROVIDERS = new Set(["openai", "openai-codex", "opencode"]);
const CODEX_RESPONSE_STATUSES = new Set(["completed", "incomplete", "failed", "cancelled", "queued", "in_progress"]);
const OPENAI_BETA_RESPONSES_WEBSOCKETS = "responses_websockets=2026-02-06";
const SESSION_WEBSOCKET_CACHE_TTL_MS = 5 * 60 * 1000;
const dynamicImport = (specifier: string) => import(specifier);
let _os: { platform(): string; release(): string; arch(): string } | null = null;

if (typeof process !== "undefined" && (process.versions?.node || process.versions?.bun)) {
	dynamicImport("node:os")
		.then((module) => {
			_os = module;
		})
		.catch(() => {
			_os = null;
		});
}

interface SavedGeneratedImage {
	absolutePath: string;
	relativePath: string;
	latestAbsolutePath: string;
	latestRelativePath: string;
	responseId: string | undefined;
	callId: string;
	outputFormat: string;
	imageModel?: string;
	revisedPrompt?: string;
}

interface ImageDisplayMessageDetails {
	savedImages: SavedGeneratedImage[];
}

interface PendingImageDisplay {
	savedImage: SavedGeneratedImage;
	imageData: { data: string; mimeType: string };
}

interface QueuedImageActivity extends PendingImageDisplay {
	kind: "image";
}

interface SurfacedWebSearch {
	callId: string;
	status?: string;
	query?: string;
	queries: string[];
	sources: Array<{ title?: string; url: string }>;
}

interface QueuedWebSearchActivity {
	kind: "web-search";
	search: SurfacedWebSearch;
}

type PendingActivity = QueuedImageActivity | QueuedWebSearchActivity;

interface CachedImagePreview {
	data: string;
	mimeType: string;
	bytes: number;
	widthPx?: number;
	heightPx?: number;
}

interface WebSocketLike {
	readyState?: number;
	send(data: string): void;
	close(code?: number, reason?: string): void;
	addEventListener(type: string, listener: (event: unknown) => void): void;
	removeEventListener(type: string, listener: (event: unknown) => void): void;
}

interface WebSocketConstructorLike {
	new (url: string, options?: { headers?: Record<string, string>; dispatcher?: unknown } | string | string[]): WebSocketLike;
}

interface SessionWebSocketCacheEntry {
	socket: WebSocketLike;
	busy: boolean;
	idleTimer?: ReturnType<typeof setTimeout>;
	continuation?: CachedWebSocketContinuationState;
}

interface AcquiredWebSocket {
	socket: WebSocketLike;
	entry?: SessionWebSocketCacheEntry;
	reused: boolean;
	release: (options?: { keep?: boolean }) => void;
}

interface CachedWebSocketContinuationState {
	lastRequestBody: ResponsesBody;
	lastResponseId: string;
	lastResponseItems: unknown[];
}

let fsPromisesPromise: Promise<typeof import("node:fs/promises")> | undefined;
const workspaceRootCache = new Map<string, Promise<string>>();

const PATH_SEPARATOR = "/";

interface ResponsesBody {
	model: string;
	store: boolean;
	stream: boolean;
	instructions?: string;
	previous_response_id?: string;
	input: unknown[];
	text: { verbosity: string };
	include: string[];
	prompt_cache_key?: string;
	tool_choice: "auto";
	parallel_tool_calls: boolean;
	temperature?: number;
	service_tier?: string;
	tools?: unknown[];
	reasoning?: {
		effort: string;
		summary: string;
	};
	[key: string]: unknown;
}

interface ResponseEnvelope {
	id?: string;
	status?: string;
	usage?: {
		input_tokens?: number;
		output_tokens?: number;
		total_tokens?: number;
		input_tokens_details?: { cached_tokens?: number };
	};
	service_tier?: string;
	error?: { message?: string };
	[key: string]: unknown;
}

type ServiceTier = ResponseCreateParamsStreaming["service_tier"];

const websocketSessionCache = new Map<string, SessionWebSocketCacheEntry>();

class NonRetryableProviderError extends Error {}

const HTTP_STATUS_MESSAGE_PREFIX = /^HTTP\s+\d{3}(?::|\b)/i;

interface StreamEventShape {
	type?: string;
	response?: ResponseEnvelope;
	item?: {
		id?: string;
		type?: string;
		result?: string | null;
		output_format?: string;
		revised_prompt?: string;
		status?: string;
		[key: string]: unknown;
	};
	code?: string;
	message?: string;
	[key: string]: unknown;
}

function sanitizeFilePart(value: string | undefined, fallback: string): string {
	const trimmed = (value ?? "").trim();
	if (!trimmed) return fallback;
	return trimmed.replace(/[^a-zA-Z0-9._-]+/g, "-");
}

function shortenFilePart(value: string | undefined, fallback: string): string {
	const safe = sanitizeFilePart(value, fallback);
	const match = /^([a-zA-Z]+_)(.+)$/.exec(safe);
	const prefix = match?.[1] ?? "";
	const body = match?.[2] ?? safe;
	if (body.length <= 12) return `${prefix}${body}`;
	return `${prefix}${body.slice(0, 8)}-${body.slice(-4)}`;
}

function normalizeImageOutputFormat(value: string | undefined): string {
	const format = (value ?? "png").toLowerCase();
	return format === "png" || format === "jpg" || format === "jpeg" || format === "webp" ? format : "png";
}

function shortHash(str: string): string {
	let h1 = 0xdeadbeef;
	let h2 = 0x41c6ce57;
	for (let i = 0; i < str.length; i++) {
		const ch = str.charCodeAt(i);
		h1 = Math.imul(h1 ^ ch, 2654435761);
		h2 = Math.imul(h2 ^ ch, 1597334677);
	}
	h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
	h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
	return (h2 >>> 0).toString(36) + (h1 >>> 0).toString(36);
}

function normalizePath(value: string): string {
	if (!value) return ".";
	const normalized = value.replace(/\/+/g, PATH_SEPARATOR);
	if (normalized === PATH_SEPARATOR) return normalized;
	return normalized.replace(/\/+$/g, "") || PATH_SEPARATOR;
}

function joinPaths(...parts: string[]): string {
	if (parts.length === 0) return ".";
	let result = parts[0] ?? "";
	for (let i = 1; i < parts.length; i++) {
		const part = parts[i];
		if (!part) continue;
		if (!result || result.endsWith(PATH_SEPARATOR)) {
			result += part.replace(/^\/+/, "");
		} else {
			result += `${PATH_SEPARATOR}${part.replace(/^\/+/, "")}`;
		}
	}
	return normalizePath(result);
}

function dirnamePath(value: string): string {
	const normalized = normalizePath(value);
	if (normalized === PATH_SEPARATOR) return PATH_SEPARATOR;
	const index = normalized.lastIndexOf(PATH_SEPARATOR);
	if (index < 0) return ".";
	if (index === 0) return PATH_SEPARATOR;
	return normalized.slice(0, index);
}

function splitPathSegments(value: string): string[] {
	const normalized = normalizePath(value);
	if (normalized === PATH_SEPARATOR) return [];
	return normalized.replace(/^\/+/, "").split(PATH_SEPARATOR).filter(Boolean);
}

function relativePath(from: string, to: string): string {
	const normalizedFrom = normalizePath(from);
	const normalizedTo = normalizePath(to);
	if (normalizedFrom === normalizedTo) return "";
	const fromSegments = splitPathSegments(normalizedFrom);
	const toSegments = splitPathSegments(normalizedTo);
	let shared = 0;
	while (shared < fromSegments.length && shared < toSegments.length && fromSegments[shared] === toSegments[shared]) {
		shared++;
	}
	const upSegments = new Array(fromSegments.length - shared).fill("..");
	const downSegments = toSegments.slice(shared);
	return [...upSegments, ...downSegments].join(PATH_SEPARATOR);
}

async function getNodeFsPromises(): Promise<typeof import("node:fs/promises")> {
	if (!fsPromisesPromise) {
		fsPromisesPromise = dynamicImport("node:fs/promises") as Promise<typeof import("node:fs/promises")>;
	}
	return fsPromisesPromise;
}

function getNodeFsSync(): { readFileSync(path: string): Buffer } | null {
	if (typeof process === "undefined" || !(process.versions?.node || process.versions?.bun)) {
		return null;
	}
	const builtinProcess = process as typeof process & { getBuiltinModule?: (specifier: string) => unknown };
	if (typeof builtinProcess.getBuiltinModule !== "function") {
		return null;
	}
	try {
		const module = builtinProcess.getBuiltinModule("node:fs") as { readFileSync?: (path: string) => Buffer } | undefined;
		return typeof module?.readFileSync === "function" ? { readFileSync: module.readFileSync } : null;
	} catch {
		return null;
	}
}

async function pathExists(value: string): Promise<boolean> {
	try {
		const fs = await getNodeFsPromises();
		await fs.access(value);
		return true;
	} catch {
		return false;
	}
}

async function resolveWorkspaceRoot(cwd: string): Promise<string> {
	const normalizedCwd = normalizePath(cwd);
	const cached = workspaceRootCache.get(normalizedCwd);
	if (cached) return cached;

	const promise = (async () => {
		let current = normalizedCwd;
		while (true) {
			if (await pathExists(joinPaths(current, ".git"))) {
				return current;
			}
			const parent = dirnamePath(current);
			if (parent === current || parent === ".") {
				return normalizedCwd;
			}
			current = parent;
		}
	})();

	workspaceRootCache.set(normalizedCwd, promise);
	return promise;
}

export function getOpenAICodexImageDirectory(cwd: string): string {
	return joinPaths(cwd, OPENAI_CODEX_IMAGE_DIR);
}

export function getOpenAICodexImagePath(cwd: string, responseId: string | undefined, callId: string, outputFormat?: string): string {
	const ext = normalizeImageOutputFormat(outputFormat);
	const safeCallId = shortenFilePart(callId, "image");
	const safeResponseId = shortenFilePart(responseId, "response");
	return joinPaths(getOpenAICodexImageDirectory(cwd), `${safeCallId}-${safeResponseId}.${ext}`);
}

export function getOpenAICodexLatestImagePath(cwd: string): string {
	return joinPaths(getOpenAICodexImageDirectory(cwd), OPENAI_CODEX_LATEST_IMAGE_NAME);
}

export function buildGeneratedImageDisplayText(savedImage: SavedGeneratedImage, options?: { expanded?: boolean }): string {
	const lines: string[] = [];
	if (options?.expanded && savedImage.revisedPrompt) {
		lines.push(`Prompt: ${savedImage.revisedPrompt}`);
	}
	lines.push(`File: ${savedImage.relativePath}`);
	return lines.join("\n");
}

export async function saveOpenAICodexGeneratedImage(
	cwd: string,
	image: { responseId?: string; callId: string; result: string; outputFormat?: string; imageModel?: string; revisedPrompt?: string },
): Promise<SavedGeneratedImage> {
	const workspaceRoot = await resolveWorkspaceRoot(cwd);
	const outputFormat = normalizeImageOutputFormat(image.outputFormat);
	const saved = await saveBase64Image({
		base64: image.result,
		callId: image.callId,
		cwd,
		format: outputFormat,
		responseId: image.responseId,
		settings: loadSettings(cwd),
	});
	const absolutePath = saved.path;
	const latestAbsolutePath = saved.latestPath ?? getOpenAICodexLatestImagePath(workspaceRoot);

	const relativeFilePath = relativePath(workspaceRoot, absolutePath);
	const latestRelativeFilePath = relativePath(workspaceRoot, latestAbsolutePath);
	const relativePathValue = relativeFilePath && !relativeFilePath.startsWith("..") ? relativeFilePath : absolutePath;
	const latestRelativePathValue =
		latestRelativeFilePath && !latestRelativeFilePath.startsWith("..") ? latestRelativeFilePath : latestAbsolutePath;

	return {
		absolutePath,
		relativePath: relativePathValue,
		latestAbsolutePath,
		latestRelativePath: latestRelativePathValue,
		responseId: image.responseId,
		callId: image.callId,
		outputFormat,
		imageModel: image.imageModel,
		revisedPrompt: image.revisedPrompt,
	};
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
		throw new Error("Failed to extract accountId from token");
	}
}

function resolveCodexUrl(baseUrl: string | undefined): string {
	const raw = baseUrl && baseUrl.trim().length > 0 ? baseUrl : DEFAULT_CODEX_BASE_URL;
	const normalized = raw.replace(/\/+$/, "");
	if (normalized.endsWith("/codex/responses")) return normalized;
	if (normalized.endsWith("/codex")) return `${normalized}/responses`;
	return `${normalized}/codex/responses`;
}

function resolveCodexWebSocketUrl(baseUrl: string | undefined): string {
	const url = new URL(resolveCodexUrl(baseUrl));
	if (url.protocol === "https:") url.protocol = "wss:";
	if (url.protocol === "http:") url.protocol = "ws:";
	return url.toString();
}

function headersToRecord(headers: Headers): Record<string, string> {
	return Object.fromEntries(headers.entries());
}

function createCodexRequestId(): string {
	if (typeof globalThis.crypto?.randomUUID === "function") {
		return globalThis.crypto.randomUUID();
	}
	return `codex_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
}

function buildBaseCodexHeaders(
	modelHeaders: Record<string, string> | undefined,
	additionalHeaders: Record<string, string> | undefined,
	accountId: string,
	token: string,
): Headers {
	const headers = new Headers(modelHeaders);
	for (const [key, value] of Object.entries(additionalHeaders ?? {})) {
		headers.set(key, value);
	}

	headers.set("Authorization", `Bearer ${token}`);
	headers.set("chatgpt-account-id", accountId);
	headers.set("originator", "pi");
	headers.set("User-Agent", _os ? `pi (${_os.platform()} ${_os.release()}; ${_os.arch()})` : "pi (browser)");
	return headers;
}

function buildSSEHeaders(
	modelHeaders: Record<string, string> | undefined,
	additionalHeaders: Record<string, string> | undefined,
	accountId: string,
	token: string,
	sessionId: string | undefined,
): Headers {
	const headers = buildBaseCodexHeaders(modelHeaders, additionalHeaders, accountId, token);
	headers.set("OpenAI-Beta", "responses=experimental");
	headers.set("accept", "text/event-stream");
	headers.set("content-type", "application/json");

	if (sessionId) {
		headers.set("session_id", sessionId);
		headers.set("x-client-request-id", sessionId);
	}

	return headers;
}

function buildWebSocketHeaders(
	modelHeaders: Record<string, string> | undefined,
	additionalHeaders: Record<string, string> | undefined,
	accountId: string,
	token: string,
	requestId: string,
): Headers {
	const headers = buildBaseCodexHeaders(modelHeaders, additionalHeaders, accountId, token);
	headers.delete("accept");
	headers.delete("content-type");
	headers.delete("OpenAI-Beta");
	headers.delete("openai-beta");
	headers.set("OpenAI-Beta", OPENAI_BETA_RESPONSES_WEBSOCKETS);
	headers.set("x-client-request-id", requestId);
	headers.set("session_id", requestId);
	return headers;
}

function clampReasoningEffort(modelId: string, effort: string): string {
	const id = modelId.includes("/") ? (modelId.split("/").pop() ?? modelId) : modelId;
	const gpt5MinorMatch = /^gpt-5\.(\d+)/.exec(id);
	const gpt5Minor = gpt5MinorMatch ? Number.parseInt(gpt5MinorMatch[1], 10) : undefined;
	if (gpt5Minor !== undefined && gpt5Minor >= 2 && effort === "minimal") return "low";
	if (id === "gpt-5.1" && effort === "xhigh") return "high";
	if (id === "gpt-5.1-codex-mini") return effort === "high" || effort === "xhigh" ? "high" : "medium";
	return effort;
}

function getServiceTierCostMultiplier(model: Model<Api>, serviceTier: ServiceTier): number {
	switch (serviceTier) {
		case "flex":
			return 0.5;
		case "priority":
			return model.id === "gpt-5.5" ? 2.5 : 2;
		default:
			return 1;
	}
}

function applyServiceTierPricing(usage: AssistantMessage["usage"], serviceTier: ServiceTier, model: Model<Api>): void {
	const multiplier = getServiceTierCostMultiplier(model, serviceTier);
	if (multiplier === 1) return;
	usage.cost.input *= multiplier;
	usage.cost.output *= multiplier;
	usage.cost.cacheRead *= multiplier;
	usage.cost.cacheWrite *= multiplier;
	usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cacheRead + usage.cost.cacheWrite;
}

function resolveCodexServiceTier(responseServiceTier: ServiceTier, requestServiceTier: ServiceTier): ServiceTier {
	if (responseServiceTier === "default" && (requestServiceTier === "flex" || requestServiceTier === "priority")) {
		return requestServiceTier;
	}
	return responseServiceTier ?? requestServiceTier;
}

function buildRequestBody<TApi extends Api>(model: Model<TApi>, context: Context, options?: SimpleStreamOptions): ResponsesBody {
	const messages = convertResponsesMessages(model, context, CODEX_TOOL_CALL_PROVIDERS, {
		includeSystemPrompt: false,
	});

	const body: ResponsesBody = {
		model: model.id,
		store: false,
		stream: true,
		instructions: context.systemPrompt,
		input: messages,
		text: { verbosity: ((options as { textVerbosity?: string } | undefined)?.textVerbosity ?? "low") as string },
		include: ["reasoning.encrypted_content"],
		prompt_cache_key: options?.sessionId,
		tool_choice: "auto",
		parallel_tool_calls: true,
	};

	// The Codex ChatGPT-backed endpoint rejects output-token cap fields with
	// `Unsupported parameter: max_output_tokens`. Pi's branch summarizer passes
	// `maxTokens`, so forwarding it breaks `/tree` summaries and extensions that
	// use `ctx.navigateTree(..., { summarize: true })`.

	if ((options as { temperature?: number } | undefined)?.temperature !== undefined) {
		body.temperature = (options as { temperature?: number }).temperature;
	}

	const serviceTier = (options as { serviceTier?: string } | undefined)?.serviceTier;
	if (serviceTier !== undefined) {
		body.service_tier = serviceTier;
	}

	if (context.tools && context.tools.length > 0) {
		body.tools = convertResponsesTools(context.tools, { strict: null });
	}

	const clampedReasoning = options?.reasoning ? clampThinkingLevel(model, options.reasoning) : undefined;
	const reasoningEffort = clampedReasoning === "off" ? undefined : clampedReasoning;
	if (reasoningEffort !== undefined) {
		const effort = model.thinkingLevelMap?.[reasoningEffort] ?? reasoningEffort;
		if (effort === null) return body;
		body.reasoning = {
			effort: clampReasoningEffort(model.id, effort),
			summary: ((options as { reasoningSummary?: string } | undefined)?.reasoningSummary ?? "auto") as string,
		};
	}

	return body;
}

function isRetryableError(status: number, errorText: string): boolean {
	if (status === 429 || status === 500 || status === 502 || status === 503 || status === 504) {
		return true;
	}
	return /rate.?limit|overloaded|service.?unavailable|upstream.?connect|connection.?refused/i.test(errorText);
}

export function withHttpStatusPrefix(status: number, message: string): string {
	const trimmed = message.trim() || "Request failed";
	if (HTTP_STATUS_MESSAGE_PREFIX.test(trimmed)) return trimmed;
	return `HTTP ${status}: ${trimmed}`;
}

function sleep(ms: number, signal: AbortSignal | undefined): Promise<void> {
	return new Promise((resolve, reject) => {
		if (signal?.aborted) {
			reject(new Error("Request was aborted"));
			return;
		}

		const timeout = setTimeout(resolve, ms);
		signal?.addEventListener(
			"abort",
			() => {
				clearTimeout(timeout);
				reject(new Error("Request was aborted"));
			},
			{ once: true },
		);
	});
}

async function* parseSSE(response: Response): AsyncIterable<StreamEventShape> {
	if (!response.body) return;

	const reader = response.body.getReader();
	const decoder = new TextDecoder();
	let buffer = "";

	try {
		while (true) {
			const { done, value } = await reader.read();
			if (done) break;

			buffer += decoder.decode(value, { stream: true });
			buffer = buffer.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
			let idx = buffer.indexOf("\n\n");
			while (idx !== -1) {
				const chunk = buffer.slice(0, idx);
				buffer = buffer.slice(idx + 2);
				const dataLines = chunk
					.split("\n")
					.filter((line) => line.startsWith("data:"))
					.map((line) => line.slice(5).trim());
				if (dataLines.length > 0) {
					const data = dataLines.join("\n").trim();
					if (data && data !== "[DONE]") {
						try {
							yield JSON.parse(data) as StreamEventShape;
						} catch {
							// Ignore malformed SSE chunks and continue consuming the stream.
						}
					}
				}
				idx = buffer.indexOf("\n\n");
			}
		}
	} finally {
		try {
			await reader.cancel();
		} catch {
			// ignore cancellation errors
		}
		try {
			reader.releaseLock();
		} catch {
			// ignore lock release errors
		}
	}
}

function getWebSocketConstructor(): WebSocketConstructorLike | null {
	const ctor = (globalThis as typeof globalThis & { WebSocket?: WebSocketConstructorLike }).WebSocket;
	return typeof ctor === "function" ? ctor : null;
}

function envFirst(names: string[]): string | undefined {
	if (typeof process === "undefined") return undefined;
	for (const name of names) {
		const value = process.env[name];
		if (value?.trim()) return value.trim();
	}
	return undefined;
}

function noProxyMatches(hostname: string, noProxy: string | undefined): boolean {
	if (!noProxy) return false;
	const host = hostname.toLowerCase();
	for (const rawPart of noProxy.split(",")) {
		const part = rawPart.trim().toLowerCase();
		if (!part) continue;
		if (part === "*") return true;
		const normalized = part.startsWith(".") ? part.slice(1) : part;
		if (host === normalized || host.endsWith(`.${normalized}`)) return true;
	}
	return false;
}

export function proxyForWebSocketUrl(rawUrl: string): string | undefined {
	let url: URL;
	try {
		url = new URL(rawUrl);
	} catch {
		return undefined;
	}
	const noProxy = envFirst(["NO_PROXY", "no_proxy"]);
	if (noProxyMatches(url.hostname, noProxy)) return undefined;
	if (url.protocol === "wss:" || url.protocol === "https:") return envFirst(["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]);
	if (url.protocol === "ws:" || url.protocol === "http:") return envFirst(["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"]);
	return undefined;
}

async function proxyDispatcherForUrl(rawUrl: string): Promise<unknown | undefined> {
	const proxy = proxyForWebSocketUrl(rawUrl);
	if (!proxy) return undefined;
	const { ProxyAgent } = await import("undici");
	return new ProxyAgent(proxy);
}

export async function webSocketOptionsForUrl(url: string, headers: Record<string, string>): Promise<{ headers: Record<string, string>; dispatcher?: unknown }> {
	const dispatcher = await proxyDispatcherForUrl(url);
	return dispatcher ? { headers, dispatcher } : { headers };
}

function getWebSocketReadyState(socket: WebSocketLike): number | undefined {
	return typeof socket.readyState === "number" ? socket.readyState : undefined;
}

function isWebSocketReusable(socket: WebSocketLike): boolean {
	const readyState = getWebSocketReadyState(socket);
	return readyState === undefined || readyState === 1;
}

function closeWebSocketSilently(socket: WebSocketLike, code = 1000, reason = "done"): void {
	try {
		socket.close(code, reason);
	} catch {
		// ignore close errors
	}
}


function scheduleSessionWebSocketExpiry(cacheKey: string, entry: SessionWebSocketCacheEntry): void {
	if (entry.idleTimer) {
		clearTimeout(entry.idleTimer);
	}
	entry.idleTimer = setTimeout(() => {
		if (entry.busy) return;
		closeWebSocketSilently(entry.socket, 1000, "idle_timeout");
		websocketSessionCache.delete(cacheKey);
	}, SESSION_WEBSOCKET_CACHE_TTL_MS);
}

function extractWebSocketError(event: unknown): Error {
	if (event && typeof event === "object" && "message" in event) {
		const message = (event as { message?: unknown }).message;
		if (typeof message === "string" && message.length > 0) {
			return new Error(message);
		}
	}
	return new Error("WebSocket error");
}

function extractWebSocketCloseError(event: unknown): Error {
	if (event && typeof event === "object") {
		const code = "code" in event ? (event as { code?: unknown }).code : undefined;
		const reason = "reason" in event ? (event as { reason?: unknown }).reason : undefined;
		const codeText = typeof code === "number" ? ` ${code}` : "";
		const reasonText = typeof reason === "string" && reason.length > 0 ? ` ${reason}` : "";
		return new Error(`WebSocket closed${codeText}${reasonText}`.trim());
	}
	return new Error("WebSocket closed");
}

async function connectWebSocket(url: string, headers: Headers, signal: AbortSignal | undefined): Promise<WebSocketLike> {
	const WebSocketCtor = getWebSocketConstructor();
	if (!WebSocketCtor) {
		throw new Error("WebSocket transport is not available in this runtime");
	}

	const wsHeaders = headersToRecord(headers);
	delete wsHeaders["OpenAI-Beta"];
	const options = await webSocketOptionsForUrl(url, wsHeaders);

	return new Promise((resolve, reject) => {
		let settled = false;
		let socket: WebSocketLike;

		try {
			socket = new WebSocketCtor(url, options);
		} catch (error) {
			reject(error instanceof Error ? error : new Error(String(error)));
			return;
		}

		const onOpen = () => {
			if (settled) return;
			settled = true;
			cleanup();
			resolve(socket);
		};
		const onError = (event: unknown) => {
			if (settled) return;
			settled = true;
			cleanup();
			reject(extractWebSocketError(event));
		};
		const onClose = (event: unknown) => {
			if (settled) return;
			settled = true;
			cleanup();
			reject(extractWebSocketCloseError(event));
		};
		const onAbort = () => {
			if (settled) return;
			settled = true;
			cleanup();
			socket.close(1000, "aborted");
			reject(new Error("Request was aborted"));
		};

		const cleanup = () => {
			socket.removeEventListener("open", onOpen);
			socket.removeEventListener("error", onError);
			socket.removeEventListener("close", onClose);
			signal?.removeEventListener("abort", onAbort);
		};

		socket.addEventListener("open", onOpen);
		socket.addEventListener("error", onError);
		socket.addEventListener("close", onClose);
		signal?.addEventListener("abort", onAbort);
	});
}

async function acquireWebSocket(
	url: string,
	headers: Headers,
	sessionId: string | undefined,
	signal: AbortSignal | undefined,
): Promise<AcquiredWebSocket> {
	if (!sessionId) {
		const socket = await connectWebSocket(url, headers, signal);
		return {
			socket,
			reused: false,
			release: ({ keep } = {}) => {
				if (keep === false) {
					closeWebSocketSilently(socket);
					return;
				}
				closeWebSocketSilently(socket);
			},
		};
	}

	const cached = websocketSessionCache.get(sessionId);
	if (cached) {
		if (cached.idleTimer) {
			clearTimeout(cached.idleTimer);
			cached.idleTimer = undefined;
		}

		if (!cached.busy && isWebSocketReusable(cached.socket)) {
			cached.busy = true;
			return {
				socket: cached.socket,
				entry: cached,
				reused: true,
				release: ({ keep } = {}) => {
					if (!keep || !isWebSocketReusable(cached.socket)) {
						closeWebSocketSilently(cached.socket);
						websocketSessionCache.delete(sessionId);
						return;
					}
					cached.busy = false;
					scheduleSessionWebSocketExpiry(sessionId, cached);
				},
			};
		}

		if (cached.busy) {
			const socket = await connectWebSocket(url, headers, signal);
			return {
				socket,
				reused: false,
				release: () => {
					closeWebSocketSilently(socket);
				},
			};
		}

		if (!isWebSocketReusable(cached.socket)) {
			closeWebSocketSilently(cached.socket);
			websocketSessionCache.delete(sessionId);
		}
	}

	const socket = await connectWebSocket(url, headers, signal);
	const entry: SessionWebSocketCacheEntry = { socket, busy: true };
	websocketSessionCache.set(sessionId, entry);
	return {
		socket,
		entry,
		reused: false,
		release: ({ keep } = {}) => {
			if (!keep || !isWebSocketReusable(entry.socket)) {
				closeWebSocketSilently(entry.socket);
				if (entry.idleTimer) clearTimeout(entry.idleTimer);
				if (websocketSessionCache.get(sessionId) === entry) {
					websocketSessionCache.delete(sessionId);
				}
				return;
			}
			entry.busy = false;
			scheduleSessionWebSocketExpiry(sessionId, entry);
		},
	};
}

async function decodeWebSocketData(data: unknown): Promise<string | null> {
	if (typeof data === "string") return data;
	if (data instanceof ArrayBuffer) {
		return new TextDecoder().decode(new Uint8Array(data));
	}
	if (ArrayBuffer.isView(data)) {
		return new TextDecoder().decode(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
	}
	if (data && typeof data === "object" && "arrayBuffer" in data) {
		const arrayBuffer = await (data as { arrayBuffer: () => Promise<ArrayBuffer> }).arrayBuffer();
		return new TextDecoder().decode(new Uint8Array(arrayBuffer));
	}
	return null;
}

function requestBodyWithoutInput(body: ResponsesBody): ResponsesBody {
	const { input: _input, previous_response_id: _previousResponseId, ...rest } = body;
	return rest as ResponsesBody;
}

function responseInputsEqual(a: unknown[] | undefined, b: unknown[] | undefined): boolean {
	return JSON.stringify(a ?? []) === JSON.stringify(b ?? []);
}

function requestBodiesMatchExceptInput(a: ResponsesBody, b: ResponsesBody): boolean {
	return JSON.stringify(requestBodyWithoutInput(a)) === JSON.stringify(requestBodyWithoutInput(b));
}

function getCachedWebSocketInputDelta(body: ResponsesBody, continuation: CachedWebSocketContinuationState): unknown[] | undefined {
	if (!requestBodiesMatchExceptInput(body, continuation.lastRequestBody)) {
		return undefined;
	}

	const currentInput = body.input ?? [];
	const baseline = [...(continuation.lastRequestBody.input ?? []), ...continuation.lastResponseItems];
	if (currentInput.length < baseline.length) {
		return undefined;
	}

	const prefix = currentInput.slice(0, baseline.length);
	if (!responseInputsEqual(prefix, baseline)) {
		return undefined;
	}

	return currentInput.slice(baseline.length);
}

function buildCachedWebSocketRequestBody(entry: SessionWebSocketCacheEntry, body: ResponsesBody): ResponsesBody {
	const continuation = entry.continuation;
	if (!continuation) {
		return body;
	}

	const delta = getCachedWebSocketInputDelta(body, continuation);
	if (!delta || !continuation.lastResponseId) {
		entry.continuation = undefined;
		return body;
	}

	return {
		...body,
		previous_response_id: continuation.lastResponseId,
		input: delta,
	};
}

async function* parseWebSocket(socket: WebSocketLike, signal: AbortSignal | undefined): AsyncIterable<StreamEventShape> {
	const queue: StreamEventShape[] = [];
	let pending: (() => void) | null = null;
	let done = false;
	let failed: Error | null = null;
	let closeError: Error | null = null;
	let sawCompletion = false;
	let pendingMessages = 0;
	let messageChain = Promise.resolve();

	const wake = () => {
		if (!pending) return;
		const resolve = pending;
		pending = null;
		resolve();
	};

	const onMessage = (event: unknown) => {
		pendingMessages++;
		messageChain = messageChain
			.then(async () => {
				if (!event || typeof event !== "object" || !("data" in event)) return;
				const text = await decodeWebSocketData((event as { data?: unknown }).data);
				if (!text) return;
				try {
					const parsed = JSON.parse(text) as StreamEventShape;
					const type = typeof parsed.type === "string" ? parsed.type : "";
					if (type === "response.completed" || type === "response.done" || type === "response.incomplete") {
						sawCompletion = true;
						closeError = null;
						done = true;
					}
					queue.push(parsed);
				} catch {
					// ignore malformed websocket messages
				}
			})
			.catch((error: unknown) => {
				failed = error instanceof Error ? error : new Error(String(error));
				done = true;
			})
			.finally(() => {
				pendingMessages--;
				wake();
			});
	};

	const onError = (event: unknown) => {
		failed = extractWebSocketError(event);
		done = true;
		wake();
	};

	const onClose = (event: unknown) => {
		if (sawCompletion) {
			done = true;
			wake();
			return;
		}
		if (!closeError) {
			closeError = extractWebSocketCloseError(event);
		}
		done = true;
		wake();
	};

	const onAbort = () => {
		failed = new Error("Request was aborted");
		done = true;
		wake();
	};

	socket.addEventListener("message", onMessage);
	socket.addEventListener("error", onError);
	socket.addEventListener("close", onClose);
	signal?.addEventListener("abort", onAbort);

	try {
		while (true) {
			if (signal?.aborted) {
				throw new Error("Request was aborted");
			}
			if (queue.length > 0) {
				yield queue.shift() as StreamEventShape;
				continue;
			}
			if (done && pendingMessages === 0) break;
			await new Promise<void>((resolve) => {
				pending = resolve;
			});
		}

		if (failed) throw failed;
		if (closeError && !sawCompletion) throw closeError;
		if (!sawCompletion) {
			throw new Error("WebSocket stream closed before response.completed");
		}
	} finally {
		socket.removeEventListener("message", onMessage);
		socket.removeEventListener("error", onError);
		socket.removeEventListener("close", onClose);
		signal?.removeEventListener("abort", onAbort);
	}
}

async function* countWebSocketEvents(
	events: AsyncIterable<StreamEventShape>,
	onEvent: () => void,
): AsyncIterable<StreamEventShape> {
	for await (const event of events) {
		onEvent();
		yield event;
	}
}

function isRetryableEarlyWebSocketError(error: unknown): boolean {
	const message = error instanceof Error ? error.message : String(error);
	return /^WebSocket (error|closed)(?:\s|$)/.test(message);
}

async function* mapCodexEvents(events: AsyncIterable<StreamEventShape>): AsyncIterable<StreamEventShape> {
	let sawTerminalResponse = false;
	const completedOutputItems = new Set<string>();
	const outputItemKey = (item: unknown, index?: number): string | undefined => {
		if (!item || typeof item !== "object") return undefined;
		const candidate = item as { id?: unknown; type?: unknown };
		if (typeof candidate.id === "string" && typeof candidate.type === "string") return `${candidate.type}:${candidate.id}`;
		return typeof candidate.type === "string" && typeof index === "number" ? `${candidate.type}:index:${index}` : undefined;
	};
	for await (const event of events) {
		const type = typeof event.type === "string" ? event.type : undefined;
		if (!type) continue;

		if (type === "error") {
			throw new Error(`Codex error: ${event.message || event.code || JSON.stringify(event)}`);
		}

		if (type === "response.failed") {
			throw new Error(event.response?.error?.message || "Codex response failed");
		}

		if (type === "response.done" || type === "response.completed" || type === "response.incomplete") {
			sawTerminalResponse = true;
			const response = event.response;
			const output = Array.isArray(response?.output) ? response.output : [];
			for (let outputIndex = 0; outputIndex < output.length; outputIndex++) {
				const item = output[outputIndex];
				if (!item || typeof item !== "object") continue;
				const itemType = (item as { type?: unknown }).type;
				if (itemType !== "image_generation_call" && itemType !== "web_search_call") continue;
				const key = outputItemKey(item, outputIndex);
				if (key && completedOutputItems.has(key)) continue;
				if (key) completedOutputItems.add(key);
				yield { type: "response.output_item.done", output_index: outputIndex, item } as StreamEventShape;
			}
			yield {
				...event,
				type: "response.completed",
				response: response ? { ...response, status: normalizeCodexStatus(response.status) } : response,
			};
			return;
		}

		if (type === "response.output_item.done") {
			const key = outputItemKey(event.item, typeof event.output_index === "number" ? event.output_index : undefined);
			if (key) completedOutputItems.add(key);
		}

		yield event;
	}

	if (!sawTerminalResponse) {
		throw new Error("Stream closed before response.completed");
	}
}

function normalizeCodexStatus(status: string | undefined): string | undefined {
	if (typeof status !== "string") return undefined;
	return CODEX_RESPONSE_STATUSES.has(status) ? status : undefined;
}

function getLatestUserText(context: Context): string | undefined {
	for (let i = context.messages.length - 1; i >= 0; i--) {
		const message = context.messages[i];
		if (message.role !== "user") continue;
		if (typeof message.content === "string") {
			const trimmed = message.content.trim();
			if (trimmed) return trimmed;
			continue;
		}
		const text = message.content
			.filter((item) => item.type === "text")
			.map((item) => item.text)
			.join("\n")
			.trim();
		if (text) return text;
	}
	return undefined;
}

async function* captureGeneratedImages(
	events: AsyncIterable<StreamEventShape>,
	options: {
		cwd: string;
		requestPrompt?: string;
		onImageSaved: (image: SavedGeneratedImage, imageData: { data: string; mimeType: string }) => void;
		onWebSearchCaptured?: (search: SurfacedWebSearch) => void;
	},
): AsyncIterable<StreamEventShape> {
	let responseId: string | undefined;

	for await (const event of events) {
		if (event.type === "response.created" && event.response?.id) {
			responseId = event.response.id;
		}

		if (event.type === "response.output_item.done" && event.item?.type === "image_generation_call") {
			const callId = typeof event.item.id === "string" ? event.item.id : undefined;
			const result = typeof event.item.result === "string" ? event.item.result : undefined;
			if (callId && result) {
				try {
					const outputFormat = typeof event.item.output_format === "string" ? event.item.output_format : undefined;
					const normalizedOutputFormat = normalizeImageOutputFormat(outputFormat);
					const settings = loadSettings(options.cwd);
					const imageModel = typeof event.item.model === "string" ? event.item.model : settings.imageModel;
					const saved = await saveOpenAICodexGeneratedImage(options.cwd, {
						responseId,
						callId,
						result,
						outputFormat: normalizedOutputFormat,
						imageModel,
						revisedPrompt:
							typeof event.item.revised_prompt === "string" ? event.item.revised_prompt : options.requestPrompt,
					});
					options.onImageSaved(saved, {
						data: result,
						mimeType: `image/${normalizedOutputFormat}`,
					});
				} catch {
					// Image persistence is best-effort. Do not write raw diagnostics to
					// stdout/stderr from inside the TUI; terminal output can corrupt active
					// widgets and boxes.
				}
			}
		}

		if (event.type === "response.output_item.done" && event.item?.type === "web_search_call") {
			const search = extractWebSearch(event.item);
			if (search) {
				options.onWebSearchCaptured?.(search);
			}
		}

		yield event;
	}
}

async function processCapturedResponsesStream<TApi extends Api>(
	events: AsyncIterable<StreamEventShape>,
	output: AssistantMessage,
	stream: AssistantMessageEventStream,
	model: Model<TApi>,
	options: SimpleStreamOptions | undefined,
	deps: {
		onImageSaved?: (savedImage: SavedGeneratedImage, imageData: { data: string; mimeType: string }) => void;
		onWebSearchCaptured?: (search: SurfacedWebSearch) => void;
	},
	cwd: string,
	requestPrompt: string | undefined,
): Promise<void> {
	const tappedEvents = captureGeneratedImages(mapCodexEvents(events), {
		cwd,
		requestPrompt,
		onImageSaved: (image, imageData) => deps.onImageSaved?.(image, imageData),
		onWebSearchCaptured: (search) => deps.onWebSearchCaptured?.(search),
	});

	await processResponsesStream(tappedEvents as AsyncIterable<never>, output, stream, model, {
		serviceTier: (options as { serviceTier?: ServiceTier } | undefined)?.serviceTier,
		resolveServiceTier: resolveCodexServiceTier,
		applyServiceTierPricing: (usage, serviceTier) => applyServiceTierPricing(usage, serviceTier, model as Model<Api>),
	});
}

async function processWebSocketStream<TApi extends Api>(
	url: string,
	body: ResponsesBody,
	headers: Headers,
	output: AssistantMessage,
	stream: AssistantMessageEventStream,
	model: Model<TApi>,
	onStart: () => void,
	options: SimpleStreamOptions | undefined,
	deps: {
		onImageSaved?: (savedImage: SavedGeneratedImage, imageData: { data: string; mimeType: string }) => void;
		onWebSearchCaptured?: (search: SurfacedWebSearch) => void;
	},
	cwd: string,
	requestPrompt: string | undefined,
): Promise<void> {
	let streamStarted = false;

	for (let attempt = 0; attempt < 2; attempt++) {
		const { socket, entry, release, reused } = await acquireWebSocket(url, headers, options?.sessionId, options?.signal);
		let keepConnection = true;
		let released = false;
		let eventCount = 0;
		const transport = (options as { transport?: string } | undefined)?.transport ?? "auto";
		const useCachedContext = transport === "websocket-cached" || transport === "auto";
		// ChatGPT Codex Responses rejects `store: true` ("Store must be set to false").
		// WebSocket continuation still works via connection-scoped previous_response_id state.
		const fullBody = body;
		const requestBody = useCachedContext && entry ? buildCachedWebSocketRequestBody(entry, fullBody) : fullBody;

		const releaseOnce = (releaseOptions?: { keep?: boolean }) => {
			if (released) return;
			released = true;
			release(releaseOptions);
		};

		try {
			socket.send(JSON.stringify({ type: "response.create", ...requestBody }));
			if (!streamStarted) {
				onStart();
				stream.push({ type: "start", partial: output });
				streamStarted = true;
			}
			await processCapturedResponsesStream(
				countWebSocketEvents(parseWebSocket(socket, options?.signal), () => {
					eventCount++;
				}),
				output,
				stream,
				model,
				options,
				deps,
				cwd,
				requestPrompt,
			);
			if (options?.signal?.aborted) {
				keepConnection = false;
			} else if (useCachedContext && entry && output.responseId) {
				const responseItems = convertResponsesMessages(model, { messages: [output] }, CODEX_TOOL_CALL_PROVIDERS, {
					includeSystemPrompt: false,
				}).filter((item) => typeof item === "object" && item !== null && (item as { type?: unknown }).type !== "function_call_output");
				entry.continuation = {
					lastRequestBody: fullBody,
					lastResponseId: output.responseId,
					lastResponseItems: responseItems,
				};
			}
			releaseOnce({ keep: keepConnection });
			return;
		} catch (error) {
			if (entry) {
				entry.continuation = undefined;
			}
			keepConnection = false;
			releaseOnce({ keep: false });
			// Pi's stock provider reuses session WebSockets. In practice the Codex
			// backend sometimes cleanly closes an idle cached socket between turns;
			// if that stale socket fails before any response event, retry once on a
			// fresh WebSocket without changing request shape or falling back transports.
			if (attempt === 0 && reused && eventCount === 0 && !options?.signal?.aborted && isRetryableEarlyWebSocketError(error)) {
				continue;
			}
			throw error;
		} finally {
			releaseOnce({ keep: keepConnection });
		}
	}
}

function extractWebSearch(item: StreamEventShape["item"]): SurfacedWebSearch | undefined {
	if (!item || item.type !== "web_search_call") return undefined;
	const callId = typeof item.id === "string" ? item.id : undefined;
	if (!callId) return undefined;

	const action = typeof item.action === "object" && item.action !== null ? (item.action as Record<string, unknown>) : undefined;
	const query = typeof action?.query === "string" ? action.query : undefined;
	const queries = Array.isArray(action?.queries) ? action.queries.filter((value): value is string => typeof value === "string") : [];
	const sourceUrls = Array.isArray(action?.sources)
		? action.sources
				.map((source) => (typeof source === "object" && source !== null ? (source as Record<string, unknown>) : undefined))
				.map((source) => (typeof source?.url === "string" ? source.url : undefined))
				.filter((url): url is string => typeof url === "string")
		: [];

	const results = Array.isArray(item.results)
		? item.results
				.map((result) => (typeof result === "object" && result !== null ? (result as Record<string, unknown>) : undefined))
				.filter((result): result is Record<string, unknown> => !!result)
		: [];

	const titledSources: Array<{ title?: string; url: string }> = [];
	for (const result of results) {
		if (typeof result.url !== "string") continue;
		titledSources.push({
			title: typeof result.title === "string" ? result.title : undefined,
			url: result.url,
		});
	}

	const seenUrls = new Set<string>();
	const sources: Array<{ title?: string; url: string }> = [];
	for (const source of titledSources) {
		if (seenUrls.has(source.url)) continue;
		seenUrls.add(source.url);
		sources.push(source);
	}
	for (const url of sourceUrls) {
		if (seenUrls.has(url)) continue;
		seenUrls.add(url);
		sources.push({ url });
	}

	return {
		callId,
		status: typeof item.status === "string" ? item.status : undefined,
		query,
		queries,
		sources,
	};
}

export function buildWebSearchActivityMessage(searches: SurfacedWebSearch[]): string {
	const sections = searches.map((search, index) => {
		const heading = searches.length > 1 ? `Web search results ${index + 1}` : "Web search results";
		const lines = [heading];
		const queries = search.queries.length > 0 ? search.queries : search.query ? [search.query] : [];
		if (queries.length > 0) {
			lines.push("Queries:");
			for (const query of queries) {
				lines.push(`- ${query}`);
			}
		}
		if (search.sources.length > 0) {
			lines.push("Sources:");
			for (const source of search.sources.slice(0, 5)) {
				lines.push(`- ${source.title ? `${source.title} — ` : ""}${source.url}`);
			}
		}
		return lines.join("\n");
	});

	return sections.join("\n\n");
}

export function buildWebSearchSummaryText(searches: SurfacedWebSearch[]): string {
	return searches.length === 1 ? "Searched the web once" : `Searched the web ${searches.length} times`;
}

function makeCachedImagePreview(data: string, mimeType: string, bytes?: number): CachedImagePreview {
	const dimensions = getImageDimensions(data, mimeType) ?? undefined;
	return { data, mimeType, bytes: bytes ?? Buffer.from(data, "base64").byteLength, widthPx: dimensions?.widthPx, heightPx: dimensions?.heightPx };
}

function loadCachedImagePreview(savedImage: SavedGeneratedImage, imagePreviewCache: Map<string, CachedImagePreview>): CachedImagePreview | undefined {
	const cached = imagePreviewCache.get(savedImage.absolutePath);
	if (cached) return cached;
	const fs = getNodeFsSync();
	if (!fs) return undefined;
	try {
		const buffer = fs.readFileSync(savedImage.absolutePath);
		const data = buffer.toString("base64");
		const mimeType = `image/${savedImage.outputFormat}`;
		const preview = makeCachedImagePreview(data, mimeType, buffer.byteLength);
		imagePreviewCache.set(savedImage.absolutePath, preview);
		return preview;
	} catch {
		return undefined;
	}
}

function formatImageBytes(bytes: number | undefined): string | undefined {
	if (!Number.isFinite(bytes) || !bytes) return undefined;
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${Math.round(bytes / 102.4) / 10}K`;
	return `${Math.round(bytes / (1024 * 102.4)) / 10}M`;
}

function themeFg(theme: any, token: string, text: string): string {
	try { return theme?.fg?.(token, text) ?? text; } catch { return text; }
}

function themeBold(theme: any, text: string): string {
	try { return theme?.bold?.(text) ?? text; } catch { return text; }
}

function shouldRenderInlineImage(): { ok: boolean; reason?: string } {
	if (process.env.TMUX) return { ok: false, reason: "inline preview disabled in tmux to avoid overlay/stale image artifacts" };
	const protocol = getCapabilities().images;
	if (!protocol) return { ok: false, reason: "terminal image protocol unavailable" };
	return { ok: true };
}

function renderImageGenerationMessage(savedImage: SavedGeneratedImage | undefined, messageContent: unknown, options: any, theme: any, imagePreviewCache: Map<string, CachedImagePreview>): Container {
	const container = new Container();
	const preview = savedImage ? loadCachedImagePreview(savedImage, imagePreviewCache) : undefined;
	const type = savedImage?.outputFormat?.toUpperCase() ?? preview?.mimeType?.replace(/^image\//, "").toUpperCase() ?? "IMAGE";
	const dimensions = preview?.widthPx && preview?.heightPx ? `${preview.widthPx}x${preview.heightPx}` : undefined;
	const size = formatImageBytes(preview?.bytes);
	const imageModel = savedImage?.imageModel ? `model ${savedImage.imageModel}` : undefined;
	const meta = [imageModel, type, dimensions, size].filter(Boolean).join(" · ");
	const label = `${themeFg(theme, "accent", "● ")}${themeFg(theme, "text", themeBold(theme, "Image Generation "))}`;
	const pathText = savedImage?.relativePath ?? (typeof messageContent === "string" ? messageContent : "generated image");
	const lines = [`${label}${themeFg(theme, "accent", pathText)}${meta ? themeFg(theme, "dim", ` · ${meta}`) : ""}`];
	if (savedImage?.latestRelativePath) lines.push(`${themeFg(theme, "muted", "  ├─ ")}${themeFg(theme, "text", "Latest ")}${themeFg(theme, "accent", savedImage.latestRelativePath)}`);
	if (options?.expanded && savedImage?.revisedPrompt) lines.push(`${themeFg(theme, "muted", "  ├─ ")}${themeFg(theme, "text", "Prompt ")}${themeFg(theme, "dim", savedImage.revisedPrompt)}`);
	const inline = shouldRenderInlineImage();
	if (!inline.ok) lines.push(`${themeFg(theme, "muted", "  └─ ")}${themeFg(theme, "warning", inline.reason ?? "inline preview unavailable")}`);
	container.addChild(new Text(lines.join("\n"), 0, 0));
	if (savedImage && preview && inline.ok) {
		container.addChild(new Spacer(1));
		container.addChild(new Image(preview.data, preview.mimeType, { fallbackColor: (text) => themeFg(theme, "dim", text) }, { maxWidthCells: 72, maxHeightCells: options?.expanded ? 24 : 14, filename: savedImage.relativePath }));
	}
	return container;
}

function createInitialAssistantMessage<TApi extends Api>(model: Model<TApi>): AssistantMessage {
	return {
		role: "assistant",
		content: [],
		api: "openai-codex-responses",
		provider: model.provider,
		model: model.id,
		usage: {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 0,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
		stopReason: "stop",
		timestamp: Date.now(),
	};
}

function createErrorMessage(message: AssistantMessage, error: unknown, aborted: boolean): AssistantMessage {
	for (const block of message.content) {
		if (typeof block === "object" && block !== null && "partialJson" in block) {
			delete (block as { partialJson?: string }).partialJson;
		}
	}
	message.stopReason = aborted ? "aborted" : "error";
	message.errorMessage = buildProviderErrorMessage(error);
	return message;
}

export function buildProviderErrorMessage(error: unknown): string {
	const message = error instanceof Error ? error.message : String(error);
	if (/^(?:WebSocket (?:error|closed)|WebSocket stream closed before response\.completed|Stream closed before response\.completed)/.test(message)) {
		return `Connection error: ${message}`;
	}
	return message;
}

function finalizeUsage<TApi extends Api>(model: Model<TApi>, output: AssistantMessage): void {
	output.usage.cost.total = output.usage.cost.input + output.usage.cost.output + output.usage.cost.cacheRead + output.usage.cost.cacheWrite;
}

async function parseErrorResponse(response: Response): Promise<{ message: string; friendlyMessage?: string }> {
	const raw = await response.text();
	let message = raw || response.statusText || "Request failed";
	let friendlyMessage: string | undefined;

	try {
		const parsed = JSON.parse(raw) as { error?: { code?: string; type?: string; plan_type?: string; resets_at?: number; message?: string } };
		const err = parsed?.error;
		if (err) {
			const code = err.code || err.type || "";
			if (/usage_limit_reached|usage_not_included|rate_limit_exceeded/i.test(code) || response.status === 429) {
				const plan = err.plan_type ? ` (${err.plan_type.toLowerCase()} plan)` : "";
				const mins = err.resets_at ? Math.max(0, Math.round((err.resets_at * 1000 - Date.now()) / 60000)) : undefined;
				const when = mins !== undefined ? ` Try again in ~${mins} min.` : "";
				friendlyMessage = `You have hit your ChatGPT usage limit${plan}.${when}`.trim();
			}
			message = err.message || friendlyMessage || message;
		}
	} catch {
		// ignore malformed error bodies
	}

	return { message, friendlyMessage };
}

function createCodexStream<TApi extends Api>(
	model: Model<TApi>,
	context: Context,
	options: SimpleStreamOptions | undefined,
	deps: {
		getCurrentCwd: () => string;
		onImageSaved?: (savedImage: SavedGeneratedImage, imageData: { data: string; mimeType: string }) => void;
		onWebSearchCaptured?: (search: SurfacedWebSearch) => void;
	},
): AssistantMessageEventStream {
	const stream = createAssistantMessageEventStream();
	const requestCwd = deps.getCurrentCwd();

	(async () => {
		const output = createInitialAssistantMessage(model);
		const requestPrompt = getLatestUserText(context);

		try {
			const apiKey = options?.apiKey || getEnvApiKey(model.provider) || "";
			if (!apiKey) {
				throw new Error(`No API key for provider: ${model.provider}`);
			}

			const accountId = extractAccountId(apiKey);
			let body = buildRequestBody(model, context, options);
			const nextBody = await options?.onPayload?.(body, model);
			if (nextBody !== undefined) {
				body = nextBody as ResponsesBody;
			}

			const websocketRequestId = options?.sessionId || createCodexRequestId();
			const sseHeaders = buildSSEHeaders(model.headers, options?.headers, accountId, apiKey, options?.sessionId);
			const websocketHeaders = buildWebSocketHeaders(model.headers, options?.headers, accountId, apiKey, websocketRequestId);
			const bodyJson = JSON.stringify(body);
			const transport = options?.transport || "auto";

			if (transport !== "sse") {
				let websocketStarted = false;
				try {
					await processWebSocketStream(
						resolveCodexWebSocketUrl(model.baseUrl),
						body,
						websocketHeaders,
						output,
						stream,
						model,
						() => {
							websocketStarted = true;
						},
						options,
						deps,
						requestCwd,
						requestPrompt,
					);
					if (options?.signal?.aborted) {
						throw new Error("Request was aborted");
					}
					finalizeUsage(model, output);
					stream.push({ type: "done", reason: output.stopReason as "stop" | "length" | "toolUse", message: output });
					stream.end();
					return;
				} catch (error) {
					appendAssistantMessageDiagnostic(
						output,
						createAssistantMessageDiagnostic("provider_transport_failure", error, {
							configuredTransport: transport,
							fallbackTransport: websocketStarted ? undefined : "sse",
							eventsEmitted: websocketStarted,
							phase: websocketStarted ? "after_message_stream_start" : "before_message_stream_start",
							requestBytes: new TextEncoder().encode(bodyJson).byteLength,
						}),
					);
					if (transport === "websocket" || transport === "websocket-cached" || websocketStarted) {
						throw error;
					}
				}
			}

			let response: Response | undefined;
			let lastError: Error | undefined;
			const sseUrl = resolveCodexUrl(model.baseUrl);
			const sseDispatcher = await proxyDispatcherForUrl(sseUrl);

			for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
				if (options?.signal?.aborted) {
					throw new Error("Request was aborted");
				}

				try {
					response = await fetch(sseUrl, {
						method: "POST",
						headers: sseHeaders,
						body: bodyJson,
						signal: options?.signal,
						...(sseDispatcher ? { dispatcher: sseDispatcher } : {}),
					} as RequestInit);

					await options?.onResponse?.({ status: response.status, headers: headersToRecord(response.headers) }, model);

					if (response.ok) {
						break;
					}

					const errorText = await response.text();
					if (attempt < MAX_RETRIES && isRetryableError(response.status, errorText)) {
						await sleep(BASE_DELAY_MS * 2 ** attempt, options?.signal);
						continue;
					}

					const fakeResponse = new Response(errorText, {
						status: response.status,
						statusText: response.statusText,
					});
					const info = await parseErrorResponse(fakeResponse);
					throw new NonRetryableProviderError(withHttpStatusPrefix(response.status, info.friendlyMessage || info.message));
				} catch (error) {
					if (error instanceof NonRetryableProviderError) {
						throw error;
					}
					if (error instanceof Error && (error.name === "AbortError" || error.message === "Request was aborted")) {
						throw new Error("Request was aborted");
					}

					lastError = error instanceof Error ? error : new Error(String(error));
					if (attempt < MAX_RETRIES && !lastError.message.includes("usage limit")) {
						await sleep(BASE_DELAY_MS * 2 ** attempt, options?.signal);
						continue;
					}
					throw lastError;
				}
			}

			if (!response?.ok) {
				throw lastError ?? new Error("Failed after retries");
			}

			if (!response.body) {
				throw new Error("No response body");
			}

			stream.push({ type: "start", partial: output });
			await processCapturedResponsesStream(parseSSE(response), output, stream, model, options, deps, requestCwd, requestPrompt);
			finalizeUsage(model, output);

			if (options?.signal?.aborted) {
				throw new Error("Request was aborted");
			}

			stream.push({ type: "done", reason: output.stopReason as "stop" | "length" | "toolUse", message: output });
			stream.end();
		} catch (error) {
			stream.push({
				type: "error",
				reason: (options?.signal?.aborted ? "aborted" : "error") as "aborted" | "error",
				error: createErrorMessage(output, error, !!options?.signal?.aborted),
			});
			stream.end();
		}
	})();

	return stream;
}

export function registerOpenAICodexCustomProvider(pi: ExtensionAPI, options: { getCurrentCwd: () => string }): void {
	const pendingActivities: PendingActivity[] = [];
	const imagePreviewCache = new Map<string, CachedImagePreview>();
	let pendingFlushTimer: ReturnType<typeof setTimeout> | undefined;

	const flushPendingMessages = () => {
		pendingFlushTimer = undefined;
		const activities = pendingActivities.splice(0, pendingActivities.length);

		for (let index = 0; index < activities.length; index++) {
			const activity = activities[index];
			if (activity.kind === "image") {
				imagePreviewCache.set(activity.savedImage.absolutePath, makeCachedImagePreview(activity.imageData.data, activity.imageData.mimeType));
				pi.sendMessage(
					{
						customType: IMAGE_SAVE_DISPLAY_MESSAGE_TYPE,
						content: [{ type: "text", text: buildGeneratedImageDisplayText(activity.savedImage, { expanded: false }) }],
						display: true,
						details: { savedImages: [activity.savedImage] } satisfies ImageDisplayMessageDetails,
					},
					{ triggerTurn: false },
				);
				continue;
			}

			const searches = [activity.search];
			while (index + 1 < activities.length && activities[index + 1]?.kind === "web-search") {
				searches.push((activities[++index] as QueuedWebSearchActivity).search);
			}
			pi.sendMessage(
				{
					customType: WEB_SEARCH_ACTIVITY_MESSAGE_TYPE,
					content: buildWebSearchActivityMessage(searches),
					display: true,
					details: { searches },
				},
				{ triggerTurn: false },
			);
		}
	};

	const schedulePendingMessageFlush = () => {
		if (pendingFlushTimer || pendingActivities.length === 0) {
			return;
		}
		pendingFlushTimer = setTimeout(flushPendingMessages, 0);
	};

	const clearPendingMessages = () => {
		if (pendingFlushTimer) {
			clearTimeout(pendingFlushTimer);
			pendingFlushTimer = undefined;
		}
		pendingActivities.length = 0;
		imagePreviewCache.clear();
	};

	pi.registerProvider("openai-codex", {
		api: "openai-codex-responses",
		streamSimple: (model, context, streamOptions) =>
			createCodexStream(model, context, streamOptions, {
				getCurrentCwd: options.getCurrentCwd,
				onImageSaved: (savedImage, imageData) => {
					pendingActivities.push({ kind: "image", savedImage, imageData });
				},
				// Web-search provider selection and native rewrite ownership stays in pi-web-tools.
				// Keep this shim focused on capturing native image_generation_call results.
			}),
	});

	pi.on("session_start", async () => {
		clearPendingMessages();
	});

	pi.on("session_shutdown", async () => {
		if (pendingActivities.length > 0) {
			flushPendingMessages();
		}
		clearPendingMessages();
	});

	pi.on("agent_end", async () => {
		schedulePendingMessageFlush();
	});

	pi.registerMessageRenderer<ImageDisplayMessageDetails>(IMAGE_SAVE_DISPLAY_MESSAGE_TYPE, (message, options, theme) => {
		const savedImage = message.details?.savedImages?.[0];
		const textContent = typeof message.content === "string"
			? message.content
			: message.content
					.filter((item) => item.type === "text")
					.map((item) => item.text)
					.join("\n");
		return renderImageGenerationMessage(savedImage, textContent, options, theme, imagePreviewCache);
	});

	pi.registerMessageRenderer<{ searches?: SurfacedWebSearch[] }>(WEB_SEARCH_ACTIVITY_MESSAGE_TYPE, (message, options, theme) => {
		const box = new Box(1, 1, (text) => theme.bg("customMessageBg", text));
		const searches = message.details?.searches ?? [];
		box.addChild(new Text(theme.fg("customMessageLabel", theme.bold(buildWebSearchSummaryText(searches))), 0, 0));
		if (options.expanded) {
			const content = typeof message.content === "string"
				? message.content
				: message.content
						.filter((item) => item.type === "text")
						.map((item) => item.text)
						.join("\n");
			box.addChild(new Text(`\n${theme.fg("customMessageText", content)}`, 0, 0));
		}
		return box;
	});
}
