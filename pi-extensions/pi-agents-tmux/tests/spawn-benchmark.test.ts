import assert from "node:assert/strict";
import test, { after } from "node:test";
import { cleanupTempRuntimes, importMainRuntime, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("benchmark fixture works with only the event ref and with main advanced", async () => {
	const { execFileSync } = await import("node:child_process");
	const { writeFileSync } = await import("node:fs");
	const { join, resolve } = await import("node:path");
	const { BENCHMARK_BASELINE } = await import("./browser-fixture.js");
	const root = tempRuntime();
	const source = resolve(import.meta.dir, "../../..");
	const env = { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root };
	const git = (args: string[]) => execFileSync("git", args, { cwd: root, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
	git(["init", "-b", "event"]);
	// Borrow the CI-supplied baseline objects without copying the source tree.
	writeFileSync(join(root, ".git/objects/info/alternates"), `${git(["-C", source, "rev-parse", "--path-format=absolute", "--git-path", "objects"])}\n`);
	git(["config", "user.name", "Fixture"]);
	git(["config", "user.email", "fixture@example.invalid"]);
	const tree = execFileSync("git", ["mktree"], { cwd: root, env, input: "", encoding: "utf8" }).trim();
	const event = git(["commit-tree", tree, "-p", BENCHMARK_BASELINE, "-m", "Empty event"]);
	git(["update-ref", "refs/heads/event", event]);
	assert.equal(git(["for-each-ref", "--format=%(refname)"]), "refs/heads/event");
	assert.equal((await importMainRuntime(root)).ref, BENCHMARK_BASELINE);
	git(["update-ref", "refs/remotes/origin/main", "refs/heads/event"]);
	assert.equal(git(["rev-parse", "origin/main"]), event);
	assert.equal((await importMainRuntime(root)).ref, BENCHMARK_BASELINE);
	// A baseline replaced by the empty event cannot supply the runtime.
	git(["replace", BENCHMARK_BASELINE, event]);
	await assert.rejects(importMainRuntime(root));
});
