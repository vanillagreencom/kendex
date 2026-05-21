import { describe, expect, test } from "bun:test";

import {
	applyBgToolResultTasksWithBarrier,
	bgToolResultTasks,
	isBgToolResultBoundedTasks,
} from "../extensions/tool-result-details.js";
import type { BackgroundTaskSnapshot } from "../extensions/types.js";

function fakeSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	return {
		command: "printf ready",
		cwd: "/tmp/worktree",
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		id: overrides.id ?? "bg-1",
		lastOutputAt: 0,
		logFile: "/tmp/bg-1.log",
		notifyMode: "always",
		notifyOnExit: true,
		notifyOnOutput: false,
		outputBytes: 0,
		pid: 1234,
		startedAt: 1_700_000_000_000,
		status: "completed",
		title: "fake task",
		updatedAt: 1_700_000_000_500,
		voidedWakeSequences: [],
		wakeEvents: [],
		wakeSequence: 0,
		...overrides,
	};
}

describe("background task tool-result details", () => {
	test("small list details keep full snapshots for legacy restore", () => {
		const tasks = [fakeSnapshot({ id: "bg-1" }), fakeSnapshot({ id: "bg-2" })];
		const detailsTasks = bgToolResultTasks(tasks);
		expect(isBgToolResultBoundedTasks(detailsTasks)).toBe(false);
		expect(Array.isArray(detailsTasks)).toBe(true);
		expect((detailsTasks as BackgroundTaskSnapshot[]).map((task) => task.id)).toEqual(["bg-1", "bg-2"]);
	});

	test("100-task list details downgrade to a compact manifest", () => {
		const tasks = Array.from({ length: 100 }, (_value, index) => fakeSnapshot({ id: `bg-${index}`, pid: 10_000 + index }));
		const detailsTasks = bgToolResultTasks(tasks);
		expect(isBgToolResultBoundedTasks(detailsTasks)).toBe(true);
		expect((detailsTasks as any).counts.tasks).toBe(100);
		expect((detailsTasks as any).taskIds).toHaveLength(20);
		expect((detailsTasks as any).omitted.tasks).toBe(80);
		expect((detailsTasks as any).fullSnapshot).toBe(false);
		expect(Buffer.byteLength(JSON.stringify(detailsTasks), "utf8")).toBeLessThanOrEqual(4 * 1024);
		expect(Buffer.byteLength(JSON.stringify({ action: "list", tasks: detailsTasks }), "utf8")).toBeLessThanOrEqual(4 * 1024);
	});

	test("oversized list details downgrade even below task-count threshold", () => {
		const tasks = [fakeSnapshot({ command: "x".repeat(80 * 1024) })];
		const detailsTasks = bgToolResultTasks(tasks);
		expect(isBgToolResultBoundedTasks(detailsTasks)).toBe(true);
		expect((detailsTasks as any).reason).toBe("payload-too-large");
		expect((detailsTasks as any).counts.tasks).toBe(1);
		expect(Buffer.byteLength(JSON.stringify(detailsTasks), "utf8")).toBeLessThanOrEqual(4 * 1024);
		expect(Buffer.byteLength(JSON.stringify({ action: "list", tasks: detailsTasks }), "utf8")).toBeLessThanOrEqual(4 * 1024);
	});

	test("tool-result restore barrier re-applies sidecar tasks after older full list", () => {
		const sidecarTasks = [fakeSnapshot({ id: "bg-sidecar", updatedAt: 2_000 })];
		const olderTasks = [fakeSnapshot({ id: "bg-old", updatedAt: 1_000 })];
		let current: BackgroundTaskSnapshot[] = [...sidecarTasks];
		const clear = () => { current = []; };
		const apply = (snapshot: BackgroundTaskSnapshot) => { current.push(snapshot); };

		applyBgToolResultTasksWithBarrier({
			apply,
			clear,
			detailsTasks: olderTasks,
			sidecarLoaded: true,
			sidecarTasks,
		});
		expect(current.map((task) => task.id)).toEqual(["bg-sidecar", "bg-old"]);

		applyBgToolResultTasksWithBarrier({
			apply,
			clear,
			detailsTasks: bgToolResultTasks(Array.from({ length: 100 }, (_value, index) => fakeSnapshot({ id: `bg-${index}` }))),
			sidecarLoaded: true,
			sidecarTasks,
		});
		expect(current.map((task) => task.id)).toEqual(["bg-sidecar"]);
	});
});
