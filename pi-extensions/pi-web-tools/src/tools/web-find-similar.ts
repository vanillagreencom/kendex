import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { ExaClient } from "../providers/exa.js";
import type { WebToolsSettings } from "../settings.js";
import { storeWebContent } from "../storage.js";
import { sourceList, toResultRef } from "../utils/format.js";
import { renderExaCall, renderExaResultList } from "./exa-render.js";

export const webFindSimilarSchema = Type.Object({ url: Type.String(), numResults: Type.Optional(Type.Number()), textMaxCharacters: Type.Optional(Type.Number()) });
export type WebFindSimilarInput = Static<typeof webFindSimilarSchema>;

export function createWebFindSimilarToolDefinition(pi: ExtensionAPI, getSettings: (cwd?: string) => WebToolsSettings, name = "web_find_similar") {
	const label = name === "web_find_similar" ? "Web Find Similar" : name;
	return {
		renderShell: "self" as const,
		name,
		label: "Web Find Similar",
		description: "Find pages similar to a URL via Exa findSimilar.",
		parameters: webFindSimilarSchema,
		renderCall(args: WebFindSimilarInput, theme: any, context: any) {
			return renderExaCall(label, args?.url, theme, context, args?.numResults ? `${args.numResults} results` : undefined);
		},
		renderResult(result: any, options: any, theme: any, context: any) {
			return renderExaResultList(label, context?.args?.url, result, options, theme, context, "results");
		},
		async execute(_toolCallId: string, params: WebFindSimilarInput, signal: AbortSignal | undefined, _onUpdate: unknown, ctx: ExtensionContext) {
			const client = new ExaClient({ apiKey: getSettings(ctx.cwd).apiKeys.exa });
			const response = await client.findSimilar(params.url, { numResults: params.numResults, textMaxCharacters: params.textMaxCharacters }, signal);
			const results = response.results.map((result) => {
				const stored = result.text || result.summary ? storeWebContent(pi, { title: result.title, url: result.url, content: result.text || result.summary || "", metadata: { url: params.url, provider: "exa", tool: name, contentKind: "similar-result", providerTextMaxCharacters: params.textMaxCharacters ?? 12000 } }) : undefined;
				return toResultRef(result, stored?.id);
			});
			return { content: [{ type: "text", text: `${sourceList(results)}${results.some((result) => result.contentId) ? "\n\nUse get_web_content with the content id for stored full text." : ""}` }], details: { provider: "exa", answer: response.answer, results } };
		},
	};
}
