import assert from "node:assert/strict";
import test from "node:test";
import {
	autoShowAgentDashboardOnce,
	cycleAgentDashboard,
	userHideAgentDashboard,
	type AgentDashboardVisibilityState,
} from "../extensions/subagent/dashboard-visibility.js";

function state(patch: Partial<AgentDashboardVisibilityState> = {}): AgentDashboardVisibilityState {
	return { mode: "normal", visible: true, lastVisibleMode: "normal", hiddenByUser: false, autoShownThisSession: false, ...patch };
}

test("agent dashboard lifecycle auto-show never reopens after user hide", () => {
	const dashboard = state({ mode: "expanded", lastVisibleMode: "expanded" });
	autoShowAgentDashboardOnce(dashboard, "normal"); // first queued event in a session
	assert.equal(dashboard.visible, true);
	assert.equal(dashboard.autoShownThisSession, true);

	userHideAgentDashboard(dashboard);
	assert.equal(dashboard.visible, false);
	assert.equal(dashboard.hiddenByUser, true);
	assert.equal(dashboard.lastVisibleMode, "expanded");

	for (const _event of ["subagents:queued", "subagents:started", "subagents:completed", "subagents:needs_completion"]) {
		autoShowAgentDashboardOnce(dashboard, "normal");
		assert.equal(dashboard.visible, false);
		assert.equal(dashboard.hiddenByUser, true);
	}
});

test("agent dashboard explicit toggle-in restores last visible mode and clears latch", () => {
	const dashboard = state({ mode: "expanded", lastVisibleMode: "expanded", visible: false, hiddenByUser: true, autoShownThisSession: true });
	cycleAgentDashboard(dashboard);
	assert.equal(dashboard.visible, true);
	assert.equal(dashboard.mode, "expanded");
	assert.equal(dashboard.hiddenByUser, false);
	assert.equal(dashboard.autoShownThisSession, true);
});
