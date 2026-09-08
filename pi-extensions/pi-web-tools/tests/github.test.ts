import assert from "node:assert/strict";
import test from "node:test";
import { parseGitHubUrl, extractGitHubUrl } from "../src/extract/github.js";

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
