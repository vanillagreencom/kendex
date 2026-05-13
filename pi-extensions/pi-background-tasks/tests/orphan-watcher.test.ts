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
import type { BackgroundTaskSnapshot, ManagedTask, ProcessIdentity, TaskEventType } from "../extensions/types.js";

function fakeIdent(pid: number, overrides: Partial<ProcessIdentity> = {}): ProcessIdentity {
	return { pid, startToken: `start-${pid}`, comm: "bot-review-wait", ...overrides };
}

function fakeSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	const defaultPid = overrides.pid ?? 2409160;
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
		pid: defaultPid,
		procIdent: fakeIdent(defaultPid),
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

// Identity probe stubs: null = pid gone, returning an identity = pid
// alive. Tests parameterize identity (startToken/comm) to model
// PID-reuse where the kernel handed the same pid to an unrelated
// process.
const probeDead = () => null;
const probeAliveSame = (pid: number) => fakeIdent(pid);
const probeAliveReused = (pid: number) => fakeIdent(pid, { startToken: "start-RECYCLED", comm: "unrelated" });

describe("createOrphanWatcher.checkOnce", () => {
	test("alive pid + identity match → no finalize", () => {
		const hooks = recordingHooks();
		const tasks = [orphanTask({ id: "bg-1", pid: 4242 })];
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			identityProbe: probeAliveSame,
		});
		const result = watcher.checkOnce();
		expect(result.finalized).toBe(0);
		expect(hooks.events).toHaveLength(0);
		expect(tasks[0]?.status).toBe("running");
	});

	test("dead pid → finalize + emit canonical exit event", () => {
		const hooks = recordingHooks();
		const tasks = [orphanTask({ id: "bg-1", pid: 4242 })];
		let seenReason: string | null = null;
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			identityProbe: probeDead,
			onFinalize: (_, reason) => { seenReason = reason; },
		});
		const result = watcher.checkOnce();
		expect(result.finalized).toBe(1);
		expect(seenReason).toBe("pid-gone");
		expect(tasks[0]?.status).toBe("failed");
		expect(tasks[0]?.exitCode).toBeNull();
		expect(tasks[0]?.exitNotified).toBe(true);
		expect(hooks.events).toHaveLength(1);
		expect(hooks.events[0]?.type).toBe("exit");
	});

	test("comm drift (bash -lc 'sleep N') → still running, no finalize", () => {
		// vstack#15 round 5 reviewer-error BLOCK: a typical workload is
		// /bin/bash -lc "sleep 5". After the shell exec(2)s the target
		// the pid and start time stay identical but /proc/<pid>/comm
		// rotates "bash" -> "sleep". The watcher must rely on startToken
		// only, NOT comm, or it will falsely finalize a live task.
		const hooks = recordingHooks();
		const task = orphanTask({
			id: "bg-bash-exec",
			pid: 4242,
			command: "/bin/bash -lc 'sleep 5'",
			procIdent: { pid: 4242, startToken: "19283746", comm: "bash" },
		});
		const watcher = createOrphanWatcher({
			getTasks: () => [task],
			hooks,
			identityProbe: (pid: number) => ({ pid, startToken: "19283746", comm: "sleep" }),
		});
		const result = watcher.checkOnce();
		expect(result.finalized).toBe(0);
		expect(hooks.events).toHaveLength(0);
		expect(task.status).toBe("running");
	});

	test("PID reuse: alive pid with mismatched startToken → finalize with pid-reused reason", () => {
		// vstack#15 round 4 reviewer-error MAJOR + reviewer-test #1: the
		// original orphan exited and the OS reused PID 12345 for an
		// unrelated process (different start time). Bare kill -0 would
		// call it alive; startToken comparison detects the reuse and
		// treats the original task as gone.
		const hooks = recordingHooks();
		const tasks = [orphanTask({
			id: "bg-3",
			pid: 12345,
			command: "bot-review-wait 81",
			procIdent: fakeIdent(12345),
		})];
		let seenReason: string | null = null;
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			identityProbe: probeAliveReused,
			onFinalize: (_, reason) => { seenReason = reason; },
		});
		const result = watcher.checkOnce();
		expect(result.finalized).toBe(1);
		expect(seenReason).toBe("pid-reused");
		expect(tasks[0]?.status).toBe("failed");
		expect(tasks[0]?.exitNotified).toBe(true);
		expect(hooks.events).toHaveLength(1);
		expect(hooks.events[0]?.task.id).toBe("bg-3");
	});

	test("PID reuse mid-poll: orphan exits, then identity mismatch on next poll → finalize", () => {
		// Mirrors the kernel race the MAJOR fix targets: poll 1 sees the
		// original orphan alive (identity matches). Between poll 1 and
		// poll 2, the orphan exits and the OS hands PID 12345 to an
		// unrelated process. Poll 2 sees kill -0 return alive, but the
		// identity probe returns a different startToken/comm — we detect
		// reuse and finalize.
		const hooks = recordingHooks();
		const tasks = [orphanTask({ id: "bg-3", pid: 12345, procIdent: fakeIdent(12345) })];
		let reused = false;
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			identityProbe: (pid: number) => reused ? probeAliveReused(pid) : probeAliveSame(pid),
		});

		const first = watcher.checkOnce();
		expect(first.finalized).toBe(0);
		expect(hooks.events).toHaveLength(0);

		reused = true;
		const second = watcher.checkOnce();
		expect(second.finalized).toBe(1);
		expect(hooks.events).toHaveLength(1);
		expect(hooks.events[0]?.task.id).toBe("bg-3");
		expect(tasks[0]?.exitNotified).toBe(true);
	});

	test("Pi-died scenario: orphan stays alive across polls then dies", () => {
		const hooks = recordingHooks();
		const tasks = [orphanTask({ id: "bg-3", pid: 4242, notifyOnExit: true })];
		let alive = true;
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			identityProbe: (pid: number) => alive ? probeAliveSame(pid) : null,
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
			identityProbe: probeDead,
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
			identityProbe: probeDead,
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
			identityProbe: probeDead,
		});
		expect(watcher.checkOnce().finalized).toBe(1);
		expect(watcher.checkOnce().finalized).toBe(0);
		expect(hooks.events).toHaveLength(1);
	});

	test("pre-1.2.2 orphan with no procIdent degrades to PID-only liveness", () => {
		const hooks = recordingHooks();
		const task = orphanTask({ id: "bg-legacy", pid: 4242 });
		delete (task as Partial<ManagedTask>).procIdent;
		const watcher = createOrphanWatcher({
			getTasks: () => [task],
			hooks,
			identityProbe: probeAliveSame,
		});
		expect(watcher.checkOnce().finalized).toBe(0);
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
			identityProbe: probeDead,
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
