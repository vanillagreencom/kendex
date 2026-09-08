import { expect, test } from "bun:test";
import {
	createBackgroundWidgetVisibility,
	shouldRenderBackgroundWidget,
	toggleBackgroundWidgetVisibility,
} from "../extensions/widget-visibility.js";

test("widget toggles preserve the last visible mode", () => {
	expect.hasAssertions();
	for (const { name, initial, toggles, expected } of [
		{ name: "hide expanded", initial: "expanded", toggles: 1, expected: { mode: "hidden", lastVisibleMode: "expanded", renders: false } },
		{ name: "restore expanded", initial: "expanded", toggles: 2, expected: { mode: "expanded", lastVisibleMode: "expanded", renders: true } },
		{ name: "hide compact", initial: "compact", toggles: 1, expected: { mode: "hidden", lastVisibleMode: "compact", renders: false } },
		{ name: "restore compact", initial: "compact", toggles: 2, expected: { mode: "compact", lastVisibleMode: "compact", renders: true } },
		{ name: "show initially hidden", initial: "hidden", toggles: 1, expected: { mode: "compact", lastVisibleMode: "compact", renders: true } },
	] as const) {
		const state = createBackgroundWidgetVisibility(initial);
		for (let index = 0; index < toggles; index++) toggleBackgroundWidgetVisibility(state);
		const renders = shouldRenderBackgroundWidget({ hasUi: true, mode: state.mode, showWidget: true, trackedTaskCount: 1, visibleTaskCount: 1 });
		expect({ ...state, renders }, name).toEqual(expected);
	}
});

test("widget rendering requires UI, enabled visibility and visible tasks", () => {
	expect.hasAssertions();
	for (const [name, hasUi, showWidget, trackedTaskCount, visibleTaskCount, mode, expected] of [
		["visible", true, true, 1, 1, "expanded", true],
		["headless", false, true, 1, 1, "expanded", false],
		["disabled", true, false, 1, 1, "expanded", false],
		["untracked", true, true, 0, 0, "expanded", false],
		["expired", true, true, 1, 0, "expanded", false],
		["manually hidden", true, true, 1, 1, "hidden", false],
	] as const) {
		expect(shouldRenderBackgroundWidget({ hasUi, showWidget, trackedTaskCount, visibleTaskCount, mode }), name).toBe(expected);
	}
});
