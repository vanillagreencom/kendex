import assert from "node:assert/strict";
import test from "node:test";
import { ExaMcpClient, parseExaMcpText } from "../src/providers/exa-mcp.js";

test("parseExaMcpText extracts title/url/text blocks", () => {
	const text = `Title: Qwen3.6-27B\nURL: https://huggingface.co/Qwen/Qwen3.6-27B\nPublished: 2026-04-22\nHighlights:\nReleased model details.\n---\nTitle: Qwen GitHub\nURL: https://github.com/QwenLM/Qwen3.6\nText: Repo content.`;
	const results = parseExaMcpText(text);
	assert.deepEqual({
		length: results.length,
		title: results[0]?.title,
		publishedDate: results[0]?.publishedDate,
		fixtureTextPresent: /Repo content/.test(results[1]?.text ?? ""),
	}, {
		length: 2,
		title: "Qwen3.6-27B",
		publishedDate: "2026-04-22",
		fixtureTextPresent: true,
	});
});

test("ExaMcpClient calls JSON-RPC MCP endpoint and parses SSE response", async () => {
	let body: any;
	const fetchImpl = (async (_url: any, init: any) => {
		body = JSON.parse(String(init?.body ?? "{}"));
		const payload = { result: { content: [{ type: "text", text: "Title: Source\nURL: https://example.com\nHighlights:\nSnippet" }] } };
		return new Response(`event: message\ndata: ${JSON.stringify(payload)}\n\n`, { status: 200 });
	}) as typeof fetch;
	const result = await new ExaMcpClient({ fetchImpl }).search({ query: "latest qwen", numResults: 2 });
	assert.deepEqual({
		name: body.params.name,
		numResults: body.params.arguments.numResults,
		url: result.results[0]?.url,
		provider: result.metadata.provider,
	}, {
		name: "web_search_exa",
		numResults: 2,
		url: "https://example.com",
		provider: "exa-mcp",
	});
});
