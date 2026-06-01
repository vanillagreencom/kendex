import type { ChildProcess } from "node:child_process";

export type BackgroundTaskStatus = "running" | "completed" | "failed" | "stopped" | "timed_out";

export type ResourceControlMode = "auto" | "systemd-run" | "nice-ionice" | "off";
export type ResourceControlAppliedMode = "systemd-run" | "nice-ionice";

export interface ResourceControlMetadata {
	mode: ResourceControlAppliedMode;
	requestedMode: ResourceControlMode;
	unitName?: string;
	warning?: string;
}

/**
 * Why a tracked task left the running state. Surfaced on `bg_status list`,
 * the wake-event payload, and persisted snapshots so callers can distinguish
 * a clean self-exit from an external kill (vstack#97).
 *
 * - `self-exit`: child closed on its own with no stop request. Reserved for
 *   `completed` (exitCode 0) and `failed` (non-zero exitCode). `external` is
 *   the same close path with `exitCode === null`, which means the child was
 *   killed by a signal we did not issue.
 * - `extension-stop`: this extension issued the kill via `bg_status stop`.
 * - `session-shutdown`: this extension issued the kill on `session_shutdown`.
 * - `timeout`: the task's `timeoutSeconds` budget elapsed.
 * - `reconcile-on-restart`: a Pi restart probed the recorded pid and found
 *   it gone; the task was coerced running -> stopped in
 *   `restoredTaskFromSnapshot`. The actual cause of death is unknown to us
 *   (Pi may have crashed mid-bg_task, the OS may have OOM-killed the child,
 *   or an unrelated session-leader cascade may have hit it).
 * - `orphaned-pid-gone` / `orphaned-pid-reused`: the orphan-watcher polled
 *   a previously-restored alive task and found the pid gone or recycled.
 */
export type BackgroundTaskTerminationReason =
	| "self-exit"
	| "extension-stop"
	| "session-shutdown"
	| "timeout"
	| "external"
	| "reconcile-on-restart"
	| "orphaned-pid-gone"
	| "orphaned-pid-reused";
export type TaskEventType = "output" | "exit";
export type NotifyMode = "always" | "transition" | "first-match-only";

export type WakeDropReason =
	| "empty-output"
	| "first-match-only-suppressed"
	| "cleared-on-task-exit"
	| "notify-exit-disabled"
	| "notify-output-disabled"
	| "notify-pattern-no-match"
	| "output-after-stop-suppressed"
	| "output-transition-dedupe"
	| "output-wake-rescheduled"
	| "shutting-down"
	| "voided"
	| "wake-budget-exhausted";

// Cumulative per-task accounting for the output-wake budget guard (vstack#210).
// Persisted so a session restart preserves the cap and a chatty task cannot
// reset its inline-wake budget by triggering a Pi reload.
export interface OutputWakeBudgetState {
	wakes: number;
	bytes: number;
	exhausted: boolean;
	announcedAt: number | null;
}

export interface WakeEventRecord {
	deliveredAt: number | null;
	droppedReason?: WakeDropReason;
	eventAt: number;
	eventType: TaskEventType;
	sequence: number;
	taskStatusAtEmit: BackgroundTaskStatus;
}

export interface WakePendingRecord {
	eventAt: number;
	eventType: TaskEventType;
	sequence: number;
}

export interface WakeDiagnostic {
	action?: "stop" | "clear" | "shutdown";
	dedupeKey?: string;
	deliveredAt?: number | null;
	eventAt?: number;
	eventType?: TaskEventType;
	matchedPattern?: string;
	reason:
		| WakeDropReason
		| "voided-wake-fired"
		| "wake-voided";
	sequence?: number;
	stopReason?: "user" | "timeout" | "shutdown";
	taskId: string;
	taskStatus: BackgroundTaskStatus;
	timestamp: number;
}

// Identity tuple used to detect PID reuse on restore/poll. The kernel
// may recycle a PID for an unrelated process; a bare `kill -0` check
// would then return alive and the bg_task would be considered still
// running against a foreign process. startToken is the process start
// time (jiffies-since-boot on Linux via /proc/<pid>/stat field 22, or
// the absolute `ps -o lstart=` string everywhere else), which is
// unique per PID lifetime. comm is the kernel comm name, a defensive
// secondary signal. Mismatch on either field treats the original task
// as gone (reviewer-error MAJOR, vstack#15 round 4).
export interface ProcessIdentity {
	pid: number;
	startToken: string;
	comm: string;
}

export interface VstackModalLock {
	depth: number;
}

export type VstackConfig = Record<string, unknown>;

export interface BackgroundTaskSnapshot {
	id: string;
	title: string;
	command: string;
	cwd: string;
	pid: number;
	logFile: string;
	startedAt: number;
	updatedAt: number;
	lastOutputAt: number | null;
	expiresAt: number | null;
	status: BackgroundTaskStatus;
	exitCode: number | null;
	notifyOnExit: boolean;
	notifyOnOutput: boolean;
	notifyPattern?: string;
	notifyMode?: NotifyMode;
	dedupeKey?: string;
	outputBytes: number;
	wakeSequence?: number;
	wakeEvents?: WakeEventRecord[];
	voidedWakeSequences?: number[];
	pendingWakes?: WakePendingRecord[];
	lastOutputDedupeHash?: string;
	lastOutputDedupeByKey?: Record<string, string>;
	outputPatternMatched?: boolean;
	/**
	 * Per-task budget accounting for output wakes (vstack#210). Persists so a
	 * session restart preserves the cap. Absent on snapshots persisted by
	 * versions <1.4.0 (this is the version that introduces the field) —
	 * treated as a fresh budget on restore.
	 */
	outputWakeBudget?: OutputWakeBudgetState;
	// True after sendTaskEvent('exit') has fired for this task. Persisted so
	// a session restart can replay missed exit wakeups for tasks that hit
	// terminal state (notably the running->stopped coercion in
	// restoredTaskFromSnapshot) without ever notifying the agent.
	//
	// Backward-compat: snapshots persisted by versions <=1.2.0 do not carry
	// this field. selectMissedExits/restoredTaskFromSnapshot treat undefined
	// on an already-terminal snapshot as "notified" so post-upgrade we do
	// not replay every historical terminal task. Only running->stopped
	// coercion at restore time produces exitNotified=false and replays.
	exitNotified?: boolean;
	// Pi session id at the time the snapshot was persisted. Used at restore
	// to gate replay ("this snapshot belongs to a different session"
	// short-circuits cross-session leaks) and to make audit logs explicit.
	sessionId?: string;
	// Process identity captured at spawn for PID-reuse-safe liveness
	// checks on restore + orphan polls. Absent on pre-1.2.2 snapshots;
	// identity check degrades to PID-only for those.
	procIdent?: ProcessIdentity;
	/**
	 * Optional metadata for opt-in resource controls (vstack#300). Systemd scope
	 * tasks persist their transient unit name so stop/timeout/shutdown paths can
	 * stop the actual workload instead of only signaling the systemd-run wrapper.
	 */
	resourceControl?: ResourceControlMetadata;
	/**
	 * Why this task left the running state. Optional so snapshots persisted
	 * before vstack#97 still load (treated as undefined). Set on every
	 * terminal transition through finalizeTaskLifecycle, the
	 * restoredTaskFromSnapshot coercion path, and the orphan watcher.
	 */
	terminationReason?: BackgroundTaskTerminationReason;
}

export type ManagedTask = BackgroundTaskSnapshot & {
	child: ChildProcess | null;
	closed: boolean;
	forceKillTimer: ReturnType<typeof setTimeout> | null;
	lastAnnouncedLength: number;
	matcher: ((text: string) => boolean) | null;
	output: string;
	outputTimer: ReturnType<typeof setTimeout> | null;
	voidedWakes: Set<number>;
	stopReason: "user" | "timeout" | "shutdown" | null;
	timeoutTimer: ReturnType<typeof setTimeout> | null;
	restored?: boolean;
};

/**
 * Wake-event payload attached to the pi.sendMessage `details` field. Output
 * wakes carry the most recent unseen tail; exit wakes carry the trailing
 * portion of full output. Both inline tails are bounded by
 * `outputAlertMaxChars` (default 2KB) and `details.task.logFile` always
 * points to the full on-disk log for recovery. Total `details` payload is
 * targeted to stay under 4KB to keep transcript growth bounded (vstack#210).
 */
export interface BackgroundTaskEventDetails {
	deliveredAt: number;
	eventAt: number;
	eventType: TaskEventType;
	matchedPattern?: string;
	outputTail: string;
	/**
	 * True iff `outputTail` had to be truncated to fit the cap. The caller can
	 * surface the full log via `task.logFile`.
	 */
	outputTailTruncated: boolean;
	sequence: number;
	task: BackgroundTaskSnapshot;
	taskStatusAtEmit: BackgroundTaskStatus;
}

export interface BackgroundLogTruncation {
	direction: "tail";
	fullOutputPath: string;
	shownChars: number;
	totalChars: number;
	truncated: true;
}

export interface SpawnTaskOptions {
	command: string;
	cwd?: string;
	notifyOnExit?: boolean;
	notifyOnOutput?: boolean;
	notifyPattern?: string;
	notifyMode?: NotifyMode;
	dedupeKey?: string;
	timeoutSeconds?: number;
	title?: string;
	origin?: "bg_task" | "auto-background";
}

export interface BashBackgroundDecision {
	forced: boolean;
	notifyOnExit: boolean;
	notifyOnOutput: boolean;
	notifyPattern?: string;
	reason: string;
	title: string;
}
