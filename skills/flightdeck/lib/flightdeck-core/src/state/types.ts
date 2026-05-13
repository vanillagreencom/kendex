export const FLIGHTDECK_SCHEMA_VERSION = 1.1;

export type IssueState = "waiting" | "prompting" | "submitting" | "merge-ready" | "merged" | "aborted" | "dead";
export type TrackedEntryState = IssueState | "ready" | "complete" | "cancelled" | string;
export type TrackedEntryKind = "adhoc" | "issue" | "workflow" | string;

export interface DecisionLogEntry {
	ts: string;
	prompt_tag: string;
	answer: string;
	[key: string]: unknown;
}

export interface TrackedEntryAdapter {
	pi_bridge_pid?: number | null;
	pi_bridge_socket?: string | null;
	pi_session_id?: string | null;
	oc_url?: string | null;
	oc_session_id?: string | null;
	oc_port?: number | null;
	cc_url?: string | null;
	cc_session_uuid?: string | null;
	cc_transcript?: string | null;
	cc_port?: number | null;
	cx_ws?: string | null;
	cx_thread_id?: string | null;
	[key: string]: unknown;
}

export interface TrackedIssueDomain {
	id: string;
	worktree?: string | null;
	pr_number?: number | null;
	scope_files_declared?: number | null;
	scope_files_actual?: number | null;
	orchestration_started?: boolean | null;
	merge_commit?: string | null;
	[key: string]: unknown;
}

export interface TrackedEntryDomain {
	issue?: TrackedIssueDomain;
	[key: string]: unknown;
}

export interface TrackedEntryLaunch {
	model?: string | null;
	effort?: string | null;
	cmd?: string | null;
	[key: string]: unknown;
}

export interface TrackedEntry {
	id: string;
	title?: string | null;
	kind: TrackedEntryKind;
	state?: TrackedEntryState | null;
	substate?: string | null;
	harness?: string | null;
	cwd?: string | null;
	window?: string | null;
	pane_target?: string | null;
	pane_id?: string | null;
	launch?: TrackedEntryLaunch | null;
	adapter?: TrackedEntryAdapter | null;
	domain?: TrackedEntryDomain | null;
	last_capture_hash?: string | null;
	last_response_at?: string | null;
	spawned_at?: string | null;
	last_polled_at?: string | null;
	decisions_log?: DecisionLogEntry[];
	unknown_since?: string | null;
	merge_commit?: string | null;
	[key: string]: unknown;
}

export interface LegacyIssueRecord {
	issue?: string;
	window?: string | null;
	pane_target?: string | null;
	pane_id?: string | null;
	harness?: string | null;
	launch?: TrackedEntryLaunch | null;
	worktree?: string | null;
	cwd?: string | null;
	pr_number?: number | null;
	oc_url?: string | null;
	oc_session_id?: string | null;
	oc_port?: number | null;
	cc_url?: string | null;
	cc_session_uuid?: string | null;
	cc_port?: number | null;
	cc_transcript?: string | null;
	pi_bridge_pid?: number | null;
	pi_bridge_socket?: string | null;
	pi_session_id?: string | null;
	cx_ws?: string | null;
	cx_thread_id?: string | null;
	state?: IssueState | string | null;
	substate?: string | null;
	unknown_since?: string | null;
	last_capture_hash?: string | null;
	last_response_at?: string | null;
	spawned_at?: string | null;
	last_polled_at?: string | null;
	orchestration_started?: boolean | null;
	scope_files_declared?: number | null;
	scope_files_actual?: number | null;
	decisions_log?: DecisionLogEntry[];
	merge_commit?: string | null;
	[key: string]: unknown;
}

export interface FlightdeckStateLike {
	schema_version?: number | string;
	entries?: unknown;
	issues?: unknown;
	[key: string]: unknown;
}
