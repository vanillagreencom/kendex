export interface NormalizedTranscriptEvent {
	event: any;
	name?: string;
	payload: any;
}

export function normalizePiStreamEvent(event: any): NormalizedTranscriptEvent {
	if (!event || typeof event !== "object") return { event, payload: event };
	if (typeof event.event === "string") {
		const data = event.data && typeof event.data === "object" && !Array.isArray(event.data) ? event.data : {};
		const canonical = { ...data, type: event.event };
		return { event: canonical, name: event.event, payload: canonical };
	}
	if (event.event && typeof event.event === "object" && !Array.isArray(event.event)) {
		const canonical = event.event;
		const name = typeof canonical.type === "string" ? canonical.type : undefined;
		return { event: canonical, name, payload: canonical };
	}
	const name = typeof event.type === "string" ? event.type : undefined;
	return { event, name, payload: event };
}

// Pi 0.84.0 made the JSON/RPC `message_update` wire event delta-only: `toJsonEvent()`
// drops the cumulative top-level `message` and `assistantMessageEvent.partial` snapshots
// that used to carry the whole message-so-far. Keeping only the newest event therefore
// preserves a single token, so the failure-path transcript flush has to rebuild the
// partial assistant message from the deltas it saw since the last message boundary.
//
// Tool calls are deliberately not reconstructed here: their lifecycle is already recorded
// through the separate tool_execution_* transcript events.
/** Replace accumulated blocks with the content of a cumulative snapshot message. */
function seedBlocksFromSnapshot(state: PartialAssistantMessageState, snapshot: any): void {
	state.blocks.clear();
	const content = Array.isArray(snapshot?.content) ? snapshot.content : undefined;
	if (!content) return;
	content.forEach((part: any, index: number) => {
		if (!part || typeof part !== "object") return;
		if (part.type === "text" && typeof part.text === "string") state.blocks.set(index, { kind: "text", text: part.text });
		else if (part.type === "thinking" && typeof part.thinking === "string") state.blocks.set(index, { kind: "thinking", text: part.thinking });
	});
}

/** Stream event types that legitimately contribute no reconstructable content. */
const PARTIAL_MESSAGE_IGNORED_TYPES = new Set(["start", "text_start", "thinking_start", "toolcall_start", "toolcall_delta", "toolcall_end", "done", "error"]);

export type PartialAssistantContentBlock =
	| { type: "text"; text: string }
	| { type: "thinking"; thinking: string };

export interface PartialAssistantMessageState {
	/** contentIndex -> block, so out-of-order or interleaved indices still land correctly. */
	blocks: Map<number, { kind: "text" | "thinking"; text: string }>;
	/**
	 * Whether the LAST applied event carried its own cumulative snapshot (older Pi, or a shape
	 * that kept `partial`). Tracked per event, not sticky: the flush only cares whether the one
	 * event it is writing already carries the message, so a later delta-only event clears it.
	 */
	hasSnapshot: boolean;
	/** Applied `message_update` payloads since the last reset — the denominator for a silent-drop check. */
	updatesSeen: number;
	/** Unrecognized `assistantMessageEvent.type` values dropped since the last reset. */
	unrecognizedTypes: Set<string>;
}

export function createPartialAssistantMessageState(): PartialAssistantMessageState {
	return { blocks: new Map(), hasSnapshot: false, updatesSeen: 0, unrecognizedTypes: new Set() };
}

export function resetPartialAssistantMessage(state: PartialAssistantMessageState): void {
	state.blocks.clear();
	state.hasSnapshot = false;
	state.updatesSeen = 0;
	state.unrecognizedTypes.clear();
}

/** Fold one `message_update` payload into the reconstructed partial assistant message. */
export function applyPartialAssistantMessage(state: PartialAssistantMessageState, payload: any): void {
	if (!payload || typeof payload !== "object") return;
	state.updatesSeen += 1;
	const streamEvent = payload.assistantMessageEvent;
	const nestedEvent = streamEvent && typeof streamEvent === "object" ? streamEvent : undefined;
	const snapshot = payload.message ?? nestedEvent?.partial;
	state.hasSnapshot = Boolean(snapshot);
	if (snapshot) {
		// The snapshot is the authoritative message-so-far, so it supersedes everything
		// accumulated before it. Reseeding from it (rather than just flagging) keeps a mixed
		// stream correct: if a later delta-only event arrives, it appends to the snapshot's
		// content instead of to stale pre-snapshot fragments.
		seedBlocksFromSnapshot(state, snapshot);
		return;
	}
	if (!nestedEvent) {
		state.unrecognizedTypes.add("<no assistantMessageEvent>");
		return;
	}
	const type = typeof nestedEvent.type === "string" ? nestedEvent.type : undefined;
	if (!type) {
		state.unrecognizedTypes.add("<no type>");
		return;
	}
	const contentIndex = typeof nestedEvent.contentIndex === "number" ? nestedEvent.contentIndex : 0;
	const kind = type.startsWith("thinking") ? "thinking" : type.startsWith("text") ? "text" : undefined;

	if (kind && type.endsWith("_end")) {
		// `*_end` carries the authoritative full block content; prefer it over accumulated deltas.
		if (typeof nestedEvent.content === "string") state.blocks.set(contentIndex, { kind, text: nestedEvent.content });
		return;
	}
	if (kind && type.endsWith("_delta")) {
		if (typeof nestedEvent.delta !== "string" || nestedEvent.delta.length === 0) return;
		const existing = state.blocks.get(contentIndex);
		if (existing && existing.kind === kind) existing.text += nestedEvent.delta;
		else state.blocks.set(contentIndex, { kind, text: nestedEvent.delta });
		return;
	}
	// A shape we do not know how to fold in. Recording it is what turns a future wire-format
	// change into a reported diagnostic instead of a silently empty forensic record.
	if (!PARTIAL_MESSAGE_IGNORED_TYPES.has(type)) state.unrecognizedTypes.add(type);
}

/**
 * The reconstructed assistant message, or undefined when nothing was accumulated or the
 * event being flushed already carries its own cumulative snapshot. Content blocks use Pi's
 * own shapes (`{ type: "text", text }` / `{ type: "thinking", thinking }`) so the record is
 * readable by the same helpers that read a real assistant message.
 */
export function partialAssistantMessage(state: PartialAssistantMessageState): { role: "assistant"; content: PartialAssistantContentBlock[] } | undefined {
	if (state.hasSnapshot || state.blocks.size === 0) return undefined;
	const content = [...state.blocks.entries()]
		.sort(([a], [b]) => a - b)
		.filter(([, block]) => block.text.length > 0)
		.map(([, block]): PartialAssistantContentBlock => (block.kind === "thinking"
			? { type: "thinking", thinking: block.text }
			: { type: "text", text: block.text }));
	return content.length > 0 ? { role: "assistant", content } : undefined;
}

/**
 * A diagnostic whenever any event shape was dropped — the signal that Pi's wire format
 * moved and this shim went stale. Reported even when some blocks WERE rebuilt: a mixed
 * stream would otherwise flush a plausible-looking partial answer with no indication that
 * part of it was silently discarded, which is the failure this tracking exists to catch.
 */
export function partialAssistantMessageDiagnostic(state: PartialAssistantMessageState): string | undefined {
	if (state.hasSnapshot || state.updatesSeen === 0) return undefined;
	if (state.unrecognizedTypes.size === 0) return undefined;
	const types = [...state.unrecognizedTypes].sort().join(", ");
	if (state.blocks.size === 0) {
		return `partial assistant message could not be rebuilt from ${state.updatesSeen} message_update event(s); unrecognized assistantMessageEvent type(s): ${types}`;
	}
	return `partial assistant message may be incomplete: rebuilt from ${state.updatesSeen} message_update event(s) with unrecognized assistantMessageEvent type(s) dropped: ${types}`;
}

export function normalizeTranscriptRecordEvent(record: any): NormalizedTranscriptEvent {
	if (!record || typeof record !== "object") return { event: record, payload: record };
	if (record.event && typeof record.event === "object") return normalizePiStreamEvent(record.event);
	return normalizePiStreamEvent(record);
}

export function normalizeInputDelivery(value: unknown): "steer" | "follow-up" | "send" | undefined {
	if (value === "steer") return "steer";
	if (value === "send") return "send";
	if (value === "followUp" || value === "follow-up" || value === "follow_up") return "follow-up";
	return undefined;
}

export function inputDeliveryLabel(value: unknown): string | undefined {
	return normalizeInputDelivery(value);
}

function oneLine(text: string, maxChars = 500): string {
	const compact = text.replace(/\s+/g, " ").trim();
	return compact.length > maxChars ? `${compact.slice(0, maxChars - 1)}…` : compact;
}

function stringValue(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

function numberValue(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function textFromMessageContent(content: unknown): string | undefined {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return undefined;
	const text = content.find((part: any) => part?.type === "text" && typeof part.text === "string");
	return text?.text;
}

const TIMELINE_PREVIEW_MAX = 160;

function formatByteSize(bytes: number): string {
	if (bytes < 1024) return `${bytes}B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}

function formatElapsedStamp(ms: number | undefined): string {
	if (ms === undefined || !Number.isFinite(ms) || ms < 0) return "--:--";
	const totalSeconds = Math.floor(ms / 1000);
	const hours = Math.floor(totalSeconds / 3600);
	const minutes = Math.floor((totalSeconds % 3600) / 60);
	const seconds = totalSeconds % 60;
	if (hours > 0) return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
	return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function formatToolDuration(ms: number | undefined): string | undefined {
	if (ms === undefined || !Number.isFinite(ms) || ms < 0) return undefined;
	if (ms < 1000) return `${ms}ms`;
	const seconds = ms / 1000;
	if (seconds < 60) return `${seconds.toFixed(1)}s`;
	return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`;
}

/** The argument that best identifies what a tool call targeted. */
function primaryToolArgument(args: unknown): string | undefined {
	if (typeof args === "string") return args || undefined;
	if (!args || typeof args !== "object" || Array.isArray(args)) return undefined;
	const record = args as Record<string, unknown>;
	for (const key of ["command", "cmd", "path", "file_path", "filePath", "pattern", "query", "url", "name", "task"]) {
		if (typeof record[key] === "string" && record[key]) return record[key] as string;
	}
	const firstString = Object.values(record).find((value) => typeof value === "string" && value);
	return firstString as string | undefined;
}

function payloadByteSize(value: unknown): number {
	if (value === undefined) return 0;
	if (typeof value === "string") return value.length;
	try {
		return JSON.stringify(value)?.length ?? 0;
	} catch {
		return 0;
	}
}

interface TimelineRow {
	stamp: string;
	kind: string;
	detail?: string;
	error?: boolean;
}

function renderTimelineRow(row: TimelineRow): string {
	const detail = row.detail ? ` · ${oneLine(row.detail, TIMELINE_PREVIEW_MAX)}` : "";
	return `${row.error ? "✖" : " "}[${row.stamp}] ${row.kind}${detail}`;
}

function describeInputEvent(event: any): TimelineRow {
	const delivery = inputDeliveryLabel(event.streamingBehavior ?? event.streaming_behavior) ?? "idle";
	const source = stringValue(event.source);
	const preview = stringValue(event.textPreview ?? event.text_preview ?? event.text) ?? "";
	const truncated = event.textTruncated === true || event.text_truncated === true;
	const imagesCount = numberValue(event.imagesCount ?? event.images_count);
	const meta = [delivery, source, imagesCount ? `${imagesCount} image${imagesCount === 1 ? "" : "s"}` : undefined].filter(Boolean).join(", ");
	return { stamp: "", kind: `input (${meta})`, detail: [preview, truncated ? "(truncated)" : ""].filter(Boolean).join(" ") };
}

function messageContentRows(message: any): Array<Pick<TimelineRow, "kind" | "detail" | "error">> {
	const role = stringValue(message?.role) ?? "assistant";
	const content = message?.content;
	if (typeof content === "string") return [{ kind: role, detail: content }];
	if (!Array.isArray(content)) return [{ kind: role, detail: `(no text, ${formatByteSize(payloadByteSize(message))})` }];
	const rows: Array<Pick<TimelineRow, "kind" | "detail" | "error">> = [];
	const toolNames: string[] = [];
	for (const part of content) {
		if (!part || typeof part !== "object") continue;
		if (part.type === "thinking" && typeof part.thinking === "string" && part.thinking) rows.push({ kind: "thinking", detail: part.thinking });
		else if (part.type === "text" && typeof part.text === "string" && part.text) rows.push({ kind: role, detail: part.text });
		else if (typeof part.type === "string" && part.type.toLowerCase().includes("tool")) {
			toolNames.push(stringValue(part.name) ?? stringValue(part.toolName) ?? stringValue(part.tool_name) ?? "tool");
		}
	}
	// A tool-call-only assistant message reads as its calls, never as raw JSON.
	if (rows.length === 0 && toolNames.length > 0) return [{ kind: role, detail: `${toolNames.length} tool call${toolNames.length === 1 ? "" : "s"}: ${toolNames.join(", ")}` }];
	if (rows.length === 0) return [{ kind: role, detail: `(no text, ${formatByteSize(payloadByteSize(message))})` }];
	return rows;
}

/**
 * Render a transcript as a chronological timeline: one row per event —
 * elapsed stamp, kind, capped one-line detail. Every event type the writer
 * emits gets a row or a deliberate elision (`message_start`, `turn_start`
 * pairs carry no information beyond their boundary); an unrecognized type
 * renders as its type and size, never as a raw JSONL dump. Tool calls
 * collapse into one row pairing start with result. `droppedEvents` (from a
 * budgeted tail read) is stated up front so a cut transcript never reads as
 * complete.
 */
export function formatTranscriptForDisplay(raw: string, options?: { droppedEvents?: number }): string {
	const rows: TimelineRow[] = [];
	let firstTs: number | undefined;
	// Open tool calls by id (fallback: name), pointing at the row to complete.
	const openTools = new Map<string, { row: TimelineRow; startedAtMs?: number; label: string }>();
	const stampFor = (record: any): { stamp: string; atMs?: number } => {
		const atMs = Date.parse(record?.ts ?? "");
		if (!Number.isFinite(atMs)) return { stamp: "--:--" };
		if (firstTs === undefined) firstTs = atMs;
		return { atMs, stamp: formatElapsedStamp(atMs - firstTs) };
	};
	const push = (stamp: string, kind: string, detail?: string, error?: boolean): TimelineRow => {
		const row: TimelineRow = { detail, error, kind, stamp };
		rows.push(row);
		return row;
	};
	if (options?.droppedEvents) push("--:--", `↑ ${options.droppedEvents} earlier event${options.droppedEvents === 1 ? "" : "s"} not shown`, "open the transcript file for the full record");
	for (const line of raw.split(/\r?\n/)) {
		if (!line.trim()) continue;
		let record: any;
		try {
			record = JSON.parse(line);
		} catch {
			push("--:--", "unparseable line", formatByteSize(line.length), true);
			continue;
		}
		const { stamp, atMs } = stampFor(record);
		const recordType = stringValue(record?.type);
		// Writer-level records (no wrapped Pi event).
		if (recordType === "start") {
			push(stamp, "session start", [stringValue(record.agent), stringValue(record.task)].filter(Boolean).join(" · "));
			continue;
		}
		if (recordType === "diagnostic") {
			push(stamp, "diagnostic", stringValue(record.diagnostic) ?? "(no detail)", true);
			continue;
		}
		if (recordType === "timeout") {
			push(stamp, "timeout", stringValue(record.reason) ?? "(no reason)", true);
			continue;
		}
		if (recordType === "exit") {
			const code = record.code ?? "unknown";
			push(stamp, "exit", `code ${code}`, code !== 0);
			continue;
		}
		if (recordType && !("event" in (record ?? {})) && !("stream" in (record ?? {}))) {
			// Other writer records (abort_close_timeout, settled_shutdown_*, …):
			// lifecycle trouble, labeled and toned as such.
			push(stamp, recordType, stringValue(record.diagnostic) ?? stringValue(record.signal) ?? formatByteSize(payloadByteSize(record)), true);
			continue;
		}
		if (typeof record?.text === "string" && record?.stream === "stderr") {
			push(stamp, "stderr", record.text, true);
			continue;
		}
		const normalized = normalizeTranscriptRecordEvent(record);
		const event = normalized.event;
		const type = typeof event?.type === "string" ? (event.type as string) : undefined;
		if (!event || typeof event !== "object" || !type) {
			push(stamp, "unlabeled record", formatByteSize(line.length), true);
			continue;
		}
		switch (type) {
			case "session":
			case "agent_start": {
				push(stamp, type === "session" ? "session" : "agent start", [stringValue(event.agent), stringValue(event.model)].filter(Boolean).join(" · ") || undefined);
				break;
			}
			case "start":
			case "message_start":
			case "turn_start":
				// Boundary openers carry nothing their closer or content rows do not.
				break;
			case "turn_end": {
				push(stamp, "turn end");
				break;
			}
			case "input": {
				const row = describeInputEvent(event);
				push(stamp, row.kind, row.detail);
				break;
			}
			case "message_update": {
				// Only present in full-stream transcripts or buffered failure
				// flushes; the reconstructed partial is the readable part.
				const partial = record.partialMessage ?? event.partialMessage;
				if (partial) for (const part of messageContentRows(partial)) push(stamp, `${part.kind} (partial)`, part.detail, part.error);
				break;
			}
			case "message_end": {
				const message = event.message && typeof event.message === "object" ? event.message : event;
				for (const part of messageContentRows(message)) push(stamp, part.kind, part.detail, part.error);
				break;
			}
			case "tool_execution_start": {
				const name = stringValue(event.toolName ?? event.tool_name) ?? stringValue(event.name) ?? "tool";
				const target = primaryToolArgument(event.args ?? event.arguments ?? event.input ?? event.params);
				const label = target ? `tool ${name} (${oneLine(target, 60)})` : `tool ${name}`;
				const id = stringValue(event.toolCallId ?? event.tool_call_id) ?? `name:${name}`;
				const row = push(stamp, label, "no result recorded");
				openTools.set(id, { label, row, startedAtMs: atMs });
				break;
			}
			case "tool_execution_update":
				// Folded into the paired tool row; the full payload stays in the file.
				break;
			case "tool_execution_end": {
				const name = stringValue(event.toolName ?? event.tool_name) ?? stringValue(event.name) ?? "tool";
				const id = stringValue(event.toolCallId ?? event.tool_call_id) ?? `name:${name}`;
				const open = openTools.get(id);
				openTools.delete(id);
				const failed = event.isError === true || event.is_error === true || stringValue(event.status) === "error";
				const status = stringValue(event.status) ?? (failed ? "error" : "ok");
				const resultSize = payloadByteSize(event.result ?? event.output ?? event.content);
				const duration = open?.startedAtMs !== undefined && atMs !== undefined ? formatToolDuration(atMs - open.startedAtMs) : undefined;
				const detail = [status, duration, resultSize ? formatByteSize(resultSize) : undefined].filter(Boolean).join(" · ");
				if (open) {
					open.row.detail = detail;
					open.row.error = failed;
				} else {
					push(stamp, `tool ${name}`, detail, failed);
				}
				break;
			}
			case "agent_end": {
				push(stamp, "agent end", stringValue(event.finalTextPreview ?? event.final_text_preview));
				break;
			}
			case "error": {
				push(stamp, "error", stringValue(event.message) ?? stringValue(event.error) ?? formatByteSize(payloadByteSize(event)), true);
				break;
			}
			default: {
				push(stamp, type, formatByteSize(line.length));
			}
		}
	}
	for (const open of openTools.values()) open.row.error = true;
	return rows.map(renderTimelineRow).join("\n");
}
