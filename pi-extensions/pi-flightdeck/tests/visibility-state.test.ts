import assert from "node:assert/strict";
import test from "node:test";
import {
	createFlightdeckDashboardVisibility,
	cycleFlightdeckDashboardVisibility,
	resetFlightdeckDashboardVisibility,
	shouldRenderFlightdeckInlineWidget,
	userHideFlightdeckDashboard,
} from "../extensions/visibility.js";

test("flightdeck user-hidden state suppresses dashboard and pause banner", () => {
	const visibility = createFlightdeckDashboardVisibility("expanded");
	userHideFlightdeckDashboard(visibility);

	for (const status of ["live", "stale", "state-error", "archive-error", "awaiting-watch"] as const) {
		assert.equal(shouldRenderFlightdeckInlineWidget(visibility, { dashboardEnabled: true, showBanner: true, status }), false);
	}
});

test("flightdeck settings/tick-style events do not reopen user-hidden widget", () => {
	const visibility = createFlightdeckDashboardVisibility("compact");
	userHideFlightdeckDashboard(visibility);
	// Settings changes and state-file ticks call render decisions without changing visibility.
	assert.equal(shouldRenderFlightdeckInlineWidget(visibility, { dashboardEnabled: true, showBanner: true, status: "live" }), false);
	assert.equal(visibility.state, "hidden");
	assert.equal(visibility.hiddenByUser, true);
});

test("flightdeck explicit toggle-in restores last visible mode", () => {
	const visibility = createFlightdeckDashboardVisibility("expanded");
	userHideFlightdeckDashboard(visibility);
	cycleFlightdeckDashboardVisibility(visibility);
	assert.equal(visibility.state, "expanded");
	assert.equal(visibility.hiddenByUser, false);
	assert.equal(shouldRenderFlightdeckInlineWidget(visibility, { dashboardEnabled: true, showBanner: false, status: "live" }), true);
});

test("flightdeck session start resets user-hidden latch", () => {
	const visibility = createFlightdeckDashboardVisibility("compact");
	userHideFlightdeckDashboard(visibility);
	resetFlightdeckDashboardVisibility(visibility, "compact");
	assert.equal(visibility.state, "compact");
	assert.equal(visibility.hiddenByUser, false);
});
