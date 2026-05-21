import { stableSnapshotFingerprint } from "./persistence.js";
import type { BackgroundTaskSnapshot } from "./types.js";

// `bg_task list` / `bg_status list` tool-result details land in Pi's
// append-only session JSONL independently of custom persistence entries. Large
// fleets must therefore use a tiny manifest while sidecar state remains
// canonical for restore. Acceptance target for bounded details is <=4 KiB.
export const BG_TOOL_RESULT_MAX_DETAILS_BYTES = 64 * 1024;
export const BG_TOOL_RESULT_MAX_TASKS = 50;
const BG_TOOL_RESULT_SAMPLE_LIMIT = 20;

export interface BgToolResultBoundedTasks {
	version: 2;
	fullSnapshot: false;
	reason: "payload-too-large" | "task-count-threshold";
	byteSize: number;
	fingerprint: string;
	counts: { tasks: number };
	taskIds: string[];
	omitted: { tasks: number };
	thresholds: { maxBytes: number; maxTasks: number };
	updatedAt: number;
}

export function isBgToolResultBoundedTasks(value: unknown): value is BgToolResultBoundedTasks {
	if (!value || typeof value !== "object") return false;
	const candidate = value as Partial<BgToolResultBoundedTasks>;
	return candidate.version === 2 && candidate.fullSnapshot === false;
}

export function bgToolResultTasks(
	tasks: BackgroundTaskSnapshot[],
	options: { maxBytes?: number; maxTasks?: number; sampleLimit?: number } = {},
): BackgroundTaskSnapshot[] | BgToolResultBoundedTasks {
	const maxBytes = options.maxBytes ?? BG_TOOL_RESULT_MAX_DETAILS_BYTES;
	const maxTasks = options.maxTasks ?? BG_TOOL_RESULT_MAX_TASKS;
	const sampleLimit = options.sampleLimit ?? BG_TOOL_RESULT_SAMPLE_LIMIT;
	const serialized = JSON.stringify(tasks);
	const byteSize = Buffer.byteLength(serialized, "utf8");
	if (tasks.length <= maxTasks && byteSize <= maxBytes) return tasks;
	const taskIds = tasks.slice(0, sampleLimit).map((task) => task.id);
	return {
		version: 2,
		fullSnapshot: false,
		reason: byteSize > maxBytes ? "payload-too-large" : "task-count-threshold",
		byteSize,
		fingerprint: stableSnapshotFingerprint({ tasks }),
		counts: { tasks: tasks.length },
		taskIds,
		omitted: { tasks: Math.max(0, tasks.length - taskIds.length) },
		thresholds: { maxBytes, maxTasks },
		updatedAt: tasks.reduce((latest, task) => Math.max(latest, task.updatedAt), 0),
	};
}

export interface ApplyBgToolResultTasksArgs<T> {
	apply: (snapshot: T) => void;
	clear: () => void;
	detailsTasks: unknown;
	sidecarLoaded: boolean;
	sidecarTasks: T[] | undefined;
}

export function applyBgToolResultTasksWithBarrier<T>(args: ApplyBgToolResultTasksArgs<T>): void {
	if (isBgToolResultBoundedTasks(args.detailsTasks)) {
		if (args.sidecarLoaded && args.sidecarTasks) {
			args.clear();
			for (const snapshot of args.sidecarTasks) args.apply(snapshot);
		}
		return;
	}
	if (Array.isArray(args.detailsTasks)) for (const snapshot of args.detailsTasks) args.apply(snapshot as T);
}
