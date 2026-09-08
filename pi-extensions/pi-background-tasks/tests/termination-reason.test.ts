// Every terminal-state transition stamps a terminationReason.
// so callers can tell self-exit from extension-stop, session-shutdown,
// external kill, reconcile-on-restart, and orphan-watcher finalize.
// `bg_status list` and the wake-event payload both surface the value.

import { describe, expect, test } from "bun:test";

import type { LifecycleHooks } from "../extensions/lifecycle.js";
import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import { taskSnapshot } from "../extensions/snapshot.js";
import type {
	BackgroundTaskSnapshot,
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

