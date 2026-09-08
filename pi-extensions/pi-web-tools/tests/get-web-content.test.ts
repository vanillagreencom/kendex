import assert from "node:assert/strict";
import test from "node:test";
import { createGetWebContentToolDefinition } from "../src/tools/get-web-content.js";

const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };
for (const row of [
	{ name: "URL as id", id: "https://example.com", present: [/Get Web Content \(Session\)/, /content id https:\/\/example\.com/, /web_fetch/], absent: [], absentHeader: [/https:\/\/example\.com/] },
	{ name: "result number as id", id: "7", present: [/content id 7/, /web_search/, /web_fetch/], absent: [], absentHeader: [] },
	{ name: "toolu id", id: "toolu_01ABC", present: [/offset:/], absent: [/web_search(?!\/web_fetch)/], absentHeader: [] },
	{ name: "call id", id: "call_abc123", present: [/offset:/], absent: [/web_search(?!\/web_fetch)/], absentHeader: [] },
	{ name: "tool result sidecar", id: "/home/u/.somehost/tool-results/toolu_01ABC.json", present: [/offset:/], absent: [/web_search(?!\/web_fetch)/], absentHeader: [] },
]) {
	test(`stored content error render: ${row.name}`, () => {
		const text = createGetWebContentToolDefinition().renderResult({ content: [{ type: "text", text: `Stored content id not found: ${row.id}` }] }, {}, theme, { isError: true, args: { id: row.id } }).render(200).join("\n");
		assert.deepEqual({ present: row.present.map((pattern) => pattern.test(text)), absent: row.absent.map((pattern) => pattern.test(text)), header: row.absentHeader.map((pattern) => pattern.test(text.split("\n")[0] ?? "")) }, { present: row.present.map(() => true), absent: row.absent.map(() => false), header: row.absentHeader.map(() => false) });
	});
}
for (const row of [
	{ name: "session source", details: { id: "web-123", title: "Example", url: "https://example.com", contentLength: 42, metadata: { provider: "exa" } }, present: [/Get Web Content \(Session\) Example/, /42 chars · full/, /source Exa/], absent: [/content id web-123/] },
	{ name: "truncated", details: { id: "web-long", title: "Long", url: "https://example.com/long", contentLength: 120000, maxCharacters: 50000, truncated: true, metadata: { provider: "http" } }, present: [/Get Web Content \(Session\) Long/, /50000\/120000 chars · truncated/, /source HTTP/], absent: [] },
	{ name: "provider excerpt", details: { id: "web-search", title: "Result", url: "https://example.com/result", contentLength: 1200, maxCharacters: 50000, truncated: false, metadata: { provider: "exa", contentKind: "search-result", providerTextMaxCharacters: 1200 } }, present: [/Get Web Content \(Session\) Result/, /1200 chars · stored excerpt/, /provider cap 1200 chars/], absent: [/1200 chars · full/] },
	{ name: "Jina source", details: { id: "web-jina", title: "Recovered", url: "https://blocked.example", contentLength: 80, truncated: false, metadata: { provider: "http", extractionChain: ["html-basic", "jina"] } }, present: [/source HTTP\+Jina/], absent: [] },
	{ name: "URL leaf title", details: { id: "web-pdf", title: "", url: "https://example.com/path/dummy.pdf", contentLength: 15, truncated: false, metadata: { provider: "exa" } }, present: [/Get Web Content \(Session\) dummy\.pdf/, /15 chars · full/], absent: [] },
]) {
	test(`stored content result render: ${row.name}`, () => {
		const text = createGetWebContentToolDefinition().renderResult({ details: row.details }, {}, theme, { args: { id: row.details.id } }).render(200).join("\n");
		assert.deepEqual({ present: row.present.map((pattern) => pattern.test(text)), absent: row.absent.map((pattern) => pattern.test(text)) }, { present: row.present.map(() => true), absent: row.absent.map(() => false) });
	});
}
