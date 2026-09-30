import { readTextWithin, truncationMetadata, type BoundedRead, type UrlReads } from "./byte-budget.js";
import { assessExtractionQuality, fetchViaJina, htmlToMarkdown as readableHtmlToMarkdown } from "./html.js";

export interface ExtractedContent {
	url: string;
	title?: string;
	content: string;
	contentType?: string;
	status?: number;
	metadata: Record<string, unknown>;
}

export interface HttpFetchOptions {
	fetchImpl?: typeof fetch;
	textMaxCharacters?: number;
	signal?: AbortSignal;
	jinaFallback?: boolean;
	jinaApiKey?: string;
	/** This URL's reads under the calling web_fetch call's budget; the caller releases them when the URL's processing ends. */
	reads: UrlReads;
}

export const htmlToMarkdown = readableHtmlToMarkdown;

export function isProbablyPdf(url: string, contentType?: string): boolean {
	if (/application\/pdf/i.test(contentType ?? "")) return true;
	try {
		return new URL(url).pathname.toLowerCase().endsWith(".pdf");
	} catch {
		return url.toLowerCase().split(/[?#]/, 1)[0]?.endsWith(".pdf") ?? false;
	}
}

export async function fetchHttpContent(url: string, options: HttpFetchOptions): Promise<ExtractedContent> {
	const fetchImpl = options.fetchImpl ?? fetch;
	const response = await fetchImpl(url, { signal: options.signal });
	const contentType = response.headers.get("content-type") ?? undefined;
	const chain: string[] = [];
	const metadata: Record<string, unknown> = { contentType, status: response.status };
	if (!response.ok) {
		if (options.jinaFallback && (response.status === 403 || response.status === 429 || response.status >= 500)) {
			chain.push(`http:${response.status}`);
			try {
				const jina = await fetchViaJina(url, { fetchImpl, signal: options.signal, apiKey: options.jinaApiKey, reads: options.reads });
				chain.push("jina");
				let content = jina.markdown;
				if (options.textMaxCharacters && content.length > options.textMaxCharacters) content = content.slice(0, options.textMaxCharacters);
				return { url, title: jina.title, content, contentType, status: response.status, metadata: { ...metadata, ...truncationMetadata(jina.cut), extraction: "jina", extractionChain: chain } };
			} catch (error) {
				chain.push("jina-failed");
				throw new Error(`HTTP fetch failed (${response.status}) and Jina fallback failed: ${error instanceof Error ? error.message : String(error)}`);
			}
		}
		throw new Error(`HTTP fetch failed (${response.status}) for ${url}`);
	}
	const body = await readTextWithin(response, options.reads);
	const raw = body.text;
	let cut: BoundedRead["cut"] = body.cut;
	let title: string | undefined;
	let content = raw;
	let extraction = "text";
	if (/html/i.test(contentType ?? "") || /<html[\s>]/i.test(raw)) {
		const extracted = htmlToMarkdown(raw);
		title = extracted.title;
		content = extracted.markdown;
		extraction = "html-basic";
		chain.push("html-basic");
		if (options.jinaFallback) {
			const quality = assessExtractionQuality({ title, markdown: content }, raw.length);
			if (quality.blocked || quality.lowContent) {
				metadata.fallbackReasons = quality.reasons;
				try {
					const jina = await fetchViaJina(url, { fetchImpl, signal: options.signal, apiKey: options.jinaApiKey, reads: options.reads });
					title = jina.title ?? title;
					content = jina.markdown;
					cut = jina.cut;
					extraction = "jina";
					chain.push("jina");
				} catch (error) {
					metadata.jinaError = error instanceof Error ? error.message : String(error);
					chain.push("jina-failed");
				}
			}
		}
	} else if (/json/i.test(contentType ?? "")) {
		try { content = JSON.stringify(JSON.parse(raw), null, 2); extraction = "json"; }
		catch { extraction = "json-raw"; }
		chain.push(extraction);
	} else {
		chain.push("text");
	}
	if (options.textMaxCharacters && content.length > options.textMaxCharacters) content = content.slice(0, options.textMaxCharacters);
	return { url, title, content, contentType, status: response.status, metadata: { ...metadata, ...truncationMetadata(cut), extraction, extractionChain: chain } };
}
