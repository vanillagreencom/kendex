import { requireApiKey } from "../utils/auth.js";
import { requestWithin } from "../utils/deadline.js";
import type { NormalizedExaResponse, NormalizedExaResult } from "./exa.js";

export interface PerplexitySearchParams {
	query: string;
	model?: string;
	numResults?: number;
	includeDomains?: string[];
	excludeDomains?: string[];
	recencyFilter?: "hour" | "day" | "week" | "month" | "year";
	startPublishedDate?: string;
	endPublishedDate?: string;
}

export interface PerplexityClientOptions {
	apiKey?: string;
	baseUrl?: string;
	fetchImpl?: typeof fetch;
	/** Deadline of each request, through its body; DEFAULT_DEADLINE_MS when absent. */
	timeoutMs?: number;
}

const DEFAULT_MODEL = "sonar";

function dedupe<T>(items: T[]): T[] {
	return Array.from(new Set(items));
}

function citationsFrom(raw: any): Array<{ url: string; title?: string }> {
	const list: Array<{ url: string; title?: string }> = [];
	if (Array.isArray(raw?.citations)) {
		for (const item of raw.citations) {
			if (typeof item === "string" && item.trim()) list.push({ url: item.trim() });
			else if (item && typeof item === "object") {
				const url = typeof item.url === "string" ? item.url : undefined;
				if (url) list.push({ url, title: typeof item.title === "string" ? item.title : undefined });
			}
		}
	}
	if (Array.isArray(raw?.search_results)) {
		for (const result of raw.search_results) {
			if (!result || typeof result !== "object") continue;
			const url = typeof result.url === "string" ? result.url : undefined;
			if (!url) continue;
			list.push({ url, title: typeof result.title === "string" ? result.title : undefined });
		}
	}
	return list;
}

function answerFrom(raw: any): string | undefined {
	const message = raw?.choices?.[0]?.message;
	if (typeof message?.content === "string" && message.content.trim()) return message.content.trim();
	if (Array.isArray(message?.content)) {
		const text = message.content.map((part: any) => typeof part?.text === "string" ? part.text : "").join("\n").trim();
		if (text) return text;
	}
	return undefined;
}

export class PerplexityClient {
	private readonly apiKey: string;
	private readonly baseUrl: string;
	private readonly fetchImpl: typeof fetch;
	private readonly timeoutMs: number | undefined;

	constructor(options: PerplexityClientOptions) {
		this.apiKey = requireApiKey(options.apiKey, "Perplexity", "Set PERPLEXITY_API_KEY or PI_WEB_TOOLS_CONFIG_FILE with perplexityApiKey.");
		this.baseUrl = options.baseUrl ?? "https://api.perplexity.ai";
		this.fetchImpl = options.fetchImpl ?? fetch;
		this.timeoutMs = options.timeoutMs;
	}

	buildChatBody(params: PerplexitySearchParams): Record<string, unknown> {
		const body: Record<string, unknown> = {
			model: params.model ?? DEFAULT_MODEL,
			messages: [{ role: "user", content: params.query }],
			return_citations: true,
		};
		if (params.numResults != null) body.search_max_results = params.numResults;
		if (params.includeDomains?.length) body.search_domain_filter = params.includeDomains;
		else if (params.excludeDomains?.length) body.search_domain_filter = params.excludeDomains.map((domain) => `-${domain}`);
		if (params.recencyFilter) body.search_recency_filter = params.recencyFilter;
		if (params.startPublishedDate) body.search_after_date_filter = params.startPublishedDate;
		if (params.endPublishedDate) body.search_before_date_filter = params.endPublishedDate;
		return body;
	}

	async search(params: PerplexitySearchParams, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		const body = this.buildChatBody(params);
		const raw = await requestWithin<any>("Perplexity /chat/completions", `${this.baseUrl}/chat/completions`, {
			method: "POST",
			headers: { "content-type": "application/json", authorization: `Bearer ${this.apiKey}` },
			body: JSON.stringify(body),
		}, { fetchImpl: this.fetchImpl, signal, timeoutMs: this.timeoutMs });
		const answer = answerFrom(raw);
		const citationItems = citationsFrom(raw);
		const seen = new Set<string>();
		const results: NormalizedExaResult[] = [];
		for (const item of citationItems) {
			const key = item.url.trim().toLowerCase();
			if (seen.has(key)) continue;
			seen.add(key);
			results.push({ url: item.url, title: item.title });
		}
		const limit = params.numResults ?? results.length;
		return {
			answer,
			results: results.slice(0, limit),
			raw,
			metadata: { provider: "perplexity", model: body.model, query: params.query, citationCount: results.length },
		};
	}
}

export async function perplexitySearch(params: PerplexitySearchParams, options: PerplexityClientOptions, signal?: AbortSignal): Promise<NormalizedExaResponse> {
	return new PerplexityClient(options).search(params, signal);
}
