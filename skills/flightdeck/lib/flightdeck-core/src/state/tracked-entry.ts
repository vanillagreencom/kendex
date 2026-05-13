import type {
	FlightdeckStateLike,
	LegacyIssueRecord,
	TrackedEntry,
	TrackedEntryAdapter,
	TrackedEntryLaunch,
} from "./types.ts";

function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function recordMap(value: unknown): Record<string, Record<string, unknown>> {
	if (!isRecord(value)) return {};
	const out: Record<string, Record<string, unknown>> = {};
	for (const [key, raw] of Object.entries(value)) {
		if (isRecord(raw)) out[key] = raw;
	}
	return out;
}

function stringOrNull(value: unknown): string | null {
	return typeof value === "string" ? value : null;
}

function numberOrNull(value: unknown): number | null {
	return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function booleanOrNull(value: unknown): boolean | null {
	return typeof value === "boolean" ? value : null;
}

function launchOrNull(value: unknown): TrackedEntryLaunch | null {
	return isRecord(value) ? value as TrackedEntryLaunch : null;
}

function decisionsLogOrEmpty(value: unknown): TrackedEntry["decisions_log"] {
	return Array.isArray(value) ? value as TrackedEntry["decisions_log"] : [];
}

function normalizeEntry(id: string, raw: Record<string, unknown>): TrackedEntry {
	const entryId = typeof raw.id === "string" && raw.id.trim() ? raw.id : id;
	const kind = typeof raw.kind === "string" && raw.kind.trim() ? raw.kind : "issue";
	return { ...raw, id: entryId, kind } as TrackedEntry;
}

function entryFromLegacyIssue(issueId: string, raw: Record<string, unknown>): TrackedEntry {
	const issue = raw as LegacyIssueRecord;
	const adapter: TrackedEntryAdapter = {
		cc_port: numberOrNull(issue.cc_port),
		cc_session_uuid: stringOrNull(issue.cc_session_uuid),
		cc_transcript: stringOrNull(issue.cc_transcript),
		cc_url: stringOrNull(issue.cc_url),
		cx_thread_id: stringOrNull(issue.cx_thread_id),
		cx_ws: stringOrNull(issue.cx_ws),
		oc_port: numberOrNull(issue.oc_port),
		oc_session_id: stringOrNull(issue.oc_session_id),
		oc_url: stringOrNull(issue.oc_url),
		pi_bridge_pid: numberOrNull(issue.pi_bridge_pid),
		pi_bridge_socket: stringOrNull(issue.pi_bridge_socket),
		pi_session_id: stringOrNull(issue.pi_session_id),
	};
	return {
		adapter,
		cwd: stringOrNull(issue.cwd) ?? stringOrNull(issue.worktree),
		decisions_log: decisionsLogOrEmpty(issue.decisions_log),
		domain: {
			issue: {
				id: issueId,
				merge_commit: stringOrNull(issue.merge_commit),
				orchestration_started: booleanOrNull(issue.orchestration_started),
				pr_number: numberOrNull(issue.pr_number),
				scope_files_actual: numberOrNull(issue.scope_files_actual),
				scope_files_declared: numberOrNull(issue.scope_files_declared),
				worktree: stringOrNull(issue.worktree),
			},
		},
		harness: stringOrNull(issue.harness),
		id: entryIdForIssue(issueId),
		kind: "issue",
		last_capture_hash: stringOrNull(issue.last_capture_hash),
		last_polled_at: stringOrNull(issue.last_polled_at),
		last_response_at: stringOrNull(issue.last_response_at),
		launch: launchOrNull(issue.launch),
		merge_commit: stringOrNull(issue.merge_commit),
		pane_id: stringOrNull(issue.pane_id),
		pane_target: stringOrNull(issue.pane_target),
		spawned_at: stringOrNull(issue.spawned_at),
		state: stringOrNull(issue.state),
		substate: stringOrNull(issue.substate),
		title: typeof issue.title === "string" && issue.title.trim() ? issue.title : issueId,
		unknown_since: stringOrNull(issue.unknown_since),
		window: stringOrNull(issue.window),
	};
}

export function readTrackedEntries(state: FlightdeckStateLike | undefined | null): Record<string, TrackedEntry> {
	if (!state || typeof state !== "object") return {};
	const entries = recordMap(state.entries);
	if (Object.keys(entries).length > 0) {
		const out: Record<string, TrackedEntry> = {};
		for (const [id, raw] of Object.entries(entries)) out[id] = normalizeEntry(id, raw);
		return out;
	}
	const issues = recordMap(state.issues);
	const out: Record<string, TrackedEntry> = {};
	for (const [issueId, raw] of Object.entries(issues)) out[entryIdForIssue(issueId)] = entryFromLegacyIssue(issueId, raw);
	return out;
}

export function writeTrackedEntry<T extends FlightdeckStateLike>(state: T, id: string, entry: TrackedEntry): T {
	const target = state as FlightdeckStateLike;
	if (!isRecord(target.entries)) target.entries = {};
	const entries = target.entries as Record<string, TrackedEntry>;
	const normalized = normalizeEntry(id, entry as unknown as Record<string, unknown>);
	entries[id] = normalized;

	const issueId = issueIdForEntry(normalized);
	if (issueId) {
		if (!isRecord(target.issues)) target.issues = {};
		const issues = target.issues as Record<string, LegacyIssueRecord>;
		issues[issueId] = {
			...(isRecord(issues[issueId]) ? issues[issueId] : {}),
			...legacyIssueProjection(normalized, issueId),
		};
	}
	return state;
}

export function entryIdForIssue(issueId: string): string {
	return issueId;
}

export function issueIdForEntry(entry: Pick<TrackedEntry, "id" | "kind" | "domain">): string | undefined {
	const issue = entry.domain && typeof entry.domain === "object" && !Array.isArray(entry.domain) ? entry.domain.issue : undefined;
	if (issue && typeof issue === "object" && !Array.isArray(issue) && typeof issue.id === "string" && issue.id.trim()) return issue.id;
	return entry.kind === "issue" && entry.id.trim() ? entry.id : undefined;
}

export function legacyIssueProjection(entry: TrackedEntry, issueId = issueIdForEntry(entry) ?? entry.id): LegacyIssueRecord {
	const issue = entry.domain?.issue;
	const adapter = entry.adapter ?? {};
	return {
		cc_port: numberOrNull(adapter.cc_port),
		cc_session_uuid: stringOrNull(adapter.cc_session_uuid),
		cc_transcript: stringOrNull(adapter.cc_transcript),
		cc_url: stringOrNull(adapter.cc_url),
		cx_thread_id: stringOrNull(adapter.cx_thread_id),
		cx_ws: stringOrNull(adapter.cx_ws),
		decisions_log: decisionsLogOrEmpty(entry.decisions_log),
		harness: stringOrNull(entry.harness),
		last_capture_hash: stringOrNull(entry.last_capture_hash),
		last_polled_at: stringOrNull(entry.last_polled_at),
		last_response_at: stringOrNull(entry.last_response_at),
		launch: launchOrNull(entry.launch),
		merge_commit: stringOrNull(entry.merge_commit ?? issue?.merge_commit),
		oc_port: numberOrNull(adapter.oc_port),
		oc_session_id: stringOrNull(adapter.oc_session_id),
		oc_url: stringOrNull(adapter.oc_url),
		orchestration_started: booleanOrNull(issue?.orchestration_started),
		pane_id: stringOrNull(entry.pane_id),
		pane_target: stringOrNull(entry.pane_target),
		pi_bridge_pid: numberOrNull(adapter.pi_bridge_pid),
		pi_bridge_socket: stringOrNull(adapter.pi_bridge_socket),
		pi_session_id: stringOrNull(adapter.pi_session_id),
		pr_number: numberOrNull(issue?.pr_number),
		scope_files_actual: numberOrNull(issue?.scope_files_actual),
		scope_files_declared: numberOrNull(issue?.scope_files_declared),
		spawned_at: stringOrNull(entry.spawned_at),
		state: stringOrNull(entry.state),
		substate: stringOrNull(entry.substate),
		unknown_since: stringOrNull(entry.unknown_since),
		window: stringOrNull(entry.window),
		worktree: stringOrNull(issue?.worktree) ?? stringOrNull(entry.cwd),
	};
}
