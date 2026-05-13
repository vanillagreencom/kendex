import type {
	FlightdeckStateLike,
	LegacyIssueRecord,
	TrackedEntry,
	TrackedEntryAdapter,
	TrackedEntryLaunch,
} from "./types.ts";

export const ENTRY_ID_PATTERN = /^[A-Za-z0-9._-]+$/;
export const SUPPORTED_SCHEMA_VERSION = "1.1";

export interface ReadTrackedEntriesOptions {
	warn?: (message: string) => void;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
}

function issueRecordMap(value: unknown): Record<string, Record<string, unknown>> {
	if (!isRecord(value)) return {};
	const out: Record<string, Record<string, unknown>> = {};
	for (const [key, raw] of Object.entries(value)) {
		if (isRecord(raw)) out[key] = raw;
	}
	return out;
}

function entryRecordMap(value: unknown, warn?: (message: string) => void): Record<string, Record<string, unknown>> {
	if (!isRecord(value)) return {};
	const out: Record<string, Record<string, unknown>> = {};
	const invalid: string[] = [];
	for (const [key, raw] of Object.entries(value)) {
		if (isRecord(raw)) out[key] = raw;
		else invalid.push(key);
	}
	if (invalid.length > 0) warn?.(invalidEntriesWarning(invalid));
	return out;
}

function invalidEntriesWarning(ids: string[]): string {
	return `Warning: invalid .entries value(s) for ${ids.map((id) => JSON.stringify(id)).join(", ")}; skipping.`;
}

function invalidEntryIdWarning(entryKey: string, rawId: unknown): string {
	return `Warning: invalid .entries[${JSON.stringify(entryKey)}].id ${JSON.stringify(rawId)}; using entry key.`;
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

export function validateEntryId(value: unknown, label = "entry id"): string {
	if (typeof value !== "string") throw new Error(`invalid ${label}: must be a string`);
	const trimmed = value.trim();
	if (!trimmed || !ENTRY_ID_PATTERN.test(trimmed)) throw new Error(`invalid ${label}: must be non-empty and match ${ENTRY_ID_PATTERN.source}`);
	return trimmed;
}

function normalizeEntry(id: string, raw: Record<string, unknown>, opts: { strict?: boolean; warn?: (message: string) => void } = {}): TrackedEntry {
	const keyId = opts.strict ? validateEntryId(id, "entry id") : (validateEntryIdOrNull(id) ?? id);
	const rawId = typeof raw.id === "string" ? validateEntryIdOrNull(raw.id) : null;
	if (raw.id !== undefined && rawId === null) opts.warn?.(invalidEntryIdWarning(id, raw.id));
	const entryId = rawId ?? keyId;
	const kind = typeof raw.kind === "string" && raw.kind.trim() ? raw.kind : "issue";
	return { ...raw, id: entryId, kind } as TrackedEntry;
}

function validateEntryIdOrNull(value: unknown): string | null {
	try {
		return validateEntryId(value);
	} catch {
		return null;
	}
}

function entryFromLegacyIssue(issueId: string, raw: Record<string, unknown>): TrackedEntry | null {
	const entryId = entryIdForIssue(issueId);
	if (!entryId) return null;
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
		id: entryId,
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

export function readTrackedEntries(state: FlightdeckStateLike | undefined | null, options: ReadTrackedEntriesOptions = {}): Record<string, TrackedEntry> {
	if (!state || typeof state !== "object") return {};
	const out: Record<string, TrackedEntry> = {};
	const issues = issueRecordMap(state.issues);
	for (const [issueId, raw] of Object.entries(issues)) {
		const projected = entryFromLegacyIssue(issueId, raw);
		if (projected) out[projected.id] = projected;
	}
	const entries = entryRecordMap(state.entries, options.warn);
	for (const [id, raw] of Object.entries(entries)) out[id] = normalizeEntry(id, raw, { warn: options.warn });
	return out;
}

export function writeTrackedEntry<T extends FlightdeckStateLike>(state: T, id: string, entry: TrackedEntry): T {
	const target = state as FlightdeckStateLike;
	const validId = validateEntryId(id, "entry id");
	const entryId = validateEntryId(entry.id, "entry.id");
	if (entryId !== validId) throw new Error(`invalid entry.id: must match entry id ${validId}`);
	validateDomainIssueId(entry);
	if (!isRecord(target.entries)) target.entries = {};
	const entries = target.entries as Record<string, TrackedEntry>;
	const normalized = normalizeEntry(validId, entry as unknown as Record<string, unknown>, { strict: true });
	entries[validId] = normalized;

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

export function entryIdForIssue(issueId: string): string | null {
	return validateEntryIdOrNull(issueId);
}

export function issueIdForEntry(entry: Pick<TrackedEntry, "id" | "kind" | "domain">): string | undefined {
	const issue = entry.domain && typeof entry.domain === "object" && !Array.isArray(entry.domain) ? entry.domain.issue : undefined;
	if (issue && typeof issue === "object" && !Array.isArray(issue) && typeof issue.id === "string" && issue.id.trim()) return validateEntryId(issue.id, "domain.issue.id");
	return entry.kind === "issue" && entry.id.trim() ? entry.id : undefined;
}

export function validateDomainIssueId(entry: Pick<TrackedEntry, "domain">): string | undefined {
	const issue = entry.domain && typeof entry.domain === "object" && !Array.isArray(entry.domain) ? entry.domain.issue : undefined;
	if (!issue || typeof issue !== "object" || Array.isArray(issue) || !("id" in issue) || issue.id === undefined) return undefined;
	return validateEntryId(issue.id, "domain.issue.id");
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

export function unknownSchemaWarning(state: FlightdeckStateLike | undefined | null): string | undefined {
	if (!state || typeof state !== "object") return undefined;
	if (!("schema_version" in state) || state.schema_version === null || state.schema_version === undefined) return undefined;
	const raw = String(state.schema_version);
	if (raw === SUPPORTED_SCHEMA_VERSION) return undefined;
	return `Warning: unknown schema_version ${JSON.stringify(raw)}, treating as 1.1 (read-only safe).`;
}

export function assertWritableSchemaVersion(state: FlightdeckStateLike | undefined | null, allowFuture = false): void {
	const warning = unknownSchemaWarning(state);
	if (!warning || allowFuture) return;
	const version = state && typeof state === "object" && state.schema_version !== undefined ? String(state.schema_version) : "unknown";
	throw new Error(`unknown schema_version ${JSON.stringify(version)}; refusing write (set FLIGHTDECK_ALLOW_FUTURE_SCHEMA=1 to override)`);
}
