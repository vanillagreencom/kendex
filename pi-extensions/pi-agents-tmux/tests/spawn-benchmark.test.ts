import assert from "node:assert/strict";
import test, { after } from "node:test";
import { cleanupTempRuntimes, importMainRuntime, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("benchmark fixture works with only the event ref and with main advanced", async () => {
	const { execFileSync } = await import("node:child_process");
	const { resolve } = await import("node:path");
	const { BENCHMARK_BASELINE } = await import("./browser-fixture.js");
	const root = tempRuntime();
	const source = resolve(import.meta.dir, "../../..");
	const env = { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root };
	const git = (args: string[]) => execFileSync("git", args, { cwd: root, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
	git(["init"]);
	git(["fetch", "--depth=1", `file://${source}`, "HEAD"]);
	git(["update-ref", "refs/heads/event", "FETCH_HEAD"]);
	assert.equal(git(["for-each-ref", "--format=%(refname)"]), "refs/heads/event");
	// CI supplies the pinned object explicitly before running npm test.
	git(["fetch", "--depth=1", `file://${source}`, BENCHMARK_BASELINE]);
	assert.equal((await importMainRuntime(root)).ref, BENCHMARK_BASELINE);
	git(["update-ref", "refs/remotes/origin/main", "refs/heads/event"]);
	assert.equal((await importMainRuntime(root)).ref, BENCHMARK_BASELINE);
});
