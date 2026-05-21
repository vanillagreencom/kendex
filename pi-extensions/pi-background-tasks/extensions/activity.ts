import type { ManagedTask, TaskEventType } from "./types.js";

export type PiActivitySeverity = "debug" | "info" | "success" | "warning" | "error";
export type PiActivityImportance = "critical" | "important" | "normal" | "noisy";

export interface PiActivityEvent {
	type: string;
	source: "pi-bg-task";
	severity: PiActivitySeverity;
	importance: PiActivityImportance;
	summary: string;
	body?: string;
	refs?: { bg_task_id?: string };
	details?: Record<string, unknown>;
	ts?: string;
}

interface PiActivityBroker {
	publish(event: PiActivityEvent): void;
}

export interface BackgroundTaskActivityOptions {
	eventAt?: number;
	matchedPattern?: string;
	newOutputTail?: string;
	sequence?: number;
}

const ACTIVITY_BROKER_SYMBOL = Symbol.for("vstack.pi.activity");
const COMMAND_DETAIL_MAX_CHARS = 200;
// Activity broker payloads are sidecar (not transcript), but a 10-20KB tail
// per match still bloats the JSONL stream and Flightdeck's activity sidecar
// (vstack#210). Keep the broker preview compact; full output stays on disk.
const ACTIVITY_OUTPUT_TAIL_MAX_CHARS = 512;

export function publishBackgroundTaskStarted(task: ManagedTask): void {
	publishBackgroundTaskActivity("start", task, { eventAt: task.startedAt, sequence: task.wakeSequence ?? 0 });
}

export function publishBackgroundTaskActivity(eventType: TaskEventType | "start", task: ManagedTask, options: BackgroundTaskActivityOptions = {}): void {
	try {
		const broker = activityBroker();
		if (!broker) return;
		broker.publish(buildBackgroundTaskActivity(eventType, task, options));
	} catch {
		// Activity publication is best-effort and must never affect task lifecycle.
	}
}

export function buildBackgroundTaskActivity(eventType: TaskEventType | "start", task: ManagedTask, options: BackgroundTaskActivityOptions = {}): PiActivityEvent {
	const type = backgroundTaskActivityType(eventType, task.status);
	const sequence = options.sequence ?? task.wakeSequence ?? 0;
	return {
		details: {
			command: truncateCommand(task.command),
			event_type: eventType,
			exit_code: typeof task.exitCode === "number" ? task.exitCode : null,
			matched_pattern: options.matchedPattern,
			new_output_tail: truncateActivityTail(options.newOutputTail),
			output_bytes: task.outputBytes,
			sequence,
			status: task.status,
			// vstack#97: carry the termination annotation on the broker event
			// so dashboards / loggers can distinguish self-exit, extension-stop,
			// reconcile-on-restart, and orphan-watcher finalizes.
			termination_reason: task.terminationReason,
		},
		importance: backgroundTaskImportance(type),
		refs: { bg_task_id: task.id },
		severity: backgroundTaskSeverity(type),
		source: "pi-bg-task",
		summary: `background task ${task.id} ${backgroundTaskSummaryVerb(type)}`,
		ts: new Date(options.eventAt ?? task.updatedAt ?? Date.now()).toISOString(),
		type,
	};
}

function activityBroker(): PiActivityBroker | undefined {
	const broker = (globalThis as unknown as Record<PropertyKey, unknown>)[ACTIVITY_BROKER_SYMBOL];
	return broker && typeof broker === "object" && typeof (broker as PiActivityBroker).publish === "function"
		? broker as PiActivityBroker
		: undefined;
}

function backgroundTaskActivityType(eventType: TaskEventType | "start", status: string): string {
	if (eventType === "start") return "bg_task.started";
	if (eventType === "output") return "bg_task.output_matched";
	if (status === "timed_out") return "bg_task.timed_out";
	if (status === "failed") return "bg_task.failed";
	if (status === "stopped") return "bg_task.stopped";
	return "bg_task.completed";
}

function backgroundTaskSeverity(type: string): PiActivitySeverity {
	if (type === "bg_task.failed" || type === "bg_task.timed_out") return "error";
	if (type === "bg_task.stopped") return "warning";
	if (type === "bg_task.completed") return "success";
	return "info";
}

function backgroundTaskImportance(type: string): PiActivityImportance {
	if (type === "bg_task.output_matched" || type === "bg_task.started") return "noisy";
	if (type === "bg_task.completed") return "normal";
	return "important";
}

function backgroundTaskSummaryVerb(type: string): string {
	switch (type) {
		case "bg_task.started": return "started";
		case "bg_task.output_matched": return "matched output";
		case "bg_task.failed": return "failed";
		case "bg_task.timed_out": return "timed out";
		case "bg_task.stopped": return "stopped";
		default: return "completed";
	}
}

function truncateCommand(command: string): string {
	return command.length > COMMAND_DETAIL_MAX_CHARS ? command.slice(0, COMMAND_DETAIL_MAX_CHARS) : command;
}

function truncateActivityTail(tail: string | undefined): string | undefined {
	if (typeof tail !== "string") return undefined;
	if (tail.length <= ACTIVITY_OUTPUT_TAIL_MAX_CHARS) return tail;
	return `${tail.slice(-ACTIVITY_OUTPUT_TAIL_MAX_CHARS)}`;
}
