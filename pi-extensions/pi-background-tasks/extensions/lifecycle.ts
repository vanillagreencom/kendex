// Pure lifecycle helpers for bg_task terminal-state transitions.
//
// Extracted from background-tasks.ts so the test suite can exercise the
// real finalizeTask / replayMissedExits code paths without standing up
// the full Pi extension closure. The extension entry wires its private
// state (rememberSnapshot, persistSnapshots, sendTaskEvent, refreshUi,
// clearTaskTimers) into LifecycleHooks; tests inject stub hooks that
// record the calls.

import { selectMissedExits } from "./snapshot.js";
import type { BackgroundTaskSnapshot, BackgroundTaskStatus, ManagedTask, TaskEventType } from "./types.js";

export interface LifecycleHooks {
	rememberSnapshot: (task: ManagedTask) => BackgroundTaskSnapshot;
	persistSnapshots: () => unknown;
	sendTaskEvent: (eventType: TaskEventType, task: ManagedTask) => boolean;
	refreshUi: () => void;
	clearTaskTimers: (task: ManagedTask) => void;
}

// Mirror the bash daemon's finalize contract:
//   - first close wins (closed=true gate is idempotent)
//   - status derives from stopReason / statusOverride / exitCode
//   - exitNotified flips to true only after a successful sendTaskEvent
//
// Returns the same task instance so callers can chain.
export function finalizeTaskLifecycle(
	task: ManagedTask,
	exitCode: number | null,
	hooks: LifecycleHooks,
	statusOverride?: BackgroundTaskStatus,
): ManagedTask {
	if (task.closed) return task;
	task.closed = true;
	task.updatedAt = Date.now();
	task.exitCode = exitCode;
	hooks.clearTaskTimers(task);

	if (statusOverride) {
		task.status = statusOverride;
	} else if (task.stopReason === "timeout") {
		task.status = "timed_out";
	} else if (task.stopReason) {
		task.status = "stopped";
	} else {
		task.status = exitCode === 0 ? "completed" : "failed";
	}
	hooks.rememberSnapshot(task);
	hooks.persistSnapshots();

	const notified = hooks.sendTaskEvent("exit", task);
	if (notified) {
		task.exitNotified = true;
		hooks.rememberSnapshot(task);
		hooks.persistSnapshots();
	}
	hooks.refreshUi();
	return task;
}

// Replay 'exit' wakeups for any restored task that hit terminal state
// without an exit notification. Returns the number of tasks replayed.
// selectMissedExits gates on (status != running, notifyOnExit, exitNotified === false)
// so backward-compat snapshots and cross-session leaks are filtered upstream.
export function replayMissedExitsLifecycle(
	tasks: Iterable<ManagedTask>,
	hooks: LifecycleHooks,
): number {
	let replayed = 0;
	for (const task of selectMissedExits(tasks)) {
		const notified = hooks.sendTaskEvent("exit", task);
		if (!notified) continue;
		task.exitNotified = true;
		hooks.rememberSnapshot(task);
		replayed += 1;
	}
	if (replayed > 0) hooks.persistSnapshots();
	return replayed;
}
