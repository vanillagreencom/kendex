import * as fs from "node:fs";
import * as path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { publishSubagentActivity } from "./activity.js";
import { sanitizeCwdSnapshot, sanitizeCwdSnapshotText, snapshotCwdGitState } from "./cwd-snapshot.js";
import { atomicWriteFile, withCrossProcessFileLock } from "./file-lock.js";
import { readLastAssistantTextFromTranscript, stringifyError } from "./format.js";
import { safeFileName } from "./names.js";
import {
	completionArchiveDir,
	completionPath,
	outboxRoot,
	registryPath,
	taskArtifactPaths,
	taskRegistryPath,
	transcriptDir,
} from "./paths.js";
import { randomHex } from "./random.js";
import {
	type DashboardKind,
	type CwdSnapshot,
	MALFORMED_COMPLETION_GRACE_MS,
	PACKAGE_ID,
	type PaneCompletion,
	type PaneCompletionDetails,
	type PaneCompletionMessageDetails,
	type PaneRegistry,
	type PaneRegistryEntry,
	type PaneTaskRecord,
	type PaneTaskRegistry,
	type PaneTaskStatus,
	type UsageStats,
} from "./types.js";

export function normalizedPath(value: string): string {
	return path.normalize(path.resolve(value));
}

export function samePath(left: string | undefined, right: string | undefined): boolean {
	return Boolean(left && right && normalizedPath(left) === normalizedPath(right));
}

export function pathWithin(parentDir: string, childPath: string): boolean {
	const parent = normalizedPath(parentDir);
	const child = normalizedPath(childPath);
	const relative = path.relative(parent, child);
	return relative === "" || Boolean(relative && !relative.startsWith("..") && !path.isAbsolute(relative));
}

export function paneSessionBelongsToRuntime(runtimeRoot: string, entry: PaneRegistryEntry): boolean {
	return pathWithin(path.join(runtimeRoot, "sessions"), entry.sessionFile);
}

export async function readPaneRegistry(runtimeRoot: string): Promise<PaneRegistry> {
	try {
		const content = await fs.promises.readFile(registryPath(runtimeRoot), "utf-8");
		return JSON.parse(content) as PaneRegistry;
	} catch {
		return {};
	}
}

async function atomicWriteJson(filePath: string, data: unknown): Promise<void> {
	await atomicWriteFile(filePath, `${JSON.stringify(data, null, "\t")}\n`);
}

export async function writePaneRegistry(runtimeRoot: string, registry: PaneRegistry): Promise<void> {
	const filePath = registryPath(runtimeRoot);
	await withCrossProcessFileLock(filePath, () => atomicWriteJson(filePath, registry));
}

export async function updatePaneRegistry(
	runtimeRoot: string,
	mutator: (registry: PaneRegistry) => Promise<void> | void,
): Promise<PaneRegistry> {
	const filePath = registryPath(runtimeRoot);
	let registry: PaneRegistry = {};
	await withCrossProcessFileLock(filePath, async () => {
		try {
			const content = await fs.promises.readFile(filePath, "utf-8");
			const parsed = JSON.parse(content);
			registry = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as PaneRegistry) : {};
		} catch {
			registry = {};
		}
		await mutator(registry);
		await atomicWriteJson(filePath, registry);
	});
	return registry;
}

export async function readTaskRegistry(runtimeRoot: string): Promise<PaneTaskRegistry> {
	try {
		const content = await fs.promises.readFile(taskRegistryPath(runtimeRoot), "utf-8");
		const parsed = JSON.parse(content);
		if (Array.isArray(parsed)) {
			return Object.fromEntries(parsed.filter((record) => record?.taskId).map((record) => [record.taskId, record])) as PaneTaskRegistry;
		}
		return parsed && typeof parsed === "object" ? (parsed as PaneTaskRegistry) : {};
	} catch {
		return {};
	}
}

export async function writeTaskRegistry(runtimeRoot: string, records: PaneTaskRegistry): Promise<void> {
	const filePath = taskRegistryPath(runtimeRoot);
	await withCrossProcessFileLock(filePath, () => atomicWriteJson(filePath, records));
}

export async function updateTaskRegistry(runtimeRoot: string, mutator: (records: PaneTaskRegistry) => void): Promise<PaneTaskRegistry> {
	const filePath = taskRegistryPath(runtimeRoot);
	let records: PaneTaskRegistry = {};
	await withCrossProcessFileLock(filePath, async () => {
		try {
			const content = await fs.promises.readFile(filePath, "utf-8");
			const parsed = JSON.parse(content);
			records = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as PaneTaskRegistry) : {};
		} catch {
			records = {};
		}
		mutator(records);
		await atomicWriteJson(filePath, records);
	});
	return records;
}

export async function upsertTaskRecord(runtimeRoot: string, record: PaneTaskRecord): Promise<void> {
	await updateTaskRegistry(runtimeRoot, (records) => {
		records[record.taskId] = { ...records[record.taskId], ...record };
	});
}

export function normalizePaneTaskStatus(status: unknown): PaneTaskStatus {
	return status === "queued" || status === "running" || status === "completed" || status === "blocked" || status === "failed" || status === "needs_completion"
		? status
		: "unknown";
}

export function isTerminalTaskStatus(status: PaneTaskStatus | undefined): boolean {
	return status === "completed" || status === "blocked" || status === "failed";
}

export function inferTaskRecordKind(runtimeRoot: string, record: PaneTaskRecord): DashboardKind {
	if (record.transcriptPath && pathWithin(transcriptDir(runtimeRoot), record.transcriptPath)) return "oneshot";
	if (record.kind === "pane" || record.kind === "oneshot") return record.kind;
	if (record.paneId || record.inboxFile || record.processingFile || record.doneFile || record.completionSourcePath || record.completionArchivePath) return "pane";
	if (record.outboxFile) return "pane";
	return "oneshot";
}

function sanitizedBgTaskRecord(record: PaneTaskRecord): PaneTaskRecord {
	const {
		paneId: _paneId,
		inboxFile: _inboxFile,
		processingFile: _processingFile,
		doneFile: _doneFile,
		outboxFile: _outboxFile,
		completionSourcePath: _completionSourcePath,
		completionArchivePath: _completionArchivePath,
		...rest
	} = record;
	return { ...rest, kind: "oneshot" };
}

export function normalizeUsageStats(value: unknown): UsageStats | undefined {
	if (!value || typeof value !== "object") return undefined;
	const raw = value as Partial<Record<keyof UsageStats, unknown>>;
	const usage: UsageStats = {
		input: Number(raw.input) || 0,
		output: Number(raw.output) || 0,
		cacheRead: Number(raw.cacheRead) || 0,
		cacheWrite: Number(raw.cacheWrite) || 0,
		cost: Number(raw.cost) || 0,
		contextTokens: Number(raw.contextTokens) || 0,
		turns: Number(raw.turns) || 0,
	};
	return usage.input || usage.output || usage.cacheRead || usage.cacheWrite || usage.cost || usage.contextTokens || usage.turns ? usage : undefined;
}

export function appendUniqueDiagnostic(existing: string[] | undefined, diagnostic: string): string[] {
	const compact = sanitizeCwdSnapshotText(diagnostic, { multiline: true }).replace(/\s+/g, " ").trim();
	if (!compact) return existing ?? [];
	const diagnostics = [...(existing ?? [])];
	if (!diagnostics.includes(compact)) diagnostics.push(compact);
	return diagnostics.slice(-8);
}

function appendUniqueDiagnostics(existing: string[] | undefined, diagnostics: string[]): string[] | undefined {
	let next = existing;
	for (const diagnostic of diagnostics) next = appendUniqueDiagnostic(next, diagnostic);
	return next;
}

function mergeNeedsCompletionCwdState(record: PaneTaskRecord, cwdState: { cwdSnapshot?: CwdSnapshot; diagnostics: string[] }): Pick<PaneTaskRecord, "cwdSnapshot" | "diagnostics"> {
	return {
		cwdSnapshot: cwdState.cwdSnapshot ?? sanitizeCwdSnapshot(record.cwdSnapshot),
		diagnostics: appendUniqueDiagnostics(record.diagnostics, cwdState.diagnostics),
	};
}

async function snapshotNeedsCompletionCwd(
	runtimeRoot: string,
	agentName: string,
	cwd: string | undefined,
): Promise<{ cwdSnapshot?: CwdSnapshot; diagnostics: string[] }> {
	let snapshotCwd = typeof cwd === "string" ? cwd : undefined;
	if (!snapshotCwd) {
		try {
			const registry = await readPaneRegistry(runtimeRoot);
			const registryCwd = registry[agentName]?.cwd;
			if (typeof registryCwd === "string") snapshotCwd = registryCwd;
		} catch {
			// Missing/invalid pane registry just means there is no cwd signal to attach.
		}
	}
	const diagnostics: string[] = [];
	try {
		const cwdSnapshot = await snapshotCwdGitState(snapshotCwd, (diagnostic) => diagnostics.push(sanitizeCwdSnapshotText(diagnostic)));
		return { cwdSnapshot, diagnostics };
	} catch (error) {
		diagnostics.push(sanitizeCwdSnapshotText(`cwdSnapshot failed for ${agentName}: ${stringifyError(error)}`));
		return { diagnostics };
	}
}

async function patchNeedsCompletionCwdSnapshot(
	runtimeRoot: string,
	agentName: string,
	taskId: string,
	cwd?: string,
): Promise<PaneTaskRecord | undefined> {
	try {
		const cwdState = await snapshotNeedsCompletionCwd(runtimeRoot, agentName, cwd);
		let updated: PaneTaskRecord | undefined;
		if (!cwdState.cwdSnapshot && cwdState.diagnostics.length === 0) {
			const records = await readTaskRegistry(runtimeRoot);
			return records[taskId];
		}
		await updateTaskRegistry(runtimeRoot, (records) => {
			const existing = records[taskId];
			if (!existing || existing.status !== "needs_completion") {
				updated = existing;
				return;
			}
			const cwdPatch = mergeNeedsCompletionCwdState(existing, cwdState);
			updated = {
				...existing,
				...cwdPatch,
				updatedAt: new Date().toISOString(),
			};
			records[taskId] = updated;
		});
		return updated;
	} catch (error) {
		return await appendNeedsCompletionCwdPatchFailure(runtimeRoot, taskId, agentName, error);
	}
}

async function appendNeedsCompletionCwdPatchFailure(
	runtimeRoot: string,
	taskId: string,
	agentName: string,
	patchError: unknown,
): Promise<PaneTaskRecord | undefined> {
	let updated: PaneTaskRecord | undefined;
	try {
		await updateTaskRegistry(runtimeRoot, (records) => {
			const existing = records[taskId];
			if (!existing || existing.status !== "needs_completion") {
				updated = existing;
				return;
			}
			updated = {
				...existing,
				diagnostics: appendUniqueDiagnostic(existing.diagnostics, `cwdSnapshot patch failed for ${agentName}: ${stringifyError(patchError)}`),
				cwdSnapshot: sanitizeCwdSnapshot(existing.cwdSnapshot),
				updatedAt: new Date().toISOString(),
			};
			records[taskId] = updated;
		});
	} catch (fallbackWriteError) {
		await recordCwdPatchFallbackWriteFailure(runtimeRoot, agentName, taskId, patchError, fallbackWriteError);
		return undefined;
	}
	return updated;
}

async function recordCwdPatchFallbackWriteFailure(
	runtimeRoot: string,
	agentName: string,
	taskId: string,
	patchError: unknown,
	fallbackWriteError: unknown,
): Promise<void> {
	const message = `cwdSnapshot patch failure diagnostic could not be persisted for agent=${agentName} taskId=${taskId} runtimeRoot=${runtimeRoot}: fallback write failed: ${stringifyError(fallbackWriteError)}; original patch error: ${stringifyError(patchError)}`;
	console.warn(message);
	const logFile = path.join(runtimeRoot, "subagent-diagnostics.jsonl");
	const entry = {
		ts: new Date().toISOString(),
		source: "subagent.tasks.cwdSnapshot",
		runtimeRoot,
		agentName,
		taskId,
		message,
		patchError: stringifyError(patchError),
		fallbackWriteError: stringifyError(fallbackWriteError),
	};
	try {
		await fs.promises.appendFile(logFile, `${JSON.stringify(entry)}\n`, { encoding: "utf-8", mode: 0o600 });
	} catch {
		// Console warning above is the last-resort diagnostic if the runtime log cannot be written.
	}
}

function scheduleNeedsCompletionCwdSnapshotPatch(runtimeRoot: string, agentName: string, taskId: string, cwd?: string): void {
	void patchNeedsCompletionCwdSnapshot(runtimeRoot, agentName, taskId, cwd).catch(async (error) => {
		await appendNeedsCompletionCwdPatchFailure(runtimeRoot, taskId, agentName, error);
	});
}

export function taskNeedsSummaryBackfill(record: PaneTaskRecord): boolean {
	return isTerminalTaskStatus(record.status) && !record.summary?.trim() && Boolean(record.transcriptPath);
}

function hasBlankSummaryField(record: PaneTaskRecord): boolean {
	if (!Object.prototype.hasOwnProperty.call(record, "summary")) return false;
	const value = (record as { summary?: unknown }).summary;
	return value === null || value === undefined || (typeof value === "string" && value.trim() === "");
}

function omitSummary(record: PaneTaskRecord): PaneTaskRecord {
	const { summary: _summary, ...rest } = record;
	return rest;
}

export async function backfillTaskSummaryFromTranscript(
	runtimeRoot: string,
	record: PaneTaskRecord,
	options: { timeoutMs?: number; maxBytes?: number } = {},
): Promise<{ diagnostic?: string; record: PaneTaskRecord; updated: boolean }> {
	if (!taskNeedsSummaryBackfill(record)) return { record, updated: false };
	let summary: string | undefined;
	try {
		summary = await readLastAssistantTextFromTranscript(record.transcriptPath, { timeoutMs: options.timeoutMs ?? 5_000, maxBytes: options.maxBytes });
	} catch {
		return { record, updated: false };
	}
	if (!summary) {
		if (!hasBlankSummaryField(record)) return { record, updated: false };
		let updated = omitSummary(record);
		await updateTaskRegistry(runtimeRoot, (records) => {
			const existing = records[record.taskId] ?? record;
			if (!hasBlankSummaryField(existing)) {
				updated = existing;
				return;
			}
			updated = { ...omitSummary(existing), updatedAt: new Date().toISOString() };
			records[record.taskId] = updated;
		});
		return { record: updated, updated: updated.summary === undefined };
	}
	let updated = record;
	await updateTaskRegistry(runtimeRoot, (records) => {
		const existing = records[record.taskId] ?? record;
		if (existing.summary?.trim()) {
			updated = existing;
			return;
		}
		updated = {
			...existing,
			summary,
			updatedAt: new Date().toISOString(),
		};
		records[record.taskId] = updated;
	});
	return { record: updated, updated: updated.summary === summary };
}

export function completionParseErrorMessage(filePath: string, error: unknown): string {
	return `Malformed completion JSON at ${filePath}: ${stringifyError(error)}. Replace it with one valid completion object or call complete_subagent again.`;
}

export async function fileExists(filePath: string | undefined): Promise<boolean> {
	if (!filePath) return false;
	try {
		await fs.promises.access(filePath, fs.constants.F_OK);
		return true;
	} catch {
		return false;
	}
}

export async function readPaneCompletionFile(filePath: string): Promise<{ completion?: PaneCompletion; error?: unknown; exists: boolean }> {
	let raw: string;
	try {
		raw = await fs.promises.readFile(filePath, "utf-8");
	} catch (error) {
		const code = typeof error === "object" && error && "code" in error ? (error as { code?: unknown }).code : undefined;
		if (code === "ENOENT") return { exists: false };
		return { error, exists: true };
	}
	try {
		const parsed = JSON.parse(raw);
		if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("completion must be a JSON object");
		return { completion: parsed as PaneCompletion, exists: true };
	} catch (error) {
		return { error, exists: true };
	}
}

export async function markTaskNeedsCompletion(
	runtimeRoot: string,
	agentName: string,
	taskId: string,
	options: {
		cwd?: string;
		diagnostic: string;
		doneFile?: string;
		outboxFile?: string;
		processingFile?: string;
		transcriptPath?: string;
	},
): Promise<PaneTaskRecord | undefined> {
	let updated: PaneTaskRecord | undefined;
	const now = new Date().toISOString();
	await updateTaskRegistry(runtimeRoot, (records) => {
		const existing = records[taskId];
		if (isTerminalTaskStatus(existing?.status)) {
			updated = existing;
			return;
		}
		const outboxFile = options.outboxFile ?? existing?.outboxFile ?? completionPath(runtimeRoot, agentName, taskId);
		updated = {
			...existing,
			taskId,
			agent: existing?.agent ?? agentName,
			task: existing?.task ?? "",
			status: "needs_completion",
			kind: "pane",
			inboxFile: existing?.inboxFile,
			processingFile: options.processingFile ?? existing?.processingFile,
			doneFile: options.doneFile ?? existing?.doneFile,
			outboxFile,
			transcriptPath: options.transcriptPath ?? existing?.transcriptPath,
			createdAt: existing?.createdAt ?? now,
			updatedAt: now,
			diagnostics: appendUniqueDiagnostic(existing?.diagnostics, options.diagnostic),
			cwdSnapshot: sanitizeCwdSnapshot(existing?.cwdSnapshot),
		};
		records[taskId] = updated;
	});
	if (!updated || isTerminalTaskStatus(updated.status)) return updated;
	scheduleNeedsCompletionCwdSnapshotPatch(runtimeRoot, updated.agent, taskId, options.cwd);
	return updated;
}

export async function recordTaskDispatchFailure(
	runtimeRoot: string,
	taskId: string,
	paths: { source: string; processing: string },
	diagnostic: string,
): Promise<{ restoredToInbox: boolean; status?: PaneTaskStatus }> {
	let restoredToInbox = false;
	try {
		await fs.promises.rename(paths.processing, paths.source);
		restoredToInbox = true;
	} catch {
		// Keep the processing artifact for inspection when it cannot be safely restored.
	}

	let status: PaneTaskStatus | undefined;
	let agentForSnapshot: string | undefined;
	await updateTaskRegistry(runtimeRoot, (records) => {
		const existing = records[taskId];
		if (!existing || isTerminalTaskStatus(existing.status)) return;
		status = restoredToInbox ? "queued" : "needs_completion";
		agentForSnapshot = existing.agent;
		records[taskId] = {
			...existing,
			status,
			inboxFile: restoredToInbox ? paths.source : existing.inboxFile,
			processingFile: restoredToInbox ? undefined : paths.processing,
			updatedAt: new Date().toISOString(),
			diagnostics: appendUniqueDiagnostic(existing.diagnostics, diagnostic),
			cwdSnapshot: sanitizeCwdSnapshot(existing.cwdSnapshot),
		};
	});
	if (status === "needs_completion" && agentForSnapshot) await patchNeedsCompletionCwdSnapshot(runtimeRoot, agentForSnapshot, taskId);

	return { restoredToInbox, status };
}

export async function refreshTaskDiagnostics(runtimeRoot: string, record: PaneTaskRecord): Promise<{ record: PaneTaskRecord; diagnostics: string[] }> {
	if (inferTaskRecordKind(runtimeRoot, record) !== "pane") {
		const sanitized = sanitizedBgTaskRecord(record);
		const changed = JSON.stringify(sanitized) !== JSON.stringify(record);
		if (changed) {
			await updateTaskRegistry(runtimeRoot, (records) => {
				records[record.taskId] = sanitized;
			});
		}
		return { record: sanitized, diagnostics: record.diagnostics ?? [] };
	}

	const paths = taskArtifactPaths(runtimeRoot, record);
	const [inboxExists, processingExists, doneExists, outboxExists, archiveExists, transcriptExists] = await Promise.all([
		fileExists(paths.inboxFile),
		fileExists(paths.processingFile),
		fileExists(paths.doneFile),
		fileExists(paths.outboxFile),
		fileExists(paths.completionArchivePath),
		fileExists(paths.transcriptPath),
	]);

	let nextStatus = record.status;
	let diagnostics = [...(record.diagnostics ?? [])];
	const add = (message: string) => {
		diagnostics = appendUniqueDiagnostic(diagnostics, message);
	};

	if (!isTerminalTaskStatus(record.status)) {
		if (processingExists && record.status === "queued") {
			nextStatus = "running";
			add(`Task file was claimed by the child pane: ${paths.processingFile}`);
		}
		if (doneExists && !outboxExists && !archiveExists) {
			nextStatus = "needs_completion";
			add(`Task turn ended but no completion record was found. Expected outbox: ${paths.outboxFile}`);
		}
		if (outboxExists) {
			const parsed = await readPaneCompletionFile(paths.outboxFile);
			if (parsed.error) {
				nextStatus = "needs_completion";
				add(completionParseErrorMessage(paths.outboxFile, parsed.error));
			}
		}
		if (!inboxExists && !processingExists && !doneExists && !outboxExists && !archiveExists) {
			// Bridge-delivered follow-up tasks (created without an inbox file) legitimately have no
			// on-disk artifacts until the child writes its outbox. Only treat the missing-artifact
			// state as a lost task when the record was originally inbox-queued.
			if (record.inboxFile && (record.status === "queued" || record.status === "running")) {
				nextStatus = "unknown";
				add(`No task handoff or completion artifacts are present for ${record.taskId}; the pane may have been reset or the runtime was cleaned.`);
			}
		}
	}

	const artifactDiagnostics = [
		`Expected outbox: ${paths.outboxFile} (${outboxExists ? "present" : "missing"})`,
		`Inbox file: ${paths.inboxFile} (${inboxExists ? "present" : "missing"})`,
		`Processing file: ${paths.processingFile} (${processingExists ? "present" : "missing"})`,
		`Done file: ${paths.doneFile} (${doneExists ? "present" : "missing"})`,
		paths.completionArchivePath ? `Archived completion: ${paths.completionArchivePath} (${archiveExists ? "present" : "missing"})` : "Archived completion: (none recorded)",
		paths.transcriptPath ? `Transcript: ${paths.transcriptPath} (${transcriptExists ? "present" : "missing"})` : "Transcript: (none recorded)",
	];

	const pathPatch = {
		inboxFile: record.inboxFile ?? paths.inboxFile,
		processingFile: record.processingFile ?? (processingExists ? paths.processingFile : undefined),
		doneFile: record.doneFile ?? (doneExists ? paths.doneFile : undefined),
		outboxFile: record.outboxFile ?? paths.outboxFile,
	};
	let cwdSnapshot = sanitizeCwdSnapshot(record.cwdSnapshot);
	const shouldPatchCwdSnapshot = nextStatus === "needs_completion" && (!cwdSnapshot || nextStatus !== record.status);
	const changed =
		nextStatus !== record.status ||
		diagnostics.join("\n") !== (record.diagnostics ?? []).join("\n") ||
		JSON.stringify(cwdSnapshot) !== JSON.stringify(record.cwdSnapshot) ||
		pathPatch.inboxFile !== record.inboxFile ||
		pathPatch.processingFile !== record.processingFile ||
		pathPatch.doneFile !== record.doneFile ||
		pathPatch.outboxFile !== record.outboxFile;

	if (!changed) {
		const patched = shouldPatchCwdSnapshot ? await patchNeedsCompletionCwdSnapshot(runtimeRoot, record.agent, record.taskId) : undefined;
		return { record: patched ?? record, diagnostics: [...(patched?.diagnostics ?? diagnostics), ...artifactDiagnostics] };
	}

	let updated = record;
	await updateTaskRegistry(runtimeRoot, (records) => {
		const existing = records[record.taskId] ?? record;
		updated = {
			...existing,
			...pathPatch,
			status: nextStatus,
			diagnostics,
			cwdSnapshot,
			updatedAt: new Date().toISOString(),
		};
		records[record.taskId] = updated;
	});
	if (shouldPatchCwdSnapshot) updated = await patchNeedsCompletionCwdSnapshot(runtimeRoot, updated.agent, updated.taskId) ?? updated;
	return { record: updated, diagnostics: [...(updated.diagnostics ?? diagnostics), ...artifactDiagnostics] };
}

export function latestTaskRecord(records: PaneTaskRegistry, agent?: string): PaneTaskRecord | undefined {
	return Object.values(records)
		.filter((record) => !agent || record.agent === agent)
		.sort((a, b) => (b.updatedAt ?? b.completedAt ?? b.createdAt).localeCompare(a.updatedAt ?? a.completedAt ?? a.createdAt))[0];
}

export function tryEmitSubagentEvent(pi: ExtensionAPI, event: string, payload: Record<string, unknown>): { error?: string; ok: boolean } {
	let errorText: string | undefined;
	try {
		const bus = (pi as unknown as { events?: { emit?: (name: string, payload: unknown) => void } }).events;
		bus?.emit?.(event, {
			package: PACKAGE_ID,
			...payload,
			timestamp: new Date().toISOString(),
		});
	} catch (error) {
		errorText = stringifyError(error);
	}
	publishSubagentActivity(event, payload);
	return errorText ? { error: errorText, ok: false } : { ok: true };
}

export function emitSubagentEvent(pi: ExtensionAPI, event: string, payload: Record<string, unknown>): void {
	try {
		tryEmitSubagentEvent(pi, event, payload);
	} catch {
		// Lifecycle events are best-effort extension integration signals.
	}
}

export async function archiveCompletion(runtimeRoot: string, agentName: string, filePath: string): Promise<string> {
	const archiveDir = completionArchiveDir(runtimeRoot, agentName);
	await fs.promises.mkdir(archiveDir, { recursive: true, mode: 0o700 });
	const archivedPath = path.join(archiveDir, `${Date.now()}-${path.basename(filePath)}`);
	await fs.promises.rename(filePath, archivedPath);
	return archivedPath;
}

export function paneCompletionDetailsFromCompletion(
	completion: PaneCompletion,
	agentDirName: string,
	filePath: string,
	archivePath: string | undefined,
	registry: PaneRegistry,
	tasks: PaneTaskRegistry,
): PaneCompletionDetails {
	const agent = completion.agent || agentDirName;
	const taskId = completion.taskId || path.basename(filePath, path.extname(filePath));
	const record = tasks[taskId];
	return {
		agent,
		taskId,
		status: normalizePaneTaskStatus(completion.status),
		summary: completion.summary || "No summary provided.",
		filesChanged: Array.isArray(completion.filesChanged) ? completion.filesChanged : [],
		validation: Array.isArray(completion.validation) ? completion.validation : [],
		notes: completion.notes,
		sourcePath: filePath,
		archivePath,
		transcriptPath: record?.transcriptPath ?? registry[agent]?.sessionFile,
		completedAt: new Date().toISOString(),
		paneId: record?.paneId ?? registry[agent]?.paneId,
	};
}

export function formatCompletionDetails(detail: PaneCompletionDetails): string {
	const files = detail.filesChanged.length ? detail.filesChanged.map((file) => `- ${file}`).join("\n") : "None reported";
	const validation = detail.validation.length ? detail.validation.map((item) => `- ${item}`).join("\n") : "None reported";
	return [
		`# Agent completion: ${detail.agent}`,
		`Task ID: ${detail.taskId}`,
		`Status: ${detail.status}`,
		`Source: ${detail.sourcePath}`,
		detail.archivePath ? `Archive: ${detail.archivePath}` : "",
		detail.transcriptPath ? `Transcript: ${detail.transcriptPath}` : "",
		"",
		"## Summary",
		detail.summary,
		"",
		"## Files Changed",
		files,
		"",
		"## Validation",
		validation,
		detail.notes ? `\n## Notes\n${detail.notes}` : "",
	]
		.filter(Boolean)
		.join("\n");
}

export function formatCompletionGroup(completions: PaneCompletionDetails[]): string {
	if (completions.length === 1) return formatCompletionDetails(completions[0]);
	return [`# Agent completions (${completions.length})`, "", ...completions.map(formatCompletionDetails)].join("\n\n---\n\n");
}

const paneCompletionPollLocks = new Set<string>();
const emittedPaneCompletionKeys = new Set<string>();

export function paneCompletionDedupKey(runtimeRoot: string, agent: string, taskId: string): string {
	return `${normalizedPath(runtimeRoot)}\0${agent}\0${taskId}`;
}

export async function pollPaneCompletions(runtimeRoot: string, pi: ExtensionAPI, triggerTurn = false): Promise<number> {
	const lockKey = normalizedPath(runtimeRoot);
	if (paneCompletionPollLocks.has(lockKey)) return 0;
	paneCompletionPollLocks.add(lockKey);
	try {
		return await pollPaneCompletionsUnlocked(runtimeRoot, pi, triggerTurn);
	} finally {
		paneCompletionPollLocks.delete(lockKey);
	}
}

async function pollPaneCompletionsUnlocked(runtimeRoot: string, pi: ExtensionAPI, triggerTurn = false): Promise<number> {
	const root = outboxRoot(runtimeRoot);
	let agentDirs: fs.Dirent[];
	try {
		agentDirs = await fs.promises.readdir(root, { withFileTypes: true });
	} catch {
		return 0;
	}

	const registry = await readPaneRegistry(runtimeRoot);
	let tasks = await readTaskRegistry(runtimeRoot);
	const completions: PaneCompletionDetails[] = [];

	for (const agentDir of agentDirs) {
		if (!agentDir.isDirectory()) continue;
		const dir = path.join(root, agentDir.name);
		let files: string[];
		try {
			files = (await fs.promises.readdir(dir)).filter((file) => file.endsWith(".json")).sort();
		} catch {
			continue;
		}

		for (const file of files) {
			const filePath = path.join(dir, file);
			let parseFailure = false;
			try {
				const parsed = await readPaneCompletionFile(filePath);
				if (parsed.error) {
					parseFailure = true;
					throw parsed.error;
				}
				if (!parsed.completion) continue;
				const completion = parsed.completion;
				const agentName = completion.agent || agentDir.name;
				const taskId = completion.taskId || path.basename(filePath, path.extname(filePath));
				const dedupKey = paneCompletionDedupKey(runtimeRoot, agentName, taskId);
				const existing = tasks[taskId];
				const alreadyEmitted = emittedPaneCompletionKeys.has(dedupKey)
					|| Boolean(existing && existing.agent === agentName && isTerminalTaskStatus(existing.status) && (existing.completedAt || existing.completionArchivePath));
				const archivePath = await archiveCompletion(runtimeRoot, agentName, filePath);
				if (alreadyEmitted) continue;
				const detail = paneCompletionDetailsFromCompletion(completion, agentDir.name, filePath, archivePath, registry, tasks);
				completions.push(detail);
				emittedPaneCompletionKeys.add(dedupKey);
				tasks = await updateTaskRegistry(runtimeRoot, (records) => {
					const existing = records[detail.taskId];
					records[detail.taskId] = {
						...existing,
						taskId: detail.taskId,
						agent: detail.agent,
						task: existing?.task ?? "",
						createdAt: existing?.createdAt ?? detail.completedAt,
						status: detail.status,
						kind: "pane",
						paneId: detail.paneId,
						completionSourcePath: detail.sourcePath,
						completionArchivePath: detail.archivePath,
						transcriptPath: detail.transcriptPath,
						summary: detail.summary,
						filesChanged: detail.filesChanged,
						validation: detail.validation,
						notes: detail.notes,
						cwdSnapshot: sanitizeCwdSnapshot(existing?.cwdSnapshot),
						diagnostics: existing?.diagnostics,
						updatedAt: detail.completedAt,
						completedAt: detail.completedAt,
					};
				});
				const updatedRecord = tasks[detail.taskId];
				const completionEvent = detail.status === "completed"
					? "subagents:completed"
					: detail.status === "needs_completion"
						? "subagents:needs_completion"
						: "subagents:failed";
				emitSubagentEvent(pi, completionEvent, {
					mode: "pane",
					agent: detail.agent,
					paneId: detail.paneId,
					taskId: detail.taskId,
					status: detail.status,
					reason: completion.reason,
					summary: detail.summary,
					runtimeRoot,
					transcriptPath: detail.transcriptPath,
					completionPath: detail.archivePath ?? detail.sourcePath,
					...(updatedRecord?.cwdSnapshot ? { cwdSnapshot: updatedRecord.cwdSnapshot } : {}),
				});
				if (detail.status === "needs_completion") {
					const patchedRecord = await patchNeedsCompletionCwdSnapshot(runtimeRoot, detail.agent, detail.taskId);
					if (patchedRecord) tasks = { ...tasks, [detail.taskId]: patchedRecord };
					if (patchedRecord?.cwdSnapshot || patchedRecord?.diagnostics?.length) {
						emitSubagentEvent(pi, "subagents:needs_completion", {
							mode: "pane",
							agent: detail.agent,
							paneId: detail.paneId,
							taskId: detail.taskId,
							status: detail.status,
							reason: completion.reason,
							summary: detail.summary,
							runtimeRoot,
							transcriptPath: detail.transcriptPath,
							completionPath: detail.archivePath ?? detail.sourcePath,
							diagnostics: patchedRecord.diagnostics,
							...(patchedRecord.cwdSnapshot ? { cwdSnapshot: patchedRecord.cwdSnapshot } : {}),
						});
					}
				}
			} catch (error) {
				const code = typeof error === "object" && error && "code" in error ? (error as { code?: unknown }).code : undefined;
				if (!parseFailure && code === "ENOENT") continue;
				let oldEnough = true;
				try {
					const stat = await fs.promises.stat(filePath);
					oldEnough = Date.now() - stat.mtimeMs >= MALFORMED_COMPLETION_GRACE_MS;
				} catch {
					oldEnough = true;
				}
				if (!oldEnough) continue;
				const taskId = path.basename(filePath, path.extname(filePath));
				const diagnostic = parseFailure
					? completionParseErrorMessage(filePath, error)
					: `Unable to collect completion JSON at ${filePath}: ${stringifyError(error)}. The file was left in place for retry.`;
				const updated = await markTaskNeedsCompletion(runtimeRoot, agentDir.name, taskId, {
					diagnostic,
					outboxFile: filePath,
					transcriptPath: registry[agentDir.name]?.sessionFile,
				});
				if (updated) {
					tasks = { ...tasks, [taskId]: updated };
					emitSubagentEvent(pi, "subagents:needs_completion", {
						mode: "pane",
						agent: updated.agent,
						paneId: updated.paneId ?? registry[updated.agent]?.paneId,
						taskId,
						status: "needs_completion",
						summary: diagnostic,
						runtimeRoot,
						transcriptPath: updated.transcriptPath,
						completionPath: filePath,
						...(updated.cwdSnapshot ? { cwdSnapshot: updated.cwdSnapshot } : {}),
					});
				}
			}
		}
	}

	if (completions.length > 0) {
		const content = formatCompletionGroup(completions);
		pi.sendMessage(
			{ customType: "subagent-completion", content, details: { completions } as PaneCompletionMessageDetails, display: true },
			triggerTurn ? { triggerTurn: true, deliverAs: "followUp" } : undefined,
		);
	}
	return completions.length;
}

export function createTaskId(agentName: string): string {
	return `${safeFileName(agentName)}-${Date.now()}-${randomHex(8)}`;
}

export function normalizedTaskForDedup(task: string): string {
	return task.replace(/\s+/g, " ").trim();
}
