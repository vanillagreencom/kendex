import assert from "node:assert/strict";
import test, { after } from "node:test";
import * as renderers from "../extensions/subagent/renderers.js";
import { formatTaskRecordResult } from "../extensions/subagent/renderers.js";
import { COMPLETION_SUMMARY_UNAVAILABLE } from "../extensions/subagent/format.js";
import { ICONS } from "../extensions/subagent/types.js";
import { record, cleanupTempRuntimes, importRuntimeCopy, toneTheme } from "./browser-fixture.js";

after(cleanupTempRuntimes);

const taskId = "reviewer-arch-1700000000-77abfc41";
const longSummary = Array.from({ length: 80 }, (_, index) => `finding-${index}`).join(" ");

for (const status of ["stopped", "refused"] as const) test(`${status} completion presentation and missing summary`, () => {
	const task = record("scout", taskId, "2026-05-14T05:00:00Z", { status });
	assert.deepEqual([renderers.paneCompletionIcon(status, toneTheme as any), renderers.paneCompletionStatus(status, toneTheme as any), renderers.paneCompletionTone(status), renderers.taskRecordSummary(task)], [`<warning>${ICONS.warning}</warning>`, `<warning>${status}</warning>`, "warning", COMPLETION_SUMMARY_UNAVAILABLE]);
	assert.ok(formatTaskRecordResult(task).includes(COMPLETION_SUMMARY_UNAVAILABLE));
});

for (const [surface, before, replacement, check] of [
	["icon", 'return theme.fg(presentation.tone, presentation.icon);', 'return theme.fg("muted", ICONS.dotSmall);', (runtime: typeof renderers) => assert.equal(runtime.paneCompletionIcon("stopped", toneTheme as any), `<warning>${ICONS.warning}</warning>`)],
	["label", 'return theme.fg(taskStatus(status).tone, taskStatus(status).label);', 'return theme.fg("muted", status);', (runtime: typeof renderers) => assert.equal(runtime.paneCompletionStatus("stopped", toneTheme as any), "<warning>stopped</warning>")],
	["tone", 'return taskStatus(status).tone;', 'return "muted";', (runtime: typeof renderers) => assert.equal(runtime.paneCompletionTone("stopped"), "warning")],
	["summary", 'return isTaskTurnFinished(record.status) ? COMPLETION_SUMMARY_UNAVAILABLE : "No summary yet.";', 'return false && isTaskTurnFinished(record.status) ? COMPLETION_SUMMARY_UNAVAILABLE : "No summary yet.";', (runtime: typeof renderers) => assert.equal(runtime.taskRecordSummary(record("scout", taskId, "2026-05-14T05:00:00Z", { status: "stopped" })), COMPLETION_SUMMARY_UNAVAILABLE)],
	["result", 'const summary = taskRecordSummary(record);', 'const summary = record.summary;', (runtime: typeof renderers) => assert.ok(runtime.formatTaskRecordResult(record("scout", taskId, "2026-05-14T05:00:00Z", { status: "stopped" })).includes(COMPLETION_SUMMARY_UNAVAILABLE))],
] as const) test(`control: completion ${surface} bypasses the status owner`, async () => {
	const mutant = await importRuntimeCopy("renderers.ts", before, replacement) as typeof renderers;
	assert.throws(() => check(mutant), assert.AssertionError);
});

test("the persisted summary reaches the result text whole", () => {
	const taskRecord = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { summary: longSummary, transcriptPath: "/tmp/reviewer-arch.jsonl" });
	assert.ok(formatTaskRecordResult(taskRecord).includes(longSummary));
});
