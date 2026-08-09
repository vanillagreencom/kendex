import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { ExaClient } from "../src/providers/exa.js";
import { applyResearchMode, buildRawSidecar, defaultRawOutputPath, displayWebResearchPath, expandSimpleGlob, prepareResearchInput, renderFindingsReport, renderWebResearchSourceTree, resolveOutputPath, runExaResearch } from "../src/tools/web-research.js";
import { providerDisplayName, providerLabel } from "../src/utils/render.js";

function fakeFetch(bodyOut: any[] = []): typeof fetch {
	return (async (_url: any, init: any) => {
		bodyOut.push(JSON.parse(init.body));
		return new Response(JSON.stringify({ answer: "Synth", results: [{ title: "Source", url: "https://example.com", highlights: ["A"] }] }), { status: 200, headers: { "content-type": "application/json" } });
	}) as typeof fetch;
}

test("Exa deep research request maps params", async () => {
	const bodies: any[] = [];
	const client = new ExaClient({ apiKey: "key", fetchImpl: fakeFetch(bodies), baseUrl: "https://exa.test" });
	await client.deepResearch({ query: "q", type: "deep-reasoning", additionalQueries: ["a"], includeDomains: ["example.com"], textMaxCharacters: 42 });
	assert.equal(bodies[0].query, "q");
	assert.equal(bodies[0].type, "deep-reasoning");
	assert.deepEqual(bodies[0].additionalQueries, ["a"]);
	assert.deepEqual(bodies[0].includeDomains, ["example.com"]);
	assert.equal(bodies[0].contents.text.maxCharacters, 42);
	assert.equal(bodies[0].contents.highlights, true);
});

test("researchMode maps to Exa params and explicit overrides win", () => {
	assert.deepEqual(
		pickMode(applyResearchMode({ researchMode: "lite" })),
		{ researchMode: "lite", type: "deep-lite", numResults: 15, textMaxCharacters: 10000, timeoutSeconds: 300, highlightsMaxCharacters: 600, highlightsPerUrl: 1 },
	);
	assert.deepEqual(
		pickMode(applyResearchMode({ researchMode: "standard" })),
		{ researchMode: "standard", type: "deep-reasoning", numResults: 50, textMaxCharacters: 16000, timeoutSeconds: 600, highlightsMaxCharacters: 900, highlightsPerUrl: 2 },
	);
	assert.deepEqual(
		pickMode(applyResearchMode({ researchMode: "full", type: "deep", numResults: 7, textMaxCharacters: 99 })),
		{ researchMode: "full", type: "deep", numResults: 7, textMaxCharacters: 99, timeoutSeconds: 1800, highlightsMaxCharacters: 1200, highlightsPerUrl: 3 },
	);
	assert.throws(() => applyResearchMode({ researchMode: "slow" as any }), /Invalid researchMode/);
});

function pickMode(mode: any) {
	return {
		researchMode: mode.researchMode,
		type: mode.type,
		numResults: mode.numResults,
		textMaxCharacters: mode.textMaxCharacters,
		timeoutSeconds: mode.timeoutSeconds,
		highlightsMaxCharacters: mode.highlightsMaxCharacters,
		highlightsPerUrl: mode.highlightsPerUrl,
	};
}

test("mode profile settings override defaults while explicit tool args win", () => {
	const settings: any = { exaResearchModes: { standard: { type: "deep", numResults: 9, textMaxCharacters: 123, highlightsMaxCharacters: 456, highlightsPerUrl: 4, summaryQuery: "summarize", maxAgeHours: 2, category: "news" } } };
	const mode = applyResearchMode({ researchMode: "standard", numResults: 3 }, settings);
	assert.equal(mode.type, "deep");
	assert.equal(mode.numResults, 3);
	assert.equal(mode.textMaxCharacters, 123);
	assert.equal(mode.highlightsMaxCharacters, 456);
	assert.equal(mode.highlightsPerUrl, 4);
	assert.equal(mode.summaryQuery, "summarize");
	assert.equal(mode.maxAgeHours, 2);
	assert.equal(mode.category, "news");
});

test("full research mode runs additional queries and dedupes URLs", async () => {
	const calls: any[] = [];
	const client = {
		async deepResearch(params: any) {
			calls.push(params);
			return {
				answer: `Answer for ${params.query}`,
				results: params.query === "main"
					? [{ title: "A", url: "https://example.com/a" }, { title: "Dup", url: "https://example.com/dup" }]
					: [{ title: "Dup 2", url: "https://example.com/dup" }, { title: "B", url: "https://example.com/b" }],
				raw: { query: params.query },
				metadata: { request: params },
			};
		},
	};
	const response = await runExaResearch(client, { query: "main", researchMode: "full", additionalQueries: ["second"] });
	assert.equal(calls.length, 2);
	assert.equal(calls[0].numResults, 150);
	assert.equal(calls[0].textMaxCharacters, 24000);
	assert.equal(calls[0].highlightsMaxCharacters, 1200);
	assert.equal(calls[0].highlightsPerUrl, 3);
	assert.ok(calls[0].outputSchema);
	assert.equal(calls[0].additionalQueries, undefined);
	assert.deepEqual(response.results.map((result) => result.url), ["https://example.com/a", "https://example.com/dup", "https://example.com/b"]);
	assert.equal(response.metadata.queryCount, 2);
	assert.equal(response.metadata.sourceCount, 4);
	assert.equal(response.metadata.uniqueSourceCount, 3);
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
	assert.equal(response.answer, "A");
	assert.deepEqual(response.results, [{ title: "S", url: "https://example.com/s", text: "Source text", summary: undefined, highlights: undefined, publishedDate: undefined }]);
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

test("findings report includes required sections and citations", () => {
	const report = renderFindingsReport({ query: "Question?" }, { answer: "Answer", results: [{ title: "T", url: "https://example.com" }], raw: { ok: true }, metadata: { researchMode: "standard", queryCount: 1, uniqueSourceCount: 1 } }, { rawOutputPath: "findings.raw.json" });
	for (const section of ["Executive Summary", "Key Findings", "Evidence and Sources", "Tradeoffs / Alternatives", "Recommendation / Decision Criteria", "Risks / Unknowns", "Revisit Conditions", "Research Metadata"]) assert.match(report, new RegExp(section.replace("/", "\\/")));
	assert.match(report, /https:\/\/example\.com/);
	assert.match(report, /Raw metadata sidecar: findings\.raw\.json/);
	assert.doesNotMatch(report, /Raw Exa Metadata/);
	assert.doesNotMatch(report, /```json/);
});

test("findings report uses structured Exa output and sanitizes markdown evidence headings", () => {
	const report = renderFindingsReport({ query: "Question?" }, {
		answer: "fallback",
		results: [{ title: "T", url: "https://example.com", highlights: ["# Huge Heading\nUseful excerpt"] }],
		raw: { output: { content: { executiveSummary: "Structured summary", keyFindings: ["Finding one"], tradeoffs: ["Tradeoff one"], recommendation: "Do it", risks: ["Risk one"], revisitConditions: ["When API changes"] } } },
		metadata: { researchMode: "standard", queryCount: 1, uniqueSourceCount: 1 },
	}, { rawOutputPath: "findings.raw.json" });
	assert.match(report, /Structured summary/);
	assert.match(report, /- Finding one/);
	assert.match(report, /Do it/);
	assert.doesNotMatch(report, /> # Huge Heading/);
	assert.match(report, /> Huge Heading Useful excerpt/);
});

test("Exa search body includes configured content and structured output options", () => {
	const client = new ExaClient({ apiKey: "key", fetchImpl: fakeFetch(), baseUrl: "https://exa.test" });
	const body = client.buildSearchBody({ query: "q", type: "deep", category: "news", maxAgeHours: 1, textMaxCharacters: 123, highlightsMaxCharacters: 456, highlightNumSentences: 2, highlightsPerUrl: 3, summaryQuery: "summarize", outputSchema: { type: "object" } });
	assert.equal(body.category, "news");
	assert.equal(body.maxAgeHours, 1);
	assert.deepEqual((body.contents as any).text, { maxCharacters: 123 });
	assert.deepEqual((body.contents as any).highlights, { maxCharacters: 456, numSentences: 2, highlightsPerUrl: 3 });
	assert.deepEqual((body.contents as any).summary, { query: "summarize" });
	assert.deepEqual(body.outputSchema, { type: "object" });
});

test("output report write path normalizes @ and relative paths", () => {
	const cwd = mkdtempSync(join(tmpdir(), "pi-web-tools-path-"));
	assert.equal(resolveOutputPath(cwd, "@docs/findings.md"), join(cwd, "docs", "findings.md"));
	assert.equal(defaultRawOutputPath(join(cwd, "docs", "findings.md")), join(cwd, "docs", "findings.raw.json"));
});

test("queryFile and contextGlob are resolved, sorted, and appended to system prompt", async () => {
	const cwd = mkdtempSync(join(tmpdir(), "pi-web-tools-context-"));
	writeFileSync(join(cwd, "prompt.txt"), "Question from file");
	writeFileSync(join(cwd, "context-b.md"), "B context");
	writeFileSync(join(cwd, "context-a.md"), "A context");
	writeFileSync(join(cwd, "other.md"), "skip");
	assert.deepEqual((await expandSimpleGlob(cwd, "@context-*.md")).map((path) => path.slice(cwd.length + 1)), ["context-a.md", "context-b.md"]);
	const prepared = await prepareResearchInput(cwd, { queryFile: "@prompt.txt", contextGlob: "context-*.md", systemPrompt: "Base" });
	assert.equal(prepared.query, "Question from file");
	assert.match(prepared.systemPrompt ?? "", /Base/);
	assert.match(prepared.systemPrompt ?? "", /A context/);
	assert.match(prepared.systemPrompt ?? "", /B context/);
	assert.ok((prepared.systemPrompt ?? "").indexOf("context-a.md") < (prepared.systemPrompt ?? "").indexOf("context-b.md"));
});

test("raw sidecar wraps metadata and provider payload", () => {
	const sidecar = buildRawSidecar({ answer: "A", results: [], raw: { answer: "A" }, metadata: { researchMode: "lite", uniqueSourceCount: 0 } }, "/tmp/findings.raw.json");
	assert.equal(sidecar.metadata.researchMode, "lite");
	assert.equal(sidecar.metadata.rawOutputPath, "/tmp/findings.raw.json");
	assert.deepEqual(sidecar.raw, { answer: "A" });
});

test("expanded web research renderer lists sources with a hard cap", () => {
	const theme = { fg: (_tone: string, text: string) => text };
	const sources = Array.from({ length: 22 }, (_, index) => ({ title: `Source ${index + 1}`, url: `https://example.com/${index + 1}` }));
	assert.deepEqual(renderWebResearchSourceTree(sources, theme, false), []);
	const lines = renderWebResearchSourceTree(sources, theme, true);
	assert.match(lines.join("\n"), /├─ \[1\] Source 1/);
	assert.match(lines.join("\n"), /https:\/\/example\.com\/1/);
	assert.match(lines.join("\n"), /\[20\] Source 20/);
	assert.doesNotMatch(lines.join("\n"), /\[21\] Source 21/);
	assert.match(lines.at(-1) ?? "", /… 2 more sources · UI cap 20\/22/);
});

test("provider labels are human-readable", () => {
	assert.equal(providerLabel("Web Research", "exa"), "Web Research (Exa)");
	assert.equal(providerLabel("Web Research", "exa", "deep-lite"), "Web Research (Exa-Lite)");
	assert.equal(providerLabel("Web Research", "exa", "deep-reasoning"), "Web Research (Exa-Deep)");
	assert.equal(providerDisplayName("http/auto"), "HTTP/Auto");
	assert.equal(providerDisplayName("github"), "GitHub");
	assert.equal(providerDisplayName("session"), "Session");
	assert.equal(providerDisplayName("resolving…"), "Resolving…");
	assert.equal(providerLabel("Web Search", "openai-native"), "Web Search (OpenAI Native)");
	assert.equal(providerLabel("Web Search", "exa-mcp"), "Web Search (Exa MCP)");
	assert.equal(providerLabel("Web Search", "duckduckgo"), "Web Search (DuckDuckGo)");
	assert.equal(providerDisplayName("openai-codex"), "Codex");
	assert.equal(providerDisplayName("gemini"), "Gemini");
});

test("web research display paths prefer cwd-relative paths", () => {
	assert.equal(displayWebResearchPath("/repo", "/repo/tmp/findings.md"), "tmp/findings.md");
	assert.equal(displayWebResearchPath("/repo", "/other/findings.md"), "/other/findings.md");
});
