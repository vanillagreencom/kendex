import { createHash } from "node:crypto";

import type {
	BackgroundTaskEventDetails,
	BackgroundTaskSnapshot,
	ManagedTask,
	NotifyMode,
	TaskEventType,
	WakeDiagnostic,
	WakeDropReason,
	WakeEventRecord,
	WakePendingRecord,
} from "./types.js";

export const NOTIFY_MODES = ["always", "transition", "first-match-only"] as const;
const MAX_WAKE_EVENTS = 50;

export function normalizeNotifyMode(value: unknown): NotifyMode {
	return value === "transition" || value === "first-match-only" ? value : "always";
}

export function ensureWakeState(task: ManagedTask): void {
	task.notifyMode = normalizeNotifyMode(task.notifyMode);
	task.wakeSequence = Number.isFinite(task.wakeSequence) ? Math.max(0, Math.floor(task.wakeSequence ?? 0)) : 0;
	task.wakeEvents = Array.isArray(task.wakeEvents) ? task.wakeEvents : [];
	task.pendingWakes = Array.isArray(task.pendingWakes) ? task.pendingWakes : [];
	task.voidedWakeSequences = Array.isArray(task.voidedWakeSequences) ? [...new Set(task.voidedWakeSequences)] : [];
	task.lastOutputDedupeByKey = task.lastOutputDedupeByKey && typeof task.lastOutputDedupeByKey === "object" ? task.lastOutputDedupeByKey : {};
	if (!(task.voidedWakes instanceof Set)) task.voidedWakes = new Set<number>();
	for (const sequence of task.voidedWakeSequences) task.voidedWakes.add(sequence);
	task.voidedWakeSequences = [...task.voidedWakes].sort((a, b) => a - b);
	task.outputPatternMatched = task.outputPatternMatched === true;
}

export function canEmitOutputWake(task: Pick<ManagedTask, "status" | "stopReason">): boolean {
	return task.status === "running" && task.stopReason == null;
}

export function nextWakeSequence(task: ManagedTask): number {
	ensureWakeState(task);
	task.wakeSequence = (task.wakeSequence ?? 0) + 1;
	return task.wakeSequence;
}

export function scheduleTaskWake(
	task: ManagedTask,
	eventType: TaskEventType,
	eventAt: number,
): WakePendingRecord {
	ensureWakeState(task);
	const pending: WakePendingRecord = { eventAt, eventType, sequence: nextWakeSequence(task) };
	task.pendingWakes = [...(task.pendingWakes ?? []), pending];
	return pending;
}

export function forgetPendingWake(task: ManagedTask, sequence: number): void {
	ensureWakeState(task);
	task.pendingWakes = (task.pendingWakes ?? []).filter((wake) => wake.sequence !== sequence);
}

export function isWakeVoided(task: ManagedTask, sequence: number): boolean {
	ensureWakeState(task);
	return task.voidedWakes.has(sequence) || (task.voidedWakeSequences ?? []).includes(sequence);
}

export function voidPendingTaskWakes(
	task: ManagedTask,
	action: "stop" | "clear" | "shutdown",
	logDiagnostic?: (diagnostic: WakeDiagnostic) => void,
	now: () => number = Date.now,
): number {
	ensureWakeState(task);
	const pending = task.pendingWakes ?? [];
	if (pending.length === 0) return 0;
	for (const wake of pending) {
		task.voidedWakes.add(wake.sequence);
		logDiagnostic?.({
			action,
			eventAt: wake.eventAt,
			eventType: wake.eventType,
			reason: "wake-voided",
			sequence: wake.sequence,
			taskId: task.id,
			taskStatus: task.status,
			timestamp: now(),
		});
	}
	task.voidedWakeSequences = [...task.voidedWakes].sort((a, b) => a - b);
	task.pendingWakes = [];
	return pending.length;
}

export function recordWakeEvent(task: ManagedTask, record: WakeEventRecord): void {
	ensureWakeState(task);
	task.wakeEvents = [...(task.wakeEvents ?? []), record].slice(-MAX_WAKE_EVENTS);
	if (record.droppedReason === "voided") {
		task.voidedWakes.add(record.sequence);
		task.voidedWakeSequences = [...task.voidedWakes].sort((a, b) => a - b);
	}
}

export interface RecordScheduledOutputDropInput {
	extra?: Partial<WakeDiagnostic>;
	logDiagnostic: (diagnostic: WakeDiagnostic) => void;
	now?: () => number;
	pending: WakePendingRecord;
	reason: WakeDropReason;
	task: ManagedTask;
}

export function recordScheduledOutputDrop(input: RecordScheduledOutputDropInput): void {
	const now = input.now ?? Date.now;
	const timestamp = now();
	forgetPendingWake(input.task, input.pending.sequence);
	recordWakeEvent(input.task, {
		deliveredAt: null,
		droppedReason: input.reason,
		eventAt: input.pending.eventAt,
		eventType: "output",
		sequence: input.pending.sequence,
		taskStatusAtEmit: input.task.status,
	});
	input.logDiagnostic({
		eventAt: input.pending.eventAt,
		eventType: "output",
		reason: input.reason,
		sequence: input.pending.sequence,
		taskId: input.task.id,
		taskStatus: input.task.status,
		timestamp,
		...input.extra,
	});
}

function recordWakeDrop(
	task: ManagedTask,
	pending: WakePendingRecord,
	reason: WakeDropReason,
	logDiagnostic: (diagnostic: WakeDiagnostic) => void,
	now: () => number,
	extra: Partial<WakeDiagnostic> = {},
): void {
	const timestamp = now();
	forgetPendingWake(task, pending.sequence);
	recordWakeEvent(task, {
		deliveredAt: null,
		droppedReason: reason,
		eventAt: pending.eventAt,
		eventType: pending.eventType,
		sequence: pending.sequence,
		taskStatusAtEmit: task.status,
	});
	logDiagnostic({
		eventAt: pending.eventAt,
		eventType: pending.eventType,
		reason: reason === "voided" ? "voided-wake-fired" : reason,
		sequence: pending.sequence,
		taskId: task.id,
		taskStatus: task.status,
		timestamp,
		...extra,
	});
}

function sha256(value: string): string {
	return createHash("sha256").update(value).digest("hex");
}

export interface OutputWakeDecisionInput {
	dedupeHashes?: Map<string, string>;
	eventAt: number;
	logDiagnostic?: (diagnostic: WakeDiagnostic) => void;
	newOutput: string;
	newOutputTail: string;
	now?: () => number;
	patternMatched: boolean;
	sequence?: number;
}

export function outputDedupeKey(task: ManagedTask): string {
	ensureWakeState(task);
	return task.dedupeKey?.trim() || task.id;
}

export function shouldEmitOutputWake(task: ManagedTask, input: OutputWakeDecisionInput): boolean {
	ensureWakeState(task);
	const log = input.logDiagnostic;
	const now = input.now ?? Date.now;
	const baseDiagnostic = {
		eventAt: input.eventAt,
		eventType: "output" as const,
		sequence: input.sequence,
		taskId: task.id,
		taskStatus: task.status,
		timestamp: now(),
	};
	if (!task.notifyOnOutput) {
		log?.({ ...baseDiagnostic, reason: "notify-output-disabled" });
		return false;
	}
	if (!canEmitOutputWake(task)) {
		log?.({ ...baseDiagnostic, reason: "output-after-stop-suppressed", stopReason: task.stopReason ?? undefined });
		return false;
	}
	if (!input.newOutput.trim()) {
		log?.({ ...baseDiagnostic, reason: "empty-output" });
		return false;
	}
	if (!input.patternMatched) {
		log?.({ ...baseDiagnostic, matchedPattern: task.notifyPattern, reason: "notify-pattern-no-match" });
		return false;
	}

	const notifyMode = normalizeNotifyMode(task.notifyMode);
	if (notifyMode === "first-match-only" && task.notifyPattern && task.outputPatternMatched) {
		log?.({ ...baseDiagnostic, matchedPattern: task.notifyPattern, reason: "first-match-only-suppressed" });
		return false;
	}

	if (notifyMode === "transition") {
		const dedupeKey = outputDedupeKey(task);
		const hash = sha256(input.newOutputTail);
		const previous = input.dedupeHashes?.get(dedupeKey) ?? task.lastOutputDedupeByKey?.[dedupeKey];
		task.lastOutputDedupeHash = hash;
		task.lastOutputDedupeByKey = { ...(task.lastOutputDedupeByKey ?? {}), [dedupeKey]: hash };
		input.dedupeHashes?.set(dedupeKey, hash);
		if (previous === hash) {
			log?.({ ...baseDiagnostic, dedupeKey, reason: "output-transition-dedupe" });
			return false;
		}
	}

	return true;
}

export function noteOutputWakeSent(task: ManagedTask): void {
	ensureWakeState(task);
	if (normalizeNotifyMode(task.notifyMode) === "first-match-only" && task.notifyPattern) {
		task.outputPatternMatched = true;
	}
}

export interface SendTaskWakeDeps {
	isShuttingDown: () => boolean;
	logDiagnostic: (diagnostic: WakeDiagnostic) => void;
	messageType: string;
	now?: () => number;
	outputTail: (task: ManagedTask) => string;
	rememberSnapshot: (task: ManagedTask) => BackgroundTaskSnapshot;
	sendMessage: (message: Record<string, unknown>, options: Record<string, unknown>) => void;
}

export interface SendTaskWakeOptions {
	eventAt?: number;
	matchedPattern?: string;
	newOutputTail?: string;
	sequence?: number;
}

export function sendTaskWake(
	deps: SendTaskWakeDeps,
	eventType: TaskEventType,
	task: ManagedTask,
	options: SendTaskWakeOptions = {},
): boolean {
	ensureWakeState(task);
	const now = deps.now ?? Date.now;
	const pending: WakePendingRecord = {
		eventAt: options.eventAt ?? (eventType === "output" ? (task.lastOutputAt ?? now()) : (task.updatedAt ?? now())),
		eventType,
		sequence: options.sequence ?? nextWakeSequence(task),
	};

	if (isWakeVoided(task, pending.sequence)) {
		recordWakeDrop(task, pending, "voided", deps.logDiagnostic, now);
		return false;
	}
	if (deps.isShuttingDown()) {
		recordWakeDrop(task, pending, "shutting-down", deps.logDiagnostic, now);
		return false;
	}
	if (eventType === "output" && !task.notifyOnOutput) {
		recordWakeDrop(task, pending, "notify-output-disabled", deps.logDiagnostic, now);
		return false;
	}
	if (eventType === "output" && !canEmitOutputWake(task)) {
		recordWakeDrop(task, pending, "output-after-stop-suppressed", deps.logDiagnostic, now, { stopReason: task.stopReason ?? undefined });
		return false;
	}
	if (eventType === "exit" && !task.notifyOnExit) {
		recordWakeDrop(task, pending, "notify-exit-disabled", deps.logDiagnostic, now);
		return false;
	}

	if (eventType === "output") noteOutputWakeSent(task);
	const deliveredAt = now();
	const record: WakeEventRecord = {
		deliveredAt,
		eventAt: pending.eventAt,
		eventType,
		sequence: pending.sequence,
		taskStatusAtEmit: task.status,
	};
	recordWakeEvent(task, record);
	forgetPendingWake(task, pending.sequence);

	const details: BackgroundTaskEventDetails = {
		deliveredAt,
		eventAt: pending.eventAt,
		eventType,
		matchedPattern: options.matchedPattern,
		newOutputTail: options.newOutputTail,
		outputTail: deps.outputTail(task),
		sequence: pending.sequence,
		task: deps.rememberSnapshot(task),
		taskStatusAtEmit: task.status,
	};
	const headline = eventType === "exit"
		? `Background task ${task.id} finished.`
		: `Background task ${task.id} emitted new output.`;

	deps.sendMessage(
		{
			content: `${headline}\nCommand: ${task.command}`,
			customType: deps.messageType,
			details,
			display: true,
		},
		eventType === "exit" ? { deliverAs: "followUp", triggerTurn: true } : { deliverAs: "steer", triggerTurn: true },
	);
	return true;
}
