import assert from "node:assert/strict";
import test, { after } from "node:test";
import { TaskRegistryReader, monitorStatusIsTerminal, monitorStatusIsActive, monitorStatusFromDashboard } from "../extensions/subagent/task-records.js";
import { assertRegistryReaderCache, cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("stopped and refused tasks leave the active Monitor list", () => {
	for (const status of ["stopped", "refused"]) assert.equal(monitorStatusIsTerminal(status), true, status);
});

test("control: the old terminal set keeps stopped tasks active", async () => {
	const mutant = await importRuntimeCopy("task-records.ts", 'return isTaskTurnFinished(status);', 'return status !== "stopped" && isTaskTurnFinished(status);') as typeof import("../extensions/subagent/task-records.js");
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

for (const [surface, before, replacement, check] of [
	["active", 'return isTaskActive(status);', 'return true || isTaskActive(status);', (runtime: typeof import("../extensions/subagent/task-records.js")) => assert.equal(runtime.monitorStatusIsActive("stopped"), false)],
	["dashboard", 'return normalizePaneTaskStatus(status);', 'return status;', (runtime: typeof import("../extensions/subagent/task-records.js")) => assert.equal(runtime.monitorStatusFromDashboard("waiting"), "queued")],
] as const) test(`control: Monitor ${surface} bypasses normalization`, async () => {
	assert.deepEqual([monitorStatusIsActive("stopped"), monitorStatusFromDashboard("waiting")], [false, "queued"]);
	const mutant = await importRuntimeCopy("task-records.ts", before, replacement) as typeof import("../extensions/subagent/task-records.js");
	assert.throws(() => check(mutant), assert.AssertionError);
});
