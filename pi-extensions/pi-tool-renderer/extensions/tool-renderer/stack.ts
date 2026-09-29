import { type ExtensionAPI } from "@earendil-works/pi-coding-agent";

import { renderBashDiffOutput, shouldRenderBashDiffsForCommand, suppressReadOnlyBashDiffOutput } from "./diff.js";
import {
	settingNumber,
	stackChildDisplay,
	stackToolCalls,
	type StackChildDisplay,
} from "./settings.js";
import { stackPrefix, toolLabel, treeConnector, treeStem, type TreeBranch } from "./theme.js";
import {
	joinPhrases,
	lineCount,
	makeEmpty,
	makeTruncatedLines,
	plural,
	preview,
	readCallText,
	bashCallText,
	readOnlyCallText,
	resultTruncated,
	splitTerminalLines,
	textContent,
	type TruncatedLines,
} from "./text.js";
import { renderPathListPreview } from "./text.js";

export type StackableToolName = "read" | "bash" | "grep" | "find" | "ls";
export type StackItemStatus = "running" | "done" | "error";

export interface StackItem {
	args: any;
	batchId: string;
	id: string;
	isError: boolean;
	/** Line count of the whole result, taken before `resultText` is capped. */
	resultLines: number;
	/** The result text, capped at STACK_RESULT_MAX_CHARS: the head for read and
	 *  search tools, the tail for bash, the ends their previews show. */
	resultText: string;
	status: StackItemStatus;
	toolName: StackableToolName;
	truncated: boolean;
}

export interface StackBatch {
	anchorId: string;
	id: string;
	items: string[];
	updatedAt: number;
}

const STACKABLE_TOOLS = new Set<string>(["read", "bash", "grep", "find", "ls"]);
/** At most this many stack items are kept. Past it the oldest finished batches
 *  are dropped whole; a dropped call that renders again rejoins as a new item. */
export const STACK_MAX_ITEMS = 256;
/** A run of stackable calls longer than this starts a new batch, so the batch
 *  still receiving calls stays small enough for eviction to reach the rest. */
export const STACK_MAX_BATCH_ITEMS = 64;
/** At most this many characters of one result are kept for its preview. */
export const STACK_RESULT_MAX_CHARS = 16_384;
export const stackItems = new Map<string, StackItem>();
export const stackBatches = new Map<string, StackBatch>();
const stackInvalidators = new Map<string, () => void>();
let currentStackBatch: StackBatch | null = null;
let stackBatchCounter = 0;

export function isStackableToolName(toolName: unknown): toolName is StackableToolName {
	return typeof toolName === "string" && STACKABLE_TOOLS.has(toolName);
}

function notifyStackBatch(batchId: string): void {
	const batch = stackBatches.get(batchId);
	if (!batch) return;
	for (const id of batch.items) stackInvalidators.get(id)?.();
}

function createStackBatch(firstId: string): StackBatch {
	const batch: StackBatch = { anchorId: firstId, id: `stack-${++stackBatchCounter}`, items: [], updatedAt: Date.now() };
	stackBatches.set(batch.id, batch);
	currentStackBatch = batch;
	return batch;
}

export function ensureStackItem(toolName: StackableToolName, id: string, args: any): StackItem {
	const existing = stackItems.get(id);
	if (existing) {
		existing.args = args ?? existing.args;
		return existing;
	}
	const batch = currentStackBatch && currentStackBatch.items.length < STACK_MAX_BATCH_ITEMS ? currentStackBatch : createStackBatch(id);
	if (!batch.items.includes(id)) batch.items.push(id);
	const item: StackItem = { args, batchId: batch.id, id, isError: false, resultLines: 0, resultText: "", status: "running", toolName, truncated: false };
	stackItems.set(id, item);
	batch.updatedAt = Date.now();
	evictOldStackBatches();
	notifyStackBatch(batch.id);
	return item;
}

/** Drop the oldest batches until the item count is within STACK_MAX_ITEMS. The
 *  current batch is never dropped: its calls are still arriving. */
function evictOldStackBatches(): void {
	for (const [batchId, batch] of stackBatches) {
		if (stackItems.size <= STACK_MAX_ITEMS) return;
		if (batch === currentStackBatch) continue;
		for (const id of batch.items) {
			stackItems.delete(id);
			stackInvalidators.delete(id);
		}
		stackBatches.delete(batchId);
	}
}

/** Record a finished result on its item, capping the text it keeps. */
function setStackItemResult(item: StackItem, result: any, isError: unknown): void {
	const text = textContent(result);
	item.status = isError ? "error" : "done";
	item.isError = Boolean(isError);
	item.resultLines = lineCount(text);
	item.truncated = resultTruncated(result) || text.length > STACK_RESULT_MAX_CHARS;
	if (text.length <= STACK_RESULT_MAX_CHARS) item.resultText = text;
	else if (item.toolName === "bash") item.resultText = text.slice(-STACK_RESULT_MAX_CHARS);
	else item.resultText = text.slice(0, STACK_RESULT_MAX_CHARS);
}

/** Release every stack collection: the items, their batches and invalidators
 *  belong to one session's tool calls. */
export function clearStackState(): void {
	stackItems.clear();
	stackBatches.clear();
	stackInvalidators.clear();
	currentStackBatch = null;
}

export function contextToolCallId(context: any, toolName: string, args: any): string {
	return String(context?.toolCallId ?? context?.id ?? `${toolName}:${JSON.stringify(args ?? {})}`);
}

export function stackItemCallText(item: StackItem, theme: any, cwd?: string): string {
	if (item.toolName === "read") return readCallText(item.args, theme, cwd);
	if (item.toolName === "bash") return bashCallText(item.args, theme, cwd);
	return readOnlyCallText(item.toolName, item.args, theme, cwd);
}

function stackItemSummary(item: StackItem, theme: any): string {
	if (item.status === "running") return theme.fg("warning", "running");
	if (item.isError) return theme.fg("error", "failed");
	if (item.toolName === "read") {
		const count = item.resultLines;
		let text = theme.fg("success", `${count} line${count === 1 ? "" : "s"}`);
		if (item.truncated) text += theme.fg("warning", " · truncated");
		return text;
	}
	if (item.toolName === "bash") {
		const count = item.resultLines;
		let text = theme.fg("success", "exit 0");
		text += theme.fg("dim", ` · ${count} line${count === 1 ? "" : "s"}`);
		if (item.truncated) text += theme.fg("warning", " · truncated");
		return text;
	}
	const count = item.resultText.trim() ? item.resultLines : 0;
	let text = theme.fg("success", `${count} result${count === 1 ? "" : "s"}`);
	if (item.truncated) text += theme.fg("warning", " · truncated");
	return text;
}

function stackItemPreview(item: StackItem, theme: any, expanded: boolean, cwd?: string): string {
	if (!item.resultText || item.status === "running") return "";
	if (item.toolName === "find" || item.toolName === "ls") return renderPathListPreview(item.resultText, item.toolName, theme, expanded, cwd);
	if (item.toolName === "bash") {
		const renderDiffs = shouldRenderBashDiffsForCommand(item.args, cwd);
		if (!renderDiffs && suppressReadOnlyBashDiffOutput(item.args, item.resultText, cwd)) return "";
		return renderBashDiffOutput(item.resultText, theme, expanded, cwd, renderDiffs) ?? preview(item.resultText, Math.max(1, Math.floor(settingNumber("bashPreviewLines", 80, cwd))), "tail", cwd);
	}
	if (item.toolName === "read") return preview(item.resultText, Math.max(1, Math.floor(settingNumber("readPreviewLines", 80, cwd))), "head", cwd);
	return preview(item.resultText, Math.max(1, Math.floor(settingNumber("searchPreviewLines", 80, cwd))), "head", cwd);
}

export function renderStackItemText(item: StackItem, theme: any, expanded: boolean, cwd?: string, branch = "├"): string {
	const typedBranch = branch as TreeBranch;
	let text = `${treeConnector(theme, typedBranch, cwd)}${stackItemCallText(item, theme, cwd)}${theme.fg("dim", " · ")}${stackItemSummary(item, theme)}`;
	if (expanded) {
		const previewText = stackItemPreview(item, theme, expanded, cwd);
		if (previewText) {
			const stem = item.toolName === "bash" ? treeConnector(theme, "│", cwd) : treeStem(theme, typedBranch, cwd);
			const lines = splitTerminalLines(previewText).map((line) => item.toolName === "bash" ? theme.fg("dim", line) : `${stem}${theme.fg("dim", line)}`);
			text += `\n${lines.join("\n")}`;
		}
	}
	return text;
}

function stackBatchHeadline(batch: StackBatch, theme: any, expanded: boolean, childDisplay: StackChildDisplay): string {
	const items = batch.items.map((id) => stackItems.get(id)).filter(Boolean) as StackItem[];
	const running = items.some((item) => item.status === "running");
	const done = items.filter((item) => item.status !== "running").length;
	const reads = items.filter((item) => item.toolName === "read").length;
	const shells = items.filter((item) => item.toolName === "bash").length;
	const searches = items.filter((item) => item.toolName === "grep" || item.toolName === "find" || item.toolName === "ls").length;
	const phrases: string[] = [];
	if (reads > 0) phrases.push(`${running ? "reading" : "read"} ${plural(reads, "file")}`);
	if (shells > 0) phrases.push(`${running ? "running" : "ran"} ${plural(shells, "shell command")}`);
	if (searches > 0) phrases.push(`${running ? "searching/listing" : "searched/listed"} ${plural(searches, "time")}`);
	const lead = joinPhrases(phrases) || (running ? "running tools" : "ran tools");
	const sentence = lead.charAt(0).toUpperCase() + lead.slice(1);
	const progress = running ? theme.fg("warning", ` · ${done}/${items.length} done`) : theme.fg("success", " · done");
	const expandHint = childDisplay === "headline" && !expanded && items.length > 0 ? theme.fg("dim", " · ctrl+o to expand") : "";
	return `${stackPrefix(theme)}${sentence}${running ? "…" : ""}${progress}${expandHint}`;
}

function renderStackBatch(batch: StackBatch, theme: any, expanded: boolean, cwd?: string, childDisplay: StackChildDisplay = "rows"): TruncatedLines {
	let text = stackBatchHeadline(batch, theme, expanded, childDisplay);
	if (childDisplay === "anchor-list" || (childDisplay === "headline" && expanded)) {
		const items = batch.items.map((id) => stackItems.get(id)).filter(Boolean) as StackItem[];
		items.forEach((item, index) => {
			text += `\n${renderStackItemText(item, theme, expanded, cwd, index === items.length - 1 ? "└" : "├")}`;
		});
	}
	return makeTruncatedLines(text);
}

export function renderStackedToolResult(toolName: StackableToolName, result: any, isPartial: boolean, expanded: boolean, theme: any, context: any, cwd: string) {
	const id = contextToolCallId(context, toolName, context?.args);
	const item = ensureStackItem(toolName, id, context?.args ?? {});
	if (context?.invalidate) stackInvalidators.set(id, context.invalidate);
	if (!isPartial) {
		setStackItemResult(item, result, context?.isError);
		stackBatches.get(item.batchId)!.updatedAt = Date.now();
	}
	const batch = stackBatches.get(item.batchId);
	if (!batch) return makeEmpty();
	const effectiveCwd = context?.cwd ?? cwd;
	const childDisplay = stackChildDisplay(effectiveCwd);
	if (batch.anchorId === id) return renderStackBatch(batch, theme, expanded, effectiveCwd, childDisplay);
	if (childDisplay !== "rows") return makeEmpty();
	const items = batch.items.map((itemId) => stackItems.get(itemId)).filter(Boolean) as StackItem[];
	const index = Math.max(0, items.findIndex((candidate) => candidate.id === id));
	return makeTruncatedLines(renderStackItemText(item, theme, false, effectiveCwd, index === items.length - 1 ? "└" : "├"));
}

export function registerStackEvents(pi: ExtensionAPI): void {
	pi.on("session_start", clearStackState);
	pi.on("session_shutdown", clearStackState);
	pi.on("agent_start", () => {
		currentStackBatch = null;
	});
	pi.on("tool_execution_start", (event: any, ctx: any) => {
		if (isStackableToolName(event.toolName) && stackToolCalls(ctx?.cwd)) {
			ensureStackItem(event.toolName, String(event.toolCallId), event.args ?? event.input ?? {});
			return;
		}
		currentStackBatch = null;
	});
	pi.on("tool_execution_end", (event: any) => {
		const item = stackItems.get(String(event.toolCallId));
		if (!item) return;
		setStackItemResult(item, event.result, event.isError);
		notifyStackBatch(item.batchId);
	});
	pi.on("agent_end", () => {
		currentStackBatch = null;
	});
}

