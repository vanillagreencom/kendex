import type { CwdSnapshot } from "./types.js";

export type PiActivitySeverity = "debug" | "info" | "success" | "warning" | "error";
export type PiActivityImportance = "critical" | "important" | "normal" | "noisy";

export interface PiActivityEvent {
	type: string;
	source: "pi-agents";
	severity: PiActivitySeverity;
	importance: PiActivityImportance;
	summary: string;
	body?: string;
	refs?: { task_id?: string; agent?: string };
	details?: Record<string, unknown>;
	ts?: string;
}

interface PiActivityBroker {
	publish(event: PiActivityEvent): void;
}

const ACTIVITY_BROKER_SYMBOL = Symbol.for("vstack.pi.activity");

export function publishSubagentActivity(eventName: string, payload: Record<string, unknown>): void {
	try {
		const broker = activityBroker();
		if (!broker) return;
		const event = buildSubagentActivity(eventName, payload);
		if (event) broker.publish(event);
	} catch {
		// Activity publication is best-effort and must never affect subagent control flow.
	}
}

export function buildSubagentActivity(eventName: string, payload: Record<string, unknown>): PiActivityEvent | null {
	const agent = stringValue(payload.agent);
	const taskId = stringValue(payload.taskId);
	const status = stringValue(payload.status);
	const reason = stringValue(payload.reason);
	const mappedType = activityType(eventName, status, reason);
	if (!mappedType) return null;
	const summary = summaryFor(mappedType, agent, taskId, payload);
	return {
		details: detailsFor(mappedType, eventName, payload),
		importance: importanceFor(mappedType),
		refs: {
			...(taskId ? { task_id: taskId } : {}),
			...(agent ? { agent } : {}),
		},
		severity: severityFor(mappedType),
		source: "pi-agents",
		summary,
		type: mappedType,
	};
}

function activityBroker(): PiActivityBroker | undefined {
	const broker = (globalThis as unknown as Record<PropertyKey, unknown>)[ACTIVITY_BROKER_SYMBOL];
	return broker && typeof broker === "object" && typeof (broker as PiActivityBroker).publish === "function"
		? broker as PiActivityBroker
		: undefined;
}

function activityType(eventName: string, status?: string, reason?: string): string | null {
	if (eventName === "subagents:created") return "agent.spawned";
	if (eventName === "subagents:queued") return "agent.task_queued";
	if (eventName === "subagents:started") return "agent.task_started";
	if (eventName === "subagents:steered") return "agent.steered";
	if (eventName === "subagents:needs_completion" && reason === "compact-then-empty") return "agent.empty_after_compact";
	if (eventName === "subagents:needs_completion") return "agent.needs_completion";
	if (reason === "pane-cwd-stale") return "agent.pane_cwd_stale";
	if (eventName === "subagents:rate_limited") return "agent.rate_limited";
	if (eventName === "subagents:rate_limit_retry") return "agent.rate_limit_retry";
	if (eventName === "subagents:rate_limit_resolved") return "agent.rate_limit_resolved";
	if (eventName === "subagents:rate_limit_exhausted") return "agent.rate_limit_exhausted";
	if (eventName === "subagents:completed" || status === "completed") return "agent.task_completed";
	if (status === "blocked") return "agent.task_blocked";
	if (eventName === "subagents:failed" || status === "failed" || status === "aborted") return "agent.task_failed";
	return null;
}

function severityFor(type: string): PiActivitySeverity {
	if (type === "agent.task_completed" || type === "agent.rate_limit_resolved") return "success";
	if (type === "agent.task_failed" || type === "agent.pane_cwd_stale" || type === "agent.rate_limit_exhausted") return "error";
	if (
		type === "agent.spawned"
		|| type === "agent.task_started"
		|| type === "agent.task_queued"
		|| type === "agent.steered"
		|| type === "agent.rate_limit_retry"
	) return "info";
	return "warning";
}

function importanceFor(type: string): PiActivityImportance {
	if (
		type === "agent.task_completed"
		|| type === "agent.task_started"
		|| type === "agent.task_queued"
		|| type === "agent.rate_limit_resolved"
	) return "normal";
	if (type === "agent.spawned" || type === "agent.steered") return "noisy";
	return "important";
}

function summaryFor(type: string, agent?: string, taskId?: string, payload: Record<string, unknown> = {}): string {
	const who = agent || "agent";
	const suffix = taskId ? ` ${taskId}` : "";
	const payloadSummary = stringValue(payload.summary);
	switch (type) {
		case "agent.spawned": return `${who} pane spawned`;
		case "agent.task_queued": return `${who} task${suffix} queued`;
		case "agent.task_started": return `${who} task${suffix} started`;
		case "agent.task_completed": return payloadSummary || `${who} task${suffix} completed`;
		case "agent.task_failed": return payloadSummary || `${who} task${suffix} failed`;
		case "agent.task_blocked": return payloadSummary || `${who} task${suffix} blocked`;
		case "agent.pane_cwd_stale": return payloadSummary || `${who} pane cwd stale`;
		case "agent.needs_completion": return payloadSummary || `${who} task${suffix} needs completion`;
		case "agent.empty_after_compact": return payloadSummary || `${who} task${suffix} empty after compact`;
		case "agent.steered": return `${who} task${suffix} steered`;
		case "agent.rate_limited": return payloadSummary || `${who} rate-limited`;
		case "agent.rate_limit_retry": return payloadSummary || `${who} rate-limit retry`;
		case "agent.rate_limit_resolved": return payloadSummary || `${who} rate-limit resolved`;
		case "agent.rate_limit_exhausted": return payloadSummary || `${who} rate-limit exhausted`;
		default: return payloadSummary || `${who} activity`;
	}
}

function detailsFor(type: string, eventName: string, payload: Record<string, unknown>): Record<string, unknown> {
	const details: Record<string, unknown> = {
		event_name: eventName,
		mode: payload.mode,
		pane_id: payload.paneId,
		reason: payload.reason,
		status: payload.status,
	};
	for (const key of ["runtimeRoot", "transcriptPath", "completionPath", "sessionFile", "sessionKey", "sessionMode", "model", "effort", "error", "cwdPid", "expectedCwd", "actualCwd", "actualCwdRaw", "cwdReason"] as const) {
		if (payload[key] !== undefined) details[key] = payload[key];
	}
	if (type === "agent.empty_after_compact") {
		const cwdSnapshot = cwdSnapshotDetails(payload.cwdSnapshot);
		if (cwdSnapshot) details.cwdSnapshot = cwdSnapshot;
	}
	return details;
}

function cwdSnapshotDetails(value: unknown): Pick<CwdSnapshot, "cwd" | "head" | "dirty" | "status" | "lastCommit"> | undefined {
	if (!value || typeof value !== "object") return undefined;
	const record = value as Partial<CwdSnapshot>;
	return {
		cwd: typeof record.cwd === "string" ? record.cwd : "",
		dirty: record.dirty === true,
		head: typeof record.head === "string" ? record.head : "",
		lastCommit: { subject: typeof record.lastCommit?.subject === "string" ? record.lastCommit.subject : "" },
		status: typeof record.status === "string" ? record.status : "",
	};
}

function stringValue(value: unknown): string | undefined {
	return typeof value === "string" && value.trim() ? value.trim() : undefined;
}
