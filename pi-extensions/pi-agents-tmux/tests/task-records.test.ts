import assert from "node:assert/strict";
import test, { after } from "node:test";
import { TaskRegistryReader, monitorStatusIsTerminal } from "../extensions/subagent/task-records.js";
import { assertRegistryReaderCache, cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("stopped and refused tasks leave the active Monitor list", () => {
	for (const status of ["stopped", "refused"]) assert.equal(monitorStatusIsTerminal(status), true, status);
});

test("control: the old terminal set keeps stopped tasks active", async () => {
	const mutant = await importRuntimeCopy("task-records.ts", 'status === "completed" || status === "failed" || status === "stopped" || status === "refused" || status === "blocked" || status === "needs_completion" || status === "cancelled"', 'status === "completed" || status === "failed" || status === "blocked" || status === "needs_completion" || status === "cancelled"') as typeof import("../extensions/subagent/task-records.js");
	assert.throws(() => assert.equal(mutant.monitorStatusIsTerminal("stopped"), true), assert.AssertionError);
});

test("the reader keeps only the latest runtime snapshot and clears it at teardown", async () => {
	await assertRegistryReaderCache(new TaskRegistryReader());
});

test("must-fail control: reading registry content again violates the cache assertion", async () => {
	const mutant = await importRuntimeCopy("task-records.ts",
		"cached?.filePath === filePath && cached.version === version",
		"cached?.filePath === filePath && cached.version === version && false") as typeof import("../extensions/subagent/task-records.js");
	await assert.rejects(() => assertRegistryReaderCache(new mutant.TaskRegistryReader()), assert.AssertionError);
});
