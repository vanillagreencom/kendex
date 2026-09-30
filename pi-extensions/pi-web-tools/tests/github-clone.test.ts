import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { cloneOrUpdateRepo, readBlobFromCache, readReadmeFromCache, readTreeFromCache, summarizeTreeEntries } from "../src/extract/github-clone.js";
import { githubFixtureRepo, tempDir } from "./fixtures.js";

for (const row of [
	{ name: "blob", read: (repo: string) => readBlobFromCache(repo, "src/index.ts", 1024), expected: { content: "export const x = 1;\n", bytes: 20 } },
	{ name: "blob over the byte limit", read: (repo: string) => readBlobFromCache(repo, "src/index.ts", 6), expected: { content: "export", bytes: 20, truncatedAtBytes: 6 } },
	{ name: "missing blob", read: (repo: string) => readBlobFromCache(repo, "src/absent.ts", 1024), expected: null },
	{ name: "directory as blob", read: (repo: string) => readBlobFromCache(repo, "src", 1024), expected: null },
	{ name: "traversal", read: (repo: string) => readBlobFromCache(repo, "../outside.txt", 1024), expected: null },
	{ name: "tree excludes Git state", read: (repo: string) => readTreeFromCache(repo, "")?.entries.map((entry) => entry.name), expected: ["src", "README.md"] },
	{ name: "README", read: (repo: string) => readReadmeFromCache(repo, 1024), expected: { content: "# Hello\n\nbody", bytes: 13 } },
]) {
	test(`GitHub cache: ${row.name}`, async (t) => {
		const root = tempDir(t);
		const repo = join(root, "repo");
		mkdirSync(join(repo, "src"), { recursive: true });
		mkdirSync(join(repo, ".git"));
		writeFileSync(join(repo, "README.md"), "# Hello\n\nbody");
		writeFileSync(join(repo, "src", "index.ts"), "export const x = 1;\n");
		if (row.name === "traversal") writeFileSync(join(root, "outside.txt"), "outside");
		assert.deepEqual(await row.read(repo), row.expected);
	});
}

test("GitHub tree summary retains paths, size, and truncation marker", () => {
	const result = summarizeTreeEntries([{ name: "src", path: "src", type: "dir" }, { name: "README.md", path: "README.md", type: "file", size: 17 }], true);
	assert.deepEqual({ directory: result.includes("src/"), file: result.includes("README.md (17 bytes)"), truncated: result.includes("…") }, { directory: true, file: true, truncated: true });
});

test("cloneOrUpdateRepo clones the local fixture through its GitHub URL", async (t) => {
	const { cache, head } = githubFixtureRepo(t, { "README.md": "# Source repo\n" });
	const result = await cloneOrUpdateRepo("fixture", "repo", undefined, { cacheDir: cache });
	assert.deepEqual({ ...result, readme: (await readBlobFromCache(result.cachePath, "README.md", 1024))?.content }, {
		cachePath: join(cache, "fixture__repo"), headRef: head, cloned: true, updated: false, readme: "# Source repo\n",
	});
});
