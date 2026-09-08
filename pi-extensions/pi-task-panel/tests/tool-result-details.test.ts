import assert from "node:assert/strict";
import test from "node:test";
import { isTaskPanelToolResultBoundedState, taskPanelToolResultState } from "../extensions/tool-result-details.js";
import { stateWithTasks } from "./lib/task-state.ts";

for (const row of [
	{ name: "small full snapshot", count: 3, text: "Task", forceFull: false, bounded: false, reason: undefined, sampled: undefined, omitted: undefined },
	{ name: "task count bounds the snapshot", count: 200, text: "x".repeat(80), forceFull: false, bounded: true, reason: "task-count-threshold", sampled: 20, omitted: 180 },
	{ name: "bytes bound a snapshot below the task count threshold", count: 2, text: "x".repeat(80 * 1024), forceFull: false, bounded: true, reason: "payload-too-large", sampled: 2, omitted: 0 },
	{ name: "sidecar failure forces full snapshot", count: 200, text: "x".repeat(80), forceFull: true, bounded: false, reason: undefined, sampled: undefined, omitted: undefined },
] as const) {
	test(row.name, () => {
		const state = stateWithTasks(row.count, row.text);
		const details = taskPanelToolResultState(state, { forceFullSnapshot: row.forceFull });
		assert.equal(isTaskPanelToolResultBoundedState(details), row.bounded);
		assert.notEqual(details, state);
		if (isTaskPanelToolResultBoundedState(details)) {
			assert.equal(details.reason, row.reason);
			assert.equal(details.counts.tasks, row.count);
			assert.equal(details.taskIds.length, row.sampled);
			assert.equal(details.omitted.tasks, row.omitted);
			assert.equal(details.fullSnapshot, false);
			assert.ok(Buffer.byteLength(JSON.stringify(details), "utf8") <= 4 * 1024);
			assert.ok(Buffer.byteLength(JSON.stringify({ action: "replace", message: `${row.count} task(s), ${row.count} remaining`, summary: `${row.count} tasks written`, state: details }), "utf8") <= 4 * 1024);
		} else {
			assert.equal(details.tasks.length, row.count);
		}
	});
}
