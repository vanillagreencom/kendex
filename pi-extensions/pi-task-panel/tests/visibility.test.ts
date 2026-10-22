import assert from "node:assert/strict";
import { test } from "bun:test";
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

	allDoneChange(panel);
	pendingChange(panel);
	assert.equal(panel.panel, "hidden");
	assert.equal(panel.hiddenByUser, true);
	assert.equal(panel.lastVisiblePanel, "compact");
});

test("task panel auto-reopens for pending work after an all-done hide", () => {
	const panel = createTaskPanelVisibility("hidden");
	pendingChange(panel);
	allDoneChange(panel);
	assert.equal(panel.panel, "hidden");
	assert.equal(panel.autoShownThisSession, false);

	pendingChange(panel);
	assert.equal(panel.panel, "compact");
	assert.equal(panel.hiddenByUser, false);
	assert.equal(panel.lastVisiblePanel, "compact");
});

test("task panel stays hidden when auto-show is disabled or its default is hidden", () => {
	for (const options of [
		{ autoShowOnFirstTask: false, defaultPanel: "compact" as const },
		{ autoShowOnFirstTask: true, defaultPanel: "hidden" as const },
	]) {
		const panel = createTaskPanelVisibility("hidden");
		applyTaskPanelContentVisibility(panel, { ...options, hasTasks: true, remainingTasks: 1 });
		applyTaskPanelContentVisibility(panel, { ...options, hasTasks: true, remainingTasks: 0 });
		applyTaskPanelContentVisibility(panel, { ...options, hasTasks: true, remainingTasks: 1 });
		assert.equal(panel.panel, "hidden");
		assert.equal(panel.hiddenByUser, false);
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

for (const initial of ["compact", "expanded"] as const) {
	test(`toggle from ${initial} hides and restores that mode`, () => {
		const panel = createTaskPanelVisibility(initial);
		toggleTaskPanelVisibility(panel);
		assert.equal(panel.panel, "hidden");
		assert.equal(panel.hiddenByUser, true);
		toggleTaskPanelVisibility(panel);
		assert.equal(panel.panel, initial);
		assert.equal(panel.hiddenByUser, false);
	});
}

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

for (const [value, expected] of [["cycle", "cycle"], ["toggle", "toggle"], ["bogus", "toggle"], [undefined, "toggle"]] as const) {
	test(`toggle behavior setting ${String(value)}`, () => {
		assert.equal(normalizePanelToggleBehavior(value), expected);
	});
}
