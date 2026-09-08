import assert from "node:assert/strict";
import test from "node:test";
import { GeminiApiClient, geminiSearch } from "../src/providers/gemini-api.js";

for (const params of [{ query: "rust async", includeDomains: ["docs.rs"], excludeDomains: ["spam.io"] }]) {
	test("Gemini request includes search and domain hints", () => {
		const body = new GeminiApiClient({ apiKey: "k" }).buildSearchBody(params);
		const text = (body.contents as Array<{ parts: Array<{ text: string }> }>)[0]!.parts[0]!.text;
		assert.deepEqual({ tools: body.tools, domains: [text.includes("docs.rs"), text.includes("spam.io")] }, { tools: [{ googleSearch: {} }], domains: [true, true] });
	});
}
for (const row of [
	{ name: "grounded results", key: "k", status: 200, response: { candidates: [{ content: { parts: [{ text: "Tokio is the dominant async runtime." }] }, groundingMetadata: { groundingChunks: [{ web: { uri: "https://tokio.rs", title: "Tokio" } }, { web: { uri: "https://docs.rs/futures", title: "futures" } }, { web: { uri: "https://tokio.rs", title: "dup" } }] } }] }, expected: { answer: "Tokio is the dominant async runtime.", urls: ["https://tokio.rs", "https://docs.rs/futures"], provider: "gemini", count: 2 } },
	{ name: "HTTP failure", key: "k", status: 403, response: {}, expected: { error: true, status: true } },
	{ name: "missing key", key: undefined, status: 200, response: {}, expected: { error: true, fetched: false } },
]) {
	test(`Gemini API search: ${row.name}`, async () => {
		let fetched = false;
		const result = await geminiSearch({ query: "rust async" }, { apiKey: row.key, fetchImpl: async () => { fetched = true; return new Response(JSON.stringify(row.response), { status: row.status }); } }).then(
			(out) => ({ answer: out.answer, urls: out.results.map((item) => item.url), provider: out.metadata.provider, count: out.results.length }),
			(error: unknown) => row.key === undefined ? { error: error instanceof Error, fetched } : { error: error instanceof Error, status: error instanceof Error && /\b403\b/.test(error.message) },
		);
		assert.deepEqual(result, row.expected);
	});
}
