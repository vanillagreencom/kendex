import assert from "node:assert/strict";
import test from "node:test";
import { ExaClient } from "../src/providers/exa.js";

function jsonResponse(payload: unknown, status = 200): Response {
	return new Response(JSON.stringify(payload), { status, headers: { "content-type": "application/json" } });
}

function fakeFetch(bodyOut: any[] = []): typeof fetch {
	return (async (_url: any, init: any) => {
		bodyOut.push(JSON.parse(init.body));
		return new Response(JSON.stringify({ answer: "Synth", results: [{ title: "Source", url: "https://example.com", highlights: ["A"] }] }), { status: 200, headers: { "content-type": "application/json" } });
	}) as typeof fetch;
}

test("ExaClient.codeContext POSTs to /context and parses response", async () => {
	const seen: { url: string; method: string | undefined; body: unknown }[] = [];
	const fetchImpl = (async (url: any, init: any) => {
		seen.push({ url: String(url), method: init?.method, body: JSON.parse(String(init?.body ?? "{}")) });
		return jsonResponse({ requestId: "req_1", query: "react hooks", response: "## Code\n\n```ts\nconst [n,setN]=useState(0);\n```", resultsCount: 12, outputTokens: 800 });
	}) as typeof fetch;
	const client = new ExaClient({ apiKey: "k", fetchImpl });
	const out = await client.codeContext("react hooks", 5000);
	assert.deepEqual({
		url: seen[0]!.url,
		method: seen[0]!.method,
		body: seen[0]!.body,
		fixtureTextPresent: /useState/.test(out.text),
		outputTokens: out.outputTokens,
		resultsCount: out.resultsCount,
	}, {
		url: "https://api.exa.ai/context",
		method: "POST",
		body: { query: "react hooks", tokensNum: 5000 },
		fixtureTextPresent: true,
		outputTokens: 800,
		resultsCount: 12,
	});
});

test("Exa deep research request maps params", async () => {
	const bodies: any[] = [];
	const client = new ExaClient({ apiKey: "key", fetchImpl: fakeFetch(bodies), baseUrl: "https://exa.test" });
	await client.deepResearch({ query: "q", type: "deep-reasoning", additionalQueries: ["a"], includeDomains: ["example.com"], textMaxCharacters: 42 });
	assert.deepEqual({
		query: bodies[0].query,
		type: bodies[0].type,
		additionalQueries: bodies[0].additionalQueries,
		includeDomains: bodies[0].includeDomains,
		maxCharacters: bodies[0].contents.text.maxCharacters,
		highlights: bodies[0].contents.highlights,
	}, {
		query: "q",
		type: "deep-reasoning",
		additionalQueries: ["a"],
		includeDomains: ["example.com"],
		maxCharacters: 42,
		highlights: true,
	});
});

test("missing Exa key returns actionable error", () => {
	assert.throws(() => new ExaClient({}), /EXA_API_KEY/);
});

test("Exa answer normalizes sources as results", async () => {
	const client = new ExaClient({
		apiKey: "key",
		baseUrl: "https://exa.test",
		fetchImpl: (async () => new Response(JSON.stringify({ answer: "A", sources: [{ title: "S", url: "https://example.com/s", text: "Source text" }] }), { status: 200, headers: { "content-type": "application/json" } })) as typeof fetch,
	});
	const response = await client.answer("q");
	assert.deepEqual({
		answer: response.answer,
		results: response.results,
	}, {
		answer: "A",
		results: [{ title: "S", url: "https://example.com/s", text: "Source text", summary: undefined, highlights: undefined, publishedDate: undefined }],
	});
});

test("Exa contents preserves result ids for request reconciliation", async () => {
	const client = new ExaClient({
		apiKey: "key",
		baseUrl: "https://exa.test",
		fetchImpl: (async () => new Response(JSON.stringify({ results: [{ id: "https://example.com/requested", url: "https://redirected.example/final", text: "Content" }] }), { status: 200, headers: { "content-type": "application/json" } })) as typeof fetch,
	});
	const response = await client.contents({ urls: ["https://example.com/requested"] });
	assert.equal(response.results[0]?.id, "https://example.com/requested");
});

test("Exa search body includes configured content and structured output options", () => {
	const client = new ExaClient({ apiKey: "key", fetchImpl: fakeFetch(), baseUrl: "https://exa.test" });
	const body = client.buildSearchBody({ query: "q", type: "deep", category: "news", maxAgeHours: 1, textMaxCharacters: 123, highlightsMaxCharacters: 456, highlightNumSentences: 2, highlightsPerUrl: 3, summaryQuery: "summarize", outputSchema: { type: "object" } });
	assert.deepEqual({
		category: body.category,
		maxAgeHours: body.maxAgeHours,
		text: (body.contents as any).text,
		highlights2: (body.contents as any).highlights,
		summary: (body.contents as any).summary,
		outputSchema: body.outputSchema,
	}, {
		category: "news",
		maxAgeHours: 1,
		text: { maxCharacters: 123 },
		highlights2: { maxCharacters: 456, numSentences: 2, highlightsPerUrl: 3 },
		summary: { query: "summarize" },
		outputSchema: { type: "object" },
	});
});
