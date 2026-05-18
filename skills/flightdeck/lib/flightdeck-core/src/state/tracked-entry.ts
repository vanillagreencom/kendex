import type {
	FlightdeckStateLike,
	TrackedEntry,
	TrackedEntryLaunch,
} from "./types.ts";

export const ENTRY_ID_PATTERN = /^[A-Za-z0-9._-]+$/;
const DOMAIN_KEYS = new Set(["issue", "github_issue"]);

export interface ReadTrackedEntriesOptions {
	warn?: (message: string) => void;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return !!value && typeof value === "object" && !Array.isArray(value);
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

function invalidEntryDomainWarning(entryKey: string, error: unknown): string {
	const message = error instanceof Error ? error.message : String(error);
	return `Warning: invalid .entries[${JSON.stringify(entryKey)}].domain: ${message}; skipping.`;
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
	const kind = typeof raw.kind === "string" && raw.kind.trim() ? raw.kind : "adhoc";
	return { ...raw, id: entryId, kind } as TrackedEntry;
}

function validateEntryIdOrNull(value: unknown): string | null {
	try {
		return validateEntryId(value);
	} catch {
		return null;
	}
}

export function readTrackedEntries(state: FlightdeckStateLike | undefined | null, options: ReadTrackedEntriesOptions = {}): Record<string, TrackedEntry> {
	if (!state || typeof state !== "object") return {};
	const out: Record<string, TrackedEntry> = {};
	const entries = entryRecordMap(state.entries, options.warn);
	for (const [id, raw] of Object.entries(entries)) {
		const entry = normalizeEntry(id, raw, { warn: options.warn });
		try {
			validateTrackedEntryDomain(entry);
		} catch (error) {
			options.warn?.(invalidEntryDomainWarning(id, error));
			continue;
		}
		out[id] = entry;
	}
	return out;
}

export function writeTrackedEntry<T extends FlightdeckStateLike>(state: T, id: string, entry: TrackedEntry): T {
	const target = state as FlightdeckStateLike;
	const validId = validateEntryId(id, "entry id");
	const entryId = validateEntryId(entry.id, "entry.id");
	if (entryId !== validId) throw new Error(`invalid entry.id: must match entry id ${validId}`);
	validateTrackedEntryDomain(entry);
	if (!isRecord(target.entries)) target.entries = {};
	const entries = target.entries as Record<string, TrackedEntry>;
	const normalized = normalizeEntry(validId, entry as unknown as Record<string, unknown>, { strict: true });
	entries[validId] = normalized;
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

function validateOptionalFiniteNumber(value: unknown, label: string): void {
	if (value === undefined || value === null) return;
	if (typeof value !== "number" || !Number.isFinite(value)) throw new Error(`invalid ${label}: must be a finite number or null`);
}

function validateOptionalString(value: unknown, label: string): void {
	if (value === undefined || value === null) return;
	if (typeof value !== "string") throw new Error(`invalid ${label}: must be a string or null`);
}

function validateRequiredString(value: unknown, label: string): void {
	if (typeof value !== "string" || !value.trim()) throw new Error(`invalid ${label}: must be a non-empty string`);
}

export function validateTrackedEntryDomain(entry: Pick<TrackedEntry, "domain">): string | undefined {
	const domain = entry.domain;
	if (domain === undefined || domain === null) return undefined;
	if (!isRecord(domain)) throw new Error("must be an object or null");
	for (const key of Object.keys(domain)) {
		if (!DOMAIN_KEYS.has(key)) throw new Error(`unknown domain key ${JSON.stringify(key)} (expected issue or github_issue)`);
	}
	const issue = domain.issue;
	const github = domain.github_issue;
	if (issue !== undefined && issue !== null && github !== undefined && github !== null) {
		throw new Error("domain.issue and domain.github_issue are mutually exclusive");
	}
	let issueId: string | undefined;
	if (issue !== undefined && issue !== null) {
		if (!isRecord(issue)) throw new Error("invalid domain.issue: must be an object or null");
		if ("id" in issue && issue.id !== undefined) issueId = validateEntryId(issue.id, "domain.issue.id");
	}
	if (github !== undefined && github !== null) {
		if (!isRecord(github)) throw new Error("invalid domain.github_issue: must be an object or null");
		if (typeof github.number !== "number" || !Number.isFinite(github.number)) throw new Error("invalid domain.github_issue.number: must be a finite number");
		validateRequiredString(github.url, "domain.github_issue.url");
		validateRequiredString(github.worktree, "domain.github_issue.worktree");
		if (!("pr_number" in github)) throw new Error("invalid domain.github_issue.pr_number: missing required key");
		if (!("merge_commit" in github)) throw new Error("invalid domain.github_issue.merge_commit: missing required key");
		validateOptionalFiniteNumber(github.pr_number, "domain.github_issue.pr_number");
		validateOptionalString(github.merge_commit, "domain.github_issue.merge_commit");
		validateOptionalFiniteNumber(github.scope_files_actual, "domain.github_issue.scope_files_actual");
	}
	return issueId;
}

export function validateDomainIssueId(entry: Pick<TrackedEntry, "domain">): string | undefined {
	return validateTrackedEntryDomain(entry);
}

// Suppress unused-import linter complaint while leaving the type
// re-exported for downstream callers that still import it.
export type { TrackedEntryLaunch };
