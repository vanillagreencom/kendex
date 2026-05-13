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
		sessionId: "sess-1",
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

const isDead = () => false;
const isAlive = () => true;

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

	test("persists sessionId so cross-session replay is gated", () => {
		const task = fakeTask({ sessionId: "sess-1" });
		expect(taskSnapshot(task).sessionId).toBe("sess-1");
	});
});

describe("restoredTaskFromSnapshot", () => {
	test("coerces running -> stopped and clears exitNotified when child pid is dead", () => {
		const snapshot = fakeSnapshot({ status: "running", exitNotified: true });
		const restored = restoredTaskFromSnapshot(snapshot, { now: 1_700_000_100_000, isProcessAlive: isDead, sessionId: "sess-1" });
		expect(restored.status).toBe("stopped");
		expect(restored.stopReason).toBe("shutdown");
		expect(restored.closed).toBe(true);
		expect(restored.exitNotified).toBe(false);
		expect(restored.restored).toBe(true);
		expect(restored.updatedAt).toBe(1_700_000_100_000);
	});

	test("running task with still-alive pid stays running (no fake exit)", () => {
		const snapshot = fakeSnapshot({ status: "running", pid: 4242 });
		const restored = restoredTaskFromSnapshot(snapshot, { now: 1_700_000_200_000, isProcessAlive: isAlive, sessionId: "sess-1" });
		expect(restored.status).toBe("running");
		expect(restored.stopReason).toBeNull();
		expect(restored.closed).toBe(false);
		expect(restored.restored).toBe(true);
		// Updated-at is preserved (no fake transition), so the dashboard
		// doesn't show a spurious "just now" timestamp.
		expect(restored.updatedAt).toBe(snapshot.updatedAt);
		expect(selectMissedExits([restored])).toHaveLength(0);
	});

	test("preserves already-terminal status and exitNotified=true", () => {
		const snapshot = fakeSnapshot({ status: "completed", exitNotified: true, exitCode: 0 });
		const restored = restoredTaskFromSnapshot(snapshot, { isProcessAlive: isDead });
		expect(restored.status).toBe("completed");
		expect(restored.exitNotified).toBe(true);
		expect(restored.stopReason).toBeNull();
	});

	test("backward-compat: terminal snapshot without exitNotified is treated as notified", () => {
		// vstack#15 (reviewer-arch #6): old snapshots persisted by 1.2.0
		// have no exitNotified field. Upgrade must not replay every
		// historical task. Only running->stopped coercion sets false.
		const snapshot = fakeSnapshot({ status: "completed", exitCode: 0 });
		delete (snapshot as Partial<BackgroundTaskSnapshot>).exitNotified;
		const restored = restoredTaskFromSnapshot(snapshot, { isProcessAlive: isDead });
		expect(restored.exitNotified).toBe(true);
		expect(selectMissedExits([restored])).toHaveLength(0);
	});

	test("terminal-but-explicitly-never-notified task replays exit", () => {
		const snapshot = fakeSnapshot({ status: "stopped", exitNotified: false });
		const restored = restoredTaskFromSnapshot(snapshot, { isProcessAlive: isDead });
		expect(restored.exitNotified).toBe(false);
		expect(selectMissedExits([restored])).toHaveLength(1);
	});

	test("cross-session snapshot is pinned to notified=true (no leak)", () => {
		// vstack#15 (reviewer-arch #7): replay must not fire for snapshots
		// that belong to a different Pi session.
		const snapshot = fakeSnapshot({ status: "running", sessionId: "sess-OTHER", exitNotified: false });
		const restored = restoredTaskFromSnapshot(snapshot, { isProcessAlive: isDead, sessionId: "sess-1" });
		expect(restored.exitNotified).toBe(true);
		expect(selectMissedExits([restored])).toHaveLength(0);
	});

	test("orphaned running snapshot with no sessionId is treated as same-session", () => {
		// Pre-1.2.1 snapshots have no sessionId. Don't refuse to replay
		// them just because we can't compare.
		const snapshot = fakeSnapshot({ status: "running" });
		delete (snapshot as Partial<BackgroundTaskSnapshot>).sessionId;
		const restored = restoredTaskFromSnapshot(snapshot, { isProcessAlive: isDead, sessionId: "sess-1" });
		expect(restored.status).toBe("stopped");
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

	test("treats undefined exitNotified as notified (no replay)", () => {
		const tasks: ManagedTask[] = [
			fakeTask({ id: "bg-1", status: "completed", exitCode: 0, exitNotified: undefined }),
			fakeTask({ id: "bg-2", status: "stopped", exitNotified: undefined }),
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
	test("CC-503-style stalled bg_task is replayed on restore (dead pid)", () => {
		const persisted = fakeSnapshot({
			id: "bg-3",
			status: "running",
			exitCode: null,
			outputBytes: 89,
			exitNotified: false,
			notifyOnExit: true,
		});
		const restored = restoredTaskFromSnapshot(persisted, { isProcessAlive: isDead, sessionId: "sess-1" });
		expect(restored.status).toBe("stopped");
		expect(restored.exitNotified).toBe(false);
		const missed = selectMissedExits([restored]);
		expect(missed).toHaveLength(1);
		expect(missed[0]?.id).toBe("bg-3");
	});

	test("restoring a snapshot whose pid is still alive does NOT announce exit", () => {
		// kill -9 / OOM defense: the parent Pi may have died but the
		// detached process group can still be alive. Replay would
		// announce a fake terminal state and lose the live process handle.
		const persisted = fakeSnapshot({
			id: "bg-3",
			status: "running",
			pid: 4242,
			notifyOnExit: true,
		});
		const restored = restoredTaskFromSnapshot(persisted, { isProcessAlive: isAlive, sessionId: "sess-1" });
		expect(restored.status).toBe("running");
		expect(restored.closed).toBe(false);
		expect(selectMissedExits([restored])).toHaveLength(0);
	});
});
