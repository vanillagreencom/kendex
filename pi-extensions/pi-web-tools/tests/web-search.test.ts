import assert from "node:assert/strict";
import { clearMemoryForTests } from "../src/storage.js";
import test, { beforeEach, afterEach } from "node:test";
import { createWebSearchToolDefinition } from "../src/tools/web-search.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";
import type { StoredWebContent } from "../src/storage.js";

beforeEach(clearMemoryForTests);
afterEach(clearMemoryForTests);

for (const row of [
	{ name: "default result cap", fallback: false, count: 8, expectedCount: 5 },
	{ name: "URL routing without stored ids", fallback: false, count: 1, expectedCount: 1 },
	{ name: "keyed provider falls back to MCP", fallback: true, count: 1, expectedCount: 1 },
]) {
	test(`web_search execute: ${row.name}`, async (t) => {
		const appended: StoredWebContent[] = [];
		t.mock.method(globalThis, "fetch", async (url: URL | string | Request) => {
			const hostname = new URL(String(url)).hostname;
			if (hostname === "api.perplexity.ai") return new Response("rate limited", { status: 429 });
			if (hostname === "mcp.exa.ai") return new Response(`data: ${JSON.stringify({ result: { content: [{ type: "text", text: "Title: Fallback\nURL: https://example.com/fallback\nHighlights:\nFallback snippet" }] } })}\n\n`);
			if (hostname === "html.duckduckgo.com") return new Response(Array.from({ length: row.count }, (_, index) => `<div class="result"><a class="result__a" href="https://example.com/${index}">Result ${index}</a><div class="result__snippet">Snippet ${index}</div></div>`).join("\n"));
			throw new Error("unexpected endpoint");
		});
		const settings = { ...DEFAULT_SETTINGS, warnings: [], apiKeys: row.fallback ? { perplexity: "pplx" } : {}, enabledProviders: row.fallback ? DEFAULT_SETTINGS.enabledProviders : ["duckduckgo" as const] };
		const tool = createWebSearchToolDefinition({ appendEntry(_type: string, data: StoredWebContent) { appended.push(data); } } as any, () => settings);
		const result = await tool.execute("call", { query: "q", ...(row.fallback ? {} : { provider: "duckduckgo" as const }) }, undefined, undefined, { cwd: process.cwd(), model: { provider: "openai-codex" } } as any);
		const block = result.content[0]!;
		const text: string = block.type === "text" ? block.text : "";
		assert.deepEqual({
			count: result.details.results.length,
			printedCount: text.includes(`Results: ${row.expectedCount}`),
			provider: result.details.provider,
			printedProvider: text.includes(row.fallback ? "exa-mcp" : "duckduckgo"),
			url: row.fallback ? text.split(/\s+/).some((token) => token === "https://example.com/fallback") : text.split(/\s+/).some((token) => token === "https://example.com/0"),
			fetchGuidance: text.includes("web_fetch"),
			storedGuidance: text.includes("get_web_content"),
			warning: result.details.warnings?.some((warning: string) => warning.includes("perplexity")) ?? false,
			appended: appended.length,
			storedProvider: appended[0]?.metadata?.provider,
		}, { count: row.expectedCount, printedCount: true, provider: row.fallback ? "exa-mcp" : "duckduckgo", printedProvider: true, url: true, fetchGuidance: !row.fallback, storedGuidance: true, warning: row.fallback, appended: row.fallback ? 1 : 0, storedProvider: row.fallback ? "exa-mcp" : undefined });
	});
}
test("web_search renderer shows source URLs and hides content ids", () => {
	const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };
	const tool = createWebSearchToolDefinition({} as any, () => ({}) as any);
	const text = tool.renderResult({ details: { provider: "exa", results: [{ title: "Example", url: "https://example.com/path", contentId: "web-123" }] } }, {}, theme, { args: { query: "q" } }).render(200).join("\n");
	assert.deepEqual({ title: text.includes("Web Search (Exa) q · 1 results"), url: text.split(/\s+/).some((token) => token === "https://example.com/path"), id: text.includes("content id web-123") }, { title: true, url: true, id: false });
});
