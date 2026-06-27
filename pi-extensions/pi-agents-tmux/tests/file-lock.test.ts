import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { acquireFileLock } from "../extensions/subagent/file-lock.js";

function tempRuntime(): string {
	return mkdtempSync(join(tmpdir(), "pi-agents-file-lock-"));
}

test("acquireFileLock waits long enough to reap stale locks before timing out", async () => {
	const runtimeRoot = tempRuntime();
	const filePath = join(runtimeRoot, "tasks.json");
	const lockDir = `${filePath}.lock`;
	mkdirSync(lockDir, { recursive: true });

	const release = await acquireFileLock(filePath, { staleMs: 100, retryMs: 5, timeoutMs: 1 });

	assert.equal(existsSync(lockDir), true);
	await release();
	assert.equal(existsSync(lockDir), false);
});
