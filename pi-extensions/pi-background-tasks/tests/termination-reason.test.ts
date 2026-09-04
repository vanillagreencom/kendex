// Every terminal-state transition stamps a terminationReason.
// so callers can tell self-exit from extension-stop, session-shutdown,
// external kill, reconcile-on-restart, and orphan-watcher finalize.
// `bg_status list` and the wake-event payload both surface the value.

import { describe, expect, test } from "bun:test";

import { finalizeTaskLifecycle, type LifecycleHooks } from "../extensions/lifecycle.js";
import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import { summarizeTaskStatus } from "../extensions/format.js";
import { restoredTaskFromSnapshot, taskSnapshot } from "../extensions/snapshot.js";
import type {
	BackgroundTaskSnapshot,
	BackgroundTaskTerminationReason,
	ManagedTask,
	ProcessIdentity,
} from "../extensions/types.js";

function fakeSnapshot(overrides: Partial<BackgroundTaskSnapshot> = {}): BackgroundTaskSnapshot {
	return {
		command: "idle-watcher",
		cwd: "/tmp/w",
		exitCode: null,
		exitNotified: false,
		expiresAt: null,
		id: "bg-97",
		lastOutputAt: null,
		logFile: "/tmp/log.txt",
		notifyOnExit: true,
		notifyOnOutput: false,
		notifyPattern: undefined,
		outputBytes: 12,
		pid: 4242,
		sessionId: "sess-A",
		startedAt: 1_700_000_000_000,
		status: "running",
		title: "idle watcher",
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

function recordingHooks(): LifecycleHooks & { events: Array<{ type: string; reason?: string }> } {
	const events: Array<{ type: string; reason?: string }> = [];
	return {
		clearTaskTimers: () => {},
		persistSnapshots: () => {},
		refreshUi: () => {},
		rememberSnapshot: (task) => taskSnapshot(task),
		sendTaskEvent: (eventType, task) => {
			events.push({ reason: task.terminationReason, type: eventType });
			return true;
		},
		events,
	};
}

describe("terminationReason annotation (kendex#97)", () => {
	test("clean self-exit (exitCode 0, no stopReason) stamps self-exit", () => {
		const task = fakeTask();
		const hooks = recordingHooks();
		finalizeTaskLifecycle(task, 0, hooks);
		expect(task.status).toBe("completed");
		expect(task.terminationReason).toBe("self-exit");
		expect(hooks.events[0]?.reason).toBe("self-exit");
	});

	test("non-zero exit with no stopReason stamps self-exit (failed)", () => {
		const task = fakeTask();
		const hooks = recordingHooks();
		finalizeTaskLifecycle(task, 1, hooks);
		expect(task.status).toBe("failed");
		expect(task.terminationReason).toBe("self-exit");
	});

	test("null exit code with no stopReason stamps external (signal we did not issue)", () => {
		const task = fakeTask();
		const hooks = recordingHooks();
		finalizeTaskLifecycle(task, null, hooks);
		expect(task.status).toBe("failed");
		expect(task.terminationReason).toBe("external");
	});

	test("pre-stamped extension-stop survives the finalize", () => {
		const task = fakeTask({ stopReason: "user", terminationReason: "extension-stop" });
		const hooks = recordingHooks();
		finalizeTaskLifecycle(task, null, hooks);
		expect(task.status).toBe("stopped");
		expect(task.terminationReason).toBe("extension-stop");
	});

	test("session-shutdown stopReason derives session-shutdown", () => {
		const task = fakeTask({ stopReason: "shutdown" });
		const hooks = recordingHooks();
		finalizeTaskLifecycle(task, null, hooks);
		expect(task.status).toBe("stopped");
		expect(task.terminationReason).toBe("session-shutdown");
	});

	test("timeout stopReason derives timeout (status timed_out)", () => {
		const task = fakeTask({ stopReason: "timeout" });
		const hooks = recordingHooks();
		finalizeTaskLifecycle(task, null, hooks);
		expect(task.status).toBe("timed_out");
		expect(task.terminationReason).toBe("timeout");
	});

	test("explicit terminationReason argument wins over the derivation", () => {
		const task = fakeTask({ stopReason: "user", terminationReason: "extension-stop" });
		const hooks = recordingHooks();
		finalizeTaskLifecycle(
			task,
			null,
			hooks,
			undefined,
			"orphaned-pid-reused" as BackgroundTaskTerminationReason,
		);
		expect(task.terminationReason).toBe("orphaned-pid-reused");
	});
});

describe("restoredTaskFromSnapshot annotation (kendex#97)", () => {
	test("running -> stopped coercion annotates reconcile-on-restart", () => {
		const snapshot = fakeSnapshot({
			procIdent: { comm: "bash", pid: 4242, startToken: "start-4242" },
			status: "running",
		});
		const restored = restoredTaskFromSnapshot(snapshot, {
			identityProbe: () => null,
			now: 1_700_000_100_000,
			sessionId: "sess-A",
		});
		expect(restored.status).toBe("stopped");
		expect(restored.terminationReason).toBe("reconcile-on-restart");
	});

	test("alive-pid restore preserves whatever terminationReason was already set", () => {
		const snapshot = fakeSnapshot({
			procIdent: { comm: "bash", pid: 4242, startToken: "start-4242" },
			status: "running",
			terminationReason: undefined,
		});
		const restored = restoredTaskFromSnapshot(snapshot, {
			identityProbe: (pid) => ({ comm: "bash", pid, startToken: "start-4242" }),
			now: 1_700_000_100_000,
			sessionId: "sess-A",
		});
		expect(restored.status).toBe("running");
		expect(restored.terminationReason).toBeUndefined();
	});

	test("terminal snapshot with pre-existing terminationReason flows through unchanged", () => {
		const snapshot = fakeSnapshot({
			exitCode: 0,
			exitNotified: true,
			status: "completed",
			terminationReason: "self-exit",
		});
		const restored = restoredTaskFromSnapshot(snapshot, {
			now: 1_700_000_100_000,
			sessionId: "sess-A",
		});
		expect(restored.status).toBe("completed");
		expect(restored.terminationReason).toBe("self-exit");
	});
});

describe("orphan-watcher annotation (kendex#97)", () => {
	function makeOrphan(overrides: Partial<ManagedTask> = {}): ManagedTask {
		return fakeTask({
			child: null,
			pid: 4242,
			procIdent: { comm: "bash", pid: 4242, startToken: "start-4242" },
			restored: true,
			status: "running",
			...overrides,
		});
	}

	test("pid-gone finalize stamps orphaned-pid-gone", () => {
		const tasks = [makeOrphan()];
		const hooks = recordingHooks();
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			identityProbe: () => null,
		});
		const { finalized } = watcher.checkOnce();
		expect(finalized).toBe(1);
		expect(tasks[0]!.terminationReason).toBe("orphaned-pid-gone");
	});

	test("pid-reuse finalize stamps orphaned-pid-reused", () => {
		const tasks = [makeOrphan()];
		const hooks = recordingHooks();
		const watcher = createOrphanWatcher({
			getTasks: () => tasks,
			hooks,
			identityProbe: (pid) => ({
				comm: "unrelated",
				pid,
				startToken: "start-RECYCLED",
			} satisfies ProcessIdentity),
		});
		const { finalized } = watcher.checkOnce();
		expect(finalized).toBe(1);
		expect(tasks[0]!.terminationReason).toBe("orphaned-pid-reused");
	});
});

describe("summarizeTaskStatus formatting (kendex#97)", () => {
	test("self-exit annotation is omitted so historical rows stay terse", () => {
		expect(summarizeTaskStatus("completed", 0, "self-exit")).toBe("completed (exit 0)");
		expect(summarizeTaskStatus("failed", 137, "self-exit")).toBe("failed (exit 137)");
	});

	test("non-self-exit reasons are appended in parentheses", () => {
		expect(summarizeTaskStatus("stopped", null, "extension-stop")).toBe(
			"stopped (extension-stop)",
		);
		expect(summarizeTaskStatus("stopped", null, "reconcile-on-restart")).toBe(
			"stopped (reconcile-on-restart)",
		);
		expect(summarizeTaskStatus("failed", null, "orphaned-pid-gone")).toBe(
			"failed (exit ?) (orphaned-pid-gone)",
		);
		expect(summarizeTaskStatus("failed", null, "external")).toBe(
			"failed (exit ?) (external)",
		);
	});

	test("undefined termination reason matches the legacy output (back-compat)", () => {
		expect(summarizeTaskStatus("stopped", null, undefined)).toBe("stopped");
		expect(summarizeTaskStatus("completed", 0, undefined)).toBe("completed (exit 0)");
	});
});

describe("taskSnapshot round-trip (kendex#97)", () => {
	test("preserves terminationReason through snapshot serialization", () => {
		const task = fakeTask({
			exitCode: 0,
			status: "stopped",
			terminationReason: "extension-stop",
		});
		expect(taskSnapshot(task).terminationReason).toBe("extension-stop");
	});

	test("undefined terminationReason serializes as undefined (older snapshots load unchanged)", () => {
		const task = fakeTask();
		expect(taskSnapshot(task).terminationReason).toBeUndefined();
	});
});
