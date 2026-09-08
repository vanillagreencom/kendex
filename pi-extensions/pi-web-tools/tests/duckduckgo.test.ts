import assert from "node:assert/strict";
import test from "node:test";
import { DuckDuckGoClient, parseDuckDuckGoHtml } from "../src/providers/duckduckgo.js";

test("parseDuckDuckGoHtml extracts titles, redirect URLs, and snippets", () => {
	const html = `
		<div class="result">
			<a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fdocs&amp;rut=abc">Example &amp; Docs</a>
			<a class="result__snippet">Useful &lt;b&gt;snippet&lt;/b&gt; here.</a>
		</div>`;
	const results = parseDuckDuckGoHtml(html, 5);
	assert.deepEqual(results, [{ title: "Example & Docs", url: "https://example.com/docs", summary: "Useful <b>snippet</b> here." }]);
});

test("DuckDuckGoClient requests html endpoint and parses response", async () => {
	const seen: string[] = [];
	const fetchImpl = (async (url: any) => {
		seen.push(String(url));
		return new Response(`<div class="result"><a class="result__a" href="https://example.com/a">A</a><div class="result__snippet">Alpha</div></div>`, { status: 200 });
	}) as typeof fetch;
	const result = await new DuckDuckGoClient({ fetchImpl }).search({ query: "hello", numResults: 3, includeDomains: ["example.com"] });
	assert.deepEqual({
		requestedEndpoint: /^https:\/\/html\.duckduckgo\.com\/html\/\?q=hello\+site%3Aexample\.com/.test(seen[0]!),
		url: result.results[0]?.url,
		provider: result.metadata.provider,
	}, {
		requestedEndpoint: true,
		url: "https://example.com/a",
		provider: "duckduckgo",
	});
});
