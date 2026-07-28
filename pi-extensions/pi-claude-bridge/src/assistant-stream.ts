import { calculateCost, type AssistantMessage, type Model } from "@earendil-works/pi-ai";
import { type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { appendIntegrityEntry, safeNotify } from "./bridge-state.js";
import { connectorResultByteSize, recordConnectorCallResult } from "./connector-audit.js";
import { isChildExecutedTool } from "./connectors.js";
import { debug, diagDump } from "./debug.js";
import { ctx, type QueryContext } from "./query-state.js";
import { mapToolArgs, mapToolName } from "./tool-mapping.js";

// --- Usage helpers ---

function updateUsage(output: AssistantMessage, usage: Record<string, number | undefined>, model: Model<any>): void {
	// Anthropic reports per-message counters and RE-reports them as the message
	// grows, so the in-flight message's figures are replaced, not added. What is
	// added is every child message already finished in this Pi turn — see
	// `turnUsageCarry` in query-state.ts for why a turn can span several.
	const c = ctx();
	const current = c.currentMessageUsage;
	const carry = c.turnUsageCarry;
	if (usage.input_tokens != null) current.input = usage.input_tokens;
	if (usage.output_tokens != null) current.output = usage.output_tokens;
	if (usage.cache_read_input_tokens != null) current.cacheRead = usage.cache_read_input_tokens;
	if (usage.cache_creation_input_tokens != null) current.cacheWrite = usage.cache_creation_input_tokens;
	output.usage.input = carry.input + current.input;
	output.usage.output = carry.output + current.output;
	output.usage.cacheRead = carry.cacheRead + current.cacheRead;
	output.usage.cacheWrite = carry.cacheWrite + current.cacheWrite;
	output.usage.totalTokens = output.usage.input + output.usage.output + output.usage.cacheRead + output.usage.cacheWrite;
	calculateCost(model, output.usage);
	const promptTokens = output.usage.input + output.usage.cacheRead + output.usage.cacheWrite;
	const cachePct = promptTokens > 0 ? Math.round(output.usage.cacheRead / promptTokens * 100) : 0;
	debug(`usage: in=${output.usage.input} out=${output.usage.output} cacheRead=${output.usage.cacheRead} cacheWrite=${output.usage.cacheWrite} total=${output.usage.totalTokens} cachePct=${cachePct}% model=${model.id}`);
}

// --- Provider helpers: misc ---

function mapStopReason(reason: string | undefined): "stop" | "length" | "toolUse" {
	switch (reason) {
		case "tool_use": return "toolUse";
		case "max_tokens": return "length";
		case "end_turn": default: return "stop";
	}
}

export function parsePartialJson(input: string, fallback: Record<string, unknown>): Record<string, unknown> {
	if (!input) return fallback;
	try { return JSON.parse(input); } catch { return fallback; }
}

export function ensureTurnStarted(): void {
	if (!ctx().turnStarted && ctx().currentPiStream && ctx().turnOutput) {
		ctx().currentPiStream!.push({ type: "start", partial: ctx().turnOutput });
		ctx().turnStarted = true;
	}
}

export function finalizeCurrentStream(stopReason?: string): void {
	if (!ctx().currentPiStream || !ctx().turnOutput) return;
	debug(`provider: finalizeCurrentStream called, stopReason=${stopReason}, turnOutput=${JSON.stringify({stopReason: ctx().turnOutput!.stopReason, error: ctx().turnOutput!.errorMessage})}`);
	if (!ctx().turnStarted) ensureTurnStarted();
	const reason = stopReason === "length" ? "length" : "stop";
	ctx().currentPiStream!.push({ type: "done", reason, message: ctx().turnOutput });
	ctx().currentPiStream!.end();
	ctx().currentPiStream = null;
}

// --- Tool-use turn end: deferred to the stream's terminal events ---
//
// The Claude Code CLI dispatches MCP tool calls (and the SDK yields the
// completed assistant message) BEFORE the stream's message_delta arrives — and
// message_delta is what carries the message's REAL output-token count (measured:
// handler invoked ~45ms before message_delta on every tool-use turn). Ending
// the pi stream at either of those early signals therefore froze usage at the
// message_start placeholder values, which is why pi sessions recorded 1–7
// output tokens per tool-use turn while the final text turn recorded hundreds
// (2026-07-28 token test, both bridge panes).
//
// So the turn now ends at message_stop, exactly like the streamed-text case,
// and the early signals only ARM a grace timer. The timer is the deadlock
// backstop for the one observed case where the terminal events never arrive
// (pi 0.80 steer draining): pi cannot execute tools before the stream ends, and
// the MCP handler cannot resolve before pi executes, so a stream that has gone
// silent must be ended by force — just 1.5s later instead of immediately.

const TOOL_USE_END_GRACE_MS = 1500;

/** End the current pi stream as a tool_use turn boundary. Safe to call when the
 *  turn already ended (no-op). */
export function endToolUseTurn(c: QueryContext): void {
	if (!c.currentPiStream || !c.turnOutput) return;
	cancelScheduledToolUseEnd(c);
	c.turnOutput.stopReason = "toolUse";
	c.currentPiStream.push({ type: "done", reason: "toolUse", message: c.turnOutput });
	c.currentPiStream.end();
	c.currentPiStream = null;
}

export function cancelScheduledToolUseEnd(c: QueryContext): void {
	if (!c.scheduledToolUseEnd) return;
	clearTimeout(c.scheduledToolUseEnd.timer);
	c.scheduledToolUseEnd = null;
}

/**
 * Arm the grace timer that force-ends the current tool_use turn if the stream's
 * terminal events never arrive. First arming per stream wins; message_stop (or
 * resetTurnState) disarms it. `action` runs only if the SAME stream is still
 * current when the grace elapses — a turn that ended normally makes it a no-op.
 */
export function scheduleToolUseTurnEnd(c: QueryContext, action: () => void, source: string): void {
	if (!c.currentPiStream || !c.turnOutput) return;
	if (c.scheduledToolUseEnd?.stream === c.currentPiStream) return;
	cancelScheduledToolUseEnd(c);
	const stream = c.currentPiStream;
	const timer = setTimeout(() => {
		if (c.currentPiStream !== stream) return;
		debug(`scheduleToolUseTurnEnd: no terminal stream event within ${TOOL_USE_END_GRACE_MS}ms (${source}) — force-ending tool_use turn`);
		c.scheduledToolUseEnd = null;
		action();
	}, TOOL_USE_END_GRACE_MS);
	timer.unref?.();
	c.scheduledToolUseEnd = { stream, timer };
}

/**
 * Drop queued tool results that no handler can ever consume again, and say so
 * everywhere it matters. Runs at a child message boundary — by then every
 * handler for the previous message has either resolved (directly or from this
 * queue) or already returned an error, so anything still queued is the real
 * output of a call whose handler gave up. See takeStaleQueuedResults for why
 * leaving them queued poisoned every later mismatch report and forced a
 * session rebuild per turn.
 */
export function reapStaleQueuedResults(c: QueryContext): void {
	const stale = c.takeStaleQueuedResults();
	if (stale.length === 0) return;
	const names = stale.map((entry) => entry.toolName);
	debug(`reapStaleQueuedResults: dropping ${stale.length} queued tool result(s) with no possible consumer:`, names.join(", "));
	diagDump("stale_queued_tool_results_dropped", { count: stale.length, stale });
	appendIntegrityEntry("stale_queued_tool_results_dropped", { count: stale.length, stale });
	safeNotify(
		`Claude bridge: dropped ${stale.length} tool result(s) whose handler never matched (${names.slice(0, 6).join(", ")}${names.length > 6 ? ", …" : ""}). ` +
		`The model saw an error for these calls and may retry them.`,
		"warning",
	);
}

export function updateTurnOutputModel(modelId: unknown): void {
	const c = ctx();
	if (typeof modelId !== "string" || !modelId || !c.turnOutput) return;
	if (c.turnOutput.model === modelId) return;
	debug(`provider: active Claude model changed ${c.turnOutput.model} -> ${modelId}`);
	c.turnOutput.model = modelId;
}

/** Force-finalizes the current pi turn as a tool_use boundary when its terminal
 *  stream events never arrived (the grace-timer action armed by an MCP handler
 *  invocation — see scheduleToolUseTurnEnd).
 *
 *  Observed with Claude Code under pi 0.80's steer draining (tool result and
 *  drained steer arrive in one provider call): the NEXT tool turn's tool_use
 *  streams in, the SDK invokes the MCP handler — and neither terminal event
 *  ever arrives. The invocation itself proves the assistant turn is committed,
 *  so end the pi stream here exactly like the `message_stop` path; otherwise
 *  the handler blocks on a result pi will never deliver (deadlock). No-op when
 *  the turn already ended (stream null) or the tool call isn't part of the
 *  currently streamed turn. */
export function finalizeToolUseTurnFromMcpInvocation(
	queryCtx: QueryContext,
	toolCallId: string,
	toolName: string,
	mappedArgs: Record<string, unknown>,
): void {
	if (!queryCtx.currentPiStream || !queryCtx.turnOutput) return;
	let idx = queryCtx.turnBlocks.findIndex((b: any) => b.type === "toolCall" && b.id === toolCallId);
	if (idx >= 0) {
		const block = queryCtx.turnBlocks[idx] as any;
		if ("partialJson" in block) {
			// Stream ended before content_block_stop — settle the args from the
			// partial JSON the same way content_block_stop would have.
			block.arguments = mapToolArgs(block.name, parsePartialJson(block.partialJson, block.arguments));
			queryCtx.updateToolCallArgs(block.id, block.arguments);
			delete block.partialJson;
			delete block.index;
			queryCtx.currentPiStream.push({ type: "toolcall_end", contentIndex: idx, toolCall: block, partial: queryCtx.turnOutput });
		}
	} else {
		// The invocation can arrive before the tool_use is streamed at all
		// (observed after a tool-result+steer provider call reset the turn):
		// synthesize the toolCall from the claim — the MCP call carries the
		// authoritative id, name, and arguments.
		queryCtx.turnBlocks.push({ type: "toolCall", id: toolCallId, name: toolName, arguments: mappedArgs });
		idx = queryCtx.turnBlocks.length - 1;
		const block = queryCtx.turnBlocks[idx] as any;
		queryCtx.currentPiStream.push({ type: "toolcall_start", contentIndex: idx, partial: queryCtx.turnOutput });
		queryCtx.currentPiStream.push({ type: "toolcall_end", contentIndex: idx, toolCall: block, partial: queryCtx.turnOutput });
	}
	queryCtx.turnSawToolCall = true;
	debug(`mcp handler: finalizing tool_use turn from MCP invocation [${toolCallId}] (${toolName}) — terminal stream events never arrived`);
	endToolUseTurn(queryCtx);
}

/** Maps Anthropic stream events to pi stream events (text, thinking, toolcall).
 *  On message_stop with tool_use: ends currentPiStream so pi can execute the tool. */
export function processStreamEvent(
	message: SDKMessage,
	customToolNameToPi: Map<string, string>,
	model: Model<any>,
): void {
	const c = ctx();
	if (!c.currentPiStream || !c.turnOutput) return;
	const event = (message as SDKMessage & { event: any }).event;
	if (event?.type === "ping") return;
	if (event?.type === "message_stop" && !c.turnSawToolCall) {
		debug("processStreamEvent: ignoring bare message_stop with no streamed content/tool call");
		return;
	}

	if (event?.type === "message_start") {
		// The child moving to a new message proves every result for the previous
		// one reached it; anything still queued can never be consumed.
		reapStaleQueuedResults(c);
		c.resetToolTracking();
		// A new child message begins: bank what the previous one billed before its
		// counters are replaced. No-op on the turn's first, and no-op if this same
		// message was already declared (see beginChildMessage).
		c.beginChildMessage(event.message?.id);
		updateTurnOutputModel(event.message?.model);
		if (event.message?.usage) updateUsage(c.turnOutput, event.message.usage, model);
		return;
	}

	if (event?.type === "content_block_start") {
		c.turnSawStreamEvent = true;
		ensureTurnStarted();
		// A new block owns this index from here on, so release any child-executed
		// claim on it. Belt-and-braces against a missed message_start: without this
		// a stale index could silently swallow a later text block's deltas.
		c.childExecutedStreamIndexes.delete(event.index);
		if (event.content_block?.type === "tool_use" && isChildExecutedTool(event.content_block.name)) {
			// The child runs this one itself — mirroring it into the Pi stream would
			// make Pi's agent loop dispatch a tool it does not have. See
			// isChildExecutedTool.
			c.noteChildExecutedToolCall(event.content_block.id, event.content_block.name, event.index);
			debug(`processStreamEvent: child-executed tool ${event.content_block.name} [${event.content_block.id}] — not mirrored as a Pi tool call`);
			return;
		}
		if (event.content_block?.type === "text") {
			c.turnBlocks.push({ type: "text", text: "", index: event.index });
			c.currentPiStream!.push({ type: "text_start", contentIndex: c.turnBlocks.length - 1, partial: c.turnOutput });
		} else if (event.content_block?.type === "thinking") {
			c.turnBlocks.push({ type: "thinking", thinking: "", thinkingSignature: "", index: event.index });
			c.currentPiStream!.push({ type: "thinking_start", contentIndex: c.turnBlocks.length - 1, partial: c.turnOutput });
		} else if (event.content_block?.type === "tool_use") {
			c.turnSawToolCall = true;
			const mappedName = mapToolName(event.content_block.name, customToolNameToPi);
			c.recordToolCall(event.content_block.id, mappedName, {});
			c.turnBlocks.push({
				type: "toolCall", id: event.content_block.id,
				name: mappedName,
				arguments: (event.content_block.input as Record<string, unknown>) ?? {},
				partialJson: "", index: event.index,
			});
			c.currentPiStream!.push({ type: "toolcall_start", contentIndex: c.turnBlocks.length - 1, partial: c.turnOutput });
		} else {
			debug("processStreamEvent: unhandled content_block_start type", event.content_block?.type);
		}
		return;
	}

	if (event?.type === "content_block_delta") {
		// A child-executed tool's argument deltas have no Pi block to land in. Skip
		// them here rather than letting the lookup below miss, so the "unmatched"
		// warning keeps meaning "something is wrong". Unlike that stale-event case
		// this IS a live event for the current message, so it still counts as one.
		if (c.childExecutedStreamIndexes.has(event.index)) {
			c.turnSawStreamEvent = true;
			return;
		}
		const index = c.turnBlocks.findIndex((b: any) => b.index === event.index);
		const block = c.turnBlocks[index];
		if (!block) {
			debug("processStreamEvent: ignoring unmatched content_block_delta", event.index);
			return;
		}
		c.turnSawStreamEvent = true;
		if (event.delta?.type === "text_delta" && block.type === "text") {
			block.text += event.delta.text;
			c.currentPiStream!.push({ type: "text_delta", contentIndex: index, delta: event.delta.text, partial: c.turnOutput });
		} else if (event.delta?.type === "thinking_delta" && block.type === "thinking") {
			block.thinking += event.delta.thinking;
			c.currentPiStream!.push({ type: "thinking_delta", contentIndex: index, delta: event.delta.thinking, partial: c.turnOutput });
		} else if (event.delta?.type === "input_json_delta" && block.type === "toolCall") {
			block.partialJson += event.delta.partial_json;
			block.arguments = parsePartialJson(block.partialJson, block.arguments);
			c.currentPiStream!.push({ type: "toolcall_delta", contentIndex: index, delta: event.delta.partial_json, partial: c.turnOutput });
		} else if (event.delta?.type === "signature_delta" && block.type === "thinking") {
			block.thinkingSignature = (block.thinkingSignature ?? "") + event.delta.signature;
		} else {
			debug("processStreamEvent: unhandled content_block_delta type", event.delta?.type);
		}
		return;
	}

	if (event?.type === "content_block_stop") {
		// Same as the delta case: the block was never mirrored, so there is nothing
		// to seal and nothing unmatched about it.
		if (c.childExecutedStreamIndexes.has(event.index)) {
			c.turnSawStreamEvent = true;
			return;
		}
		const index = c.turnBlocks.findIndex((b: any) => b.index === event.index);
		const block = c.turnBlocks[index];
		if (!block) {
			debug("processStreamEvent: ignoring unmatched content_block_stop", event.index);
			return;
		}
		c.turnSawStreamEvent = true;
		delete block.index;
		if (block.type === "text") {
			c.currentPiStream!.push({ type: "text_end", contentIndex: index, content: block.text, partial: c.turnOutput });
		} else if (block.type === "thinking") {
			c.currentPiStream!.push({ type: "thinking_end", contentIndex: index, content: block.thinking, partial: c.turnOutput });
		} else if (block.type === "toolCall") {
			c.turnSawToolCall = true;
			block.arguments = mapToolArgs(
				block.name, parsePartialJson(block.partialJson, block.arguments),
			);
			c.updateToolCallArgs(block.id, block.arguments);
			delete block.partialJson;
			c.currentPiStream!.push({ type: "toolcall_end", contentIndex: index, toolCall: block, partial: c.turnOutput });
		}
		return;
	}

	if (event?.type === "message_delta") {
		c.turnOutput.stopReason = mapStopReason(event.delta?.stop_reason);
		if (event.usage) updateUsage(c.turnOutput, event.usage, model);
		return;
	}

	if (event?.type === "message_stop" && c.turnSawToolCall) {
		// Tool call complete — end this pi stream, disarming any grace timer the
		// MCP-invocation or assistant-boundary path armed. This is the NORMAL end
		// for a tool-use turn: message_delta already delivered the message's real
		// usage just above, so the done event carries correct output tokens. The
		// MCP handler blocks the generator until pi delivers the tool result via
		// the next streamSimple call.
		endToolUseTurn(c);

		// Cursor is updated by the next streamSimple call (tool result delivery path)
		// which sets cursor = context.messages.length with the post-tool-result context.
		return;
	}

	if (event?.type !== "message_stop" && event?.type !== "ping") {
		debug("processStreamEvent: unhandled event type", event?.type);
	}
}

// The SDK always yields `assistant` messages (completed content blocks) after streaming.
// When stream_events already delivered the content, this is a no-op. But after
// resetTurnState (e.g. tool result delivery), if the next turn's assistant message
// arrives before any stream_events, this is the primary content path. Must maintain
// the same stream lifecycle as processStreamEvent — including ending the stream on
// tool_use to prevent deadlock with the MCP handler.
function appendMissingToolUsesFromAssistant(
	assistantMsg: { content?: Array<any>; usage?: Record<string, number | undefined> },
	model: Model<any>,
	customToolNameToPi: Map<string, string>,
): boolean {
	const c = ctx();
	if (!assistantMsg?.content) return false;
	let sawToolUse = false;
	for (const block of assistantMsg.content) {
		if (block.type !== "tool_use") continue;
		if (isChildExecutedTool(block.name)) {
			// Not a Pi tool call, so it is NOT a turn boundary either: `sawToolUse`
			// stays false for it and the caller keeps streaming this Pi message. The
			// child neither blocks on Pi nor needs a result from it.
			c.noteChildExecutedToolCall(block.id, block.name);
			debug(`assistant message: child-executed tool ${block.name} [${block.id}] — not mirrored as a Pi tool call`);
			continue;
		}
		sawToolUse = true;
		const existingIdx = c.turnBlocks.findIndex((b: any) => b.type === "toolCall" && b.id === block.id);
		const name = mapToolName(block.name, customToolNameToPi);
		const mappedArgs = mapToolArgs(name, block.input);
		c.recordToolCall(block.id, name, mappedArgs);
		if (existingIdx >= 0) {
			const existing = c.turnBlocks[existingIdx] as any;
			existing.name = name;
			existing.arguments = mappedArgs;
			c.updateToolCallArgs(block.id, mappedArgs);
			if ("partialJson" in existing) {
				delete existing.partialJson;
				delete existing.index;
				c.currentPiStream?.push({ type: "toolcall_end", contentIndex: existingIdx, toolCall: existing, partial: c.turnOutput });
			}
			continue;
		}

		ensureTurnStarted();
		c.turnBlocks.push({
			type: "toolCall", id: block.id,
			name,
			arguments: mappedArgs,
		});
		const idx = c.turnBlocks.length - 1;
		const toolBlock = c.turnBlocks[idx];
		c.currentPiStream?.push({ type: "toolcall_start", contentIndex: idx, partial: c.turnOutput });
		c.currentPiStream?.push({ type: "toolcall_end", contentIndex: idx, toolCall: toolBlock as any, partial: c.turnOutput });
	}
	// Only while the stream is still live: the SDK's assistant yields carry the
	// message_start placeholder usage (output ≈ 1–7), and once the done event has
	// delivered turnOutput to pi, overwriting its usage with those placeholders
	// would corrupt the very figure message_delta got right.
	if (assistantMsg.usage && c.turnOutput && c.currentPiStream) updateUsage(c.turnOutput, assistantMsg.usage, model);
	return sawToolUse;
}

/**
 * Record that a child-executed tool call came back, from the SDK's `user` message
 * carrying the child's own `tool_result` blocks.
 *
 * This is the only place the bridge ever OBSERVES one of these results, and it is
 * deliberately observation-only: the result already reached the model inside the
 * child, which is the conversation of record for a bridge turn, so re-delivering
 * it would double it. What the bridge could not do before this existed was say
 * anything true about these calls at all — the Pi transcript claimed they failed
 * and nothing anywhere claimed otherwise.
 *
 * The payload is NEVER logged or recorded, only its shape: a connector result is
 * live account data (mail, messages, documents) and the bridge's debug log sits
 * outside a host app's redaction boundary.
 *
 * Observing it is also what makes the call auditable: each one appends a session
 * `CustomEntry` (connector-audit.ts) so the Pi session records that the call
 * happened, without a content block Pi's agent loop could try to dispatch.
 */
export function noteChildExecutedToolResults(message: SDKMessage): void {
	const c = ctx();
	if (c.childExecutedToolCalls.size === 0) return;
	const content = (message as SDKMessage & { message?: { content?: unknown } }).message?.content;
	if (!Array.isArray(content)) return;
	for (const block of content) {
		if (block?.type !== "tool_result") continue;
		const name = c.childExecutedToolCalls.get(block.tool_use_id);
		if (!name) continue;
		const isError = block.is_error === true;
		const byteSize = connectorResultByteSize(block.content);
		const audited = recordConnectorCallResult(c, block.tool_use_id, name, isError, byteSize);
		debug(`child-executed tool result: ${name} [${block.tool_use_id}] isError=${isError} byteSize=${byteSize ?? "unknown"} audited=${audited}`);
	}
}

export function processAssistantMessage(message: SDKMessage, model: Model<any>, customToolNameToPi: Map<string, string>): void {
	const c = ctx();
	const assistantMsg = (message as any).message;
	if (!assistantMsg?.content) return;
	updateTurnOutputModel(assistantMsg.model);
	if (c.turnSawStreamEvent) {
		// The SDK yields the completed assistant message BEFORE the stream's
		// message_delta/message_stop on every tool-use turn (measured — this is
		// the norm, not a fallback). Record any tool_use blocks the stream hasn't
		// delivered yet, but do NOT end the pi stream here: message_delta, which
		// arrives tens of ms later, carries the message's real output-token count,
		// and message_stop is the normal turn end. Ending here froze usage at the
		// message_start placeholders (1–7 output tokens per tool turn). The grace
		// timer force-ends the turn if the terminal events never arrive, so pi
		// still gets to execute the tools and unblock the MCP handlers.
		if (appendMissingToolUsesFromAssistant(assistantMsg, model, customToolNameToPi)) {
			c.turnSawToolCall = true;
			scheduleToolUseTurnEnd(c, () => endToolUseTurn(c), "assistant-boundary");
		}
		return;
	}
	// The SDK yields the SAME assistant message more than once (per-block
	// partial copies and the completed message share one id). With stream
	// events, the streamed path already renders content and the duplicates are
	// naturally ignored; on this no-stream-events path each yield used to be
	// re-rendered wholesale — a rate-limited turn printed "You've hit your
	// weekly limit" twice. Same-message yields keep the turn's tracking (a
	// reset mid-message would wipe live tool-claim state) and render only
	// blocks not already rendered.
	const sameMessage = typeof assistantMsg.id === "string" && assistantMsg.id.length > 0 && assistantMsg.id === c.currentMessageId;
	if (!sameMessage) {
		reapStaleQueuedResults(c);
		c.resetToolTracking();
	}
	// The no-stream-events path also sees a message boundary. It is keyed on the
	// message ID rather than trusted blindly, because this branch is ALSO reached
	// for a message whose `message_start` already streamed — any message that
	// produced no content blocks, since `turnSawStreamEvent` only tracks those.
	c.beginChildMessage(assistantMsg.id);
	debug(`processAssistantMessage fallback: ${assistantMsg.content.length} blocks, types=${assistantMsg.content.map((b: any) => b.type).join(",")}${sameMessage ? " (same message re-yield)" : ""}`);
	const alreadyRendered = (type: string, content: string): boolean =>
		sameMessage && c.turnBlocks.some((b: any) => b.type === type && (type === "text" ? b.text : b.thinking) === content);
	for (const block of assistantMsg.content) {
		if (block.type === "text" && block.text) {
			if (alreadyRendered("text", block.text)) continue;
			ensureTurnStarted();
			c.turnBlocks.push({ type: "text", text: block.text });
			const idx = c.turnBlocks.length - 1;
			c.currentPiStream?.push({ type: "text_start", contentIndex: idx, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "text_delta", contentIndex: idx, delta: block.text, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "text_end", contentIndex: idx, content: block.text, partial: c.turnOutput });
		} else if (block.type === "thinking") {
			if (alreadyRendered("thinking", block.thinking ?? "")) continue;
			ensureTurnStarted();
			c.turnBlocks.push({ type: "thinking", thinking: block.thinking ?? "", thinkingSignature: block.signature ?? "" });
			const idx = c.turnBlocks.length - 1;
			c.currentPiStream?.push({ type: "thinking_start", contentIndex: idx, partial: c.turnOutput });
			if (block.thinking) c.currentPiStream?.push({ type: "thinking_delta", contentIndex: idx, delta: block.thinking, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "thinking_end", contentIndex: idx, content: block.thinking ?? "", partial: c.turnOutput });
		} else if (block.type === "tool_use") {
			if (isChildExecutedTool(block.name)) {
				// Same as the streamed path: the child owns this call, so it never
				// becomes a Pi tool call and never ends the turn.
				c.noteChildExecutedToolCall(block.id, block.name);
				debug(`processAssistantMessage fallback: child-executed tool ${block.name} [${block.id}] — not mirrored as a Pi tool call`);
				continue;
			}
			ensureTurnStarted();
			c.turnSawToolCall = true;
			const mappedName = mapToolName(block.name, customToolNameToPi);
			const mappedArgs = mapToolArgs(mappedName, block.input);
			c.recordToolCall(block.id, mappedName, mappedArgs);
			// A same-message re-yield of an already-mirrored call refreshes its
			// arguments in place — a second toolCall block would make pi dispatch
			// the tool twice.
			const existingIdx = c.turnBlocks.findIndex((b: any) => b.type === "toolCall" && b.id === block.id);
			if (existingIdx >= 0) {
				const existing = c.turnBlocks[existingIdx] as any;
				existing.name = mappedName;
				existing.arguments = mappedArgs;
				c.updateToolCallArgs(block.id, mappedArgs);
				continue;
			}
			c.turnBlocks.push({
				type: "toolCall", id: block.id,
				name: mappedName,
				arguments: mappedArgs,
			});
			const idx = c.turnBlocks.length - 1;
			const toolBlock = c.turnBlocks[idx];
			c.currentPiStream?.push({ type: "toolcall_start", contentIndex: idx, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "toolcall_end", contentIndex: idx, toolCall: toolBlock as any, partial: c.turnOutput });
		} else if (block.type === "fallback") {
			updateTurnOutputModel(block.to?.model);
		} else {
			debug("processAssistantMessage: unhandled block type", block.type);
		}
	}
	if (assistantMsg.usage && c.turnOutput) updateUsage(c.turnOutput, assistantMsg.usage, model);

	// End the stream on tool_use. Immediate (no grace deferral) ON PURPOSE: this
	// branch only runs when NO content blocks streamed for the message, so there
	// is no reason to expect terminal stream events either, and the completed
	// message's own usage — applied just above — is the best figure available.
	if (c.turnSawToolCall && c.currentPiStream && c.turnOutput) {
		endToolUseTurn(c);
	}
}
