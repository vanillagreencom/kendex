import assert from "node:assert/strict";
import test from "node:test";
import { fetchHttpContent } from "../src/extract/http.js";
import { urlReads } from "./fixtures.js";

for (const row of [
	{ name: "HTML", url: "https://example.com", body: "<title>Doc</title><p>Body</p>", type: "text/html", status: 200, fallback: false, expected: { title: "Doc", content: /Body/, chain: ["html-basic"] } },
	{ name: "JSON", url: "https://example.com/data.json", body: '{"b":2}', type: "application/json", status: 200, fallback: false, expected: { content: /"b": 2/ } },
	{ name: "blocked HTML recovery", url: "https://blocked.example", body: "<html><body><h1>Just a moment</h1><p>Checking your browser.</p></body></html>", type: "text/html", status: 200, fallback: true, recovered: "# Got it\n\nclean body", expected: { title: "Recovered", content: /clean body/, chain: ["html-basic", "jina"] } },
	{ name: "HTTP 403 recovery", url: "https://e403.example", body: "denied", type: "text/plain", status: 403, fallback: true, recovered: "# After 403\n\nrescued", expected: { title: "Recovered", content: /rescued/, chain: ["http:403", "jina"] } },
	{ name: "fallback disabled", url: "https://blocked.example", body: "<html><body><h1>Just a moment</h1></body></html>", type: "text/html", status: 200, fallback: false, expected: { content: /Just a moment/, chain: ["html-basic"] } },
]) {
	test(`HTTP extraction: ${row.name}`, async (t) => {
		const out = await fetchHttpContent(row.url, {
			jinaFallback: row.fallback,
			reads: urlReads(t),
			fetchImpl: async (url) => String(url).startsWith("https://r.jina.ai/") ? new Response(`Title: Recovered\n\nMarkdown Content:\n${row.recovered}`) : new Response(row.body, { status: row.status, headers: { "content-type": row.type } }),
		});
		assert.deepEqual({ content: row.expected.content.test(out.content), ...(row.expected.title ? { title: out.title } : {}), ...(row.expected.chain ? { chain: out.metadata.extractionChain } : {}) }, { content: true, ...(row.expected.title ? { title: row.expected.title } : {}), ...(row.expected.chain ? { chain: row.expected.chain } : {}) });
	});
}

const lowQualityPage = `<html><body><p>tiny</p>${"<i></i>".repeat(700)}</body></html>`;
for (const row of [
	{ name: "direct body", status: 200, type: "text/plain", body: "a".repeat(20), expected: { content: "aaaaaaaaaaaa", cut: 12, by: "call-budget", chain: ["text"] } },
	{ name: "Jina body after HTTP 403", status: 403, type: "text/plain", body: "a".repeat(20), expected: { content: "rescued and", cut: 12, by: "call-budget", chain: ["http:403", "jina"] } },
	{ name: "Jina body after low-quality HTML", status: 200, type: "text/html", body: lowQualityPage, budget: lowQualityPage.length + 12, expected: { content: "rescued and", cut: 12, by: "call-budget", chain: ["html-basic", "jina"] } },
]) {
	test(`HTTP extraction cuts at the call byte budget: ${row.name}`, async (t) => {
		const out = await fetchHttpContent("https://big.example", {
			jinaFallback: true,
			reads: urlReads(t, row.budget ?? 12),
			fetchImpl: async (url) => String(url).startsWith("https://r.jina.ai/") ? new Response("rescued and more past the budget") : new Response(row.body, { status: row.status, headers: { "content-type": row.type } }),
		});
		assert.deepEqual({ content: out.content, cut: out.metadata.bodyTruncatedAtBytes, by: out.metadata.bodyTruncatedBy, chain: out.metadata.extractionChain }, row.expected);
	});
}
