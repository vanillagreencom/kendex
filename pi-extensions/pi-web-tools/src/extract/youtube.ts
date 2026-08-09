import { GeminiApiClient } from "../providers/gemini-api.js";
import { GeminiWebClient } from "../providers/gemini-web.js";
import { readBrowserCookies, type ReadCookiesOptions } from "../utils/browser-cookies.js";
import { fetchTranscript, type TranscriptConfig, type TranscriptResult, type TranscriptSegment } from "youtube-transcript-plus";

const YOUTUBE_HOSTS = new Set(["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com"]);

export interface ParsedYouTubeUrl {
	videoId: string;
	canonicalUrl: string;
	kind: "watch" | "short" | "live" | "embed" | "v";
}

export function parseYouTubeUrl(input: string): ParsedYouTubeUrl | undefined {
	let url: URL;
	try { url = new URL(input); } catch { return undefined; }
	if (!YOUTUBE_HOSTS.has(url.hostname)) return undefined;
	if (url.hostname === "youtu.be") {
		const id = url.pathname.split("/").filter(Boolean)[0];
		if (id) return { videoId: id, canonicalUrl: `https://www.youtube.com/watch?v=${id}`, kind: "watch" };
	}
	const watch = url.searchParams.get("v");
	if (watch) return { videoId: watch, canonicalUrl: `https://www.youtube.com/watch?v=${watch}`, kind: "watch" };
	const parts = url.pathname.split("/").filter(Boolean);
	if (parts.length >= 2) {
		const [marker, id] = parts;
		if (marker === "shorts" && id) return { videoId: id, canonicalUrl: `https://www.youtube.com/shorts/${id}`, kind: "short" };
		if (marker === "live" && id) return { videoId: id, canonicalUrl: `https://www.youtube.com/live/${id}`, kind: "live" };
		if (marker === "embed" && id) return { videoId: id, canonicalUrl: `https://www.youtube.com/embed/${id}`, kind: "embed" };
		if (marker === "v" && id) return { videoId: id, canonicalUrl: `https://www.youtube.com/watch?v=${id}`, kind: "v" };
	}
	return undefined;
}

export interface YouTubeExtractOptions {
	prompt?: string;
	mode?: "auto" | "transcript" | "understand";
	transcriptLanguage?: string;
	geminiApiKey?: string;
	geminiModel?: string;
	browserCookies?: ReadCookiesOptions;
	preferGeminiWeb?: boolean;
	transcriptFetcher?: YouTubeTranscriptFetcher;
	signal?: AbortSignal;
	timeoutMs?: number;
	fetchImpl?: typeof fetch;
}

export type YouTubeTranscriptFetcher = (
	videoId: string,
	config: TranscriptConfig & { videoDetails: true },
) => Promise<TranscriptResult>;

export interface YouTubeExtractResult {
	videoId: string;
	url: string;
	title: string;
	content: string;
	source: "youtube-captions" | "gemini-web" | "gemini-api";
	metadata: Record<string, unknown>;
}

const DEFAULT_PROMPT = "Provide a structured summary of the video: title (if shown), key topics, important quotes, and any visual details. Include approximate timestamps for major sections.";

const TRANSCRIPT_KEYWORDS = /\b(transcript(?:ion|s|ed|ing)?|transcrib(?:e|ed|es|ing|er|ers)|verbatim|subtitles?|captions?|lyrics?)\b/i;
const TIMESTAMP_DIRECTIVE = "\n\nFormat the output as a transcript with [HH:MM:SS] timestamps at every line break (every 10-15 seconds). Include spoken dialogue, lyrics, and notable visual cues. Do not omit timestamps.";

export function isTranscriptPrompt(input: string | undefined): boolean {
	return Boolean(input && TRANSCRIPT_KEYWORDS.test(input));
}

function enhancePrompt(input: string | undefined): string {
	const base = input ?? DEFAULT_PROMPT;
	if (isTranscriptPrompt(input) && !/\[hh:mm/i.test(input!)) return base + TIMESTAMP_DIRECTIVE;
	return base;
}

function decodeHtmlEntities(text: string): string {
	const decodeNumericEntity = (match: string, digits: string, radix: number): string => {
		const codePoint = Number.parseInt(digits, radix);
		if (!Number.isInteger(codePoint) || codePoint < 0 || codePoint > 0x10ffff || (codePoint >= 0xd800 && codePoint <= 0xdfff)) return match;
		return String.fromCodePoint(codePoint);
	};
	return text
		.replace(/&#x([0-9a-f]+);/gi, (match, hex: string) => decodeNumericEntity(match, hex, 16))
		.replace(/&#(\d+);/g, (match, code: string) => decodeNumericEntity(match, code, 10))
		.replace(/&quot;/g, '"')
		.replace(/&apos;|&#39;/g, "'")
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&amp;/g, "&");
}

function transcriptTimestamp(offsetSeconds: number): string {
	const whole = Math.max(0, Math.floor(offsetSeconds));
	const hours = String(Math.floor(whole / 3600)).padStart(2, "0");
	const minutes = String(Math.floor((whole % 3600) / 60)).padStart(2, "0");
	const seconds = String(whole % 60).padStart(2, "0");
	return `[${hours}:${minutes}:${seconds}]`;
}

export function formatYouTubeTranscript(segments: TranscriptSegment[]): string {
	return segments
		.map((segment) => {
			const text = decodeHtmlEntities(segment.text).replace(/\s+/g, " ").trim();
			return text ? `${transcriptTimestamp(segment.offset)} ${text}` : "";
		})
		.filter(Boolean)
		.join("\n");
}

function isAbortError(error: unknown, signal: AbortSignal | undefined): boolean {
	return Boolean(signal?.aborted || (error && typeof error === "object" && "name" in error && (error as { name?: unknown }).name === "AbortError"));
}

function availableTranscriptLanguages(error: unknown): string[] | undefined {
	if (!error || typeof error !== "object" || !("name" in error) || (error as { name?: unknown }).name !== "YoutubeTranscriptNotAvailableLanguageError" || !("availableLangs" in error)) return undefined;
	const available = (error as { availableLangs?: unknown }).availableLangs;
	return Array.isArray(available) && available.every((lang) => typeof lang === "string") ? available : undefined;
}

async function tryYouTubeCaptions(parsed: ParsedYouTubeUrl, options: YouTubeExtractOptions): Promise<YouTubeExtractResult> {
	const transcriptFetcher = options.transcriptFetcher ?? fetchTranscript;
	const fetchCaptions = (lang: string | undefined) => transcriptFetcher(parsed.videoId, {
		...(lang !== undefined ? { lang } : {}),
		videoDetails: true,
		retries: 2,
		retryDelay: 500,
		signal: options.signal,
	});
	let selectedLanguage = options.transcriptLanguage;
	let result: TranscriptResult;
	try {
		result = await fetchCaptions(selectedLanguage);
	} catch (error) {
		const available = availableTranscriptLanguages(error);
		if (!available || selectedLanguage === undefined) throw error;
		const requested = selectedLanguage.toLowerCase();
		const recovered = available.find((lang) => lang.toLowerCase() === requested)
			?? available.find((lang) => {
				const candidate = lang.toLowerCase();
				return candidate.startsWith(`${requested}-`) || requested.startsWith(`${candidate}-`);
			});
		if (!recovered) throw error;
		selectedLanguage = recovered;
		result = await fetchCaptions(recovered);
	}
	const content = formatYouTubeTranscript(result.segments);
	if (!content) throw new Error("YouTube returned no caption segments.");
	return {
		videoId: parsed.videoId,
		url: parsed.canonicalUrl,
		title: result.videoDetails.title || `YouTube ${parsed.kind} ${parsed.videoId}`,
		content,
		source: "youtube-captions",
		metadata: {
			provider: "youtube-captions",
			contentKind: "full-transcript",
			videoId: parsed.videoId,
			kind: parsed.kind,
			language: result.segments[0]?.lang ?? selectedLanguage,
			captionSegments: result.segments.length,
			durationSeconds: result.videoDetails.lengthSeconds,
			author: result.videoDetails.author,
			channelId: result.videoDetails.channelId,
		},
	};
}

async function tryGeminiWeb(parsed: ParsedYouTubeUrl, options: YouTubeExtractOptions): Promise<YouTubeExtractResult | undefined> {
	const cookies = await readBrowserCookies({ ...(options.browserCookies ?? {}), requiredCookies: ["__Secure-1PSID", "__Secure-1PSIDTS"] });
	if (!cookies) return undefined;
	const client = new GeminiWebClient(cookies.cookies, options.fetchImpl ?? fetch);
	const prompt = `${enhancePrompt(options.prompt)}\n\nYouTube video: ${parsed.canonicalUrl}`;
	const text = await client.query(prompt, { model: options.geminiModel, signal: options.signal, timeoutMs: options.timeoutMs });
	return {
		videoId: parsed.videoId,
		url: parsed.canonicalUrl,
		title: `YouTube ${parsed.kind} ${parsed.videoId}`,
		content: text,
		source: "gemini-web",
		metadata: { provider: "gemini-web", browser: cookies.browser, profile: cookies.profile, videoId: parsed.videoId, kind: parsed.kind },
	};
}

async function tryGeminiApi(parsed: ParsedYouTubeUrl, options: YouTubeExtractOptions): Promise<YouTubeExtractResult | undefined> {
	if (!options.geminiApiKey) return undefined;
	const client = new GeminiApiClient({ apiKey: options.geminiApiKey, fetchImpl: options.fetchImpl });
	const model = options.geminiModel ?? "gemini-2.5-flash";
	const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${encodeURIComponent(options.geminiApiKey)}`;
	const body = {
		contents: [{ role: "user", parts: [{ fileData: { fileUri: parsed.canonicalUrl, mimeType: "video/mp4" } }, { text: enhancePrompt(options.prompt) }] }],
	};
	const fetchImpl = options.fetchImpl ?? fetch;
	const response = await fetchImpl(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: options.signal });
	if (!response.ok) {
		const text = await response.text().catch(() => "");
		throw new Error(`Gemini API video request failed (${response.status}): ${text || response.statusText}`);
	}
	const raw = await response.json() as any;
	const text = raw?.candidates?.[0]?.content?.parts?.map((p: any) => p?.text).filter(Boolean).join("\n").trim() ?? "";
	if (!text) throw new Error("Gemini API returned empty response for YouTube video.");
	void client;
	return {
		videoId: parsed.videoId,
		url: parsed.canonicalUrl,
		title: `YouTube ${parsed.kind} ${parsed.videoId}`,
		content: text,
		source: "gemini-api",
		metadata: { provider: "gemini-api", model, videoId: parsed.videoId, kind: parsed.kind },
	};
}

export async function extractYouTubeUrl(input: string, options: YouTubeExtractOptions = {}): Promise<YouTubeExtractResult | undefined> {
	const parsed = parseYouTubeUrl(input);
	if (!parsed) return undefined;
	const transcriptRequested = options.mode === "transcript" || (options.mode !== "understand" && isTranscriptPrompt(options.prompt));
	if (transcriptRequested) return await tryYouTubeCaptions(parsed, options);
	const order: Array<() => Promise<YouTubeExtractResult | undefined>> = options.preferGeminiWeb === false
		? [() => tryGeminiApi(parsed, options), () => tryGeminiWeb(parsed, options)]
		: [() => tryGeminiWeb(parsed, options), () => tryGeminiApi(parsed, options)];
	const errors: string[] = [];
	for (const attempt of order) {
		try {
			const result = await attempt();
			if (result) return result;
		} catch (error) {
			if (isAbortError(error, options.signal)) throw error;
			errors.push(error instanceof Error ? error.message : String(error));
		}
	}
	throw new Error(`YouTube extraction failed for ${parsed.canonicalUrl}: ${errors.join("; ") || "no provider available"}`);
}
