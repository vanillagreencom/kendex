// Orphan-running liveness watcher tests (vstack#15 reviewer-error BLOCK).
//
// Scenario: Pi dies, bg_task keeps running. On restart, restoredTaskFromSnapshot
// rehydrates the task as `running` because kill -0 still reports the pid
// alive (child handle is gone). Without a watcher, no `exit` event ever
// fires when the orphan eventually dies and the silent stall returns.
//
// These tests drive createOrphanWatcher with a deterministic
// isProcessAlive + clock and assert that:
//   1. checkOnce skips tasks with live pids.
//   2. checkOnce finalizes + emits a canonical exit event when the pid
//      transitions alive -> dead between polls.
//   3. Tasks that are not orphan-running (still has child handle, or
//      already terminal) are ignored.
//   4. Multiple orphans across a single check are all finalized.

import { describe, expect, test } from "bun:test";
import { createOrphanWatcher, isOrphanRunning } from "../extensions/orphan-watcher.js";
import type { LifecycleHooks } from "../extensions/lifecycle.js";
import type { BackgroundTaskSnapshot, ManagedTask, TaskEventType } from "../extensions/types.js";

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

function orphanTask(overrides: Partial<ManagedTask> = {}): ManagedTask {
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
		restored: true,
		...overrides,
	};
}

function recordingHooks(): LifecycleHooks & { events: { type: TaskEventType; task: ManagedTask }[]; persists: number } {
	const events: { type: TaskEventType; task: ManagedTask }[] = [];
	let persists = 0;
	const hooks: LifecycleHooks = {
		rememberSnapshot: (task) => ({ ...task }),
		persistSnapshots: () => { persists += 1; return { appendEntry: true, sidecar: true }; },
		sendTaskEvent: (type, task) => { events.push({ type, task }); return true; },
		refreshUi: () => {},
		clearTaskTimers: () => {},
	};
	return Object.assign(hooks, { events, get persists() { return persists; } });
}

describe("isOrphanRunning", () => {
	test("alive restored running task with valid pid → true", () => {
		expect(isOrphanRunning(orphanTask({ pid: 4242 }))).toBe(true);
	});

	test("non-restored task → false (in-process child still owns it)", () => {
		const task = orphanTask({ restored: false });
		expect(isOrphanRunning(task)).toBe(false);
	});

	test("terminal status → false", () => {
		expect(isOrphanRunning(orphanTask({ status: "stopped" }))).toBe(false);
	});

	test("task with live child handle → false (in-session, not orphan)", () => {
		const task = orphanTask();
		(task as ManagedTask).child = {} as ManagedTask["child"];
		expect(isOrphanRunning(task)).toBe(false);
	});

	test("invalid pid → false", () => {
		expect(isOrphanRunning(orphanTask({ pid: 0 }))).toBe(false);
		expect(isOrphanRunning(orphanTask({ pid: -1 }))).toBe(false);
	});
});

describe("createOrphanWatcher.checkOnce", () => {
	test("alive pid → no finalize", () => {
		const hooks = recordingHooks();
		const tasks = [orphanTask({ id: "bg-1", pid: 4242 })];
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			isProcessAlive: () => true,
		});
		const result = watcher.checkOnce();
		expect(result.finalized).toBe(0);
		expect(hooks.events).toHaveLength(0);
		expect(tasks[0]?.status).toBe("running");
	});

	test("dead pid → finalize + emit canonical exit event", () => {
		const hooks = recordingHooks();
		const tasks = [orphanTask({ id: "bg-1", pid: 4242 })];
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			isProcessAlive: () => false,
		});
		const result = watcher.checkOnce();
		expect(result.finalized).toBe(1);
		expect(tasks[0]?.status).toBe("failed");
		expect(tasks[0]?.exitCode).toBeNull();
		expect(tasks[0]?.exitNotified).toBe(true);
		expect(hooks.events).toHaveLength(1);
		expect(hooks.events[0]?.type).toBe("exit");
	});

	test("Pi-died scenario: orphan stays alive across polls then dies", () => {
		// This is the BLOCK fix in action. Pi crashed while bg_task was
		// still running. Restore brings it back as orphan-running. First
		// poll: pid alive, skip. Second poll: pid dead, finalize + wake.
		const hooks = recordingHooks();
		const tasks = [orphanTask({ id: "bg-3", pid: 4242, notifyOnExit: true })];
		let alive = true;
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			isProcessAlive: () => alive,
		});

		const first = watcher.checkOnce();
		expect(first.finalized).toBe(0);
		expect(hooks.events).toHaveLength(0);

		alive = false;
		const second = watcher.checkOnce();
		expect(second.finalized).toBe(1);
		expect(hooks.events).toHaveLength(1);
		expect(hooks.events[0]?.task.id).toBe("bg-3");
		expect(tasks[0]?.exitNotified).toBe(true);
	});

	test("non-orphan tasks are ignored", () => {
		const hooks = recordingHooks();
		const tasks = [
			orphanTask({ id: "bg-running-child", restored: false }),
			orphanTask({ id: "bg-already-terminal", status: "completed", exitCode: 0 }),
			orphanTask({ id: "bg-orphan-dead", pid: 4242 }),
		];
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			isProcessAlive: () => false,
		});
		const result = watcher.checkOnce();
		expect(result.finalized).toBe(1);
		expect(hooks.events[0]?.task.id).toBe("bg-orphan-dead");
	});

	test("multiple orphans dead at the same time all finalize", () => {
		const hooks = recordingHooks();
		const tasks = [
			orphanTask({ id: "bg-1", pid: 1111 }),
			orphanTask({ id: "bg-2", pid: 2222 }),
			orphanTask({ id: "bg-3", pid: 3333 }),
		];
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			isProcessAlive: () => false,
		});
		const result = watcher.checkOnce();
		expect(result.finalized).toBe(3);
		expect(hooks.events.map((e) => e.task.id)).toEqual(["bg-1", "bg-2", "bg-3"]);
		for (const task of tasks) {
			expect(task.exitNotified).toBe(true);
		}
	});

	test("idempotent: once finalized, subsequent checkOnce does nothing", () => {
		const hooks = recordingHooks();
		const tasks = [orphanTask({ id: "bg-1", pid: 4242 })];
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			isProcessAlive: () => false,
		});
		expect(watcher.checkOnce().finalized).toBe(1);
		expect(watcher.checkOnce().finalized).toBe(0);
		expect(hooks.events).toHaveLength(1);
	});
});

describe("createOrphanWatcher start/stop", () => {
	test("start arms an interval; stop cancels it", () => {
		const hooks = recordingHooks();
		let armed = false;
		let cleared = false;
		const watcher = createOrphanWatcher({
			getTasks: () => [],
			hooks,
			isProcessAlive: () => false,
			pollMs: 5_000,
			setIntervalFn: () => { armed = true; return { unref: () => {} } as unknown as NodeJS.Timeout; },
			clearIntervalFn: () => { cleared = true; },
		});
		watcher.start();
		expect(armed).toBe(true);
		watcher.stop();
		expect(cleared).toBe(true);
	});

	test("start is idempotent (second start does not arm a second timer)", () => {
		const hooks = recordingHooks();
		let armCount = 0;
		const watcher = createOrphanWatcher({
			getTasks: () => [],
			hooks,
			pollMs: 5_000,
			setIntervalFn: () => { armCount += 1; return { unref: () => {} } as unknown as NodeJS.Timeout; },
			clearIntervalFn: () => {},
		});
		watcher.start();
		watcher.start();
		expect(armCount).toBe(1);
	});
});
