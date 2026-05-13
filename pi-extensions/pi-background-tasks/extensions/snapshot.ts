import { parseOutputMatcher } from "./format.js";
import type { BackgroundTaskSnapshot, ManagedTask } from "./types.js";

const liveSnapshots = new Map<string, BackgroundTaskSnapshot>();

export function taskSnapshot(task: ManagedTask): BackgroundTaskSnapshot {
	return {
		command: task.command,
		cwd: task.cwd,
		exitCode: task.exitCode,
		exitNotified: task.exitNotified === true,
		expiresAt: task.expiresAt,
		id: task.id,
		lastOutputAt: task.lastOutputAt,
		logFile: task.logFile,
		notifyOnExit: task.notifyOnExit,
		notifyOnOutput: task.notifyOnOutput,
		notifyPattern: task.notifyPattern,
		outputBytes: task.outputBytes,
		pid: task.pid,
		sessionId: task.sessionId,
		startedAt: task.startedAt,
		status: task.status,
		title: task.title,
		updatedAt: task.updatedAt,
	};
}

export function rememberSnapshot(task: ManagedTask): BackgroundTaskSnapshot {
	const snapshot = taskSnapshot(task);
	liveSnapshots.set(snapshot.id, snapshot);
	return snapshot;
}

export function forgetSnapshot(id: string): void {
	liveSnapshots.delete(id);
}

export function latestSnapshot(snapshot: BackgroundTaskSnapshot | undefined): BackgroundTaskSnapshot | undefined {
	if (!snapshot) return undefined;
	return liveSnapshots.get(snapshot.id) ?? snapshot;
}

export function latestSnapshots(snapshots: BackgroundTaskSnapshot[]): BackgroundTaskSnapshot[] {
	return snapshots.map((snapshot) => latestSnapshot(snapshot) ?? snapshot);
}

export function resolveTaskByToken<T extends Pick<BackgroundTaskSnapshot, "id" | "pid">>(
	tasks: Iterable<T>,
	token: string | number | undefined,
): T | null {
	if (token === undefined || token === null || token === "") return null;
	const normalized = String(token).trim();
	if (!normalized) return null;
	for (const task of tasks) {
		if (task.id === normalized || String(task.pid) === normalized) return task;
	}
	return null;
}

// Default pid-liveness probe. Returns true iff the kernel reports the
// pid as alive (or EPERM, which means alive-but-foreign). Tests inject a
// deterministic stub via the second arg of restoredTaskFromSnapshot.
export function defaultProcessAlive(pid: number): boolean {
	if (!Number.isFinite(pid) || pid <= 0) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

export interface RestoreOptions {
	now?: number;
	// Hook for tests + production. Default uses process.kill(pid, 0). Return
	// true when the original child process group is still alive; restore
	// then keeps the task as `running` (with `restored: true`) and skips the
	// replay rather than synthesizing a fake terminal transition.
	isProcessAlive?: (pid: number) => boolean;
	// Current Pi session id. Snapshots whose sessionId disagrees with this
	// value are still rehydrated (so the dashboard can show their final
	// state) but are not eligible for missed-exit replay; replay is scoped
	// to the session that originally spawned the task.
	sessionId?: string;
}

// Rehydrate a persisted snapshot into a ManagedTask placeholder. The child
// process is gone in the vast majority of cases, so closed=true and timers
// are zeroed. Two cases get special treatment:
//
// 1. snapshot.status === 'running' AND the recorded PID is no longer
//    alive -> coerce to 'stopped', stopReason=shutdown, exitNotified=false
//    so selectMissedExits / replayMissedExits can deliver the deferred
//    'exit' wake. This is the primary defense from vstack#15.
//
// 2. snapshot.status === 'running' AND the recorded PID is still alive
//    (Pi restarted but the detached child group is still chugging) ->
//    keep status='running', child=null, exitNotified untouched, and tag
//    the rehydrated task as `restored: true` + `closed: false` so the
//    caller can re-attach output streams (or at minimum surface the
//    orphan in the dashboard) instead of falsely announcing it exited.
//
// Already-terminal snapshots flow through unchanged. Pre-vstack#15
// snapshots that lack exitNotified are treated as notified for terminal
// states; only fresh running->stopped coercion produces exitNotified=false.
export function restoredTaskFromSnapshot(snapshot: BackgroundTaskSnapshot, options: RestoreOptions = {}): ManagedTask {
	const now = options.now ?? Date.now();
	const isAlive = options.isProcessAlive ?? defaultProcessAlive;
	const wasRunning = snapshot.status === "running";
	const foreignSession = typeof options.sessionId === "string"
		&& typeof snapshot.sessionId === "string"
		&& snapshot.sessionId !== options.sessionId;
	const pidStillAlive = wasRunning && !foreignSession && isAlive(snapshot.pid);
	const coercedFromRunning = wasRunning && !pidStillAlive;

	// Backward-compat: snapshots from <=1.2.0 have no `exitNotified` field.
	// Treat undefined as "already notified" for terminal states so an
	// upgrade doesn't replay every historical task. Only the
	// running->stopped coercion below produces a false (replay-eligible)
	// value. Foreign-session snapshots are pinned to notified=true so
	// cross-session leaks are impossible.
	let exitNotified: boolean;
	if (coercedFromRunning && !foreignSession) {
		exitNotified = false;
	} else if (foreignSession) {
		exitNotified = true;
	} else if (snapshot.status === "running") {
		exitNotified = snapshot.exitNotified === true;
	} else {
		exitNotified = snapshot.exitNotified === undefined ? true : snapshot.exitNotified;
	}

	return {
		...snapshot,
		child: null,
		closed: !pidStillAlive,
		exitNotified,
		forceKillTimer: null,
		lastAnnouncedLength: snapshot.outputBytes,
		matcher: parseOutputMatcher(snapshot.notifyPattern),
		output: "",
		outputTimer: null,
		status: pidStillAlive ? "running" : (wasRunning ? "stopped" : snapshot.status),
		stopReason: pidStillAlive ? null : (coercedFromRunning ? "shutdown" : null),
		timeoutTimer: null,
		restored: true,
		updatedAt: coercedFromRunning ? now : snapshot.updatedAt,
		sessionId: options.sessionId ?? snapshot.sessionId,
	};
}

// Select tasks whose terminal transition never produced an exit wake.
// Drives replayMissedExits on session_start so a session restart can
// recover from running->stopped coercion in restoredTaskFromSnapshot or
// a session_shutdown that killed tasks without notifying the agent.
//
// Treats `exitNotified === undefined` as notified to preserve
// backward-compatibility with snapshots persisted before this field
// existed; restoredTaskFromSnapshot is the only path that flips this
// to false (and only on a fresh running->stopped coercion).
export function selectMissedExits<T extends Pick<BackgroundTaskSnapshot, "status" | "notifyOnExit" | "exitNotified">>(
	tasks: Iterable<T>,
): T[] {
	const out: T[] = [];
	for (const task of tasks) {
		if (task.status === "running") continue;
		if (!task.notifyOnExit) continue;
		if (task.exitNotified !== false) continue;
		out.push(task);
	}
	return out;
}
