import assert from "node:assert/strict";
import test from "node:test";
import { storeWebContent } from "../src/storage.js";
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
	{ name: "truncated", details: { id: "web-long", title: "Long", url: "https://example.com/long", contentLength: 120000, maxCharacters: 50000, truncated: true, metadata: { provider: "http" } }, present: [/Get Web Content \(Session\) Long/, /50000\/120000 chars · truncated/, /source HTTP/], absent: [/· full/] },
	{ name: "provider excerpt", details: { id: "web-search", title: "Result", url: "https://example.com/result", contentLength: 1200, maxCharacters: 50000, truncated: false, metadata: { provider: "exa", contentKind: "search-result", providerTextMaxCharacters: 1200 } }, present: [/Get Web Content \(Session\) Result/, /1200 chars · stored excerpt/, /provider cap 1200 chars/], absent: [/1200 chars · full/] },
	{ name: "Jina source", details: { id: "web-jina", title: "Recovered", url: "https://blocked.example", contentLength: 80, truncated: false, metadata: { provider: "http", extractionChain: ["html-basic", "jina"] } }, present: [/source HTTP\+Jina/], absent: [] },
	{ name: "source cut", details: { id: "web-cut", title: "Big", url: "https://example.com/big", contentLength: 80, truncated: false, metadata: { provider: "http", bodyTruncatedAtBytes: 8388608, bodyTruncatedBy: "read-limit" } }, present: [/80 chars · source cut at 8388608 bytes/], absent: [/· full/] },
	{ name: "paged source cut", details: { id: "web-cut-long", title: "Big", url: "https://example.com/big", contentLength: 120000, maxCharacters: 50000, truncated: true, metadata: { provider: "http", bodyTruncatedAtBytes: 8388608, bodyTruncatedBy: "read-limit" } }, present: [/50000\/120000 chars · truncated · source cut at 8388608 bytes/], absent: [/· full/] },
	{ name: "URL leaf title", details: { id: "web-pdf", title: "", url: "https://example.com/path/dummy.pdf", contentLength: 15, truncated: false, metadata: { provider: "exa" } }, present: [/Get Web Content \(Session\) dummy\.pdf/, /15 chars · full/], absent: [] },
]) {
	test(`stored content result render: ${row.name}`, () => {
		const text = createGetWebContentToolDefinition().renderResult({ details: row.details }, {}, theme, { args: { id: row.details.id } }).render(200).join("\n");
		assert.deepEqual({ present: row.present.map((pattern) => pattern.test(text)), absent: row.absent.map((pattern) => pattern.test(text)) }, { present: row.present.map(() => true), absent: row.absent.map(() => false) });
	});
}

const pi = {} as Parameters<typeof storeWebContent>[0];
for (const row of [
	{ name: "whole source, one page", content: "abc", metadata: { provider: "http" }, maxCharacters: 10, notes: [] },
	{ name: "whole source, paged", content: "abcdef", metadata: { provider: "http" }, maxCharacters: 3, notes: ["[truncated 3 characters]", "[Use a larger maxCharacters value for more.]"] },
	{ name: "cut source, one page", content: "abc", metadata: { provider: "http", bodyTruncatedAtBytes: 8388608, bodyTruncatedBy: "read-limit" }, maxCharacters: 10, notes: ["[source cut at 8388608 bytes]"] },
	{ name: "cut source, paged", content: "abcdef", metadata: { provider: "http", bodyTruncatedAtBytes: 1024, bodyTruncatedBy: "call-budget" }, maxCharacters: 3, notes: ["[truncated 3 characters]", "[Use a larger maxCharacters value for more.]", "[source cut at 1024 bytes because this call's byte budget ran out; fetch fewer URLs per call to read it whole]"] },
]) {
	test(`stored content text: ${row.name}`, async () => {
		const stored = storeWebContent(pi, { title: "Page", url: "https://example.com/page", content: row.content, metadata: row.metadata });
		const result = await createGetWebContentToolDefinition().execute("call", { id: stored.id, maxCharacters: row.maxCharacters });
		assert.deepEqual(result.content[0]?.text.match(/\[[^\]]*\]/g) ?? [], row.notes);
	});
}
