import { Type, type Static } from "typebox";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { ExaClient } from "../providers/exa.js";
import type { WebToolsSettings } from "../settings.js";
import { storeWebContent } from "../storage.js";
import { sourceList, toResultRef } from "../utils/format.js";
import { renderExaCall, renderExaResultList } from "./exa-render.js";

function parseExaCodeSources(text: string): Array<{ title?: string; url: string }> {
	const sources: Array<{ title?: string; url: string }> = [];
	const seen = new Set<string>();
	const lines = text.split(/\r?\n/);
	let pendingTitle: string | undefined;
	for (const line of lines) {
		const headingMatch = line.match(/^##+\s+(.+?)\s*$/);
		if (headingMatch) { pendingTitle = headingMatch[1]; continue; }
		const urlMatch = line.match(/^\s*(https?:\/\/\S+)\s*$/);
		if (urlMatch) {
			const url = urlMatch[1]!.replace(/[).,;]+$/, "");
			const key = url.toLowerCase();
			if (!seen.has(key)) {
				seen.add(key);
				sources.push({ title: pendingTitle, url });
			}
			pendingTitle = undefined;
		}
	}
	return sources;
}

export const codeSearchSchema = Type.Object({
	query: Type.String(),
	numResults: Type.Optional(Type.Number()),
	includeDomains: Type.Optional(Type.Array(Type.String())),
	tokensNum: Type.Optional(Type.Union([Type.Number(), Type.Literal("dynamic")], { description: "Token cap for Exa Code context response (default 'dynamic'; 50-100000 for explicit count)." })),
	mode: Type.Optional(Type.Union([Type.Literal("auto"), Type.Literal("context"), Type.Literal("search")], { description: "auto (default) prefers Exa Code context; search forces classic domain-filtered search." })),
});
export type CodeSearchInput = Static<typeof codeSearchSchema>;

export function createCodeSearchToolDefinition(pi: ExtensionAPI, getSettings: (cwd?: string) => WebToolsSettings) {
	return {
		renderShell: "self" as const,
		name: "code_search",
		label: "Code Search",
		description: "Search code and technical documentation. Uses Exa Code (/context endpoint) for token-efficient code snippets by default; falls back to Exa search with code-focused domain hints (github.com, stackoverflow.com).",
		promptSnippet: "Search for code examples and technical docs via Exa.",
		parameters: codeSearchSchema,
		renderCall(args: CodeSearchInput, theme: any, context: any) {
			return renderExaCall("Code Search", args?.query, theme, context, args?.numResults ? `${args.numResults} results` : undefined);
		},
		renderResult(result: any, options: any, theme: any, context: any) {
			return renderExaResultList("Code Search", context?.args?.query, result, options, theme, context, "results");
		},
		async execute(_toolCallId: string, params: CodeSearchInput, signal: AbortSignal | undefined, _onUpdate: unknown, ctx: ExtensionContext) {
			const client = new ExaClient({ apiKey: getSettings(ctx.cwd).apiKeys.exa });
			const mode = params.mode ?? "auto";
			if (mode !== "search") {
				try {
					const tokensNum = params.tokensNum ?? "dynamic";
					const context = await client.codeContext(params.query, tokensNum, signal);
					if (context.text.trim()) {
						const stored = storeWebContent(pi, { title: `Code Context: ${params.query}`, url: "", content: context.text, metadata: { query: params.query, provider: "exa", tool: "code_search", contentKind: "code-context", source: "exa-code", outputTokens: context.outputTokens, resultsCount: context.resultsCount } });
						const sources = parseExaCodeSources(context.text);
						return {
							content: [{ type: "text", text: `${context.text}\n\nUse get_web_content with content id ${stored.id} for the full stored context.` }],
							details: { provider: "exa-code", source: "exa-code", outputTokens: context.outputTokens, resultsCount: context.resultsCount, contentId: stored.id, results: sources },
						};
					}
				} catch (error) {
					if (mode === "context") throw error;
					// fall through to classic search
				}
			}
			const includeDomains = params.includeDomains?.length ? params.includeDomains : ["github.com", "docs.github.com", "stackoverflow.com"];
			const response = await client.search({ query: params.query, numResults: params.numResults ?? 8, includeDomains }, signal);
			const results = response.results.map((result) => {
				const stored = result.text || result.summary ? storeWebContent(pi, { title: result.title, url: result.url, content: result.text || result.summary || "", metadata: { query: params.query, provider: "exa", tool: "code_search", contentKind: "code-search-result", providerTextMaxCharacters: 12000 } }) : undefined;
				return toResultRef(result, stored?.id);
			});
			return { content: [{ type: "text", text: `${sourceList(results)}${results.some((result) => result.contentId) ? "\n\nUse get_web_content with the content id for stored full text." : ""}` }], details: { provider: "exa", answer: response.answer, results } };
		},
	};
}
