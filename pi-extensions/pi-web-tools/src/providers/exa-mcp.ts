import { DEFAULT_DEADLINE_MS, withDeadline } from "../utils/deadline.js";
import type { NormalizedExaResponse, NormalizedExaResult } from "./exa.js";

const EXA_MCP_URL = "https://mcp.exa.ai/mcp";

export interface ExaMcpSearchParams {
	query: string;
	numResults?: number;
	textMaxCharacters?: number;
	includeDomains?: string[];
	excludeDomains?: string[];
	startPublishedDate?: string;
	endPublishedDate?: string;
	includeContent?: boolean;
}

export interface ExaMcpClientOptions {
	baseUrl?: string;
	fetchImpl?: typeof fetch;
	/** Deadline of each request, through its body; DEFAULT_DEADLINE_MS when absent. */
	timeoutMs?: number;
}

interface ExaMcpRpcResponse {
	result?: { content?: Array<{ type?: string; text?: string }>; isError?: boolean };
	error?: { code?: number; message?: string };
}

function parseRpcBody(body: string): ExaMcpRpcResponse | undefined {
	for (const line of body.split(/\r?\n/)) {
		if (!line.startsWith("data:")) continue;
		const data = line.slice(5).trim();
		if (!data) continue;
		try {
			const parsed = JSON.parse(data) as ExaMcpRpcResponse;
			if (parsed.result || parsed.error) return parsed;
		} catch {
			// ignore non-JSON event payloads
		}
	}
	try {
		const parsed = JSON.parse(body) as ExaMcpRpcResponse;
		if (parsed.result || parsed.error) return parsed;
	} catch {
		// ignore non-JSON body
	}
	return undefined;
}

function firstText(response: ExaMcpRpcResponse): string | undefined {
	return response.result?.content
		?.find((item) => item.type === "text" && typeof item.text === "string" && item.text.trim())
		?.text?.trim();
}

export function parseExaMcpText(text: string): NormalizedExaResult[] {
	const blocks = text.split(/(?=^Title:\s*)/m).filter((block) => block.trim());
	const results: NormalizedExaResult[] = [];
	for (const block of blocks) {
		const title = block.match(/^Title:\s*(.+)$/m)?.[1]?.trim();
		const url = block.match(/^URL:\s*(.+)$/m)?.[1]?.trim();
		if (!url) continue;
		const publishedDate = block.match(/^Published:\s*(.+)$/m)?.[1]?.trim();
		let content = "";
		const textStart = block.search(/^Text:\s*/m);
		if (textStart >= 0) {
			content = block.slice(textStart).replace(/^Text:\s*/m, "").trim();
		} else {
			const highlightsStart = block.search(/^Highlights:\s*$/m);
			if (highlightsStart >= 0) content = block.slice(highlightsStart).replace(/^Highlights:\s*$/m, "").trim();
		}
		content = content.replace(/\n---\s*$/m, "").trim();
		const highlights = content ? content.split(/\n(?:\[\.\.\.\]\n)?/).map((item) => item.trim()).filter(Boolean).slice(0, 6) : undefined;
		results.push({ title: title || url, url, text: content || undefined, highlights, publishedDate: publishedDate && publishedDate !== "N/A" ? publishedDate : undefined });
	}
	return results;
}

function buildQuery(params: ExaMcpSearchParams): string {
	const parts = [params.query];
	for (const domain of params.includeDomains ?? []) {
		const clean = domain.trim();
		if (clean) parts.push(`site:${clean}`);
	}
	for (const domain of params.excludeDomains ?? []) {
		const clean = domain.trim();
		if (clean) parts.push(`-site:${clean}`);
	}
	if (params.startPublishedDate) parts.push(`after:${params.startPublishedDate}`);
	if (params.endPublishedDate) parts.push(`before:${params.endPublishedDate}`);
	return parts.join(" ");
}

export class ExaMcpClient {
	private readonly baseUrl: string;
	private readonly fetchImpl: typeof fetch;
	private readonly timeoutMs: number;

	constructor(options: ExaMcpClientOptions = {}) {
		this.baseUrl = options.baseUrl ?? EXA_MCP_URL;
		this.fetchImpl = options.fetchImpl ?? fetch;
		this.timeoutMs = options.timeoutMs ?? DEFAULT_DEADLINE_MS;
	}

	async search(params: ExaMcpSearchParams, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		const query = buildQuery(params);
		const body = {
			jsonrpc: "2.0",
			id: 1,
			method: "tools/call",
			params: {
				name: "web_search_exa",
				arguments: {
					query,
					numResults: params.numResults ?? 10,
					livecrawl: "fallback",
					type: "auto",
					contextMaxCharacters: params.includeContent ? params.textMaxCharacters ?? 12000 : Math.min(params.textMaxCharacters ?? 3000, 3000),
				},
			},
		};
		const responseBody = await withDeadline(signal, this.timeoutMs, "Exa MCP web_search_exa", async (deadline) => {
			const response = await this.fetchImpl(this.baseUrl, {
				method: "POST",
				headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
				body: JSON.stringify(body),
				signal: deadline,
			});
			const responseBody = await response.text();
			if (!response.ok) throw new Error(`Exa MCP request failed (${response.status}): ${responseBody.slice(0, 500) || response.statusText}`);
			return responseBody;
		});
		const parsed = parseRpcBody(responseBody);
		if (!parsed) throw new Error("Exa MCP returned an empty response.");
		if (parsed.error) throw new Error(`Exa MCP error${typeof parsed.error.code === "number" ? ` ${parsed.error.code}` : ""}: ${parsed.error.message || "Unknown error"}`);
		if (parsed.result?.isError) throw new Error(firstText(parsed) || "Exa MCP returned an error.");
		const text = firstText(parsed);
		if (!text) throw new Error("Exa MCP returned empty content.");
		return { results: parseExaMcpText(text), raw: parsed, metadata: { provider: "exa-mcp", query, request: body } };
	}
}

export async function exaMcpAvailable(): Promise<boolean> {
	return true;
}
