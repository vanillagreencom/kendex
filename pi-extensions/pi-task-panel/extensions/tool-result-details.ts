import { createHash } from "node:crypto";

// Tool-result details are written into Pi's session JSONL. Keep large task
// panels out of that append-only stream; the sidecar remains canonical for
// restore. Acceptance target for bounded details is <=4 KiB, so summaries keep
// counts plus a small id sample rather than every task body/note.
export const TASK_PANEL_TOOL_RESULT_MAX_STATE_BYTES = 64 * 1024;
export const TASK_PANEL_TOOL_RESULT_MAX_TASKS = 100;
const TASK_PANEL_TOOL_RESULT_SAMPLE_LIMIT = 20;

export interface TaskPanelToolResultTaskLike {
	id: string;
}

export interface TaskPanelToolResultPhaseLike {
	id: string;
}

export interface TaskPanelToolResultStateLike {
	phases: TaskPanelToolResultPhaseLike[];
	tasks: TaskPanelToolResultTaskLike[];
	updatedAt: string;
}

export interface TaskPanelToolResultBoundedState {
	version: 2;
	fullSnapshot: false;
	reason: "payload-too-large" | "task-count-threshold";
	byteSize: number;
	fingerprint: string;
	counts: { tasks: number; phases: number };
	taskIds: string[];
	phaseIds: string[];
	omitted: { tasks: number; phases: number };
	thresholds: { maxBytes: number; maxTasks: number };
	updatedAt: string;
}

export function isTaskPanelToolResultBoundedState(value: unknown): value is TaskPanelToolResultBoundedState {
	if (!value || typeof value !== "object") return false;
	const candidate = value as Partial<TaskPanelToolResultBoundedState>;
	return candidate.version === 2 && candidate.fullSnapshot === false;
}

function stableValue(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(stableValue);
	if (!value || typeof value !== "object") return value;
	const sorted: Record<string, unknown> = {};
	for (const key of Object.keys(value as Record<string, unknown>).sort()) sorted[key] = stableValue((value as Record<string, unknown>)[key]);
	return sorted;
}

function fingerprint(value: unknown): string {
	const { updatedAt: _ignored, ...rest } = value as Record<string, unknown>;
	return createHash("sha256").update(JSON.stringify(stableValue(rest))).digest("hex");
}

function sampleIds(items: Array<{ id: string }>, limit: number): string[] {
	return items.slice(0, limit).map((item) => item.id);
}

export function taskPanelToolResultState<T extends TaskPanelToolResultStateLike>(
	state: T,
	options: { forceFullSnapshot?: boolean; maxBytes?: number; maxTasks?: number; sampleLimit?: number } = {},
): T | TaskPanelToolResultBoundedState {
	const maxBytes = options.maxBytes ?? TASK_PANEL_TOOL_RESULT_MAX_STATE_BYTES;
	const maxTasks = options.maxTasks ?? TASK_PANEL_TOOL_RESULT_MAX_TASKS;
	const sampleLimit = options.sampleLimit ?? TASK_PANEL_TOOL_RESULT_SAMPLE_LIMIT;
	const serialized = JSON.stringify(state);
	const byteSize = Buffer.byteLength(serialized, "utf8");
	if (options.forceFullSnapshot || (state.tasks.length <= maxTasks && byteSize <= maxBytes)) return JSON.parse(serialized) as T;
	const taskIds = sampleIds(state.tasks, sampleLimit);
	const phaseIds = sampleIds(state.phases, Math.min(sampleLimit, 10));
	return {
		version: 2,
		fullSnapshot: false,
		reason: byteSize > maxBytes ? "payload-too-large" : "task-count-threshold",
		byteSize,
		fingerprint: fingerprint(state),
		counts: { tasks: state.tasks.length, phases: state.phases.length },
		taskIds,
		phaseIds,
		omitted: { tasks: Math.max(0, state.tasks.length - taskIds.length), phases: Math.max(0, state.phases.length - phaseIds.length) },
		thresholds: { maxBytes, maxTasks },
		updatedAt: state.updatedAt,
	};
}

export interface ApplyTaskPanelToolResultRestoreArgs<T> {
	currentState: T;
	detailsState: unknown;
	hasStateContent: (state: T) => boolean;
	normalizeState: (value: unknown) => T;
	sidecarState: T | undefined;
}

export function applyTaskPanelToolResultRestore<T>(args: ApplyTaskPanelToolResultRestoreArgs<T>): T {
	if (isTaskPanelToolResultBoundedState(args.detailsState)) return args.sidecarState ?? args.currentState;
	const restored = args.normalizeState(args.detailsState);
	return args.hasStateContent(restored) ? restored : args.currentState;
}
