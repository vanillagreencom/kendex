import timers from "node:timers/promises";
import { requireApiKey } from "../utils/auth.js";
import { requestWithin, withDeadline } from "../utils/deadline.js";
import type { NormalizedExaResponse, NormalizedExaResult } from "./exa.js";

// Google refuses the 2.5 models to API keys created after it limited them; current models per
// https://ai.google.dev/gemini-api/docs/deprecations.
export const DEFAULT_GEMINI_SEARCH_MODEL = "gemini-3.5-flash-lite";
export const DEFAULT_GEMINI_VIDEO_MODEL = "gemini-3.8-flash";
const API_BASE = "https://generativelanguage.googleapis.com/v1beta";

export interface GeminiApiSearchParams {
	query: string;
	model?: string;
	systemInstruction?: string;
	includeDomains?: string[];
	excludeDomains?: string[];
	startPublishedDate?: string;
	endPublishedDate?: string;
	numResults?: number;
}

export interface GeminiApiClientOptions {
	apiKey?: string;
	baseUrl?: string;
	fetchImpl?: typeof fetch;
	/** Deadline of each request, through its body; DEFAULT_DEADLINE_MS when absent. */
	timeoutMs?: number;
}

interface GenerateContentResponse {
	candidates?: Array<{
		content?: { parts?: Array<{ text?: string }> };
		groundingMetadata?: {
			groundingChunks?: Array<{ web?: { uri?: string; title?: string } }>;
			groundingSupports?: Array<{ segment?: { partIndex?: number; endIndex?: number }; groundingChunkIndices?: number[] }>;
			webSearchQueries?: string[];
		};
	}>;
}

function answerFrom(raw: GenerateContentResponse, sourceIndices: Map<number, number>): string | undefined {
	const candidate = raw.candidates?.[0];
	const text = candidate?.content?.parts?.map((part, partIndex) => {
		if (!part.text) return undefined;
		let bytes = Buffer.from(part.text, "utf8");
		const markers = new Map<number, Set<number>>();
		for (const support of candidate.groundingMetadata?.groundingSupports ?? []) {
			const end = support.segment?.endIndex;
			if ((support.segment?.partIndex ?? 0) !== partIndex || end === undefined) continue;
			const sources = markers.get(end) ?? new Set<number>();
			for (const index of support.groundingChunkIndices ?? []) {
				const number = sourceIndices.get(index);
				if (number !== undefined) sources.add(number);
			}
			markers.set(end, sources);
		}
		// Gemini's segment offsets count UTF-8 bytes in the original part, before trimming or adding citations.
		for (const [end, sources] of [...markers].sort(([a], [b]) => b - a)) {
			const marker = [...sources].sort((a, b) => a - b).map((number) => `[${number}]`).join("");
			bytes = Buffer.concat([bytes.subarray(0, end), Buffer.from(marker), bytes.subarray(end)]);
		}
		return bytes.toString("utf8");
	}).filter(Boolean).join("\n").trim();
	return text || undefined;
}

async function citationsFrom(raw: GenerateContentResponse, fetchImpl: typeof fetch, signal: AbortSignal | undefined, limit: number) {
	const chunks = raw.candidates?.[0]?.groundingMetadata?.groundingChunks ?? [];
	const urls = await Promise.all(chunks.map(async (chunk) => {
		const url = chunk.web?.uri;
		if (!url || !url.startsWith("https://vertexaisearch.cloud.google.com/grounding-api-redirect/")) return url;
		try {
			return await withDeadline(signal, 2500, "Gemini source redirect", async (lookupSignal) => {
				const response = await fetchImpl(url, { method: "HEAD", redirect: "manual", signal: lookupSignal });
				const location = response.headers.get("location");
				return location ? new URL(location, url).href : url;
			});
		} catch {
			signal?.throwIfAborted();
			// Grounding redirects are optional enrichment; the raw link still identifies the source.
			return url;
		}
	}));
	const seen = new Map<string, number>();
	const sourceIndices = new Map<number, number>();
	const out: NormalizedExaResult[] = [];
	for (const [index, chunk] of chunks.entries()) {
		const url = urls[index];
		if (!url) continue;
		let number = seen.get(url);
		if (number === undefined && out.length < limit) {
			out.push({ url, title: chunk.web?.title });
			number = out.length;
			seen.set(url, number);
		}
		if (number !== undefined) sourceIndices.set(index, number);
	}
	return { results: out, sourceIndices };
}

export class GeminiApiClient {
	private readonly apiKey: string;
	private readonly baseUrl: string;
	private readonly fetchImpl: typeof fetch;
	private readonly timeoutMs: number | undefined;

	constructor(options: GeminiApiClientOptions) {
		this.apiKey = requireApiKey(options.apiKey, "Gemini", "Set GEMINI_API_KEY or PI_WEB_TOOLS_CONFIG_FILE with geminiApiKey.");
		this.baseUrl = options.baseUrl ?? API_BASE;
		this.fetchImpl = options.fetchImpl ?? fetch;
		this.timeoutMs = options.timeoutMs;
	}

	buildSearchBody(params: GeminiApiSearchParams): Record<string, unknown> {
		const userText = [
			params.query,
			params.includeDomains?.length ? `Restrict sources to these domains: ${params.includeDomains.join(", ")}.` : undefined,
			params.excludeDomains?.length ? `Avoid these domains: ${params.excludeDomains.join(", ")}.` : undefined,
			params.startPublishedDate ? `Use sources published on or after ${params.startPublishedDate}.` : undefined,
			params.endPublishedDate ? `Use sources published on or before ${params.endPublishedDate}.` : undefined,
		].filter(Boolean).join("\n\n");
		const body: Record<string, unknown> = {
			contents: [{ role: "user", parts: [{ text: userText }] }],
			tools: [{ googleSearch: {} }],
		};
		if (params.systemInstruction) body.systemInstruction = { role: "system", parts: [{ text: params.systemInstruction }] };
		return body;
	}

	async search(params: GeminiApiSearchParams, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		const model = params.model ?? DEFAULT_GEMINI_SEARCH_MODEL;
		const body = this.buildSearchBody(params);
		const url = `${this.baseUrl}/models/${model}:generateContent?key=${encodeURIComponent(this.apiKey)}`;
		const raw = await requestWithin<GenerateContentResponse>(`Gemini API ${model}:generateContent`, url, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify(body),
		}, { fetchImpl: async (input, init) => {
			const response = await this.fetchImpl(input, init);
			// Gemini emits rate limits and transient server failures; retry once within the request's deadline.
			if (response.status !== 429 && (response.status < 500 || response.status >= 600)) return response;
			await response.body?.cancel();
			try {
				await timers.setTimeout(1000, undefined, { signal: init?.signal ?? undefined });
			} catch (error) {
				init?.signal?.throwIfAborted();
				throw error;
			}
			return await this.fetchImpl(input, init);
		}, signal, timeoutMs: this.timeoutMs });
		const { results, sourceIndices } = await citationsFrom(raw, this.fetchImpl, signal, params.numResults ?? Infinity);
		return {
			answer: answerFrom(raw, sourceIndices),
			results,
			raw,
			metadata: { provider: "gemini", model, query: params.query },
		};
	}
}

export async function geminiSearch(params: GeminiApiSearchParams, options: GeminiApiClientOptions, signal?: AbortSignal): Promise<NormalizedExaResponse> {
	return new GeminiApiClient(options).search(params, signal);
}
