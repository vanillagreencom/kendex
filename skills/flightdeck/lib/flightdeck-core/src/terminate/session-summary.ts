import { readTrackedEntries } from "../state/tracked-entry.ts";
import type { FlightdeckStateLike, TrackedEntry } from "../state/types.ts";

export interface TerminationPartition {
	entryCount: number;
	genericEntries: TrackedEntry[];
	issueEntries: TrackedEntry[];
	warnings: string[];
}

export interface TerminationPartitionOptions {
	warn?: (message: string) => void;
}

export interface TerminationSummaryOptions extends TerminationPartitionOptions {
	session?: string;
	timestamp?: string;
	summaryPath?: string;
}

const ISSUE_STATES = new Set(["merge-ready", "merged", "aborted"]);
const ISSUE_SUBSTATES = new Set([
	"audit-relation-prompt",
	"bot-review-wait-stuck",
	"cleanup-prompt",
	"cycle-fix-suggestions",
	"descope-related",
	"external-fix-suggestions",
	"force-merge-confirm",
	"force-push-prompt",
	"merge-now",
	"merge-ready-but-unknown",
	"rebase-multi-choice",
	"scope-creep-detected",
	"stale-no-pr-branch",
	"stale-orphan-worktree",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function issueDomain(entry: TrackedEntry): Record<string, unknown> | undefined {
	const domain = isRecord(entry.domain) ? entry.domain : undefined;
	const issue = domain && isRecord(domain.issue) ? domain.issue : undefined;
	return issue;
}

function githubIssueDomain(entry: TrackedEntry): Record<string, unknown> | undefined {
	const domain = isRecord(entry.domain) ? entry.domain : undefined;
	const issue = domain && isRecord(domain.github_issue) ? domain.github_issue : undefined;
	return issue;
}

function hasNonEmptyString(value: unknown): boolean {
	return typeof value === "string" && value.trim().length > 0;
}

function hasFiniteNumber(value: unknown): boolean {
	return typeof value === "number" && Number.isFinite(value);
}

function issueMarkers(entry: TrackedEntry): string[] {
	const markers: string[] = [];
	const issue = issueDomain(entry);
	const githubIssue = githubIssueDomain(entry);
	const genericKind = entry.kind === "adhoc" || entry.kind === "workflow";
	if (hasNonEmptyString(issue?.id)) markers.push("domain.issue.id");
	if (hasFiniteNumber(githubIssue?.number)) markers.push("domain.github_issue.number");
	if (hasFiniteNumber(issue?.pr_number) || hasFiniteNumber(githubIssue?.pr_number) || (!genericKind && hasFiniteNumber(entry.pr_number))) markers.push("pr_number");
	if (hasNonEmptyString(issue?.worktree) || hasNonEmptyString(githubIssue?.worktree) || (!genericKind && hasNonEmptyString(entry.worktree))) markers.push("worktree");
	if (hasNonEmptyString(issue?.merge_commit) || hasNonEmptyString(githubIssue?.merge_commit) || hasNonEmptyString(entry.merge_commit)) markers.push("merge_commit");
	if (hasFiniteNumber(issue?.scope_files_declared) || hasFiniteNumber(issue?.scope_files_actual) || hasFiniteNumber(githubIssue?.scope_files_actual)) markers.push("scope_files");
	if (typeof issue?.orchestration_started === "boolean" || typeof entry.orchestration_started === "boolean") markers.push("orchestration_started");
	if (typeof entry.state === "string" && ISSUE_STATES.has(entry.state)) markers.push(`state:${entry.state}`);
	if (typeof entry.substate === "string" && ISSUE_SUBSTATES.has(entry.substate)) markers.push(`substate:${entry.substate}`);
	return [...new Set(markers)];
}

function warn(message: string, opts: TerminationPartitionOptions, warnings: string[]): void {
	warnings.push(message);
	if (opts.warn) opts.warn(message);
	else process.stderr.write(`${message}\n`);
}

function classifyEntry(entry: TrackedEntry, opts: TerminationPartitionOptions, warnings: string[]): "generic" | "issue" {
	if (entry.kind === "issue") return "issue";
	if (hasNonEmptyString(issueDomain(entry)?.id)) return "issue";
	if (hasFiniteNumber(githubIssueDomain(entry)?.number)) return "issue";
	const markers = issueMarkers(entry).filter((marker) => marker !== "domain.issue.id" && marker !== "domain.github_issue.number");
	if (markers.length > 0) {
		warn(`Warning: issue-shaped tracked entry ${JSON.stringify(entry.id)} missing kind=issue/domain issue key; routing through issue termination path (${markers.join(", ")}).`, opts, warnings);
		return "issue";
	}
	return "generic";
}

export function partitionTerminationEntries(state: FlightdeckStateLike, opts: TerminationPartitionOptions = {}): TerminationPartition {
	const warnings: string[] = [];
	const entries = Object.values(readTrackedEntries(state, { warn: (message) => warn(message, opts, warnings) }));
	const issueEntries: TrackedEntry[] = [];
	const genericEntries: TrackedEntry[] = [];
	for (const entry of entries) {
		if (classifyEntry(entry, opts, warnings) === "issue") issueEntries.push(entry);
		else genericEntries.push(entry);
	}
	return { entryCount: entries.length, genericEntries, issueEntries, warnings };
}

function decisionCount(entry: TrackedEntry): number {
	return Array.isArray(entry.decisions_log) ? entry.decisions_log.length : 0;
}

function stringField(value: unknown, fallback = "—"): string {
	return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function summaryPath(opts: TerminationSummaryOptions): string {
	if (opts.summaryPath) return opts.summaryPath;
	const session = opts.session ?? "SESSION";
	const ts = (opts.timestamp ?? "TS").replace(/:/g, "");
	return `tmp/flightdeck-summary-${session}-${ts}.md`;
}

export function renderEmptyTerminationSummary(opts: TerminationSummaryOptions = {}): string {
	return [
		"### ✈️ Flightdeck session complete",
		"",
		"Session terminated with no tracked entries.",
		"",
		"**Counts**: 0 sessions · 0 complete · 0 cancelled · 0 dead",
		"",
		`Summary file: \`${summaryPath(opts)}\``,
	].join("\n");
}

export function renderGenericTerminationSummary(entries: TrackedEntry[], opts: TerminationSummaryOptions = {}): string {
	if (entries.length === 0) return renderEmptyTerminationSummary(opts);
	const rows = entries.map((entry) => `| ${entry.id} | ${stringField(entry.kind)} | ${stringField(entry.state, "unknown")} | ${stringField(entry.harness)} | ${decisionCount(entry)} |`);
	const complete = entries.filter((entry) => entry.state === "complete").length;
	const cancelled = entries.filter((entry) => entry.state === "cancelled").length;
	const dead = entries.filter((entry) => entry.state === "dead").length;
	return [
		"### ✈️ Flightdeck sessions complete",
		"",
		"**Tracked sessions**",
		"",
		"| Entry | Kind | State | Harness | Decisions |",
		"|-------|------|-------|---------|-----------|",
		...rows,
		"",
		`**Counts**: ${entries.length} sessions · ${complete} complete · ${cancelled} cancelled · ${dead} dead`,
		"",
		`Summary file: \`${summaryPath(opts)}\``,
	].join("\n");
}

export function renderGenericTerminationSummaryFromState(state: FlightdeckStateLike, opts: TerminationSummaryOptions = {}): string {
	const { entryCount, genericEntries } = partitionTerminationEntries(state, opts);
	if (entryCount === 0) return renderEmptyTerminationSummary(opts);
	if (genericEntries.length === 0) return "";
	return renderGenericTerminationSummary(genericEntries, opts);
}
