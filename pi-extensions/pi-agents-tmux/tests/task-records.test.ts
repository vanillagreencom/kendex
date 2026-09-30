import assert from "node:assert/strict";
import test, { after } from "node:test";
import { TaskRegistryReader } from "../extensions/subagent/task-records.js";
import { assertRegistryReaderCache, cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("the reader keeps only the latest runtime snapshot and clears it at teardown", async () => {
	await assertRegistryReaderCache(new TaskRegistryReader());
});

test("must-fail control: reading registry content again violates the cache assertion", async () => {
	const mutant = await importRuntimeCopy("task-records.ts",
		"cached?.filePath === filePath && cached.version === version",
		"cached?.filePath === filePath && cached.version === version && false") as typeof import("../extensions/subagent/task-records.js");
	await assert.rejects(() => assertRegistryReaderCache(new mutant.TaskRegistryReader()), assert.AssertionError);
});
