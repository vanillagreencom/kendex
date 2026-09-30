import assert from "node:assert/strict";
import { endWebContentSession } from "../src/storage.js";
import { detailsHold } from "./fixtures.js";
import test, { beforeEach, afterEach } from "node:test";
import { createWebSearchToolDefinition } from "../src/tools/web-search.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";
import type { StoredWebContent } from "../src/storage.js";

beforeEach(endWebContentSession);
afterEach(endWebContentSession);

const ANSWER = "Provider answer text";
const ANSWER_SOURCE = "https://example.com/answer";
const duckduckgo = (count: number) => () => new Response(Array.from({ length: count }, (_, index) => `<div class="result"><a class="result__a" href="https://example.com/${index}">Result ${index}</a><div class="result__snippet">Snippet ${index}</div></div>`).join("\n"));

for (const row of [
	{ name: "default result cap", params: { provider: "duckduckgo" as const }, apiKeys: {}, enabledProviders: ["duckduckgo" as const], hosts: { "html.duckduckgo.com": duckduckgo(8) }, detailsProbe: "Snippet 0", printed: ["Results: 5", "duckduckgo"],
		expected: { count: 5, missing: [], provider: "duckduckgo", url: "https://example.com/0", fetchGuidance: true, storedGuidance: true, warning: false, detailsText: false, appended: 0, storedProvider: undefined } },
	{ name: "URL routing without stored ids", params: { provider: "duckduckgo" as const }, apiKeys: {}, enabledProviders: ["duckduckgo" as const], hosts: { "html.duckduckgo.com": duckduckgo(1) }, detailsProbe: "Snippet 0", printed: ["Results: 1", "duckduckgo"],
		expected: { count: 1, missing: [], provider: "duckduckgo", url: "https://example.com/0", fetchGuidance: true, storedGuidance: true, warning: false, detailsText: false, appended: 0, storedProvider: undefined } },
	{ name: "keyed provider falls back to MCP", params: {}, apiKeys: { perplexity: "pplx" }, enabledProviders: DEFAULT_SETTINGS.enabledProviders, detailsProbe: "Fallback snippet", printed: ["Results: 1", "exa-mcp"],
		hosts: {
			"api.perplexity.ai": () => new Response("rate limited", { status: 429 }),
			"mcp.exa.ai": () => new Response(`data: ${JSON.stringify({ result: { content: [{ type: "text", text: "Title: Fallback\nURL: https://example.com/fallback\nHighlights:\nFallback snippet" }] } })}\n\n`),
		},
		expected: { count: 1, missing: [], provider: "exa-mcp", url: "https://example.com/fallback", fetchGuidance: false, storedGuidance: true, warning: true, detailsText: false, appended: 1, storedProvider: "exa-mcp" } },
	{ name: "Perplexity answer stays out of details", params: { provider: "perplexity" as const }, apiKeys: { perplexity: "pplx" }, enabledProviders: DEFAULT_SETTINGS.enabledProviders, detailsProbe: ANSWER, printed: [ANSWER],
		hosts: { "api.perplexity.ai": () => Response.json({ choices: [{ message: { content: ANSWER } }], search_results: [{ url: ANSWER_SOURCE, title: "Answer source" }] }) },
		expected: { count: 1, missing: [], provider: "perplexity", url: ANSWER_SOURCE, fetchGuidance: true, storedGuidance: true, warning: false, detailsText: false, appended: 0, storedProvider: undefined } },
	{ name: "Gemini API answer stays out of details", params: { provider: "gemini" as const }, apiKeys: { gemini: "gem" }, enabledProviders: DEFAULT_SETTINGS.enabledProviders, detailsProbe: ANSWER, printed: [ANSWER],
		hosts: { "generativelanguage.googleapis.com": () => Response.json({ candidates: [{ content: { parts: [{ text: ANSWER }] }, groundingMetadata: { groundingChunks: [{ web: { uri: ANSWER_SOURCE, title: "Answer source" } }] } }] }) },
		expected: { count: 1, missing: [], provider: "gemini", url: ANSWER_SOURCE, fetchGuidance: true, storedGuidance: true, warning: false, detailsText: false, appended: 0, storedProvider: undefined } },
]) {
	test(`web_search execute: ${row.name}`, async (t) => {
		const appended: StoredWebContent[] = [];
		const hosts: Partial<Record<string, () => Response>> = row.hosts;
		t.mock.method(globalThis, "fetch", async (url: URL | string | Request) => {
			const respond = hosts[new URL(String(url)).hostname];
			if (!respond) throw new Error("unexpected endpoint");
			return respond();
		});
		const settings = { ...DEFAULT_SETTINGS, warnings: [], apiKeys: row.apiKeys, enabledProviders: row.enabledProviders };
		const tool = createWebSearchToolDefinition({ appendEntry(_type: string, data: StoredWebContent) { appended.push(data); } } as any, () => settings);
		const result = await tool.execute("call", { query: "q", ...row.params }, undefined, undefined, { cwd: process.cwd(), model: { provider: "openai-codex" } } as any);
		const block = result.content[0]!;
		const text: string = block.type === "text" ? block.text : "";
		assert.deepEqual({
			count: result.details.results.length,
			missing: row.printed.filter((needle) => !text.includes(needle)),
			provider: result.details.provider,
			url: text.split(/\s+/).some((token) => token === row.expected.url) ? row.expected.url : undefined,
			fetchGuidance: text.includes("web_fetch"),
			storedGuidance: text.includes("get_web_content"),
			warning: result.details.warnings?.some((warning: string) => warning.includes("perplexity")) ?? false,
			detailsText: detailsHold(result.details, row.detailsProbe),
			appended: appended.length,
			storedProvider: appended[0]?.metadata?.provider,
		}, row.expected);
	});
}
test("web_search renderer shows source URLs and hides content ids", () => {
	const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };
	const tool = createWebSearchToolDefinition({} as any, () => ({}) as any);
	const text = tool.renderResult({ details: { provider: "exa", results: [{ title: "Example", url: "https://example.com/path", contentId: "web-123" }] } }, {}, theme, { args: { query: "q" } }).render(200).join("\n");
	assert.deepEqual({ title: text.includes("Web Search (Exa) q · 1 results"), url: text.split(/\s+/).some((token) => token === "https://example.com/path"), id: text.includes("content id web-123") }, { title: true, url: true, id: false });
});
