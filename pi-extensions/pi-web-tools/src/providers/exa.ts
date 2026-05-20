import { requireApiKey } from "../utils/auth.js";

export type ExaDeepType = "deep-reasoning" | "deep-lite" | "deep";

export interface ExaSearchParams {
	query: string;
	type?: "auto" | "keyword" | "neural" | ExaDeepType;
	category?: string;
	numResults?: number;
	textMaxCharacters?: number;
	highlightsMaxCharacters?: number;
	highlightNumSentences?: number;
	highlightsPerUrl?: number;
	summaryQuery?: string;
	maxAgeHours?: number;
	includeDomains?: string[];
	excludeDomains?: string[];
	startPublishedDate?: string;
	endPublishedDate?: string;
	additionalQueries?: string[];
	systemPrompt?: string;
	outputSchema?: Record<string, unknown>;
}

export interface ExaContentsParams {
	urls: string[];
	textMaxCharacters?: number;
}

export interface ExaClientOptions {
	apiKey?: string;
	baseUrl?: string;
	fetchImpl?: typeof fetch;
}

export interface NormalizedExaResult {
	title?: string;
	url?: string;
	text?: string;
	summary?: string;
	highlights?: string[];
	publishedDate?: string;
}

export interface NormalizedExaResponse {
	answer?: string;
	results: NormalizedExaResult[];
	raw: unknown;
	metadata: Record<string, unknown>;
}

function normalizeResults(raw: any): NormalizedExaResult[] {
	const results = Array.isArray(raw?.results) ? raw.results : Array.isArray(raw?.sources) ? raw.sources : [];
	return results.map((result: any) => ({
		title: typeof result.title === "string" ? result.title : undefined,
		url: typeof result.url === "string" ? result.url : undefined,
		text: typeof result.text === "string" ? result.text : typeof result.contents === "string" ? result.contents : undefined,
		summary: typeof result.summary === "string" ? result.summary : undefined,
		highlights: Array.isArray(result.highlights) ? result.highlights.filter((item: unknown) => typeof item === "string") : undefined,
		publishedDate: typeof result.publishedDate === "string" ? result.publishedDate : undefined,
	}));
}

function synthesized(raw: any): string | undefined {
	const outputContent = raw?.output?.content;
	if (typeof outputContent === "string" && outputContent.trim()) return outputContent;
	if (outputContent && typeof outputContent === "object") return structuredContentToMarkdown(outputContent);
	for (const key of ["answer", "summary", "output", "research", "text"]) {
		if (typeof raw?.[key] === "string" && raw[key].trim()) return raw[key];
	}
	if (typeof raw?.data?.answer === "string") return raw.data.answer;
	return undefined;
}

function linesFrom(value: unknown): string[] {
	if (Array.isArray(value)) return value.map((item) => typeof item === "string" ? item : JSON.stringify(item)).filter(Boolean);
	if (typeof value === "string" && value.trim()) return [value.trim()];
	return [];
}

function structuredContentToMarkdown(content: Record<string, unknown>): string | undefined {
	const parts: string[] = [];
	const summary = typeof content.executiveSummary === "string" ? content.executiveSummary : typeof content.summary === "string" ? content.summary : undefined;
	if (summary?.trim()) parts.push(summary.trim());
	const keyFindings = linesFrom(content.keyFindings ?? content.findings);
	if (keyFindings.length) parts.push(keyFindings.map((item) => `- ${item}`).join("\n"));
	const recommendation = typeof content.recommendation === "string" ? content.recommendation : undefined;
	if (recommendation?.trim()) parts.push(recommendation.trim());
	if (parts.length) return parts.join("\n\n");
	try { return JSON.stringify(content); }
	catch { return undefined; }
}

export class ExaClient {
	private readonly apiKey: string;
	private readonly baseUrl: string;
	private readonly fetchImpl: typeof fetch;

	constructor(options: ExaClientOptions) {
		this.apiKey = requireApiKey(options.apiKey, "Exa", "Set EXA_API_KEY or PI_WEB_TOOLS_CONFIG_FILE with exaApiKey.");
		this.baseUrl = options.baseUrl ?? "https://api.exa.ai";
		this.fetchImpl = options.fetchImpl ?? fetch;
	}

	private async post(path: string, body: Record<string, unknown>, signal?: AbortSignal): Promise<any> {
		const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
			method: "POST",
			headers: { "content-type": "application/json", "x-api-key": this.apiKey },
			body: JSON.stringify(body),
			signal,
		});
		if (!response.ok) {
			const text = await response.text().catch(() => "");
			throw new Error(`Exa request failed (${response.status}): ${text || response.statusText}`);
		}
		return response.json();
	}

	buildSearchBody(params: ExaSearchParams): Record<string, unknown> {
		const highlightsOptions: Record<string, unknown> = {};
		if (params.highlightsMaxCharacters != null) highlightsOptions.maxCharacters = params.highlightsMaxCharacters;
		if (params.highlightNumSentences != null) highlightsOptions.numSentences = params.highlightNumSentences;
		if (params.highlightsPerUrl != null) highlightsOptions.highlightsPerUrl = params.highlightsPerUrl;
		const highlights = Object.keys(highlightsOptions).length ? highlightsOptions : true;
		const contents: Record<string, unknown> = { text: { maxCharacters: params.textMaxCharacters ?? 12000 }, highlights };
		if (params.summaryQuery) contents.summary = { query: params.summaryQuery };
		const body: Record<string, unknown> = {
			query: params.query,
			type: params.type ?? "auto",
			numResults: params.numResults ?? 10,
			contents,
		};
		if (params.category) body.category = params.category;
		if (params.maxAgeHours != null) body.maxAgeHours = params.maxAgeHours;
		if (params.includeDomains?.length) body.includeDomains = params.includeDomains;
		if (params.excludeDomains?.length) body.excludeDomains = params.excludeDomains;
		if (params.startPublishedDate) body.startPublishedDate = params.startPublishedDate;
		if (params.endPublishedDate) body.endPublishedDate = params.endPublishedDate;
		if (params.additionalQueries?.length) body.additionalQueries = params.additionalQueries;
		if (params.systemPrompt) body.systemPrompt = params.systemPrompt;
		if (params.outputSchema) body.outputSchema = params.outputSchema;
		return body;
	}

	async search(params: ExaSearchParams, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		const raw = await this.post("/search", this.buildSearchBody(params), signal);
		return { answer: synthesized(raw), results: normalizeResults(raw), raw, metadata: { request: this.buildSearchBody(params) } };
	}

	async contents(params: ExaContentsParams, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		// Default contents text cap is intentionally lower than search/findSimilar:
		// `web_fetch` callers can pass dozens of URLs in one call, and the previously-12k
		// default produced hundreds of KB of inlined preview that blew the model input window.
		// Callers can opt back into larger payloads with `textMaxCharacters`.
		const raw = await this.post("/contents", { urls: params.urls, text: { maxCharacters: params.textMaxCharacters ?? 6000 } }, signal);
		return { answer: synthesized(raw), results: normalizeResults(raw), raw, metadata: { urls: params.urls } };
	}

	async answer(query: string, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		const raw = await this.post("/answer", { query, text: true }, signal);
		return { answer: synthesized(raw), results: normalizeResults(raw), raw, metadata: { query } };
	}

	async findSimilar(url: string, options: Omit<ExaSearchParams, "query"> = {}, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		const raw = await this.post("/findSimilar", { url, numResults: options.numResults ?? 10, contents: { text: { maxCharacters: options.textMaxCharacters ?? 12000 }, highlights: true } }, signal);
		return { answer: synthesized(raw), results: normalizeResults(raw), raw, metadata: { url } };
	}

	async deepResearch(params: ExaSearchParams & { type: ExaDeepType }, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		return this.search(params, signal);
	}

	async codeContext(query: string, tokensNum: number | "dynamic" = "dynamic", signal?: AbortSignal): Promise<{ raw: any; text: string; resultsCount?: number; outputTokens?: number }> {
		const raw = await this.post("/context", { query, tokensNum }, signal);
		return {
			raw,
			text: typeof raw?.response === "string" ? raw.response : "",
			resultsCount: typeof raw?.resultsCount === "number" ? raw.resultsCount : undefined,
			outputTokens: typeof raw?.outputTokens === "number" ? raw.outputTokens : undefined,
		};
	}
}
