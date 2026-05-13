import type { ChildProcess } from "node:child_process";

export type BackgroundTaskStatus = "running" | "completed" | "failed" | "stopped" | "timed_out";
export type TaskEventType = "output" | "exit";

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
	outputBytes: number;
	// True after sendTaskEvent('exit') has fired for this task. Persisted so
	// a session restart can replay missed exit wakeups for tasks that hit
	// terminal state (notably the running->stopped coercion in
	// restoredTaskFromSnapshot) without ever notifying the agent.
	exitNotified?: boolean;
}

export type ManagedTask = BackgroundTaskSnapshot & {
	child: ChildProcess | null;
	closed: boolean;
	forceKillTimer: ReturnType<typeof setTimeout> | null;
	lastAnnouncedLength: number;
	matcher: ((text: string) => boolean) | null;
	output: string;
	outputTimer: ReturnType<typeof setTimeout> | null;
	stopReason: "user" | "timeout" | "shutdown" | null;
	timeoutTimer: ReturnType<typeof setTimeout> | null;
	restored?: boolean;
};

export interface BackgroundTaskEventDetails {
	eventAt: number;
	eventType: TaskEventType;
	matchedPattern?: string;
	newOutputTail?: string;
	outputTail: string;
	task: BackgroundTaskSnapshot;
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
