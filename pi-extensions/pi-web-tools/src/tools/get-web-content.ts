import { Type, type Static } from "typebox";
import { sourceCutNote } from "../extract/byte-budget.js";
import { getWebContent } from "../storage.js";
import { truncateText } from "../utils/format.js";
import { accent, emptyComponent, errorSummary, firstText, muted, providerDisplayName, providerLabel, successSummary, textComponent, tree, webCallText } from "../utils/render.js";

export const getWebContentSchema = Type.Object({
	id: Type.String({ description: "Content id returned by web_search or web_fetch." }),
	maxCharacters: Type.Optional(Type.Number({ description: "Maximum characters to return to the model. Defaults to 50000; omit for normal full-context retrieval, lower only for previews." })),
});
export type GetWebContentInput = Static<typeof getWebContentSchema>;

export const DEFAULT_GET_WEB_CONTENT_CHARACTERS = 50000;

function fallbackTitle(url: string | undefined, fallback = "content"): string {
	if (!url) return fallback;
	try {
		const parsed = new URL(url);
		const leaf = parsed.pathname.split("/").filter(Boolean).pop();
		return leaf || parsed.hostname || url;
	} catch {
		return url.split("/").filter(Boolean).pop() || url || fallback;
	}
}

function displayTitle(item: { title?: string; url?: string; id?: string }): string {
	return item.title?.trim() || fallbackTitle(item.url, item.id || "content");
}

function isStoredExcerpt(metadata: Record<string, unknown> | undefined): boolean {
	const kind = String(metadata?.contentKind ?? "");
	return ["search-result", "code-search-result", "answer-source", "similar-result"].includes(kind);
}

function sourceLabelFromMetadata(metadata: Record<string, unknown> | undefined): string | undefined {
	const provider = String(metadata?.provider ?? "").trim().toLowerCase();
	if (!provider) return undefined;
	const chain = Array.isArray(metadata?.extractionChain) ? metadata!.extractionChain.map((x) => String(x).toLowerCase()) : [];
	if (provider === "http" && chain.includes("jina")) return "http+jina";
	return provider;
}

function missingContentGuidance(id: string | undefined): string {
	const value = String(id ?? "").trim();
	if (/^\d+$/.test(value)) return "Result numbers from web_search are not content ids; use web_fetch with the result URL first.";
	if (/^https?:\/\//i.test(value)) return "URLs are not content ids; use web_fetch with the URL first.";
	if (/^(toolu_|call_|tool_)/i.test(value) || /[\\/]tool-results?[\\/].+\.json$/i.test(value))
		return "Looks like a host tool-call/result id or sidecar path, not a web content id. To continue a truncated read, re-call the originating tool with `offset:`; don't open the sidecar. Content ids look like web-... from web_search/web_fetch.";
	return "Use a content id returned by web_search or web_fetch; content ids look like web-...";
}

export function createGetWebContentToolDefinition(name = "get_web_content") {
	return {
		renderShell: "self" as const,
		name,
		label: "Get Web Content",
		description: "Retrieve stored content from prior pi-web-tools calls by content id. Content is stored in the current Pi session, not fetched again; omit maxCharacters to return up to 50000 characters.",
		promptSnippet: "Retrieve stored full web content by content id; omit maxCharacters unless the user asks for a short preview.",
		parameters: getWebContentSchema,
		renderCall(args: GetWebContentInput, theme: any, context: any) {
			if (context?.executionStarted && !context?.isPartial) return emptyComponent();
			return textComponent(webCallText(theme, providerLabel("Get Web Content", "session"), args?.id ? "stored content" : "content", args?.maxCharacters ? `${args.maxCharacters} chars` : undefined));
		},
		renderResult(result: any, options: any, theme: any, context: any) {
			if (options?.isPartial) return emptyComponent();
			if (context?.isError) {
				const rawMessage = firstText(result) || "stored content id not found";
				const message = rawMessage.toLowerCase().includes("stored content id not found") ? "stored content id not found" : rawMessage;
				const lines = [errorSummary(theme, providerLabel("Get Web Content", "session"), message)];
				if (context?.args?.id) lines.push(`${tree(theme, "├")}${muted(theme, "content id ")}${accent(theme, context.args.id)}`);
				lines.push(`${tree(theme, "└")}${muted(theme, missingContentGuidance(context?.args?.id))}`);
				return textComponent(lines.join("\n"));
			}
			const details = result?.details ?? {};
			const metadata = details?.metadata as Record<string, unknown> | undefined;
			const provider = sourceLabelFromMetadata(metadata) ?? "stored";
			const title = displayTitle({ title: details.title, url: details.url, id: details.id ?? context?.args?.id });
			const contentLength = typeof details.contentLength === "number" ? details.contentLength : 0;
			const maxCharacters = typeof details.maxCharacters === "number" ? details.maxCharacters : contentLength;
			const shownCharacters = Math.min(contentLength, Math.max(0, maxCharacters));
			const lengthMeta = details.truncated ? `${shownCharacters}/${contentLength} chars` : `${contentLength} chars`;
			const excerpt = isStoredExcerpt(metadata);
			const providerCap = typeof metadata?.providerTextMaxCharacters === "number" ? metadata.providerTextMaxCharacters : undefined;
			const cutAt = metadata?.bodyTruncatedAtBytes;
			const sourceState = excerpt ? "stored excerpt" : typeof cutAt === "number" ? `source cut at ${cutAt} bytes` : details.truncated ? undefined : "full";
			const meta = [lengthMeta, details.truncated ? "truncated" : undefined, sourceState].filter(Boolean).join(" · ");
			const rows = [provider ? "source" : undefined, providerCap ? "providerCap" : undefined, details.url ? "url" : undefined].filter(Boolean);
			const lines = [successSummary(theme, providerLabel("Get Web Content", "session"), title, meta)];
			if (provider) lines.push(`${tree(theme, rows.at(-1) === "source" ? "└" : "├")}${muted(theme, "source ")}${accent(theme, providerDisplayName(provider))}`);
			if (providerCap) lines.push(`${tree(theme, rows.at(-1) === "providerCap" ? "└" : "├")}${muted(theme, "provider cap ")}${accent(theme, `${providerCap} chars`)}`);
			if (details.url) lines.push(`${tree(theme, "└")}${muted(theme, details.url)}`);
			return textComponent(lines.join("\n"));
		},
		async execute(_toolCallId: string, params: GetWebContentInput) {
			const item = getWebContent(params.id);
			if (!item) throw new Error(`Stored content id not found: ${params.id}. ${missingContentGuidance(params.id)}`);
			const maxCharacters = params.maxCharacters ?? DEFAULT_GET_WEB_CONTENT_CHARACTERS;
			const { text, truncated } = truncateText(item.content, maxCharacters);
			const notes = [truncated ? "Use a larger maxCharacters value for more." : undefined, sourceCutNote(item.metadata)].filter(Boolean).map((note) => `\n\n[${note}]`).join("");
			return { content: [{ type: "text", text: `${displayTitle(item)}\n${item.url ?? ""}\n\n${text}${notes}` }], details: { ...item, truncated, maxCharacters, contentLength: item.content.length } };
		},
	};
}
