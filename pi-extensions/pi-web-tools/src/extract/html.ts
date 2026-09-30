import { readTextWithin, type BoundedRead, type UrlReads } from "./byte-budget.js";

export interface HtmlExtraction {
	title?: string;
	markdown: string;
}

const NAMED_ENTITIES: Record<string, string> = {
	nbsp: " ",
	amp: "&",
	lt: "<",
	gt: ">",
	quot: '"',
	"#39": "'",
	apos: "'",
	hellip: "…",
	mdash: "—",
	ndash: "–",
	laquo: "«",
	raquo: "»",
	copy: "©",
	reg: "®",
	trade: "™",
};

/** Named entities an `&amp;` in front of them still decodes: `&amp;lt;` reads as `<`, `&amp;nbsp;` as `&nbsp;`. */
const AFTER_AMP = "lt|gt|quot|#39|apos|hellip|mdash|ndash|laquo|raquo|copy|reg|trade";
/** Groups: 1 a named entity after `&amp;`, 2 a decimal entity after `&amp;`, 3 a named entity, 4 a decimal entity; none is a bare `&amp;`. */
const DECIMAL_OR_NAMED_ENTITY = new RegExp(`&(?:amp;(?:(${AFTER_AMP});|#(\\d+);)?|(nbsp|${AFTER_AMP});|#(\\d+);)`, "g");

/** Decodes named and decimal entities in one scan, then hexadecimal ones, so a decimal entity that spells out a hexadecimal one
 * decodes twice. */
function decodeEntities(text: string): string {
	return text
		.replace(DECIMAL_OR_NAMED_ENTITY, (_match, afterAmp?: string, afterAmpDecimal?: string, named?: string, decimal?: string) => {
			const name = afterAmp ?? named;
			if (name !== undefined) return NAMED_ENTITIES[name]!;
			const code = afterAmpDecimal ?? decimal;
			return code === undefined ? "&" : String.fromCodePoint(Number(code));
		})
		.replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)));
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

/** The markup rule for the tag at a `<`, tried in this order. Groups: 1 a block dropped with its content, by name prefix; 2 the
 * same, by whole name; 3 a block's closing tag; 4 a line break; 5 a heading level; 6 a list item; 7 a link's href; 8 any other tag.
 * A dropped block without a closing tag after it counts as any other tag. */
const TAG_RULE = /<(?:(script|style|noscript|svg)|(header|nav|footer|aside|menu|form|button)\b|\/(?:h[1-6]|p|li|blockquote|pre|tr|div|section|article)>()|br\s*\/?>()|h([1-4])[^>]*>|li[^>]*>()|a\s+[^>]*href=["']([^"']+)["'][^>]*>|[^>]+>())/iy;
const HEADING_PREFIX = ["", "\n# ", "\n## ", "\n### ", "\n#### "];
const LINK_CLOSE = /<\/a>/iy;

/** Converts the tags of one document to markdown text in a single left-to-right scan, building the output once. */
class MarkupScan {
	readonly #html: string;
	/** Per dropped-block name: where its next closing tag is, or -1 from where on none is left. */
	readonly #closes = new Map<string, { from: number; at: number; re: RegExp }>();
	/** Set once a link reaches no closing tag: none is left for any later link either. */
	#noLinkClose = false;

	constructor(html: string) {
		this.#html = html;
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
			const dropped = match[1] ?? match[2];
			if (dropped !== undefined) {
				const close = this.#closeAfter(dropped, cursor);
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
			} else if (match[3] !== undefined || match[4] !== undefined) out.push("\n");
			else if (match[5] !== undefined) out.push(HEADING_PREFIX[Number(match[5])]!);
			else if (match[6] !== undefined) out.push("\n- ");
			else if (match[7] !== undefined && !inLink) cursor = this.#link(lt, cursor, match[7], out);
			else if (!inLink) out.push(" ");
		}
	}

	/** Replaces a link with its text and href, or with a space for its opening tag alone when no closing tag follows. */
	#link(lt: number, openEnd: number, href: string, out: string[]): number {
		const content: string[] = [];
		const end = this.#noLinkClose ? -1 : this.#scan(openEnd, content, true);
		if (end < 0) {
			this.#noLinkClose = true;
			out.push(" ");
			return this.#html.indexOf(">", lt) + 1;
		}
		const text = content.join("").replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
		if (text) out.push(href.startsWith("#") ? text : `${text} (${href})`);
		return end;
	}

	/** The index after the first closing tag of `name` at or after `from`, or -1 when none follows. */
	#closeAfter(name: string, from: number): number {
		const key = name.toLowerCase();
		let entry = this.#closes.get(key);
		if (!entry) {
			entry = { from: -1, at: -1, re: new RegExp(`</${key}>`, "ig") };
			this.#closes.set(key, entry);
		}
		if (entry.from >= 0 && from >= entry.from && (entry.at < 0 || from <= entry.at)) return entry.at < 0 ? -1 : entry.at + key.length + 3;
		entry.re.lastIndex = from;
		const found = entry.re.exec(this.#html);
		entry.from = from;
		entry.at = found ? found.index : -1;
		return found ? entry.re.lastIndex : -1;
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
	const markdown = decodeEntities(new MarkupScan(main).convert())
		.replace(/[ \t]*\t[ \t]*| {2,}/g, " ")
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
	const body = await readTextWithin(response, options.reads);
	const text = body.text;
	const titleMatch = text.match(/^Title:\s*(.+)$/m);
	const bodyStart = text.indexOf("Markdown Content:");
	const markdown = bodyStart >= 0 ? text.slice(bodyStart + "Markdown Content:".length).trim() : text.trim();
	return { title: titleMatch?.[1]?.trim(), markdown, source: "jina", ...(body.cut ? { cut: body.cut } : {}) };
}
