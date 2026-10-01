// Incremental reader for child transcripts. A transcript is append-only
// JSONL; each read consumes only the bytes appended since the previous read
// and folds every complete line into that transcript's usage total and latest
// activity. The dashboard renders from these snapshots, so the render path
// never touches a transcript file and a growing transcript is never replayed
// from its first byte.

import * as fs from "node:fs";
import { fileVersion } from "./file-version.js";
import { formatToolCall } from "./format.js";
import { normalizeTranscriptRecordEvent, oneLine } from "./transcripts.js";
import type { UsageStats } from "./types.js";

/**
 * Largest slice read in one call. A read holds at most one chunk plus the
 * longest line: bytes with no newline yet carry over into the next chunk.
 */
const READ_CHUNK_BYTES = 1024 * 1024;
/** Width cap of one activity line on a dashboard row. */
export const ACTIVITY_MAX_CHARS = 180;
const NEWLINE = 0x0a;

export type TranscriptUsage = { usage: UsageStats; model?: string };

/**
 * What a transcript says so far. `version` changes whenever the transcript's
 * bytes do, so a consumer acts once per change by remembering the last one.
 */
export interface TranscriptSnapshot {
	version: string;
	usage?: TranscriptUsage;
	activity?: string;
}

type TurnPeak = { input: number; output: number; reasoning: number; cacheRead: number; cacheWrite: number; cost: number };

interface TranscriptFold {
	total: UsageStats;
	model?: string;
	/** Largest streamed per-turn usage, counted only when no final message carries usage. */
	peak?: TurnPeak;
	activity?: string;
	/** Last record time supplied by the child transcript writer, not the dashboard poll. */
	progressAt?: number;
}

interface TailState {
	dev: number;
	ino: number;
	mtimeMs: number;
	/** Bytes of the file this state has seen. */
	size: number;
	/** Bytes folded into `fold`: everything through the last newline. The rest is re-read next time. */
	committed: number;
	fold: TranscriptFold;
	snapshot: TranscriptSnapshot;
}

/**
 * The `TranscriptSnapshot.version` a read of this transcript would report now,
 * from one stat and no read. Undefined when the path is missing or not a file.
 */
export async function statTranscriptVersion(filePath: string): Promise<string | undefined> {
	try {
		const stat = await fs.promises.stat(filePath);
		return stat.isFile() ? fileVersion(stat) : undefined;
	} catch {
		return undefined;
	}
}

function emptyFold(): TranscriptFold {
	return { total: { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 } };
}

function usageCost(rawCost: unknown): number {
	if (typeof rawCost === "number") return rawCost;
	if (!rawCost || typeof rawCost !== "object") return 0;
	const c = rawCost as Record<string, unknown>;
	return (Number(c.total) || 0)
		|| ((Number(c.input) || 0) + (Number(c.output) || 0) + (Number(c.cacheRead ?? c.cache_read) || 0) + (Number(c.cacheWrite ?? c.cache_write) || 0));
}

function foldUsage(fold: TranscriptFold, inner: any): void {
	if (!fold.model && typeof inner?.modelId === "string") fold.model = inner.modelId;
	if (!fold.model && typeof inner?.model === "string") fold.model = inner.model;
	if (!fold.model && typeof inner?.message?.model === "string") fold.model = inner.message.model;
	const usage = inner?.usage ?? inner?.message?.usage;
	if (!usage || typeof usage !== "object") return;
	const u = usage as Record<string, unknown>;
	const input = Number(u.input ?? u.input_tokens ?? 0) || 0;
	const output = Number(u.output ?? u.output_tokens ?? 0) || 0;
	const outputDetails = u.output_tokens_details;
	const reasoning = Number(u.reasoning ?? u.reasoning_tokens ?? (outputDetails && typeof outputDetails === "object" ? (outputDetails as Record<string, unknown>).reasoning_tokens : 0) ?? 0) || 0;
	const cacheRead = Number(u.cacheRead ?? u.cache_read_input_tokens ?? 0) || 0;
	const cacheWrite = Number(u.cacheWrite ?? u.cache_creation_input_tokens ?? 0) || 0;
	const cost = usageCost(u.cost);
	const isFinal = inner?.type === "message" || inner?.type === "message_end";
	const hasAny = input > 0 || output > 0 || reasoning > 0 || cacheRead > 0 || cacheWrite > 0 || cost > 0;
	if (!hasAny) return;
	if (isFinal) {
		const total = fold.total;
		total.input += input;
		total.output += output;
		total.reasoning = (total.reasoning ?? 0) + reasoning;
		total.cacheRead += cacheRead;
		total.cacheWrite += cacheWrite;
		total.cost += cost;
		total.turns = (total.turns ?? 0) + 1;
		return;
	}
	const peak = fold.peak ?? { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
	peak.input = Math.max(peak.input, input);
	peak.output = Math.max(peak.output, output);
	peak.reasoning = Math.max(peak.reasoning, reasoning);
	peak.cacheRead = Math.max(peak.cacheRead, cacheRead);
	peak.cacheWrite = Math.max(peak.cacheWrite, cacheWrite);
	peak.cost = Math.max(peak.cost, cost);
	fold.peak = peak;
}

function toolNameFromPart(part: any): string | undefined {
	return typeof part?.name === "string" && part.name.trim()
		? part.name.trim()
		: typeof part?.toolName === "string" && part.toolName.trim()
			? part.toolName.trim()
			: undefined;
}

function toolCallActivity(name: string, args: unknown): string {
	if (!args || typeof args !== "object" || Array.isArray(args)) return name;
	const preview = formatToolCall(name, args as Record<string, unknown>, (_color, text) => text);
	return oneLine(name === "bash" ? `${name} ${preview}` : preview, ACTIVITY_MAX_CHARS);
}

function activityFromMessageContent(content: unknown): { kind: "text" | "tool"; text: string } | undefined {
	if (typeof content === "string") return { kind: "text", text: oneLine(content, ACTIVITY_MAX_CHARS) };
	if (!Array.isArray(content)) return undefined;
	const tool = content.find((part: any) => part?.type === "toolCall" || part?.type === "tool_call" || part?.type === "tool-call");
	if (tool) return { kind: "tool", text: toolCallActivity(toolNameFromPart(tool) ?? "call", tool.arguments) };
	const text = content.find((part: any) => part?.type === "text" && typeof part.text === "string");
	if (text?.text) return { kind: "text", text: oneLine(String(text.text), ACTIVITY_MAX_CHARS) };
	return undefined;
}

function activityFromRecord(parsed: any, inner: any): string | undefined {
	if (!parsed || typeof parsed !== "object") return undefined;
	if (typeof parsed.text === "string" && parsed.stream === "stderr") return `stderr: ${oneLine(parsed.text, ACTIVITY_MAX_CHARS)}`;
	if (parsed.type === "exit" && typeof parsed.code !== "undefined") return `exit ${parsed.code}`;
	const type = typeof inner?.type === "string" ? inner.type : undefined;
	const toolName = typeof inner?.toolName === "string" ? inner.toolName : toolNameFromPart(inner?.toolCall) ?? toolNameFromPart(inner?.tool_call);
	if ((type === "tool_execution_start" || type === "tool_execution_update") && toolName) return `tool: ${toolCallActivity(toolName, inner.args)}`;
	if ((type === "tool_execution_end" || type === "tool_result_end") && toolName) return `tool: ${toolName}`;
	if (type === "tool_result_end") return "tool: result";
	const msg = inner?.message && typeof inner.message === "object" ? inner.message : undefined;
	if (msg) {
		const rendered = activityFromMessageContent(msg.content);
		if (rendered?.kind === "tool") return `tool: ${rendered.text}`;
		if (rendered?.kind === "text" && msg.role === "assistant") return `said: ${rendered.text}`;
		if (rendered?.kind === "text" && msg.role === "tool") return `tool: ${rendered.text}`;
		return undefined;
	}
	if (type === "message_end") return "message complete";
	return undefined;
}

/**
 * Fold one line. `terminated` is false for the bytes after the last newline:
 * those may be a record the child is still writing, so a parse failure there
 * is not yet a non-JSON line.
 */
function foldLine(fold: TranscriptFold, rawLine: string, terminated: boolean): void {
	const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;
	if (!line.trim()) return;
	let parsed: unknown;
	try {
		parsed = JSON.parse(line);
	} catch {
		// A complete line that is not JSON (a raw stderr capture) still says what the child is doing.
		if (terminated) fold.activity = oneLine(line, ACTIVITY_MAX_CHARS);
		return;
	}
	const inner = normalizeTranscriptRecordEvent(parsed).event;
	foldUsage(fold, inner);
	const activity = activityFromRecord(parsed, inner);
	if (activity) fold.activity = activity;
	// Background appender records use ts; native pane session entries use timestamp.
	const record = parsed && typeof parsed === "object" ? parsed as Record<string, unknown> : undefined;
	const ts = record?.ts ?? record?.timestamp;
	const progressAt = typeof ts === "number" ? ts : typeof ts === "string" ? Date.parse(ts) : NaN;
	if (Number.isFinite(progressAt)) fold.progressAt = progressAt;
}

function usageFromFold(fold: TranscriptFold): TranscriptUsage | undefined {
	const total = { ...fold.total };
	if ((total.turns ?? 0) === 0 && fold.peak) {
		Object.assign(total, fold.peak);
		total.turns = 1;
	}
	if ((total.turns ?? 0) === 0 && total.input === 0 && total.output === 0) return undefined;
	return { usage: total, model: fold.model };
}

async function foldAppendedBytes(filePath: string, tail: TailState, size: number): Promise<string> {
	const handle = await fs.promises.open(filePath, "r");
	try {
		let carry = Buffer.alloc(0);
		let position = tail.committed;
		while (position < size) {
			const chunk = Buffer.alloc(Math.min(READ_CHUNK_BYTES, size - position));
			const { bytesRead } = await handle.read(chunk, 0, chunk.length, position);
			if (bytesRead === 0) break;
			position += bytesRead;
			const pending = carry.length > 0 ? Buffer.concat([carry, chunk.subarray(0, bytesRead)]) : chunk.subarray(0, bytesRead);
			const lastNewline = pending.lastIndexOf(NEWLINE);
			if (lastNewline < 0) {
				carry = pending;
				continue;
			}
			// A UTF-8 continuation byte is never 0x0a, so splitting at a newline never cuts a character.
			for (const line of pending.subarray(0, lastNewline).toString("utf-8").split("\n")) foldLine(tail.fold, line, true);
			tail.committed += lastNewline + 1;
			carry = pending.subarray(lastNewline + 1);
		}
		tail.size = position;
		return carry.toString("utf-8");
	} finally {
		await handle.close().catch(() => undefined);
	}
}

/**
 * Per-transcript incremental read state, keyed by transcript path. One
 * instance lives for one parent session; `clear` releases it at session
 * boundaries and `retain` drops transcripts no dashboard row still shows.
 */
export class TranscriptTailCache {
	private readonly tails = new Map<string, TailState>();
	private readonly queues = new Map<string, Promise<void>>();

	/**
	 * Advance the transcript to its current end and return the snapshot, or
	 * undefined when the file is missing or unreadable. Reads of one path run
	 * one at a time, so two callers never fold the same bytes twice.
	 */
	async read(filePath: string): Promise<TranscriptSnapshot | undefined> {
		const run = (this.queues.get(filePath) ?? Promise.resolve()).then(() => this.advance(filePath));
		const settled = run.then(() => undefined, () => undefined);
		this.queues.set(filePath, settled);
		try {
			return await run;
		} finally {
			if (this.queues.get(filePath) === settled) this.queues.delete(filePath);
		}
	}

	retain(filePaths: Set<string>): void {
		for (const filePath of this.tails.keys()) {
			if (!filePaths.has(filePath)) this.tails.delete(filePath);
		}
	}

	clear(): void {
		this.tails.clear();
	}

	private async advance(filePath: string): Promise<TranscriptSnapshot | undefined> {
		let stat: fs.Stats;
		try {
			stat = await fs.promises.stat(filePath);
		} catch {
			this.tails.delete(filePath);
			return undefined;
		}
		if (!stat.isFile()) {
			this.tails.delete(filePath);
			return undefined;
		}
		let tail = this.tails.get(filePath);
		// Append-only is the contract. A new device or inode, a smaller size, or a same-size
		// rewrite with a new mtime starts over from byte 0. An in-place edit that also grows
		// the file is not detected: the fold keeps the lines it already read.
		const rewritten = tail !== undefined
			&& (tail.dev !== stat.dev || tail.ino !== stat.ino || stat.size < tail.size || (stat.size === tail.size && stat.mtimeMs !== tail.mtimeMs));
		if (tail && !rewritten && stat.size === tail.size) return tail.snapshot;
		if (!tail || rewritten) {
			tail = { dev: stat.dev, ino: stat.ino, mtimeMs: stat.mtimeMs, size: 0, committed: 0, fold: emptyFold(), snapshot: { version: "" } };
		}
		let remainder: string;
		try {
			remainder = await foldAppendedBytes(filePath, tail, stat.size);
		} catch {
			// A failed read leaves the fold at an unknown line; drop it so the next read starts clean.
			this.tails.delete(filePath);
			return undefined;
		}
		// An unterminated last line is folded into a copy: complete JSON counts now, and the
		// committed fold picks it up once its newline lands, without counting it twice.
		let fold = tail.fold;
		if (remainder.trim()) {
			fold = structuredClone(tail.fold);
			foldLine(fold, remainder, false);
		}
		tail.mtimeMs = stat.mtimeMs;
		const progress = fold.progressAt === undefined ? "" : `last ${new Date(fold.progressAt).toISOString().slice(11, 19)}Z · `;
		tail.snapshot = { version: fileVersion(stat, tail.size), usage: usageFromFold(fold), activity: fold.activity ? oneLine(`${progress}${fold.activity}`, ACTIVITY_MAX_CHARS) : undefined };
		this.tails.set(filePath, tail);
		return tail.snapshot;
	}
}
