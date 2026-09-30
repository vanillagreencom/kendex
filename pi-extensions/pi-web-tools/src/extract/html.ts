import { ByteBudget, readTextWithin } from "./byte-budget.js";

export interface HtmlExtraction {
	title?: string;
	markdown: string;
}

const ENTITY_MAP: Record<string, string> = {
	"&nbsp;": " ",
	"&amp;": "&",
	"&lt;": "<",
	"&gt;": ">",
	"&quot;": '"',
	"&#39;": "'",
	"&apos;": "'",
	"&hellip;": "…",
	"&mdash;": "—",
	"&ndash;": "–",
	"&laquo;": "«",
	"&raquo;": "»",
	"&copy;": "©",
	"&reg;": "®",
	"&trade;": "™",
};

function decodeEntities(text: string): string {
	let out = text;
	for (const [k, v] of Object.entries(ENTITY_MAP)) out = out.split(k).join(v);
	out = out.replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)));
	out = out.replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)));
	return out;
}

const CHROME_CLASS_EXACT = [
	"navbox",
	"sidebar",
	"infobox",
	"hatnote",
	"shortdescription",
	"noprint",
	"thumb",
	"thumbcaption",
	"vertical-navbox",
	"mw-editsection",
	"mw-jump-link",
	"mw-cite-backlink",
	"reflist",
	"catlinks",
	"printfooter",
	"mw-indicator",
	"mw-empty-elt",
	"toc",
	"cookie-banner",
	"cookies-banner",
	"newsletter-signup",
	"share-buttons",
	"social-share",
	"breadcrumbs",
	"pagination",
	"site-header",
	"site-footer",
];

/** Most chrome blocks one document has removed; a document past it keeps the rest. */
const MAX_CHROME_REMOVALS = 500;

function nextTag(re: RegExp, html: string, from: number): RegExpExecArray | null {
	re.lastIndex = from;
	return re.exec(html);
}

/** Removes each chrome-class block with its nested same-name tags, or only its opening tag when it never closes.
 * One pass over the input: kept ranges are collected and joined once, so the document is never copied per removal. */
function stripChromeBlocks(html: string): string {
	const classRe = new RegExp(
		`<(table|div|aside|section|nav|ul|ol|figure)\\b[^>]*class=["'][^"']*(?<![\\w-])(?:${CHROME_CLASS_EXACT.join("|")})(?![\\w-])[^"']*["'][^>]*>`,
		"ig",
	);
	const kept: string[] = [];
	let keptFrom = 0;
	for (let removals = 0; removals < MAX_CHROME_REMOVALS; removals++) {
		const match = nextTag(classRe, html, keptFrom);
		if (!match) break;
		const tag = match[1].toLowerCase();
		const start = match.index;
		const openEnd = start + match[0].length;
		const openRe = new RegExp(`<${tag}\\b[^>]*>`, "ig");
		const closeRe = new RegExp(`</${tag}\\s*>`, "ig");
		let depth = 1;
		let cursor = openEnd;
		let open = nextTag(openRe, html, cursor);
		let close = nextTag(closeRe, html, cursor);
		while (depth > 0 && close) {
			if (open && open.index < close.index) {
				depth++;
				cursor = open.index + open[0].length;
				open = nextTag(openRe, html, cursor);
				if (close.index < cursor) close = nextTag(closeRe, html, cursor);
			} else {
				depth--;
				cursor = close.index + close[0].length;
				close = nextTag(closeRe, html, cursor);
				if (open && open.index < cursor) open = nextTag(openRe, html, cursor);
			}
		}
		kept.push(html.slice(keptFrom, start));
		keptFrom = depth === 0 ? cursor : openEnd;
	}
	kept.push(html.slice(keptFrom));
	return kept.join("");
}

function stripRoleNavigation(html: string): string {
	return html.replace(/<(div|section|nav|aside)\b[^>]*role=["']navigation["'][^>]*>[\s\S]*?<\/\1>/gi, "");
}

export function htmlToMarkdown(html: string): HtmlExtraction {
	const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.replace(/\s+/g, " ").trim();
	let main = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i)?.[1]
		?? html.match(/<article\b[^>]*>([\s\S]*?)<\/article>/i)?.[1]
		?? html.match(/<body\b[^>]*>([\s\S]*?)<\/body>/i)?.[1]
		?? html;
	main = stripRoleNavigation(main);
	main = stripChromeBlocks(main);
	let body = main
		.replace(/<script[\s\S]*?<\/script>/gi, "")
		.replace(/<style[\s\S]*?<\/style>/gi, "")
		.replace(/<noscript[\s\S]*?<\/noscript>/gi, "")
		.replace(/<svg[\s\S]*?<\/svg>/gi, "")
		.replace(/<(header|nav|footer|aside|menu)\b[\s\S]*?<\/\1>/gi, "")
		.replace(/<form\b[\s\S]*?<\/form>/gi, "")
		.replace(/<button\b[\s\S]*?<\/button>/gi, "")
		.replace(/<\/(h[1-6]|p|li|blockquote|pre|tr|div|section|article)>/gi, "\n")
		.replace(/<br\s*\/?>/gi, "\n")
		.replace(/<h1[^>]*>/gi, "\n# ")
		.replace(/<h2[^>]*>/gi, "\n## ")
		.replace(/<h3[^>]*>/gi, "\n### ")
		.replace(/<h4[^>]*>/gi, "\n#### ")
		.replace(/<li[^>]*>/gi, "\n- ")
		.replace(/<a\s+[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi, (_m, href, label) => {
			const text = label.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
			if (!text) return "";
			if (href.startsWith("#")) return text;
			return `${text} (${href})`;
		})
		.replace(/<[^>]+>/g, " ");
	body = decodeEntities(body)
		.replace(/[ \t]+/g, " ")
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter((line) => line && line !== "-" && line !== "•")
		.join("\n")
		.replace(/\n{3,}/g, "\n\n")
		.trim();
	return { title: title ? decodeEntities(title) : undefined, markdown: body };
}

const BLOCKED_PATTERNS: RegExp[] = [
	/please enable javascript/i,
	/enable cookies/i,
	/are you a robot/i,
	/just a moment/i,
	/checking your browser/i,
	/access denied/i,
	/captcha/i,
	/cloudflare/i,
	/perimeterx/i,
	/this page can.t be displayed/i,
	/error 1020/i,
];

export interface QualityAssessment {
	blocked: boolean;
	lowContent: boolean;
	reasons: string[];
}

export function assessExtractionQuality(extraction: HtmlExtraction, rawHtmlLength: number): QualityAssessment {
	const reasons: string[] = [];
	const text = extraction.markdown;
	let blocked = false;
	for (const re of BLOCKED_PATTERNS) {
		if (re.test(text)) {
			blocked = true;
			reasons.push(`blocked-pattern:${re.source}`);
		}
	}
	const lowContent = !blocked && text.length < 400 && rawHtmlLength > 4000;
	if (lowContent) reasons.push(`low-content:${text.length}/${rawHtmlLength}`);
	return { blocked, lowContent, reasons };
}

export interface JinaFetchOptions {
	fetchImpl?: typeof fetch;
	signal?: AbortSignal;
	apiKey?: string;
	byteBudget?: ByteBudget;
}

export interface JinaResult {
	title?: string;
	markdown: string;
	source: "jina";
	/** The byte limit the Jina body was cut at; absent when it was read whole. */
	truncatedAtBytes?: number;
}

export async function fetchViaJina(targetUrl: string, options: JinaFetchOptions = {}): Promise<JinaResult> {
	const fetchImpl = options.fetchImpl ?? fetch;
	const headers: Record<string, string> = { accept: "text/markdown,text/plain,*/*" };
	if (options.apiKey) headers.authorization = `Bearer ${options.apiKey}`;
	const response = await fetchImpl(`https://r.jina.ai/${targetUrl}`, { headers, signal: options.signal });
	if (!response.ok) throw new Error(`Jina Reader fetch failed (${response.status}) for ${targetUrl}`);
	const body = await readTextWithin(response, options.byteBudget ?? new ByteBudget());
	const text = body.text;
	const titleMatch = text.match(/^Title:\s*(.+)$/m);
	const bodyStart = text.indexOf("Markdown Content:");
	const markdown = bodyStart >= 0 ? text.slice(bodyStart + "Markdown Content:".length).trim() : text.trim();
	return { title: titleMatch?.[1]?.trim(), markdown, source: "jina", ...(body.truncatedAtBytes === undefined ? {} : { truncatedAtBytes: body.truncatedAtBytes }) };
}
