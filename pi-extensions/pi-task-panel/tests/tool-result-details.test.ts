import assert from "node:assert/strict";
import test from "node:test";

import {
	applyTaskPanelToolResultRestore,
	isTaskPanelToolResultBoundedState,
	taskPanelToolResultState,
} from "../extensions/tool-result-details.js";

function stateWithTasks(count: number, taskText = "Task"): any {
	return {
		autoShownThisSession: true,
		hiddenByUser: false,
		lastVisiblePanel: "compact",
		panel: "compact",
		phases: [{ id: "phase-1", order: 0, title: "Phase" }],
		tasks: Array.from({ length: count }, (_value, index) => ({
			content: `${taskText} ${index}`,
			id: `task-${index}`,
			notes: [`note ${index}`],
			order: index,
			phaseId: "phase-1",
			status: index === 0 ? "in_progress" : "pending",
		})),
		updatedAt: "2026-05-20T00:00:00.000Z",
		version: 1,
	};
}

function hasStateContent(state: any): boolean {
	return state.tasks.length > 0 || state.phases.length > 0;
}

function normalizeState(value: unknown): any {
	return value;
}

test("small task-panel tool result details keep full state for legacy restore", () => {
	const state = stateWithTasks(3);
	const detailsState = taskPanelToolResultState(state);
	assert.equal(isTaskPanelToolResultBoundedState(detailsState), false);
	assert.equal((detailsState as any).tasks.length, 3);
	assert.notEqual(detailsState, state);
});

test("large task-panel tool result details downgrade to a compact manifest", () => {
	const state = stateWithTasks(200, "x".repeat(80));
	const detailsState = taskPanelToolResultState(state);
	assert.equal(isTaskPanelToolResultBoundedState(detailsState), true);
	assert.equal((detailsState as any).counts.tasks, 200);
	assert.equal((detailsState as any).taskIds.length, 20);
	assert.equal((detailsState as any).omitted.tasks, 180);
	assert.equal((detailsState as any).fullSnapshot, false);
	assert.ok(Buffer.byteLength(JSON.stringify(detailsState), "utf8") <= 4 * 1024);
	assert.ok(Buffer.byteLength(JSON.stringify({ action: "replace", message: "200 task(s), 200 remaining", summary: "200 tasks written", state: detailsState }), "utf8") <= 4 * 1024);
});

test("oversized task-panel tool result details downgrade even below task-count threshold", () => {
	const state = stateWithTasks(2, "x".repeat(80 * 1024));
	const detailsState = taskPanelToolResultState(state);
	assert.equal(isTaskPanelToolResultBoundedState(detailsState), true);
	assert.equal((detailsState as any).reason, "payload-too-large");
	assert.equal((detailsState as any).counts.tasks, 2);
	assert.ok(Buffer.byteLength(JSON.stringify(detailsState), "utf8") <= 4 * 1024);
	assert.ok(Buffer.byteLength(JSON.stringify({ action: "replace", message: "2 task(s), 2 remaining", summary: "2 tasks written", state: detailsState }), "utf8") <= 4 * 1024);
});

test("tool-result restore barrier re-applies sidecar state after older full details", () => {
	const sidecarState = stateWithTasks(200, "sidecar");
	const olderState = stateWithTasks(1, "older");
	let currentState = sidecarState;

	currentState = applyTaskPanelToolResultRestore({
		currentState,
		detailsState: olderState,
		hasStateContent,
		normalizeState,
		sidecarState,
	});
	assert.equal(currentState.tasks[0]?.content, "older 0");

	currentState = applyTaskPanelToolResultRestore({
		currentState,
		detailsState: taskPanelToolResultState(sidecarState),
		hasStateContent,
		normalizeState,
		sidecarState,
	});
	assert.equal(currentState.tasks.length, 200);
	assert.equal(currentState.tasks[0]?.content, "sidecar 0");
});

test("sidecar write failure can force full tool-result state fallback", () => {
	const state = stateWithTasks(200, "x".repeat(80));
	const detailsState = taskPanelToolResultState(state, { forceFullSnapshot: true });
	assert.equal(isTaskPanelToolResultBoundedState(detailsState), false);
	assert.equal((detailsState as any).tasks.length, 200);
});
