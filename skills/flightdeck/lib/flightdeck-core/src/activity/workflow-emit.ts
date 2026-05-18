import { readFileSync } from "node:fs";
import { emitActivityWithPath } from "./emit.ts";
import { resolveActivityPath } from "./paths.ts";
import type { ActivityEventInput, ActivityImportance, ActivityRefs, ActivitySeverity } from "./types.ts";

export interface WorkflowEmitContext {
	stateFile?: string;
	sessionId?: string;
	tmuxSession?: string;
	stateDir?: string;
	activityPath?: string;
	entry?: Record<string, unknown> | null;
	entryId?: string;
	entryTitle?: string;
	entryKind?: string;
	paneId?: string;
	harness?: string;
	refs?: ActivityRefs;
}

export interface WorkflowDecisionOptions {
	answer?: string;
	details?: Record<string, unknown>;
	importance?: ActivityImportance;
	refs?: ActivityRefs;
	sequence?: number;
	severity?: ActivitySeverity;
	summary?: string;
}

export interface WorkflowCloseIssueOptions {
	details?: Record<string, unknown>;
	severity?: ActivitySeverity;
	summary?: string;
}

export type MergeActionKind = "queued" | "merged" | "blocked" | "pr.merge_queued" | "pr.merged" | "pr.merge_blocked";
export type CloseIssueOutcome = "complete" | "completed" | "merged" | "cancelled" | "canceled" | "dead" | "aborted";
export interface MergeActionDetails extends Record<string, unknown> {
	commit?: string;
	reason?: string;
	transient?: boolean;
}

export function emitSessionStarted(ctx: WorkflowEmitContext): void {
	emitWorkflowActivity(ctx, {
		details: { dedup_key: `${workflowSessionId(ctx)}:session.started` },
		importance: "important",
		severity: "info",
		summary: `Flightdeck session started: ${workflowSessionId(ctx)}`,
		type: "session.started",
	});
}

export function emitSessionCompleted(ctx: WorkflowEmitContext, summary?: string | Record<string, unknown>): void {
	const detailSummary = typeof summary === "object" && summary ? summary : undefined;
	const textSummary = typeof summary === "string" && summary.trim() ? summary.trim() : `Flightdeck session completed: ${workflowSessionId(ctx)}`;
	emitWorkflowActivity(ctx, {
		details: { dedup_key: `${workflowSessionId(ctx)}:session.completed`, ...(detailSummary ?? {}) },
		importance: "important",
		severity: "success",
		summary: textSummary,
		type: "session.completed",
	});
}

export function emitWorkflowDecision(ctx: WorkflowEmitContext, kind: string, options: WorkflowDecisionOptions = {}): void {
	const decisionKind = nonEmpty(kind) ?? "workflow";
	const answer = nonEmpty(options.answer);
	const summary = nonEmpty(options.summary) ?? (answer ? trimSummary(answer) : `Decision recorded: ${decisionKind}`);
	const severity = options.severity ?? (answer && /^(BLOCKED|ESCALATED|REJECTED):/.test(answer) ? "warning" : "info");
	const entryId = workflowEntryId(ctx) ?? workflowSessionId(ctx);
	const sequence = Number.isFinite(options.sequence) ? Math.trunc(options.sequence as number) : undefined;
	emitWorkflowActivity(ctx, {
		details: {
			...(options.details ?? {}),
			...(answer ? { answer } : {}),
			dedup_key: `${entryId}:decision.recorded:${sequence ?? decisionKind}:${summary}`,
			prompt_tag: decisionKind,
			...(sequence ? { sequence } : {}),
		},
		importance: options.importance ?? "important",
		refs: mergeRefs(ctx.refs, options.refs),
		severity,
		summary,
		type: "decision.recorded",
	});
}

export function emitMergePlanUpdated(ctx: WorkflowEmitContext, queue: unknown, conflictGraph: unknown): void {
	const queueCount = Array.isArray(queue) ? queue.length : 0;
	const conflictCount = conflictEdgeCount(conflictGraph);
	const severity: ActivitySeverity = conflictCount > 0 ? "warning" : "info";
	emitWorkflowActivity(ctx, {
		details: {
			conflict_count: conflictCount,
			conflict_graph: conflictGraph ?? null,
			dedup_key: `${workflowSessionId(ctx)}:merge-plan:${queueCount}:${conflictCount}:${conflictFingerprint(conflictGraph)}`,
			merge_queue: queue ?? null,
			queue_count: queueCount,
		},
		importance: conflictCount > 0 ? "important" : "normal",
		severity,
		summary: conflictCount > 0 ? `Merge plan updated: ${conflictCount} conflict${conflictCount === 1 ? "" : "s"} found` : `Merge plan updated: ${queueCount} queued PR${queueCount === 1 ? "" : "s"}`,
		type: "daemon.warning",
	});
}

export function emitMergeAction(ctx: WorkflowEmitContext, prNumber: number | string | null | undefined, kind: MergeActionKind, details: MergeActionDetails = {}): void {
	const type = normalizeMergeAction(kind);
	const pr = normalizePrNumber(prNumber) ?? normalizePrNumber(ctx.refs?.pr_number);
	const severity: ActivitySeverity = type === "pr.merged" ? "success" : type === "pr.merge_blocked" ? (details.transient === true ? "warning" : "error") : "info";
	const label = pr ? `PR #${pr}` : "PR";
	emitWorkflowActivity(ctx, {
		details: {
			...details,
			dedup_key: `${workflowEntryId(ctx) ?? workflowSessionId(ctx)}:${type}:${pr ?? "unknown"}:${details.commit ?? details.reason ?? ""}`,
		},
		importance: type === "pr.merge_blocked" ? "important" : "normal",
		refs: mergeRefs(ctx.refs, pr ? { pr_number: pr } : undefined, typeof details.commit === "string" ? { commit: details.commit } : undefined),
		severity,
		summary: type === "pr.merged" ? `${label} merged` : type === "pr.merge_blocked" ? `${label} merge blocked` : `${label} queued for merge`,
		type,
	});
}

export function emitCloseIssue(ctx: WorkflowEmitContext, outcome: CloseIssueOutcome, options: WorkflowCloseIssueOptions = {}): void {
	const normalized = normalizeCloseOutcome(outcome);
	const entryId = workflowEntryId(ctx) ?? workflowIssueId(ctx) ?? "entry";
	emitWorkflowActivity(ctx, {
		details: {
			...(options.details ?? {}),
			dedup_key: `${entryId}:${normalized.type}:${outcome}:${JSON.stringify(options.details ?? {})}`,
			outcome,
		},
		importance: "important",
		severity: options.severity ?? normalized.severity,
		summary: options.summary ?? `${entryId} ${normalized.word}${outcome === normalized.word ? "" : ` (${outcome})`}`,
		type: normalized.type,
	});
}

function emitWorkflowActivity(ctx: WorkflowEmitContext, event: ActivityEventInput): void {
	const activityPath = workflowActivityPath(ctx);
	if (!activityPath) return;
	emitActivityWithPath(activityPath, {
		...entryFields(ctx),
		...event,
		refs: mergeRefs(entryFields(ctx).refs as ActivityRefs | undefined, event.refs as ActivityRefs | undefined),
		source: event.source ?? "workflow",
	}, { nonblocking: true, sessionId: workflowSessionId(ctx) });
}

function workflowActivityPath(ctx: WorkflowEmitContext): string | null {
	const envPath = nonEmpty(process.env.FLIGHTDECK_ACTIVITY_FILE);
	if (envPath) return envPath;
	if (process.env.FLIGHTDECK_MANAGED !== "1") return null;
	const explicit = nonEmpty(ctx.activityPath);
	if (explicit) return explicit;
	const stateFile = nonEmpty(ctx.stateFile);
	if (!stateFile) return null;
	return resolveActivityPath({
		stateDir: ctx.stateDir,
		stateFile,
		sessionId: ctx.sessionId,
		tmuxSession: ctx.tmuxSession,
	});
}

function workflowSessionId(ctx: WorkflowEmitContext): string {
	return nonEmpty(ctx.sessionId) ?? nonEmpty(ctx.tmuxSession) ?? stateSessionId(ctx.stateFile) ?? "unknown";
}

function stateSessionId(stateFile: string | undefined): string | undefined {
	if (!stateFile) return undefined;
	try {
		const parsed = JSON.parse(readFileSync(stateFile, "utf8")) as unknown;
		if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return nonEmpty((parsed as Record<string, unknown>).session_id);
	} catch {
		return undefined;
	}
	return undefined;
}

function entryFields(ctx: WorkflowEmitContext): Pick<ActivityEventInput, "entry_id" | "entry_title" | "entry_kind" | "pane_id" | "harness" | "refs"> {
	const entry = ctx.entry && typeof ctx.entry === "object" && !Array.isArray(ctx.entry) ? ctx.entry : {};
	const issue = issueDomain(entry);
	const githubIssue = githubIssueDomain(entry);
	const refs = mergeRefs(
		ctx.refs,
		stringRecordRef("issue_id", nonEmpty(issue.id) ?? githubIssueId(githubIssue)),
		stringRecordRef("linear_id", nonEmpty(issue.linear_id) ?? nonEmpty(issue.id)),
		numberRecordRef("pr_number", normalizePrNumber(issue.pr_number) ?? normalizePrNumber(githubIssue.pr_number) ?? normalizePrNumber(entry.pr_number)),
		stringRecordRef("commit", nonEmpty(issue.merge_commit) ?? nonEmpty(githubIssue.merge_commit) ?? nonEmpty(entry.merge_commit)),
	);
	const out: Pick<ActivityEventInput, "entry_id" | "entry_title" | "entry_kind" | "pane_id" | "harness" | "refs"> = {};
	const entryId = nonEmpty(ctx.entryId) ?? nonEmpty(entry.id) ?? nonEmpty(issue.id) ?? githubIssueId(githubIssue);
	if (entryId) out.entry_id = entryId;
	const title = nonEmpty(ctx.entryTitle) ?? nonEmpty(entry.title);
	if (title) out.entry_title = title;
	const kind = nonEmpty(ctx.entryKind) ?? nonEmpty(entry.kind);
	if (kind) out.entry_kind = kind;
	const pane = nonEmpty(ctx.paneId) ?? nonEmpty(entry.pane_id);
	if (pane) out.pane_id = pane;
	const harness = nonEmpty(ctx.harness) ?? nonEmpty(entry.harness);
	if (harness) out.harness = harness;
	if (refs && Object.keys(refs).length > 0) out.refs = refs;
	return out;
}

function workflowEntryId(ctx: WorkflowEmitContext): string | undefined {
	return nonEmpty(ctx.entryId) ?? (ctx.entry ? nonEmpty(ctx.entry.id) : undefined);
}

function workflowIssueId(ctx: WorkflowEmitContext): string | undefined {
	if (!ctx.entry) return undefined;
	return nonEmpty(issueDomain(ctx.entry).id) ?? githubIssueId(githubIssueDomain(ctx.entry));
}

function issueDomain(entry: Record<string, unknown>): Record<string, unknown> {
	const domain = entry.domain;
	if (!domain || typeof domain !== "object" || Array.isArray(domain)) return {};
	const issue = (domain as Record<string, unknown>).issue;
	return issue && typeof issue === "object" && !Array.isArray(issue) ? issue as Record<string, unknown> : {};
}

function githubIssueDomain(entry: Record<string, unknown>): Record<string, unknown> {
	const domain = entry.domain;
	if (!domain || typeof domain !== "object" || Array.isArray(domain)) return {};
	const issue = (domain as Record<string, unknown>).github_issue;
	return issue && typeof issue === "object" && !Array.isArray(issue) ? issue as Record<string, unknown> : {};
}

function githubIssueId(issue: Record<string, unknown>): string | undefined {
	const number = normalizePrNumber(issue.number);
	return typeof number === "number" ? `#${number}` : undefined;
}

function normalizeMergeAction(kind: MergeActionKind): "pr.merge_queued" | "pr.merged" | "pr.merge_blocked" {
	if (kind === "merged" || kind === "pr.merged") return "pr.merged";
	if (kind === "blocked" || kind === "pr.merge_blocked") return "pr.merge_blocked";
	return "pr.merge_queued";
}

function normalizeCloseOutcome(outcome: CloseIssueOutcome): { severity: ActivitySeverity; type: "entry.completed" | "entry.cancelled" | "entry.dead"; word: string } {
	if (outcome === "complete" || outcome === "completed" || outcome === "merged") return { severity: "success", type: "entry.completed", word: "completed" };
	if (outcome === "cancelled" || outcome === "canceled") return { severity: "warning", type: "entry.cancelled", word: "cancelled" };
	return { severity: "error", type: "entry.dead", word: "dead" };
}

function conflictEdgeCount(value: unknown): number {
	if (!value || typeof value !== "object" || Array.isArray(value)) return 0;
	const edges = (value as Record<string, unknown>).edges;
	return Array.isArray(edges) ? edges.length : 0;
}

function conflictFingerprint(value: unknown): string {
	try { return JSON.stringify(value ?? null); }
	catch { return "unserializable"; }
}

function trimSummary(value: string): string {
	return value.length <= 120 ? value : `${value.slice(0, 119)}…`;
}

function nonEmpty(value: unknown): string | undefined {
	return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function normalizePrNumber(value: unknown): number | undefined {
	if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
	if (typeof value === "string" && /^[0-9]+$/.test(value)) return Number.parseInt(value, 10);
	return undefined;
}

function mergeRefs(...refsList: Array<ActivityRefs | undefined>): ActivityRefs | undefined {
	const merged: ActivityRefs = {};
	for (const refs of refsList) {
		if (!refs) continue;
		for (const [key, value] of Object.entries(refs) as Array<[keyof ActivityRefs, ActivityRefs[keyof ActivityRefs]]>) {
			if (value !== undefined && value !== null && value !== "") (merged as Record<string, unknown>)[key] = value;
		}
	}
	return Object.keys(merged).length > 0 ? merged : undefined;
}

function stringRecordRef(key: keyof ActivityRefs, value: string | undefined): ActivityRefs | undefined {
	return value ? { [key]: value } as ActivityRefs : undefined;
}

function numberRecordRef(key: keyof ActivityRefs, value: number | undefined): ActivityRefs | undefined {
	return value ? { [key]: value } as ActivityRefs : undefined;
}
