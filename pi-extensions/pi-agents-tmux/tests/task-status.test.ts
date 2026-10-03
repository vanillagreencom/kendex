import assert from "node:assert/strict";
import test, { after } from "node:test";
import { isTerminalTaskStatus, normalizePaneTaskStatus, isTaskTurnFinished, isTaskActive, taskStatus, singleResultIsError } from "../extensions/subagent/outcomes.js";
import * as tasks from "../extensions/subagent/tasks.js";
import { assertMissingArtifactStatus, cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";
import { assertCompletionPresentation, assertStallSelector, assertStoppedEvent } from "./extension-fixture.js";

after(cleanupTempRuntimes);

test("task diagnostics use the owner's working phase after a handoff reset", () => assertMissingArtifactStatus(tasks));
test("control: task diagnostics ignore the lost working task", async () => {
	const mutant = await importRuntimeCopy("tasks.ts", 'taskStatus(record.status).phase === "working"', 'false && taskStatus(record.status).phase === "working"') as typeof tasks;
	await assert.rejects(() => assertMissingArtifactStatus(mutant), assert.AssertionError);
});

test("parent aborted event is stopped in the persisted task result", () => assertStoppedEvent());
test("extension stall selector keeps the running task and drops the stopped one", () => assertStallSelector());
test("control: extension stall selector includes a stopped task", async () => {
	const mutant = await importRuntimeCopy("index.ts", "isTaskActive(record.status)", "true || isTaskActive(record.status)") as typeof import("../extensions/subagent/index.js");
	// Bound to the selector's answer, so a fixture failure cannot pass as the caught mutant.
	await assert.rejects(() => assertStallSelector(mutant.default), (error: unknown) => {
		assert.ok(error instanceof assert.AssertionError);
		assert.deepEqual(error.actual, ["running", "stopped"]);
		return true;
	});
});

test("completion tool and self-completion message use the status presentation owner", () => assertCompletionPresentation());
for (const indentation of ["\t\t\t", "\t\t"]) test(`control: completion presentation bypasses owner indent=${indentation.length}`, async () => {
	const mutant = await importRuntimeCopy("index.ts", `\n${indentation}const tone = taskStatus(statusWord).tone;`, `\n${indentation}const tone = "error";`) as typeof import("../extensions/subagent/index.js");
	await assert.rejects(() => assertCompletionPresentation(mutant.default), assert.AssertionError);
});

test("control: the old event mapper marks parent cancellation failed", async () => {
	const mutant = await importRuntimeCopy("index.ts", 'const payloadStatus = normalizePaneTaskStatus(event.status);', 'const raw = event.status;\n\t\tconst payloadStatus = raw === "queued" || raw === "running" || raw === "completed" || raw === "blocked" || raw === "failed" || raw === "needs_completion" ? raw : "unknown";') as typeof import("../extensions/subagent/index.js");
	await assert.rejects(() => assertStoppedEvent(mutant.default), assert.AssertionError);
});

// Raw status, normalized status, irreversible, finished turn, tone, completion activity.
const rows = [
	["queued", "queued", false, false, "warning", null],
	["running", "running", false, false, "warning", null],
	["unknown", "unknown", false, false, "warning", null],
	["completed", "completed", true, true, "success", "agent.task_completed"],
	["blocked", "blocked", true, true, "warning", "agent.task_blocked"],
	["failed", "failed", true, true, "error", "agent.task_failed"],
	["stopped", "stopped", true, true, "warning", null],
	["refused", "refused", true, true, "warning", null],
	["aborted", "stopped", true, true, "warning", null],
	["cancelled", "stopped", true, true, "warning", null],
	["waiting", "queued", false, false, "warning", null],
	[undefined, "unknown", false, false, "warning", null],
	["needs_completion", "needs_completion", false, true, "warning", "agent.needs_completion"],
] as const;

test("task status parsing retains unsuccessful outcomes without calling them failed", () => {
	for (const [raw, normalized, terminal, finished, tone, activity] of rows) {
		const status = normalizePaneTaskStatus(raw);
		const contract = taskStatus(status);
		assert.deepEqual([status, isTerminalTaskStatus(status), isTaskTurnFinished(status), isTaskActive(status), contract.tone, contract.activity], [normalized, terminal, finished, !finished, tone, activity]);
	}
});

test("control: the old parser loses parent cancellation", async () => {
	const mutant = await importRuntimeCopy("outcomes.ts", 'case "aborted":', 'case "aborted": return "unknown";') as typeof import("../extensions/subagent/outcomes.js");
	assert.throws(() => assert.equal(mutant.normalizePaneTaskStatus("aborted"), "stopped"), assert.AssertionError);
});

for (const [label, before, after, check] of [
	["recoverable turn stays active", 'return phase === "terminal" || phase === "recoverable";', 'return phase === "terminal";', (runtime: typeof import("../extensions/subagent/outcomes.js")) => assert.equal(runtime.isTaskTurnFinished("needs_completion"), true)],
	["active includes stopped", 'return !isTaskTurnFinished(status);', 'return isTaskTurnFinished(status);', (runtime: typeof import("../extensions/subagent/outcomes.js")) => assert.equal(runtime.isTaskActive("stopped"), false)],
	["result adapter ignores stopped", 'return taskStatus(singleResultStatus(result)).isError;', 'return false && taskStatus(singleResultStatus(result)).isError;', (runtime: typeof import("../extensions/subagent/outcomes.js")) => assert.equal(runtime.singleResultIsError({ status: "stopped", exitCode: 1 } as Parameters<typeof singleResultIsError>[0]), true)],
] as const) test(`control: ${label}`, async () => {
	const mutant = await importRuntimeCopy("outcomes.ts", before, after) as typeof import("../extensions/subagent/outcomes.js");
	assert.throws(() => check(mutant), assert.AssertionError);
});

test("control: the old terminal set keeps a stopped task running", async () => {
	const mutant = await importRuntimeCopy("outcomes.ts", 'case "stopped": return { phase: "terminal"', 'case "stopped": return { phase: "working"') as typeof import("../extensions/subagent/outcomes.js");
	assert.throws(() => assert.equal(mutant.isTerminalTaskStatus("stopped"), true), assert.AssertionError);
});
