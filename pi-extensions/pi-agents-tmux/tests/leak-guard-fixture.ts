// Run alone by preload-leak-guard.test.ts under the suite preload: makes one
// tempdir and removes it unless LEAK_GUARD_KEEP is set.
import { test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("tempdir owner", () => {
	const dir = mkdtempSync(join(tmpdir(), "leak-guard-"));
	if (!process.env.LEAK_GUARD_KEEP) rmSync(dir, { recursive: true });
});
