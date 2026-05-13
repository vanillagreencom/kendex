// Liveness watcher for orphan-running tasks rehydrated by
// restoredTaskFromSnapshot when the recorded child pid is still alive.
//
// vstack#15 (reviewer-error BLOCK): the previous fix skipped replay for
// alive-pid restored tasks but never re-armed the close listener — when
// the orphan eventually died, no exit event fired and the silent stall
// returned. This module polls `kill -0` per orphan; when the pid
// disappears, it routes through finalizeTaskLifecycle so the same
// canonical exit wake (and pi-bg-task-exit daemon path) fires that
// would have fired if Pi had stayed alive.
//
// Pure logic; tests inject deterministic `isProcessAlive` + clock.

import { finalizeTaskLifecycle, type LifecycleHooks } from "./lifecycle.js";
import { defaultReadProcessIdentity, identityMatches } from "./snapshot.js";
import type { ManagedTask, ProcessIdentity } from "./types.js";

export interface OrphanWatcherDeps {
	getTasks: () => Iterable<ManagedTask>;
	hooks: LifecycleHooks;
	pollMs?: number;
	// PID-reuse-safe identity probe. Returns null when the pid is gone
	// (orphan exited cleanly) and a ProcessIdentity when it is alive.
	// The watcher compares against task.procIdent so a recycled PID
	// hitting an unrelated process is detected as a mismatch and treated
	// like the pid is gone (reviewer-error MAJOR, vstack#15 round 4).
	identityProbe?: (pid: number) => ProcessIdentity | null;
	setIntervalFn?: (cb: () => void, ms: number) => NodeJS.Timeout;
	clearIntervalFn?: (handle: NodeJS.Timeout) => void;
	onFinalize?: (task: ManagedTask, reason: "pid-gone" | "pid-reused") => void;
}

export interface OrphanWatcher {
	checkOnce(): { finalized: number };
	start(): void;
	stop(): void;
}

export const DEFAULT_ORPHAN_POLL_MS = 30_000;

// A task is "orphan-running" when status=running AND it was restored
// from a snapshot (child handle is gone) AND its recorded pid is real.
// This identifies exactly the alive-at-restore branch from
// restoredTaskFromSnapshot.
export function isOrphanRunning(task: ManagedTask): boolean {
	if (task.status !== "running") return false;
	if (task.restored !== true) return false;
	if (task.child !== null) return false;
	if (!Number.isFinite(task.pid) || task.pid <= 0) return false;
	return true;
}

export function createOrphanWatcher(deps: OrphanWatcherDeps): OrphanWatcher {
	const pollMs = deps.pollMs ?? DEFAULT_ORPHAN_POLL_MS;
	const probe = deps.identityProbe ?? defaultReadProcessIdentity;
	const startTimer = deps.setIntervalFn ?? ((cb, ms) => setInterval(cb, ms));
	const stopTimer = deps.clearIntervalFn ?? ((h) => clearInterval(h));
	let timer: NodeJS.Timeout | null = null;

	function checkOnce(): { finalized: number } {
		let finalized = 0;
		for (const task of deps.getTasks()) {
			if (!isOrphanRunning(task)) continue;
			const current = probe(task.pid);
			let reason: "pid-gone" | "pid-reused" | null = null;
			if (current === null) {
				reason = "pid-gone";
			} else if (!identityMatches(task.procIdent, current)) {
				reason = "pid-reused";
			}
			if (reason === null) continue;
			// PID disappeared or was recycled by an unrelated process. We
			// can't recover the real exit code; the orphan is gone. Use
			// exitCode=null and let finalizeTaskLifecycle classify as
			// 'failed' (no stopReason, non-zero exit). The canonical exit
			// event fires here, and the subscriber/daemon routes the
			// resulting pi-bg-task-exit wake to master.
			finalizeTaskLifecycle(task, null, deps.hooks);
			deps.onFinalize?.(task, reason);
			finalized += 1;
		}
		return { finalized };
	}

	function start(): void {
		if (timer) return;
		timer = startTimer(checkOnce, pollMs);
		// unref so the timer never blocks Pi shutdown.
		(timer as { unref?: () => void }).unref?.();
	}

	function stop(): void {
		if (!timer) return;
		stopTimer(timer);
		timer = null;
	}

	return { checkOnce, start, stop };
}
