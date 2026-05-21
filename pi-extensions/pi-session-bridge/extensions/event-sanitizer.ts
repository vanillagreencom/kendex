/**
 * Bridge event sanitizer.
 *
 * Compacts noisy Pi events (message_update, tool_execution_*, agent_end)
 * to small descriptors before they are pushed to history or broadcast to
 * bridge clients. Caps every envelope at a configured byte budget; raw
 * payloads spill to a per-session JSONL sidecar so `pi-bridge history --raw`
 * can still fetch them when an operator explicitly asks.
 */

import { Buffer } from "node:buffer";

export const DEFAULT_MAX_EVENT_BYTES = 8 * 1024;
export const DEFAULT_MAX_HISTORY_BYTES = 4 * 1024 * 1024;
export const DEFAULT_MAX_HISTORY_RESPONSE_BYTES = 1 * 1024 * 1024;
export const DEFAULT_PREVIEW_BYTES = 256;

const COMPACTED_EVENT_NAMES = new Set([
	"message_update",
	"tool_execution_start",
	"tool_execution_update",
	"tool_execution_end",
	"agent_end",
	"session_compact",
	"session_tree",
]);

export interface SanitizerConfig {
	maxEventBytes: number;
	previewBytes: number;
}

export interface SanitizedEvent {
	/** Compact payload safe to broadcast and retain in history. */
	data: unknown;
	/** True when the sanitizer dropped or replaced detail vs the original. */
	truncated: boolean;
	/** Byte length of the JSON-serialized original payload. */
	originalBytes: number;
	/** Original payload preserved for sidecar spill; undefined when no truncation occurred. */
	raw?: unknown;
}

export function sanitizeBridgeEvent(eventName: string, payload: unknown, config: SanitizerConfig): SanitizedEvent {
	const originalBytes = byteLengthOf(payload);
	const previewBytes = Math.max(0, Math.floor(config.previewBytes));
	const maxEventBytes = Math.max(0, Math.floor(config.maxEventBytes));

	if (COMPACTED_EVENT_NAMES.has(eventName)) {
		const compact = compactKnownEvent(eventName, payload, previewBytes);
		const truncated = compact.truncated || compact.compact !== payload;
		return finalize(compact.compact, originalBytes, truncated, payload, maxEventBytes, eventName);
	}

	if (originalBytes <= maxEventBytes) {
		return { data: payload, truncated: false, originalBytes };
	}

	const descriptor = oversizedDescriptor(eventName, originalBytes, maxEventBytes);
	return { data: descriptor, truncated: true, originalBytes, raw: payload };
}

function finalize(
	compact: unknown,
	originalBytes: number,
	truncated: boolean,
	raw: unknown,
	maxEventBytes: number,
	eventName: string,
): SanitizedEvent {
	const bytes = byteLengthOf(compact);
	if (bytes <= maxEventBytes) {
		return { data: compact, truncated, originalBytes, raw: truncated ? raw : undefined };
	}
	const descriptor = oversizedDescriptor(eventName, originalBytes, maxEventBytes);
	return { data: descriptor, truncated: true, originalBytes, raw };
}

function oversizedDescriptor(eventName: string, originalBytes: number, maxEventBytes: number) {
	return {
		summary: `${eventName} payload omitted (exceeded ${maxEventBytes} bytes)`,
		truncated: true,
		originalBytes,
		maxBytes: maxEventBytes,
	};
}

interface CompactResult {
	compact: unknown;
	truncated: boolean;
}

function compactKnownEvent(eventName: string, payload: unknown, previewBytes: number): CompactResult {
	switch (eventName) {
		case "message_update":
			return compactMessageUpdate(payload, previewBytes);
		case "tool_execution_start":
		case "tool_execution_update":
		case "tool_execution_end":
			return compactToolExecution(eventName, payload, previewBytes);
		case "agent_end":
			return compactAgentEnd(payload, previewBytes);
		case "session_compact":
		case "session_tree":
			return compactSessionTree(payload, previewBytes);
		default:
			return { compact: payload, truncated: false };
	}
}

function compactMessageUpdate(payload: unknown, previewBytes: number): CompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, truncated: false };

	const inner = pickInnerMessage(source);
	const role = pickString(source, "role") ?? (inner ? pickString(inner, "role") : undefined);
	const type = pickString(source, "type") ?? (inner ? pickString(inner, "type") : undefined);
	const contentIndex = pickNumber(source, "contentIndex")
		?? pickNumber(source, "content_index")
		?? (inner ? pickNumber(inner, "contentIndex") ?? pickNumber(inner, "content_index") : undefined);
	const messageId = pickString(source, "messageId")
		?? pickString(source, "message_id")
		?? (inner ? pickString(inner, "id") ?? pickString(inner, "messageId") ?? pickString(inner, "message_id") : undefined);

	const candidate = pickDeltaCandidate(source) ?? (inner ? pickDeltaCandidate(inner) : undefined);

	let deltaLength: number | undefined;
	let deltaBytes: number | undefined;
	let deltaPreview: string | undefined;
	let deltaTruncated = false;

	if (candidate !== undefined) {
		const serialized = typeof candidate === "string" ? candidate : safeStringify(candidate);
		deltaLength = serialized.length;
		deltaBytes = Buffer.byteLength(serialized, "utf8");
		const previewed = previewString(serialized, previewBytes);
		deltaPreview = previewed.preview;
		deltaTruncated = previewed.truncated;
	}

	return {
		compact: {
			...(role !== undefined ? { role } : {}),
			...(type !== undefined ? { type } : {}),
			...(messageId !== undefined ? { messageId } : {}),
			...(contentIndex !== undefined ? { contentIndex } : {}),
			...(deltaLength !== undefined ? { deltaLength } : {}),
			...(deltaBytes !== undefined ? { deltaBytes } : {}),
			...(deltaPreview !== undefined ? { deltaPreview } : {}),
		},
		truncated: deltaTruncated || candidate !== undefined,
	};
}

function pickInnerMessage(source: Record<string, unknown>): Record<string, unknown> | undefined {
	const nestedEvent = asRecord(source.assistantMessageEvent);
	if (nestedEvent) {
		const nestedMessage = asRecord(nestedEvent.message);
		if (nestedMessage) return nestedMessage;
		return nestedEvent;
	}
	const message = asRecord(source.message);
	if (message) return message;
	return undefined;
}

function pickDeltaCandidate(source: Record<string, unknown>): unknown {
	if (source.delta !== undefined && source.delta !== null) return source.delta;
	if (source.text !== undefined && source.text !== null) return source.text;
	if (source.content !== undefined && source.content !== null) return source.content;
	return undefined;
}

function compactToolExecution(eventName: string, payload: unknown, previewBytes: number): CompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, truncated: false };

	const inner = asRecord(source.toolUse) ?? asRecord(source.toolCall) ?? asRecord(source.tool_call) ?? asRecord(source.toolExecution);
	const lookup = (key: string): unknown => source[key] ?? (inner ? inner[key] : undefined);
	const lookupString = (key: string): string | undefined => {
		const direct = pickString(source, key);
		if (direct !== undefined) return direct;
		if (!inner) return undefined;
		return pickString(inner, key);
	};

	const toolName = lookupString("toolName") ?? lookupString("tool_name") ?? lookupString("name");
	const toolUseId = lookupString("toolUseId")
		?? lookupString("tool_use_id")
		?? lookupString("toolCallId")
		?? lookupString("tool_call_id")
		?? lookupString("id");
	const status = lookupString("status");
	const isError = readBoolean(source.isError) ?? readBoolean(source.is_error) ?? (inner ? readBoolean(inner.isError) ?? readBoolean(inner.is_error) : undefined);
	const artifactPath = lookupString("artifactPath") ?? lookupString("artifact_path");
	const logPath = lookupString("logPath") ?? lookupString("log_path");
	const detailPath = lookupString("detailPath") ?? lookupString("detail_path");

	const compact: Record<string, unknown> = {};
	if (toolName !== undefined) compact.toolName = toolName;
	if (toolUseId !== undefined) compact.toolUseId = toolUseId;
	if (status !== undefined) compact.status = status;
	if (isError !== undefined) compact.isError = isError;
	if (artifactPath !== undefined) compact.artifactPath = artifactPath;
	if (logPath !== undefined) compact.logPath = logPath;
	if (detailPath !== undefined) compact.detailPath = detailPath;

	let truncated = false;
	for (const [key, target] of [
		["input", "inputPreview"],
		["arguments", "argumentsPreview"],
		["args", "argsPreview"],
		["result", "resultPreview"],
		["output", "outputPreview"],
		["content", "contentPreview"],
		["error", "errorPreview"],
		["delta", "deltaPreview"],
	] as const) {
		const value = lookup(key);
		if (value === undefined || value === null) continue;
		const measurement = measurePayload(value, previewBytes);
		compact[`${key}Bytes`] = measurement.bytes;
		compact[target] = measurement.preview;
		if (measurement.truncated) truncated = true;
	}

	// Surface explicit truncation marker upstream layers already set.
	if (source.truncated === true) truncated = true;

	return { compact, truncated };
}

function readBoolean(value: unknown): boolean | undefined {
	return typeof value === "boolean" ? value : undefined;
}

function compactAgentEnd(payload: unknown, previewBytes: number): CompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, truncated: false };

	const status = pickString(source, "status");
	const stopReason = pickString(source, "stopReason") ?? pickString(source, "stop_reason");
	const usage = source.usage && typeof source.usage === "object" ? source.usage : undefined;

	const compact: Record<string, unknown> = {};
	if (status !== undefined) compact.status = status;
	if (stopReason !== undefined) compact.stopReason = stopReason;
	if (usage !== undefined) compact.usage = usage;

	const finalText = pickAgentEndFinalText(source);
	const messagesCount = pickAgentEndMessageCount(source);
	if (messagesCount !== undefined) compact.messagesCount = messagesCount;
	if (finalText !== undefined) {
		const previewed = previewString(finalText, previewBytes);
		compact.finalTextBytes = Buffer.byteLength(finalText, "utf8");
		compact.finalTextLength = finalText.length;
		compact.finalTextPreview = previewed.preview;
		if (previewed.truncated) compact.finalTextTruncated = true;
	}

	return { compact, truncated: true };
}

function pickAgentEndFinalText(source: Record<string, unknown>): string | undefined {
	const messages = source.messages;
	if (Array.isArray(messages)) {
		const direct = extractFinalText(messages);
		if (direct !== undefined) return direct;
	}
	const single = asRecord(source.message);
	if (single) {
		const text = extractFinalText([single]);
		if (text !== undefined) return text;
	}
	const content = source.content;
	if (typeof content === "string" && content.trim().length > 0) return content;
	if (Array.isArray(content)) {
		const text = extractFinalTextFromBlocks(content);
		if (text !== undefined) return text;
	}
	const text = source.text;
	if (typeof text === "string" && text.trim().length > 0) return text;
	const finalText = source.finalText ?? source.final_text;
	if (typeof finalText === "string" && finalText.trim().length > 0) return finalText;
	return undefined;
}

function pickAgentEndMessageCount(source: Record<string, unknown>): number | undefined {
	if (Array.isArray(source.messages)) return source.messages.length;
	if (typeof source.messagesCount === "number" && Number.isFinite(source.messagesCount)) return source.messagesCount;
	if (typeof source.messages_count === "number" && Number.isFinite(source.messages_count)) return source.messages_count;
	if (asRecord(source.message)) return 1;
	return undefined;
}

function compactSessionTree(payload: unknown, previewBytes: number): CompactResult {
	const measurement = measurePayload(payload, previewBytes);
	return {
		compact: {
			bytes: measurement.bytes,
			preview: measurement.preview,
			...(measurement.truncated ? { truncated: true } : {}),
		},
		truncated: measurement.truncated,
	};
}

function extractFinalText(messages: unknown[]): string | undefined {
	for (let i = messages.length - 1; i >= 0; i--) {
		const message = messages[i];
		if (!message || typeof message !== "object") continue;
		const record = message as Record<string, unknown>;
		const directText = record.text;
		if (typeof directText === "string" && directText.trim().length > 0) return directText;
		const content = record.content;
		if (typeof content === "string" && content.trim().length > 0) return content;
		if (Array.isArray(content)) {
			const text = extractFinalTextFromBlocks(content);
			if (text !== undefined) return text;
		}
	}
	return undefined;
}

function extractFinalTextFromBlocks(blocks: unknown[]): string | undefined {
	for (let j = blocks.length - 1; j >= 0; j--) {
		const block = blocks[j];
		if (!block || typeof block !== "object") continue;
		const text = (block as Record<string, unknown>).text;
		if (typeof text === "string" && text.trim().length > 0) return text;
	}
	return undefined;
}

interface PreviewMeasurement {
	preview: string;
	bytes: number;
	truncated: boolean;
}

function previewString(value: string, maxBytes: number): PreviewMeasurement {
	const bytes = Buffer.byteLength(value, "utf8");
	if (bytes <= maxBytes) return { preview: value, bytes, truncated: false };
	let cut = value.slice(0, Math.max(1, maxBytes));
	while (Buffer.byteLength(cut, "utf8") > maxBytes && cut.length > 0) cut = cut.slice(0, -1);
	return { preview: cut, bytes, truncated: true };
}

function measurePayload(value: unknown, previewBytes: number): PreviewMeasurement {
	if (typeof value === "string") return previewString(value, previewBytes);
	const serialized = safeStringify(value);
	return previewString(serialized, previewBytes);
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
	return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
}

function pickString(source: Record<string, unknown>, key: string): string | undefined {
	const value = source[key];
	return typeof value === "string" ? value : undefined;
}

function pickNumber(source: Record<string, unknown>, key: string): number | undefined {
	const value = source[key];
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function safeStringify(value: unknown): string {
	try {
		return JSON.stringify(value) ?? "";
	} catch {
		return "";
	}
}

function byteLengthOf(value: unknown): number {
	return Buffer.byteLength(safeStringify(value), "utf8");
}

/** Visible for tests. */
export const __internals = { byteLengthOf, previewString };
