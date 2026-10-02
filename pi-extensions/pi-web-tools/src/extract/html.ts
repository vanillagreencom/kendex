import { readTextWithin, type BoundedRead, type UrlReads } from "./byte-budget.js";

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

/** The index after the next closing tag of each name, found by one forward search per name that later lookups reuse while
 * they start at or before the tag it found. */
class ClosingTags {
	readonly #html: string;
	/** Per name: the lookup start the search ran from, and where its closing tag is, or -1 when none follows that start. */
	readonly #found = new Map<string, { from: number; at: number; re: RegExp }>();

	constructor(html: string) {
		this.#html = html;
	}

	/** The index after the first closing tag of `name` at or after `from`, or -1 when none follows. */
	after(name: string, from: number): number {
		const key = name.toLowerCase();
		let entry = this.#found.get(key);
		if (!entry) {
			entry = { from: -1, at: -1, re: new RegExp(`</${key}>`, "ig") };
			this.#found.set(key, entry);
		}
		if (entry.from >= 0 && from >= entry.from && (entry.at < 0 || from <= entry.at)) return entry.at < 0 ? -1 : entry.at + key.length + 3;
		const found = nextTag(entry.re, this.#html, from);
		entry.from = from;
		entry.at = found ? found.index : -1;
		return found ? entry.re.lastIndex : -1;
	}
}

const SCRIPT_LIKE_OPEN = /<(script|style|noscript|svg)/gi;

/** Removes each script, style, noscript and svg block, from its opening name to its first closing tag, in one pass before the
 * tag scan, so a closing tag written inside one (`'</form>'` in a script) never ends the block around it. An opening name with
 * no closing tag after it stays, and the scan reads it as any other tag. */
function stripScriptLikeBlocks(html: string): string {
	const closes = new ClosingTags(html);
	const kept: string[] = [];
	let keptFrom = 0;
	let from = 0;
	for (let open = nextTag(SCRIPT_LIKE_OPEN, html, from); open; open = nextTag(SCRIPT_LIKE_OPEN, html, from)) {
		const close = closes.after(open[1]!, SCRIPT_LIKE_OPEN.lastIndex);
		if (close < 0) {
			from = SCRIPT_LIKE_OPEN.lastIndex;
			continue;
		}
		kept.push(html.slice(keptFrom, open.index));
		keptFrom = from = close;
	}
	kept.push(html.slice(keptFrom));
	return kept.join("");
}

/** The markup rule for the tag at a `<`, tried in this order. Groups: 1 a block dropped with its content; 2 a block's closing
 * tag; 3 a line break; 4 a heading level; 5 a list item; 6 a link's href; 7 any other tag. A dropped block without a closing tag
 * after it counts as any other tag. */
const TAG_RULE = /<(?:(header|nav|footer|aside|menu|form|button)\b|\/(?:h[1-6]|p|li|blockquote|pre|tr|div|section|article)>()|br\s*\/?>()|h([1-4])[^>]*>|li[^>]*>()|a\s+[^>]*href=["']([^"']+)["'][^>]*>|[^>]+>())/iy;
const HEADING_PREFIX = ["", "\n# ", "\n## ", "\n### ", "\n#### "];
const LINK_CLOSE = /<\/a>/iy;

/** Converts the tags of one document to markdown text in a single left-to-right scan, building the output once. */
class MarkupScan {
	readonly #html: string;
	readonly #closes: ClosingTags;
	/** Set once a link reaches no closing tag: none is left for any later link either. */
	#noLinkClose = false;

	constructor(html: string) {
		this.#html = html;
		this.#closes = new ClosingTags(html);
	}

	/** The markdown text of the whole document, entities not yet decoded. */
	convert(): string {
		const out: string[] = [];
		this.#scan(0, out, false);
		return out.join("");
	}

	/** Appends the text from `from` on to `out`. Inside a link it stops at the link's closing tag and returns the index after it,
	 * or -1 when none follows; otherwise it returns the document's length. */
	#scan(from: number, out: string[], inLink: boolean): number {
		const html = this.#html;
		let cursor = from;
		for (;;) {
			const lt = html.indexOf("<", cursor);
			if (lt < 0) {
				out.push(html.slice(cursor));
				return inLink ? -1 : html.length;
			}
			if (lt > cursor) out.push(html.slice(cursor, lt));
			if (inLink) {
				LINK_CLOSE.lastIndex = lt;
				if (LINK_CLOSE.test(html)) return LINK_CLOSE.lastIndex;
			}
			TAG_RULE.lastIndex = lt;
			const match = TAG_RULE.exec(html);
			if (!match) {
				out.push("<");
				cursor = lt + 1;
				continue;
			}
			cursor = TAG_RULE.lastIndex;
			const dropped = match[1];
			if (dropped !== undefined) {
				const close = this.#closes.after(dropped, cursor);
				if (close >= 0) {
					cursor = close;
					continue;
				}
				const gt = html.indexOf(">", cursor);
				if (gt < 0) {
					out.push(html.slice(lt));
					return inLink ? -1 : html.length;
				}
				if (!inLink) out.push(" ");
				cursor = gt + 1;
			} else if (match[2] !== undefined || match[3] !== undefined) out.push("\n");
			else if (match[4] !== undefined) out.push(HEADING_PREFIX[Number(match[4])]!);
			else if (match[5] !== undefined) out.push("\n- ");
			else if (match[6] !== undefined && !inLink) cursor = this.#link(lt, cursor, match[6], out);
			else if (!inLink) out.push(" ");
		}
	}

	/** Replaces a link with its text and href, or with a space for its opening tag alone when no closing tag follows. */
	#link(lt: number, openEnd: number, href: string, out: string[]): number {
		const html = this.#html;
		const next = html.indexOf("<", openEnd);
		LINK_CLOSE.lastIndex = Math.max(next, 0);
		let content: string;
		let end: number;
		if (next >= 0 && LINK_CLOSE.test(html)) {
			content = html.slice(openEnd, next);
			end = LINK_CLOSE.lastIndex;
		} else {
			const pieces: string[] = [];
			end = this.#noLinkClose ? -1 : this.#scan(openEnd, pieces, true);
			if (end < 0) {
				this.#noLinkClose = true;
				out.push(" ");
				return html.indexOf(">", lt) + 1;
			}
			content = pieces.join("").replace(/<[^>]+>/g, "");
		}
		const text = content.replace(/\s+/g, " ").trim();
		if (text) out.push(href.startsWith("#") ? text : `${text} (${href})`);
		return end;
	}
}

export function htmlToMarkdown(html: string): HtmlExtraction {
	const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.replace(/\s+/g, " ").trim();
	let main = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i)?.[1]
		?? html.match(/<article\b[^>]*>([\s\S]*?)<\/article>/i)?.[1]
		?? html.match(/<body\b[^>]*>([\s\S]*?)<\/body>/i)?.[1]
		?? html;
	main = stripRoleNavigation(main);
	main = stripChromeBlocks(main);
	main = stripScriptLikeBlocks(main);
	const markdown = decodeEntities(new MarkupScan(main).convert())
		.replace(/[ \t]{2,}|\t/g, " ")
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter((line) => line && line !== "-" && line !== "•")
		.join("\n");
	return { title: title ? decodeEntities(title) : undefined, markdown };
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
	/** This URL's reads under the calling web_fetch call's budget. */
	reads: UrlReads;
}

export interface JinaResult {
	title?: string;
	markdown: string;
	source: "jina";
	/** Where the Jina body was cut and by which ceiling; absent when it was read whole. */
	cut?: BoundedRead["cut"];
}

export async function fetchViaJina(targetUrl: string, options: JinaFetchOptions): Promise<JinaResult> {
	const fetchImpl = options.fetchImpl ?? fetch;
	const headers: Record<string, string> = { accept: "text/markdown,text/plain,*/*" };
	if (options.apiKey) headers.authorization = `Bearer ${options.apiKey}`;
	const response = await fetchImpl(`https://r.jina.ai/${targetUrl}`, { headers, signal: options.signal });
	if (!response.ok) throw new Error(`Jina Reader fetch failed (${response.status}) for ${targetUrl}`);
	const body = await readTextWithin(response, options.reads, options.signal);
	const text = body.text;
	const titleMatch = text.match(/^Title:\s*(.+)$/m);
	const bodyStart = text.indexOf("Markdown Content:");
	const markdown = bodyStart >= 0 ? text.slice(bodyStart + "Markdown Content:".length).trim() : text.trim();
	return { title: titleMatch?.[1]?.trim(), markdown, source: "jina", ...(body.cut ? { cut: body.cut } : {}) };
}
