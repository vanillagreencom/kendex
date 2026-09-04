import { type ExtensionAPI } from "@earendil-works/pi-coding-agent";

import { settingNumber } from "./settings.js";
import {
	isStackableToolName,
	renderStackItemText,
	stackItemCallText,
	type StackableToolName,
	type StackItem,
} from "./stack.js";
import { stackPrefix, toolLabel, treeConnector } from "./theme.js";
import {
	lineCount,
	makeEmpty,
	makeTruncatedLines,
	resultTruncated,
	splitTerminalLines,
	textContent,
} from "./text.js";
import { contextCwd, getBuiltInTool } from "./tools.js";

type BatchToolCall = { args: Record<string, any>; tool: StackableToolName };

interface BatchToolItem {
	args: Record<string, any>;
	details?: unknown;
	index: number;
	isError: boolean;
	resultText: string;
	toolName: StackableToolName;
	truncated: boolean;
}

interface BatchToolDetails {
	items: BatchToolItem[];
	failed: number;
	succeeded: number;
	total: number;
}

const TOOL_BATCH_MAX_OUTPUT_BYTES = 50 * 1024;
const TOOL_BATCH_MAX_OUTPUT_LINES = 2_000;
const TOOL_BATCH_DEFAULT_CALL_TIMEOUT_MS = 120_000;
const TOOL_BATCH_MIN_CALL_TIMEOUT_MS = 1_000;

function utf8Length(text: string): number {
	return Buffer.byteLength(text, "utf8");
}

function fitPrefix(text: string, maxBytes: number): string {
	if (utf8Length(text) <= maxBytes) return text;
	let low = 0;
	let high = text.length;
	while (low < high) {
		const mid = Math.ceil((low + high) / 2);
		if (utf8Length(text.slice(0, mid)) <= maxBytes) low = mid;
		else high = mid - 1;
	}
	return text.slice(0, low);
}

function fitSuffix(text: string, maxBytes: number): string {
	if (utf8Length(text) <= maxBytes) return text;
	let low = 0;
	let high = text.length;
	while (low < high) {
		const mid = Math.ceil((low + high) / 2);
		if (utf8Length(text.slice(text.length - mid)) <= maxBytes) low = mid;
		else high = mid - 1;
	}
	return text.slice(text.length - low);
}

function capBatchItemText(text: string, maxBytes: number, maxLines: number): { text: string; truncated: boolean } {
	const originalBytes = utf8Length(text);
	const originalLines = lineCount(text);
	if (originalBytes <= maxBytes && originalLines <= maxLines) return { text, truncated: false };

	const marker = `[...tool_batch item truncated: showing head and tail within ${maxLines} lines / ${Math.round(maxBytes / 1024)}KB. Original: ${originalLines} lines / ${Math.round(originalBytes / 1024)}KB...]`;
	const markerBytes = utf8Length(`\n${marker}\n`);
	if (maxBytes <= markerBytes + 128 || maxLines <= 3) return { text: fitPrefix(marker, maxBytes), truncated: true };
	const lines = splitTerminalLines(text);
	let working: string;
	if (lines.length > maxLines) {
		const bodyLines = Math.max(2, maxLines - 1);
		const headCount = Math.max(1, Math.floor(bodyLines / 2));
		const tailCount = Math.max(1, bodyLines - headCount);
		working = [...lines.slice(0, headCount), marker, ...lines.slice(-tailCount)].join("\n");
	} else {
		working = text;
	}

	if (utf8Length(working) > maxBytes) {
		const contentBudget = Math.max(256, maxBytes - markerBytes);
		const headBudget = Math.max(128, Math.floor(contentBudget * 0.45));
		const tailBudget = Math.max(128, contentBudget - headBudget);
		working = `${fitPrefix(working, headBudget)}\n${marker}\n${fitSuffix(working, tailBudget)}`;
	}
	return { text: working, truncated: true };
}

function allocateBatchBudgets(sizes: number[], total: number): number[] {
	const budgets = new Array(sizes.length).fill(0);
	let remaining = Math.max(0, total);
	let pending = sizes.map((_size, index) => index);
	while (pending.length > 0) {
		const fair = Math.max(1, Math.floor(remaining / pending.length));
		const fitting = pending.filter((index) => sizes[index] <= fair);
		if (fitting.length === 0) {
			for (const index of pending) budgets[index] = fair;
			break;
		}
		for (const index of fitting) {
			budgets[index] = sizes[index];
			remaining -= sizes[index];
		}
		pending = pending.filter((index) => !fitting.includes(index));
	}
	return budgets;
}

function capBatchItemsForAggregate(items: BatchToolItem[]): BatchToolItem[] {
	if (utf8Length(toolBatchOutput(items)) <= TOOL_BATCH_MAX_OUTPUT_BYTES && lineCount(toolBatchOutput(items)) <= TOOL_BATCH_MAX_OUTPUT_LINES) return items;

	const emptyItems = items.map((item) => ({ ...item, resultText: "" }));
	const overheadBytes = utf8Length(toolBatchOutput(emptyItems));
	const overheadLines = lineCount(toolBatchOutput(emptyItems));
	const availableBytes = Math.max(1, TOOL_BATCH_MAX_OUTPUT_BYTES - overheadBytes - 512);
	const availableLines = Math.max(1, TOOL_BATCH_MAX_OUTPUT_LINES - overheadLines - items.length);
	const byteBudgets = allocateBatchBudgets(items.map((item) => utf8Length(item.resultText)), availableBytes);
	const lineBudgets = allocateBatchBudgets(items.map((item) => lineCount(item.resultText)), availableLines);

	return items.map((item, index) => {
		const capped = capBatchItemText(item.resultText, byteBudgets[index] ?? 1, lineBudgets[index] ?? 1);
		return capped.truncated ? { ...item, resultText: capped.text, truncated: true } : item;
	});
}

const ToolBatchParams = {
	type: "object",
	additionalProperties: false,
	properties: {
		calls: {
			type: "array",
			minItems: 1,
			items: {
				type: "object",
				additionalProperties: true,
				description: "One tool call. Prefer { tool, args } (e.g. { tool: 'read', args: { path: 'README.md' } }). MCP-style { name, arguments } and flat shorthand { tool: 'read', path: 'README.md' } are also accepted. The 'tool' / 'name' field must be one of read | grep | find | ls | bash.",
				properties: {
					tool: { type: "string", enum: ["read", "grep", "find", "ls", "bash"], description: "Tool to run inside the batch (or pass 'name' instead)." },
					name: { type: "string", enum: ["read", "grep", "find", "ls", "bash"], description: "Alias for 'tool' (MCP-style shape)." },
					args: { type: "object", additionalProperties: true, description: "Arguments for the selected tool. Optional; flat sibling fields are folded into args." },
					arguments: { type: "object", additionalProperties: true, description: "Alias for 'args' (MCP-style shape)." },
				},
			},
		},
		concurrency: { type: "number", description: "Maximum calls to run at once. Defaults to all calls, capped by settings." },
	},
	required: ["calls"],
} as const;

function normalizeBatchCalls(value: unknown): BatchToolCall[] {
	if (!Array.isArray(value)) return [];
	const calls: BatchToolCall[] = [];
	for (const raw of value) {
		if (!raw || typeof raw !== "object") continue;
		const tool = (raw as any).tool ?? (raw as any).name;
		if (!isStackableToolName(tool)) continue;
		const flatArgs: Record<string, unknown> = {};
		for (const [key, val] of Object.entries(raw as Record<string, unknown>)) {
			if (key === "tool" || key === "name" || key === "args" || key === "arguments") continue;
			flatArgs[key] = val;
		}
		const nestedArgsRaw = (raw as any).args ?? (raw as any).arguments;
		const nestedArgs = nestedArgsRaw && typeof nestedArgsRaw === "object" && !Array.isArray(nestedArgsRaw) ? nestedArgsRaw : {};
		calls.push({ args: { ...flatArgs, ...nestedArgs }, tool });
	}
	return calls;
}

async function mapBatchWithConcurrency<TIn, TOut>(items: TIn[], concurrency: number, fn: (item: TIn, index: number) => Promise<TOut>): Promise<TOut[]> {
	const results = new Array<TOut>(items.length);
	let next = 0;
	const workers = new Array(Math.max(1, Math.min(concurrency, items.length || 1))).fill(null).map(async () => {
		while (true) {
			const index = next++;
			if (index >= items.length) return;
			results[index] = await fn(items[index], index);
		}
	});
	await Promise.all(workers);
	return results;
}

function batchStackItem(item: BatchToolItem): StackItem {
	return {
		args: item.args,
		batchId: "tool-batch",
		id: `tool-batch:${item.index}`,
		isError: item.isError,
		resultText: item.resultText,
		status: item.isError ? "error" : "done",
		toolName: item.toolName,
		truncated: item.truncated,
	};
}

function renderToolBatchText(items: BatchToolItem[], theme: any, expanded: boolean, cwd?: string): string {
	const failed = items.filter((item) => item.isError).length;
	const succeeded = items.length - failed;
	const header =
		stackPrefix(theme) +
		toolLabel(theme, `Batch ${succeeded}/${items.length}`) +
		theme.fg(failed > 0 ? "warning" : "success", failed > 0 ? ` · ${failed} failed` : " · succeeded") +
		(expanded ? "" : theme.fg("dim", " · ctrl+o to expand"));
	const lines = [header];
	items.forEach((item, index) => {
		const stackItem = batchStackItem(item);
		lines.push(renderStackItemText(stackItem, theme, expanded, cwd, index === items.length - 1 ? "└" : "├"));
	});
	return lines.join("\n");
}

function toolBatchOutput(items: BatchToolItem[]): string {
	const failed = items.filter((item) => item.isError).length;
	const lines = [`Batch: ${items.length - failed}/${items.length} succeeded`];
	for (const item of items) {
		const label = `${item.index + 1}. ${item.toolName}`;
		lines.push("", `## ${label}`, item.isError ? "Status: failed" : "Status: completed", item.resultText || "(no output)");
	}
	return lines.join("\n");
}

function renderToolBatchCallText(args: any, theme: any, cwd?: string): string {
	const calls = normalizeBatchCalls(args?.calls);
	const lines = [stackPrefix(theme) + toolLabel(theme, `Batch ${calls.length || 0} tool${calls.length === 1 ? "" : "s"} launching`)];
	calls.slice(0, 12).forEach((call, index) => {
		const item: StackItem = { args: call.args, batchId: "call", id: String(index), isError: false, resultText: "", status: "running", toolName: call.tool, truncated: false };
		lines.push(`${treeConnector(theme, index === calls.length - 1 ? "└" : "├", cwd)}${stackItemCallText(item, theme, cwd)}`);
	});
	if (calls.length > 12) lines.push(`${treeConnector(theme, "└", cwd)}${theme.fg("muted", `… +${calls.length - 12} more`)}`);
	return lines.join("\n");
}

export function registerToolBatch(pi: ExtensionAPI, agent: any, cwd: string): void {
	pi.registerTool({
		renderShell: "self",
		name: "tool_batch",
		label: "Tool Batch",
		description:
			"Run multiple independent read/grep/find/ls/bash calls as one composite tool with a single stacked renderer. Prefer this over separate parallel read/search/list/diagnostic bash calls. Use bash only for diagnostic commands whose side effects and ordering do not matter.",
		promptSnippet: "Batch 2+ independent read/search/list/diagnostic bash calls into one compact result.",
		promptGuidelines: [
			"Prefer tool_batch instead of separate parallel read, grep, find, ls, or diagnostic bash calls whenever the calls are independent.",
			"Use individual calls when you need the maximum output budget from each call; tool_batch preserves full per-call output only while the combined result fits the aggregate cap.",
			"Use individual read/grep/find/ls/bash calls when there is only one call, when calls depend on previous results, when bash mutates state, when streaming/live output matters, or when the user explicitly wants separate tool entries.",
			"Do not use tool_batch for edit/write or for bash commands that mutate files, depend on ordering, need streaming output, or should be inspected as separate commands.",
		],
		parameters: ToolBatchParams as never,
		async execute(toolCallId: string, params: any, signal: AbortSignal | undefined, _onUpdate: unknown, context: any) {
			const effectiveCwd = contextCwd(context, cwd);
			const calls = normalizeBatchCalls(params?.calls);
			const maxCalls = Math.max(1, Math.floor(settingNumber("batchMaxCalls", 8, effectiveCwd)));
			if (calls.length === 0) return { content: [{ type: "text", text: "No valid calls provided." }], details: { failed: 0, items: [], succeeded: 0, total: 0 } };
			if (calls.length > maxCalls) {
				return {
					content: [{ type: "text", text: `Too many calls (${calls.length}). Max is ${maxCalls}.` }],
					details: { failed: calls.length, items: [], succeeded: 0, total: calls.length },
					isError: true,
				};
			}
			const concurrency = Math.max(1, Math.min(calls.length, Math.floor(Number(params?.concurrency) || calls.length), maxCalls));
			// per-call timeout so a single wedged inner tool can't block the
			// aggregate forever. Default 120s, minimum 1s. Each inner gets its own
			// AbortController so timeout aborts only that call (parent abort still
			// propagates to all children via the addEventListener bridge).
			const batchCallTimeoutMs = Math.max(
				TOOL_BATCH_MIN_CALL_TIMEOUT_MS,
				Math.floor(settingNumber("batchCallTimeoutMs", TOOL_BATCH_DEFAULT_CALL_TIMEOUT_MS, effectiveCwd)),
			);
			const items = await mapBatchWithConcurrency(calls, concurrency, async (call, index): Promise<BatchToolItem> => {
				const childController = new AbortController();
				const onParentAbort = () => childController.abort();
				if (signal) {
					if (signal.aborted) childController.abort();
					else signal.addEventListener("abort", onParentAbort);
				}
				let timeoutHandle: ReturnType<typeof setTimeout> | undefined;
				try {
					const original = getBuiltInTool(agent, effectiveCwd, call.tool);
					if (!original?.execute) throw new Error(`Built-in tool unavailable: ${call.tool}`);
					const timeoutPromise = new Promise<never>((_, reject) => {
						timeoutHandle = setTimeout(() => {
							// Reject the race promise BEFORE aborting so the timeout
							// error wins over any AbortError the inner tool may raise
							// in response to childController.abort().
							reject(
								new Error(
									`tool_batch inner call ${call.tool} timed out after ${batchCallTimeoutMs}ms`,
								),
							);
							childController.abort();
						}, batchCallTimeoutMs);
					});
					const result = await Promise.race([
						original.execute(`${toolCallId}:${index}`, call.args, childController.signal, undefined),
						timeoutPromise,
					]);
					return {
						args: call.args,
						details: result?.details,
						index,
						isError: Boolean(result?.isError),
						resultText: textContent(result),
						toolName: call.tool,
						truncated: resultTruncated(result),
					};
				} catch (error) {
					return {
						args: call.args,
						index,
						isError: true,
						resultText: error instanceof Error ? `${error.name}: ${error.message}` : String(error),
						toolName: call.tool,
						truncated: false,
					};
				} finally {
					if (timeoutHandle) clearTimeout(timeoutHandle);
					signal?.removeEventListener("abort", onParentAbort);
				}
			});
			const cappedItems = capBatchItemsForAggregate(items);
			const failed = cappedItems.filter((item) => item.isError).length;
			const details: BatchToolDetails = { failed, items: cappedItems, succeeded: cappedItems.length - failed, total: cappedItems.length };
			return { content: [{ type: "text", text: toolBatchOutput(cappedItems) }], details, isError: failed > 0 };
		},
		renderCall() {
			return makeEmpty();
		},
		renderResult(result: any, { expanded, isPartial }: any, theme: any, context: any) {
			if (isPartial) return makeTruncatedLines(renderToolBatchCallText(context?.args, theme, context?.cwd ?? cwd));
			const details = result.details as BatchToolDetails | undefined;
			if (!details?.items) return makeTruncatedLines(textContent(result) || "(no output)");
			return makeTruncatedLines(renderToolBatchText(details.items, theme, expanded, context?.cwd ?? cwd));
		},
	});
}

