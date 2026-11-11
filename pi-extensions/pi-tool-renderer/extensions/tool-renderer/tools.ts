import type { ExtensionAPI, ToolRenderers } from "@earendil-works/pi-coding-agent";

import {
	attachDiffDetails,
	attachPatchDetails,
	buildStructuredDiff,
	diffSummary,
	editOperationsFromArgs,
	readDiffSnapshot,
	renderBashDiffOutput,
	renderMutationCallPreview,
	renderStructuredDiff,
	shouldRenderBashDiffsForCommand,
	suppressReadOnlyBashDiffOutput,
	textSnapshot,
	type DiffSnapshot,
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
	holdUntilFinalRender,
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
	splitTerminalLines,
	textContent,
} from "./text.js";
import { renderStackedToolResult, STACK_MAX_ITEMS } from "./stack.js";

export function contextCwd(context: any, fallback: string): string {
	return context?.cwd ?? fallback;
}

/** Pi awaits tool_call before execution. Keep only the old bytes needed to
 *  draw in-flight writes, within the existing display count and file limits. */
export function registerWriteDiffEvents(pi: ExtensionAPI): void {
	const pending = new Map<string, { path: string; snapshot?: DiffSnapshot }>();
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "write" || !ctx.hasUI || pending.size >= STACK_MAX_ITEMS) return;
		const input = event.input as Record<string, unknown>;
		const path = input.path ?? input.file_path;
		if (typeof path !== "string" || typeof input.content !== "string") return;
		const record: { path: string; snapshot?: DiffSnapshot } = { path };
		pending.set(event.toolCallId, record);
		const snapshot = await readDiffSnapshot(path, ctx.cwd);
		// A lifecycle reset during the read must not restore an old call's state.
		if (pending.get(event.toolCallId) === record) record.snapshot = snapshot;
	});
	pi.on("tool_result", (event) => {
		const record = pending.get(event.toolCallId);
		pending.delete(event.toolCallId);
		if (event.toolName !== "write" || event.isError || !record?.snapshot) return;
		if (event.details !== undefined && (event.details === null || typeof event.details !== "object" || Array.isArray(event.details))) return;
		const path = event.input.path ?? event.input.file_path;
		// A later handler can change arguments. Never diff a different target's old bytes.
		if (path !== record.path || typeof event.input.content !== "string") return;
		const result = attachDiffDetails({ details: event.details }, record.snapshot, textSnapshot(event.input.content), record.path);
		return { details: result.details };
	});
	pi.on("tool_execution_end", (event) => { pending.delete(event.toolCallId); });
	const clear = () => pending.clear();
	pi.on("agent_end", clear);
	pi.on("session_start", clear);
	pi.on("session_shutdown", clear);
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
	if (!record.kendexBashLiveTail || typeof record.kendexBashLiveTail !== "object") record.kendexBashLiveTail = {};
	return record.kendexBashLiveTail as BashLiveTailState;
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
	const tailLines = splitTerminalLines(preview(trimmed, limit, "tail", cwd));
	return tailLines.map((line) => theme.fg("dim", line)).join("\n");
}

function diffSkippedNote(reason: string, theme: any): string {
	return theme.fg("warning", ` · diff skipped: ${reason}`);
}

interface WriteCallSnapshot {
	path: string;
	snapshot?: DiffSnapshot;
}

/** The written file as it stood before the call, read once per path into the
 *  row's renderer state off the render path; undefined until the read settles,
 *  which redraws the row. The row drops it at its final render or when the
 *  agent run ends without one, so a session's rows hold no file text. */
function writeCallSnapshot(context: any, targetPath: string, cwd: string): DiffSnapshot | undefined {
	const state = context?.state;
	if (!state || typeof state !== "object") return undefined;
	const record = state as Record<string, unknown>;
	if (context.executionStarted && !context.isPartial) {
		delete record.kendexWriteSnapshot;
		return undefined;
	}
	const current = record.kendexWriteSnapshot as WriteCallSnapshot | undefined;
	if (current?.path === targetPath) return current.snapshot;
	const next: WriteCallSnapshot = { path: targetPath };
	const release = () => {
		if (record.kendexWriteSnapshot === next) delete record.kendexWriteSnapshot;
	};
	if (!holdUntilFinalRender(context, release)) return undefined;
	record.kendexWriteSnapshot = next;
	void readDiffSnapshot(targetPath, cwd).then((snapshot) => {
		if (record.kendexWriteSnapshot !== next) return;
		next.snapshot = snapshot;
		try {
			context.invalidate?.();
		} catch {
			// Best-effort redraw only; the row draws the preview on its next render.
		}
	});
	return undefined;
}

export function createReadRenderers(cwd: string): ToolRenderers {
	return {
		renderShell: "self",
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
				text += `\n${splitTerminalLines(preview(content, limit, "head", context?.cwd))
					.map((line) => `${treeConnector(theme, "│")}${theme.fg("dim", line)}`)
					.join("\n")}`;
				if (count > limit) text += `\n${treeConnector(theme, "│")}${theme.fg("muted", `… ${count - limit} more line(s)`)}`;
			}
			return renderReadImages(makeTruncatedLines(text), result, expanded, theme, context, cwd);
		},
	};
}

export function createBashRenderers(cwd: string): ToolRenderers {
	return {
		renderShell: "self",
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
			const failed = Boolean(context?.isError || result?.isError);
			const exit = failed ? commandExit(output) : 0;
			const count = lineCount(output);
			const exitLabel = exit === null ? "failed" : `exit ${exit}`;
			let summary = theme.fg(failed ? "error" : "success", exitLabel);
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
				text += `\n${splitTerminalLines(preview(output, limit, "tail", effectiveCwd))
					.map((line) => theme.fg("dim", line))
					.join("\n")}`;
				if (count > limit) text += `\n${theme.fg("muted", `… ${count - limit} older line(s)`)}`;
			} else if (!suppressDiffOutput && mode === "opencode" && expanded && output) {
				const limit = Math.max(1, Math.floor(settingNumber("bashPreviewLines", 80, effectiveCwd)));
				text += `\n${splitTerminalLines(preview(output, limit, "tail", effectiveCwd))
					.map((line) => theme.fg("dim", line))
					.join("\n")}`;
				if (count > limit) text += `\n${theme.fg("muted", `… ${count - limit} older line(s)`)}`;
			} else if (!suppressDiffOutput && mode === "opencode" && liveTailState.tailShown && output) {
				const tailText = renderBashTail(output, bashLiveTailLines(effectiveCwd), theme, effectiveCwd);
				if (tailText) text += `\n${tailText}`;
			}
			return makeTruncatedLines(text);
		},
	};
}

export function createEditRenderers(cwd: string): ToolRenderers {
	return {
		renderShell: "self",
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
			result = attachPatchDetails({ ...result }, targetPath);
			clearBlink(context);
			const structured = result?.details?.kendexDiff as StructuredDiff | undefined;
			if (context?.isError || result?.isError) {
				const errorText = splitTerminalLines(textContent(result))[0] || "edit failed";
				return makeTruncatedLines(`${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${theme.fg("error", errorText)}`);
			}
			const skipped = result?.details?.kendexDiffSkipped;
			const summary = structured ? diffSummary(structured, theme, context?.cwd ?? cwd) : theme.fg("success", "applied") + (typeof skipped === "string" ? diffSkippedNote(skipped, theme) : "");
			let text = `${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${summary}`;
			if (structured) text += `\n${renderStructuredDiff(structured, theme, expanded, context?.cwd ?? cwd, undefined, targetPath)}`;
			return makeTruncatedLines(text);
		},
	};
}

export function createWriteRenderers(cwd: string): ToolRenderers {
	return {
		renderShell: "self",
		renderCall(args: any, theme: any, context: any) {
			const effectiveCwd = context?.cwd ?? cwd;
			const targetPath = args?.path ?? args?.file_path ?? "";
			const lineTotal = lineCount(args?.content ?? "");
			let skipNote = "";
			if (context?.argsComplete && typeof args?.content === "string") {
				const before = writeCallSnapshot(context, String(targetPath), effectiveCwd);
				const after = textSnapshot(args.content);
				const skipped = before?.kind === "skipped" ? before : after.kind === "skipped" ? after : undefined;
				if (skipped) skipNote = diffSkippedNote(skipped.reason, theme);
				else if (before && after.kind === "text") {
					const label: "Write" | "Create" = before.kind === "absent" ? "Create" : "Write";
					const diff = { ...buildStructuredDiff(before.kind === "text" ? before.text : "", after.text), path: String(targetPath) };
					const previewComponent = renderMutationCallPreview(label, String(targetPath), [diff], theme, context, effectiveCwd);
					if (componentHasVisibleLines(previewComponent)) return previewComponent;
				}
			}
			return renderPendingCall(`${toolLabel(theme, "Write ")}${renderToolPathText(targetPath, theme, effectiveCwd)} ${theme.fg("dim", `· ${lineTotal} lines`)}${skipNote}`, theme, context, cwd);
		},
		renderResult(result: any, { expanded, isPartial }: any, theme: any, context: any) {
			const args = context?.args ?? {};
			const targetPath = args.path ?? args.file_path ?? "";
			const lineTotal = lineCount(args.content ?? "");
			const label = result?.details?.kendexDiffWasNewFile ? "Create " : "Write ";
			const call = `${toolLabel(theme, label)}${renderToolPathText(targetPath, theme, context?.cwd ?? cwd)} ${theme.fg("dim", `· ${lineTotal} lines`)}`;
			if (isPartial) return renderPendingDetail("writing…", theme);
			clearBlink(context);
			const structured = result?.details?.kendexDiff as StructuredDiff | undefined;
			if (context?.isError || result?.isError) {
				const errorText = splitTerminalLines(textContent(result))[0] || "write failed";
				return makeTruncatedLines(`${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${theme.fg("error", errorText)}`);
			}
			const skipped = result?.details?.kendexDiffSkipped;
			const summary = structured ? diffSummary(structured, theme, context?.cwd ?? cwd) : theme.fg("success", "written") + (typeof skipped === "string" ? diffSkippedNote(skipped, theme) : "");
			let text = `${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${summary}`;
			if (structured) text += `\n${renderStructuredDiff(structured, theme, expanded, context?.cwd ?? cwd, undefined, targetPath)}`;
			return makeTruncatedLines(text);
		},
	};
}

export function createReadOnlyRenderers(cwd: string, toolName: "grep" | "find" | "ls"): ToolRenderers {
	return {
		renderShell: "self",
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
					text += `\n${splitTerminalLines(preview(output, limit, "head", context?.cwd))
						.map((line) => `${treeConnector(theme, "│")}${theme.fg("dim", line)}`)
						.join("\n")}`;
					if (count > limit) text += `\n${treeConnector(theme, "│")}${theme.fg("muted", `… ${count - limit} more result line(s)`)}`;
				}
			}
			return makeTruncatedLines(text);
		},
	};
}

