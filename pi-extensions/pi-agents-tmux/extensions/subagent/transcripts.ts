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

export function describeTranscriptEvent(record: any): string | undefined {
	const normalized = normalizeTranscriptRecordEvent(record);
	const event = normalized.event;
	if (!event || typeof event !== "object") return undefined;
	const type = typeof event.type === "string" ? event.type : undefined;
	if (type === "input") {
		const delivery = inputDeliveryLabel(event.streamingBehavior ?? event.streaming_behavior) ?? "idle";
		const source = stringValue(event.source);
		const preview = stringValue(event.textPreview ?? event.text_preview ?? event.text) ?? "";
		const bytes = numberValue(event.textBytes ?? event.text_bytes);
		const truncated = event.textTruncated === true || event.text_truncated === true;
		const imagesCount = numberValue(event.imagesCount ?? event.images_count);
		const meta = [delivery, source, imagesCount !== undefined ? `${imagesCount} image${imagesCount === 1 ? "" : "s"}` : undefined]
			.filter(Boolean)
			.join(" · ");
		const suffix = [bytes !== undefined ? `${bytes}B` : undefined, truncated ? "truncated" : undefined].filter(Boolean).join(" · ");
		return [`── input${meta ? ` (${meta})` : ""} ──`, preview ? `${oneLine(preview)}${suffix ? ` (${suffix})` : ""}` : suffix].filter(Boolean).join("\n");
	}
	if (type === "message_end") {
		const message = event.message && typeof event.message === "object" ? event.message : event;
		const role = stringValue(message.role);
		const text = textFromMessageContent(message.content);
		if (role && text) return [`── ${role} message ──`, oneLine(text)].join("\n");
	}
	if (type === "tool_execution_start" || type === "tool_execution_end") {
		const toolName = stringValue(event.toolName ?? event.tool_name) ?? stringValue(event.name);
		const status = stringValue(event.status);
		return `── ${type === "tool_execution_start" ? "tool start" : "tool end"}${toolName ? ` (${toolName})` : ""}${status ? ` · ${status}` : ""} ──`;
	}
	if (type === "agent_end") {
		const preview = stringValue(event.finalTextPreview ?? event.final_text_preview);
		return [`── agent end ──`, preview ? oneLine(preview) : undefined].filter(Boolean).join("\n");
	}
	if (record?.type === "exit") return `── exit ──\ncode ${record.code ?? "unknown"}`;
	return undefined;
}

export function formatTranscriptForDisplay(raw: string): string {
	const lines: string[] = [];
	for (const line of raw.split(/\r?\n/)) {
		if (!line.trim()) continue;
		try {
			const parsed = JSON.parse(line);
			lines.push(describeTranscriptEvent(parsed) ?? line);
		} catch {
			lines.push(line);
		}
	}
	return lines.join("\n");
}
