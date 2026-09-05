import { describe, expect, test } from "bun:test";
import {
	createBackgroundWidgetExpiryScheduler,
	createBackgroundWidgetVisibility,
	nextBackgroundWidgetExpiryDelay,
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

	test("refreshes after the earliest finished task expires", () => {
		const tasks = [
			{ status: "running", updatedAt: 500 },
			{ status: "completed", updatedAt: 1_000 },
			{ status: "failed", updatedAt: 2_000 },
		];
		expect(nextBackgroundWidgetExpiryDelay(tasks, 15_000, 10_000)).toBe(6_001);
		expect(nextBackgroundWidgetExpiryDelay(tasks, 15_000, 16_001)).toBe(1_000);
		expect(nextBackgroundWidgetExpiryDelay(tasks, 15_000, 17_001)).toBeNull();

		let refreshes = 0;
		let scheduledDelay = 0;
		let callback = () => {};
		let clears = 0;
		const timer = { unref() {} } as ReturnType<typeof setTimeout>;
		const expiry = createBackgroundWidgetExpiryScheduler(
			() => refreshes++,
			(nextCallback, delay) => {
				callback = nextCallback;
				scheduledDelay = delay;
				return timer;
			},
			() => clears++,
		);
		expiry.schedule(tasks, 15_000, 10_000);
		expect(scheduledDelay).toBe(6_001);
		callback();
		expect(refreshes).toBe(1);
		expiry.schedule(tasks, 15_000, 10_000);
		expiry.clear();
		expect(clears).toBe(1);
	});
});
