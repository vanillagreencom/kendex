import type { ChildProcess } from "node:child_process";

export type BackgroundTaskStatus = "running" | "completed" | "failed" | "stopped" | "timed_out";
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
	| "voided";

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

export interface BackgroundTaskEventDetails {
	deliveredAt: number;
	eventAt: number;
	eventType: TaskEventType;
	matchedPattern?: string;
	newOutputTail?: string;
	outputTail: string;
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
}

export interface BashBackgroundDecision {
	forced: boolean;
	notifyOnExit: boolean;
	notifyOnOutput: boolean;
	notifyPattern?: string;
	reason: string;
	title: string;
}
