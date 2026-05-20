import assert from "node:assert/strict";
import test from "node:test";
import {
	applyTaskPanelContentVisibility,
	createTaskPanelVisibility,
	cycleTaskPanelVisibility,
	rememberTaskPanelVisibility,
	restoreTaskPanelVisibility,
	userHideTaskPanel,
	userShowTaskPanel,
	type TaskPanelVisibilityState,
} from "../extensions/visibility.js";

function pendingChange(state: TaskPanelVisibilityState): void {
	applyTaskPanelContentVisibility(state, { autoShowOnFirstTask: true, defaultPanel: "compact", hasTasks: true, remainingTasks: 1 });
}

function allDoneChange(state: TaskPanelVisibilityState): void {
	applyTaskPanelContentVisibility(state, { autoShowOnFirstTask: true, defaultPanel: "compact", hasTasks: true, remainingTasks: 0 });
}

test("task panel auto-shows first task once, then user hide blocks later task mutations", () => {
	const panel = createTaskPanelVisibility("hidden");
	pendingChange(panel);
	assert.equal(panel.panel, "compact");
	assert.equal(panel.autoShownThisSession, true);

	userHideTaskPanel(panel);
	assert.equal(panel.panel, "hidden");
	assert.equal(panel.hiddenByUser, true);

	for (const _mutation of ["tasks_write add_task", "tasks_write replace", "tasks_write start_task", "tasks_write mark_done -> new pending"]) {
		pendingChange(panel);
		assert.equal(panel.panel, "hidden");
		assert.equal(panel.hiddenByUser, true);
	}
});

test("task panel replace preserves user-hidden visibility snapshot", () => {
	const beforeReplace = createTaskPanelVisibility("expanded");
	userHideTaskPanel(beforeReplace);
	const snapshot = rememberTaskPanelVisibility(beforeReplace);

	const replaced = createTaskPanelVisibility("compact");
	restoreTaskPanelVisibility(replaced, snapshot);
	pendingChange(replaced);

	assert.equal(replaced.panel, "hidden");
	assert.equal(replaced.hiddenByUser, true);
	assert.equal(replaced.lastVisiblePanel, "expanded");
});

test("task panel all-done auto-hide is distinct from user hide", () => {
	const panel = createTaskPanelVisibility("expanded");
	pendingChange(panel);
	allDoneChange(panel);
	assert.equal(panel.panel, "hidden");
	assert.equal(panel.hiddenByUser, false);
	assert.equal(panel.lastVisiblePanel, "expanded");

	userShowTaskPanel(panel);
	assert.equal(panel.panel, "expanded");
	assert.equal(panel.hiddenByUser, false);
});

test("task panel explicit toggle-in restores last visible mode", () => {
	const panel = createTaskPanelVisibility("expanded");
	userHideTaskPanel(panel);
	cycleTaskPanelVisibility(panel);
	assert.equal(panel.panel, "expanded");
	assert.equal(panel.hiddenByUser, false);
});
