import assert from "node:assert/strict";
import test from "node:test";
import { readTextWithin } from "../src/extract/byte-budget.js";
import { parseGitHubUrl, extractGitHubUrl } from "../src/extract/github.js";
import { githubFixtureRepo, urlReads } from "./fixtures.js";

for (const { url, kind, rawUrl } of [
	{ url: "https://github.com/o/r", kind: "repo", rawUrl: undefined },
	{ url: "https://github.com/o/r/blob/main/src/index.ts", kind: "blob", rawUrl: "https://raw.githubusercontent.com/o/r/main/src/index.ts" },
	{ url: "https://github.com/o/r/tree/main/src", kind: "tree", rawUrl: undefined },
	{ url: "https://github.com/o/r/commit/abc", kind: "commit", rawUrl: undefined },
]) {
	test(`GitHub URL: ${kind}`, () => {
		const result = parseGitHubUrl(url);
		assert.deepEqual({ kind: result?.kind, ...(rawUrl ? { rawUrl: result?.rawUrl } : {}) }, { kind, ...(rawUrl ? { rawUrl } : {}) });
	});
}
test("GitHub blob extraction fetches the raw URL when clone is disabled", async (t) => {
	const seen: string[] = [];
	const result = await extractGitHubUrl("https://github.com/o/r/blob/main/a.txt", { cloneEnabled: false, reads: urlReads(t), fetchImpl: async (url) => { seen.push(String(url)); return new Response("file contents"); } });
	assert.deepEqual({ content: result?.content, seen }, { content: "file contents", seen: ["https://raw.githubusercontent.com/o/r/main/a.txt"] });
});

const big = "b".repeat(40);
for (const { name, url, clone, budget, expected } of [
	{ name: "clone blob", url: "https://github.com/fixture/repo/blob/main/big.txt", clone: true, budget: 12, expected: { extraction: "clone", cut: 12, content: true, left: "ByteBudgetExhausted" } },
	{ name: "clone README", url: "https://github.com/fixture/repo", clone: true, budget: 12, expected: { extraction: "clone", cut: 12, content: true, left: "ByteBudgetExhausted" } },
	{ name: "raw blob", url: "https://github.com/fixture/repo/blob/main/big.txt", clone: false, budget: 12, expected: { extraction: "raw", cut: 12, content: true, left: "ByteBudgetExhausted" } },
	{ name: "API README", url: "https://github.com/fixture/repo", clone: false, budget: 12, expected: { extraction: "repo", cut: 12, content: true, left: "ByteBudgetExhausted" } },
	{ name: "clone blob within the budget", url: "https://github.com/fixture/repo/blob/main/big.txt", clone: true, budget: 45, expected: { extraction: "clone", content: false, left: "01234" } },
	{ name: "clone README after the budget is spent", url: "https://github.com/fixture/repo", clone: true, budget: 0, expected: { error: "ByteBudgetExhausted", requests: ["https://api.github.com/repos/fixture/repo"] } },
	{ name: "API README after the budget is spent", url: "https://github.com/fixture/repo", clone: false, budget: 0, expected: { error: "ByteBudgetExhausted", requests: ["https://api.github.com/repos/fixture/repo", "https://raw.githubusercontent.com/fixture/repo/HEAD/README.md"] } },
]) {
	test(`GitHub extraction reads under the call byte budget: ${name}`, async (t) => {
		const { cache } = githubFixtureRepo(t, { "big.txt": big, "README.md": big });
		const reads = urlReads(t, budget);
		const requests: string[] = [];
		const outcome = await extractGitHubUrl(url, {
			cacheDir: cache,
			cloneEnabled: clone,
			reads,
			fetchImpl: async (target) => (requests.push(String(target)), String(target).startsWith("https://api.github.com/") ? Response.json({ size: 1, default_branch: "main", full_name: "fixture/repo" }) : new Response(big)),
		}).then(async (result) => ({
			extraction: result?.metadata.extraction,
			...(expected.cut === undefined ? {} : { cut: (result?.metadata as Record<string, unknown> | undefined)?.bodyTruncatedAtBytes }),
			content: Boolean(result?.content.includes("b".repeat(12)) && !result.content.includes("b".repeat(13))),
			left: await readTextWithin(new Response("0123456789"), reads).then((read) => read.text, (error: Error) => error.name),
		}), (error: Error) => ({ error: error.name, requests }));
		assert.deepEqual(outcome, expected);
	});
}
