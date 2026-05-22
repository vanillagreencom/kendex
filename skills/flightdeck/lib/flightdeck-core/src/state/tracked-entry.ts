import type {
	FlightdeckStateLike,
	TrackedEntry,
	TrackedEntryLaunch,
} from "./types.ts";
import { lstatSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, normalize, relative, resolve, sep } from "node:path";
import { loadDotEnvIntoProcess, resolveProjectRoot } from "../shared/project.ts";
import { resolveProjectIdentity, resolveProjectRunPaths } from "./run-store.ts";

export const ENTRY_ID_PATTERN = /^[A-Za-z0-9._-]+$/;
const DOMAIN_KEYS = new Set(["issue", "github_issue", "plan_item"]);

export interface ReadTrackedEntriesOptions {
	strictPlanItemDomain?: boolean;
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
	return `Warning: ${invalidEntryDomainError(entryKey, error)}; skipping.`;
}

function invalidEntryDomainError(entryKey: string, error: unknown): string {
	const message = error instanceof Error ? error.message : String(error);
	return `invalid .entries[${JSON.stringify(entryKey)}].domain: ${message}`;
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

function hasPlanItemDomain(entry: Pick<TrackedEntry, "domain">): boolean {
	const domain = entry.domain;
	return isRecord(domain) && domain.plan_item !== undefined && domain.plan_item !== null;
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
			if (options.strictPlanItemDomain && hasPlanItemDomain(entry)) throw new Error(invalidEntryDomainError(id, error));
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

function validateOptionalNonEmptyString(value: unknown, label: string): void {
	if (value === undefined || value === null) return;
	if (typeof value !== "string" || !value.trim()) throw new Error(`invalid ${label}: must be a non-empty string or null`);
}

interface PlanBriefLocation {
	projectRoot: string;
	stateBase: string;
	briefRoot: string;
}

function expectedPlanBriefLocation(): PlanBriefLocation {
	const projectRoot = resolveProjectRoot();
	loadDotEnvIntoProcess(projectRoot);
	// vstack#227: plan briefs live under the project's run-store
	// container, not inside any specific run directory. Plans outlive
	// individual run rotations, so binding the briefs to a single run
	// would orphan them on terminate/restart. The validator therefore
	// accepts any path under `<project_dir>/plan-briefs/`, regardless of
	// the active run.
	const identity = resolveProjectIdentity(projectRoot);
	const stateBase = resolveProjectRunPaths(identity).project_dir;
	return { projectRoot, stateBase, briefRoot: resolve(stateBase, "plan-briefs") };
}

function isInside(root: string, candidate: string): boolean {
	const rel = relative(root, candidate);
	return rel === "" || (!!rel && !rel.startsWith("..") && !isAbsolute(rel));
}

function lstatIfPresent(path: string): ReturnType<typeof lstatSync> | null {
	try {
		return lstatSync(path);
	} catch (error) {
		if (error && typeof error === "object" && "code" in error) {
			const code = (error as { code?: unknown }).code;
			if (code === "ENOENT" || code === "ENOTDIR") return null;
		}
		throw error;
	}
}

function pathChain(root: string, target: string): string[] {
	if (!isInside(root, target)) return [];
	const out: string[] = [];
	let cursor = target;
	while (isInside(root, cursor)) {
		out.push(cursor);
		if (cursor === root) break;
		const next = dirname(cursor);
		if (next === cursor) break;
		cursor = next;
	}
	return out.reverse();
}

function assertNoSymlinkEscape(location: PlanBriefLocation, artifactPath: string, label: string): void {
	const { projectRoot, stateBase, briefRoot } = location;
	const projectRootReal = realpathSync(projectRoot);
	for (const ancestor of pathChain(projectRoot, stateBase)) {
		const stat = lstatIfPresent(ancestor);
		if (!stat) continue;
		if (ancestor !== projectRoot && stat.isSymbolicLink()) {
			if (ancestor === stateBase) throw new Error(`invalid ${label}: state directory must not be a symlink`);
			throw new Error(`invalid ${label}: state directory parent must not be a symlink`);
		}
		const ancestorReal = realpathSync(ancestor);
		if (!isInside(projectRootReal, ancestorReal)) throw new Error(`invalid ${label}: state directory escapes project-owned root`);
	}

	const stateBaseStat = lstatIfPresent(stateBase);
	let stateBaseReal: string | null = null;
	if (stateBaseStat) {
		if (stateBaseStat.isSymbolicLink()) throw new Error(`invalid ${label}: state directory must not be a symlink`);
		stateBaseReal = realpathSync(stateBase);
	}

	for (const ancestor of pathChain(stateBase, artifactPath)) {
		const stat = lstatIfPresent(ancestor);
		if (!stat) continue;
		if (stat.isSymbolicLink()) {
			if (ancestor === stateBase) throw new Error(`invalid ${label}: state directory must not be a symlink`);
			if (ancestor === briefRoot) throw new Error(`invalid ${label}: plan-briefs root must not be a symlink`);
			throw new Error(`invalid ${label}: must not traverse symlinks`);
		}
		if (stateBaseReal) {
			const ancestorReal = realpathSync(ancestor);
			if (!isInside(stateBaseReal, ancestorReal)) throw new Error(`invalid ${label}: parent directory escapes state-owned directory`);
		}
	}

	const briefRootStat = lstatIfPresent(briefRoot);
	if (!briefRootStat) return;
	if (briefRootStat.isSymbolicLink()) throw new Error(`invalid ${label}: plan-briefs root must not be a symlink`);
	const briefRootReal = realpathSync(briefRoot);
	const parentStat = lstatIfPresent(dirname(artifactPath));
	if (parentStat) {
		const parentReal = realpathSync(dirname(artifactPath));
		if (!isInside(briefRootReal, parentReal)) throw new Error(`invalid ${label}: parent directory escapes state-owned plan-briefs root`);
	}
	const artifactStat = lstatIfPresent(artifactPath);
	if (artifactStat) {
		if (artifactStat.isSymbolicLink()) throw new Error(`invalid ${label}: must not traverse symlinks`);
		const artifactReal = realpathSync(artifactPath);
		if (!isInside(briefRootReal, artifactReal)) throw new Error(`invalid ${label}: must not escape via symlink or alias`);
	}
}

function validateBriefArtifactPath(value: unknown, itemId: string, label: string): void {
	if (value === undefined || value === null) return;
	validateOptionalNonEmptyString(value, label);
	const path = value as string;
	if (/\p{Cc}/u.test(path)) throw new Error(`invalid ${label}: must not contain control characters`);
	if (!isAbsolute(path)) throw new Error(`invalid ${label}: must be an absolute path under a state-owned plan-briefs directory`);
	if (normalize(path) !== path) throw new Error(`invalid ${label}: must be normalized with no traversal segments`);
	const location = expectedPlanBriefLocation();
	const root = location.briefRoot;
	if (!isInside(root, path)) throw new Error(`invalid ${label}: must be under state-owned plan-briefs root ${root}`);
	const rootRelative = relative(root, path).split(sep).filter(Boolean);
	if (rootRelative.length < 2) throw new Error(`invalid ${label}: must include a plan namespace under the state-owned plan-briefs root`);
	if (basename(path) !== `${itemId}.md`) throw new Error(`invalid ${label}: filename must be ${itemId}.md`);
	assertNoSymlinkEscape(location, path, label);
}

function validateOptionalSha256(value: unknown, label: string): void {
	if (value === undefined || value === null) return;
	if (typeof value !== "string" || !/^sha256:[a-f0-9]{64}$/i.test(value)) throw new Error(`invalid ${label}: must be sha256:<64 hex chars> or null`);
}

function validateRequiredString(value: unknown, label: string): void {
	if (typeof value !== "string" || !value.trim()) throw new Error(`invalid ${label}: must be a non-empty string`);
}

function validateRequiredStringArray(value: unknown, label: string): void {
	if (!Array.isArray(value)) throw new Error(`invalid ${label}: must be an array of strings`);
	for (const [idx, item] of value.entries()) validateEntryId(item, `${label}[${idx}]`);
}

function validateOptionalStringArray(value: unknown, label: string): void {
	if (value === undefined || value === null) return;
	if (!Array.isArray(value)) throw new Error(`invalid ${label}: must be an array of strings or null`);
	for (const [idx, item] of value.entries()) validateRequiredString(item, `${label}[${idx}]`);
}

export function validateTrackedEntryDomain(entry: Pick<TrackedEntry, "domain">): string | undefined {
	const domain = entry.domain;
	if (domain === undefined || domain === null) return undefined;
	if (!isRecord(domain)) throw new Error("must be an object or null");
	for (const key of Object.keys(domain)) {
		if (!DOMAIN_KEYS.has(key)) throw new Error(`unknown domain key ${JSON.stringify(key)} (expected issue, github_issue, or plan_item)`);
	}
	const issue = domain.issue;
	const github = domain.github_issue;
	const planItem = domain.plan_item;
	const presentDomainKeys = [
		["domain.issue", issue],
		["domain.github_issue", github],
		["domain.plan_item", planItem],
	].filter(([, value]) => value !== undefined && value !== null).map(([key]) => key);
	if (presentDomainKeys.length > 1) {
		throw new Error(`${presentDomainKeys.join(", ")} are mutually exclusive`);
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
	if (planItem !== undefined && planItem !== null) {
		if (!isRecord(planItem)) throw new Error("invalid domain.plan_item: must be an object or null");
		validateRequiredString(planItem.plan_path, "domain.plan_item.plan_path");
		validateRequiredString(planItem.plan_title, "domain.plan_item.plan_title");
		validateEntryId(planItem.item_id, "domain.plan_item.item_id");
		validateRequiredString(planItem.item_title, "domain.plan_item.item_title");
		validateRequiredStringArray(planItem.depends_on, "domain.plan_item.depends_on");
		validateRequiredString(planItem.worktree, "domain.plan_item.worktree");
		if (!("pr_number" in planItem)) throw new Error("invalid domain.plan_item.pr_number: missing required key");
		if (!("merge_commit" in planItem)) throw new Error("invalid domain.plan_item.merge_commit: missing required key");
		validateOptionalFiniteNumber(planItem.pr_number, "domain.plan_item.pr_number");
		validateOptionalString(planItem.merge_commit, "domain.plan_item.merge_commit");
		validateOptionalString(planItem.parse_mode, "domain.plan_item.parse_mode");
		validateOptionalSha256(planItem.plan_snapshot_sha256, "domain.plan_item.plan_snapshot_sha256");
		validateBriefArtifactPath(planItem.brief_artifact_path, validateEntryId(planItem.item_id, "domain.plan_item.item_id"), "domain.plan_item.brief_artifact_path");
		validateOptionalSha256(planItem.brief_sha256, "domain.plan_item.brief_sha256");
		if ((planItem.brief_artifact_path === undefined || planItem.brief_artifact_path === null) !== (planItem.brief_sha256 === undefined || planItem.brief_sha256 === null)) {
			throw new Error("invalid domain.plan_item.brief_artifact_path/domain.plan_item.brief_sha256: both keys must be present together or omitted together");
		}
		if (planItem.brief_artifact_path !== undefined && planItem.brief_artifact_path !== null && (planItem.plan_snapshot_sha256 === undefined || planItem.plan_snapshot_sha256 === null)) {
			throw new Error("invalid domain.plan_item.plan_snapshot_sha256: required when brief_artifact_path is present");
		}
		validateOptionalStringArray(planItem.omitted_context, "domain.plan_item.omitted_context");
		validateOptionalFiniteNumber(planItem.scope_files_actual, "domain.plan_item.scope_files_actual");
	}
	return issueId;
}

export function validateDomainIssueId(entry: Pick<TrackedEntry, "domain">): string | undefined {
	return validateTrackedEntryDomain(entry);
}

// Suppress unused-import linter complaint while leaving the type
// re-exported for downstream callers that still import it.
export type { TrackedEntryLaunch };
