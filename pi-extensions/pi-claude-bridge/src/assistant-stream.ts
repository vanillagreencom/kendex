import { calculateCost, type AssistantMessage, type Model } from "@earendil-works/pi-ai";
import { type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { debug } from "./debug.js";
import { ctx } from "./query-state.js";
import { mapToolArgs, mapToolName } from "./tool-mapping.js";

// --- Usage helpers ---

function updateUsage(output: AssistantMessage, usage: Record<string, number | undefined>, model: Model<any>): void {
	if (usage.input_tokens != null) output.usage.input = usage.input_tokens;
	if (usage.output_tokens != null) output.usage.output = usage.output_tokens;
	if (usage.cache_read_input_tokens != null) output.usage.cacheRead = usage.cache_read_input_tokens;
	if (usage.cache_creation_input_tokens != null) output.usage.cacheWrite = usage.cache_creation_input_tokens;
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

export function updateTurnOutputModel(modelId: unknown): void {
	const c = ctx();
	if (typeof modelId !== "string" || !modelId || !c.turnOutput) return;
	if (c.turnOutput.model === modelId) return;
	debug(`provider: active Claude model changed ${c.turnOutput.model} -> ${modelId}`);
	c.turnOutput.model = modelId;
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
		c.resetToolTracking();
		updateTurnOutputModel(event.message?.model);
		if (event.message?.usage) updateUsage(c.turnOutput, event.message.usage, model);
		return;
	}

	if (event?.type === "content_block_start") {
		c.turnSawStreamEvent = true;
		ensureTurnStarted();
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
		// Tool call complete — end this pi stream. The SDK will still yield an
		// assistant message for this turn, but currentPiStream=null causes
		// consumeQuery to skip it. The MCP handler blocks the generator until
		// pi delivers the tool result via the next streamSimple call.
		c.turnOutput.stopReason = "toolUse";
		c.currentPiStream!.push({ type: "done", reason: "toolUse", message: c.turnOutput });
		c.currentPiStream!.end();
		c.currentPiStream = null;

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
	if (assistantMsg.usage && c.turnOutput) updateUsage(c.turnOutput, assistantMsg.usage, model);
	return sawToolUse;
}

export function processAssistantMessage(message: SDKMessage, model: Model<any>, customToolNameToPi: Map<string, string>): void {
	const c = ctx();
	const assistantMsg = (message as any).message;
	if (!assistantMsg?.content) return;
	updateTurnOutputModel(assistantMsg.model);
	if (c.turnSawStreamEvent) {
		// Claude Agent SDK can yield the completed assistant message before (or
		// instead of) a stream_event message_stop for a tool-use turn. Treat that
		// assistant message as a hard turn boundary so Pi executes the tool calls
		// and the MCP handlers stay blocked until real tool results are delivered.
		// Without this fallback, Claude Code can continue internally with empty MCP
		// results and Pi only sees the real outputs one render cycle later.
		if (appendMissingToolUsesFromAssistant(assistantMsg, model, customToolNameToPi)) {
			c.turnSawToolCall = true;
			if (c.currentPiStream && c.turnOutput) {
				c.turnOutput.stopReason = "toolUse";
				c.currentPiStream.push({ type: "done", reason: "toolUse", message: c.turnOutput });
				c.currentPiStream.end();
				c.currentPiStream = null;
				debug("processAssistantMessage boundary: ended streamed tool_use turn from assistant message");
			}
		}
		return;
	}
	c.resetToolTracking();
	debug(`processAssistantMessage fallback: ${assistantMsg.content.length} blocks, types=${assistantMsg.content.map((b: any) => b.type).join(",")}`);
	for (const block of assistantMsg.content) {
		if (block.type === "text" && block.text) {
			ensureTurnStarted();
			c.turnBlocks.push({ type: "text", text: block.text });
			const idx = c.turnBlocks.length - 1;
			c.currentPiStream?.push({ type: "text_start", contentIndex: idx, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "text_delta", contentIndex: idx, delta: block.text, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "text_end", contentIndex: idx, content: block.text, partial: c.turnOutput });
		} else if (block.type === "thinking") {
			ensureTurnStarted();
			c.turnBlocks.push({ type: "thinking", thinking: block.thinking ?? "", thinkingSignature: block.signature ?? "" });
			const idx = c.turnBlocks.length - 1;
			c.currentPiStream?.push({ type: "thinking_start", contentIndex: idx, partial: c.turnOutput });
			if (block.thinking) c.currentPiStream?.push({ type: "thinking_delta", contentIndex: idx, delta: block.thinking, partial: c.turnOutput });
			c.currentPiStream?.push({ type: "thinking_end", contentIndex: idx, content: block.thinking ?? "", partial: c.turnOutput });
		} else if (block.type === "tool_use") {
			ensureTurnStarted();
			c.turnSawToolCall = true;
			const mappedName = mapToolName(block.name, customToolNameToPi);
			const mappedArgs = mapToolArgs(mappedName, block.input);
			c.recordToolCall(block.id, mappedName, mappedArgs);
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

	// End the stream on tool_use, same as processStreamEvent's message_stop handler.
	if (c.turnSawToolCall && c.currentPiStream && c.turnOutput) {
		c.turnOutput.stopReason = "toolUse";
		c.currentPiStream.push({ type: "done", reason: "toolUse", message: c.turnOutput });
		c.currentPiStream.end();
		c.currentPiStream = null;
	}
}
