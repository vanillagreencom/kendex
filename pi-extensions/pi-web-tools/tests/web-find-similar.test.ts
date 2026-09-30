import assert from "node:assert/strict";
import test from "node:test";
import { createWebFindSimilarToolDefinition } from "../src/tools/web-find-similar.js";
import { endWebContentSession } from "../src/storage.js";
import { detailsHold, withStoredText } from "./fixtures.js";

test("web_find_similar renders provider, result count, and source", () => {
	const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };
	const tool = createWebFindSimilarToolDefinition({} as any, () => ({}) as any);
	const text = tool.renderResult({ details: { results: [{ title: "Docs", url: "https://ghostty.org/docs" }, { title: "Repo", url: "https://github.com/ghostty-org/ghostty" }] } }, {}, theme, { args: { url: "https://ghostty.org" } }).render(200).join("\n");
	assert.deepEqual({ title: text.includes("Web Find Similar (Exa) https://ghostty.org · 2 results"), source: text.includes("Docs · https://ghostty.org/docs") }, { title: true, source: true });
});

test("web_find_similar execute: details carry source refs, the page text only in the store", async (t) => {
	endWebContentSession();
	t.after(endWebContentSession);
	t.mock.method(globalThis, "fetch", async () => new Response(JSON.stringify({ results: [{ title: "Docs", url: "https://ghostty.org/docs", text: "similar page text", summary: "similar page summary" }] })));
	const tool = createWebFindSimilarToolDefinition({ appendEntry() {} } as any, () => ({ apiKeys: { exa: "k" } }) as any);
	const result = await tool.execute("call", { url: "https://ghostty.org" }, undefined, undefined, { cwd: process.cwd() } as any);
	const { results, ...rest } = result.details;
	assert.deepEqual({ rest: JSON.parse(JSON.stringify(rest)), results: withStoredText(results), detailsText: detailsHold(result.details, "similar page") }, {
		rest: { provider: "exa" },
		results: [{ title: "Docs", url: "https://ghostty.org/docs", stored: "similar page text" }],
		detailsText: false,
	});
});
