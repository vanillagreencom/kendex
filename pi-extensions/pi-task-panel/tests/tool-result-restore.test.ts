import assert from "node:assert/strict";
import { test } from "bun:test";
import { applyTaskPanelToolResultRestore, taskPanelToolResultState } from "../extensions/tool-result-details.js";
import { stateWithTasks } from "./lib/task-state.ts";

type State = ReturnType<typeof stateWithTasks>;
function hasStateContent(state: State): boolean {
	return state.tasks.length > 0 || state.phases.length > 0;
}
function normalizeState(value: unknown): State { return value as State; }

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

