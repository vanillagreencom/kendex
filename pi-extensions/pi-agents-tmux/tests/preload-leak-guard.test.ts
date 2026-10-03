import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

// The preload's teardown check fails a run that leaves a tempdir behind. The
// kept row is its must-fail control; the removed row shows the same run passes
// once the creating test cleans up.
for (const [label, keep, status, leaked] of [
	["removed tempdir passes", "", 0, false],
	["control: kept tempdir fails the run", "1", 1, true],
] as const) test(`preload leak guard: ${label}`, () => {
	// Bun writes its own state under HOME, so the child gets one this test removes.
	const home = mkdtempSync(join(tmpdir(), "leak-guard-home-"));
	let run: ReturnType<typeof spawnSync<string>>;
	try {
		run = spawnSync(process.execPath, ["--no-install", "test", "./tests/leak-guard-fixture.ts"], {
			cwd: resolve(import.meta.dir, ".."),
			encoding: "utf8",
			// The preload's tmux reads its own server back through a tab, which the
			// C locale prints as an underscore.
			env: { PATH: process.env.PATH, HOME: home, TMPDIR: home, LANG: "C.UTF-8", LEAK_GUARD_KEEP: keep },
		});
	} finally {
		rmSync(home, { force: true, recursive: true });
	}
	assert.equal(run.status, status, run.stderr);
	assert.equal(/leaked 1 tmp dir\(s\).*leak-guard-/.test(run.stderr), leaked, run.stderr);
});
