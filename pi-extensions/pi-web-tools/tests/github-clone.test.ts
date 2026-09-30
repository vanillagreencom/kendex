import assert from "node:assert/strict";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join, posix, win32 } from "node:path";
import test from "node:test";
import { cloneOrUpdateRepo, isInside, readBlobFromCache, readReadmeFromCache, readTreeFromCache, summarizeTreeEntries } from "../src/extract/github-clone.js";
import type { UrlReads } from "../src/extract/byte-budget.js";
import { githubFixtureRepo, tempDir, urlReads } from "./fixtures.js";

for (const row of [
	{ name: "blob", read: (repo: string, reads: UrlReads) => readBlobFromCache(repo, "src/index.ts", reads), expected: { content: "export const x = 1;\n", bytes: 20 } },
	{ name: "blob over the call budget", budget: 6, read: (repo: string, reads: UrlReads) => readBlobFromCache(repo, "src/index.ts", reads), expected: { content: "export", bytes: 20, cut: { atBytes: 6, by: "call-budget" } } },
	{ name: "missing blob", read: (repo: string, reads: UrlReads) => readBlobFromCache(repo, "src/absent.ts", reads), expected: null },
	{ name: "directory as blob", read: (repo: string, reads: UrlReads) => readBlobFromCache(repo, "src", reads), expected: null },
	{ name: "traversal", read: (repo: string, reads: UrlReads) => readBlobFromCache(repo, "../outside.txt", reads), expected: null },
	{ name: "symlinked file outside the cache", read: (repo: string, reads: UrlReads) => readBlobFromCache(repo, "src/escape.txt", reads), expected: null },
	{ name: "symlinked README outside the cache", read: (repo: string, reads: UrlReads) => readReadmeFromCache(join(repo, "src"), reads), expected: null },
	{ name: "symlinked file inside the cache", read: (repo: string, reads: UrlReads) => readBlobFromCache(repo, "src/alias.ts", reads), expected: { content: "export const x = 1;\n", bytes: 20 } },
	{ name: "tree excludes Git state", read: async (repo: string) => (await readTreeFromCache(repo, ""))?.entries.map((entry) => entry.name), expected: ["src", "outer", "README.md"] },
	{ name: "symlinked directory outside the cache", read: (repo: string) => readTreeFromCache(repo, "outer"), expected: null },
	{ name: "README", read: (repo: string, reads: UrlReads) => readReadmeFromCache(repo, reads), expected: { content: "# Hello\n\nbody", bytes: 13 } },
]) {
	test(`GitHub cache: ${row.name}`, async (t) => {
		const root = tempDir(t);
		const repo = join(root, "repo");
		mkdirSync(join(repo, "src"), { recursive: true });
		mkdirSync(join(repo, ".git"));
		mkdirSync(join(root, "outside"));
		writeFileSync(join(repo, "README.md"), "# Hello\n\nbody");
		writeFileSync(join(repo, "src", "index.ts"), "export const x = 1;\n");
		writeFileSync(join(root, "outside.txt"), "outside");
		writeFileSync(join(root, "outside", "secret.txt"), "secret");
		symlinkSync(join(root, "outside.txt"), join(repo, "src", "escape.txt"));
		symlinkSync(join(root, "outside.txt"), join(repo, "src", "README.md"));
		symlinkSync(join(repo, "src", "index.ts"), join(repo, "src", "alias.ts"));
		symlinkSync(join(root, "outside"), join(repo, "outer"));
		assert.deepEqual(await row.read(repo, urlReads(t, row.budget)), row.expected);
	});
}

// The symlink rows above run on POSIX only; a target on another Windows drive or UNC share is reachable only through win32 rules.
for (const row of [
	{ name: "POSIX file under the cache", paths: posix, parent: "/cache", child: "/cache/src/a.ts", expected: true },
	{ name: "POSIX sibling of the cache", paths: posix, parent: "/cache", child: "/other/a.ts", expected: false },
	{ name: "POSIX cache root itself", paths: posix, parent: "/cache", child: "/cache", expected: false },
	{ name: "Windows file under the cache", paths: win32, parent: "C:\\cache", child: "C:\\cache\\src\\a.ts", expected: true },
	{ name: "Windows sibling on the same drive", paths: win32, parent: "C:\\cache", child: "C:\\other\\a.ts", expected: false },
	{ name: "Windows target on another drive", paths: win32, parent: "C:\\cache", child: "D:\\secret.txt", expected: false },
	{ name: "Windows target on a UNC share", paths: win32, parent: "C:\\cache", child: "\\\\server\\share\\secret.txt", expected: false },
]) {
	test(`GitHub cache containment: ${row.name}`, () => {
		assert.equal(isInside(row.paths, row.parent, row.child), row.expected);
	});
}

test("GitHub tree summary retains paths, size, and truncation marker", () => {
	const result = summarizeTreeEntries([{ name: "src", path: "src", type: "dir" }, { name: "README.md", path: "README.md", type: "file", size: 17 }], true);
	assert.deepEqual({ directory: result.includes("src/"), file: result.includes("README.md (17 bytes)"), truncated: result.includes("…") }, { directory: true, file: true, truncated: true });
});

test("cloneOrUpdateRepo clones the local fixture through its GitHub URL", async (t) => {
	const { cache, head } = githubFixtureRepo(t, { "README.md": "# Source repo\n" });
	const result = await cloneOrUpdateRepo("fixture", "repo", undefined, { cacheDir: cache });
	assert.deepEqual({ ...result, readme: (await readBlobFromCache(result.cachePath, "README.md", urlReads(t)))?.content }, {
		cachePath: join(cache, "fixture__repo"), headRef: head, cloned: true, updated: false, readme: "# Source repo\n",
	});
});
