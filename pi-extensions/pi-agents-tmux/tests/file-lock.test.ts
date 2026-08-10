import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import { acquireFileLock } from "../extensions/subagent/file-lock.js";

const tempDirs: string[] = [];

after(() => {
	for (const dir of tempDirs) rmSync(dir, { force: true, recursive: true });
});

function tempRuntime(): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-agents-file-lock-"));
	tempDirs.push(dir);
	return dir;
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
