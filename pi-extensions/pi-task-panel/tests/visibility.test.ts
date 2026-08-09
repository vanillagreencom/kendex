import assert from "node:assert/strict";
import test from "node:test";
import {
	applyTaskPanelContentVisibility,
	createTaskPanelVisibility,
	normalizePanelToggleBehavior,
	rememberTaskPanelVisibility,
	restoreTaskPanelVisibility,
	toggleTaskPanelVisibility,
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
	toggleTaskPanelVisibility(panel);
	assert.equal(panel.panel, "expanded");
	assert.equal(panel.hiddenByUser, false);
});

test("toggle from compact hides, then reopens compact", () => {
	const panel = createTaskPanelVisibility("compact");
	toggleTaskPanelVisibility(panel);
	assert.equal(panel.panel, "hidden");
	assert.equal(panel.hiddenByUser, true);
	toggleTaskPanelVisibility(panel);
	assert.equal(panel.panel, "compact");
	assert.equal(panel.hiddenByUser, false);
});

test("toggle from expanded hides, then reopens expanded", () => {
	const panel = createTaskPanelVisibility("expanded");
	toggleTaskPanelVisibility(panel);
	assert.equal(panel.panel, "hidden");
	toggleTaskPanelVisibility(panel);
	assert.equal(panel.panel, "expanded");
});

test("toggle on a fresh hidden panel opens compact", () => {
	const panel = createTaskPanelVisibility("hidden");
	toggleTaskPanelVisibility(panel);
	assert.equal(panel.panel, "compact");
});

test("cycle behavior walks hidden, compact, expanded, hidden regardless of last visible mode", () => {
	const panel = createTaskPanelVisibility("expanded");
	userHideTaskPanel(panel);
	toggleTaskPanelVisibility(panel, "cycle");
	assert.equal(panel.panel, "compact");
	toggleTaskPanelVisibility(panel, "cycle");
	assert.equal(panel.panel, "expanded");
	toggleTaskPanelVisibility(panel, "cycle");
	assert.equal(panel.panel, "hidden");
	assert.equal(panel.hiddenByUser, true);
	toggleTaskPanelVisibility(panel, "cycle");
	assert.equal(panel.panel, "compact");
});

test("toggle behavior setting values normalize with a toggle default", () => {
	assert.equal(normalizePanelToggleBehavior("cycle"), "cycle");
	assert.equal(normalizePanelToggleBehavior("toggle"), "toggle");
	assert.equal(normalizePanelToggleBehavior("bogus"), "toggle");
	assert.equal(normalizePanelToggleBehavior(undefined), "toggle");
});
