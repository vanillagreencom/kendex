import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

import { emitActivityWithPath } from "../activity/emit.ts";
import { activityPathFromStatePath, resolveActivityPath } from "../activity/paths.ts";
import type { ActivityEventInput, ActivitySeverity } from "../activity/types.ts";
import { BG_TASK_EXIT_CLASSIFIER_TAG } from "../events/bg-task-exit.ts";

export interface DaemonActivityContext {
	activityPath?: string | null;
	sessionId?: string;
}

export interface WakeEventRow {
	ts?: unknown;
	pane_id?: unknown;
	harness?: unknown;
	event_type?: unknown;
	classifier_tag?: unknown;
	hash?: unknown;
	request_id?: unknown;
	question?: unknown;
	completion?: unknown;
	task?: unknown;
	activity?: unknown;
	activity_event_type?: unknown;
	sequence?: unknown;
	details?: unknown;
	entry_id?: unknown;
	reason?: unknown;
	attempt?: unknown;
	next_retry_at?: unknown;
	error?: unknown;
	exit_code?: unknown;
	master_id?: unknown;
	pid?: unknown;
}

export function resolveDaemonActivityContext(sessionName: string): DaemonActivityContext {
	const stateFile = resolveMasterStatePath(sessionName);
	if (!stateFile || !existsSync(stateFile)) return { sessionId: sessionName };
	const activityPath = resolveActivityPath({ stateFile, sessionId: sessionName, tmuxSession: sessionName })
		?? activityPathFromStatePath(stateFile);
	return { activityPath, sessionId: sessionName };
}

export function emitDaemonStarted(ctx: DaemonActivityContext, details: { pid: number; mode: string; lifetimeMax: number }): void {
	emitDaemonActivity(ctx, {
		details: {
			dedup_key: `daemon.started:${details.pid}`,
			lifetime_max: details.lifetimeMax,
			mode: details.mode,
			pid: details.pid,
		},
		importance: "important",
		natural_key: `daemon.started:${details.pid}`,
		severity: "info",
		source: "daemon",
		summary: `flightdeck daemon started pid=${details.pid}`,
		type: "daemon.started",
	});
}

export function emitDaemonStopped(ctx: DaemonActivityContext, details: { reason: string; masterId?: string; pid: number }): void {
	emitDaemonActivity(ctx, {
		details: {
			dedup_key: `daemon_exited:${details.pid}:${details.reason}`,
			event_type: "daemon-exited",
			master_id: details.masterId ?? null,
			pid: details.pid,
			reason: details.reason,
		},
		importance: "important",
		natural_key: `daemon_exited:${details.pid}:${details.reason}`,
		pane_id: details.masterId,
		severity: daemonStoppedSeverity(details.reason),
		source: "daemon",
		summary: `flightdeck daemon stopped: ${details.reason}`,
		type: "daemon.stopped",
	});
}

export function daemonStoppedSeverity(reason: string): ActivitySeverity {
	switch (reason) {
		case "master-gone":
		case "session-gone":
		case "signal-term":
			return "warning";
		case "signal-int":
			return "info";
		default:
			return "error";
	}
}

export function emitMaxLifetimeHandoff(ctx: DaemonActivityContext, successorPid: number | null): void {
	emitDaemonActivity(ctx, {
		details: {
			dedup_key: `max-lifetime-handoff:${process.pid}:${successorPid ?? "unknown"}`,
			event_type: "max-lifetime-handoff",
			successor_pid: successorPid,
		},
		importance: "important",
		natural_key: `max-lifetime-handoff:${process.pid}:${successorPid ?? "unknown"}`,
		severity: "warning",
		source: "daemon",
		summary: successorPid ? `daemon max-lifetime handoff to pid=${successorPid}` : "daemon max-lifetime handoff started",
		type: "daemon.warning",
	});
}

export function emitSubscriberStarted(ctx: DaemonActivityContext, harness: string, paneId: string, pid: number): void {
	emitDaemonActivity(ctx, {
		details: { dedup_key: `${paneId}:subscriber.started:${pid}`, harness, pane_id: paneId, pid },
		harness,
		importance: "normal",
		natural_key: `${paneId}:subscriber.started:${pid}`,
		pane_id: paneId,
		severity: "info",
		source: "subscriber",
		summary: `${harness || "unknown"} subscriber started for ${paneId}`,
		type: "subscriber.started",
	});
}

export function emitSubscriberDead(ctx: DaemonActivityContext, harness: string, paneId: string, pid?: number): void {
	emitDaemonActivity(ctx, {
		details: { dedup_key: `${paneId}:subscriber.dead:${pid ?? "unknown"}`, harness, pane_id: paneId, pid: pid ?? null },
		harness,
		importance: "important",
		natural_key: `${paneId}:subscriber.dead:${pid ?? "unknown"}`,
		pane_id: paneId,
		severity: "warning",
		source: "subscriber",
		summary: `${harness || "unknown"} subscriber stopped for ${paneId}`,
		type: "subscriber.dead",
	});
}

export function emitSubscriberReattached(ctx: DaemonActivityContext, harness: string, paneId: string, pid: number): void {
	emitDaemonActivity(ctx, {
		details: { dedup_key: `${paneId}:subscriber-reattach:${pid}`, event_type: "subscriber-reattach", harness, pane_id: paneId, pid },
		harness,
		importance: "important",
		natural_key: `${paneId}:subscriber-reattach:${pid}`,
		pane_id: paneId,
		severity: "warning",
		source: "daemon",
		summary: `${harness || "unknown"} subscriber reattached for ${paneId}`,
		type: "daemon.warning",
	});
}

export function emitWakeDeliveryFailure(ctx: DaemonActivityContext | undefined, details: { kind?: string; reason: string; targetMasterPid?: string | number | null }): void {
	if (!ctx) return;
	emitDaemonActivity(ctx, {
		details: {
			dedup_key: `wake-delivery-failed:${details.reason}:${details.targetMasterPid ?? "unknown"}`,
			kind: details.kind ?? "wake-delivery-failed",
			reason: details.reason,
			target_master_pid: details.targetMasterPid ?? null,
		},
		importance: "important",
		natural_key: `wake-delivery-failed:${details.reason}:${details.targetMasterPid ?? "unknown"}`,
		severity: "error",
		source: "daemon",
		summary: `wake delivery failed: ${details.reason}`,
		type: "daemon.error",
	});
}

export function emitActivityForWakeRow(ctx: DaemonActivityContext, row: WakeEventRow): number {
	const inputs = activityInputsForWakeRow(row);
	for (const input of inputs) emitDaemonActivity(ctx, input);
	return inputs.length;
}

export function activityInputsForWakeRow(row: WakeEventRow): ActivityEventInput[] {
	const tag = str(row.classifier_tag) || str(row.event_type) || "";
	if (tag === "oc-question" || tag === "pi-question") return [questionActivity(row, tag)];
	if (tag === "pi-subagent-completion" || tag === "pi-subagent-completion-ok") return subagentActivities(row);
	if (tag === BG_TASK_EXIT_CLASSIFIER_TAG || tag === "pi-bg-task-activity") return bgTaskActivities(row);
	if (tag === "pi-activity-broker") return brokerActivities(row);
	if (tag.startsWith("pi-rate-limit-")) return rateLimitActivities(row, tag);
	if (tag === "domain-mismatch") return [domainMismatchActivity(row)];
	if (tag === "daemon-exited") return [daemonExitedActivity(row)];
	if (isPromptTag(tag)) return [promptActivity(row, tag)];
	return [];
}

function emitDaemonActivity(ctx: DaemonActivityContext, event: ActivityEventInput): void {
	emitActivityWithPath(ctx.activityPath, event, { nonblocking: true, sessionId: ctx.sessionId });
}

function questionActivity(row: WakeEventRow, tag: string): ActivityEventInput {
	const paneId = str(row.pane_id);
	const questionId = str(row.request_id) || str((record(row.question)?.requestId)) || str((record(row.question)?.id));
	const dedup = `${paneId}:question.opened:${questionId || str(row.hash) || str(row.ts) || tag}`;
	return {
		details: { dedup_key: dedup, event_type: str(row.event_type) || tag, question: row.question ?? null, request_id: questionId || null },
		harness: str(row.harness),
		importance: "important",
		natural_key: dedup,
		pane_id: paneId,
		refs: questionId ? { question_id: questionId } : undefined,
		severity: "warning",
		source: "subscriber",
		summary: questionId ? `question opened: ${questionId}` : `question opened on ${paneId || "pane"}`,
		ts: str(row.ts),
		type: "question.opened",
	};
}

function subagentActivities(row: WakeEventRow): ActivityEventInput[] {
	const paneId = str(row.pane_id);
	const root = record(row.completion);
	const completions = Array.isArray(root?.completions) ? root.completions : [];
	const items = completions.length > 0 ? completions : [root ?? {}];
	return items.map((item, index) => {
		const completion = record(item) ?? {};
		const taskId = firstString(completion.taskId, completion.task_id, completion.id, record(completion.task)?.id) || `${str(row.hash) || "completion"}-${index}`;
		const status = normalizeSubagentStatus(firstString(completion.status, completion.outcome) || "completed");
		const type = subagentActivityType(status);
		const dedup = `${paneId}:${type}:${taskId}`;
		return {
			details: { ...completion, dedup_key: dedup, event_type: str(row.event_type) || "subagent-completion", status },
			harness: str(row.harness),
			importance: subagentImportance(status),
			natural_key: dedup,
			pane_id: paneId,
			refs: { task_id: taskId },
			severity: subagentSeverity(status),
			source: "subscriber",
			summary: `subagent ${taskId} ${subagentSummaryVerb(status)}`,
			ts: str(row.ts),
			type,
		};
	});
}

function brokerActivities(row: WakeEventRow): ActivityEventInput[] {
	const activity = record(row.activity);
	if (!activity) return [];
	const type = str(activity.type);
	const source = str(activity.source);
	const summary = str(activity.summary);
	if (!type || !source || !summary) return [];
	const paneId = str(row.pane_id);
	const details = record(activity.details) ?? {};
	const refs = record(activity.refs) ?? {};
	const dedupKey = brokerDedupKey({ activity, details, paneId, refs, row, summary, type });
	return [{
		body: str(activity.body),
		details: {
			...details,
			broker_hash: str(row.hash) ?? null,
			dedup_key: dedupKey,
			event_type: "vstack_activity",
		},
		entry_id: str(row.entry_id) ?? str(activity.entry_id),
		harness: str(row.harness) || "pi",
		importance: str(activity.importance),
		natural_key: dedupKey,
		pane_id: paneId,
		refs: Object.keys(refs).length > 0 ? refs : undefined,
		severity: str(activity.severity),
		source,
		summary,
		ts: str(activity.ts) ?? str(row.ts),
		type,
	}];
}

function brokerDedupKey(args: {
	activity: Record<string, unknown>;
	details: Record<string, unknown>;
	paneId?: string;
	refs: Record<string, unknown>;
	row: WakeEventRow;
	summary: string;
	type: string;
}): string {
	const paneKey = args.paneId || "pane";
	const bgTaskId = firstString(args.refs.bg_task_id);
	if (bgTaskId) {
		const sequence = firstString(args.details.sequence, args.row.sequence) ?? "0";
		return `${paneKey}:${args.type}:${bgTaskId}:${sequence}`;
	}
	const taskId = firstString(args.refs.task_id);
	if (taskId) return `${paneKey}:${args.type}:${taskId}`;
	const questionId = firstString(args.refs.question_id);
	if (questionId) return `${paneKey}:${args.type}:${questionId}`;
	const fallback = firstString(args.row.hash, args.activity.ts, args.row.ts) ?? args.summary;
	return `${paneKey}:${args.type}:${fallback}`;
}

function bgTaskActivities(row: WakeEventRow): ActivityEventInput[] {
	const paneId = str(row.pane_id);
	const task = record(row.task) ?? record(record(row.details)?.task) ?? {};
	const taskId = firstString(task.id, task.taskId, task.task_id) || str(row.hash) || "bg-task";
	const activityKind = firstString(row.activity_event_type, record(row.details)?.eventType, record(row.details)?.event_type, row.event_type) || "bg-task-exit";
	const status = normalizeBgStatus(firstString(task.status, activityKind) || "completed", activityKind);
	const type = bgTaskActivityType(status, activityKind);
	const sequence = firstString(row.sequence, task.sequence, record(row.details)?.sequence, task.updatedAt) ?? str(row.hash) ?? "0";
	const dedup = `${taskId}:${sequence}`;
	return [{
		details: {
			command: str(task.command) || null,
			dedup_key: `${paneId}:${type}:${dedup}`,
			event_type: activityKind,
			exit_code: typeof task.exitCode === "number" ? task.exitCode : null,
			output_bytes: typeof task.outputBytes === "number" ? task.outputBytes : null,
			status,
			task,
		},
		harness: str(row.harness),
		importance: bgTaskImportance(type),
		natural_key: `${paneId}:${type}:${dedup}`,
		pane_id: paneId,
		refs: { bg_task_id: taskId },
		severity: bgTaskSeverity(type),
		source: "pi-bg-task",
		summary: `background task ${taskId} ${bgTaskSummaryVerb(type)}`,
		ts: str(row.ts),
		type,
	}];
}

function rateLimitActivities(row: WakeEventRow, tag: string): ActivityEventInput[] {
	const paneId = str(row.pane_id);
	const reason = str(row.reason);
	const hash = str(row.hash) || str(row.ts) || Date.now().toString();
	const attempt = typeof row.attempt === "number" ? row.attempt : undefined;
	const nextRetryAt = typeof row.next_retry_at === "number" ? row.next_retry_at : undefined;
	const error = str(row.error);
	const exitCode = typeof row.exit_code === "number" ? row.exit_code : undefined;
	const baseDetails = {
		event_type: str(row.event_type) || tag,
		hash,
		...(attempt !== undefined ? { attempt } : {}),
		...(nextRetryAt !== undefined ? { next_retry_at: nextRetryAt } : {}),
		...(reason ? { reason } : {}),
		...(error ? { error } : {}),
		...(exitCode !== undefined ? { exit_code: exitCode } : {}),
	};
	const common = {
		harness: str(row.harness) || "pi",
		pane_id: paneId,
		source: "subscriber" as const,
		ts: str(row.ts),
	};

	if (tag === "pi-rate-limit-skipped") {
		const skipReason = reason || "unknown";
		const dedup = `${paneId}:rate_limit_skipped:${skipReason}:${hash}`;
		return [{
			...common,
			details: { ...baseDetails, dedup_key: dedup, reason: skipReason },
			importance: "noisy",
			natural_key: dedup,
			severity: "debug",
			summary: `rate-limit skipped: ${skipReason}`,
			type: "agent.rate_limit_skipped",
		}];
	}

	if (tag === "pi-rate-limit-retry") {
		const dedup = `${paneId}:rate_limit_retry:${attempt ?? "unknown"}:${hash}`;
		return [{
			...common,
			details: { ...baseDetails, dedup_key: dedup },
			importance: "important",
			natural_key: dedup,
			severity: "info",
			summary: attempt !== undefined ? `rate-limit retry scheduled: attempt ${attempt}` : "rate-limit retry scheduled",
			type: "agent.rate_limit_retry",
		}];
	}

	if (tag === "pi-rate-limit-resolved") {
		const dedup = `${paneId}:rate_limit_resolved:${attempt ?? "unknown"}:${hash}`;
		return [{
			...common,
			details: { ...baseDetails, dedup_key: dedup },
			importance: "normal",
			natural_key: dedup,
			severity: "success",
			summary: attempt !== undefined ? `rate-limit resolved after attempt ${attempt}` : "rate-limit resolved",
			type: "agent.rate_limit_resolved",
		}];
	}

	if (tag === "pi-rate-limit-exhausted") {
		const dedup = `${paneId}:rate_limit_exhausted:${attempt ?? "unknown"}:${hash}`;
		return [{
			...common,
			details: { ...baseDetails, dedup_key: dedup },
			importance: "important",
			natural_key: dedup,
			severity: "error",
			summary: attempt !== undefined ? `rate-limit exhausted after attempt ${attempt}` : "rate-limit exhausted",
			type: "agent.rate_limit_exhausted",
		}];
	}

	if (tag === "pi-rate-limit-decider-error") {
		const eventType = str(row.event_type) || "rate_limit_decider_error";
		const dedup = `${paneId}:${eventType}:${reason || exitCode || hash}:${hash}`;
		const summary = eventType === "rate_limit_decider_unavailable"
			? `rate-limit decider unavailable: ${reason || "unknown"}`
			: reason ? `rate-limit decider error: ${reason}` : "rate-limit decider error";
		return [{
			...common,
			details: { ...baseDetails, dedup_key: dedup },
			importance: "important",
			natural_key: dedup,
			severity: "warning",
			summary,
			type: "daemon.warning",
		}];
	}

	return [];
}

function domainMismatchActivity(row: WakeEventRow): ActivityEventInput {
	const paneId = str(row.pane_id);
	const dedup = `${paneId}:domain-mismatch:${str(row.ts) || str(row.hash) || Date.now()}`;
	return {
		details: { dedup_key: dedup, event_type: "domain-mismatch", hash: str(row.hash) || null },
		importance: "important",
		natural_key: dedup,
		pane_id: paneId,
		severity: "warning",
		source: "daemon",
		summary: `domain mismatch from ${paneId || "pane"}`,
		ts: str(row.ts),
		type: "daemon.warning",
	};
}

function daemonExitedActivity(row: WakeEventRow): ActivityEventInput {
	const reason = str(row.reason) || firstString(record(row.details)?.reason) || "other";
	const pid = typeof row.pid === "number" ? row.pid : process.pid;
	const masterId = str(row.master_id) || str(row.pane_id);
	return {
		details: { dedup_key: `daemon_exited:${pid}:${reason}`, event_type: "daemon-exited", master_id: masterId || null, pid, reason },
		importance: "important",
		natural_key: `daemon_exited:${pid}:${reason}`,
		pane_id: masterId,
		severity: daemonStoppedSeverity(reason),
		source: "daemon",
		summary: `flightdeck daemon stopped: ${reason}`,
		ts: str(row.ts),
		type: "daemon.stopped",
	};
}

function promptActivity(row: WakeEventRow, tag: string): ActivityEventInput {
	const paneId = str(row.pane_id);
	const dedup = `${paneId}:${tag}:${str(row.hash) || str(row.ts) || Date.now()}`;
	return {
		details: { dedup_key: dedup, event_type: tag, hash: str(row.hash) || null },
		importance: "important",
		natural_key: dedup,
		pane_id: paneId,
		severity: "warning",
		source: "daemon",
		summary: `pane needs attention: ${tag}`,
		ts: str(row.ts),
		type: "question.opened",
	};
}

function resolveMasterStatePath(sessionName: string): string | null {
	const top = spawnSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" });
	if (top.status !== 0 || !top.stdout.trim()) return null;
	let root = top.stdout.trim();
	const common = spawnSync("git", ["-C", root, "rev-parse", "--git-common-dir"], { encoding: "utf8" });
	const gitCommonDir = common.stdout.trim();
	if (gitCommonDir && gitCommonDir !== ".git") {
		root = resolve(root, gitCommonDir, "..");
	}
	const stateDir = process.env.FLIGHTDECK_STATE_DIR?.trim() || "tmp";
	return resolve(root, stateDir, `flightdeck-state-${sessionName}.json`);
}

function subagentActivityType(status: string): string {
	switch (status) {
		case "failed": return "agent.task_failed";
		case "blocked": return "agent.task_blocked";
		case "needs_completion": return "agent.needs_completion";
		case "empty_after_compact": return "agent.empty_after_compact";
		default: return "agent.task_completed";
	}
}

function normalizeSubagentStatus(status: string): string {
	const normalized = status.trim().toLowerCase().replace(/-/g, "_");
	if (normalized === "success" || normalized === "succeeded" || normalized === "complete") return "completed";
	if (normalized === "compact_then_empty" || normalized === "empty_after_compact") return "empty_after_compact";
	if (["failed", "blocked", "needs_completion", "completed"].includes(normalized)) return normalized;
	return "completed";
}

function subagentSeverity(status: string): ActivitySeverity {
	if (status === "failed") return "error";
	if (status === "completed") return "success";
	return "warning";
}

function subagentImportance(status: string): "important" | "normal" {
	return status === "completed" ? "normal" : "important";
}

function subagentSummaryVerb(status: string): string {
	switch (status) {
		case "failed": return "failed";
		case "blocked": return "blocked";
		case "needs_completion": return "needs completion";
		case "empty_after_compact": return "empty after compact";
		default: return "completed";
	}
}

function normalizeBgStatus(status: string, activityKind: string): string {
	const normalized = status.trim().toLowerCase().replace(/-/g, "_");
	const kind = activityKind.trim().toLowerCase().replace(/-/g, "_");
	if (kind === "output" || kind.includes("output_matched")) return "output_matched";
	if (kind.includes("started")) return "started";
	if (normalized === "success" || normalized === "complete") return "completed";
	if (normalized === "timeout") return "timed_out";
	return normalized || "completed";
}

function bgTaskActivityType(status: string, activityKind: string): string {
	const kind = activityKind.trim().toLowerCase().replace(/-/g, "_");
	if (status === "output_matched" || kind === "output" || kind.includes("output_matched")) return "bg_task.output_matched";
	if (status === "started" || status === "running") return "bg_task.started";
	if (status === "timed_out") return "bg_task.timed_out";
	if (status === "failed" || status === "error") return "bg_task.failed";
	if (status === "stopped" || status === "cancelled") return "bg_task.stopped";
	return "bg_task.completed";
}

function bgTaskSeverity(type: string): ActivitySeverity {
	if (type === "bg_task.failed" || type === "bg_task.timed_out") return "error";
	if (type === "bg_task.completed") return "success";
	if (type === "bg_task.stopped") return "warning";
	return "info";
}

function bgTaskImportance(type: string): "important" | "normal" | "noisy" {
	if (type === "bg_task.completed") return "normal";
	if (type === "bg_task.output_matched" || type === "bg_task.started") return "noisy";
	return "important";
}

function bgTaskSummaryVerb(type: string): string {
	switch (type) {
		case "bg_task.failed": return "failed";
		case "bg_task.timed_out": return "timed out";
		case "bg_task.stopped": return "stopped";
		case "bg_task.output_matched": return "matched output";
		case "bg_task.started": return "started";
		default: return "completed";
	}
}

function isPromptTag(tag: string): boolean {
	return tag.endsWith("prompt")
		|| tag.includes("multi-choice")
		|| tag === "awaiting-direction"
		|| tag === "modal-prompt";
}

function record(value: unknown): Record<string, unknown> | null {
	return !!value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function str(value: unknown): string | undefined {
	return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function firstString(...values: unknown[]): string | undefined {
	for (const value of values) {
		if (typeof value === "string" && value.trim()) return value.trim();
		if (typeof value === "number" && Number.isFinite(value)) return String(value);
	}
	return undefined;
}
