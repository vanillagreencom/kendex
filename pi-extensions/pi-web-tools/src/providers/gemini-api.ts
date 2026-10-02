import { requireApiKey } from "../utils/auth.js";
import { requestWithin } from "../utils/deadline.js";
import type { NormalizedExaResponse, NormalizedExaResult } from "./exa.js";

const DEFAULT_MODEL = "gemini-2.5-flash";
const API_BASE = "https://generativelanguage.googleapis.com/v1beta";

export interface GeminiApiSearchParams {
	query: string;
	model?: string;
	systemInstruction?: string;
	includeDomains?: string[];
	excludeDomains?: string[];
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
			webSearchQueries?: string[];
		};
	}>;
}

function answerFrom(raw: GenerateContentResponse): string | undefined {
	const text = raw.candidates?.[0]?.content?.parts?.map((p) => p?.text).filter(Boolean).join("\n").trim();
	return text || undefined;
}

function citationsFrom(raw: GenerateContentResponse): NormalizedExaResult[] {
	const chunks = raw.candidates?.[0]?.groundingMetadata?.groundingChunks ?? [];
	const seen = new Set<string>();
	const out: NormalizedExaResult[] = [];
	for (const chunk of chunks) {
		const url = chunk.web?.uri;
		if (!url) continue;
		const key = url.trim().toLowerCase();
		if (seen.has(key)) continue;
		seen.add(key);
		out.push({ url, title: chunk.web?.title });
	}
	return out;
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
		].filter(Boolean).join("\n\n");
		const body: Record<string, unknown> = {
			contents: [{ role: "user", parts: [{ text: userText }] }],
			tools: [{ googleSearch: {} }],
		};
		if (params.systemInstruction) body.systemInstruction = { role: "system", parts: [{ text: params.systemInstruction }] };
		return body;
	}

	async search(params: GeminiApiSearchParams, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		const model = params.model ?? DEFAULT_MODEL;
		const body = this.buildSearchBody(params);
		const url = `${this.baseUrl}/models/${model}:generateContent?key=${encodeURIComponent(this.apiKey)}`;
		const raw = await requestWithin<GenerateContentResponse>(`Gemini API ${model}:generateContent`, url, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify(body),
		}, { fetchImpl: this.fetchImpl, signal, timeoutMs: this.timeoutMs });
		return {
			answer: answerFrom(raw),
			results: citationsFrom(raw),
			raw,
			metadata: { provider: "gemini", model, query: params.query },
		};
	}
}

export async function geminiSearch(params: GeminiApiSearchParams, options: GeminiApiClientOptions, signal?: AbortSignal): Promise<NormalizedExaResponse> {
	return new GeminiApiClient(options).search(params, signal);
}
