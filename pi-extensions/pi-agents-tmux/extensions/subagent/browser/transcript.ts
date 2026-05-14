import * as fs from "node:fs";
import { textFromMessageContent } from "../format.js";
import { type PaneTaskRecord } from "../types.js";

export function readTranscriptTail(transcriptPath: string | undefined, maxLines: number): string[] {
	if (!transcriptPath) return [];
	// Pi's --mode json stream emits ~50-100x more streaming-delta events
	// (message_update, tool_execution_update) than terminal ones, and the
	// deltas carry partial/empty argument objects. Rendering them produces a
	// flood of duplicate "assistant: [tool] bash {}" lines that don't reflect
	// real activity. Restrict to terminal lifecycle events that carry final
	// content. tool_execution_start is kept so we still see the tool call
	// before its result arrives.
	const INCLUDED_EVENT_TYPES = new Set([
		"start",
		"agent_start",
		"session",
		"session_compact",
		"turn_start",
		"turn_end",
		"message_end",
		"tool_execution_start",
		"tool_execution_end",
		"tool_result_end",
		"exit",
	]);
	try {
		const raw = fs.readFileSync(transcriptPath, "utf-8");
		const lines = raw.split(/\r?\n/);
		const rendered: string[] = [];
		let lastRendered: string | undefined;
		const push = (text: string | undefined) => {
			if (text === undefined) return;
			const parts = String(text).replace(/\r\n/g, "\n").split("\n");
			for (const part of parts) {
				if (part === lastRendered) continue;
				lastRendered = part;
				rendered.push(part);
			}
		};
		const pushSection = (label: string, ts?: string) => {
			push(`── ${label}${ts ? ` · ${ts}` : ""} ──`);
		};
		const eventTime = (outer: any, inner: any): string | undefined => {
			const rawTs = typeof outer?.ts === "string" ? outer.ts : typeof inner?.timestamp === "string" ? inner.timestamp : undefined;
			if (!rawTs) return undefined;
			const date = new Date(rawTs);
			if (!Number.isFinite(date.getTime())) return rawTs;
			return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}:${String(date.getSeconds()).padStart(2, "0")}`;
		};
		const pushJson = (value: unknown) => {
			try {
				const text = JSON.stringify(value ?? {}, null, 2);
				for (const line of text.split(/\r?\n/)) push(line);
			} catch {
				push(String(value));
			}
		};
		for (const line of lines) {
			if (!line.trim()) continue;
			let event: any;
			try { event = JSON.parse(line); } catch { push(line); continue; }
			const inner = transcriptInnerEvent(event);
			const innerType = typeof inner?.type === "string" ? inner.type : undefined;
			const ts = eventTime(event, inner);
			if (isTranscriptCompactionEvent(event, inner)) {
				push(transcriptCompactionBanner(ts));
				continue;
			}
			if (innerType && !INCLUDED_EVENT_TYPES.has(innerType)) continue;
			const msg = inner?.message;
			if (msg && typeof msg === "object") {
				const role = msg.role || innerType || "?";
				const content = Array.isArray(msg.content) ? msg.content : [];
				const tool = content.find((c: any) => c?.type === "toolCall");
				if (tool) {
					const args = tool.arguments ?? tool.args ?? {};
					pushSection(`${role} tool call ${tool.name ?? "?"}`, ts);
					if (Object.keys(args).length > 0) pushJson(args);
				} else {
					const text = textFromMessageContent(msg.content);
					if (text.trim()) {
						pushSection(String(role), ts);
						push(text);
					} else if (innerType) pushSection(`${role} (${innerType})`, ts);
				}
				continue;
			}
			// tool_execution_start/end carry identity in inner.toolName + inner.toolCallId
			// at the top level (not inside a .message or .call). Render the tool name
			// and a short id so dedup doesn't collapse two distinct tool runs into a
			// single bare event-type line.
			if (innerType && typeof inner?.toolName === "string") {
				const rawId = typeof inner.toolCallId === "string" ? inner.toolCallId : "";
				const id = rawId ? rawId.split("|").pop()?.slice(-8) : undefined;
				const suffix = id ? ` · ${id}` : "";
				const phase = innerType === "tool_execution_start" ? "tool start" : innerType === "tool_execution_end" ? "tool end" : innerType;
				pushSection(`${phase} ${inner.toolName}${suffix}`, ts);
				const result = inner.result ?? inner.output ?? inner.content;
				if (innerType === "tool_result_end" && result) push(typeof result === "string" ? result : JSON.stringify(result, null, 2));
				continue;
			}
			if (innerType) {
				if (innerType === "turn_start" || innerType === "turn_end") pushSection(innerType.replace("_", " "), ts);
				else if (innerType === "exit") pushSection(`exit${typeof inner?.code === "number" ? ` ${inner.code}` : ""}`, ts);
				else pushSection(innerType, ts);
				continue;
			}
			push(line);
		}
		return rendered.slice(-maxLines);
	} catch {
		return [];
	}
}

function transcriptRowTime(raw: string | undefined): string {
	if (!raw) return "--:--:--";
	const date = new Date(raw);
	if (!Number.isFinite(date.getTime())) return raw.slice(0, 8).padEnd(8, "-");
	return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}:${String(date.getSeconds()).padStart(2, "0")}`;
}

function transcriptEventTimestamp(outer: any, inner: any): string | undefined {
	return typeof outer?.ts === "string"
		? outer.ts
		: typeof inner?.timestamp === "string"
			? inner.timestamp
			: typeof inner?.ts === "string"
				? inner.ts
				: typeof outer?.timestamp === "string"
					? outer.timestamp
					: undefined;
}

function firstTranscriptLine(value: unknown): string {
	const text = typeof value === "string" ? value : value === undefined ? "" : JSON.stringify(value) ?? "";
	return text.replace(/\r\n/g, "\n").split("\n")[0]?.replace(/\s+/g, " ").trim() ?? "";
}

type TranscriptEntryType = "prompt" | "assistant" | "tool" | "error" | "exit" | "turn";
type TranscriptEntry =
	| { arrow: "→" | "←"; body?: string; compaction?: false; preview: string; timestamp?: string; type: TranscriptEntryType }
	| { body: string; compaction: true; preview: string; timestamp?: string };

export const TRANSCRIPT_COMPACTION_BANNER = "⚠ COMPACTION — context window full, history compressed before continuation";
export const TRANSCRIPT_COMPACTION_BODY = "(Pi runtime compacted context. Subsequent messages start from the compacted state.)";
const TRANSCRIPT_EMPTY_PLACEHOLDER = "(empty)";

function transcriptCompactRow(timestamp: string | undefined, arrow: "→" | "←", type: TranscriptEntryType, text: string): string {
	return `${transcriptRowTime(timestamp)} ${arrow} ${type} ${firstTranscriptLine(text)}`.trimEnd();
}

function transcriptHeaderRow(timestamp: string | undefined, arrow: "→" | "←", type: TranscriptEntryType): string {
	return `${transcriptRowTime(timestamp)} ${arrow} ${type}`;
}

function transcriptCompactionBanner(timestamp: string | undefined): string {
	return `${transcriptRowTime(timestamp)} ${TRANSCRIPT_COMPACTION_BANNER}`;
}

function transcriptInnerEvent(event: any): any {
	const inner = event?.event && typeof event.event === "object" ? event.event : event;
	if (inner?.type === "event" && inner?.data && typeof inner.data === "object") return inner.data;
	return inner;
}

function isCompactionToken(value: unknown): boolean {
	return value === "session_compact" || value === "session-compact" || value === "compact";
}

function isTranscriptCompactionEvent(outer: any, inner: any): boolean {
	return isCompactionToken(outer?.type)
		|| isCompactionToken(inner?.type)
		|| isCompactionToken(outer?.event)
		|| isCompactionToken(inner?.event)
		|| isCompactionToken(outer?.customType)
		|| isCompactionToken(inner?.customType)
		|| isCompactionToken(outer?.message?.customType)
		|| isCompactionToken(inner?.message?.customType);
}

function hasTranscriptValue(value: unknown): boolean {
	if (value == null) return false;
	if (typeof value === "string") return value.trim().length > 0;
	if (Array.isArray(value)) return value.length > 0;
	if (typeof value === "object") return Object.keys(value).length > 0;
	return true;
}

function formatTranscriptJson(value: unknown): string {
	if (typeof value === "string") {
		const trimmed = value.trim();
		if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
			try { return JSON.stringify(JSON.parse(trimmed), null, 2); } catch { /* keep raw */ }
		}
		return value;
	}
	try { return JSON.stringify(value ?? {}, null, 2); } catch { return String(value); }
}

function transcriptTextOrPlaceholder(text: string): string {
	return text.trim() ? text : TRANSCRIPT_EMPTY_PLACEHOLDER;
}

function toolCallPreview(tool: any): string {
	const name = tool?.name ?? tool?.toolName ?? "tool";
	const args = tool?.arguments ?? tool?.args;
	if (!args || (typeof args === "object" && Object.keys(args).length === 0)) return String(name);
	return `${name} ${firstTranscriptLine(args)}`;
}

function toolCallBody(tool: any): string {
	const name = String(tool?.name ?? tool?.toolName ?? "tool");
	const args = tool?.arguments ?? tool?.args;
	if (!hasTranscriptValue(args)) return name;
	return `${name}\n${formatTranscriptJson(args)}`;
}

function parseTranscriptEntries(record: PaneTaskRecord): TranscriptEntry[] {
	const entries: TranscriptEntry[] = [];
	let sawPrompt = false;
	let sawMalformedLine = false;
	try {
		const raw = record.transcriptPath ? fs.readFileSync(record.transcriptPath, "utf-8") : "";
		for (const line of raw.split(/\r?\n/)) {
			if (!line.trim()) continue;
			let event: any;
			try { event = JSON.parse(line); } catch { sawMalformedLine = true; continue; }
			const inner = transcriptInnerEvent(event);
			if (isTranscriptCompactionEvent(event, inner)) {
				entries.push({ body: TRANSCRIPT_COMPACTION_BODY, compaction: true, preview: TRANSCRIPT_COMPACTION_BANNER, timestamp: transcriptEventTimestamp(event, inner) });
				continue;
			}
			const innerType = typeof inner?.type === "string" ? inner.type : undefined;
			const timestamp = transcriptEventTimestamp(event, inner);
			const msg = inner?.message;
			if (msg && typeof msg === "object") {
				const role = String(msg.role ?? "");
				const content = Array.isArray(msg.content) ? msg.content : [];
				const tool = content.find((item: any) => item?.type === "toolCall" || item?.type === "tool_call");
				if (tool) {
					entries.push({ arrow: "←", body: toolCallBody(tool), preview: toolCallPreview(tool), timestamp, type: "tool" });
					continue;
				}
				const text = textFromMessageContent(msg.content);
				if (role === "user") {
					if (text.trim()) sawPrompt = true;
					const body = transcriptTextOrPlaceholder(text);
					entries.push({ arrow: "→", body, preview: body, timestamp, type: "prompt" });
				} else if (role === "assistant") {
					const body = transcriptTextOrPlaceholder(text);
					entries.push({ arrow: "←", body, preview: body, timestamp, type: "assistant" });
				} else {
					const body = transcriptTextOrPlaceholder(text);
					entries.push({ arrow: "←", body, preview: `${role || innerType || "message"} ${body}`, timestamp, type: "turn" });
				}
				continue;
			}
			if (innerType && typeof inner?.toolName === "string") {
				const phase = innerType === "tool_execution_start" ? "start" : innerType === "tool_execution_end" ? "end" : innerType === "tool_result_end" ? "result" : innerType;
				const result = inner.result ?? inner.output ?? inner.content;
				const args = inner.arguments ?? inner.args ?? inner.input;
				const bodyParts = [`${inner.toolName} ${phase}`];
				if (hasTranscriptValue(args)) bodyParts.push(formatTranscriptJson(args));
				if (hasTranscriptValue(result)) bodyParts.push(formatTranscriptJson(result));
				entries.push({
					arrow: "←",
					body: bodyParts.join("\n"),
					preview: `${inner.toolName} ${phase}${result ? ` ${firstTranscriptLine(result)}` : ""}`,
					timestamp,
					type: "tool",
				});
				continue;
			}
			if (innerType === "turn_start" || innerType === "turn_end") {
				entries.push({ arrow: "←", body: innerType.replace("_", " "), preview: innerType.replace("_", " "), timestamp, type: "turn" });
				continue;
			}
			if (innerType === "exit") {
				const text = typeof inner?.code === "number" ? `code ${inner.code}` : "exit";
				entries.push({ arrow: "←", body: text, preview: text, timestamp, type: "exit" });
				continue;
			}
			if (innerType && (innerType.includes("error") || inner?.error)) {
				const text = String(inner.error ?? innerType);
				entries.push({ arrow: "←", body: text, preview: text, timestamp, type: "error" });
			}
		}
	} catch {
		entries.push({ arrow: "←", body: "(transcript unavailable)", preview: "(transcript unavailable)", timestamp: undefined, type: "error" });
	}
	if (sawMalformedLine) entries.push({ arrow: "←", body: "(malformed transcript JSONL)", preview: "(malformed transcript JSONL)", timestamp: undefined, type: "error" });
	if (!sawPrompt && record.task?.trim()) entries.unshift({ arrow: "→", body: record.task, preview: record.task, timestamp: record.createdAt, type: "prompt" });
	return entries;
}

export function transcriptCompactRows(record: PaneTaskRecord, maxRows = 200): string[] {
	return parseTranscriptEntries(record).slice(-maxRows).map((entry) => entry.compaction
		? transcriptCompactionBanner(entry.timestamp)
		: transcriptCompactRow(entry.timestamp, entry.arrow, entry.type, entry.preview));
}

function expandedTranscriptEntryLines(entry: TranscriptEntry): string[] {
	if (entry.compaction) return [transcriptCompactionBanner(entry.timestamp), entry.body];
	const body = entry.body ?? entry.preview;
	const bodyLines = body.replace(/\r\n/g, "\n").split("\n");
	return [transcriptHeaderRow(entry.timestamp, entry.arrow, entry.type), ...bodyLines];
}

export function transcriptExpandedRows(record: PaneTaskRecord, maxRows = 200): string[] {
	const out: string[] = [];
	for (const entry of parseTranscriptEntries(record).slice(-maxRows)) {
		if (out.length > 0) out.push("");
		out.push(...expandedTranscriptEntryLines(entry));
	}
	return out;
}
