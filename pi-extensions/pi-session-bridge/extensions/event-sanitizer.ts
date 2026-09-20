/**
 * Bridge event sanitizer.
 *
 * Compacts noisy Pi events (input, message_update, tool_execution_*, agent_end)
 * to small descriptors before they are pushed to history or broadcast to
 * bridge clients. Caps every envelope at a configured byte budget; raw
 * payloads spill to a per-session JSONL sidecar so `pi-bridge history --raw`
 * can still fetch them when an operator explicitly asks.
 *
 * Streaming events are the exception. Pi fires `message_update` once per token
 * and `tool_execution_update` once per partial tool result, and each payload
 * carries the whole cumulative value so far (`message`,
 * `assistantMessageEvent.partial`, `partialResult`). Serializing or measuring
 * that cumulative value costs O(n) per token and O(n^2) per turn, and spilling
 * it writes the same bytes to disk again. Streaming events therefore keep only
 * delta and identity fields, measure only the delta, and never carry a raw
 * payload; whole-value data reaches history on the terminal events
 * (`message_end`, `tool_execution_end`), which Pi fires once each.
 */

import { Buffer } from "node:buffer";

export const DEFAULT_MAX_EVENT_BYTES = 8 * 1024;
export const DEFAULT_MAX_HISTORY_BYTES = 4 * 1024 * 1024;
export const DEFAULT_MAX_HISTORY_RESPONSE_BYTES = 1 * 1024 * 1024;
export const DEFAULT_PREVIEW_BYTES = 256;

export interface SanitizerConfig {
	maxEventBytes: number;
	previewBytes: number;
}

export interface SanitizedEvent {
	/** Compact payload safe to broadcast and retain in history. */
	data: unknown;
	/** True when the sanitizer dropped or replaced detail vs the original. */
	truncated: boolean;
	/** Byte length of the JSON-serialized original payload; on a streaming event, of its delta alone. */
	originalBytes: number;
	/** Original payload preserved for sidecar spill; undefined when no truncation occurred. */
	raw?: unknown;
}

export function sanitizeBridgeEvent(eventName: string, payload: unknown, config: SanitizerConfig): SanitizedEvent {
	const previewBytes = Math.max(0, Math.floor(config.previewBytes));
	const maxEventBytes = Math.max(0, Math.floor(config.maxEventBytes));

	const streamingCompactor = STREAMING_DELTA_COMPACTORS.get(eventName);
	if (streamingCompactor) return sanitizeStreamingEvent(eventName, streamingCompactor, payload, previewBytes, maxEventBytes);

	const originalBytes = byteLengthOf(payload);
	const compactor = COMPACT_EVENT_COMPACTORS.get(eventName);
	if (compactor) {
		const compact = compactor(payload, previewBytes);
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

/**
 * Pi events reduced to a compact descriptor that keeps counts and previews.
 * Their whole payload is still spilled to the raw sidecar. An event absent
 * from this map and from {@link STREAMING_DELTA_COMPACTORS} is published
 * as it arrived, subject only to the event byte cap.
 */
const COMPACT_EVENT_COMPACTORS = new Map<string, (payload: unknown, previewBytes: number) => CompactResult>([
	["input", compactInputEvent],
	["tool_execution_start", compactToolExecution],
	["tool_execution_end", compactToolExecution],
	["agent_end", compactAgentEnd],
	["session_info_changed", compactSessionInfoChanged],
	["session_compact", compactSessionTree],
	["session_tree", compactSessionTree],
]);

function compactInputEvent(payload: unknown, previewBytes: number): CompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, truncated: false };

	const text = pickString(source, "text") ?? "";
	const sourceName = pickString(source, "source");
	const streamingBehavior = normalizeStreamingBehavior(source.streamingBehavior ?? source.streaming_behavior);
	const imagesCount = Array.isArray(source.images) ? source.images.length : undefined;
	const previewed = previewString(text, previewBytes);

	const compact: Record<string, unknown> = {
		textBytes: Buffer.byteLength(text, "utf8"),
		textLength: text.length,
		textPreview: previewed.preview,
	};
	if (sourceName !== undefined) compact.source = sourceName;
	if (streamingBehavior !== undefined) compact.streamingBehavior = streamingBehavior;
	if (imagesCount !== undefined) compact.imagesCount = imagesCount;
	if (previewed.truncated) compact.textTruncated = true;

	return { compact, truncated: true };
}

function normalizeStreamingBehavior(value: unknown): "steer" | "followUp" | undefined {
	if (value === "steer") return "steer";
	if (value === "followUp" || value === "follow-up" || value === "follow_up") return "followUp";
	return undefined;
}

interface StreamingCompactResult {
	/** Delta-only descriptor published in place of the payload. */
	compact: unknown;
	/** Byte length of the delta this event carried; never the cumulative value. */
	deltaBytes: number;
	/** True when the descriptor drops detail the payload held. */
	truncated: boolean;
}

type StreamingCompactor = (payload: unknown, previewBytes: number) => StreamingCompactResult;

/**
 * The per-event compactors for Pi's streaming events. Membership here is what
 * makes an event delta-only and unspillable, so the names live in one place.
 */
const STREAMING_DELTA_COMPACTORS = new Map<string, StreamingCompactor>([
	["message_update", compactMessageUpdate],
	["tool_execution_update", compactToolExecutionUpdate],
]);

function sanitizeStreamingEvent(
	eventName: string,
	compactor: StreamingCompactor,
	payload: unknown,
	previewBytes: number,
	maxEventBytes: number,
): SanitizedEvent {
	const streamed = compactor(payload, previewBytes);
	if (byteLengthOf(streamed.compact) <= maxEventBytes) {
		return { data: streamed.compact, truncated: streamed.truncated, originalBytes: streamed.deltaBytes };
	}
	// A single delta larger than the whole event budget still yields a
	// descriptor rather than a raw reference: streaming events never spill.
	return {
		data: oversizedDescriptor(eventName, streamed.deltaBytes, maxEventBytes),
		truncated: true,
		originalBytes: streamed.deltaBytes,
	};
}

/**
 * Compact a `message_update`.
 *
 * Reads the delta from the payload or from `assistantMessageEvent`, and takes
 * identity fields as plain property reads. The cumulative `message` and
 * `assistantMessageEvent.partial` are never serialized or measured.
 */
function compactMessageUpdate(payload: unknown, previewBytes: number): StreamingCompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, deltaBytes: byteLengthOf(payload), truncated: false };

	const stream = asRecord(source.assistantMessageEvent);
	const cumulative = asRecord(source.message) ?? (stream ? asRecord(stream.message) : undefined);
	const fromStream = <T>(pick: (record: Record<string, unknown>) => T | undefined): T | undefined => {
		if (stream) {
			const value = pick(stream);
			if (value !== undefined) return value;
		}
		return cumulative ? pick(cumulative) : undefined;
	};

	const role = pickString(source, "role") ?? fromStream((record) => pickString(record, "role"));
	const type = pickString(source, "type") ?? fromStream((record) => pickString(record, "type"));
	const contentIndex = pickNumber(source, "contentIndex")
		?? pickNumber(source, "content_index")
		?? fromStream((record) => pickNumber(record, "contentIndex") ?? pickNumber(record, "content_index"));
	const messageId = pickString(source, "messageId")
		?? pickString(source, "message_id")
		?? fromStream((record) => pickString(record, "id") ?? pickString(record, "messageId") ?? pickString(record, "message_id"));

	const delta = pickDelta(source) ?? (stream ? pickDelta(stream) : undefined);

	let deltaLength: number | undefined;
	let deltaBytes = 0;
	let deltaPreview: string | undefined;
	let deltaTruncated = false;

	if (delta !== undefined) {
		const serialized = typeof delta === "string" ? delta : safeStringify(delta);
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
			...(deltaLength !== undefined ? { deltaLength, deltaBytes } : {}),
			...(deltaPreview !== undefined ? { deltaPreview } : {}),
			...(deltaTruncated ? { deltaTruncated: true } : {}),
		},
		deltaBytes,
		truncated: true,
	};
}

/**
 * Compact a `tool_execution_update`.
 *
 * Pi's payload carries `partialResult`, the tool output so far, which grows
 * with every update. The descriptor keeps the call's identity only; the whole
 * result reaches history on `tool_execution_end`.
 */
function compactToolExecutionUpdate(payload: unknown): StreamingCompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, deltaBytes: byteLengthOf(payload), truncated: false };
	return { compact: toolExecutionIdentity(source), deltaBytes: 0, truncated: true };
}

function pickDelta(source: Record<string, unknown>): unknown {
	const value = source.delta;
	return value === undefined || value === null ? undefined : value;
}

function toolExecutionInner(source: Record<string, unknown>): Record<string, unknown> | undefined {
	return asRecord(source.toolUse) ?? asRecord(source.toolCall) ?? asRecord(source.tool_call) ?? asRecord(source.toolExecution);
}

/** Constant-size fields naming the tool call, shared by every `tool_execution_*` descriptor. */
function toolExecutionIdentity(source: Record<string, unknown>): Record<string, unknown> {
	const inner = toolExecutionInner(source);
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

	const identity: Record<string, unknown> = {};
	if (toolName !== undefined) identity.toolName = toolName;
	if (toolUseId !== undefined) identity.toolUseId = toolUseId;
	if (status !== undefined) identity.status = status;
	if (isError !== undefined) identity.isError = isError;
	if (artifactPath !== undefined) identity.artifactPath = artifactPath;
	if (logPath !== undefined) identity.logPath = logPath;
	if (detailPath !== undefined) identity.detailPath = detailPath;
	return identity;
}

function compactToolExecution(payload: unknown, previewBytes: number): CompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, truncated: false };

	const inner = toolExecutionInner(source);
	const lookup = (key: string): unknown => source[key] ?? (inner ? inner[key] : undefined);
	const compact = toolExecutionIdentity(source);

	let truncated = false;
	for (const [key, target] of [
		["input", "inputPreview"],
		["arguments", "argumentsPreview"],
		["args", "argsPreview"],
		["result", "resultPreview"],
		["output", "outputPreview"],
		["content", "contentPreview"],
		["error", "errorPreview"],
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
	const willRetry = readBoolean(source.willRetry) ?? readBoolean(source.will_retry);
	const usage = source.usage && typeof source.usage === "object" ? source.usage : undefined;

	const compact: Record<string, unknown> = {};
	if (status !== undefined) compact.status = status;
	if (stopReason !== undefined) compact.stopReason = stopReason;
	if (willRetry !== undefined) compact.willRetry = willRetry;
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

function compactSessionInfoChanged(payload: unknown, previewBytes: number): CompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, truncated: false };

	// Pi sends `{ type, name }` and nothing else; `name` is undefined when the
	// session name is cleared, so an empty compact is a legitimate outcome.
	const name = pickString(source, "name");
	const compact: Record<string, unknown> = {};
	if (name !== undefined) {
		const previewed = previewString(name, previewBytes);
		compact.nameBytes = Buffer.byteLength(name, "utf8");
		compact.nameLength = name.length;
		compact.namePreview = previewed.preview;
		if (previewed.truncated) compact.nameTruncated = true;
	}

	// The descriptor replaces the payload record wholesale (every unrecognized
	// key is dropped), so report the replacement and let the raw spill keep the
	// original — same contract as compactInputEvent/compactAgentEnd.
	return { compact, truncated: true };
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
