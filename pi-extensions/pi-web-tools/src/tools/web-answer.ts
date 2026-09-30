import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { ExaClient } from "../providers/exa.js";
import type { WebToolsSettings } from "../settings.js";
import { storeWebContent } from "../storage.js";
import { sourceList, toResultRef } from "../utils/format.js";
import { renderExaCall, renderExaResultList } from "./exa-render.js";

export const webAnswerSchema = Type.Object({ query: Type.String() });
export type WebAnswerInput = Static<typeof webAnswerSchema>;

export function createWebAnswerToolDefinition(pi: ExtensionAPI, getSettings: (cwd?: string) => WebToolsSettings, name = "web_answer") {
	const label = name === "web_answer" ? "Web Answer" : name;
	return {
		renderShell: "self" as const,
		name,
		label: "Web Answer",
		description: "Quick cited answer via Exa answer endpoint.",
		promptSnippet: "Get a quick cited answer from Exa.",
		parameters: webAnswerSchema,
		renderCall(args: WebAnswerInput, theme: any, context: any) {
			return renderExaCall(label, args?.query, theme, context);
		},
		renderResult(result: any, options: any, theme: any, context: any) {
			return renderExaResultList(label, context?.args?.query, result, options, theme, context, "sources");
		},
		async execute(_toolCallId: string, params: WebAnswerInput, signal: AbortSignal | undefined, _onUpdate: unknown, ctx: ExtensionContext) {
			const client = new ExaClient({ apiKey: getSettings(ctx.cwd).apiKeys.exa });
			const response = await client.answer(params.query, signal);
			const results = response.results.map((result) => {
				const stored = result.text || result.summary ? storeWebContent(pi, { title: result.title, url: result.url, content: result.text || result.summary || "", metadata: { query: params.query, provider: "exa", tool: name, contentKind: "answer-source", providerTextMaxCharacters: 12000 } }) : undefined;
				return toResultRef(result, stored?.id);
			});
			return { content: [{ type: "text", text: `${response.answer ?? "No answer returned."}\n\nSources:\n${sourceList(results)}${results.some((result) => result.contentId) ? "\n\nUse get_web_content with the content id for stored full text." : ""}` }], details: { provider: "exa", answer: response.answer, results } };
		},
	};
}
