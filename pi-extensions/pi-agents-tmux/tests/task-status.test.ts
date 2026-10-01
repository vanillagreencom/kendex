import assert from "node:assert/strict";
import test, { after } from "node:test";
import { isTerminalTaskStatus, normalizePaneTaskStatus } from "../extensions/subagent/tasks.js";
import { cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";
import { assertStoppedEvent } from "./extension-fixture.js";

after(cleanupTempRuntimes);

test("parent aborted event is stopped in the persisted task result", () => assertStoppedEvent());

test("control: the old event mapper marks parent cancellation failed", async () => {
	const mutant = await importRuntimeCopy("index.ts", 'const payloadStatus = normalizePaneTaskStatus(event.status);', 'const raw = event.status;\n\t\tconst payloadStatus = raw === "queued" || raw === "running" || raw === "completed" || raw === "blocked" || raw === "failed" || raw === "needs_completion" ? raw : "unknown";') as typeof import("../extensions/subagent/index.js");
	await assert.rejects(() => assertStoppedEvent(mutant.default), assert.AssertionError);
});

const rows = [
	["stopped", "stopped", true],
	["refused", "refused", true],
	["aborted", "stopped", true],
	["running", "running", false],
	["needs_completion", "needs_completion", false],
] as const;

test("task status parsing retains unsuccessful outcomes without calling them failed", () => {
	for (const [raw, normalized, terminal] of rows) {
		const status = normalizePaneTaskStatus(raw);
		assert.deepEqual([status, isTerminalTaskStatus(status)], [normalized, terminal]);
	}
});

test("control: the old parser loses parent cancellation", async () => {
	const mutant = await importRuntimeCopy("tasks.ts", 'if (status === "aborted") return "stopped";', 'if (status === "aborted") return "unknown";') as typeof import("../extensions/subagent/tasks.js");
	assert.throws(() => assert.equal(mutant.normalizePaneTaskStatus("aborted"), "stopped"), assert.AssertionError);
});

test("control: the old terminal set keeps a stopped task running", async () => {
	const mutant = await importRuntimeCopy("tasks.ts", 'return status === "completed" || status === "blocked" || status === "failed" || status === "stopped" || status === "refused";', 'return status === "completed" || status === "blocked" || status === "failed";') as typeof import("../extensions/subagent/tasks.js");
	assert.throws(() => assert.equal(mutant.isTerminalTaskStatus("stopped"), true), assert.AssertionError);
});
