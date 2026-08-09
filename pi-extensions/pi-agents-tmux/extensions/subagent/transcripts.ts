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
export interface PartialAssistantMessageState {
	/** contentIndex -> block, so out-of-order or interleaved indices still land correctly. */
	blocks: Map<number, { kind: "text" | "thinking"; text: string }>;
	/** A snapshot-bearing event (older Pi, or a shape that kept `partial`) supersedes deltas. */
	hasSnapshot: boolean;
}

export function createPartialAssistantMessageState(): PartialAssistantMessageState {
	return { blocks: new Map(), hasSnapshot: false };
}

export function resetPartialAssistantMessage(state: PartialAssistantMessageState): void {
	state.blocks.clear();
	state.hasSnapshot = false;
}

/** Fold one `message_update` payload into the reconstructed partial assistant message. */
export function applyPartialAssistantMessage(state: PartialAssistantMessageState, payload: any): void {
	if (!payload || typeof payload !== "object") return;
	const streamEvent = payload.assistantMessageEvent;
	if (payload.message || (streamEvent && typeof streamEvent === "object" && streamEvent.partial)) {
		state.hasSnapshot = true;
		return;
	}
	if (!streamEvent || typeof streamEvent !== "object") return;
	const type = typeof streamEvent.type === "string" ? streamEvent.type : undefined;
	if (!type) return;
	const contentIndex = typeof streamEvent.contentIndex === "number" ? streamEvent.contentIndex : 0;
	const kind = type.startsWith("thinking") ? "thinking" : type.startsWith("text") ? "text" : undefined;
	if (!kind) return;

	if (type.endsWith("_end")) {
		// `*_end` carries the authoritative full block content; prefer it over accumulated deltas.
		if (typeof streamEvent.content === "string") state.blocks.set(contentIndex, { kind, text: streamEvent.content });
		return;
	}
	if (type.endsWith("_delta")) {
		if (typeof streamEvent.delta !== "string" || streamEvent.delta.length === 0) return;
		const existing = state.blocks.get(contentIndex);
		if (existing && existing.kind === kind) existing.text += streamEvent.delta;
		else state.blocks.set(contentIndex, { kind, text: streamEvent.delta });
	}
}

/**
 * The reconstructed assistant message, or undefined when nothing was accumulated or the
 * flushed event already carries its own cumulative snapshot.
 */
export function partialAssistantMessage(state: PartialAssistantMessageState): { role: "assistant"; content: Array<{ type: "text" | "thinking"; text: string }> } | undefined {
	if (state.hasSnapshot || state.blocks.size === 0) return undefined;
	const content = [...state.blocks.entries()]
		.sort(([a], [b]) => a - b)
		.filter(([, block]) => block.text.length > 0)
		.map(([, block]) => ({ type: block.kind, text: block.text }));
	return content.length > 0 ? { role: "assistant", content } : undefined;
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
