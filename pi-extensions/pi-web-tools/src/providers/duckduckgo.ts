import type { NormalizedExaResponse, NormalizedExaResult } from "./exa.js";

const DUCKDUCKGO_HTML_URL = "https://html.duckduckgo.com/html/";
const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

export interface DuckDuckGoSearchParams {
	query: string;
	numResults?: number;
	includeDomains?: string[];
	excludeDomains?: string[];
}

export interface DuckDuckGoClientOptions {
	fetchImpl?: typeof fetch;
}

function decodeHtml(value: string): string {
	return value
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&quot;/g, '"')
		.replace(/&#39;|&apos;/g, "'")
		.replace(/&nbsp;/g, " ")
		.replace(/&#(\d+);/g, (_match, code) => String.fromCharCode(Number(code)))
		.replace(/&#x([0-9a-f]+);/gi, (_match, code) => String.fromCharCode(Number.parseInt(code, 16)))
		.replace(/&amp;/g, "&");
}

function stripTags(value: string): string {
	return decodeHtml(value.replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
}

function normalizeDuckDuckGoUrl(rawUrl: string): string {
	const decoded = decodeHtml(rawUrl).trim();
	try {
		const absolute = decoded.startsWith("//") ? `https:${decoded}` : new URL(decoded, DUCKDUCKGO_HTML_URL).toString();
		const parsed = new URL(absolute);
		if (parsed.hostname.endsWith("duckduckgo.com") && parsed.pathname === "/l/") {
			const target = parsed.searchParams.get("uddg");
			if (target) return decodeURIComponent(target);
		}
		return absolute;
	} catch {
		return decoded;
	}
}

function addDomainHints(query: string, includeDomains?: string[], excludeDomains?: string[]): string {
	const parts = [query];
	for (const domain of includeDomains ?? []) {
		const clean = domain.trim();
		if (clean) parts.push(`site:${clean}`);
	}
	for (const domain of excludeDomains ?? []) {
		const clean = domain.trim();
		if (clean) parts.push(`-site:${clean}`);
	}
	return parts.join(" ");
}

function looksBlocked(html: string): boolean {
	return /captcha|challenge|verify you are human|are you a robot|unusual traffic/i.test(html);
}

export function parseDuckDuckGoHtml(html: string, limit = 10): NormalizedExaResult[] {
	const results: NormalizedExaResult[] = [];
	const blocks = html.split(/<div[^>]+class=["'][^"']*\bresult\b[^"']*["'][^>]*>/i).slice(1);
	for (const block of blocks) {
		const anchor = block.match(/<a[^>]+class=["'][^"']*\bresult__a\b[^"']*["'][^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/i);
		if (!anchor) continue;
		const url = normalizeDuckDuckGoUrl(anchor[1] ?? "");
		const title = stripTags(anchor[2] ?? "");
		if (!url || !title) continue;
		const snippetMatch = block.match(/<(?:a|div)[^>]+class=["'][^"']*\bresult__snippet\b[^"']*["'][^>]*>([\s\S]*?)<\/(?:a|div)>/i);
		const summary = snippetMatch ? stripTags(snippetMatch[1] ?? "") : undefined;
		results.push({ title, url, summary });
		if (results.length >= limit) break;
	}
	return results;
}

export class DuckDuckGoClient {
	private readonly fetchImpl: typeof fetch;

	constructor(options: DuckDuckGoClientOptions = {}) {
		this.fetchImpl = options.fetchImpl ?? fetch;
	}

	async search(params: DuckDuckGoSearchParams, signal?: AbortSignal): Promise<NormalizedExaResponse> {
		const query = addDomainHints(params.query, params.includeDomains, params.excludeDomains);
		const url = new URL(DUCKDUCKGO_HTML_URL);
		url.searchParams.set("q", query);
		const response = await this.fetchImpl(url.toString(), {
			headers: { "user-agent": USER_AGENT, accept: "text/html,application/xhtml+xml" },
			signal,
		});
		if (!response.ok) throw new Error(`DuckDuckGo request failed (${response.status}): ${await response.text().catch(() => response.statusText)}`);
		const html = await response.text();
		if (looksBlocked(html)) throw new Error("DuckDuckGo search appears blocked or rate limited.");
		const results = parseDuckDuckGoHtml(html, params.numResults ?? 10);
		return { results, raw: html, metadata: { provider: "duckduckgo", query, requestUrl: url.toString() } };
	}
}
