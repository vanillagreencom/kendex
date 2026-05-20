import { describe, expect, test } from "bun:test";
import {
	createBackgroundWidgetVisibility,
	shouldRenderBackgroundWidget,
	toggleBackgroundWidgetVisibility,
} from "../extensions/widget-visibility.js";

function lifecycleRefreshRenders(mode: "compact" | "expanded" | "hidden"): boolean {
	return shouldRenderBackgroundWidget({ hasUi: true, mode, showWidget: true, trackedTaskCount: 1, visibleTaskCount: 1 });
}

describe("background task mini-dashboard visibility", () => {
	test("task lifecycle refreshes do not reopen widget after manual hide", () => {
		const visibility = createBackgroundWidgetVisibility("expanded");
		toggleBackgroundWidgetVisibility(visibility);
		expect(visibility.mode).toBe("hidden");
		expect(visibility.lastVisibleMode).toBe("expanded");

		for (const _event of ["spawnTask", "output update", "exit update", "restore/replay", "clear/retention"]) {
			expect(lifecycleRefreshRenders(visibility.mode)).toBe(false);
			expect(visibility.mode).toBe("hidden");
		}
	});

	test("explicit toggle-in restores last visible widget mode", () => {
		const visibility = createBackgroundWidgetVisibility("expanded");
		toggleBackgroundWidgetVisibility(visibility);
		toggleBackgroundWidgetVisibility(visibility);
		expect(visibility.mode).toBe("expanded");
		expect(lifecycleRefreshRenders(visibility.mode)).toBe(true);
	});
});
