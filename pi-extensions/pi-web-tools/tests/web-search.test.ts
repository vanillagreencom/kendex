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

// The tool emits batch queries; Google's fake API returns an independent answer and grounding list for each one.
for (const parallel of [false, true]) {
	test(`Gemini batch retains each answer and source list${parallel ? " with parallel requests" : ""}`, { timeout: 10_000 }, async (t) => {
		const requests: Array<{ query: string; dates: Array<{ direction: string; date: string }>; systemInstruction: unknown }> = [];
		const release: Array<() => void> = [];
		t.mock.method(globalThis, "fetch", async (_url: Parameters<typeof fetch>[0], init?: RequestInit) => {
			const body = JSON.parse(String(init?.body));
			const prompt: string = body.contents[0].parts[0].text;
			const query = prompt.split("\n")[0]!;
			// Gemini consumes date relations as prompt hints; the date alone does not define a bound.
			const dates = [...prompt.matchAll(/\b(after|before)\s+(\d{4}-\d{2}-\d{2})\b/g)].map(([, direction, date]) => ({ direction: direction!, date: date! }));
			requests.push({ query, dates, systemInstruction: body.systemInstruction });
			if (parallel) await new Promise<void>((resolve) => release.push(resolve));
			return Response.json({ candidates: [{ content: { parts: [{ text: `Answer ${query}` }] }, groundingMetadata: { groundingChunks: [{ web: { uri: `https://example.com/${query}`, title: query } }], groundingSupports: [{ segment: { endIndex: Buffer.byteLength(`Answer ${query}`) }, groundingChunkIndices: [0] }] } }] });
		});
		const settings = { ...DEFAULT_SETTINGS, warnings: [], apiKeys: { gemini: "k" } };
		const tool = createWebSearchToolDefinition({} as any, () => settings);
		const pending = tool.execute("batch", { queries: ["first", "second"], provider: "gemini", startPublishedDate: "2026-10-01", endPublishedDate: "2026-10-13" }, undefined, undefined, { cwd: process.cwd() } as any);
		if (parallel) {
			assert.deepEqual(requests.map((request) => request.query), ["first", "second"]);
			release[1]!();
			release[0]!();
		}
		const result = await pending;
		const text: string = result.content[0]!.text;
		const sections = text.startsWith("## ") ? text.split(/^## /m).slice(1) : [text];
		assert.equal(sections.length, 2);
		assert.deepEqual(sections.map((section) => ({ query: section.split("\n")[0], answer: section.match(/Answer \w+\[\d+\]/)?.[0], sources: [...section.matchAll(/https:\/\/example\.com\/\w+/g)].map((match) => match[0]) })), ["first", "second"].map((query) => ({ query, answer: `Answer ${query}[1]`, sources: [`https://example.com/${query}`] })));
		assert.deepEqual(requests, ["first", "second"].map((query) => ({ query, dates: [{ direction: "after", date: "2026-10-01" }, { direction: "before", date: "2026-10-13" }], systemInstruction: undefined })));
		assert.deepEqual(result.details.results.map((source: { url?: string }) => source.url), ["https://example.com/first", "https://example.com/second"]);
		assert.equal(detailsHold(result.details, "Answer first"), false);
	});
}
