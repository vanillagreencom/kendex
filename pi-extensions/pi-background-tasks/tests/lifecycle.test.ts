import { describe, expect, test } from "bun:test";
import { restoredTaskFromSnapshot, selectMissedExits, taskSnapshot } from "../extensions/snapshot.js";
import type { BackgroundTaskSnapshot, ManagedTask } from "../extensions/types.js";

function fakeSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	return {
		command: "bot-review-wait 81",
		cwd: "/tmp/worktree",
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		id: "bg-3",
		lastOutputAt: null,
		logFile: "/tmp/log.txt",
		notifyOnExit: true,
		notifyOnOutput: false,
		notifyPattern: undefined,
		outputBytes: 89,
		pid: 2409160,
		startedAt: 1_700_000_000_000,
		status: "running",
		title: "bot review wait PR 81",
		updatedAt: 1_700_000_000_000,
		...overrides,
	};
}

function fakeTask(overrides: Partial<ManagedTask> = {}): ManagedTask {
	const snapshot = fakeSnapshot(overrides);
	return {
		...snapshot,
		child: null,
		closed: false,
		forceKillTimer: null,
		lastAnnouncedLength: 0,
		matcher: null,
		output: "",
		outputTimer: null,
		stopReason: null,
		timeoutTimer: null,
		...overrides,
	};
}

describe("taskSnapshot", () => {
	test("preserves exitNotified flag through serialization", () => {
		const task = fakeTask({ status: "completed", exitCode: 0, exitNotified: true });
		const snapshot = taskSnapshot(task);
		expect(snapshot.exitNotified).toBe(true);
	});

	test("defaults exitNotified to false when undefined", () => {
		const task = fakeTask({ exitNotified: undefined });
		const snapshot = taskSnapshot(task);
		expect(snapshot.exitNotified).toBe(false);
	});
});

describe("restoredTaskFromSnapshot", () => {
	test("coerces running -> stopped and clears exitNotified so replay fires", () => {
		const snapshot = fakeSnapshot({ status: "running", exitNotified: true });
		const restored = restoredTaskFromSnapshot(snapshot, 1_700_000_100_000);
		expect(restored.status).toBe("stopped");
		expect(restored.stopReason).toBe("shutdown");
		expect(restored.closed).toBe(true);
		expect(restored.exitNotified).toBe(false);
		expect(restored.restored).toBe(true);
		expect(restored.updatedAt).toBe(1_700_000_100_000);
	});

	test("preserves already-terminal status and exitNotified=true", () => {
		const snapshot = fakeSnapshot({ status: "completed", exitNotified: true, exitCode: 0 });
		const restored = restoredTaskFromSnapshot(snapshot);
		expect(restored.status).toBe("completed");
		expect(restored.exitNotified).toBe(true);
		expect(restored.stopReason).toBeNull();
	});

	test("terminal-but-never-notified task replays exit", () => {
		const snapshot = fakeSnapshot({ status: "stopped", exitNotified: false });
		const restored = restoredTaskFromSnapshot(snapshot);
		expect(restored.exitNotified).toBe(false);
	});
});

describe("selectMissedExits", () => {
	test("returns tasks in terminal state without prior exit notification", () => {
		const tasks: ManagedTask[] = [
			fakeTask({ id: "bg-1", status: "running" }),
			fakeTask({ id: "bg-2", status: "stopped", exitNotified: false, notifyOnExit: true }),
			fakeTask({ id: "bg-3", status: "completed", exitNotified: true, exitCode: 0, notifyOnExit: true }),
			fakeTask({ id: "bg-4", status: "failed", exitNotified: false, exitCode: 1, notifyOnExit: false }),
			fakeTask({ id: "bg-5", status: "timed_out", exitNotified: false, notifyOnExit: true }),
		];
		const missed = selectMissedExits(tasks).map((t) => t.id);
		expect(missed).toEqual(["bg-2", "bg-5"]);
	});

	test("returns nothing when all tasks already notified", () => {
		const tasks: ManagedTask[] = [
			fakeTask({ id: "bg-1", status: "completed", exitNotified: true, exitCode: 0 }),
			fakeTask({ id: "bg-2", status: "stopped", exitNotified: true }),
		];
		expect(selectMissedExits(tasks)).toHaveLength(0);
	});

	test("does not replay running tasks", () => {
		const tasks: ManagedTask[] = [
			fakeTask({ id: "bg-1", status: "running", exitNotified: false }),
		];
		expect(selectMissedExits(tasks)).toHaveLength(0);
	});
});

describe("incident replay", () => {
	// Mirrors the hyprtrade CC-503 incident: bg-3 transitioned running -> stopped
	// with exitCode: null and outputBytes: 89 (gh-auth warning) but no exit wake
	// fired. After restore + replay, the task must be selectable for replay.
	test("CC-503-style stalled bg_task is replayed on restore", () => {
		const persisted = fakeSnapshot({
			id: "bg-3",
			status: "running",
			exitCode: null,
			outputBytes: 89,
			exitNotified: false,
			notifyOnExit: true,
		});
		const restored = restoredTaskFromSnapshot(persisted);
		expect(restored.status).toBe("stopped");
		expect(restored.exitNotified).toBe(false);
		const missed = selectMissedExits([restored]);
		expect(missed).toHaveLength(1);
		expect(missed[0]?.id).toBe("bg-3");
	});
});
