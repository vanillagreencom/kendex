// Pure lifecycle helpers for bg_task terminal-state transitions.
//
// Extracted from background-tasks.ts so the test suite can exercise the
// real finalizeTask / replayMissedExits code paths without standing up
// the full Pi extension closure. The extension entry wires its private
// state (rememberSnapshot, persistSnapshots, sendTaskEvent, refreshUi,
// clearTaskTimers) into LifecycleHooks; tests inject stub hooks that
// record the calls.

import { selectMissedExits } from "./snapshot.js";
import type {
	BackgroundTaskSnapshot,
	BackgroundTaskStatus,
	BackgroundTaskTerminationReason,
	ManagedTask,
	TaskEventType,
} from "./types.js";

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
//   - terminationReason is set on every terminal transition so callers
//     can distinguish self-exit from extension-stop, session-shutdown,
//     external kill, reconcile-on-restart, and orphan-watcher finalizes
//     (kendex#97). An explicit `terminationReason` argument wins over
//     whatever the caller pre-stamped on `task.terminationReason`; the
//     default falls back to a derivation from stopReason and exitCode.
//
// Returns the same task instance so callers can chain.
export function finalizeTaskLifecycle(
	task: ManagedTask,
	exitCode: number | null,
	hooks: LifecycleHooks,
	statusOverride?: BackgroundTaskStatus,
	terminationReason?: BackgroundTaskTerminationReason,
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
	task.terminationReason = resolveTerminationReason(task, exitCode, terminationReason);
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

// Resolve the terminationReason for a finalize call. Precedence:
//   1. Explicit argument from the caller (e.g. orphan-watcher passes
//      "orphaned-pid-gone", session_shutdown passes "session-shutdown").
//   2. A reason the caller pre-stamped on task.terminationReason
//      (requestStop sets "extension-stop" before invoking the SIGTERM
//      cascade so the eventual child.on("close") finalize picks it up).
//   3. Derived from the resolved status + exitCode: completed
//      (exit 0) and failed (non-zero) self-exit; null exitCode with no
//      stopReason is treated as external (signal we did not issue).
function resolveTerminationReason(
	task: ManagedTask,
	exitCode: number | null,
	explicit: BackgroundTaskTerminationReason | undefined,
): BackgroundTaskTerminationReason {
	if (explicit !== undefined) return explicit;
	if (task.terminationReason !== undefined) return task.terminationReason;
	if (task.stopReason === "timeout") return "timeout";
	if (task.stopReason === "user") return "extension-stop";
	if (task.stopReason === "shutdown") return "session-shutdown";
	if (exitCode === null) return "external";
	return "self-exit";
}

// Replay 'exit' wakeups for any restored task that hit terminal state
// without an exit notification. Returns the number of tasks replayed.
// selectMissedExits gates on (status != running, notifyOnExit, exitNotified === false)
// so cross-session leaks are filtered upstream.
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
