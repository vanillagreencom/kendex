// E2E coverage of the real finalizeTask / replayMissedExits code paths
// using the extracted lifecycle helpers. Drives the exact same functions
// the extension uses; only the I/O surfaces (sendTaskEvent, persist,
// rememberSnapshot, refreshUi, clearTaskTimers) are stubbed so the test
// runs without a Pi runtime. Required by reviewer-test #11 and #12.

import { describe, expect, test } from "bun:test";
import { finalizeTaskLifecycle, replayMissedExitsLifecycle, type LifecycleHooks } from "../extensions/lifecycle.js";
import { restoredTaskFromSnapshot, selectMissedExits } from "../extensions/snapshot.js";
import type { BackgroundTaskSnapshot, ManagedTask, ProcessIdentity, TaskEventType } from "../extensions/types.js";

function fakeIdent(pid: number): ProcessIdentity {
	return { pid, startToken: `start-${pid}`, comm: "bot-review-wait" };
}
const probeDead = () => null;
const probeAlive = (pid: number) => fakeIdent(pid);

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
		outputBytes: 0,
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

interface RecordedHooks {
	events: { type: TaskEventType; task: ManagedTask }[];
	persists: number;
	remembers: number;
	refreshes: number;
	timerClears: number;
}

function recordingHooks(sendReturns: boolean = true): LifecycleHooks & { record: RecordedHooks } {
	const record: RecordedHooks = { events: [], persists: 0, remembers: 0, refreshes: 0, timerClears: 0 };
	const hooks: LifecycleHooks = {
		rememberSnapshot(task) {
			record.remembers += 1;
			return { ...task };
		},
		persistSnapshots() {
			record.persists += 1;
			return { appendEntry: true, sidecar: true };
		},
		sendTaskEvent(type, task) {
			record.events.push({ type, task });
			return sendReturns;
		},
		refreshUi() {
			record.refreshes += 1;
		},
		clearTaskTimers() {
			record.timerClears += 1;
		},
	};
	return Object.assign(hooks, { record });
}

describe("finalizeTaskLifecycle", () => {
	test("normal exit (code 0) -> status=completed + exitNotified=true", () => {
		const hooks = recordingHooks();
		const task = fakeTask();
		const result = finalizeTaskLifecycle(task, 0, hooks);
		expect(result.status).toBe("completed");
		expect(result.exitCode).toBe(0);
		expect(result.exitNotified).toBe(true);
		expect(result.closed).toBe(true);
		expect(hooks.record.events).toHaveLength(1);
		expect(hooks.record.events[0]?.type).toBe("exit");
		expect(hooks.record.timerClears).toBe(1);
		// Two persist calls: once after status mutation, once after
		// exitNotified flip. Each persist follows a remember.
		expect(hooks.record.persists).toBe(2);
	});

	test("abnormal exit (code null, no stopReason) -> status=failed", () => {
		const hooks = recordingHooks();
		const task = fakeTask();
		const result = finalizeTaskLifecycle(task, null, hooks);
		expect(result.status).toBe("failed");
		expect(result.exitCode).toBeNull();
		expect(result.exitNotified).toBe(true);
	});

	test("exit (code 1) -> status=failed", () => {
		const hooks = recordingHooks();
		const task = fakeTask();
		const result = finalizeTaskLifecycle(task, 1, hooks);
		expect(result.status).toBe("failed");
		expect(result.exitCode).toBe(1);
	});

	test("stopReason=user -> status=stopped, exitNotified=true", () => {
		const hooks = recordingHooks();
		const task = fakeTask({ stopReason: "user" });
		const result = finalizeTaskLifecycle(task, null, hooks);
		expect(result.status).toBe("stopped");
		expect(result.exitNotified).toBe(true);
	});

	test("stopReason=timeout -> status=timed_out", () => {
		const hooks = recordingHooks();
		const task = fakeTask({ stopReason: "timeout" });
		const result = finalizeTaskLifecycle(task, null, hooks);
		expect(result.status).toBe("timed_out");
	});

	test("statusOverride wins over stopReason and exitCode", () => {
		const hooks = recordingHooks();
		const task = fakeTask({ stopReason: "user" });
		const result = finalizeTaskLifecycle(task, 0, hooks, "failed");
		expect(result.status).toBe("failed");
	});

	test("sendTaskEvent failure (shuttingDown) leaves exitNotified=false for replay", () => {
		const hooks = recordingHooks(false);
		const task = fakeTask();
		const result = finalizeTaskLifecycle(task, 0, hooks);
		expect(result.status).toBe("completed");
		expect(result.exitNotified).toBe(false);
		// Persist still fires once for status mutation; the second persist
		// (after notify) is skipped because no flip happened.
		expect(hooks.record.persists).toBe(1);
		expect(hooks.record.events).toHaveLength(1);
	});

	test("notifyOnExit=false records the call but leaves exitNotified=false", () => {
		// sendTaskEvent returning false simulates the shuttingDown /
		// !notifyOnExit early-return in the real implementation.
		const hooks = recordingHooks(false);
		const task = fakeTask({ notifyOnExit: false });
		const result = finalizeTaskLifecycle(task, 0, hooks);
		expect(result.exitNotified).toBe(false);
	});

	test("second close is a no-op (idempotent)", () => {
		const hooks = recordingHooks();
		const task = fakeTask();
		finalizeTaskLifecycle(task, 0, hooks);
		const before = { ...hooks.record };
		finalizeTaskLifecycle(task, 99, hooks);
		// No new events / persists / remembers / refreshes after the first close.
		expect(hooks.record.events.length).toBe(before.events.length);
		expect(hooks.record.persists).toBe(before.persists);
		expect(task.exitCode).toBe(0);
	});

	test("partial output is preserved through finalize", () => {
		// CC-503 incident: bg-3 had 89 bytes of stderr ('Warning: GH_TOKEN
		// failed gh auth') but never produced an exit event. After
		// finalize the output is still on the task so the dashboard /
		// log inspection can show it.
		const hooks = recordingHooks();
		const task = fakeTask({
			outputBytes: 89,
			output: "Warning: GH_TOKEN/GITHUB_TOKEN failed gh auth; unsetting them and using gh keyring auth.\n",
		});
		const result = finalizeTaskLifecycle(task, null, hooks);
		expect(result.output.length).toBeGreaterThan(0);
		expect(result.outputBytes).toBe(89);
		expect(result.exitNotified).toBe(true);
	});

	test("zero output is fine (no spurious wake skip)", () => {
		const hooks = recordingHooks();
		const task = fakeTask({ outputBytes: 0, output: "" });
		const result = finalizeTaskLifecycle(task, 0, hooks);
		expect(result.exitNotified).toBe(true);
	});
});

describe("replayMissedExitsLifecycle", () => {
	test("replays only terminal tasks with exitNotified=false", () => {
		const hooks = recordingHooks();
		const tasks: ManagedTask[] = [
			fakeTask({ id: "bg-1", status: "running" }),
			fakeTask({ id: "bg-2", status: "stopped", exitNotified: false, notifyOnExit: true }),
			fakeTask({ id: "bg-3", status: "completed", exitNotified: true, exitCode: 0 }),
			fakeTask({ id: "bg-4", status: "failed", exitNotified: false, exitCode: 1, notifyOnExit: false }),
		];
		const replayed = replayMissedExitsLifecycle(tasks, hooks);
		expect(replayed).toBe(1);
		expect(hooks.record.events[0]?.task.id).toBe("bg-2");
		expect(tasks.find((t) => t.id === "bg-2")?.exitNotified).toBe(true);
	});

	test("sendTaskEvent failure does not flip exitNotified", () => {
		const hooks = recordingHooks(false);
		const tasks: ManagedTask[] = [
			fakeTask({ id: "bg-2", status: "stopped", exitNotified: false }),
		];
		const replayed = replayMissedExitsLifecycle(tasks, hooks);
		expect(replayed).toBe(0);
		expect(tasks[0]?.exitNotified).toBe(false);
	});

	test("zero missed exits -> no persist call", () => {
		const hooks = recordingHooks();
		const tasks: ManagedTask[] = [fakeTask({ status: "running" })];
		replayMissedExitsLifecycle(tasks, hooks);
		expect(hooks.record.persists).toBe(0);
	});
});

describe("session_start E2E (restore + replay)", () => {
	test("CC-503-style restore: persisted running snapshot triggers exit wake", () => {
		const hooks = recordingHooks();
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
		const replayed = replayMissedExitsLifecycle([restored], hooks);
		expect(replayed).toBe(1);
		expect(hooks.record.events).toHaveLength(1);
		expect(hooks.record.events[0]?.type).toBe("exit");
		expect(hooks.record.events[0]?.task.id).toBe("bg-3");
		expect(restored.exitNotified).toBe(true);
	});

	test("orphan-running restore: pid alive + identity match -> no fake exit", () => {
		const hooks = recordingHooks();
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
		const replayed = replayMissedExitsLifecycle([restored], hooks);
		expect(replayed).toBe(0);
		expect(hooks.record.events).toHaveLength(0);
	});

	test("backward-compat restore: pre-1.2.1 terminal snapshot does not replay", () => {
		const hooks = recordingHooks();
		const persisted = fakeSnapshot({
			id: "bg-historical",
			status: "completed",
			exitCode: 0,
			notifyOnExit: true,
		});
		delete (persisted as Partial<BackgroundTaskSnapshot>).exitNotified;
		delete (persisted as Partial<BackgroundTaskSnapshot>).sessionId;
		const restored = restoredTaskFromSnapshot(persisted, { identityProbe: probeDead, sessionId: "sess-1" });
		expect(selectMissedExits([restored])).toHaveLength(0);
		const replayed = replayMissedExitsLifecycle([restored], hooks);
		expect(replayed).toBe(0);
	});

	test("cross-session restore: snapshot from different sessionId does not replay", () => {
		const hooks = recordingHooks();
		const persisted = fakeSnapshot({
			id: "bg-other",
			status: "running",
			exitNotified: false,
			notifyOnExit: true,
			sessionId: "sess-OTHER",
		});
		const restored = restoredTaskFromSnapshot(persisted, { identityProbe: probeDead, sessionId: "sess-1" });
		expect(restored.exitNotified).toBe(true);
		expect(replayMissedExitsLifecycle([restored], hooks)).toBe(0);
	});
});
