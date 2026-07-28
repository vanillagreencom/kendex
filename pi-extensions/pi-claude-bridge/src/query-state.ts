// Query state: QueryContext class + context stack.
//
// All per-query and per-turn mutable state lives here. Reentrant queries
// (subagents) push the parent context onto a stack and get a fresh instance.
// Adding a new field = one property on the class.
//
// Extracted from index.ts so tests can import without activating the extension.

import type { AssistantMessage, AssistantMessageEventStream, Model } from "@earendil-works/pi-ai";
import type { McpResult } from "./extract-tool-results.js";

export interface PendingToolCall {
	toolName: string;
	resolve: (result: McpResult) => void;
}

// Why pending MCP handlers were drained without a real tool result. A drained
// handler is waiting on a result pi will now never deliver, so the drain must
// resolve as an error — never as a successful result whose text merely says the
// turn died, which a consumer cannot tell apart from a tool that genuinely
// returned that string. The cause is carried because an abort, an idle timeout,
// and a plain end-with-stragglers are different things to act on.
export type ToolCallDrainCause = "abort" | "stream-idle-timeout" | "query-end";

const DRAIN_CAUSE_TEXT: Record<ToolCallDrainCause, string> = {
	"abort": "the turn was aborted",
	"stream-idle-timeout": "the Claude Code stream went idle and the turn timed out",
	"query-end": "the query ended",
};

export function interruptedToolCallResult(cause: ToolCallDrainCause): McpResult {
	return {
		content: [{ type: "text", text: `Claude bridge: ${DRAIN_CAUSE_TEXT[cause]} before this tool call's result was delivered. The call did not complete and produced no output.` }],
		isError: true,
	};
}

// Precedence matches the forceRotate expression at the query-teardown site: an
// explicit abort (pi's signal or our own abort handler) outranks a stream-idle
// timeout, which outranks a plain end with stragglers.
export function toolCallDrainCause(flags: { wasAborted?: boolean; signalAborted?: boolean; streamIdleTimedOut?: boolean }): ToolCallDrainCause {
	if (flags.wasAborted || flags.signalAborted) return "abort";
	if (flags.streamIdleTimedOut) return "stream-idle-timeout";
	return "query-end";
}

/** Resolves every handler still waiting on `queryCtx` with an error result naming
 *  `cause`, clears the map, and returns how many were drained. Scoped to the one
 *  context it is given — never touches a sibling or parent query's handlers. */
export function drainPendingToolCalls(queryCtx: QueryContext, cause: ToolCallDrainCause): number {
	const drained = queryCtx.pendingToolCalls.size;
	if (drained === 0) return 0;
	const result = interruptedToolCallResult(cause);
	for (const pending of queryCtx.pendingToolCalls.values()) pending.resolve(result);
	queryCtx.pendingToolCalls.clear();
	return drained;
}

/** One connector call's audit state for the life of a query. `recorded` means an
 *  entry for it has already been appended (or attempted), so neither a re-yielded
 *  result nor the teardown flush can record it twice. */
export interface ConnectorCallAuditState {
	name: string;
	/** The child session that issued it, captured when the call was seen — a
	 *  continuation query gets a new one, and a call is audited against the session
	 *  that actually made it. */
	childSessionId?: string;
	recorded: boolean;
}

export interface TurnToolCallRecord {
	id: string;
	toolName: string;
	arguments: Record<string, unknown>;
}

export interface ClaimedToolCall {
	toolCallId?: string;
	match: "tool-args" | "tool-name" | "none";
	ambiguous: boolean;
	available: number;
}

export interface ToolResultProgress {
	expectedIds: string[];
	deliveredIds: string[];
	resolvedIds: string[];
	waitingIds: string[];
	queuedIds: string[];
	unmatchedResultIds: string[];
	missingDeliveredIds: string[];
	unresolvedIds: string[];
	toolNames: Array<{ name: string; count: number }>;
	expectedCount: number;
	deliveredCount: number;
	resolvedCount: number;
	waitingCount: number;
	queuedCount: number;
	unmatchedResultCount: number;
}

function normalizeForCompare(value: unknown): unknown {
	if (Array.isArray(value)) return value.map(normalizeForCompare);
	if (value && typeof value === "object") {
		const out: Record<string, unknown> = {};
		for (const key of Object.keys(value as Record<string, unknown>).sort()) {
			const child = (value as Record<string, unknown>)[key];
			if (child !== undefined) out[key] = normalizeForCompare(child);
		}
		return out;
	}
	return value;
}

function argsKey(value: unknown): string {
	return JSON.stringify(normalizeForCompare(value ?? {}));
}

function sameArgs(left: unknown, right: unknown): boolean {
	return argsKey(left) === argsKey(right);
}

function hasRecordedArgs(args: Record<string, unknown> | undefined): boolean {
	return Object.keys(args ?? {}).length > 0;
}

function unique(values: Iterable<string | undefined>): string[] {
	const out: string[] = [];
	const seen = new Set<string>();
	for (const value of values) {
		if (!value || seen.has(value)) continue;
		seen.add(value);
		out.push(value);
	}
	return out;
}

export class QueryContext {
	// Query-scoped (fully isolated per query)
	activeQuery: unknown | null = null;
	currentPiStream: AssistantMessageEventStream | null = null;
	latestCursor = 0;
	pendingToolCalls = new Map<string, PendingToolCall>();
	pendingResults = new Map<string, McpResult>();
	turnToolCallIds: string[] = [];
	turnToolCalls: TurnToolCallRecord[] = [];
	claimedToolCallIds = new Set<string>();
	deliveredToolResultIds = new Set<string>();
	resolvedToolResultIds = new Set<string>();
	unmatchedToolResultIds = new Set<string>();
	reportedToolResultMismatch = false;
	deferredUserMessages: string[] = [];
	handledTerminalError = false;

	// Tool calls the CHILD executes itself (claude.ai connectors — see
	// isChildExecutedTool). Deliberately NOT in turnToolCalls/turnToolCallIds:
	// those track calls Pi owes a result for, and Pi owes nothing here. Kept only
	// so the child's real result can be recognized when it comes back on the SDK's
	// `user` message, and so the streamed block's deltas can be skipped silently
	// instead of logging as "unmatched" (which reads like a bug).
	/** tool_use id → raw SDK tool name. */
	childExecutedToolCalls = new Map<string, string>();
	/**
	 * The same calls, for the connector-call audit trail (see connector-audit.ts).
	 *
	 * Query-scoped and deliberately NOT cleared by resetToolTracking: that runs at
	 * every child message boundary, and a call issued in one child message is only
	 * reconciled after that message ends. Clearing it there would make an abandoned
	 * call unrecordable at teardown — which is the one case the trail exists for.
	 */
	connectorCallAudit = new Map<string, ConnectorCallAuditState>();
	/** Claude Code session id for this query, from the SDK's `system` init message.
	 *  Undefined until it arrives; the audit trail omits the field rather than
	 *  guessing. */
	childSessionId: string | undefined;
	/** Anthropic content-block indexes of the current assistant message that carry
	 *  a child-executed tool_use. Scoped to one message: cleared at message_start,
	 *  and an index is released as soon as a new block starts there. */
	childExecutedStreamIndexes = new Set<number>();

	// Usage accounting for a Pi turn that spans SEVERAL child assistant messages.
	//
	// Every child message is a separate billed API call, and each reports its own
	// counters — `message_start`/`message_delta` REPLACE rather than accumulate. A
	// Pi turn used to end at the first tool call, so one Pi message meant one child
	// message and replacing was right. A turn containing a child-executed connector
	// call now keeps running across the child's follow-up messages, so replacing
	// would silently drop everything the earlier ones billed (measured: 55,685
	// cache-write tokens lost on a single connector turn).
	//
	// So: `turnUsageCarry` holds the totals of the child messages already COMPLETE
	// in this Pi turn, `currentMessageUsage` holds the one in flight, and the Pi
	// message reports their sum. Summing is the correct model for input and cache
	// too — each call bills its own.
	turnUsageCarry = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
	currentMessageUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
	/** Anthropic id of the child message `currentMessageUsage` describes. */
	currentMessageId: string | undefined;

	/**
	 * Declare which child message the following usage belongs to, banking the
	 * previous one's counters into the turn total.
	 *
	 * Keyed on the MESSAGE ID rather than on the call site, because both paths
	 * that see a message boundary can fire for the SAME message: `message_start`
	 * arrives on the stream, and the SDK then yields that message again in
	 * completed form. Banking per call site double-counted whenever the completed
	 * copy took the no-stream-events branch — which it does whenever a message
	 * produced no content blocks, since `turnSawStreamEvent` only tracks those.
	 *
	 * With no id on either side (older/streamless shapes) this degrades to
	 * banking on every call, which is what each caller means when it cannot
	 * prove otherwise.
	 */
	beginChildMessage(messageId?: unknown): void {
		const id = typeof messageId === "string" && messageId.length > 0 ? messageId : undefined;
		if (id !== undefined && id === this.currentMessageId) return; // same message
		this.turnUsageCarry.input += this.currentMessageUsage.input;
		this.turnUsageCarry.output += this.currentMessageUsage.output;
		this.turnUsageCarry.cacheRead += this.currentMessageUsage.cacheRead;
		this.turnUsageCarry.cacheWrite += this.currentMessageUsage.cacheWrite;
		this.currentMessageUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
		this.currentMessageId = id;
	}

	// Per-turn (reset together)
	turnOutput: AssistantMessage | null = null;
	turnStarted = false;
	turnSawStreamEvent = false;
	turnSawToolCall = false;

	get turnBlocks(): Array<any> {
		if (!this.turnOutput) throw new Error("turnBlocks accessed before resetTurnState");
		return this.turnOutput.content;
	}

	resetTurnState(model: Model<any>): void {
		this.turnOutput = {
			role: "assistant", content: [],
			api: model.api, provider: model.provider, model: model.id,
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
			stopReason: "stop", timestamp: Date.now(),
		};
		this.turnStarted = false;
		this.turnSawStreamEvent = false;
		this.turnSawToolCall = false;
		this.handledTerminalError = false;
		// Usage accounting IS per-Pi-message, so it resets with the message it
		// describes — unlike tool-call tracking below.
		this.turnUsageCarry = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
		this.currentMessageUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
		this.currentMessageId = undefined;
		// Tool-call tracking is NOT reset here — it persists across the
		// tool-result delivery callback for the same assistant message. New
		// assistant messages call resetToolTracking() explicitly.
	}

	resetToolTracking(): void {
		this.turnToolCallIds = [];
		this.turnToolCalls = [];
		this.claimedToolCallIds.clear();
		this.deliveredToolResultIds.clear();
		this.resolvedToolResultIds.clear();
		this.unmatchedToolResultIds.clear();
		this.reportedToolResultMismatch = false;
		this.childExecutedToolCalls.clear();
		this.childExecutedStreamIndexes.clear();
	}

	/** Note a tool_use the child runs itself. `streamIndex` is present only on the
	 *  streamed path, where later deltas/stops for that block must be skipped. */
	noteChildExecutedToolCall(id: string | undefined, rawName: string, streamIndex?: number): void {
		if (id) {
			this.childExecutedToolCalls.set(id, rawName);
			// Both emission paths can see the same call (streamed block, then the
			// SDK's completed copy), so never overwrite an existing audit state —
			// that would resurrect one already recorded.
			if (!this.connectorCallAudit.has(id)) {
				this.connectorCallAudit.set(id, {
					name: rawName,
					...(this.childSessionId ? { childSessionId: this.childSessionId } : {}),
					recorded: false,
				});
			}
		}
		if (typeof streamIndex === "number") this.childExecutedStreamIndexes.add(streamIndex);
	}

	recordToolCall(id: string | undefined, toolName: string, args: Record<string, unknown> = {}): void {
		if (!id) return;
		if (!this.turnToolCallIds.includes(id)) this.turnToolCallIds.push(id);
		const existing = this.turnToolCalls.find((call) => call.id === id);
		if (existing) {
			existing.toolName = toolName;
			existing.arguments = args;
			return;
		}
		this.turnToolCalls.push({ id, toolName, arguments: args });
	}

	updateToolCallArgs(id: string | undefined, args: Record<string, unknown>): void {
		if (!id) return;
		const existing = this.turnToolCalls.find((call) => call.id === id);
		if (existing) existing.arguments = args;
	}

	hasRecordedToolCall(id: string | undefined): boolean {
		return Boolean(id && (this.turnToolCallIds.includes(id) || this.turnToolCalls.some((call) => call.id === id)));
	}

	claimToolCall(toolName: string, args: Record<string, unknown> = {}): ClaimedToolCall {
		const unclaimed = this.turnToolCalls.filter((call) => !this.claimedToolCallIds.has(call.id));
		const byName = unclaimed.filter((call) => call.toolName === toolName);
		const exact = byName.filter((call) => sameArgs(call.arguments, args));
		let chosen: TurnToolCallRecord | undefined;
		let match: ClaimedToolCall["match"] = "none";
		let ambiguous = false;

		if (exact.length > 0) {
			chosen = exact[0];
			match = "tool-args";
			ambiguous = exact.length > 1;
		} else if (byName.length === 1 && !hasRecordedArgs(byName[0].arguments)) {
			// The SDK can invoke the MCP handler after content_block_start but
			// before input_json_delta/content_block_stop finalizes arguments.
			// Falling back to the sole same-name, argument-less call preserves that
			// race without ever claiming a different tool type.
			chosen = byName[0];
			match = "tool-name";
		}

		if (!chosen) return { match: "none", ambiguous: false, available: unclaimed.length };
		this.claimedToolCallIds.add(chosen.id);
		return { toolCallId: chosen.id, match, ambiguous, available: unclaimed.length };
	}

	markToolResultDelivered(id: string | undefined): void {
		if (id) this.deliveredToolResultIds.add(id);
	}

	markToolResultResolved(id: string | undefined): void {
		if (id) this.resolvedToolResultIds.add(id);
	}

	markToolResultUnmatched(id: string | undefined): void {
		if (id) this.unmatchedToolResultIds.add(id);
	}

	toolResultProgress(): ToolResultProgress {
		const expectedIds = unique([
			...this.turnToolCalls.map((call) => call.id),
			...this.turnToolCallIds,
		]);
		const deliveredIds = unique(this.deliveredToolResultIds);
		const resolvedIds = unique(this.resolvedToolResultIds);
		const waitingIds = unique(this.pendingToolCalls.keys());
		const queuedIds = unique(this.pendingResults.keys());
		const unmatchedResultIds = unique(this.unmatchedToolResultIds);
		const missingDeliveredIds = expectedIds.filter((id) => !this.deliveredToolResultIds.has(id));
		const unresolvedIds = expectedIds.filter((id) => !this.resolvedToolResultIds.has(id));
		const affectedIds = new Set([...missingDeliveredIds, ...unresolvedIds, ...waitingIds, ...queuedIds, ...unmatchedResultIds]);
		const counts = new Map<string, number>();
		for (const call of this.turnToolCalls) {
			if (affectedIds.size > 0 && !affectedIds.has(call.id)) continue;
			counts.set(call.toolName, (counts.get(call.toolName) ?? 0) + 1);
		}
		return {
			expectedIds,
			deliveredIds,
			resolvedIds,
			waitingIds,
			queuedIds,
			unmatchedResultIds,
			missingDeliveredIds,
			unresolvedIds,
			toolNames: [...counts.entries()]
				.sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
				.map(([name, count]) => ({ name, count })),
			expectedCount: expectedIds.length,
			deliveredCount: deliveredIds.length,
			resolvedCount: resolvedIds.length,
			waitingCount: waitingIds.length,
			queuedCount: queuedIds.length,
			unmatchedResultCount: unmatchedResultIds.length,
		};
	}
}

let _ctx = new QueryContext();
const contextStack: QueryContext[] = [];

export function ctx(): QueryContext { return _ctx; }

export function stackDepth(): number { return contextStack.length; }

export function pushContext(): void {
	if (!_ctx.activeQuery) throw new Error("pushContext() called with no active query");
	contextStack.push(_ctx);
	_ctx = new QueryContext();
}

export function popContext(): void {
	if (contextStack.length === 0) throw new Error("popContext() called with empty stack");
	const parent = contextStack[contextStack.length - 1];
	parent.deferredUserMessages.push(..._ctx.deferredUserMessages);
	_ctx = contextStack.pop()!;
}

// Test-only: drop all state so test files can start from a clean module.
// Not called from production.
export function resetStack(): void {
	_ctx = new QueryContext();
	contextStack.length = 0;
}
