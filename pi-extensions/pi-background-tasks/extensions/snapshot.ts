import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

import { parseOutputMatcher } from "./format.js";
import type { BackgroundTaskSnapshot, ManagedTask, ProcessIdentity } from "./types.js";
import { normalizeNotifyMode, normalizeOutputWakeBudget } from "./wake-events.js";

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
		notifyMode: normalizeNotifyMode(task.notifyMode),
		dedupeKey: task.dedupeKey,
		outputBytes: task.outputBytes,
		wakeSequence: task.wakeSequence ?? 0,
		wakeEvents: task.wakeEvents ?? [],
		voidedWakeSequences: task.voidedWakes instanceof Set
			? [...task.voidedWakes].sort((a, b) => a - b)
			: (task.voidedWakeSequences ?? []),
		pendingWakes: task.pendingWakes ?? [],
		lastOutputDedupeHash: task.lastOutputDedupeHash,
		lastOutputDedupeByKey: task.lastOutputDedupeByKey,
		outputPatternMatched: task.outputPatternMatched === true,
		outputWakeBudget: task.outputWakeBudget ? normalizeOutputWakeBudget(task.outputWakeBudget) : undefined,
		pid: task.pid,
		procIdent: task.procIdent,
		resourceControl: task.resourceControl,
		sessionId: task.sessionId,
		startedAt: task.startedAt,
		status: task.status,
		terminationReason: task.terminationReason,
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
// pid as alive (or EPERM, which means alive-but-foreign). Used as a
// pre-filter before the more expensive identity probe; the watcher /
// restore paths use identityProbe directly so PID reuse cannot pass
// as "still running".
export function defaultProcessAlive(pid: number): boolean {
	if (!Number.isFinite(pid) || pid <= 0) return false;
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

// Read kernel-stable process identity. Linux fast path: /proc/<pid>/stat
// field 22 (starttime in jiffies since boot) + /proc/<pid>/comm. Other
// platforms: `ps -o lstart=,comm= -p <pid>` returns an absolute start
// time string + comm. Returns null when the pid is gone or the probe
// failed. Used to detect PID reuse: the kernel may recycle a PID for
// an unrelated process, but the start token cannot collide for the
// same recycled pid within the same boot.
export function defaultReadProcessIdentity(pid: number): ProcessIdentity | null {
	if (!Number.isFinite(pid) || pid <= 0) return null;
	if (process.platform === "linux") {
		try {
			const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
			const lastParen = stat.lastIndexOf(")");
			if (lastParen < 0) return null;
			// stat fields after the closing paren of comm are space-separated.
			// starttime is field 22 globally, which is index 22-3=19 inside the
			// post-paren slice (fields 1, 2 (parenthesized comm), 3..N).
			const after = stat.slice(lastParen + 1).trim().split(/\s+/);
			const starttime = after[19];
			if (!starttime) return null;
			const comm = stat.slice(stat.indexOf("(") + 1, lastParen);
			return { pid, startToken: starttime, comm };
		} catch {
			// Fall through to the portable ps path.
		}
	}
	const r = spawnSync("ps", ["-o", "lstart=,comm=", "-p", String(pid)], { encoding: "utf8" });
	if (r.status !== 0) return null;
	const line = (r.stdout ?? "").trim();
	if (!line) return null;
	// lstart format: "Day Mon DD HH:MM:SS YYYY" (5 whitespace-separated tokens),
	// then comm. Split on whitespace and reassemble.
	const parts = line.split(/\s+/);
	if (parts.length < 6) return null;
	return { pid, startToken: parts.slice(0, 5).join(" "), comm: parts.slice(5).join(" ") };
}

// True iff both identities are present and the kernel-stable subset
// matches. "Kernel-stable" means pid + startToken (process start time):
// these cannot drift while the original process lives. comm is
// captured and persisted as a diagnostic so `bg_task list` / logs can
// show what the process was at spawn, but it is NOT part of equality:
// the common `bash -lc "sleep 5"` pattern rotates /proc/<pid>/comm
// from "bash" to "sleep" via exec(2) without changing pid or
// starttime. Gating identity on comm would false-finalize a still-live
// task (reviewer-error BLOCK, vstack#15 round 5).
//
// Absent identity on the snapshot (pre-1.2.2 upgrade) is treated as a
// match because we have no pre-recorded token to compare against and
// PID-only liveness is the documented degraded path. background-tasks.ts
// emits a one-time legacy-fallback warning so operators can notice
// long-lived pre-upgrade tasks.
export function identityMatches(
	recorded: ProcessIdentity | undefined,
	current: ProcessIdentity | null,
): boolean {
	if (!current) return false;
	if (!recorded) return true;
	return recorded.pid === current.pid
		&& recorded.startToken === current.startToken;
}

export interface RestoreOptions {
	now?: number;
	// Identity probe. Default uses /proc + ps. Return null when the pid
	// is gone or the probe failed; the watcher / restore paths then
	// treat the task as terminal and replay the missed exit. Return a
	// ProcessIdentity when the pid is alive; identityMatches against
	// the snapshot's procIdent decides whether the original task is
	// still that process or PID reuse hit.
	identityProbe?: (pid: number) => ProcessIdentity | null;
	// Current Pi session id. Snapshots whose sessionId disagrees with this
	// value are still rehydrated (so the dashboard can show their final
	// state) but are not eligible for missed-exit replay; replay is scoped
	// to the session that originally spawned the task.
	sessionId?: string;
	// Optional systemd scope liveness probe for resource-controlled tasks.
	// Returns true while the persisted transient scope/unit is active, false
	// when it is known inactive, and null when the unit cannot be queried.
	unitActiveProbe?: (unitName: string) => boolean | null;
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
	const probe = options.identityProbe ?? defaultReadProcessIdentity;
	const wasRunning = snapshot.status === "running";
	const foreignSession = typeof options.sessionId === "string"
		&& typeof snapshot.sessionId === "string"
		&& snapshot.sessionId !== options.sessionId;
	// PID-reuse safe: a non-null identity is required AND must match the
	// snapshot's recorded procIdent (when present). Pre-1.2.2 snapshots
	// with no procIdent degrade to PID-only liveness via identityMatches.
	let pidStillAlive = false;
	if (wasRunning && !foreignSession) {
		const unitName = snapshot.resourceControl?.mode === "systemd-run" ? snapshot.resourceControl.unitName : undefined;
		const unitActive = unitName ? options.unitActiveProbe?.(unitName) : null;
		if (unitActive === true) {
			pidStillAlive = true;
		} else if (unitActive !== false) {
			const current = probe(snapshot.pid);
			if (current !== null && identityMatches(snapshot.procIdent, current)) {
				pidStillAlive = true;
			}
		}
	}
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

	// vstack#97: annotate the running -> stopped coercion so callers can
	// distinguish a Pi-restart reconcile from a clean self-exit or an
	// explicit extension stop. Pre-existing termination reasons (e.g. a
	// snapshot persisted at extension-stop time) are preserved.
	let terminationReason = snapshot.terminationReason;
	if (coercedFromRunning && terminationReason === undefined) {
		terminationReason = "reconcile-on-restart";
	}

	return {
		...snapshot,
		child: null,
		closed: !pidStillAlive,
		exitNotified,
		forceKillTimer: null,
		lastAnnouncedLength: snapshot.outputBytes,
		lastOutputDedupeHash: snapshot.lastOutputDedupeHash,
		lastOutputDedupeByKey: snapshot.lastOutputDedupeByKey ?? {},
		matcher: parseOutputMatcher(snapshot.notifyPattern),
		notifyMode: normalizeNotifyMode(snapshot.notifyMode),
		output: "",
		outputPatternMatched: snapshot.outputPatternMatched === true,
		outputWakeBudget: normalizeOutputWakeBudget(snapshot.outputWakeBudget),
		outputTimer: null,
		pendingWakes: [],
		status: pidStillAlive ? "running" : (wasRunning ? "stopped" : snapshot.status),
		stopReason: pidStillAlive ? null : (coercedFromRunning ? "shutdown" : null),
		terminationReason,
		timeoutTimer: null,
		voidedWakeSequences: snapshot.voidedWakeSequences ?? [],
		voidedWakes: new Set(snapshot.voidedWakeSequences ?? []),
		wakeEvents: snapshot.wakeEvents ?? [],
		wakeSequence: snapshot.wakeSequence ?? 0,
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
