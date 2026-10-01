import { ICONS, type PaneTaskStatus, type SingleResult } from "./types.js";

/** Normalize legacy cancellation and the dashboard's waiting state at one boundary. */
export function normalizePaneTaskStatus(status: unknown): PaneTaskStatus {
	switch (status) {
		case "aborted":
		case "cancelled": return "stopped";
		case "waiting": return "queued";
		case "queued": case "running": case "completed": case "blocked": case "failed":
		case "stopped": case "refused": case "needs_completion": case "unknown": return status;
		default: return "unknown";
	}
}

/** Recoverable ends a turn but permits a later real completion to replace it. */
interface TaskStatus {
	phase: "working" | "unresolved" | "recoverable" | "terminal";
	tone: "success" | "warning" | "error";
	icon: string;
	label: string;
	rank: number;
	activity: "agent.task_completed" | "agent.task_failed" | "agent.task_blocked" | "agent.needs_completion" | null;
	isError: boolean;
	diagnostic?: true;
	animate?: true;
}

/** The exhaustive owner of lifecycle, presentation and completion activity decisions. */
export function taskStatus(value: unknown): TaskStatus {
	const status = normalizePaneTaskStatus(value);
	switch (status) {
		case "queued": return { phase: "working", tone: "warning", icon: ICONS.clock, label: "queued", rank: 0, activity: null, isError: false };
		case "running": return { phase: "working", tone: "warning", icon: ICONS.cog, animate: true, label: "working", rank: 0, activity: null, isError: false };
		case "unknown": return { phase: "unresolved", tone: "warning", icon: ICONS.warning, label: "stale", rank: 1, activity: null, isError: false };
		case "needs_completion": return { phase: "recoverable", tone: "warning", icon: ICONS.warning, label: "needs completion", rank: 1, activity: "agent.needs_completion", isError: false };
		case "completed": return { phase: "terminal", tone: "success", icon: ICONS.check, label: "completed", rank: 2, activity: "agent.task_completed", isError: false };
		case "blocked": return { phase: "terminal", tone: "warning", icon: ICONS.times, label: "blocked", rank: 1, activity: "agent.task_blocked", isError: true };
		case "failed": return { phase: "terminal", tone: "error", icon: ICONS.times, label: "failed", diagnostic: true, rank: 1, activity: "agent.task_failed", isError: true };
		case "refused": return { phase: "terminal", tone: "warning", icon: ICONS.warning, label: "refused", diagnostic: true, rank: 1, activity: null, isError: true };
		case "stopped": return { phase: "terminal", tone: "warning", icon: ICONS.warning, label: "stopped", diagnostic: true, rank: 3, activity: null, isError: true };
		default: { const unreachable: never = status; throw new Error(`Unknown task status: ${unreachable}`); }
	}
}

/** An irreversible outcome, unlike recoverable needs_completion. */
export function isTerminalTaskStatus(status: unknown): boolean {
	return taskStatus(status).phase === "terminal";
}

/** No live execution remains, including a turn awaiting its completion record. */
export function isTaskTurnFinished(status: unknown): boolean {
	const phase = taskStatus(status).phase;
	return phase === "terminal" || phase === "recoverable";
}

/** Active includes unknown records that a watchdog must still inspect. */
export function isTaskActive(status: unknown): boolean {
	return !isTaskTurnFinished(status);
}

/** A refusal ran no child; provider errors can end with process exit zero. */
export function singleResultStatus(result: SingleResult): PaneTaskStatus {
	if (result.refused) return "refused";
	if (normalizePaneTaskStatus(result.status) === "stopped" || result.stopReason === "aborted") return "stopped";
	if (result.status === "needs_completion") return "needs_completion";
	if (result.exitCode === -1) return "running";
	if (result.stopReason === "error") return "failed";
	return result.exitCode === 0 ? "completed" : "failed";
}

/** Whether the caller must handle an unsuccessful dispatch. */
export function singleResultIsError(result: SingleResult): boolean {
	return taskStatus(singleResultStatus(result)).isError;
}
