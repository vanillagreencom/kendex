export type TrackedEntryState =
	| "waiting"
	| "prompting"
	| "submitting"
	| "ready"
	| "complete"
	| "cancelled"
	| "dead"
	// Issue-mode lifecycle states (issue-mode workflows tag kind=issue
	// entries with these; renderers and handlers treat them as terminal
	// or near-terminal alongside the generic enum).
	| "merge-ready"
	| "merged"
	| "aborted"
	| string;
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

export interface GithubIssueDomain {
	number: number;
	url: string;
	worktree: string;
	pr_number: number | null;
	merge_commit: string | null;
	scope_files_actual?: number | null;
	[key: string]: unknown;
}

export interface TrackedEntryDomain {
	issue?: TrackedIssueDomain;
	github_issue?: GithubIssueDomain;
}

export interface TrackedEntryLaunch {
	model?: string | null;
	effort?: string | null;
	cmd?: string | null;
	requested_model?: string | null;
	requested_effort?: string | null;
	resolved_model?: string | null;
	resolved_effort?: string | null;
	model_source?: string | null;
	effort_source?: string | null;
	argv?: string[] | null;
	reasoning_status?: "configured" | "recorded" | "unsupported" | "not-applicable" | string | null;
	unsupported_reason?: string | null;
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
	/**
	 * PR number for generic ad-hoc/workflow entries that create a pull
	 * request outside the issue-domain model. Issue-mode entries keep the
	 * canonical value under `domain.issue.pr_number`; readers should prefer
	 * that and fall back to this field for non-issue rows.
	 */
	pr_number?: number | null;
	/** Optional worktree override for non-issue rows. */
	worktree?: string | null;
	/**
	 * Git branch captured at spawn time by `flightdeck-session start`
	 * via `git -C <cwd> rev-parse --abbrev-ref HEAD`. Null when the cwd
	 * is not a git repo or HEAD is detached. Informational — staleness
	 * is acceptable; agents that switch branches mid-session will not
	 * automatically refresh this field (vstack#101).
	 */
	branch?: string | null;
	/**
	 * ISO8601 timestamp recorded when a synthetic terminal-state
	 * transition fires (vstack#95C). Suppresses re-emission when an
	 * operator manually resets state back from a terminal value;
	 * clearing the marker explicitly re-enables a fresh emit.
	 */
	terminal_emitted_at?: string | null;
	[key: string]: unknown;
}

export interface FlightdeckStateLike {
	entries?: unknown;
	[key: string]: unknown;
}
