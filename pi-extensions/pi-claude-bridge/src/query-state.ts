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
