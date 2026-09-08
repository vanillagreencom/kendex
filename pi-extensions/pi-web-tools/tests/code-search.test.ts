import assert from "node:assert/strict";
import { clearMemoryForTests } from "../src/storage.js";
import test, { beforeEach, afterEach } from "node:test";
import { createCodeSearchToolDefinition } from "../src/tools/code-search.js";
import type { StoredWebContent } from "../src/storage.js";

beforeEach(clearMemoryForTests);
afterEach(clearMemoryForTests);

const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };
for (const { name, expanded, details, query, present, absent } of [
	{ name: "context compact", expanded: false, details: { provider: "exa-code", source: "exa-code", outputTokens: 1500, resultsCount: 8, contentId: "web-foo", results: [{ title: "React Hooks", url: "https://react.dev/reference/react/useState" }, { title: "GFG", url: "https://geeksforgeeks.org/x" }] }, query: "react", present: [/Code Search \(Exa Code\) react/, /1500 tokens · 8 sources/, /content id web-foo/, /2 sources/, /ctrl\+o/], absent: [/0 results/] },
	{ name: "context expanded", expanded: true, details: { provider: "exa-code", source: "exa-code", outputTokens: 1500, resultsCount: 8, contentId: "web-foo", results: [{ title: "React Hooks", url: "https://react.dev/reference/react/useState" }, { title: "GFG", url: "https://geeksforgeeks.org/x" }] }, query: "react", present: [/React Hooks/, /react\.dev\/reference\/react\/useState/, /GFG/], absent: [] },
	{ name: "search compact", expanded: false, details: { results: [{ title: "Example", url: "https://example.com", contentId: "web-123" }] }, query: "q", present: [/Code Search \(Exa\) q · 1 results/, /https:\/\/example.com/], absent: [/content id web-123/, /contentId/] },
]) {
	test(`code_search render: ${name}`, () => {
		const tool = createCodeSearchToolDefinition({} as any, () => ({}) as any);
		const text = tool.renderResult({ content: [{ type: "text", text: "snippets" }], details }, { expanded }, theme, { args: { query } }).render(200).join("\n");
		assert.deepEqual({ present: present.map((pattern) => pattern.test(text)), absent: absent.map((pattern) => pattern.test(text)) }, { present: present.map(() => true), absent: absent.map(() => false) });
	});
}
for (const { name, contextStatus, expected } of [
	{ name: "context success", contextStatus: 200, expected: { provider: "exa-code", contextCalls: 1, searchCalls: 0, text: true, appended: 1, kind: "code-context", full: "code snippet body" } },
	{ name: "classic fallback", contextStatus: 500, expected: { provider: "exa", contextCalls: 1, searchCalls: 1, results: 1 } },
]) {
	test(`code_search execute: ${name}`, async (t) => {
		let contextCalls = 0;
		let searchCalls = 0;
		const appended: StoredWebContent[] = [];
		t.mock.method(globalThis, "fetch", async (url: URL | string | Request) => {
			if (String(url).endsWith("/context")) { contextCalls++; return new Response(JSON.stringify({ response: "code snippet body", resultsCount: 5, outputTokens: 400 }), { status: contextStatus }); }
			searchCalls++;
			return new Response(JSON.stringify({ results: [{ title: "GitHub repo", url: "https://github.com/foo/bar", text: "code" }] }));
		});
		const tool = createCodeSearchToolDefinition({ appendEntry(_type: string, data: StoredWebContent) { appended.push(data); } } as any, () => ({ apiKeys: { exa: "k" } } as any));
		const result = await tool.execute("call", { query: "react hooks" }, undefined, undefined, { cwd: process.cwd() } as any);
		const block = result.content[0]!;
		assert.deepEqual({ provider: result.details.provider, contextCalls, searchCalls, ...(contextStatus === 200 ? { text: block.type === "text" && block.text.includes("code snippet body"), appended: appended.length, kind: appended[0]?.metadata?.contentKind, full: appended[0]?.content } : { results: result.details.results.length }) }, expected);
	});
}
