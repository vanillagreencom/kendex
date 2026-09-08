import assert from "node:assert/strict";
import test from "node:test";
import { createWebFindSimilarToolDefinition } from "../src/tools/web-find-similar.js";

test("web_find_similar renders provider, result count, and source", () => {
	const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };
	const tool = createWebFindSimilarToolDefinition({} as any, () => ({}) as any);
	const text = tool.renderResult({ details: { results: [{ title: "Docs", url: "https://ghostty.org/docs" }, { title: "Repo", url: "https://github.com/ghostty-org/ghostty" }] } }, {}, theme, { args: { url: "https://ghostty.org" } }).render(200).join("\n");
	assert.deepEqual({ title: text.includes("Web Find Similar (Exa) https://ghostty.org · 2 results"), source: text.includes("Docs · https://ghostty.org/docs") }, { title: true, source: true });
});
