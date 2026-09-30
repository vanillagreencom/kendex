import { StringEnum } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { DuckDuckGoClient } from "../providers/duckduckgo.js";
import { ExaClient, type NormalizedExaResult } from "../providers/exa.js";
import { ExaMcpClient } from "../providers/exa-mcp.js";
import { GeminiApiClient } from "../providers/gemini-api.js";
import { geminiWebSearch } from "../providers/gemini-web.js";
import { nativeOpenAiNotice } from "../providers/openai-native.js";
import { PerplexityClient } from "../providers/perplexity.js";
import { resolveWebProvider, resolveWebProviderCandidates } from "../provider-selection.js";
import { WEB_PROVIDERS, type ResolvedWebProvider, type WebProvider, type WebToolsSettings } from "../settings.js";
import { storeWebContent } from "../storage.js";
import { sourceList, toResultRef, type ResultRef } from "../utils/format.js";
import { accent, emptyComponent, errorSummary, firstText, muted, oneLine, providerLabel, successSummary, textComponent, tree, webCallText } from "../utils/render.js";

export const webSearchSchema = Type.Object({
	query: Type.Optional(Type.String()),
	queries: Type.Optional(Type.Array(Type.String())),
	provider: Type.Optional(StringEnum(WEB_PROVIDERS)),
	numResults: Type.Optional(Type.Number()),
	textMaxCharacters: Type.Optional(Type.Number()),
	includeDomains: Type.Optional(Type.Array(Type.String())),
	excludeDomains: Type.Optional(Type.Array(Type.String())),
	startPublishedDate: Type.Optional(Type.String()),
	endPublishedDate: Type.Optional(Type.String()),
	includeContent: Type.Optional(Type.Boolean()),
});

export type WebSearchInput = Static<typeof webSearchSchema>;

const DEFAULT_WEB_SEARCH_RESULTS = 5;

function effectiveNumResults(params: WebSearchInput): number {
	return Math.max(1, Math.floor(params.numResults ?? DEFAULT_WEB_SEARCH_RESULTS));
}

function normalizeQueries(params: WebSearchInput): string[] {
	const queries = [...(params.queries ?? [])];
	if (params.query) queries.unshift(params.query);
	return queries.map((query) => query.trim()).filter(Boolean);
}

function storeProviderContent(pi: ExtensionAPI, result: NormalizedExaResult, metadata: Record<string, unknown>) {
	const content = result.text || result.summary || result.highlights?.join("\n\n") || "";
	if (!content) return undefined;
	return storeWebContent(pi, {
		title: result.title,
		url: result.url,
		content,
		metadata,
	});
}

function contentIdGuidance(all: ResultRef[]): string {
	return all.some((r) => r.contentId)
		? "Use get_web_content only with shown content id values (for example web-...), not result numbers."
		: "Result numbers above are not content ids. To inspect a page, call web_fetch with its URL; use get_web_content only after a tool returns a content id.";
}

function formatProviderBody(provider: string, all: ResultRef[], answer?: string): string {
	const guidance = contentIdGuidance(all);
	if (answer) return `${answer}\n\n${sourceList(all)}\n\n${guidance}`;
	return `Provider: ${provider}\nResults: ${all.length}\n${sourceList(all)}\n\n${guidance}`;
}

export function createWebSearchToolDefinition(pi: ExtensionAPI, getSettings: (cwd?: string) => WebToolsSettings, name = "web_search", forcedProvider?: WebProvider) {
	async function executeResolvedProvider(provider: ResolvedWebProvider, settings: WebToolsSettings, queries: string[], params: WebSearchInput, signal: AbortSignal | undefined): Promise<any> {
		const numResults = effectiveNumResults(params);
		if (provider === "openai-native") return { content: [{ type: "text", text: nativeOpenAiNotice() }], details: { provider: "openai-native" } };

		if (provider === "perplexity") {
			const client = new PerplexityClient({ apiKey: settings.apiKeys.perplexity });
			const all: ResultRef[] = [];
			let answer: string | undefined;
			for (const query of queries) {
				const response = await client.search({
					query,
					numResults,
					includeDomains: params.includeDomains,
					excludeDomains: params.excludeDomains,
					startPublishedDate: params.startPublishedDate,
					endPublishedDate: params.endPublishedDate,
				}, signal);
				if (!answer && response.answer) answer = response.answer;
				for (const result of response.results.slice(0, numResults)) all.push(toResultRef(result));
			}
			return { content: [{ type: "text", text: formatProviderBody("perplexity", all, answer) }], details: { provider: "perplexity", results: all } };
		}

		if (provider === "gemini") {
			const all: ResultRef[] = [];
			let answer: string | undefined;
			let sourceLabel = "gemini";
			for (const query of queries) {
				let response;
				if (settings.apiKeys.gemini) {
					const client = new GeminiApiClient({ apiKey: settings.apiKeys.gemini });
					response = await client.search({ query, includeDomains: params.includeDomains, excludeDomains: params.excludeDomains }, signal);
				} else if (settings.browserCookieAccess) {
					response = await geminiWebSearch({ query, numResults }, { preferredBrowser: settings.browserCookies.preferredBrowser, browserProfile: settings.browserCookies.profile, signal });
					sourceLabel = "gemini-web";
				} else {
					throw new Error("Gemini provider requires GEMINI_API_KEY or browserCookieAccess=true with a signed-in Firefox/Zen/Chrome.");
				}
				if (!answer && response.answer) answer = response.answer;
				for (const result of response.results.slice(0, numResults)) all.push(toResultRef(result));
			}
			return { content: [{ type: "text", text: formatProviderBody(sourceLabel, all, answer) }], details: { provider: sourceLabel, results: all } };
		}

		if (provider === "duckduckgo") {
			const client = new DuckDuckGoClient();
			const all: ResultRef[] = [];
			for (const query of queries) {
				const response = await client.search({ query, numResults, includeDomains: params.includeDomains, excludeDomains: params.excludeDomains }, signal);
				for (const result of response.results.slice(0, numResults)) all.push(toResultRef(result));
			}
			return { content: [{ type: "text", text: formatProviderBody("duckduckgo", all) }], details: { provider: "duckduckgo", results: all } };
		}

		const client = provider === "exa-mcp"
			? new ExaMcpClient()
			: new ExaClient({ apiKey: settings.apiKeys.exa });
		const all: ResultRef[] = [];
		for (const query of queries) {
			const response = await client.search({
				query,
				numResults,
				textMaxCharacters: params.textMaxCharacters,
				includeDomains: params.includeDomains,
				excludeDomains: params.excludeDomains,
				startPublishedDate: params.startPublishedDate,
				endPublishedDate: params.endPublishedDate,
				includeContent: params.includeContent,
			}, signal);
			for (const result of response.results.slice(0, numResults)) {
				const stored = storeProviderContent(pi, result, {
					query,
					provider,
					tool: name,
					contentKind: "search-result",
					providerTextMaxCharacters: params.textMaxCharacters ?? (provider === "exa-mcp" ? 3000 : 12000),
				});
				all.push(toResultRef(result, stored?.id));
			}
		}
		return { content: [{ type: "text", text: formatProviderBody(provider, all) }], details: { provider, results: all } };
	}

	return {
		renderShell: "self" as const,
		name,
		label: "Web Search",
		description: "Unified web search. Supports provider auto|exa|perplexity|gemini|exa-mcp|duckduckgo|openai-native, batch queries, recency/date/domain filters, and optional content storage. Auto prefers configured keyed providers, then no-key Exa MCP/DuckDuckGo, then Gemini Web/OpenAI native. Defaults to 5 results unless numResults is set.",
		promptSnippet: "Search the web across configured providers. For simple factual questions, run one targeted search with numResults<=5, answer from the best source, and stop. Use web_research only for deep reports.",
		promptGuidelines: ["Use web_search for current web information; for simple factual questions do one targeted search with a small result count. Prefer web_research only for deep evidence-backed findings reports."],
		parameters: webSearchSchema,
		renderCall(args: WebSearchInput, theme: any, context: any) {
			if (context?.executionStarted && !context?.isPartial) return emptyComponent();
			const query = args?.query || args?.queries?.[0] || "search";
			const batch = args?.queries && args.queries.length > 1 ? ` +${args.queries.length - 1} queries` : undefined;
			const provider = forcedProvider ?? args?.provider ?? "auto";
			return textComponent(webCallText(theme, providerLabel(name === "web_search" ? "Web Search" : name, provider), query, [batch].filter(Boolean).join(" · ")));
		},
		renderResult(result: any, options: any, theme: any, context: any) {
			if (options?.isPartial) return emptyComponent();
			if (context?.isError) return textComponent(errorSummary(theme, providerLabel(name === "web_search" ? "Web Search" : name, forcedProvider ?? context?.args?.provider ?? "auto"), firstText(result) || "failed"));
			const details = result?.details ?? {};
			const results = Array.isArray(details.results) ? details.results : [];
			const provider = details.provider ? `${details.provider}` : "provider";
			const query = context?.args?.query || context?.args?.queries?.[0] || "complete";
			const warnings = Array.isArray(details.warnings) && details.warnings.length ? ` · ${details.warnings.length} fallback note${details.warnings.length === 1 ? "" : "s"}` : "";
			const lines = [successSummary(theme, providerLabel(name === "web_search" ? "Web Search" : name, provider), query, `${results.length} results${warnings}`)];
			const shown = results.slice(0, options?.expanded ? 8 : 3);
			for (let index = 0; index < shown.length; index++) {
				const item = shown[index]!;
				const title = item.title || item.url || "Untitled";
				const meta = [item.url ? oneLine(item.url, 76) : undefined].filter(Boolean).join(" · ");
				lines.push(`${tree(theme, index === shown.length - 1 && results.length <= shown.length ? "└" : "├")}${accent(theme, title)}${meta ? muted(theme, ` · ${meta}`) : ""}`);
			}
			if (results.length > (options?.expanded ? 8 : 3)) lines.push(`${tree(theme, "└")}${muted(theme, `… ${results.length - (options?.expanded ? 8 : 3)} more · ctrl+o to expand`)}`);
			return textComponent(lines.join("\n"));
		},
		async execute(_toolCallId: string, params: WebSearchInput, signal: AbortSignal | undefined, _onUpdate: unknown, ctx: ExtensionContext) {
			const settings = getSettings(ctx.cwd);
			const requested = forcedProvider ?? params.provider as WebProvider | undefined;
			const queries = normalizeQueries(params);
			if (queries.length === 0) throw new Error("web_search requires query or queries.");
			const candidates = requested === "auto" || (!requested && settings.defaultProvider === "auto")
				? resolveWebProviderCandidates(requested, settings, ctx.model as any)
				: resolveWebProvider(requested, settings, ctx.model as any).provider ? [resolveWebProvider(requested, settings, ctx.model as any).provider!] : [];
			if (candidates.length === 0) throw new Error(`No web_search provider available: ${resolveWebProvider(requested, settings, ctx.model as any).reason}`);

			const warnings: string[] = [];
			for (const provider of candidates) {
				if (provider === "openai-native" && candidates.length > 1) {
					warnings.push("OpenAI native skipped after direct provider failures because it is not a function-tool result path.");
					continue;
				}
				try {
					const result = await executeResolvedProvider(provider, settings, queries, params, signal);
					if (warnings.length) result.details = { ...(result.details ?? {}), warnings };
					return result;
				} catch (error) {
					if (signal?.aborted) throw error;
					warnings.push(`${provider}: ${error instanceof Error ? error.message : String(error)}`);
					if (requested && requested !== "auto") break;
				}
			}
			throw new Error(`All web_search providers failed. ${warnings.join(" | ")}`);
		},
	};
}
