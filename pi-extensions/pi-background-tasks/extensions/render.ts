import type { AgentToolResult, Theme } from "@earendil-works/pi-coding-agent";
import { type Component, truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";

import {
	DASHBOARD_PADDING_X,
	DASHBOARD_PADDING_Y,
	DEFAULT_LOG_TAIL_MAX_CHARS,
	ICONS,
	TOOL_PREVIEW_LINES,
	TOOL_PREVIEW_TASKS,
	VSTACK_MODAL_LOCK_SYMBOL,
	WIDGET_PADDING_X,
	ansiGreen,
} from "./constants.js";
import {
	compactText,
	formatRelativeTime,
	lineCount,
	summarizeTaskStatus,
	tailText,
	takeTailLines,
	taskActivityAt,
	taskDisplayName,
} from "./format.js";
import { latestSnapshot } from "./snapshot.js";
import { frameGlyphs, glyphs, glyphStyle, treeGlyph } from "./glyphs.js";
import { settingEnum, settingNumber } from "./settings.js";
import type {
	BackgroundTaskEventDetails,
	BackgroundTaskSnapshot,
	BackgroundTaskStatus,
	VstackModalLock,
} from "./types.js";

type TreeBranch = "├" | "└" | "│";

export function padAnsi(text: string, width: number): string {
	const truncated = truncateToWidth(text, width, "");
	return `${truncated}${" ".repeat(Math.max(0, width - visibleWidth(truncated)))}`;
}

export function splitOutputLines(output: string): string[] {
	const text = tailText(output, settingNumber("logTailMaxChars", DEFAULT_LOG_TAIL_MAX_CHARS)).trimEnd();
	if (text.length === 0) return ["(no output yet)"];
	const lines = text.split(/\r?\n/);
	const maxLines = Math.max(20, Math.floor(settingNumber("dashboardOutputMaxLines", 800)));
	if (lines.length <= maxLines) return lines;
	return [`${glyphs().ellipsis} ${lines.length - maxLines} older line(s) omitted from dashboard; use bg_task log or the Log file for full output`, ...lines.slice(-maxLines)];
}

export function acquireVstackModalLock(): () => void {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[VSTACK_MODAL_LOCK_SYMBOL] as VstackModalLock | undefined;
	const lock = existing && typeof existing.depth === "number" ? existing : { depth: 0 };
	host[VSTACK_MODAL_LOCK_SYMBOL] = lock;
	lock.depth += 1;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		lock.depth = Math.max(0, lock.depth - 1);
	};
}

export function dashboardContentWidth(width: number): number {
	return Math.max(1, width - 2 - DASHBOARD_PADDING_X * 2);
}

export function frameDashboard(lines: string[], width: number, theme: Theme, title = "", right = "", options: { paddingBottom?: number; paddingTop?: number } = {}): string[] {
	if (width < 8) return lines.map((line) => truncateToWidth(line, width, ""));

	const border = (text: string) => theme.fg("borderAccent", text);
	const frame = frameGlyphs();
	const contentWidth = dashboardContentWidth(width);
	const blank = `${border(frame.v)}${" ".repeat(width - 2)}${border(frame.v)}`;
	const paddingTop = options.paddingTop ?? DASHBOARD_PADDING_Y;
	const paddingBottom = options.paddingBottom ?? DASHBOARD_PADDING_Y;
	const top = () => {
		if (!title) return `${border(frame.tl)}${border(frame.h.repeat(width - 2))}${border(frame.tr)}`;
		const rightPlain = right ? ` ${right} ` : "";
		const titleBudget = Math.max(1, width - 2 - visibleWidth(rightPlain) - 1);
		const titlePlain = ` ${truncateToWidth(title, Math.max(1, titleBudget - 2), glyphs().ellipsis)} `;
		const fill = Math.max(1, width - 2 - visibleWidth(titlePlain) - visibleWidth(rightPlain));
		return `${border(frame.tl)}${ansiGreen(titlePlain)}${border(frame.h.repeat(fill))}${right ? theme.fg("dim", rightPlain) : ""}${border(frame.tr)}`;
	};
	const framed = [top()];

	for (let i = 0; i < paddingTop; i += 1) framed.push(blank);
	for (const line of lines) {
		const content = padAnsi(line, contentWidth);
		framed.push(`${border(frame.v)}${" ".repeat(DASHBOARD_PADDING_X)}${content}${" ".repeat(DASHBOARD_PADDING_X)}${border(frame.v)}`);
	}
	for (let i = 0; i < paddingBottom; i += 1) framed.push(blank);
	framed.push(`${border(frame.bl)}${border(frame.h.repeat(width - 2))}${border(frame.br)}`);
	return framed.map((line) => truncateToWidth(line, width, ""));
}

export function frameWidget(lines: string[], width: number, theme: Theme): string[] {
	const safeWidth = Math.max(1, width);
	if (safeWidth < 8) return lines.map((line) => truncateToWidth(line, safeWidth, ""));
	const border = (text: string) => theme.fg("borderAccent", text);
	const frame = frameGlyphs();
	const contentWidth = Math.max(1, safeWidth - 2 - WIDGET_PADDING_X * 2);
	return [
		`${border(frame.tl)}${border(frame.h.repeat(safeWidth - 2))}${border(frame.tr)}`,
		...lines.map((line) => `${border(frame.v)}${" ".repeat(WIDGET_PADDING_X)}${padAnsi(line, contentWidth)}${" ".repeat(WIDGET_PADDING_X)}${border(frame.v)}`),
		`${border(frame.bl)}${border(frame.h.repeat(safeWidth - 2))}${border(frame.br)}`,
	].map((line) => truncateToWidth(line, safeWidth, ""));
}

function wrapAnsiLines(text: string, width: number): string[] {
	const targetWidth = Math.max(1, width);
	return text.split(/\r?\n/).flatMap((line) => {
		const wrapped = wrapTextWithAnsi(line, targetWidth);
		return wrapped.length > 0 ? wrapped : [""];
	});
}

export class RenderedLines {
	private cachedLines?: string[];
	private cachedWidth?: number;

	constructor(private readonly text: string) {}

	invalidate(): void {
		this.cachedLines = undefined;
		this.cachedWidth = undefined;
	}

	render(width: number): string[] {
		if (this.cachedLines && this.cachedWidth === width) return this.cachedLines;
		this.cachedLines = wrapAnsiLines(this.text, Math.max(1, width));
		this.cachedWidth = width;
		return this.cachedLines;
	}
}

export function renderLines(text: string): RenderedLines {
	return new RenderedLines(text);
}

export function renderEmpty() {
	return { invalidate() {}, render: () => [] as string[] };
}

function bgTreeGlyph(branch: TreeBranch, cwd?: string): string {
	return treeGlyph(branch, cwd);
}

export function bgTree(theme: Theme, branch: TreeBranch = "├", cwd?: string): string {
	return theme.fg("muted", bgTreeGlyph(branch, cwd));
}

export function bgToolLabel(theme: Theme, label: string): string {
	return theme.fg("text", theme.bold(label));
}

function bgStatusColor(status: BackgroundTaskStatus): "success" | "error" | "warning" | "muted" {
	if (status === "running") return "warning";
	if (status === "completed") return "success";
	if (status === "failed" || status === "timed_out") return "error";
	return "muted";
}

export function bgStatusIcon(status: BackgroundTaskStatus, theme: Theme): string {
	const g = glyphs();
	if (status === "running") return theme.fg("warning", g.bullet.trim());
	if (status === "completed") return theme.fg("success", glyphStyle() === "ascii" ? g.ok : ICONS.check);
	if (status === "failed" || status === "timed_out") return theme.fg("error", glyphStyle() === "ascii" ? g.fail : ICONS.times);
	return theme.fg("muted", glyphStyle() === "ascii" ? "-" : "■");
}

export function bgStatusText(task: Pick<BackgroundTaskSnapshot, "status" | "exitCode">, theme: Theme): string {
	return theme.fg(bgStatusColor(task.status), summarizeTaskStatus(task.status, task.exitCode, task.terminationReason));
}

function renderToolTaskRow(task: BackgroundTaskSnapshot, theme: Theme, branch: TreeBranch, cwd?: string): string {
	return `${bgTree(theme, branch, cwd)}${bgStatusIcon(task.status, theme)} ${theme.fg("accent", task.id)} ${bgStatusText(task, theme)}${theme.fg(
		"dim",
		` · pid ${task.pid} · ${compactText(taskDisplayName(task), 56)} · ${formatRelativeTime(taskActivityAt(task))}`,
	)}`;
}

export function renderTaskDetails(task: BackgroundTaskSnapshot, theme: Theme, cwd?: string): string[] {
	const current = latestSnapshot(task) ?? task;
	const lines = [
		`${bgTree(theme, "├", cwd)}${theme.fg("muted", "Status")}: ${bgStatusText(current, theme)} ${theme.fg("dim", `· pid ${current.pid}`)}`,
		`${bgTree(theme, "├", cwd)}${theme.fg("muted", "Title")}: ${taskDisplayName(current)}`,
		`${bgTree(theme, "├", cwd)}${theme.fg("muted", "Command")}: ${current.command}`,
		`${bgTree(theme, "├", cwd)}${theme.fg("muted", "Cwd")}: ${current.cwd}`,
		`${bgTree(theme, "├", cwd)}${theme.fg("muted", "Log")}: ${current.logFile}`,
	];
	if (current.status === "running" && current.expiresAt != null) lines.push(`${bgTree(theme, "├", cwd)}${theme.fg("muted", "Timeout")}: ${formatRelativeTime(current.expiresAt)}`);
	lines.push(
		`${bgTree(theme, "└", cwd)}${theme.fg("muted", "Wakeups")}: exit=${current.notifyOnExit ? "yes" : "no"}, output=${
			current.notifyOnOutput ? (current.notifyPattern ?? "yes") : "no"
		}, mode=${current.notifyMode ?? "always"}${current.dedupeKey ? `, dedupeKey=${current.dedupeKey}` : ""}`,
	);
	return lines;
}

function toolRenderMode(cwd?: string): "compact" | "stacked" {
	return settingEnum("toolRenderMode", ["compact", "stacked"] as const, "stacked", cwd);
}

export function makeToolResult(text: string, details: Record<string, unknown> = {}): AgentToolResult<unknown> {
	return { content: [{ type: "text", text }], details };
}

function backgroundRule(theme: Theme, width: number): string {
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

function renderRuledBackgroundMessage(text: string, theme: Theme): Component {
	return {
		invalidate() {},
		render(width: number): string[] {
			const rule = backgroundRule(theme, width);
			return [rule, ...wrapAnsiLines(text, width), rule];
		},
	};
}

function isBackgroundTaskEventDetails(value: unknown): value is BackgroundTaskEventDetails {
	if (!value || typeof value !== "object") return false;
	const candidate = value as Partial<BackgroundTaskEventDetails>;
	return (
		(candidate.eventType === "output" || candidate.eventType === "exit") &&
		Boolean(candidate.task) &&
		typeof candidate.outputTail === "string"
	);
}

function outputLineLimit(cwd?: string): number {
	return Math.max(1, Math.floor(settingNumber("toolExpandedLogLines", 80, cwd)));
}

export function renderTaskEventMessage(
	message: { content?: unknown; details?: unknown },
	expanded: boolean,
	theme: Theme,
): Component {
	if (!isBackgroundTaskEventDetails(message.details)) {
		return renderRuledBackgroundMessage(String(message.content ?? "Background task update"), theme);
	}

	const details = message.details;
	const task = latestSnapshot(details.task) ?? details.task;
	if (!expanded) {
		const prefix = details.eventType === "exit" ? theme.fg("success", "●") : theme.fg("accent", "●");
		const label = details.eventType === "exit"
			? `${theme.fg("toolTitle", theme.bold("Background task "))}${theme.fg("success", "finished")}`
			: theme.fg("toolTitle", theme.bold("Background task output"));
		return renderRuledBackgroundMessage(
			`${prefix} ${label} ${theme.fg("accent", task.id)}${theme.fg("dim", ` · ${compactText(taskDisplayName(task), 64)} · ctrl+o to expand`)}`,
			theme,
		);
	}

	const headingLabel = details.eventType === "exit"
		? `${theme.fg("toolTitle", theme.bold("Background task "))}${theme.fg("success", "finished ")}`
		: bgToolLabel(theme, "Background task output ");
	const headingIcon = details.eventType === "exit" ? theme.fg("success", "●") : theme.fg("accent", "●");
	const lines = [
		`${headingIcon} ${headingLabel}${theme.fg("accent", task.id)}${theme.fg(
			"dim",
			` · ${compactText(taskDisplayName(task), 72)}`,
		)}`,
		...renderTaskDetails(task, theme),
	];
	if (details.matchedPattern) lines.push(`${bgTree(theme, "└")}${theme.fg("muted", "Pattern")}: ${details.matchedPattern}`);

	const preview = details.outputTail;
	const lineLimit = outputLineLimit();
	const output = takeTailLines(preview, lineLimit);
	lines.push("", theme.fg("accent", theme.bold("Recent output")));
	if (output.hidden > 0) lines.push(`${bgTree(theme, "│")}${theme.fg("muted", `… ${output.hidden} older line(s); full log: ${task.logFile}`)}`);
	lines.push(...(output.lines.length ? output.lines : ["(no output yet)"]).map((line) => `${bgTree(theme, "│")}${theme.fg("dim", line)}`));
	if (output.total >= lineLimit) lines.push(`${bgTree(theme, "└")}${theme.fg("muted", `Full background log: ${task.logFile}`)}`);
	return renderRuledBackgroundMessage(lines.join("\n"), theme);
}

function bgToolAction(args: any, details: any): string {
	return typeof details?.action === "string" ? details.action : typeof args?.action === "string" ? args.action : "status";
}

function renderBgToolPartial(args: any, theme: Theme): RenderedLines {
	const action = bgToolAction(args, undefined);
	const target = args?.id ?? args?.pid ?? "tasks";
	const verb = action === "spawn" ? "starting" : action === "log" ? "tailing" : action === "stop" ? "stopping" : action === "clear" ? "clearing" : "checking";
	const title = action === "spawn" ? compactText(String(args?.title || args?.command || "background task"), 72) : String(target);
	return renderLines(`${theme.fg("warning", "● ")}${bgToolLabel(theme, `Background task ${verb}`)} ${theme.fg("accent", title)}${theme.fg("dim", "…")}`);
}

function renderBgLogResult(task: BackgroundTaskSnapshot | undefined, output: string, theme: Theme, expanded: boolean, cwd?: string): string {
	task = latestSnapshot(task);
	const taskLabel = task ? `${theme.fg("accent", task.id)} ${bgStatusText(task, theme)}` : theme.fg("accent", "log");
	const outputLines = takeTailLines(output, expanded ? outputLineLimit(cwd) : TOOL_PREVIEW_LINES);
	let text = `${theme.fg("accent", "● ")}${bgToolLabel(theme, "Background log ")}${taskLabel}${theme.fg(
		"dim",
		` · ${lineCount(output)} line${lineCount(output) === 1 ? "" : "s"}${expanded ? "" : " · ctrl+o to expand"}`,
	)}`;
	if (expanded && task) text += `\n${renderTaskDetails(task, theme, cwd).join("\n")}`;
	if (expanded && output) {
		if (outputLines.hidden > 0) text += `\n${bgTree(theme, "│", cwd)}${theme.fg("muted", `… ${outputLines.hidden} older line(s); full log: ${task?.logFile ?? "available in details"}`)}`;
		text += `\n${outputLines.lines.map((line) => `${bgTree(theme, "│", cwd)}${theme.fg("dim", line)}`).join("\n")}`;
		if (task) text += `\n${bgTree(theme, "└", cwd)}${theme.fg("muted", `Full background log: ${task.logFile}`)}`;
	} else if (!expanded && output && toolRenderMode(cwd) === "stacked") {
		if (outputLines.lines.length > 0) text += `\n${bgTree(theme, "└", cwd)}${theme.fg("muted", compactText(outputLines.lines[outputLines.lines.length - 1] ?? "", 120))}`;
	}
	return text;
}

export function renderBgToolResult(result: any, options: any, theme: Theme, context: any): RenderedLines | ReturnType<typeof renderEmpty> {
	if (options?.isPartial) return renderBgToolPartial(context?.args ?? {}, theme);
	const action = bgToolAction(context?.args ?? {}, result?.details);
	const cwd = context?.cwd;
	const expanded = Boolean(options?.expanded);
	const details = result?.details ?? {};
	const raw = typeof result?.content?.find === "function" ? result.content.find((part: any) => part?.type === "text")?.text ?? "" : "";

	if (context?.isError || result?.isError) {
		const first = raw.split(/\r?\n/)[0] || "background task failed";
		return renderLines(`${theme.fg("error", `${ICONS.times} `)}${bgToolLabel(theme, "Background task")} ${theme.fg("error", first)}`);
	}

	if (action === "list") return renderEmpty();

	if (action === "spawn") {
		const task = details.task as BackgroundTaskSnapshot | undefined;
		if (!task) return renderLines(`${theme.fg("warning", "● ")}${bgToolLabel(theme, "Background task started")}`);
		let text = `${theme.fg("warning", "● ")}${bgToolLabel(theme, "Background task started ")}${theme.fg("accent", task.id)}${theme.fg(
			"dim",
			` · pid ${task.pid} · ${compactText(taskDisplayName(task), 72)}${expanded ? "" : " · ctrl+o to expand"}`,
		)}`;
		if (expanded) text += `\n${renderTaskDetails(task, theme, cwd).join("\n")}`;
		return renderLines(text);
	}

	if (action === "log") return renderLines(renderBgLogResult(details.task as BackgroundTaskSnapshot | undefined, raw, theme, expanded, cwd));

	if (action === "stop") {
		const task = latestSnapshot(details.task as BackgroundTaskSnapshot | undefined);
		const label = task ? `${theme.fg("accent", task.id)} ${bgStatusText(task, theme)}` : theme.fg("muted", compactText(raw, 80));
		let text = `${theme.fg("warning", "● ")}${bgToolLabel(theme, "Background task stop ")}${label}`;
		if (expanded && task) text += `\n${renderTaskDetails(task, theme, cwd).join("\n")}`;
		return renderLines(text);
	}

	if (action === "clear") {
		const removed = Number(details.removed ?? 0);
		return renderLines(`${theme.fg("success", "● ")}${bgToolLabel(theme, "Background tasks cleared")}${theme.fg("dim", ` · removed ${removed} finished`)}`);
	}

	return raw ? renderLines(raw) : renderEmpty();
}

export function activePill(theme: Theme, label: string): string {
	return theme.fg("accent", theme.inverse(theme.bold(label)));
}

export function inactivePill(theme: Theme, label: string): string {
	return theme.bg("selectedBg", theme.fg("accent", label));
}
