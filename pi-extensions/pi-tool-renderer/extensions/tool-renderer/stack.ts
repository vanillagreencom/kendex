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
 *  are dropped whole; a dropped call that renders again is drawn on its own,
 *  outside every batch, and kept only while there is room. */
export const STACK_MAX_ITEMS = 256;
/** A run of stackable calls longer than this starts a new batch, so the batch
 *  still receiving calls stays small enough for eviction to reach the rest. */
export const STACK_MAX_BATCH_ITEMS = 64;
/** At most this many characters of one result are kept for its preview. */
export const STACK_RESULT_MAX_CHARS = 16_384;
export const stackItems = new Map<string, StackItem>();
export const stackBatches = new Map<string, StackBatch>();
const stackInvalidators = new Map<string, () => void>();
/** The batch live calls join: only tool_execution_start adds to it. */
let currentStackBatch: StackBatch | null = null;
/** The batch calls first seen at render time join, such as a resumed
 *  session's history. It is never the live batch. */
let renderedStackBatch: StackBatch | null = null;
/** Whether this session has dropped a batch. From then on a call first seen at
 *  render time may be a dropped one, and keeping it would take the room of a
 *  batch still on screen. */
let stackEvicted = false;
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
	return batch;
}

/** The one constructor of a StackItem: a running call with no result yet. */
export function newStackItem(toolName: StackableToolName, id: string, args: any, batchId: string): StackItem {
	return { args, batchId, id, isError: false, resultLines: 0, resultText: "", status: "running", toolName, truncated: false };
}

function addStackItem(batch: StackBatch, item: StackItem): void {
	batch.items.push(item.id);
	stackItems.set(item.id, item);
	batch.updatedAt = Date.now();
}

/** Record a live call: it joins the live batch, or starts one, and the oldest
 *  finished batches are dropped once the item count passes STACK_MAX_ITEMS. */
function startStackItem(toolName: StackableToolName, id: string, args: any): StackItem {
	const existing = stackItems.get(id);
	if (existing) {
		existing.args = args ?? existing.args;
		return existing;
	}
	if (!currentStackBatch || currentStackBatch.items.length >= STACK_MAX_BATCH_ITEMS) currentStackBatch = createStackBatch(id);
	const item = newStackItem(toolName, id, args, currentStackBatch.id);
	addStackItem(currentStackBatch, item);
	evictOldStackBatches();
	notifyStackBatch(item.batchId);
	return item;
}

/** The item for a call Pi renders. A call first seen here, such as a resumed
 *  session's history, joins the rendered batch and never evicts: a render pass
 *  that dropped the batches it draws next would regroup the whole history.
 *  Once the item count reaches STACK_MAX_ITEMS, or the session has dropped a
 *  batch, such a call gets an item outside every batch that is not kept. */
function renderedStackItem(toolName: StackableToolName, id: string, args: any): StackItem {
	const existing = stackItems.get(id);
	if (existing) {
		existing.args = args ?? existing.args;
		return existing;
	}
	if (stackEvicted || stackItems.size >= STACK_MAX_ITEMS) return newStackItem(toolName, id, args, "");
	if (!renderedStackBatch || renderedStackBatch.items.length >= STACK_MAX_BATCH_ITEMS || !stackBatches.has(renderedStackBatch.id)) {
		renderedStackBatch = createStackBatch(id);
	}
	const item = newStackItem(toolName, id, args, renderedStackBatch.id);
	addStackItem(renderedStackBatch, item);
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
		stackEvicted = true;
	}
}

/** A live event ends both open batches: a later call starts a new one. */
function closeOpenStackBatches(): void {
	currentStackBatch = null;
	renderedStackBatch = null;
}

/** Record a finished result's text on its item, capping the text it keeps.
 *  `truncated` is true when the producer already cut the text. */
export function setStackItemResultText(item: StackItem, text: string, isError: boolean, truncated: boolean): void {
	item.status = isError ? "error" : "done";
	item.isError = isError;
	item.resultLines = lineCount(text);
	item.truncated = truncated || text.length > STACK_RESULT_MAX_CHARS;
	if (text.length <= STACK_RESULT_MAX_CHARS) item.resultText = text;
	else if (item.toolName === "bash") item.resultText = text.slice(-STACK_RESULT_MAX_CHARS);
	else item.resultText = text.slice(0, STACK_RESULT_MAX_CHARS);
}

/** Record a finished tool result on its item. */
function setStackItemResult(item: StackItem, result: any, isError: unknown): void {
	setStackItemResultText(item, textContent(result), Boolean(isError), resultTruncated(result));
}

/** Release every stack collection: the items, their batches and invalidators
 *  belong to one session's tool calls. */
export function clearStackState(): void {
	stackItems.clear();
	stackBatches.clear();
	stackInvalidators.clear();
	closeOpenStackBatches();
	stackEvicted = false;
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

function stackBatchHeadline(items: StackItem[], theme: any, expanded: boolean, childDisplay: StackChildDisplay): string {
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

function renderStackBatch(items: StackItem[], theme: any, expanded: boolean, cwd?: string, childDisplay: StackChildDisplay = "rows"): TruncatedLines {
	let text = stackBatchHeadline(items, theme, expanded, childDisplay);
	if (childDisplay === "anchor-list" || (childDisplay === "headline" && expanded)) {
		items.forEach((item, index) => {
			text += `\n${renderStackItemText(item, theme, expanded, cwd, index === items.length - 1 ? "└" : "├")}`;
		});
	}
	return makeTruncatedLines(text);
}

export function renderStackedToolResult(toolName: StackableToolName, result: any, isPartial: boolean, expanded: boolean, theme: any, context: any, cwd: string) {
	const id = contextToolCallId(context, toolName, context?.args);
	const item = renderedStackItem(toolName, id, context?.args ?? {});
	const batch = stackBatches.get(item.batchId);
	if (batch && context?.invalidate) stackInvalidators.set(id, context.invalidate);
	if (!isPartial) {
		setStackItemResult(item, result, context?.isError);
		if (batch) batch.updatedAt = Date.now();
	}
	const effectiveCwd = context?.cwd ?? cwd;
	const childDisplay = stackChildDisplay(effectiveCwd);
	// An item outside every batch is drawn as a batch of one.
	if (!batch) return renderStackBatch([item], theme, expanded, effectiveCwd, childDisplay);
	const items = batch.items.map((itemId) => stackItems.get(itemId)).filter(Boolean) as StackItem[];
	if (batch.anchorId === id) return renderStackBatch(items, theme, expanded, effectiveCwd, childDisplay);
	if (childDisplay !== "rows") return makeEmpty();
	const index = Math.max(0, items.findIndex((candidate) => candidate.id === id));
	return makeTruncatedLines(renderStackItemText(item, theme, false, effectiveCwd, index === items.length - 1 ? "└" : "├"));
}

export function registerStackEvents(pi: ExtensionAPI): void {
	pi.on("session_start", clearStackState);
	pi.on("session_shutdown", clearStackState);
	pi.on("agent_start", closeOpenStackBatches);
	pi.on("tool_execution_start", (event: any, ctx: any) => {
		renderedStackBatch = null;
		if (isStackableToolName(event.toolName) && stackToolCalls(ctx?.cwd)) {
			startStackItem(event.toolName, String(event.toolCallId), event.args ?? event.input ?? {});
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
	pi.on("agent_end", closeOpenStackBatches);
}

