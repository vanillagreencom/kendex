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

	const role = pickString(source, "role");
	const type = pickString(source, "type");
	const contentIndex = pickNumber(source, "contentIndex") ?? pickNumber(source, "content_index");
	const delta = source.delta;
	const messageId = pickString(source, "messageId") ?? pickString(source, "message_id");

	let deltaLength: number | undefined;
	let deltaBytes: number | undefined;
	let deltaPreview: string | undefined;
	let deltaTruncated = false;

	if (typeof delta === "string") {
		deltaLength = delta.length;
		deltaBytes = Buffer.byteLength(delta, "utf8");
		const previewed = previewString(delta, previewBytes);
		deltaPreview = previewed.preview;
		deltaTruncated = previewed.truncated;
	} else if (delta != null) {
		const serialized = safeStringify(delta);
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
		truncated: deltaTruncated || deltaBytes !== undefined,
	};
}

function compactToolExecution(eventName: string, payload: unknown, previewBytes: number): CompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, truncated: false };

	const toolName = pickString(source, "toolName") ?? pickString(source, "tool_name") ?? pickString(source, "name");
	const toolUseId = pickString(source, "toolUseId") ?? pickString(source, "tool_use_id") ?? pickString(source, "id");
	const status = pickString(source, "status");
	const isError = typeof source.isError === "boolean" ? (source.isError as boolean) : typeof source.is_error === "boolean" ? (source.is_error as boolean) : undefined;
	const artifactPath = pickString(source, "artifactPath") ?? pickString(source, "artifact_path");
	const logPath = pickString(source, "logPath") ?? pickString(source, "log_path");
	const detailPath = pickString(source, "detailPath") ?? pickString(source, "detail_path");

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
		["error", "errorPreview"],
		["delta", "deltaPreview"],
	] as const) {
		const value = source[key];
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

function compactAgentEnd(payload: unknown, previewBytes: number): CompactResult {
	const source = asRecord(payload);
	if (!source) return { compact: payload, truncated: false };

	const status = pickString(source, "status");
	const stopReason = pickString(source, "stopReason") ?? pickString(source, "stop_reason");
	const usage = source.usage && typeof source.usage === "object" ? source.usage : undefined;
	const messages = source.messages;

	const compact: Record<string, unknown> = {};
	if (status !== undefined) compact.status = status;
	if (stopReason !== undefined) compact.stopReason = stopReason;
	if (usage !== undefined) compact.usage = usage;

	if (Array.isArray(messages)) {
		compact.messagesCount = messages.length;
		const finalText = extractFinalText(messages);
		if (finalText !== undefined) {
			const previewed = previewString(finalText, previewBytes);
			compact.finalTextBytes = Buffer.byteLength(finalText, "utf8");
			compact.finalTextLength = finalText.length;
			compact.finalTextPreview = previewed.preview;
			if (previewed.truncated) compact.finalTextTruncated = true;
		}
	}

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
		const content = (message as Record<string, unknown>).content;
		if (typeof content === "string" && content.trim().length > 0) return content;
		if (Array.isArray(content)) {
			for (let j = content.length - 1; j >= 0; j--) {
				const block = content[j];
				if (!block || typeof block !== "object") continue;
				const text = (block as Record<string, unknown>).text;
				if (typeof text === "string" && text.trim().length > 0) return text;
			}
		}
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

/**
 * Cap an array of envelopes to a byte budget, dropping older items first.
 * Always returns at least one envelope when input has any (the most recent),
 * even if that single envelope exceeds the budget — operators still see the
 * latest event rather than an empty response.
 */
export function trimEnvelopesByBytes<T>(envelopes: T[], maxBytes: number): { events: T[]; truncated: boolean } {
	if (envelopes.length === 0) return { events: [], truncated: false };
	const cap = Math.max(0, Math.floor(maxBytes));
	let bytes = 0;
	const out: T[] = [];
	for (let i = envelopes.length - 1; i >= 0; i--) {
		const piece = byteLengthOf(envelopes[i]);
		if (out.length > 0 && bytes + piece > cap) return { events: out, truncated: true };
		out.unshift(envelopes[i] as T);
		bytes += piece;
	}
	return { events: out, truncated: false };
}

/** Visible for tests. */
export const __internals = { byteLengthOf, previewString };
