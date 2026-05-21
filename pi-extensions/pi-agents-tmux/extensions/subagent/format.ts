import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { Message } from "@earendil-works/pi-ai";
import { type Theme } from "@earendil-works/pi-coding-agent";
import { Container, Spacer, truncateToWidth, visibleWidth, wrapTextWithAnsi, type Component } from "@earendil-works/pi-tui";
import { discoverAgents, type AgentConfig } from "./agents.js";
import { frameGlyphs, glyphs } from "./glyphs.js";
import { subagentTreeStyle } from "./settings.js";
import { normalizeTranscriptRecordEvent } from "./transcripts.js";
import {
	AGENT_ASCII_COLOR_SEQUENCE,
	type AgentAsciiColor,
	type CompletionMessageProvenance,
	type DisplayItem,
	ICONS,
	type SessionMode,
	type SubagentStatuslineInfo,
	type UsageStats,
} from "./types.js";

export const SESSION_KEY_CHIP_MAX_CHARS = 14;

function normalizeSessionMode(value: unknown): SessionMode | undefined {
	return value === "fresh" || value === "resumed" || value === "new" ? value : undefined;
}

export function paneSessionModeToRecordMode(mode: "live" | "resumed" | "new" | undefined): SessionMode | undefined {
	if (!mode) return undefined;
	return mode === "new" ? "new" : "resumed";
}

export function truncateSessionKeyForChip(sessionKey: string | undefined, maxChars = SESSION_KEY_CHIP_MAX_CHARS): string | undefined {
	const trimmed = sessionKey?.trim();
	if (!trimmed) return undefined;
	if (trimmed.length > maxChars) return `${trimmed.slice(0, 6)}…${trimmed.slice(-4)}`;
	return oneLinePreview(trimmed, maxChars);
}

export function sessionModeChipLabel(value: { kind?: string; sessionKey?: string; sessionMode?: unknown } | undefined): string | undefined {
	const sessionMode = normalizeSessionMode(value?.sessionMode);
	if (!value || !sessionMode) return undefined;
	const kindLabel = value.kind === "oneshot" ? "bg" : value.kind === "pane" ? "pane" : undefined;
	if (value.kind === "oneshot" && sessionMode === "resumed" && value.sessionKey?.trim()) return `lane:${truncateSessionKeyForChip(value.sessionKey)}`;
	if (value.kind === "oneshot" && sessionMode === "fresh") return "fresh";
	if (value.kind === "pane" && (sessionMode === "new" || sessionMode === "resumed")) return sessionMode;
	return kindLabel ? sessionMode : undefined;
}

export function sessionModeChipSuffix(theme: Theme, value: { kind?: string; sessionKey?: string; sessionMode?: unknown } | undefined): string {
	const label = sessionModeChipLabel(value);
	return label ? theme.fg("dim", ` · ${label}`) : "";
}

export function sessionModeDetailLabel(value: { sessionKey?: string; sessionMode?: unknown } | undefined): string | undefined {
	const sessionMode = normalizeSessionMode(value?.sessionMode);
	if (!value || !sessionMode) return undefined;
	const key = value.sessionKey?.trim();
	return key ? `${sessionMode} · lane: ${key}` : sessionMode;
}

export function normalizeAgentAsciiColor(value: string | undefined): AgentAsciiColor | undefined {
	const normalized = value?.trim().toLowerCase().replace(/[^a-z]/g, "");
	switch (normalized) {
		case "red": return "red";
		case "green": return "green";
		case "yellow":
		case "orange": return "yellow";
		case "blue": return "blue";
		case "magenta":
		case "purple":
		case "violet": return "magenta";
		case "cyan":
		case "teal": return "cyan";
		default: return undefined;
	}
}

export function defaultAgentAsciiColor(agentName: string, agents: AgentConfig[]): AgentAsciiColor {
	const names = agents.map((agent) => agent.name).sort((a, b) => a.localeCompare(b));
	const index = Math.max(0, names.indexOf(agentName));
	return AGENT_ASCII_COLOR_SEQUENCE[index % AGENT_ASCII_COLOR_SEQUENCE.length] ?? "magenta";
}

export function resolveSubagentStatuslineInfo(agentName: string | undefined, cwd?: string): SubagentStatuslineInfo | undefined {
	const name = agentName?.trim();
	if (!name) return undefined;
	const envColor = normalizeAgentAsciiColor(process.env.PI_SUBAGENT_CHILD_COLOR);
	try {
		const agents = discoverAgents(cwd ?? process.cwd(), "both").agents;
		const agent = agents.find((candidate) => candidate.name === name);
		const color = normalizeAgentAsciiColor(agent?.color) ?? envColor ?? defaultAgentAsciiColor(name, agents);
		return { name, color };
	} catch {
		return { name, color: envColor };
	}
}

export function formatTokens(count: number): string {
	if (count < 1000) return count.toString();
	if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
	if (count < 1000000) return `${Math.round(count / 1000)}k`;
	return `${(count / 1000000).toFixed(1)}M`;
}

// Highlight common JSON keys + status verdict tokens in one-line subagent
// previews. Untouched runs stay in the terminal default; matched tokens get
// semantic colors so reviewer-style outputs (`verdict: approve`, `failed`,
// etc.) are scannable without expanding the row. Order matters: JSON keys
// match first so a `"verdict":` field name doesn't get re-tokenized by the
// status passes below.
export function highlightInlinePreview(text: string, theme: Theme): string {
	if (!text) return text;
	let result = text;
	const protectedSpans: string[] = [];
	const protect = (span: string) => {
		const token = `\uE000${protectedSpans.length}\uE001`;
		protectedSpans.push(span);
		return token;
	};
	// JSON keys: "name":
	result = result.replace(/"([A-Za-z_][\w-]*)"(\s*):/g, (_full, key: string, ws: string) =>
		protect(`${theme.fg("accent", `"${key}"`)}${ws}${theme.fg("dim", ":")}`),
	);
	// Success-tone status values inside quoted strings.
	result = result.replace(/"(approve|approved|success|completed|merged|ok|done|clean|passed)"/g, (_full, w: string) =>
		`${theme.fg("dim", '"')}${theme.fg("success", w)}${theme.fg("dim", '"')}`,
	);
	// Warning-tone status values.
	result = result.replace(/"(changes[-_]requested|action[-_]required|warning|needs[-_]completion|pending|skip)"/g, (_full, w: string) =>
		`${theme.fg("dim", '"')}${theme.fg("warning", w)}${theme.fg("dim", '"')}`,
	);
	// Error-tone status values.
	result = result.replace(/"(failed|failure|error|aborted|blocked|rejected)"/g, (_full, w: string) =>
		`${theme.fg("dim", '"')}${theme.fg("error", w)}${theme.fg("dim", '"')}`,
	);
	result = result.replace(/\uE000(\d+)\uE001/g, (_full, index: string) => protectedSpans[Number(index)] ?? "");
	return result;
}

export function oneLinePreview(text: string | undefined, maxChars: number): string {
	const compact = (text ?? "").replace(/\s+/g, " ").trim();
	return compact.length > maxChars ? `${compact.slice(0, Math.max(0, maxChars - 1))}…` : compact;
}

export const COMPLETION_SUMMARY_UNAVAILABLE = "completion summary unavailable; see transcript";

export function normalizeSummaryText(text: string | undefined): string | undefined {
	const trimmed = text?.replace(/\r\n/g, "\n").trim();
	return trimmed ? trimmed : undefined;
}

export function normalizeComparableText(value: string | undefined): string {
	return (value ?? "")
		.toLowerCase()
		.replace(/\x1b\[[0-9;]*m/g, "")
		.replace(/[`*_#>]/g, " ")
		.replace(/\s+/g, " ")
		.trim();
}

export function completionSummaryForDisplay(summary: string | undefined): string {
	return normalizeSummaryText(summary) ?? COMPLETION_SUMMARY_UNAVAILABLE;
}

export function completionBodyWithoutPromptEcho(summary: string | undefined, task: string | undefined, provenance: CompletionMessageProvenance = "persisted"): string {
	const body = completionSummaryForDisplay(summary);
	if (provenance === "task-echo-fallback" && normalizeComparableText(body) && normalizeComparableText(body) === normalizeComparableText(task)) return COMPLETION_SUMMARY_UNAVAILABLE;
	return body;
}

export function compactPath(filePath: string | undefined, options?: { baseDir?: string; maxChars?: number }): string {
	const raw = filePath?.trim();
	if (!raw) return "";
	const home = os.homedir();
	let compact = raw.startsWith(home) ? `~${raw.slice(home.length)}` : raw;
	if (options?.baseDir) {
		const relative = path.relative(options.baseDir, raw);
		if (relative && !relative.startsWith("..") && !path.isAbsolute(relative)) compact = relative;
	}
	return oneLinePreview(compact, options?.maxChars ?? 96);
}

export function shortTaskId(taskId: string | undefined, maxChars = 36): string {
	return oneLinePreview(taskId, maxChars);
}

export function subagentBranch(theme: Theme, branch: "├" | "└" | "│", cwd?: string): string {
	if (subagentTreeStyle(cwd) === "ascii") {
		if (branch === "│") return theme.fg("muted", "|  ");
		return theme.fg("muted", branch === "└" ? "`-- " : "|-- ");
	}
	if (branch === "│") return theme.fg("muted", "│  ");
	return theme.fg("muted", `${branch}─ `);
}

export function subagentStem(theme: Theme, isLast: boolean, cwd?: string): string {
	return isLast ? theme.fg("muted", subagentTreeStyle(cwd) === "ascii" ? "    " : "   ") : subagentBranch(theme, "│", cwd);
}

export function padAnsi(text: string, width: number): string {
	return `${text}${" ".repeat(Math.max(0, width - visibleWidth(text)))}`;
}

const ANSI_GREEN_FG = "\x1b[32m";
const ANSI_YELLOW_FG = "\x1b[33m";
const ANSI_MAGENTA_FG = "\x1b[35m";
const ANSI_FG_RESET = "\x1b[39m";
export function ansiGreen(text: string): string { return `${ANSI_GREEN_FG}${text}${ANSI_FG_RESET}`; }
export function ansiYellow(text: string): string { return `${ANSI_YELLOW_FG}${text}${ANSI_FG_RESET}`; }
export function ansiMagenta(text: string): string { return `${ANSI_MAGENTA_FG}${text}${ANSI_FG_RESET}`; }

export function simpleFrame(lines: string[], width: number, theme: Theme, title = ""): string[] {
	if (width < 8) return lines.map((line) => truncateToWidth(line, width, ""));
	const border = (text: string) => theme.fg("borderAccent", text);
	const innerWidth = Math.max(1, width - 4);
	const top = () => {
		const frame = frameGlyphs();
		if (!title) return `${border(frame.tl)}${border(frame.h.repeat(width - 2))}${border(frame.tr)}`;
		const titlePlain = ` ${truncateToWidth(title, Math.max(1, width - 4), glyphs().ellipsis)} `;
		const fill = Math.max(1, width - 2 - visibleWidth(titlePlain));
		return `${border(frame.tl)}${ansiGreen(titlePlain)}${border(frame.h.repeat(fill))}${border(frame.tr)}`;
	};
	const frame = frameGlyphs();
	return [
		top(),
		...lines.map((line) => `${border(frame.v)} ${padAnsi(truncateToWidth(line, innerWidth, ""), innerWidth)} ${border(frame.v)}`),
		`${border(frame.bl)}${border(frame.h.repeat(width - 2))}${border(frame.br)}`,
	].map((line) => truncateToWidth(line, width, ""));
}

export function activePill(theme: Theme, label: string): string {
	return theme.fg("accent", theme.inverse(theme.bold(label)));
}

export function inactivePill(theme: Theme, label: string): string {
	return theme.bg("selectedBg", theme.fg("accent", label));
}

export function divider(width: number, theme: Theme): string {
	return theme.fg("borderMuted", glyphs().line.repeat(Math.max(1, width)));
}

export async function parseTranscriptUsage(transcriptPath: string | undefined): Promise<{ usage: UsageStats; model?: string } | undefined> {
	if (!transcriptPath) return undefined;
	let content: string;
	try {
		content = await fs.promises.readFile(transcriptPath, "utf-8");
	} catch {
		return undefined;
	}
	const total: UsageStats = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
	let model: string | undefined;
	let bestPerTurn: { input: number; output: number; cacheRead: number; cacheWrite: number; cost: number } | undefined;
	for (const line of content.split(/\r?\n/)) {
		if (!line.trim()) continue;
		let event: any;
		try {
			event = JSON.parse(line);
		} catch {
			continue;
		}
		const inner = normalizeTranscriptRecordEvent(event).event;
		if (!model && typeof inner?.modelId === "string") model = inner.modelId;
		if (!model && typeof inner?.model === "string") model = inner.model;
		if (!model && typeof inner?.message?.model === "string") model = inner.message.model;
		const usage = inner?.usage ?? inner?.message?.usage;
		if (!usage || typeof usage !== "object") continue;
		const input = Number((usage as Record<string, unknown>).input ?? (usage as Record<string, unknown>).input_tokens ?? 0) || 0;
		const output = Number((usage as Record<string, unknown>).output ?? (usage as Record<string, unknown>).output_tokens ?? 0) || 0;
		const cacheRead = Number((usage as Record<string, unknown>).cacheRead ?? (usage as Record<string, unknown>).cache_read_input_tokens ?? 0) || 0;
		const cacheWrite = Number((usage as Record<string, unknown>).cacheWrite ?? (usage as Record<string, unknown>).cache_creation_input_tokens ?? 0) || 0;
		const rawCost = (usage as Record<string, unknown>).cost;
		let cost = 0;
		if (typeof rawCost === "number") cost = rawCost;
		else if (rawCost && typeof rawCost === "object") {
			const c = rawCost as Record<string, unknown>;
			cost =
				(Number(c.total) || 0) ||
				((Number(c.input) || 0) +
					(Number(c.output) || 0) +
					(Number(c.cacheRead ?? c.cache_read) || 0) +
					(Number(c.cacheWrite ?? c.cache_write) || 0));
		}
		const type = inner?.type;
		const isFinal = type === "message" || type === "message_end";
		const hasAny = input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 || cost > 0;
		if (isFinal && hasAny) {
			total.input += input;
			total.output += output;
			total.cacheRead += cacheRead;
			total.cacheWrite += cacheWrite;
			total.cost += cost;
			total.turns = (total.turns ?? 0) + 1;
		} else if (hasAny) {
			bestPerTurn = bestPerTurn ?? { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
			bestPerTurn.input = Math.max(bestPerTurn.input, input);
			bestPerTurn.output = Math.max(bestPerTurn.output, output);
			bestPerTurn.cacheRead = Math.max(bestPerTurn.cacheRead, cacheRead);
			bestPerTurn.cacheWrite = Math.max(bestPerTurn.cacheWrite, cacheWrite);
			bestPerTurn.cost = Math.max(bestPerTurn.cost, cost);
		}
	}
	if ((total.turns ?? 0) === 0 && bestPerTurn) {
		total.input = bestPerTurn.input;
		total.output = bestPerTurn.output;
		total.cacheRead = bestPerTurn.cacheRead;
		total.cacheWrite = bestPerTurn.cacheWrite;
		total.cost = bestPerTurn.cost;
		total.turns = 1;
	}
	if ((total.turns ?? 0) === 0 && total.input === 0 && total.output === 0) return undefined;
	return { usage: total, model };
}

export function formatUsageStatsForDashboard(usage: {
	input: number;
	output: number;
	cost: number;
	turns?: number;
}): string[] {
	const parts: string[] = [];
	if (usage.turns) parts.push(`${ICONS.refresh} ${usage.turns}`);
	const tokenBits: string[] = [];
	if (usage.input) tokenBits.push(`↑${formatTokens(usage.input)}`);
	if (usage.output) tokenBits.push(`↓${formatTokens(usage.output)}`);
	if (tokenBits.length > 0) parts.push(tokenBits.join(" "));
	if (usage.cost) parts.push(`$${usage.cost.toFixed(4)}`);
	return parts;
}

export function formatUsageStats(
	usage: {
		input: number;
		output: number;
		cacheRead: number;
		cacheWrite: number;
		cost: number;
		contextTokens?: number;
		turns?: number;
	},
	model?: string,
): string {
	const parts: string[] = [];
	if (usage.turns) parts.push(`${usage.turns} turn${usage.turns > 1 ? "s" : ""}`);
	if (usage.input) parts.push(`↑${formatTokens(usage.input)}`);
	if (usage.output) parts.push(`↓${formatTokens(usage.output)}`);
	if (usage.cacheRead) parts.push(`R${formatTokens(usage.cacheRead)}`);
	if (usage.cacheWrite) parts.push(`W${formatTokens(usage.cacheWrite)}`);
	if (usage.cost) parts.push(`$${usage.cost.toFixed(4)}`);
	if (usage.contextTokens && usage.contextTokens > 0) {
		parts.push(`ctx:${formatTokens(usage.contextTokens)}`);
	}
	if (model) parts.push(model);
	return parts.join(" ");
}

export function getFinalOutput(messages: Message[]): string {
	for (let i = messages.length - 1; i >= 0; i--) {
		const msg = messages[i];
		if (msg.role === "assistant") {
			const text = textFromMessageContent(msg.content);
			if (text) return text;
		}
	}
	return "";
}

export function textFromMessageContent(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	const parts = content
		.map((part) => {
			if (!part || typeof part !== "object") return "";
			const candidate = part as Record<string, unknown>;
			return candidate.type === "text" && typeof candidate.text === "string" ? candidate.text : "";
		})
		.filter((text) => text.trim());
	return parts.join("\n\n");
}

function assistantTextFromTranscriptRecord(record: unknown): string | undefined {
	if (!record || typeof record !== "object") return undefined;
	const event = normalizeTranscriptRecordEvent(record).event as Record<string, unknown>;
	const message = event.message && typeof event.message === "object"
		? event.message as Record<string, unknown>
		: event.role === "assistant"
			? event
			: undefined;
	if (!message || message.role !== "assistant") return undefined;
	return normalizeSummaryText(textFromMessageContent(message.content));
}

export function extractLastAssistantTextFromTranscriptContent(content: string): string | undefined {
	let finalText: string | undefined;
	for (const line of content.split(/\r?\n/)) {
		if (!line.trim()) continue;
		let parsed: unknown;
		try {
			parsed = JSON.parse(line);
		} catch {
			continue;
		}
		const text = assistantTextFromTranscriptRecord(parsed);
		if (text) finalText = text;
	}
	return finalText;
}

function assertTranscriptJsonlValid(content: string): void {
	let lineNumber = 0;
	for (const line of content.split(/\r?\n/)) {
		lineNumber += 1;
		if (!line.trim()) continue;
		try {
			JSON.parse(line);
		} catch (error) {
			throw new Error(`Invalid transcript JSONL at line ${lineNumber}: ${stringifyError(error)}`);
		}
	}
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number, label: string): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	const timeout = new Promise<never>((_resolve, reject) => {
		timer = setTimeout(() => reject(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs);
		timer.unref?.();
	});
	try {
		return await Promise.race([promise, timeout]);
	} finally {
		if (timer) clearTimeout(timer);
	}
}

async function readFileTailBounded(filePath: string, maxBytes: number, timeoutMs: number): Promise<string> {
	const read = (async () => {
		const stat = await fs.promises.stat(filePath);
		const size = Math.max(0, stat.size);
		const start = Math.max(0, size - maxBytes);
		const length = size - start;
		const handle = await fs.promises.open(filePath, "r");
		try {
			const buffer = Buffer.alloc(length);
			await handle.read(buffer, 0, length, start);
			const text = buffer.toString("utf-8");
			if (start === 0) return text;
			return text.replace(/^[^\n]*(?:\n|$)/, "");
		} finally {
			await handle.close().catch(() => undefined);
		}
	})();
	return withTimeout(read, timeoutMs, `read ${filePath}`);
}

export async function readLastAssistantTextFromTranscript(
	transcriptPath: string | undefined,
	options: { maxBytes?: number; timeoutMs?: number } = {},
): Promise<string | undefined> {
	if (!transcriptPath) return undefined;
	const content = await readFileTailBounded(transcriptPath, options.maxBytes ?? 2 * 1024 * 1024, options.timeoutMs ?? 5_000);
	assertTranscriptJsonlValid(content);
	return extractLastAssistantTextFromTranscriptContent(content);
}

export function getDisplayItems(messages: Message[]): DisplayItem[] {
	const items: DisplayItem[] = [];
	for (const msg of messages) {
		if (msg.role === "assistant") {
			for (const part of msg.content) {
				if (part.type === "text") items.push({ type: "text", text: part.text });
				else if (part.type === "toolCall") items.push({ type: "toolCall", name: part.name, args: part.arguments });
			}
		}
	}
	return items;
}

function normalizeEchoText(value: string): string {
	return value
		.toLowerCase()
		.replace(/\x1b\[[0-9;]*m/g, "")
		.replace(/[`*_#>]/g, " ")
		.replace(/^\s*(?:[-*•]|\d+[.)]|→)\s+/, "")
		.replace(/\s+/g, " ")
		.trim();
}

function addEchoToken(tokens: Set<string>, value: unknown): void {
	if (typeof value !== "string") return;
	const raw = value.trim();
	if (!raw || raw === "." || raw === "*" || raw === "/") return;
	const normalized = normalizeEchoText(raw);
	if (normalized.length >= 3) tokens.add(normalized);
	const home = os.homedir();
	if (raw.startsWith(home)) {
		const shortened = normalizeEchoText(`~${raw.slice(home.length)}`);
		if (shortened.length >= 3) tokens.add(shortened);
	}
	const base = path.basename(raw);
	if (base && base !== raw) {
		const normalizedBase = normalizeEchoText(base);
		if (normalizedBase.length >= 6) tokens.add(normalizedBase);
	}
}

function extractToolEchoTokens(items: DisplayItem[]): Set<string> {
	const tokens = new Set<string>();
	for (const item of items) {
		if (item.type !== "toolCall") continue;
		const args = item.args ?? {};
		switch (item.name) {
			case "read":
			case "write":
			case "edit":
				addEchoToken(tokens, args.file_path ?? args.path);
				break;
			case "ls":
				addEchoToken(tokens, args.path ?? ".");
				break;
			case "grep":
				addEchoToken(tokens, args.pattern);
				addEchoToken(tokens, args.path);
				addEchoToken(tokens, args.glob);
				break;
			case "find":
				addEchoToken(tokens, args.pattern);
				addEchoToken(tokens, args.path);
				break;
			case "bash": {
				const command = typeof args.command === "string" ? args.command.replace(/\s+/g, " ").trim() : "";
				addEchoToken(tokens, command.length > 90 ? command.slice(0, 90) : command);
				break;
			}
		}
	}
	return tokens;
}

export function finalOutputLooksLikeToolEcho(finalOutput: string, toolCalls: DisplayItem[]): boolean {
	if (!finalOutput.trim() || toolCalls.length === 0) return false;
	if (/```/.test(finalOutput)) return false;
	const tokens = extractToolEchoTokens(toolCalls);
	if (tokens.size === 0) return false;
	const lines = finalOutput
		.split(/\r?\n/)
		.map((line) => normalizeEchoText(line))
		.filter(Boolean);
	if (lines.length === 0) return false;

	const proseMarkers = /\b(finding|findings|warning|warn|conclusion|recommendation|because|therefore|issue|bug|risk|observed|validated|failed|failure|passed|note|summary)\b/i;
	const proseLines = lines.filter((line) => proseMarkers.test(line)).length;
	if (proseLines >= 2) return false;

	let matchingLines = 0;
	for (const line of lines) {
		for (const token of tokens) {
			if (line.includes(token)) {
				matchingLines++;
				break;
			}
		}
	}
	const ratio = matchingLines / lines.length;
	if (matchingLines >= 5 && ratio >= 0.65) return true;
	return lines.length <= 25 && matchingLines >= 3 && ratio >= 0.8;
}

export function finalResponseSuppressedLine(theme: Theme): string {
	return theme.fg("dim", "(final response repeated the tool activity list; hidden)");
}

export function formatToolCall(
	toolName: string,
	args: Record<string, unknown>,
	themeFg: (color: any, text: string) => string,
): string {
	const shortenPath = (p: string) => compactPath(p, { maxChars: 72 });

	switch (toolName) {
		case "bash": {
			const command = (args.command as string) || "...";
			const compactCommand = command.replace(/\s+/g, " ").trim();
			const preview = /pi-(?:sub)?agents-tmux\/sessions\/.*\/outbox\//.test(compactCommand)
				? "complete_subagent (legacy shell completion)"
				: /^sleep\s+\d+\b/.test(compactCommand)
					? compactCommand.replace(/^sleep\s+/, "wait ")
					: oneLinePreview(compactCommand, 60);
			return themeFg("muted", "$ ") + themeFg("toolOutput", preview);
		}
		case "read": {
			const rawPath = (args.file_path || args.path || "...") as string;
			const filePath = shortenPath(rawPath);
			const offset = args.offset as number | undefined;
			const limit = args.limit as number | undefined;
			let text = themeFg("accent", filePath);
			if (offset !== undefined || limit !== undefined) {
				const startLine = offset ?? 1;
				const endLine = limit !== undefined ? startLine + limit - 1 : "";
				text += themeFg("warning", `:${startLine}${endLine ? `-${endLine}` : ""}`);
			}
			return themeFg("muted", "read ") + text;
		}
		case "write": {
			const rawPath = (args.file_path || args.path || "...") as string;
			const filePath = shortenPath(rawPath);
			const content = (args.content || "") as string;
			const lines = content.split("\n").length;
			let text = themeFg("muted", "write ") + themeFg("accent", filePath);
			if (lines > 1) text += themeFg("dim", ` (${lines} lines)`);
			return text;
		}
		case "edit": {
			const rawPath = (args.file_path || args.path || "...") as string;
			return themeFg("muted", "edit ") + themeFg("accent", shortenPath(rawPath));
		}
		case "ls": {
			const rawPath = (args.path || ".") as string;
			return themeFg("muted", "ls ") + themeFg("accent", shortenPath(rawPath));
		}
		case "find": {
			const pattern = (args.pattern || "*") as string;
			const rawPath = (args.path || ".") as string;
			return themeFg("muted", "find ") + themeFg("accent", pattern) + themeFg("dim", ` in ${shortenPath(rawPath)}`);
		}
		case "grep": {
			const pattern = (args.pattern || "") as string;
			const rawPath = (args.path || ".") as string;
			return (
				themeFg("muted", "grep ") +
				themeFg("accent", `/${pattern}/`) +
				themeFg("dim", ` in ${shortenPath(rawPath)}`)
			);
		}
		default: {
			const argsStr = JSON.stringify(args);
			const preview = argsStr.length > 50 ? `${argsStr.slice(0, 50)}...` : argsStr;
			return themeFg("accent", toolName) + themeFg("dim", ` ${preview}`);
		}
	}
}

export function toolChromeRule(theme: Theme, width: number): string {
	const rule = glyphs().line.repeat(Math.max(1, width));
	for (const token of ["borderMuted", "muted", "dim"] as const) {
		try {
			const styled = theme.fg(token, rule);
			const textStyled = theme.fg("text", rule);
			if (styled !== rule && styled !== textStyled) return styled;
		} catch {
			// Try the next token/fallback below.
		}
	}
	return `\x1b[90m${rule}\x1b[39m`;
}

export function wrapAnsiLines(text: string, width: number): string[] {
	const targetWidth = Math.max(1, width);
	return text.split(/\r?\n/).flatMap((line) => {
		const wrapped = wrapTextWithAnsi(line, targetWidth);
		return wrapped.length > 0 ? wrapped : [""];
	});
}

export function wrappedText(text: string): Component {
	return {
		invalidate() {},
		render(width: number): string[] {
			return wrapAnsiLines(text, width);
		},
	};
}

export function framedComponent(inner: Component, theme: Theme): Component {
	return {
		invalidate() {
			inner.invalidate?.();
		},
		render(width: number): string[] {
			const rule = toolChromeRule(theme, width);
			return [rule, ...inner.render(width), rule];
		},
	};
}

export function framedMessage(content: string, theme: Theme): Component {
	return {
		invalidate() {},
		render(width: number): string[] {
			const rule = toolChromeRule(theme, width);
			return [rule, ...wrapAnsiLines(content, width), rule];
		},
	};
}

export function sectionHeading(theme: Theme, label: string): string {
	const rule = glyphs().line.repeat(3);
	return `${theme.fg("muted", `${rule} `)}${theme.fg("toolTitle", theme.bold(label))}${theme.fg("muted", ` ${rule}`)}`;
}

export function addSectionHeading(container: Container, theme: Theme, label: string): void {
	container.addChild(new Spacer(1));
	container.addChild(wrappedText(sectionHeading(theme, label)));
}

export function addWrappedSection(container: Container, theme: Theme, label: string, content: string, tone: "toolOutput" | "dim" | "muted" = "toolOutput"): void {
	addSectionHeading(container, theme, label);
	container.addChild(wrappedText(theme.fg(tone, content || "(none)")));
}

export function addArtifactPathSection(container: Container, theme: Theme, label: string, filePath: string | undefined): void {
	if (!filePath) return;
	addWrappedSection(container, theme, label, compactPath(filePath, { maxChars: Number.POSITIVE_INFINITY }), "toolOutput");
}

export function agentsCommandBullet(theme: Theme): string {
	return theme.fg("accent", glyphs().bullet);
}

export function agentWord(theme: Theme): string {
	return theme.fg("accent", theme.bold("Agent"));
}

export function agentStatusBadge(theme: Theme, label: string, tone: "success" | "warning" | "error" | "muted" = "muted"): string {
	return theme.fg(tone, label);
}

export function agentStatusLine(theme: Theme, agent: string, label: string, tone: "success" | "warning" | "error" | "muted", suffix = ""): string {
	return `${agentsCommandBullet(theme)}${agentWord(theme)} ${ansiMagenta(theme.bold(agent))} ${agentStatusBadge(theme, label, tone)}${suffix}`;
}

export function agentsCommandArtifactLine(theme: Theme, branch: "├" | "└", label: string, filePath: string | undefined, width: number): string {
	const prefix = `${subagentBranch(theme, branch)}${theme.fg("muted", `${label} `)}`;
	const maxChars = Math.max(24, width - visibleWidth(prefix) - 1);
	return `${prefix}${theme.fg("toolOutput", compactPath(filePath, { maxChars }))}`;
}

export function stringifyError(error: unknown): string {
	if (error instanceof Error) return `${error.name}: ${error.message}`;
	return String(error);
}

export function delay(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

