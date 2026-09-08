import { expect, test } from "bun:test";
import {
	createBackgroundWidgetExpiryScheduler,
	nextBackgroundWidgetExpiryDelay,
} from "../extensions/widget-visibility.js";

const tasks = [
	{ status: "running", updatedAt: 500 },
	{ status: "completed", updatedAt: 1_000 },
	{ status: "failed", updatedAt: 2_000 },
];

test("widget expiry selects the earliest unexpired finished task", () => {
	expect.hasAssertions();
	for (const [name, now, expected] of [
		["first finished task", 10_000, 6_001],
		["inclusive deadline", 16_000, 1],
		["next finished task", 16_001, 1_000],
		["all finished tasks expired", 17_001, null],
	] as const) {
		expect(nextBackgroundWidgetExpiryDelay(tasks, 15_000, now), name).toBe(expected);
	}
});

test("widget expiry owns one timer until it fires or is cleared", () => {
	expect.hasAssertions();
	for (const { name, retention, now, steps, expected } of [
		{ name: "refresh then cancel", retention: 15_000, now: 10_000, steps: ["schedule", "fire", "schedule", "clear"], expected: { delays: [6_001, 6_001], refreshes: 1, clears: 1, pending: false } },
		{ name: "replace pending timer", retention: 15_000, now: 10_000, steps: ["schedule", "schedule", "clear"], expected: { delays: [6_001, 6_001], refreshes: 0, clears: 2, pending: false } },
		{ name: "fired timer is no longer owned", retention: 15_000, now: 10_000, steps: ["schedule", "fire", "clear"], expected: { delays: [6_001], refreshes: 1, clears: 0, pending: false } },
		{ name: "expired tasks need no timer", retention: 15_000, now: 17_001, steps: ["schedule", "clear"], expected: { delays: [], refreshes: 0, clears: 0, pending: false } },
		{ name: "native timer limit", retention: 2_592_000_000, now: 10_000, steps: ["schedule"], expected: { delays: [2_147_483_647], refreshes: 0, clears: 0, pending: true } },
	] as const) {
		const delays: number[] = [];
		let refreshes = 0;
		let clears = 0;
		const clock: { pending: { callback: () => void; unref(): void } | null } = { pending: null };
		const expiry = createBackgroundWidgetExpiryScheduler(
			() => refreshes++,
			((callback: () => void, delay: number) => {
				if (clock.pending) throw new Error("previous timer was not cleared");
				delays.push(delay);
				clock.pending = { callback, unref() {} };
				return clock.pending;
			}) as unknown as typeof setTimeout,
			((timer: unknown) => {
				if (timer !== clock.pending) throw new Error("cleared timer is not pending");
				clock.pending = null;
				clears++;
			}) as typeof clearTimeout,
		);
		for (const step of steps) {
			switch (step) {
				case "schedule": expiry.schedule(tasks, retention, now); break;
				case "clear": expiry.clear(); break;
				case "fire": {
					const timer = clock.pending;
					if (!timer) throw new Error("no timer to fire");
					clock.pending = null;
					timer.callback();
					break;
				}
			}
		}
		expect({ delays, refreshes, clears, pending: clock.pending !== null }, name).toEqual(expected);
	}
});
