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

// Rehydrate a persisted snapshot into a ManagedTask placeholder. The child
// process is gone, so we mark closed=true and zero out timers. Any task
// that was 'running' at persist time is coerced to 'stopped' with
// exitNotified=false so the caller can replay the missed exit wake.
export function restoredTaskFromSnapshot(snapshot: BackgroundTaskSnapshot, now: number = Date.now()): ManagedTask {
	const coercedFromRunning = snapshot.status === "running";
	return {
		...snapshot,
		child: null,
		closed: true,
		exitNotified: coercedFromRunning ? false : snapshot.exitNotified === true,
		forceKillTimer: null,
		lastAnnouncedLength: snapshot.outputBytes,
		matcher: parseOutputMatcher(snapshot.notifyPattern),
		output: "",
		outputTimer: null,
		status: coercedFromRunning ? "stopped" : snapshot.status,
		stopReason: coercedFromRunning ? "shutdown" : null,
		timeoutTimer: null,
		restored: true,
		updatedAt: coercedFromRunning ? now : snapshot.updatedAt,
	};
}

// Select tasks whose terminal transition never produced an exit wake.
// Drives replayMissedExits on session_start so a session restart can
// recover from running->stopped coercion in restoredTaskFromSnapshot or
// a session_shutdown that killed tasks without notifying the agent.
export function selectMissedExits<T extends Pick<BackgroundTaskSnapshot, "status" | "notifyOnExit" | "exitNotified">>(
	tasks: Iterable<T>,
): T[] {
	const out: T[] = [];
	for (const task of tasks) {
		if (task.status === "running") continue;
		if (!task.notifyOnExit) continue;
		if (task.exitNotified === true) continue;
		out.push(task);
	}
	return out;
}
