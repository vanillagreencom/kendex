import {
	assignHunkNumbers,
	buildStructuredDiff,
	countStructuredHunks,
	diffSummary,
	hiddenDiffLine,
	renderStructuredDiff,
	summarizeDiffs,
	type StructuredDiff,
	type StructuredDiffLine,
} from "./diff.js";
import { mcpOutputMode, settingBoolean, settingNumber } from "./settings.js";
import { glyphs, truncateText } from "./glyphs.js";
import { stackPrefix, toolLabel, treeConnector, treeStem } from "./theme.js";
import {
	clearBlink,
	clipLine,
	makeEmpty,
	makeTruncatedLines,
	pendingStatusPrefix,
	renderPendingDetail,
	textContent,
	type TruncatedLines,
} from "./text.js";

export const CORE_TOOL_RENDERERS = new Set(["read", "bash", "grep", "find", "ls", "edit", "write", "tool_batch", "tasks_write", "bg_task", "bg_status", "question", "subagent"]);
export const OPENAI_STYLE_TOOL_NAMES = new Set([
	"webfetch",
	"web_fetch",
	"web_search",
	"fetch_content",
	"get_search_content",
	"code_search",
	"context_tag",
	"context_log",
	"context_checkout",
	"annotate",
	"Skill",
	"EnterPlanMode",
	"ExitPlanMode",
	"Agent",
	"get_subagent_result",
	"steer_subagent",
	"TaskCreate",
	"TaskList",
	"TaskGet",
	"TaskUpdate",
	"TaskOutput",
	"TaskStop",
	"TaskExecute",
]);

export function isMcpToolName(name: string): boolean {
	return name === "mcp" || name.startsWith("mcp__") || name.startsWith("mcp_") || /(^|[_-])mcp([_-]|$)/i.test(name);
}

export function shouldUseGenericRenderer(name: string): boolean {
	if (!name || CORE_TOOL_RENDERERS.has(name) || name === "apply_patch") return false;
	if (isMcpToolName(name)) return true;
	if (OPENAI_STYLE_TOOL_NAMES.has(name)) return true;
	return /^Task[A-Z]/.test(name);
}

export function isUnknownToolComponent(component: any): boolean {
	return component?.toolDefinition === undefined && component?.builtInToolDefinition === undefined;
}

export function shouldUseUnknownToolRenderer(component: any, name: string): boolean {
	return Boolean(name) && settingBoolean("genericToolRenderers", true) && isUnknownToolComponent(component);
}

export function componentDefinesRenderer(component: any, slot: "renderCall" | "renderResult"): boolean {
	for (const key of ["tool", "toolDefinition", "definition", "toolDef", "toolConfig"]) {
		const candidate = component?.[key];
		if (candidate && typeof candidate[slot] === "function") return true;
	}
	return false;
}

export function humanizeToolName(name: string): string {
	return name
		.replace(/([a-z0-9])([A-Z])/g, "$1 $2")
		.replace(/[_-]+/g, " ")
		.replace(/\b\w/g, (char) => char.toUpperCase());
}

export function oneLine(value: string, max = 72, cwd?: string): string {
	const normalized = value.replace(/\s+/g, " ").trim();
	return truncateText(normalized, max, cwd);
}

function stringArg(args: any, ...keys: string[]): string {
	for (const key of keys) {
		const value = args?.[key];
		if (typeof value === "string" && value.trim()) return value.trim();
	}
	return "";
}

function stringArrayArg(args: any, ...keys: string[]): string[] {
	for (const key of keys) {
		const value = args?.[key];
		if (!Array.isArray(value)) continue;
		const strings = value.filter((item): item is string => typeof item === "string" && item.trim().length > 0);
		if (strings.length > 0) return strings;
	}
	return [];
}

export function genericStatusPrefix(context: any, theme: any): string {
	if (!context?.executionStarted || context?.isPartial) return pendingStatusPrefix(theme, context);
	clearBlink(context);
	return theme.fg(context?.isError ? "error" : "success", glyphs(context?.cwd).bullet);
}

function patchTextFromArgs(args: any): string {
	return stringArg(args, "patch", "patchText", "patch_text", "input");
}

function extractApplyPatchFiles(patchText: string): string[] {
	const files = new Set<string>();
	for (const match of patchText.matchAll(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/gm)) {
		const file = match[1]?.trim();
		if (file) files.add(file);
	}
	return [...files];
}

function parsePatchBodyLine(rawLine: string): { content: string; marker: "+" | "-" | " " } {
	const marker = rawLine[0];
	if (marker === "+" || marker === "-" || marker === " ") return { content: rawLine.slice(1), marker };
	return { content: rawLine, marker: " " };
}

function parseApplyPatchUpdateDiff(lines: string[]): StructuredDiff {
	const diffLines: StructuredDiffLine[] = [];
	let additions = 0;
	let removals = 0;
	let chars = 0;
	let oldLine: number | null = null;
	let newLine: number | null = null;
	let hunk = 0;
	let inHunk = false;
	for (const rawLine of lines) {
		if (rawLine.startsWith("*** Move to: ")) continue;
		const header = rawLine.match(/^@@\s*-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s*@@/);
		if (rawLine.startsWith("@@")) {
			if (diffLines.length > 0 && diffLines[diffLines.length - 1]?.type !== "sep") diffLines.push(hiddenDiffLine(0));
			oldLine = header ? Number.parseInt(header[1]!, 10) : (oldLine ?? 1);
			newLine = header ? Number.parseInt(header[2]!, 10) : (newLine ?? 1);
			hunk++;
			inHunk = true;
			continue;
		}
		if (rawLine === "\\ No newline at end of file") continue;
		if (!inHunk) {
			hunk++;
			oldLine = oldLine ?? 1;
			newLine = newLine ?? 1;
			inHunk = true;
		}
		const { content, marker } = parsePatchBodyLine(rawLine);
		chars += content.length;
		if (marker === "+") {
			diffLines.push({ content, hunk, newNum: newLine, oldNum: null, type: "add" });
			additions++;
			if (newLine !== null) newLine++;
		} else if (marker === "-") {
			diffLines.push({ content, hunk, newNum: null, oldNum: oldLine, type: "del" });
			removals++;
			if (oldLine !== null) oldLine++;
		} else {
			diffLines.push({ content, hunk, newNum: newLine, oldNum: oldLine, type: "ctx" });
			if (oldLine !== null) oldLine++;
			if (newLine !== null) newLine++;
		}
	}
	const numbered = assignHunkNumbers(diffLines);
	return { additions, chars, hunks: Math.max(hunk, numbered.hunks), lines: numbered.lines, removals };
}

interface ApplyPatchChange {
	diff: StructuredDiff;
	displayPath: string;
	kind: "add" | "update" | "delete";
	line: number;
	moveTo?: string;
	path: string;
}

function firstChangedLine(diff: StructuredDiff): number {
	for (const line of diff.lines) {
		if (line.type === "add" && line.newNum !== null) return line.newNum;
		if (line.type === "del" && line.oldNum !== null) return line.oldNum;
	}
	return 0;
}

function parseApplyPatchPreview(patchText: string): ApplyPatchChange[] {
	const lines = patchText.replace(/\r\n/g, "\n").split("\n");
	const changes: ApplyPatchChange[] = [];
	const fileHeader = /^\*\*\* (Add|Update|Delete) File: (.+)$/;
	let index = 0;
	while (index < lines.length) {
		const header = lines[index]?.match(fileHeader);
		if (!header) {
			index++;
			continue;
		}
		const kind = header[1]!.toLowerCase() as ApplyPatchChange["kind"];
		const path = header[2]!.trim();
		index++;
		let moveTo: string | undefined;
		const body: string[] = [];
		while (index < lines.length && !fileHeader.test(lines[index] ?? "") && !/^\*\*\* End Patch$/.test(lines[index] ?? "")) {
			const line = lines[index] ?? "";
			if (line.startsWith("*** Move to: ")) moveTo = line.slice("*** Move to: ".length).trim();
			else body.push(line);
			index++;
		}
		const diff = kind === "add"
			? buildStructuredDiff("", body.map((line) => line.startsWith("+") ? line.slice(1) : line).join("\n"))
			: kind === "delete"
				? buildStructuredDiff(body.map((line) => line.startsWith("-") ? line.slice(1) : line).join("\n"), "")
				: parseApplyPatchUpdateDiff(body);
		diff.path = moveTo || path;
		changes.push({ diff, displayPath: moveTo ? `${path} ${glyphs().arrow} ${moveTo}` : path, kind, line: firstChangedLine(diff), moveTo, path });
	}
	return changes;
}

function summarizeApplyPatchChanges(changes: ApplyPatchChange[]): StructuredDiff {
	return summarizeDiffs(changes.map((change) => change.diff));
}

function applyPatchChangeLabel(change: ApplyPatchChange): string {
	if (change.moveTo) return `Rename ${change.displayPath}`;
	if (change.kind === "add") return `Create ${change.displayPath}`;
	if (change.kind === "delete") return `Delete ${change.displayPath}`;
	return `Update ${change.displayPath}`;
}

function applyPatchSummaryTarget(changes: ApplyPatchChange[], theme: any): string {
	if (changes.length === 0) return theme.fg("muted", "patch");
	if (changes.length > 1) return theme.fg("muted", `${changes.length} files changed`);
	const first = changes[0]!;
	const firstPath = first.moveTo || first.path;
	return theme.fg("accent", firstPath);
}

function applyPatchKindLabel(changes: ApplyPatchChange[]): string {
	if (changes.length !== 1) return "Apply Patch ";
	const change = changes[0]!;
	if (change.moveTo) return "Rename ";
	if (change.kind === "add") return "Create ";
	if (change.kind === "delete") return "Delete ";
	return "Update ";
}

function applyPatchChangeStatus(change: ApplyPatchChange): string {
	if (change.moveTo) return "renamed";
	if (change.kind === "add") return "created";
	if (change.kind === "delete") return "deleted";
	return "applied";
}

function applyPatchResultSummary(changes: ApplyPatchChange[], total: StructuredDiff, theme: any, cwd?: string): string {
	if (total.additions > 0 || total.removals > 0) return diffSummary(total, theme, cwd);
	return theme.fg("success", changes.length === 1 ? applyPatchChangeStatus(changes[0]!) : "applied");
}

function applyPatchChangesFromContext(context: any): ApplyPatchChange[] {
	if (Array.isArray(context?.state?._vstackApplyPatchChanges)) return context.state._vstackApplyPatchChanges as ApplyPatchChange[];
	try {
		return parseApplyPatchPreview(patchTextFromArgs(context?.args ?? {}));
	} catch {
		return [];
	}
}

export function renderApplyPatchCall(args: any, theme: any, context: any): TruncatedLines | ReturnType<typeof makeEmpty> {
	if (context?.executionStarted) return makeEmpty();
	const patchText = patchTextFromArgs(args);
	let changes: ApplyPatchChange[] = [];
	if (patchText) {
		try {
			changes = parseApplyPatchPreview(patchText);
			if (context?.argsComplete && context?.state) context.state._vstackApplyPatchChanges = changes;
		} catch {
			// Leave compact pending header only if patch cannot be parsed.
		}
	}
	const files = changes.length > 0 ? changes.map((change) => change.moveTo || change.path) : extractApplyPatchFiles(patchText);
	const multiFile = changes.length > 1 || files.length > 1;
	const summary = multiFile ? theme.fg("muted", `${Math.max(changes.length, files.length)} files changed`) : theme.fg("muted", "patch");
	const total = changes.length > 1 ? `${theme.fg("dim", " · ")}${diffSummary(summarizeApplyPatchChanges(changes), theme, context?.cwd)}` : "";
	return makeTruncatedLines(`${genericStatusPrefix(context, theme)}${toolLabel(theme, "Apply Patch ")}${summary}${total}`);
}

export function renderApplyPatchResult(result: any, { expanded, isPartial }: any, theme: any, context: any): TruncatedLines | ReturnType<typeof makeEmpty> {
	if (isPartial) return makeEmpty();
	clearBlink(context);
	const changes = applyPatchChangesFromContext(context);
	const target = applyPatchSummaryTarget(changes, theme);
	const call = `${toolLabel(theme, applyPatchKindLabel(changes))}${target}`;
	if (context?.isError) {
		const first = textContent(result).split(/\r?\n/)[0] || "apply_patch failed";
		return makeTruncatedLines(`${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${theme.fg("error", first)}`);
	}
	if (changes.length === 0) return makeTruncatedLines(`${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${theme.fg("success", "applied")}`);
	const total = summarizeApplyPatchChanges(changes);
	let text = `${stackPrefix(theme)}${call}${theme.fg("dim", " · ")}${applyPatchResultSummary(changes, total, theme, context?.cwd)}`;
	const maxShown = expanded ? changes.length : Math.min(1, changes.length);
	const hidden = changes.length - maxShown;
	const rowLimit = maxShown > 1 ? Math.max(4, Math.floor(settingNumber("applyPatchPreviewLines", 18, context?.cwd) / Math.max(1, maxShown))) : undefined;
	for (let i = 0; i < maxShown; i++) {
		const change = changes[i]!;
		const changed = change.diff.additions > 0 || change.diff.removals > 0;
		const connector = changes.length > 1 ? treeConnector(theme, i === maxShown - 1 && hidden === 0 ? "└" : "├", context?.cwd) : "";
		if (!changed) {
			if (changes.length > 1) text += `\n${connector}${theme.fg("accent", applyPatchChangeLabel(change))} ${theme.fg("success", applyPatchChangeStatus(change))}`;
			continue;
		}
		if (changes.length > 1) text += `\n${connector}${theme.fg("accent", applyPatchChangeLabel(change))} ${diffSummary(change.diff, theme, context?.cwd)}`;
		text += `\n${renderStructuredDiff(change.diff, theme, expanded, context?.cwd, rowLimit, change.diff.path)}`;
	}
	if (hidden > 0) text += `\n${treeConnector(theme, "└", context?.cwd)}${theme.fg("muted", `… ${hidden} more file patch${hidden === 1 ? "" : "es"} · ctrl+o to expand`)}`;
	return makeTruncatedLines(text);
}

function formatScheduleWakeupDelay(value: unknown): string {
	const seconds = typeof value === "number" ? value : typeof value === "string" && value.trim() ? Number(value) : Number.NaN;
	if (!Number.isFinite(seconds) || seconds <= 0) return "later";
	if (seconds < 60) return `${Math.round(seconds)}s`;
	const minutes = seconds / 60;
	if (minutes < 60) return `${Number.isInteger(minutes) ? minutes : minutes.toFixed(1)}m`;
	const hours = minutes / 60;
	return `${Number.isInteger(hours) ? hours : hours.toFixed(1)}h`;
}

function summarizeScheduleWakeupCall(args: any, theme: any): string {
	const delay = formatScheduleWakeupDelay(args?.delaySeconds ?? args?.delay_seconds ?? args?.delay ?? args?.seconds);
	const reason = stringArg(args, "reason", "prompt", "description") || "scheduled wakeup";
	return `${theme.fg("accent", delay)}${theme.fg("dim", " · ")}${theme.fg("muted", oneLine(reason, 56))}`;
}

function summarizeGenericCall(name: string, args: any, theme: any): string {
	if (isMcpToolName(name)) {
		const parts = name.split("__").filter(Boolean);
		const label = parts.length >= 2 ? `${parts[0]}/${parts.slice(1).join("/")}` : humanizeToolName(name);
		const arg = stringArg(args, "path", "file_path", "query", "url", "name", "prompt", "description");
		return arg ? `${theme.fg("accent", label)} ${theme.fg("muted", oneLine(arg, 48))}` : theme.fg("accent", label);
	}
	switch (name) {
		case "webfetch":
		case "web_fetch":
		case "fetch_content": {
			const url = stringArg(args, "url") || stringArrayArg(args, "urls")[0] || "fetch";
			return theme.fg("accent", oneLine(url, 72));
		}
		case "web_search":
		case "code_search": return theme.fg("accent", oneLine(stringArg(args, "query") || stringArrayArg(args, "queries")[0] || "search", 72));
		case "Agent": return theme.fg("accent", oneLine(stringArg(args, "description", "prompt") || "launch agent", 72));
		case "TaskCreate": return theme.fg("accent", oneLine(stringArg(args, "subject", "description") || "create task", 72));
		case "TaskGet":
		case "TaskUpdate":
		case "TaskOutput":
		case "TaskStop": return theme.fg("accent", stringArg(args, "taskId", "task_id") || "task");
		case "TaskList": return theme.fg("muted", "task list");
		case "TaskExecute": {
			const ids = stringArrayArg(args, "taskIds", "task_ids");
			return ids.length <= 1 ? theme.fg("accent", ids[0] ?? "start tasks") : `${theme.fg("accent", ids[0]!)}${theme.fg("muted", ` +${ids.length - 1} tasks`)}`;
		}
		case "ScheduleWakeup": return summarizeScheduleWakeupCall(args, theme);
		default: return theme.fg("accent", oneLine(stringArg(args, "path", "file_path", "url", "query", "name", "subject", "tool", "description", "prompt") || humanizeToolName(name), 72));
	}
}

export function renderGenericToolCall(name: string, args: any, theme: any, context: any): TruncatedLines {
	return makeTruncatedLines(`${genericStatusPrefix(context, theme)}${toolLabel(theme, `${humanizeToolName(name)} `)}${summarizeGenericCall(name, args, theme)}`);
}

function summarizeUnknownToolCall(name: string, args: any, theme: any): string {
	if (name === "ScheduleWakeup") return summarizeScheduleWakeupCall(args, theme);
	return summarizeGenericCall(name, args, theme);
}

function unknownToolStatus(name: string, raw: string, isError: boolean, theme: any): string {
	if (!isError) return theme.fg("success", "done");
	const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	if (/not found/i.test(raw) || new RegExp(`\\b${escapedName}\\b.*not found`, "i").test(raw)) return theme.fg("error", "x not found");
	return theme.fg("error", "x error");
}

export function renderUnknownToolCall(name: string, args: any, theme: any, context: any): TruncatedLines | ReturnType<typeof makeEmpty> {
	if (context?.executionStarted) return makeEmpty();
	return makeTruncatedLines(`${genericStatusPrefix(context, theme)}${toolLabel(theme, `${humanizeToolName(name)} `)}${summarizeUnknownToolCall(name, args, theme)}`);
}

export function renderUnknownToolResult(name: string, result: any, { expanded, isPartial }: any, theme: any, context: any): TruncatedLines | ReturnType<typeof makeEmpty> {
	if (isPartial) return makeEmpty();
	clearBlink(context);
	const raw = textContent(result).trim();
	const args = context?.args ?? {};
	const status = unknownToolStatus(name, raw, Boolean(context?.isError), theme);
	let text = `${stackPrefix(theme)}${toolLabel(theme, `${humanizeToolName(name)} `)}${summarizeUnknownToolCall(name, args, theme)}${theme.fg("dim", " · ")}${status}`;
	if (!expanded) return makeTruncatedLines(`${text}${theme.fg("dim", " · ctrl+o to expand")}`);
	const json = JSON.stringify(args, null, 2).split(/\r?\n/);
	text += `\n${treeConnector(theme, raw ? "├" : "└", context?.cwd)}${theme.fg("muted", "args")}`;
	text += `\n${json.map((line) => `${treeStem(theme, raw ? "├" : "└", context?.cwd)}${theme.fg("dim", clipLine(line, context?.cwd))}`).join("\n")}`;
	if (raw) {
		const lines = raw.split(/\r?\n/);
		text += `\n${treeConnector(theme, "└", context?.cwd)}${theme.fg(context?.isError ? "error" : "muted", clipLine(lines[0] ?? raw, context?.cwd))}`;
		for (const line of lines.slice(1, 8)) text += `\n${treeStem(theme, "└", context?.cwd)}${theme.fg("dim", clipLine(line, context?.cwd))}`;
		if (lines.length > 8) text += `\n${treeStem(theme, "└", context?.cwd)}${theme.fg("muted", `… ${lines.length - 8} more line(s)`)}`;
	}
	return makeTruncatedLines(text);
}

export function renderScheduleWakeupCall(args: any, theme: any, context: any): TruncatedLines | ReturnType<typeof makeEmpty> {
	return renderUnknownToolCall("ScheduleWakeup", args, theme, context);
}

export function renderScheduleWakeupResult(result: any, { expanded, isPartial }: any, theme: any, context: any): TruncatedLines | ReturnType<typeof makeEmpty> {
	return renderUnknownToolResult("ScheduleWakeup", result, { expanded, isPartial }, theme, context);
}

export function renderGenericToolResult(name: string, result: any, { expanded, isPartial }: any, theme: any, context: any): TruncatedLines | ReturnType<typeof makeEmpty> {
	if (isPartial) return renderPendingDetail(`${humanizeToolName(name)}…`, theme);
	clearBlink(context);
	const raw = textContent(result).trim();
	const lines = raw ? raw.split(/\r?\n/) : [];
	const mode = isMcpToolName(name) ? mcpOutputMode(context?.cwd) : "preview";
	if (mode === "hidden") return makeEmpty();
	if (context?.isError) {
		const first = lines[0] || `${humanizeToolName(name)} failed`;
		return makeTruncatedLines(`${treeConnector(theme, "└")}${theme.fg("error", first)}`);
	}
	if (lines.length === 0) return makeTruncatedLines(`${treeConnector(theme, "└")}${theme.fg("success", "done")}`);
	if (lines.length === 1) return makeTruncatedLines(`${treeConnector(theme, "└")}${theme.fg("muted", oneLine(lines[0]!, 120))}`);
	let text = `${treeConnector(theme, "└")}${theme.fg("success", `${lines.length} lines returned`)}`;
	if (mode === "preview" && expanded) {
		const limit = Math.max(1, Math.floor(settingNumber(isMcpToolName(name) ? "mcpPreviewLines" : "searchPreviewLines", 80, context?.cwd)));
		text += `\n${lines.slice(0, limit).map((line) => `${treeConnector(theme, "│")}${theme.fg("dim", clipLine(line, context?.cwd))}`).join("\n")}`;
		if (lines.length > limit) text += `\n${treeConnector(theme, "│")}${theme.fg("muted", `… ${lines.length - limit} more line(s)`)}`;
	} else if (mode === "preview") {
		text += theme.fg("dim", " · ctrl+o to expand");
	}
	return makeTruncatedLines(text);
}

