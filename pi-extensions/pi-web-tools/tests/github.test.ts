import assert from "node:assert/strict";
import test from "node:test";
import { ByteBudget } from "../src/extract/byte-budget.js";
import { parseGitHubUrl, extractGitHubUrl } from "../src/extract/github.js";
import { githubFixtureRepo } from "./fixtures.js";

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
test("GitHub blob extraction fetches the raw URL when clone is disabled", async () => {
	const seen: string[] = [];
	const result = await extractGitHubUrl("https://github.com/o/r/blob/main/a.txt", { cloneEnabled: false, fetchImpl: async (url) => { seen.push(String(url)); return new Response("file contents"); } });
	assert.deepEqual({ content: result?.content, seen }, { content: "file contents", seen: ["https://raw.githubusercontent.com/o/r/main/a.txt"] });
});

for (const { name, url, clone } of [
	{ name: "clone blob", url: "https://github.com/fixture/repo/blob/main/big.txt", clone: true },
	{ name: "clone README", url: "https://github.com/fixture/repo", clone: true },
	{ name: "raw blob", url: "https://github.com/fixture/repo/blob/main/big.txt", clone: false },
]) {
	test(`GitHub extraction cuts at the call byte budget and spends it: ${name}`, async (t) => {
		const big = "b".repeat(40);
		const { cache } = githubFixtureRepo(t, { "big.txt": big, "README.md": big });
		const budget = new ByteBudget(12);
		const result = await extractGitHubUrl(url, {
			cacheDir: cache,
			cloneEnabled: clone,
			byteBudget: budget,
			fetchImpl: async (target) => String(target).startsWith("https://api.github.com/") ? Response.json({ size: 1, default_branch: "main" }) : new Response(big),
		});
		const exhausted = (() => { try { budget.limitFor(1); return false; } catch { return true; } })();
		assert.deepEqual({ extraction: result?.metadata.extraction, cut: (result?.metadata as Record<string, unknown> | undefined)?.bodyTruncatedAtBytes, readme: result?.content.includes("b".repeat(12)) && !result.content.includes("b".repeat(13)), exhausted }, { extraction: clone ? "clone" : "raw", cut: 12, readme: true, exhausted: true });
	});
}
