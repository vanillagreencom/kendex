import { type CookieMap, buildCookieHeader, readBrowserCookies } from "../utils/browser-cookies.js";
import type { NormalizedExaResponse } from "./exa.js";

const GEMINI_APP_URL = "https://gemini.google.com/app";
const GEMINI_STREAM_GENERATE_URL = "https://gemini.google.com/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate";

const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

const MODEL_HEADER_NAME = "x-goog-ext-525001261-jspb";
const MODEL_HEADERS: Record<string, string> = {
	"gemini-3-pro": '[1,null,null,null,"9d8ca3786ebdfbea",null,null,0,[4]]',
	"gemini-2.5-pro": '[1,null,null,null,"4af6c7f5da75d65d",null,null,0,[4]]',
	"gemini-2.5-flash": '[1,null,null,null,"9ec249fc9ad08861",null,null,0,[4]]',
};

const REQUIRED_COOKIES = ["__Secure-1PSID", "__Secure-1PSIDTS"];

export interface GeminiWebOptions {
	model?: string;
	signal?: AbortSignal;
	timeoutMs?: number;
	preferredBrowser?: "auto" | "firefox" | "zen" | "chrome" | "chromium";
	browserProfile?: string;
	fetchImpl?: typeof fetch;
}

export interface GeminiWebSearchParams {
	query: string;
	numResults?: number;
}

function withTimeout(signal: AbortSignal | undefined, timeoutMs: number): AbortSignal {
	const timeout = AbortSignal.timeout(timeoutMs);
	return signal ? AbortSignal.any([signal, timeout]) : timeout;
}

async function fetchWithRedirects(fetchImpl: typeof fetch, url: string, cookieHeader: string, signal: AbortSignal, maxRedirects = 10): Promise<string> {
	let current = url;
	for (let i = 0; i <= maxRedirects; i++) {
		const res = await fetchImpl(current, { headers: { "user-agent": USER_AGENT, cookie: cookieHeader }, redirect: "manual", signal });
		if (res.status >= 300 && res.status < 400) {
			const location = res.headers.get("location");
			if (location) { current = new URL(location, current).toString(); continue; }
		}
		return await res.text();
	}
	throw new Error(`Too many redirects (>${maxRedirects})`);
}

async function fetchAccessToken(fetchImpl: typeof fetch, cookieHeader: string, signal: AbortSignal): Promise<string> {
	const html = await fetchWithRedirects(fetchImpl, GEMINI_APP_URL, cookieHeader, signal);
	for (const key of ["SNlM0e", "thykhd"]) {
		const match = html.match(new RegExp(`"${key}":"(.*?)"`));
		if (match?.[1]) return match[1];
	}
	throw new Error("Unable to authenticate with Gemini Web. Cookies may be expired or browser is not signed into gemini.google.com.");
}

function trimJsonEnvelope(text: string): string {
	const start = text.indexOf("[");
	const end = text.lastIndexOf("]");
	if (start === -1 || end === -1 || end <= start) throw new Error("Gemini Web response did not contain a JSON payload.");
	return text.slice(start, end + 1);
}

function getNested(value: unknown, path: number[]): unknown {
	let current: unknown = value;
	for (const part of path) {
		if (!Array.isArray(current)) return undefined;
		current = (current as unknown[])[part];
	}
	return current;
}

function parseStreamGenerate(rawText: string): { text: string; errorCode?: number } {
	const root = JSON.parse(trimJsonEnvelope(rawText));
	const errorCodeRaw = getNested(root, [0, 5, 2, 0, 1, 0]);
	const errorCode = typeof errorCodeRaw === "number" && errorCodeRaw >= 0 ? errorCodeRaw : undefined;
	let firstCandidate: unknown = undefined;
	let latestNonEmptyText = "";
	for (const part of Array.isArray(root) ? root : []) {
		const partBody = getNested(part, [2]);
		if (typeof partBody !== "string") continue;
		try {
			const parsed = JSON.parse(partBody);
			const candidates = getNested(parsed, [4]);
			if (!Array.isArray(candidates) || candidates.length === 0) continue;
			const candidate = candidates[0];
			if (firstCandidate === undefined) firstCandidate = candidate;
			const text = candidateText(candidate);
			if (text) latestNonEmptyText = text;
		} catch { /* skip */ }
	}
	const text = latestNonEmptyText || candidateText(firstCandidate);
	return { text, errorCode };
}

function candidateText(candidate: unknown): string {
	const raw = getNested(candidate, [1, 0]);
	let text = typeof raw === "string" ? raw : "";
	const isCardPlaceholder = (value: string) => /^https?:\/\/(?:www\.)?googleusercontent\.com\/card_content\/\d+(?:[/?#].*)?$/i.test(value.trim());
	if (isCardPlaceholder(text)) {
		const alternate = getNested(candidate, [22, 0]);
		text = typeof alternate === "string" && alternate && !isCardPlaceholder(alternate) ? alternate : "";
	}
	return text;
}

function buildFReq(prompt: string): string {
	const inner = JSON.stringify([[prompt], null, null]);
	return JSON.stringify([null, inner]);
}

export class GeminiWebClient {
	private readonly cookies: CookieMap;
	private readonly fetchImpl: typeof fetch;

	constructor(cookies: CookieMap, fetchImpl: typeof fetch = fetch) {
		this.cookies = cookies;
		this.fetchImpl = fetchImpl;
	}

	async query(prompt: string, options: GeminiWebOptions = {}): Promise<string> {
		const model = options.model && MODEL_HEADERS[options.model] ? options.model : "gemini-2.5-flash";
		const timeoutMs = options.timeoutMs ?? 120000;
		const signal = withTimeout(options.signal, timeoutMs);
		const cookieHeader = buildCookieHeader(this.cookies);
		const accessToken = await fetchAccessToken(this.fetchImpl, cookieHeader, signal);
		const params = new URLSearchParams();
		params.set("at", accessToken);
		params.set("f.req", buildFReq(prompt));
		const res = await this.fetchImpl(GEMINI_STREAM_GENERATE_URL, {
			method: "POST",
			headers: {
				"content-type": "application/x-www-form-urlencoded;charset=utf-8",
				origin: "https://gemini.google.com",
				referer: "https://gemini.google.com/",
				"x-same-domain": "1",
				"user-agent": USER_AGENT,
				cookie: cookieHeader,
				[MODEL_HEADER_NAME]: MODEL_HEADERS[model]!,
			},
			body: params.toString(),
			signal,
		});
		const rawText = await res.text();
		if (!res.ok) throw new Error(`Gemini Web request failed (${res.status})`);
		const result = parseStreamGenerate(rawText);
		if (!result.text) throw new Error(`Gemini Web returned empty response${result.errorCode ? ` (errorCode ${result.errorCode})` : ""}`);
		return result.text;
	}
}

function extractCitations(answer: string): Array<{ url: string; title?: string }> {
	const list: Array<{ url: string; title?: string }> = [];
	const seen = new Set<string>();
	const re = /https?:\/\/[^\s)\]'"<>]+/g;
	let match: RegExpExecArray | null;
	while ((match = re.exec(answer)) !== null) {
		const url = match[0]!.replace(/[.,;:!?)]+$/, "");
		const key = url.toLowerCase();
		if (seen.has(key)) continue;
		seen.add(key);
		list.push({ url });
	}
	return list;
}

export async function geminiWebSearch(params: GeminiWebSearchParams, options: GeminiWebOptions = {}): Promise<NormalizedExaResponse> {
	const browserResult = await readBrowserCookies({ preferredBrowser: options.preferredBrowser, profile: options.browserProfile, requiredCookies: REQUIRED_COOKIES });
	if (!browserResult) throw new Error("No browser cookies found for gemini.google.com. Sign into Gemini in Firefox/Zen/Chrome and enable browserCookieAccess.");
	const client = new GeminiWebClient(browserResult.cookies, options.fetchImpl ?? fetch);
	const limit = Math.max(1, Math.floor(params.numResults ?? 5));
	const prompt = `Search the web and answer with citations: ${params.query}\n\nUse at most ${limit} high-quality sources. For each source, include the full URL inline so it can be parsed. Do not include extra source lists beyond the limit.`;
	const answer = await client.query(prompt, options);
	return {
		answer,
		results: extractCitations(answer).slice(0, limit),
		raw: { answer, browser: browserResult.browser },
		metadata: { provider: "gemini-web", browser: browserResult.browser, profile: browserResult.profile, model: options.model ?? "gemini-2.5-flash", numResults: limit },
	};
}

export async function geminiWebFetch(params: { url: string; prompt?: string }, options: GeminiWebOptions = {}): Promise<{ url: string; title?: string; content: string; metadata: Record<string, unknown> }> {
	const browserResult = await readBrowserCookies({ preferredBrowser: options.preferredBrowser, profile: options.browserProfile, requiredCookies: REQUIRED_COOKIES });
	if (!browserResult) throw new Error("No browser cookies found for gemini.google.com.");
	const client = new GeminiWebClient(browserResult.cookies, options.fetchImpl ?? fetch);
	const prompt = `${params.prompt ?? "Extract the readable content of this URL as clean markdown."}\n\nURL: ${params.url}`;
	const content = await client.query(prompt, options);
	return { url: params.url, content, metadata: { provider: "gemini-web", browser: browserResult.browser, profile: browserResult.profile } };
}
