import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { applyResearchMode, buildRawSidecar, defaultRawOutputPath, displayWebResearchPath, expandSimpleGlob, prepareResearchInput, renderFindingsReport, renderWebResearchSourceTree, resolveOutputPath, runExaResearch } from "../src/tools/web-research.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";
import { tempDir } from "./fixtures.js";

for (const { name, params, settings, expected } of [
	{ name: "lite", params: { researchMode: "lite" }, settings: undefined, expected: { researchMode: "lite", type: "deep-lite", numResults: 15, textMaxCharacters: 10000, timeoutSeconds: 300, highlightsMaxCharacters: 600, highlightsPerUrl: 1 } },
	{ name: "standard", params: { researchMode: "standard" }, settings: undefined, expected: { researchMode: "standard", type: "deep-reasoning", numResults: 50, textMaxCharacters: 16000, timeoutSeconds: 600, highlightsMaxCharacters: 900, highlightsPerUrl: 2 } },
	{ name: "full with explicit overrides", params: { researchMode: "full", type: "deep", numResults: 7, textMaxCharacters: 99 }, settings: undefined, expected: { researchMode: "full", type: "deep", numResults: 7, textMaxCharacters: 99, timeoutSeconds: 1800, highlightsMaxCharacters: 1200, highlightsPerUrl: 3 } },
	{ name: "profile with explicit count", params: { researchMode: "standard", numResults: 3 }, settings: { exaResearchModes: { standard: { type: "deep", numResults: 9, textMaxCharacters: 123, highlightsMaxCharacters: 456, highlightsPerUrl: 4, summaryQuery: "summarize", maxAgeHours: 2, category: "news" } } }, expected: { type: "deep", numResults: 3, textMaxCharacters: 123, highlightsMaxCharacters: 456, highlightsPerUrl: 4, summaryQuery: "summarize", maxAgeHours: 2, category: "news" } },
]) {
	test(`research mode: ${name}`, () => {
		const result = applyResearchMode(params as Parameters<typeof applyResearchMode>[0], settings ? { ...DEFAULT_SETTINGS, apiKeys: {}, warnings: [], ...settings } : undefined);
		assert.deepEqual(Object.fromEntries(Object.keys(expected).map((key) => [key, result[key as keyof typeof result]])), expected);
	});
}
test("research mode rejects an unknown profile", () => {
	assert.throws(() => applyResearchMode({ researchMode: "slow" as any }), Error);
});

test("full research executes additional queries and deduplicates URLs", async () => {
	const calls: Array<Parameters<typeof runExaResearch>[1]> = [];
	const client = {
		async deepResearch(params: Parameters<typeof runExaResearch>[1]) {
			calls.push(params);
			return { answer: `Answer for ${params.query}`, results: params.query === "main" ? [{ title: "A", url: "https://example.com/a" }, { title: "Dup", url: "https://example.com/dup" }] : [{ title: "Dup 2", url: "https://example.com/dup" }, { title: "B", url: "https://example.com/b" }], raw: { query: params.query }, metadata: { request: params } };
		},
	};
	const response = await runExaResearch(client, { query: "main", researchMode: "full", additionalQueries: ["second"] });
	assert.deepEqual({ calls: calls.length, numResults: calls[0]?.numResults, textMaxCharacters: calls[0]?.textMaxCharacters, highlightsMaxCharacters: calls[0]?.highlightsMaxCharacters, highlightsPerUrl: calls[0]?.highlightsPerUrl, schema: Boolean(calls[0]?.outputSchema), additionalQueries: calls[0]?.additionalQueries, urls: response.results.map((result) => result.url), queryCount: response.metadata.queryCount, sourceCount: response.metadata.sourceCount, uniqueSourceCount: response.metadata.uniqueSourceCount }, { calls: 2, numResults: 150, textMaxCharacters: 24000, highlightsMaxCharacters: 1200, highlightsPerUrl: 3, schema: true, additionalQueries: undefined, urls: ["https://example.com/a", "https://example.com/dup", "https://example.com/b"], queryCount: 2, sourceCount: 4, uniqueSourceCount: 3 });
});

for (const row of [
	{ name: "fallback report", raw: { ok: true }, highlights: undefined, present: [/https:\/\/example\.com/, /findings\.raw\.json/], absent: [/```json/] },
	{ name: "structured report", raw: { output: { content: { executiveSummary: "Structured summary", keyFindings: ["Finding one"], tradeoffs: ["Tradeoff one"], recommendation: "Do it", risks: ["Risk one"], revisitConditions: ["When API changes"] } } }, highlights: ["# Huge Heading\nUseful excerpt"], present: [/Structured summary/, /- Finding one/, /Do it/, /> Huge Heading Useful excerpt/], absent: [/> # Huge Heading/] },
]) {
	test(`findings report: ${row.name}`, () => {
		const report = renderFindingsReport({ query: "Question?" }, { answer: "Answer", results: [{ title: "T", url: "https://example.com", highlights: row.highlights }], raw: row.raw, metadata: { researchMode: "standard", queryCount: 1, uniqueSourceCount: 1 } }, { rawOutputPath: "findings.raw.json" });
		assert.deepEqual({ sections: report.split("\n").filter((line) => /^## /.test(line)).length, present: row.present.map((pattern) => pattern.test(report)), absent: row.absent.map((pattern) => pattern.test(report)) }, { sections: 9, present: row.present.map(() => true), absent: row.absent.map(() => false) });
	});
}

for (const { name, path, expected } of [
	{ name: "relative report", path: "@docs/findings.md", expected: "docs/findings.md" },
	{ name: "raw sidecar", path: "docs/findings.md", expected: "docs/findings.raw.json" },
]) {
	test(`research output path: ${name}`, (t) => {
		const cwd = tempDir(t);
		assert.equal(name === "raw sidecar" ? defaultRawOutputPath(join(cwd, path)) : resolveOutputPath(cwd, path), join(cwd, expected));
	});
}
test("research input loads query and ordered context files", async (t) => {
	const cwd = tempDir(t);
	writeFileSync(join(cwd, "prompt.txt"), "Question from file");
	writeFileSync(join(cwd, "context-b.md"), "B context");
	writeFileSync(join(cwd, "context-a.md"), "A context");
	writeFileSync(join(cwd, "other.md"), "skip");
	const paths = (await expandSimpleGlob(cwd, "@context-*.md")).map((path) => path.slice(cwd.length + 1));
	const prepared = await prepareResearchInput(cwd, { queryFile: "@prompt.txt", contextGlob: "context-*.md", systemPrompt: "Base" });
	const prompt = prepared.systemPrompt ?? "";
	assert.deepEqual({ paths, query: prepared.query, contents: [prompt.includes("Base"), prompt.includes("A context"), prompt.includes("B context")], sorted: prompt.indexOf("context-a.md") < prompt.indexOf("context-b.md") }, { paths: ["context-a.md", "context-b.md"], query: "Question from file", contents: [true, true, true], sorted: true });
});
test("research sidecar retains metadata and raw payload", () => {
	const sidecar = buildRawSidecar({ answer: "A", results: [], raw: { answer: "A" }, metadata: { researchMode: "lite", uniqueSourceCount: 0 } }, "/repo/findings.raw.json");
	assert.deepEqual({ mode: sidecar.metadata.researchMode, path: sidecar.metadata.rawOutputPath, raw: sidecar.raw }, { mode: "lite", path: "/repo/findings.raw.json", raw: { answer: "A" } });
});
for (const expanded of [false, true]) {
	test(`research source tree: expanded=${expanded}`, () => {
		const sources = Array.from({ length: 22 }, (_, index) => ({ title: `Source ${index + 1}`, url: `https://example.com/${index + 1}` }));
		const lines = renderWebResearchSourceTree(sources, { fg: (_tone: string, text: string) => text }, expanded);
		const text = lines.join("\n");
		assert.deepEqual(expanded ? { first: text.includes("├─ [1] Source 1"), url: text.split(/\s+/).some((token) => token === "https://example.com/1"), last: text.includes("[20] Source 20"), hidden: text.includes("[21] Source 21"), remaining: /2.*20\/22/.test(lines.at(-1) ?? "") } : lines, expanded ? { first: true, url: true, last: true, hidden: false, remaining: true } : []);
	});
}
for (const { path, expected } of [{ path: "/repo/tmp/findings.md", expected: "tmp/findings.md" }, { path: "/other/findings.md", expected: "/other/findings.md" }]) {
	test(`research display path: ${path}`, () => assert.equal(displayWebResearchPath("/repo", path), expected));
}
