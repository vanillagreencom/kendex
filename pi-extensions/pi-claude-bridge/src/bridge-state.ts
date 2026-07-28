import { type ExtensionAPI, type ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { debug, diagDump, diagLogPath } from "./debug.js";
import { type QueryContext } from "./query-state.js";
import { summarizeMissingToolNames, type MissingToolResult } from "./tool-pairing-audit.js";

export interface SessionState {
	sessionId: string;
	cursor: number;
	cwd: string;
	// Force the next syncSharedSession call down the REBUILD path. Set when
	// pi has mutated its messages array out from under us (compact, tree
	// navigation) or after an abort left the JSONL in an indeterminate state.
	// REBUILD wipes and rewrites the file to match pi's current history.
	needsRebuild?: boolean;
	// Set ONLY after an abort. The killed CC subprocess may still be flushing
	// a late "[Request interrupted by user]" record to the session JSONL.
	// Reusing the same sessionId/path would race that orphan write into our
	// fresh file and break CC's parent-uuid chain on the next resume. When
	// this flag is set, REBUILD takes a fresh UUID and skips deleteSession
	// so the orphan writes land on a dead inode. Compact/tree do NOT set
	// this — there's no concurrent CC writer during those events, so
	// in-place rebuild (preserve UUID, deleteSession + createSession) is safe.
	forceRotate?: boolean;
}

// Shared mutable bridge state. Lives in its own module so the extracted
// modules and index.ts observe the SAME state: ESM live bindings let every
// importer READ these `let` bindings live, but only this module may assign
// them — cross-module writes must go through the setters below.
export let sharedSession: SessionState | null = null;
export let extensionApi: ExtensionAPI | undefined;
export let piUI: ExtensionUIContext | undefined;

export function setSharedSession(next: SessionState | null): void {
	sharedSession = next;
}

export function setExtensionApi(next: ExtensionAPI | undefined): void {
	extensionApi = next;
}

export function setPiUI(next: ExtensionUIContext | undefined): void {
	piUI = next;
}

export function safeNotify(message: string, level: "info" | "warning" | "error" = "warning"): void {
	try { piUI?.notify(message, level); }
	catch (error) { debug("notify failed:", error); }
}

export function argKeys(args: Record<string, unknown> | undefined): string[] {
	return Object.keys(args ?? {}).sort();
}

export function safeToolCallSummary(calls: Array<{ id: string; toolName: string; arguments?: Record<string, unknown> }>): Array<{ id: string; toolName: string; argKeys: string[] }> {
	return calls.map((call) => ({ id: call.id, toolName: call.toolName, argKeys: argKeys(call.arguments) }));
}

export const INTEGRITY_CUSTOM_TYPE = "claude-bridge-integrity";

/**
 * Persist a bridge integrity event into the pi session transcript.
 *
 * The diag log and a piUI toast both die with the machine or the render cycle:
 * the 2026-07-28 post-mortem found `Error: Claude bridge: …` messages that were
 * SHOWN but existed nowhere in the pi session file, making analysis from the
 * session alone impossible. A `CustomEntry` closes that gap the same way the
 * connector-call audit does — persisted, never part of built context, never
 * dispatchable by pi's agent loop. Payloads must stay compact metadata (ids,
 * counts, tool names), never tool output.
 *
 * Never throws; returns whether the entry was appended (false outside a pi
 * session — tests, embedded hosts without extensionApi).
 */
export function appendIntegrityEntry(label: string, data: Record<string, unknown>): boolean {
	try {
		if (!extensionApi) return false;
		extensionApi.appendEntry(INTEGRITY_CUSTOM_TYPE, { label, at: new Date().toISOString(), ...data });
		return true;
	} catch (error) {
		debug("appendIntegrityEntry failed:", error);
		return false;
	}
}

function compactToolNameSummary(names: Array<{ name: string; count: number }>, limit = 12): string[] {
	const shown = names.slice(0, limit).map(({ name, count }) => count > 1 ? `${name}×${count}` : name);
	if (names.length > limit) shown.push(`+${names.length - limit} more`);
	return shown;
}

export function reportSyntheticToolResultRepair(missing: MissingToolResult[], context: Record<string, unknown>): void {
	try {
		if (missing.length === 0) return;
		const toolNames = summarizeMissingToolNames(missing);
		const toolNameSummary = compactToolNameSummary(toolNames);
		const sampledToolCallIds = missing.slice(0, 50).map((item) => item.id);
		diagDump("repair_tool_pairing_synthetic_results", {
			count: missing.length,
			toolNames,
			sampledToolCallIds,
			missing: missing.slice(0, 50),
			...context,
		});
		appendIntegrityEntry("repair_tool_pairing_synthetic_results", {
			count: missing.length,
			toolNames,
			sampledToolCallIds: sampledToolCallIds.slice(0, 12),
		});
		safeNotify(
			`Claude bridge: ${missing.length} missing tool result(s) repaired with an explicit error placeholder` +
			`${toolNameSummary.length ? ` for ${toolNameSummary.join(", ")}` : ""}. ` +
			`Real tool output was lost before Claude session import; see ${diagLogPath()}.`,
			"error",
		);
	} catch (error) {
		debug("reportSyntheticToolResultRepair failed:", error);
	}
}

export function reportToolResultMismatch(queryCtx: QueryContext, reason: string, cwd: string | undefined, opts: { forceRotate?: boolean } = {}): boolean {
	try {
		if (queryCtx.reportedToolResultMismatch) return false;
		const progress = queryCtx.toolResultProgress();
		const hasMismatch = progress.expectedCount > 0
			? progress.unresolvedIds.length > 0 || progress.waitingCount > 0 || progress.queuedCount > 0 || progress.unmatchedResultCount > 0
			: progress.waitingCount > 0 || progress.queuedCount > 0 || progress.unmatchedResultCount > 0;
		if (!hasMismatch) return false;
		queryCtx.reportedToolResultMismatch = true;
		if (sharedSession) {
			sharedSession = { ...sharedSession, needsRebuild: true, ...(opts.forceRotate ? { forceRotate: true } : {}) };
		}
		const toolNameSummary = compactToolNameSummary(progress.toolNames);
		diagDump("tool_result_delivery_mismatch", {
			reason,
			cwd,
			progress,
			activeQueryExists: queryCtx.activeQuery !== null,
			sharedSession: sharedSession ? {
				sessionId: sharedSession.sessionId.slice(0, 8),
				cursor: sharedSession.cursor,
				needsRebuild: sharedSession.needsRebuild === true,
				forceRotate: sharedSession.forceRotate === true,
			} : null,
		});
		appendIntegrityEntry("tool_result_delivery_mismatch", {
			reason,
			toolNames: progress.toolNames,
			expectedCount: progress.expectedCount,
			deliveredCount: progress.deliveredCount,
			resolvedCount: progress.resolvedCount,
			waitingIds: progress.waitingIds,
			queuedIds: progress.queuedIds,
			unmatchedResultIds: progress.unmatchedResultIds,
		});
		safeNotify(
			`Claude bridge: tool result delivery interrupted during ${reason}; ` +
			`delivered ${progress.deliveredCount}/${progress.expectedCount}, resolved ${progress.resolvedCount}/${progress.expectedCount}, ` +
			`waiting=${progress.waitingCount}, queued=${progress.queuedCount}, unmatched=${progress.unmatchedResultCount}` +
			`${toolNameSummary.length ? `, tools=${toolNameSummary.join(", ")}` : ""}. ` +
			`Claude session will rebuild before the next turn; see ${diagLogPath()}.`,
			"error",
		);
		return true;
	} catch (error) {
		debug("reportToolResultMismatch failed:", error);
		return false;
	}
}

export function __testSetBridgeIntegrityState(state: { ui?: Pick<ExtensionUIContext, "notify"> | null; sharedSession?: SessionState | null }): void {
	if ("ui" in state) piUI = state.ui as ExtensionUIContext | undefined;
	if ("sharedSession" in state) sharedSession = state.sharedSession ?? null;
}

export function __testGetBridgeIntegrityState(): { sharedSession: SessionState | null } {
	return { sharedSession };
}
