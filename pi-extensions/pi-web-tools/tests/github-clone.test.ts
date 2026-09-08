import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { cloneOrUpdateRepo, readBlobFromCache, readReadmeFromCache, readTreeFromCache, summarizeTreeEntries } from "../src/extract/github-clone.js";
import { isolateEnvironment, tempDir } from "./fixtures.js";

for (const row of [
	{ name: "blob", read: (repo: string) => readBlobFromCache(repo, "src/index.ts"), expected: { content: "export const x = 1;\n", bytes: 20 } },
	{ name: "traversal", read: (repo: string) => readBlobFromCache(repo, "../outside.txt"), expected: null },
	{ name: "tree excludes Git state", read: (repo: string) => readTreeFromCache(repo, "")?.entries.map((entry) => entry.name), expected: ["src", "README.md"] },
	{ name: "README", read: (repo: string) => readReadmeFromCache(repo), expected: "# Hello\n\nbody" },
]) {
	test(`GitHub cache: ${row.name}`, (t) => {
		const root = tempDir(t);
		const repo = join(root, "repo");
		mkdirSync(join(repo, "src"), { recursive: true });
		mkdirSync(join(repo, ".git"));
		writeFileSync(join(repo, "README.md"), "# Hello\n\nbody");
		writeFileSync(join(repo, "src", "index.ts"), "export const x = 1;\n");
		if (row.name === "traversal") writeFileSync(join(root, "outside.txt"), "outside");
		assert.deepEqual(row.read(repo), row.expected);
	});
}

test("GitHub tree summary retains paths, size, and truncation marker", () => {
	const result = summarizeTreeEntries([{ name: "src", path: "src", type: "dir" }, { name: "README.md", path: "README.md", type: "file", size: 17 }], true);
	assert.deepEqual({ directory: result.includes("src/"), file: result.includes("README.md (17 bytes)"), truncated: result.includes("…") }, { directory: true, file: true, truncated: true });
});

test("cloneOrUpdateRepo clones the local fixture through its GitHub URL", async (t) => {
	isolateEnvironment(t, [...Object.keys(process.env).filter((key) => key.startsWith("GIT_")), "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"]);
	const root = tempDir(t);
	const source = join(root, "source");
	const cache = join(root, "cache");
	const config = join(root, "gitconfig");
	process.env.GIT_CONFIG_GLOBAL = config;
	process.env.GIT_CONFIG_NOSYSTEM = "1";
	process.env.GIT_CONFIG_COUNT = "1";
	process.env.GIT_CONFIG_KEY_0 = "core.hooksPath";
	process.env.GIT_CONFIG_VALUE_0 = join(root, "no-hooks");
	const git = (...args: string[]) => execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
	git("init", "-q", "--initial-branch=main", source);
	writeFileSync(join(source, "README.md"), "# Source repo\n");
	git("-C", source, "add", "README.md");
	git("-C", source, "-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgSign=false", "commit", "-q", "-m", "init");
	const head = git("-C", source, "rev-parse", "HEAD");
	git("config", "--file", config, `url.${source}.insteadOf`, "https://github.com/fixture/repo.git");
	const result = await cloneOrUpdateRepo("fixture", "repo", undefined, { cacheDir: cache });
	assert.deepEqual({ ...result, readme: readBlobFromCache(result.cachePath, "README.md")?.content }, {
		cachePath: join(cache, "fixture__repo"), headRef: head, cloned: true, updated: false, readme: "# Source repo\n",
	});
});
