import assert from "node:assert/strict";
import test from "node:test";
import { PerplexityClient, perplexitySearch, type PerplexitySearchParams } from "../src/providers/perplexity.js";

for (const { name, params, expected } of [
	{ name: "include and date filters", params: { query: "rust async runtimes", numResults: 7, includeDomains: ["docs.rs"], recencyFilter: "month", startPublishedDate: "2026-01-01" }, expected: { model: "sonar", messages: [{ role: "user", content: "rust async runtimes" }], return_citations: true, search_max_results: 7, search_domain_filter: ["docs.rs"], search_recency_filter: "month", search_after_date_filter: "2026-01-01" } },
	{ name: "exclude filter", params: { query: "q", excludeDomains: ["spam.io"] }, expected: { model: "sonar", messages: [{ role: "user", content: "q" }], return_citations: true, search_domain_filter: ["-spam.io"] } },
] satisfies Array<{ name: string; params: PerplexitySearchParams; expected: Record<string, unknown> }>) {
	test(`Perplexity body: ${name}`, () => assert.deepEqual(new PerplexityClient({ apiKey: "k" }).buildChatBody(params), expected));
}
for (const row of [
	{ name: "deduplicated citations", key: "k", status: 200, response: { choices: [{ message: { content: "Tokio and async-std are the main runtimes." } }], citations: ["https://tokio.rs", "https://async.rs", "https://tokio.rs"], search_results: [{ url: "https://tokio.rs", title: "Tokio" }, { url: "https://docs.rs/futures", title: "futures" }] }, expected: { answer: "Tokio and async-std are the main runtimes.", urls: ["https://tokio.rs", "https://async.rs", "https://docs.rs/futures"], provider: "perplexity" } },
	{ name: "HTTP failure", key: "k", status: 401, response: {}, expected: { error: true, status: true } },
	{ name: "missing key", key: undefined, status: 200, response: {}, expected: { error: true, fetched: false } },
]) {
	test(`Perplexity search: ${row.name}`, async () => {
		let fetched = false;
		const result = await perplexitySearch({ query: "rust runtimes", numResults: 5 }, { apiKey: row.key, fetchImpl: async () => { fetched = true; return new Response(JSON.stringify(row.response), { status: row.status }); } }).then(
			(out) => ({ answer: out.answer, urls: out.results.map((item) => item.url), provider: out.metadata.provider }),
			(error: unknown) => row.key === undefined ? { error: error instanceof Error, fetched } : { error: error instanceof Error, status: error instanceof Error && /\b401\b/.test(error.message) },
		);
		assert.deepEqual(result, row.expected);
	});
}
