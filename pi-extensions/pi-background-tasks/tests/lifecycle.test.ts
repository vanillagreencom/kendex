import { describe, expect, test } from "bun:test";
import { restoredTaskFromSnapshot, selectMissedExits, taskSnapshot } from "../extensions/snapshot.js";
import type { BackgroundTaskSnapshot, ManagedTask, ProcessIdentity } from "../extensions/types.js";

function fakeIdent(pid: number, overrides: Partial<ProcessIdentity> = {}): ProcessIdentity {
	return { pid, startToken: `start-${pid}`, comm: "bot-review-wait", ...overrides };
}

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

// Identity-probe stubs: null = pid gone, returning an identity = pid alive.
const probeDead = (): null => null;
const probeAlive = (pid: number): ProcessIdentity => fakeIdent(pid);
const probeReused = (pid: number): ProcessIdentity => fakeIdent(pid, { startToken: "start-RECYCLED", comm: "unrelated" });

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
		const snapshot = fakeSnapshot({ status: "running", exitNotified: true, procIdent: fakeIdent(2409160) });
		const restored = restoredTaskFromSnapshot(snapshot, { now: 1_700_000_100_000, identityProbe: probeDead, sessionId: "sess-1" });
		expect(restored.status).toBe("stopped");
		expect(restored.stopReason).toBe("shutdown");
		expect(restored.closed).toBe(true);
		expect(restored.exitNotified).toBe(false);
		expect(restored.restored).toBe(true);
		expect(restored.updatedAt).toBe(1_700_000_100_000);
	});

	test("running task with still-alive pid AND identity match stays running (no fake exit)", () => {
		const snapshot = fakeSnapshot({ status: "running", pid: 4242, procIdent: fakeIdent(4242) });
		const restored = restoredTaskFromSnapshot(snapshot, { now: 1_700_000_200_000, identityProbe: probeAlive, sessionId: "sess-1" });
		expect(restored.status).toBe("running");
		expect(restored.stopReason).toBeNull();
		expect(restored.closed).toBe(false);
		expect(restored.restored).toBe(true);
		expect(restored.updatedAt).toBe(snapshot.updatedAt);
		expect(selectMissedExits([restored])).toHaveLength(0);
	});

	test("PID-reuse safe: alive pid with mismatched startToken coerces to stopped", () => {
		// vstack#15 round 4 reviewer-error MAJOR: the original orphan
		// died, the OS reused the PID for an unrelated process, and a
		// bare kill -0 would treat the task as still running. Start-time
		// comparison detects the reuse and coerces the restored task to
		// stopped so the canonical exit wake fires.
		const snapshot = fakeSnapshot({ status: "running", pid: 12345, exitNotified: false, procIdent: fakeIdent(12345) });
		const restored = restoredTaskFromSnapshot(snapshot, { now: 1_700_000_300_000, identityProbe: probeReused, sessionId: "sess-1" });
		expect(restored.status).toBe("stopped");
		expect(restored.exitNotified).toBe(false);
		expect(selectMissedExits([restored])).toHaveLength(1);
	});

	test("comm drift (bash -lc 'sleep N'): same pid + startToken, different comm -> still running", () => {
		// vstack#15 round 5 reviewer-error BLOCK: bash often exec(2)s
		// the target binary in the same pid (the canonical example is
		// /bin/bash -lc "sleep 5" which rotates /proc/<pid>/comm from
		// "bash" to "sleep"). startToken is the kernel-stable signal;
		// gating identity on comm would falsely finalize this live task.
		const snapshot = fakeSnapshot({
			status: "running",
			pid: 4242,
			command: "/bin/bash -lc 'sleep 5'",
			procIdent: { pid: 4242, startToken: "19283746", comm: "bash" },
		});
		const probeCommDrifted = (pid: number): ProcessIdentity => ({ pid, startToken: "19283746", comm: "sleep" });
		const restored = restoredTaskFromSnapshot(snapshot, { identityProbe: probeCommDrifted, sessionId: "sess-1" });
		expect(restored.status).toBe("running");
		expect(restored.closed).toBe(false);
		expect(restored.stopReason).toBeNull();
		expect(selectMissedExits([restored])).toHaveLength(0);
	});

	test("pre-1.2.2 snapshot with no procIdent degrades to PID-only liveness", () => {
		const snapshot = fakeSnapshot({ status: "running", pid: 4242 });
		delete (snapshot as Partial<BackgroundTaskSnapshot>).procIdent;
		const restored = restoredTaskFromSnapshot(snapshot, { identityProbe: probeAlive, sessionId: "sess-1" });
		expect(restored.status).toBe("running");
	});

	test("preserves already-terminal status and exitNotified=true", () => {
		const snapshot = fakeSnapshot({ status: "completed", exitNotified: true, exitCode: 0 });
		const restored = restoredTaskFromSnapshot(snapshot, { identityProbe: probeDead });
		expect(restored.status).toBe("completed");
		expect(restored.exitNotified).toBe(true);
		expect(restored.stopReason).toBeNull();
	});

	test("backward-compat: terminal snapshot without exitNotified is treated as notified", () => {
		const snapshot = fakeSnapshot({ status: "completed", exitCode: 0 });
		delete (snapshot as Partial<BackgroundTaskSnapshot>).exitNotified;
		const restored = restoredTaskFromSnapshot(snapshot, { identityProbe: probeDead });
		expect(restored.exitNotified).toBe(true);
		expect(selectMissedExits([restored])).toHaveLength(0);
	});

	test("terminal-but-explicitly-never-notified task replays exit", () => {
		const snapshot = fakeSnapshot({ status: "stopped", exitNotified: false });
		const restored = restoredTaskFromSnapshot(snapshot, { identityProbe: probeDead });
		expect(restored.exitNotified).toBe(false);
		expect(selectMissedExits([restored])).toHaveLength(1);
	});

	test("cross-session snapshot is pinned to notified=true (no leak)", () => {
		const snapshot = fakeSnapshot({ status: "running", sessionId: "sess-OTHER", exitNotified: false, procIdent: fakeIdent(2409160) });
		const restored = restoredTaskFromSnapshot(snapshot, { identityProbe: probeDead, sessionId: "sess-1" });
		expect(restored.exitNotified).toBe(true);
		expect(selectMissedExits([restored])).toHaveLength(0);
	});

	test("orphaned running snapshot with no sessionId is treated as same-session", () => {
		const snapshot = fakeSnapshot({ status: "running" });
		delete (snapshot as Partial<BackgroundTaskSnapshot>).sessionId;
		const restored = restoredTaskFromSnapshot(snapshot, { identityProbe: probeDead, sessionId: "sess-1" });
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
	test("CC-503-style stalled bg_task is replayed on restore (dead pid)", () => {
		const persisted = fakeSnapshot({
			id: "bg-3",
			status: "running",
			exitCode: null,
			outputBytes: 89,
			exitNotified: false,
			notifyOnExit: true,
			procIdent: fakeIdent(2409160),
		});
		const restored = restoredTaskFromSnapshot(persisted, { identityProbe: probeDead, sessionId: "sess-1" });
		expect(restored.status).toBe("stopped");
		expect(restored.exitNotified).toBe(false);
		const missed = selectMissedExits([restored]);
		expect(missed).toHaveLength(1);
		expect(missed[0]?.id).toBe("bg-3");
	});

	test("restoring a snapshot whose pid is still alive (matching identity) does NOT announce exit", () => {
		const persisted = fakeSnapshot({
			id: "bg-3",
			status: "running",
			pid: 4242,
			notifyOnExit: true,
			procIdent: fakeIdent(4242),
		});
		const restored = restoredTaskFromSnapshot(persisted, { identityProbe: probeAlive, sessionId: "sess-1" });
		expect(restored.status).toBe("running");
		expect(restored.closed).toBe(false);
		expect(selectMissedExits([restored])).toHaveLength(0);
	});
});
