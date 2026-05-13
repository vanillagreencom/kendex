// Canonical contract for pi-bg-task-exit wake events (vstack#15).
//
// Bash mirror lives at scripts/lib/daemon-bg-task-events.sh as
// BG_TASK_EVENT_CUSTOM_TYPE / BG_TASK_EXIT_EVENT_TYPE /
// BG_TASK_EXIT_CLASSIFIER_TAG. The parity test at
// tests/unit/bg-task-exit-contract.test.ts reads both files and asserts
// the constants match so a typo in either place fails CI immediately
// instead of silently breaking the routing.

/** Pi `pi.sendMessage` customType for the pi-background-tasks adapter. */
export const BG_TASK_EVENT_CUSTOM_TYPE = "vstack-background-tasks:event";

/** `details.eventType` discriminator for terminal-state exit notifications. */
export const BG_TASK_EXIT_EVENT_TYPE = "exit";

/** Classifier tag the daemon emits to the wake-events log. */
export const BG_TASK_EXIT_CLASSIFIER_TAG = "pi-bg-task-exit";

export interface BgTaskExitPayload {
	id: string;
	status: "running" | "completed" | "failed" | "stopped" | "timed_out";
	exitCode: number | null;
	command: string;
	notifyOnExit?: boolean;
	notifyOnOutput?: boolean;
	outputBytes?: number;
	startedAt?: number;
	updatedAt?: number;
	exitNotified?: boolean;
}

/** Wake-events log row emitted by the subscriber for a bg-task exit. */
export interface BgTaskExitWakeRow {
	ts: string;
	pane_id: string;
	harness: "pi";
	event_type: "bg-task-exit";
	task: BgTaskExitPayload | Record<string, unknown>;
	classifier_tag: typeof BG_TASK_EXIT_CLASSIFIER_TAG;
	hash: string;
}
