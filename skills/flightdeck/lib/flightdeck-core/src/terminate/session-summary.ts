import { readTrackedEntries } from "../state/tracked-entry.ts";
import type { FlightdeckStateLike, TrackedEntry } from "../state/types.ts";

export interface TerminationPartition {
	genericEntries: TrackedEntry[];
	issueEntries: TrackedEntry[];
}

export interface TerminationSummaryOptions {
	session?: string;
	timestamp?: string;
	summaryPath?: string;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function issueDomain(entry: TrackedEntry): Record<string, unknown> | undefined {
	const domain = isRecord(entry.domain) ? entry.domain : undefined;
	const issue = domain && isRecord(domain.issue) ? domain.issue : undefined;
	return issue;
}

function isIssueEntry(entry: TrackedEntry): boolean {
	return entry.kind === "issue" || typeof issueDomain(entry)?.id === "string";
}

export function partitionTerminationEntries(state: FlightdeckStateLike): TerminationPartition {
	const entries = Object.values(readTrackedEntries(state));
	const issueEntries = entries.filter(isIssueEntry);
	const genericEntries = entries.filter((entry) => !isIssueEntry(entry));
	return { genericEntries, issueEntries };
}

function decisionCount(entry: TrackedEntry): number {
	return Array.isArray(entry.decisions_log) ? entry.decisions_log.length : 0;
}

function stringField(value: unknown, fallback = "—"): string {
	return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function issueId(entry: TrackedEntry): string {
	const issue = issueDomain(entry);
	return stringField(issue?.id, entry.id);
}

function issuePr(entry: TrackedEntry): string {
	const issue = issueDomain(entry);
	const pr = typeof issue?.pr_number === "number" ? issue.pr_number : (typeof entry.pr_number === "number" ? entry.pr_number : null);
	return pr === null ? "—" : `#${pr}`;
}

function issueMergeCommit(entry: TrackedEntry): string {
	const issue = issueDomain(entry);
	const raw = typeof entry.merge_commit === "string" ? entry.merge_commit : typeof issue?.merge_commit === "string" ? issue.merge_commit : "";
	return raw ? raw.slice(0, 12) : "—";
}

function issueState(entry: TrackedEntry): string {
	const issue = issueDomain(entry);
	const outcome = issue && typeof issue.outcome === "string" ? issue.outcome : "";
	if (outcome) return outcome;
	return stringField(entry.state, "unknown");
}

function summaryPath(opts: TerminationSummaryOptions): string {
	if (opts.summaryPath) return opts.summaryPath;
	const session = opts.session ?? "SESSION";
	const ts = (opts.timestamp ?? "TS").replace(/:/g, "");
	return `tmp/flightdeck-summary-${session}-${ts}.md`;
}

export function renderGenericTerminationSummary(entries: TrackedEntry[], opts: TerminationSummaryOptions = {}): string {
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
		...(rows.length ? rows : ["| — | — | — | — | 0 |"]),
		"",
		`**Counts**: ${entries.length} sessions · ${complete} complete · ${cancelled} cancelled · ${dead} dead`,
		"",
		`Summary file: \`${summaryPath(opts)}\``,
	].join("\n");
}

export function renderIssueTerminationSummary(entries: TrackedEntry[], opts: TerminationSummaryOptions = {}): string {
	const rows = entries.map((entry) => `| ${issueId(entry)} | ${issueState(entry)} | ${issuePr(entry)} | ${issueMergeCommit(entry)} | ${decisionCount(entry)} |`);
	const merged = entries.filter((entry) => issueState(entry) === "merged").length;
	const aborted = entries.filter((entry) => issueState(entry) === "aborted").length;
	return [
		"### ✈️ Flightdeck session complete",
		"",
		"**Outcomes**",
		"",
		"| Issue | State | PR | Merge commit | Decisions |",
		"|-------|-------|----|--------------|-----------|",
		...(rows.length ? rows : ["| — | — | — | — | 0 |"]),
		"",
		"**Next-cycle recommendation**",
		"",
		"- Stick with planned cycle — no created issues warrant precedence.",
		"",
		`**Counts**: ${merged} merged · ${aborted} aborted · 0 children · 0 follow-ups · 0 recommended next`,
		"",
		`Summary file: \`${summaryPath(opts)}\``,
	].join("\n");
}

export function renderTerminationSummary(state: FlightdeckStateLike, opts: TerminationSummaryOptions = {}): string {
	const { genericEntries, issueEntries } = partitionTerminationEntries(state);
	const sections: string[] = [];
	if (genericEntries.length > 0) sections.push(renderGenericTerminationSummary(genericEntries, opts));
	if (issueEntries.length > 0) sections.push(renderIssueTerminationSummary(issueEntries, opts));
	return sections.join("\n\n");
}
