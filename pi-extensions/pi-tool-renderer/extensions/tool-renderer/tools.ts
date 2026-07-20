import { type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { resolve } from "node:path";

import {
	attachDiffDetails,
	buildStructuredDiff,
	diffSummary,
	editOperationsFromArgs,
	existingSmallTextOrUndefined,
	readTextForDiff,
	renderBashDiffOutput,
	renderMutationCallPreview,
	renderStructuredDiff,
	shouldRenderBashDiffsForCommand,
	suppressReadOnlyBashDiffOutput,
	type StructuredDiff,
} from "./diff.js";
import { renderReadImages } from "./images.js";
import {
	bashLiveOutputDelayMs,
	bashLiveTailLines,
	bashOutputMode,
	readOutputMode,
	searchOutputMode,
	settingNumber,
	stackToolCalls,
} from "./settings.js";
import { stackPrefix, toolLabel, treeConnector } from "./theme.js";
import {
	bashCallText,
	clearBlink,
	commandExit,
	componentHasVisibleLines,
	lineCount,
	makeEmpty,
	makeTruncatedLines,
	preview,
	readCallText,
	readOnlyCallText,
	readResultSummary,
	renderPathListPreview,
	renderToolPathText,
	renderPendingCall,
	renderPendingDetail,
	resultTruncated,
	textContent,
} from "./text.js";
import { renderStackedToolResult, type StackableToolName } from "./stack.js";

export type BuiltInToolName = StackableToolName | "edit" | "write";
export type BuiltInToolSet = Partial<Record<BuiltInToolName, any>>;

const builtInToolCache = new Map<string, BuiltInToolSet>();

export function normalizedCwd(cwd?: string): string {
	return resolve(cwd || process.cwd());
}

function createBuiltInToolSet(agent: any, cwd: string): BuiltInToolSet {
	return {
		read: agent.createReadTool?.(cwd),
		bash: agent.createBashTool?.(cwd),
		edit: agent.createEditTool?.(cwd),
		write: agent.createWriteTool?.(cwd),
		grep: agent.createGrepTool?.(cwd),
		find: agent.createFindTool?.(cwd),
		ls: agent.createLsTool?.(cwd),
	};
}

export function getBuiltInTool(agent: any, cwd: string, toolName: BuiltInToolName): any {
	const key = normalizedCwd(cwd);
	let tools = builtInToolCache.get(key);
	if (!tools) {
		tools = createBuiltInToolSet(agent, key);
		builtInToolCache.set(key, tools);
	}
	return tools[toolName];
}

export function contextCwd(context: any, fallback: string): string {
	return context?.cwd ?? fallback;
}

interface BashLiveTailState {
	startedAt?: number;
	tailShown?: boolean;
	timer?: ReturnType<typeof setTimeout>;
}

function bashLiveTailState(context: any): BashLiveTailState {
	const state = context?.state;
	if (!state || typeof state !== "object") return {};
	const record = state as Record<string, unknown>;
	if (!record.vstackBashLiveTail || typeof record.vstackBashLiveTail !== "object") record.vstackBashLiveTail = {};
	return record.vstackBashLiveTail as BashLiveTailState;
}

function markBashStarted(context: any): BashLiveTailState {
	const state = bashLiveTailState(context);
	if (!state.startedAt && context?.executionStarted) state.startedAt = Date.now();
	return state;
}

function clearBashLiveTailTimer(state: BashLiveTailState): void {
	if (!state.timer) return;
	clearTimeout(state.timer);
	state.timer = undefined;
}

function scheduleBashLiveTailRerender(state: BashLiveTailState, context: any, delayMs: number): void {
	if (state.tailShown || state.timer || typeof context?.invalidate !== "function") return;
	const startedAt = state.startedAt ?? Date.now();
	const remaining = Math.max(0, startedAt + delayMs - Date.now());
	state.timer = setTimeout(() => {
		state.timer = undefined;
		try {
			context.invalidate();
		} catch {
			// Best-effort redraw only; tool execution continues either way.
		}
	}, remaining);
	state.timer.unref?.();
}

function renderBashTail(output: string, limit: number, theme: any, cwd?: string): string {
	const trimmed = output.replace(/(?:\r?\n)+$/, "");
	if (!trimmed) return "";
	const tailLines = preview(trimmed, limit, "tail", cwd).split(/\r?\n/);
	return tailLines.map((line) => theme.fg("dim", line)).join("\n");
}

export function registerRead(pi: ExtensionAPI, agent: any, cwd: string): void {
	const original = getBuiltInTool(agent, cwd, "read");
	if (!original) return;
	pi.registerTool({
		renderShell: "self",
		name: "read",
		label: "read",
		description: original.description,
		parameters: original.parameters,
		async execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, context: any) {
			return getBuiltInTool(agent, contextCwd(context, cwd), "read").execute(id, params, signal, onUpdate);
		},
		renderCall(args: any, theme: any, context: any) {
			return renderPendingCall(readCallText(args ?? {}, theme, context?.cwd ?? cwd), theme, context, cwd);
		},
		renderResult(result: any, { expanded, isPartial }: any, theme: any, context: any) {
			const stacked = stackToolCalls(context?.cwd ?? cwd);
			if (stacked) return renderStackedToolResult("read", result, isPartial, expanded, theme, context, cwd);
			const call = readCallText(context?.args ?? {}, theme, context?.cwd ?? cwd);
			if (isPartial) return renderPendingDetail("reading…", theme);
			clearBlink(context);
			const content = textContent(result);
			const count = lineCount(content);
			const summary = readResultSummary(result, context?.args ?? {}, theme);
			const mode = readOutputMode(context?.cwd ?? cwd);
			if (mode === "hidden") return renderReadImages(makeEmpty(), result, expanded, theme, context, cwd);
			let text = `${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${summary}`;
			if (mode === "preview" && expanded && content) {
				const limit = Math.max(1, Math.floor(settingNumber("readPreviewLines", 80, context?.cwd)));
				text += `\n${preview(content, limit, "head", context?.cwd)
					.split(/\r?\n/)
					.map((line) => `${treeConnector(theme, "│")}${theme.fg("dim", line)}`)
					.join("\n")}`;
				if (count > limit) text += `\n${treeConnector(theme, "│")}${theme.fg("muted", `… ${count - limit} more line(s)`)}`;
			}
			return renderReadImages(makeTruncatedLines(text), result, expanded, theme, context, cwd);
		},
	});
}

export function registerBash(pi: ExtensionAPI, agent: any, cwd: string): void {
	const original = getBuiltInTool(agent, cwd, "bash");
	if (!original) return;
	pi.registerTool({
		renderShell: "self",
		name: "bash",
		label: "bash",
		description: original.description,
		parameters: original.parameters,
		async execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, context: any) {
			return getBuiltInTool(agent, contextCwd(context, cwd), "bash").execute(id, params, signal, onUpdate);
		},
		renderCall(args: any, theme: any, context: any) {
			markBashStarted(context);
			return renderPendingCall(bashCallText(args ?? {}, theme, context?.cwd ?? cwd), theme, context, cwd);
		},
		renderResult(result: any, { expanded, isPartial }: any, theme: any, context: any) {
			const stacked = stackToolCalls(context?.cwd ?? cwd);
			if (stacked) return renderStackedToolResult("bash", result, isPartial, expanded, theme, context, cwd);
			const effectiveCwd = context?.cwd ?? cwd;
			const call = bashCallText(context?.args ?? {}, theme, effectiveCwd);
			const output = textContent(result);
			const liveTailState = markBashStarted(context);
			if (isPartial) {
				const trimmedOutput = output.trim();
				const partialMode = bashOutputMode(effectiveCwd);
				if (partialMode !== "summary" && partialMode !== "hidden" && trimmedOutput) {
					const delayMs = bashLiveOutputDelayMs(effectiveCwd);
					const startedAt = liveTailState.startedAt ?? Date.now();
					if (Date.now() - startedAt >= delayMs) {
						clearBashLiveTailTimer(liveTailState);
						liveTailState.tailShown = true;
						const tailText = renderBashTail(output, bashLiveTailLines(effectiveCwd), theme, effectiveCwd);
						if (tailText) return makeTruncatedLines(tailText);
					}
					scheduleBashLiveTailRerender(liveTailState, context, delayMs);
				}
				return makeEmpty();
			}
			clearBlink(context);
			clearBashLiveTailTimer(liveTailState);
			const exit = commandExit(output);
			const count = lineCount(output);
			const exitLabel = exit === null ? "exit 0" : `exit ${exit}`;
			let summary = exit !== null && exit !== 0 ? theme.fg("error", exitLabel) : theme.fg("success", exitLabel);
			summary += theme.fg("dim", ` · ${count} line${count === 1 ? "" : "s"}`);
			if (resultTruncated(result)) summary += theme.fg("warning", " · truncated");
			const mode = bashOutputMode(effectiveCwd);
			if (mode === "hidden") return makeEmpty();
			let text = `${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${summary}`;
			const renderDiffs = shouldRenderBashDiffsForCommand(context?.args ?? {}, effectiveCwd);
			const suppressDiffOutput = output ? suppressReadOnlyBashDiffOutput(context?.args ?? {}, output, effectiveCwd) : false;
			const diffPreview = output && mode !== "summary" ? renderBashDiffOutput(output, theme, expanded, effectiveCwd, renderDiffs) : null;
			if (diffPreview) {
				text += `\n${diffPreview}`;
			} else if (!suppressDiffOutput && mode === "preview" && output) {
				const limit = Math.max(1, Math.floor(settingNumber(expanded ? "bashPreviewLines" : "bashCollapsedLines", expanded ? 80 : 10, effectiveCwd)));
				text += `\n${preview(output, limit, "tail", effectiveCwd)
					.split(/\r?\n/)
					.map((line) => theme.fg("dim", line))
					.join("\n")}`;
				if (count > limit) text += `\n${theme.fg("muted", `… ${count - limit} older line(s)`)}`;
			} else if (!suppressDiffOutput && mode === "opencode" && expanded && output) {
				const limit = Math.max(1, Math.floor(settingNumber("bashPreviewLines", 80, effectiveCwd)));
				text += `\n${preview(output, limit, "tail", effectiveCwd)
					.split(/\r?\n/)
					.map((line) => theme.fg("dim", line))
					.join("\n")}`;
				if (count > limit) text += `\n${theme.fg("muted", `… ${count - limit} older line(s)`)}`;
			} else if (!suppressDiffOutput && mode === "opencode" && liveTailState.tailShown && output) {
				const tailText = renderBashTail(output, bashLiveTailLines(effectiveCwd), theme, effectiveCwd);
				if (tailText) text += `\n${tailText}`;
			}
			return makeTruncatedLines(text);
		},
	});
}

export function registerEdit(pi: ExtensionAPI, agent: any, cwd: string): void {
	const original = getBuiltInTool(agent, cwd, "edit");
	if (!original) return;
	pi.registerTool({
		renderShell: "self",
		name: "edit",
		label: "edit",
		description: original.description,
		parameters: original.parameters,
		async execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, context: any) {
			const effectiveCwd = contextCwd(context, cwd);
			const targetPath = params?.path ?? params?.file_path;
			const before = readTextForDiff(targetPath, effectiveCwd);
			const result = await getBuiltInTool(agent, effectiveCwd, "edit").execute(id, params, signal, onUpdate);
			const after = result?.isError ? before : readTextForDiff(targetPath, effectiveCwd);
			return attachDiffDetails(result, before, after, typeof targetPath === "string" ? targetPath : undefined);
		},
		renderCall(args: any, theme: any, context: any) {
			const effectiveCwd = context?.cwd ?? cwd;
			const targetPath = args?.path ?? args?.file_path ?? "";
			if (context?.argsComplete) {
				const diffs = editOperationsFromArgs(args).map((edit) => ({ ...buildStructuredDiff(edit.oldText, edit.newText), path: targetPath }));
				const previewComponent = renderMutationCallPreview("Edit", String(targetPath), diffs, theme, context, effectiveCwd);
				if (componentHasVisibleLines(previewComponent)) return previewComponent;
			}
			return renderPendingCall(`${toolLabel(theme, "Edit ")}${renderToolPathText(targetPath, theme, effectiveCwd)}`, theme, context, cwd);
		},
		renderResult(result: any, { expanded, isPartial }: any, theme: any, context: any) {
			const args = context?.args ?? {};
			const targetPath = args.path ?? args.file_path ?? "";
			const call = `${toolLabel(theme, "Edit ")}${renderToolPathText(targetPath, theme, context?.cwd ?? cwd)}`;
			if (isPartial) return renderPendingDetail("editing…", theme);
			clearBlink(context);
			const structured = result?.details?.vstackDiff as StructuredDiff | undefined;
			if (context?.isError || result?.isError) {
				const errorText = textContent(result).split(/\r?\n/)[0] || "edit failed";
				return makeTruncatedLines(`${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${theme.fg("error", errorText)}`);
			}
			const summary = structured ? diffSummary(structured, theme, context?.cwd ?? cwd) : theme.fg("success", "applied");
			let text = `${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${summary}`;
			if (structured) text += `\n${renderStructuredDiff(structured, theme, expanded, context?.cwd ?? cwd, undefined, targetPath)}`;
			return makeTruncatedLines(text);
		},
	});
}

export function registerWrite(pi: ExtensionAPI, agent: any, cwd: string): void {
	const original = getBuiltInTool(agent, cwd, "write");
	if (!original) return;
	pi.registerTool({
		renderShell: "self",
		name: "write",
		label: "write",
		description: original.description,
		parameters: original.parameters,
		async execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, context: any) {
			const effectiveCwd = contextCwd(context, cwd);
			const targetPath = params?.path ?? params?.file_path;
			const before = readTextForDiff(targetPath, effectiveCwd);
			const result = await getBuiltInTool(agent, effectiveCwd, "write").execute(id, params, signal, onUpdate);
			const after = result?.isError ? before : typeof params?.content === "string" ? params.content : readTextForDiff(targetPath, effectiveCwd);
			return attachDiffDetails(result, before, after, typeof targetPath === "string" ? targetPath : undefined);
		},
		renderCall(args: any, theme: any, context: any) {
			const effectiveCwd = context?.cwd ?? cwd;
			const targetPath = args?.path ?? args?.file_path ?? "";
			const lineTotal = lineCount(args?.content ?? "");
			if (context?.argsComplete && typeof args?.content === "string") {
				const before = existingSmallTextOrUndefined(String(targetPath), effectiveCwd);
				const label: "Write" | "Create" = before === undefined ? "Create" : "Write";
				const diff = { ...buildStructuredDiff(before ?? "", args.content), path: String(targetPath) };
				const previewComponent = renderMutationCallPreview(label, String(targetPath), [diff], theme, context, effectiveCwd);
				if (componentHasVisibleLines(previewComponent)) return previewComponent;
			}
			return renderPendingCall(`${toolLabel(theme, "Write ")}${renderToolPathText(targetPath, theme, effectiveCwd)} ${theme.fg("dim", `· ${lineTotal} lines`)}`, theme, context, cwd);
		},
		renderResult(result: any, { expanded, isPartial }: any, theme: any, context: any) {
			const args = context?.args ?? {};
			const targetPath = args.path ?? args.file_path ?? "";
			const lineTotal = lineCount(args.content ?? "");
			const label = result?.details?.vstackDiffWasNewFile ? "Create " : "Write ";
			const call = `${toolLabel(theme, label)}${renderToolPathText(targetPath, theme, context?.cwd ?? cwd)} ${theme.fg("dim", `· ${lineTotal} lines`)}`;
			if (isPartial) return renderPendingDetail("writing…", theme);
			clearBlink(context);
			const structured = result?.details?.vstackDiff as StructuredDiff | undefined;
			if (context?.isError || result?.isError) {
				const errorText = textContent(result).split(/\r?\n/)[0] || "write failed";
				return makeTruncatedLines(`${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${theme.fg("error", errorText)}`);
			}
			const summary = structured ? diffSummary(structured, theme, context?.cwd ?? cwd) : theme.fg("success", "written");
			let text = `${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${summary}`;
			if (structured) text += `\n${renderStructuredDiff(structured, theme, expanded, context?.cwd ?? cwd, undefined, targetPath)}`;
			return makeTruncatedLines(text);
		},
	});
}

export function registerReadOnly(pi: ExtensionAPI, agent: any, cwd: string, toolName: "grep" | "find" | "ls"): void {
	const original = getBuiltInTool(agent, cwd, toolName);
	if (!original) return;
	pi.registerTool({
		renderShell: "self",
		name: toolName,
		label: toolName,
		description: original.description,
		parameters: original.parameters,
		async execute(id: string, params: any, signal: AbortSignal | undefined, onUpdate: unknown, context: any) {
			return getBuiltInTool(agent, contextCwd(context, cwd), toolName).execute(id, params, signal, onUpdate);
		},
		renderCall(args: any, theme: any, context: any) {
			return renderPendingCall(readOnlyCallText(toolName, args ?? {}, theme, context?.cwd ?? cwd), theme, context, cwd);
		},
		renderResult(result: any, { expanded, isPartial }: any, theme: any, context: any) {
			const stacked = stackToolCalls(context?.cwd ?? cwd);
			if (stacked) return renderStackedToolResult(toolName, result, isPartial, expanded, theme, context, cwd);
			const call = readOnlyCallText(toolName, context?.args ?? {}, theme, context?.cwd ?? cwd);
			if (isPartial) return renderPendingDetail(`${toolName}…`, theme);
			clearBlink(context);
			const output = textContent(result);
			const count = output.trim() ? lineCount(output) : 0;
			const label = toolName === "grep"
				? `${count} match${count === 1 ? "" : "es"}`
				: toolName === "ls"
					? `${count} entr${count === 1 ? "y" : "ies"}`
					: `${count} file${count === 1 ? "" : "s"}`;
			let summary = count === 0 ? theme.fg("muted", toolName === "grep" ? "no matches" : toolName === "ls" ? "empty" : "no files") : theme.fg("success", label);
			if (resultTruncated(result)) summary += theme.fg("warning", " · truncated");
			const mode = searchOutputMode(context?.cwd ?? cwd);
			if (mode === "hidden") return makeEmpty();
			let text = `${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${summary}`;
			if (mode === "preview" && expanded && output) {
				if (toolName === "find" || toolName === "ls") {
					text += `\n${renderPathListPreview(output, toolName, theme, expanded, context?.cwd)}`;
				} else {
					const limit = Math.max(1, Math.floor(settingNumber("searchPreviewLines", 80, context?.cwd)));
					text += `\n${preview(output, limit, "head", context?.cwd)
						.split(/\r?\n/)
						.map((line) => `${treeConnector(theme, "│")}${theme.fg("dim", line)}`)
						.join("\n")}`;
					if (count > limit) text += `\n${treeConnector(theme, "│")}${theme.fg("muted", `… ${count - limit} more result line(s)`)}`;
				}
			}
			return makeTruncatedLines(text);
		},
	});
}

