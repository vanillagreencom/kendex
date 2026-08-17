import { inputDeliveryLabel, normalizeTranscriptRecordEvent, numberValue, oneLine, stringValue } from "./transcripts.js";

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
	if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
	const totalSeconds = Math.round(ms / 1000);
	return `${Math.floor(totalSeconds / 60)}m ${totalSeconds % 60}s`;
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
	if (typeof value === "string") return Buffer.byteLength(value, "utf8");
	try {
		const serialized = JSON.stringify(value);
		return serialized === undefined ? 0 : Buffer.byteLength(serialized, "utf8");
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

// JSON.parse revives escaped C0/C1 controls (OSC/CSI included) that the old
// raw-JSONL view kept escaped; a hostile tool output must not reach the
// terminal as live sequences.
function stripTerminalControls(text: string): string {
	// eslint-disable-next-line no-control-regex
	return text.replace(/[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/g, "");
}

function renderTimelineRow(row: TimelineRow): string {
	const detail = row.detail ? ` · ${oneLine(row.detail, TIMELINE_PREVIEW_MAX)}` : "";
	return stripTerminalControls(`${row.error ? "✖" : " "}[${row.stamp}] ${row.kind}${detail}`);
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
	// Pane sessions store failed tools as toolResult messages with isError —
	// there is no separate tool_execution_end to carry the failure tone.
	const failed = message?.isError === true;
	const content = message?.content;
	if (typeof content === "string") return [{ detail: content, error: failed, kind: role }];
	if (!Array.isArray(content)) return [{ detail: `(no text, ${formatByteSize(payloadByteSize(message))})`, error: failed, kind: role }];
	const rows: Array<Pick<TimelineRow, "kind" | "detail" | "error">> = [];
	const toolNames: string[] = [];
	for (const part of content) {
		if (!part || typeof part !== "object") continue;
		if (part.type === "thinking" && typeof part.thinking === "string" && part.thinking) rows.push({ detail: part.thinking, error: failed, kind: "thinking" });
		else if (part.type === "text" && typeof part.text === "string" && part.text) rows.push({ detail: part.text, error: failed, kind: role });
		else if (typeof part.type === "string" && part.type.toLowerCase().includes("tool")) {
			toolNames.push(stringValue(part.name) ?? stringValue(part.toolName) ?? stringValue(part.tool_name) ?? "tool");
		}
	}
	// Tool calls always surface as a compact row — pane sessions have no
	// separate tool_execution_* records, so this is their only trace — and a
	// tool-call-only message reads as its calls, never as raw JSON.
	if (toolNames.length > 0) rows.push({ detail: `${toolNames.length} tool call${toolNames.length === 1 ? "" : "s"}: ${toolNames.join(", ")}`, error: failed, kind: role });
	if (rows.length === 0) return [{ detail: `(no text, ${formatByteSize(payloadByteSize(message))})`, error: failed, kind: role }];
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
export function formatTranscriptForDisplay(raw: string, options?: { droppedEvents?: number; originTs?: unknown; taskTerminal?: boolean }): string {
	const rows: TimelineRow[] = [];
	const originMs = typeof options?.originTs === "number" ? options.originTs : Date.parse(String(options?.originTs ?? ""));
	let firstTs: number | undefined = Number.isFinite(originMs) ? originMs : undefined;
	// Open tool calls by id (fallback: FIFO per name), pointing at the row to
	// complete — id-less same-named calls pair first-started-first-ended.
	const openTools = new Map<string, Array<{ row: TimelineRow; startedAtMs?: number; label: string }>>();
	const stampFor = (record: any): { stamp: string; atMs?: number } => {
		// One-shot writer records stamp `ts`; native pane session entries stamp
		// `timestamp` (ISO string or epoch ms).
		const raw = record?.ts ?? record?.timestamp;
		const atMs = typeof raw === "number" ? raw : Date.parse(raw ?? "");
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
			push("--:--", "unparseable line", formatByteSize(payloadByteSize(line)), true);
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
		if (recordType === "message" && record.message && typeof record.message === "object") {
			// Native pane-session entries carry the message at the record level.
			for (const part of messageContentRows(record.message)) push(stamp, part.kind, part.detail, part.error);
			continue;
		}
		if (recordType && !("event" in (record ?? {})) && !("stream" in (record ?? {}))) {
			// Other writer/session records. Only trouble-shaped types get the
			// failure tone; anything else is a neutral labeled row.
			const troubled = /^abort_|_failed$|_escalation$|^error$|^process_error$/.test(recordType);
			push(stamp, recordType, stringValue(record.diagnostic) ?? stringValue(record.error) ?? stringValue(record.signal) ?? formatByteSize(payloadByteSize(record)), troubled);
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
			push(stamp, "unlabeled record", formatByteSize(payloadByteSize(line)), true);
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
				const row = push(stamp, label, "running");
				const queue = openTools.get(id) ?? [];
				queue.push({ label, row, startedAtMs: atMs });
				openTools.set(id, queue);
				break;
			}
			case "tool_execution_update":
				// Folded into the paired tool row; the full payload stays in the file.
				break;
			case "tool_execution_end": {
				const name = stringValue(event.toolName ?? event.tool_name) ?? stringValue(event.name) ?? "tool";
				const id = stringValue(event.toolCallId ?? event.tool_call_id) ?? `name:${name}`;
				const open = openTools.get(id)?.shift();
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
				push(stamp, type, formatByteSize(payloadByteSize(line)));
			}
		}
	}
	// An unmatched start is a failure only once the task itself has ended; a
	// live task legitimately has its newest tool call still open.
	if (options?.taskTerminal !== false) {
		for (const queue of openTools.values()) {
			for (const open of queue) {
				open.row.error = true;
				open.row.detail = "no result recorded";
			}
		}
	}
	return rows.map(renderTimelineRow).join("\n");
}
