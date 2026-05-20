import { StringEnum } from "@earendil-works/pi-ai";
import type { AgentToolResult, ExtensionAPI, ExtensionCommandContext, ExtensionContext, Theme, ToolExecutionMode } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, visibleWidth, wrapTextWithAnsi, type AutocompleteItem } from "@earendil-works/pi-tui";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { Type } from "typebox";
import { MINI_DASHBOARD_RANK, setMiniDashboardWidget } from "./stacked-widget.js";
import {
	applyTaskPanelContentVisibility,
	createTaskPanelVisibility,
	cycleTaskPanelVisibility,
	ensureTaskPanelVisibility,
	normalizePanelState,
	rememberTaskPanelVisibility,
	restoreTaskPanelVisibility,
	userHideTaskPanel,
	userShowTaskPanel,
	visiblePanelFor,
	type PanelState,
	type VisiblePanelState,
} from "./visibility.js";

const INSTALL_SYMBOL = Symbol.for("vstack.pi-task-panel.installed");
const CONFIG_ID = "@vanillagreen/pi-task-panel";
const STATE_TYPE = "vstack-task-panel:state";
const TASK_CONTEXT_TYPE = "vstack-task-panel:context";
const TASK_COMPLETE_MESSAGE_TYPE = "vstack-task-panel:complete";
const WIDGET_KEY = "vstack-task-panel";
const VSTACK_MODAL_LOCK_SYMBOL = Symbol.for("vstack.pi.modal-lock");
const PANEL_BAR_COLOR = "borderAccent";
const PANEL_TITLE_COLOR = "customMessageLabel";
const PANEL_RULE_COLOR = "muted";
const POPUP_PADDING_X = 2;
const POPUP_PADDING_Y = 1;
const PANEL_CARD_PADDING_X = 1;
const MANAGE_TASK_ROWS = 12;
const ANSI_GREEN_FG = "\x1b[32m";
const ANSI_YELLOW_FG = "\x1b[33m";
const ANSI_FG_RESET = "\x1b[39m";

function ansiGreen(text: string): string { return `${ANSI_GREEN_FG}${text}${ANSI_FG_RESET}`; }
function ansiYellow(text: string): string { return `${ANSI_YELLOW_FG}${text}${ANSI_FG_RESET}`; }

type Status = "pending" | "in_progress" | "completed" | "abandoned";
type VstackConfig = Record<string, unknown>;

interface TaskItem {
	id: string;
	content: string;
	status: Status;
	phaseId?: string;
	notes: string[];
	order: number;
}

interface PhaseItem {
	id: string;
	title: string;
	order: number;
}

interface TaskPanelState {
	version: 1;
	panel: PanelState;
	lastVisiblePanel: VisiblePanelState;
	hiddenByUser: boolean;
	autoShownThisSession: boolean;
	phases: PhaseItem[];
	tasks: TaskItem[];
	updatedAt: string;
}

interface VstackModalLock {
	depth: number;
}

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

function projectSettingsPath(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi", "settings.json");
		if (existsSync(candidate)) return candidate;
		if (existsSync(join(current, ".pi")) || existsSync(join(current, ".git")) || existsSync(join(current, ".vstack-lock.json"))) return candidate;
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
}

function piSettingsPaths(cwd = process.cwd()): string[] {
	const userDir = resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
	return [join(userDir, "settings.json"), projectSettingsPath(cwd)];
}

function piUserDir(): string {
	return resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
}

function safeFileName(value: string): string {
	return value.replace(/[^\w.-]+/g, "_");
}

function sessionIdForContext(ctx: ExtensionContext): string {
	const id = ctx.sessionManager.getSessionId();
	if (id && id.trim()) return id;
	const file = ctx.sessionManager.getSessionFile();
	if (file) return file.split(/[\\/]/).pop()?.replace(/\.jsonl$/, "") ?? `ephemeral-${process.pid}`;
	return `ephemeral-${process.pid}`;
}

function sidecarStatePath(ctx: ExtensionContext): string {
	return join(piUserDir(), "vstack", "sessions", safeFileName(sessionIdForContext(ctx)), "pi-task-panel", "state.json");
}

function readVstackConfig(cwd?: string): VstackConfig {
	const merged: VstackConfig = {};
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			const config = parsed?.vstack?.extensionManager?.config?.[CONFIG_ID];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return merged;
}

function settingNumber(key: string, fallback: number, cwd?: string): number {
	const value = readVstackConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readVstackConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readVstackConfig(cwd)[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

function acquireVstackModalLock(): () => void {
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

function padAnsi(text: string, width: number): string {
	const truncated = truncateToWidth(text, width, "");
	return `${truncated}${" ".repeat(Math.max(0, width - visibleWidth(truncated)))}`;
}

function panelFrameContentWidth(width: number): number {
	return Math.max(1, width - 2 - PANEL_CARD_PADDING_X * 2);
}

function panelFrame(lines: string[], width: number, theme: Theme): string[] {
	const safeWidth = Math.max(1, width);
	if (safeWidth < 8) return lines.map((line) => truncateToWidth(line, safeWidth, ""));
	const inner = Math.max(1, safeWidth - 2);
	const contentWidth = panelFrameContentWidth(safeWidth);
	const border = (text: string) => theme.fg(PANEL_BAR_COLOR, text);
	return [
		`${border("┏")}${border("━".repeat(inner))}${border("┓")}`,
		...lines.map((line) => `${border("┃")}${" ".repeat(PANEL_CARD_PADDING_X)}${padAnsi(line, contentWidth)}${" ".repeat(PANEL_CARD_PADDING_X)}${border("┃")}`),
		`${border("┗")}${border("━".repeat(inner))}${border("┛")}`,
	].map((line) => truncateToWidth(line, safeWidth, ""));
}

function panelTreeStyle(cwd?: string): "unicode" | "ascii" {
	const value = readVstackConfig(cwd).treeStyle;
	return value === "ascii" || value === "unicode" ? value : "unicode";
}

function panelBranch(theme: Theme, branch: "├" | "└" | "│", cwd?: string): string {
	if (panelTreeStyle(cwd) === "ascii") {
		if (branch === "│") return theme.fg(PANEL_RULE_COLOR, "|  ");
		return theme.fg(PANEL_RULE_COLOR, branch === "└" ? "`-- " : "|-- ");
	}
	if (branch === "│") return theme.fg(PANEL_RULE_COLOR, "│  ");
	return theme.fg(PANEL_RULE_COLOR, `${branch}─ `);
}

function panelGroupRoot(theme: Theme, title: string, count: number, isLastGroup: boolean, cwd?: string): string {
	const prefix = panelTreeStyle(cwd) === "ascii" ? (isLastGroup ? "`-- " : "|-- ") : (isLastGroup ? "└─ " : "├─ ");
	const titleText = theme.fg("mdHeading", theme.bold(title));
	const countText = theme.fg("dim", ` ${count}`);
	return `${theme.fg(PANEL_RULE_COLOR, prefix)}${titleText}${countText}`;
}

function panelGroupBranch(theme: Theme, isLastTask: boolean, isLastGroup: boolean, cwd?: string): string {
	if (panelTreeStyle(cwd) === "ascii") return theme.fg(PANEL_RULE_COLOR, `${isLastGroup ? "    " : "|   "}${isLastTask ? "`-- " : "|-- "}`);
	return theme.fg(PANEL_RULE_COLOR, `${isLastGroup ? "   " : "│  "}${isLastTask ? "└─ " : "├─ "}`);
}

function panelGroupStem(theme: Theme, isLastTask: boolean, isLastGroup: boolean, cwd?: string): string {
	if (panelTreeStyle(cwd) === "ascii") return theme.fg(PANEL_RULE_COLOR, `${isLastGroup ? "    " : "|   "}${isLastTask ? "    " : "|   "}`);
	return theme.fg(PANEL_RULE_COLOR, `${isLastGroup ? "   " : "│  "}${isLastTask ? "   " : "│  "}`);
}

function framePopup(lines: string[], width: number, theme: Theme, title = ""): string[] {
	if (width < 8) return lines.map((line) => truncateToWidth(line, width, ""));
	const border = (text: string) => theme.fg("borderAccent", text);
	const contentWidth = Math.max(1, width - 2 - POPUP_PADDING_X * 2);
	const blank = `${border("┃")}${" ".repeat(width - 2)}${border("┃")}`;
	const top = () => {
		if (!title) return `${border("┏")}${border("━".repeat(width - 2))}${border("┓")}`;
		const titlePlain = ` ${truncateToWidth(title, Math.max(1, width - 4), "…")} `;
		const fill = Math.max(1, width - 2 - visibleWidth(titlePlain));
		return `${border("┏")}${ansiGreen(titlePlain)}${border("━".repeat(fill))}${border("┓")}`;
	};
	const framed = [top()];
	for (let i = 0; i < POPUP_PADDING_Y; i += 1) framed.push(blank);
	for (const line of lines) {
		framed.push(`${border("┃")}${" ".repeat(POPUP_PADDING_X)}${padAnsi(line, contentWidth)}${" ".repeat(POPUP_PADDING_X)}${border("┃")}`);
	}
	for (let i = 0; i < POPUP_PADDING_Y; i += 1) framed.push(blank);
	framed.push(`${border("┗")}${border("━".repeat(width - 2))}${border("┛")}`);
	return framed.map((line) => truncateToWidth(line, width, ""));
}

function newId(prefix: string): string {
	return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
}

function defaultPanelState(cwd?: string): PanelState {
	return normalizePanelState(settingString("panelDefaultState", "compact", cwd), "compact");
}

function emptyState(cwd?: string): TaskPanelState {
	const visibility = createTaskPanelVisibility(defaultPanelState(cwd));
	return { ...visibility, phases: [], tasks: [], updatedAt: new Date().toISOString(), version: 1 };
}

function cloneState(state: TaskPanelState): TaskPanelState {
	return JSON.parse(JSON.stringify(state)) as TaskPanelState;
}

function normalizeState(value: unknown, cwd?: string): TaskPanelState {
	if (!value || typeof value !== "object") return emptyState(cwd);
	const candidate = value as Partial<TaskPanelState>;
	const panel = normalizePanelState(candidate.panel, defaultPanelState(cwd));
	const state: TaskPanelState = {
		version: 1,
		panel,
		lastVisiblePanel: visiblePanelFor(candidate.lastVisiblePanel, visiblePanelFor(panel)),
		hiddenByUser: candidate.hiddenByUser === true,
		autoShownThisSession: candidate.autoShownThisSession === true,
		phases: Array.isArray(candidate.phases) ? candidate.phases.filter((p): p is PhaseItem => Boolean(p?.id && p.title)) : [],
		tasks: Array.isArray(candidate.tasks) ? candidate.tasks.filter((t): t is TaskItem => Boolean(t?.id && t.content && t.status)) : [],
		updatedAt: typeof candidate.updatedAt === "string" ? candidate.updatedAt : new Date().toISOString(),
	};
	ensureTaskPanelVisibility(state);
	return state;
}

function taskIcon(status: Status, active = false): string {
	if (active || status === "in_progress" || status === "completed") return "●";
	return "○";
}

function markerColor(status: Status, active = false): string {
	if (active || status === "in_progress") return "accent";
	if (status === "completed") return "success";
	if (status === "abandoned") return "error";
	return "dim";
}

function taskText(task: TaskItem, active: boolean, theme: Theme): string {
	if (active || task.status === "in_progress") return theme.fg("accent", task.content);
	if (task.status === "completed") return theme.fg("muted", theme.strikethrough(task.content));
	if (task.status === "abandoned") return theme.fg("dim", theme.strikethrough(task.content));
	return task.content;
}

function renderTaskLine(task: TaskItem, theme: Theme, active = false, prefix = " "): string {
	const marker = theme.fg(markerColor(task.status, active), taskIcon(task.status, active));
	const notes = task.notes.length ? theme.fg("dim", ` +${task.notes.length}`) : "";
	return `${prefix}${marker} ${taskText(task, active, theme)}${notes}`;
}

function mutedRule(theme: Theme, width: number): string {
	const rule = "─".repeat(Math.max(1, width));
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

class SingleLineText {
	constructor(private readonly text: string) {}
	invalidate(): void {}
	render(width: number): string[] {
		if (!this.text.trim()) return [];
		return wrapTextWithAnsi(this.text, Math.max(1, width));
	}
}

class RuledSingleLineText {
	constructor(private readonly text: string, private readonly theme: Theme) {}
	invalidate(): void {}
	render(width: number): string[] {
		if (!this.text.trim()) return [];
		return [mutedRule(this.theme, width), ...wrapTextWithAnsi(this.text, Math.max(1, width)), mutedRule(this.theme, width)];
	}
}

function singleLine(text: string): SingleLineText {
	return new SingleLineText(text);
}

function ruledSingleLine(text: string, theme: Theme): RuledSingleLineText {
	return new RuledSingleLineText(text, theme);
}

function formatShortcutHint(shortcut: string): string {
	return shortcut.toLowerCase();
}

function panelToggleHint(cwd: string): string {
	const toggle = settingString("alternateShortcut", "alt+t", cwd);
	const manager = settingString("managerShortcut", "alt+shift+t", cwd);
	const parts: string[] = [];
	if (toggle !== "none") parts.push(`${formatShortcutHint(toggle)} toggle`);
	if (manager !== "none") parts.push(`${formatShortcutHint(manager)} manage`);
	return parts.join(" · ");
}

function activeTask(state: TaskPanelState): TaskItem | undefined {
	return state.tasks.find((task) => task.status === "in_progress") ?? sortTasks(state.tasks).find((task) => task.status === "pending");
}

function ensureActiveTask(state: TaskPanelState): TaskItem | undefined {
	const current = state.tasks.find((task) => task.status === "in_progress");
	if (current) return current;
	const next = sortTasks(state.tasks).find((task) => task.status === "pending");
	if (next) next.status = "in_progress";
	return next;
}

function remainingCount(state: TaskPanelState): number {
	return state.tasks.filter((task) => task.status === "pending" || task.status === "in_progress").length;
}

function completedCount(state: TaskPanelState): number {
	return state.tasks.filter((task) => task.status === "completed").length;
}

function phaseTitle(state: TaskPanelState, phaseId?: string): string {
	return state.phases.find((phase) => phase.id === phaseId)?.title ?? "Tasks";
}

function sortTasks(tasks: TaskItem[]): TaskItem[] {
	return [...tasks].sort((a, b) => a.order - b.order || a.id.localeCompare(b.id));
}

function ensurePhase(state: TaskPanelState, title: string): string {
	const trimmed = title.trim();
	const existing = state.phases.find((phase) => phase.title.toLowerCase() === trimmed.toLowerCase());
	if (existing) return existing.id;
	const phase: PhaseItem = { id: newId("phase"), order: state.phases.length, title: trimmed || "General" };
	state.phases.push(phase);
	return phase.id;
}

function updatePanelAfterTaskChange(state: TaskPanelState, cwd?: string): void {
	const active = sortTasks(state.tasks.filter((task) => task.status === "in_progress"));
	for (const task of active.slice(1)) task.status = "pending";
	const remaining = remainingCount(state);
	if (remaining > 0) ensureActiveTask(state);
	applyTaskPanelContentVisibility(state, {
		autoShowOnFirstTask: settingBoolean("autoShowOnFirstTask", true, cwd),
		defaultPanel: defaultPanelState(cwd),
		hasTasks: state.tasks.length > 0,
		remainingTasks: remaining,
	});
}

function addTask(state: TaskPanelState, content: string, phaseTitleText?: string, cwd?: string): TaskItem {
	const task: TaskItem = {
		content: content.trim(),
		id: newId("task"),
		notes: [],
		order: state.tasks.length,
		phaseId: phaseTitleText ? ensurePhase(state, phaseTitleText) : undefined,
		status: "pending",
	};
	state.tasks.push(task);
	updatePanelAfterTaskChange(state, cwd);
	return task;
}

function findTask(state: TaskPanelState, token: string): TaskItem | undefined {
	const trimmed = token.trim();
	if (!trimmed) return undefined;
	const needle = trimmed.toLowerCase();
	return state.tasks.find((task) => task.id === trimmed) ?? state.tasks.find((task) => task.content.toLowerCase().includes(needle));
}

function findTaskOrActive(state: TaskPanelState, token: string): TaskItem | undefined {
	return findTask(state, token) ?? (!token.trim() ? activeTask(state) : undefined);
}

function startTask(state: TaskPanelState, token: string, cwd?: string): TaskItem | undefined {
	const task = findTaskOrActive(state, token);
	if (!task) return undefined;
	for (const candidate of state.tasks) if (candidate.status === "in_progress") candidate.status = "pending";
	task.status = "in_progress";
	updatePanelAfterTaskChange(state, cwd);
	return task;
}

function isStatus(value: unknown): value is Status {
	return value === "pending" || value === "in_progress" || value === "completed" || value === "abandoned";
}

function markStatus(state: TaskPanelState, token: string, status: Status, cwd?: string): TaskItem | undefined {
	const task = findTaskOrActive(state, token);
	if (!task) return undefined;
	task.status = status;
	updatePanelAfterTaskChange(state, cwd);
	return task;
}

function removeTask(state: TaskPanelState, token: string, cwd?: string): boolean {
	const task = findTask(state, token);
	if (!task) return false;
	state.tasks = state.tasks.filter((candidate) => candidate.id !== task.id);
	updatePanelAfterTaskChange(state, cwd);
	return true;
}

function editableStatusLabel(status: Status): string {
	switch (status) {
		case "in_progress": return "active";
		case "completed": return "done";
		case "abandoned": return "dropped";
		case "pending": return "pending";
	}
}

function toEditableText(state: TaskPanelState): string {
	const lines = ["# Tasks", ""];
	const phaseIds = new Set(state.tasks.map((task) => task.phaseId).filter(Boolean) as string[]);
	const phases = state.phases.filter((phase) => phaseIds.has(phase.id)).sort((a, b) => a.order - b.order);
	const unphased = sortTasks(state.tasks.filter((task) => !task.phaseId));
	const renderTask = (task: TaskItem) => {
		const status = task.status === "pending" ? "" : ` (${editableStatusLabel(task.status)})`;
		lines.push(`- ${task.content}${status}`);
		for (const note of task.notes) lines.push(`  note: ${note}`);
	};
	if (unphased.length > 0) unphased.forEach(renderTask);
	for (const phase of phases) {
		lines.push("", `## ${phase.title}`, "");
		sortTasks(state.tasks.filter((task) => task.phaseId === phase.id)).forEach(renderTask);
	}
	return `${lines.join("\n").trim()}\n`;
}

function statusFromEditableLabel(label: string | undefined): Status | undefined {
	const normalized = label?.trim().toLowerCase().replace(/[\s_-]+/g, " ");
	if (!normalized) return undefined;
	if (normalized === "active" || normalized === "in progress" || normalized === "current") return "in_progress";
	if (normalized === "done" || normalized === "complete" || normalized === "completed") return "completed";
	if (normalized === "drop" || normalized === "dropped" || normalized === "abandoned" || normalized === "cancelled" || normalized === "canceled") return "abandoned";
	if (normalized === "pending" || normalized === "open") return "pending";
	return undefined;
}

function stripEditableStatus(content: string): { content: string; status?: Status } {
	const match = content.match(/\s+\((active|current|in[\s_-]*progress|pending|open|done|complete|completed|drop|dropped|abandoned|cancelled|canceled)\)\s*$/i);
	if (!match) return { content: content.trim() };
	return { content: content.slice(0, match.index).trim(), status: statusFromEditableLabel(match[1]) };
}

function statusFromLegacyBox(box: string | undefined): Status | undefined {
	if (!box) return undefined;
	if (box === "x" || box === "X") return "completed";
	if (box === "-") return "abandoned";
	if (box === ">") return "in_progress";
	return "pending";
}

function parseEditableText(text: string, cwd?: string, visibility = rememberTaskPanelVisibility(emptyState(cwd))): TaskPanelState {
	const state = emptyState(cwd);
	restoreTaskPanelVisibility(state, visibility);
	let currentPhase: string | undefined;
	let lastTask: TaskItem | undefined;
	for (const line of text.split(/\r?\n/)) {
		if (/^#\s+tasks\s*$/i.test(line.trim())) continue;
		const phase = line.match(/^##\s+(.+)$/);
		if (phase) {
			currentPhase = ensurePhase(state, phase[1] ?? "General");
			lastTask = undefined;
			continue;
		}
		const note = line.match(/^\s+(?:[-*]\s+)?note:\s*(.+)$/i);
		if (note && lastTask) {
			lastTask.notes.push(note[1] ?? "");
			continue;
		}
		const task = line.match(/^[-*]\s+(?:\[( |x|-|>)\]\s+)?(.+?)(?:\s+<!--\s*([^>]+)\s*-->)?\s*$/i);
		if (!task) continue;
		const parsed = stripEditableStatus(task[2] ?? "Task");
		if (!parsed.content) continue;
		const item = addTask(state, parsed.content, undefined, cwd);
		item.phaseId = currentPhase;
		item.id = task[3]?.trim() || item.id;
		item.status = parsed.status ?? statusFromLegacyBox(task[1]) ?? "pending";
		lastTask = item;
	}
	updatePanelAfterTaskChange(state, cwd);
	return state;
}

function renderPanelWidgetLines(state: TaskPanelState, theme: Theme, cwd: string, width: number): string[] {
	const lines = renderPanelLines(state, theme, cwd);
	if (lines.length === 0) return [];
	return panelFrame(lines, Math.max(1, width), theme);
}

/**
 * Cap the widget's rendered line count so an expanded panel can't push chat / status
 * above the terminal viewport top. pi-tui's differential renderer falls back to a
 * full screen + scrollback clear whenever firstChanged < prevViewportTop, which is
 * exactly what happens during streaming once the panel spans past the top of the
 * terminal. Reserve room for editor + footer + a sliver of chat; drop overflow with
 * a muted hint that the manage modal still shows the full list.
 */
function clampAboveEditorWidget(lines: string[], terminalRows: number, theme: Theme): string[] {
	const reserveForOtherUi = 10;
	const maxLines = Math.max(4, terminalRows - reserveForOtherUi);
	if (lines.length <= maxLines) return lines;
	const hidden = lines.length - (maxLines - 1);
	return [...lines.slice(0, maxLines - 1), theme.fg("muted", `… ${hidden} more (open task manager for full view)`)];
}

function renderPanelHeader(state: TaskPanelState, theme: Theme, active?: TaskItem, hint = ""): string {
	const remaining = remainingCount(state);
	const activePhase = active?.phaseId ? phaseTitle(state, active.phaseId) : "";
	const phaseBadge = state.panel === "compact" && activePhase && activePhase !== "Tasks"
		? ` ${theme.fg("dim", "›")} ${theme.fg("muted", activePhase)}`
		: "";
	const toggleHint = hint ? ` ${theme.fg("dim", `· ${hint}`)}` : "";
	return `${theme.fg(PANEL_TITLE_COLOR, theme.bold("Tasks"))}${phaseBadge} ${theme.fg("muted", `${completedCount(state)}/${state.tasks.length} done · ${remaining} remaining`)}${toggleHint}`;
}

function pushTaskGroup(lines: string[], title: string, tasks: TaskItem[], theme: Theme, cwd: string, isLastGroup: boolean): void {
	// Spine connector keeps the tree visually unbroken across phase groups.
	if (lines.length > 1) lines.push(panelBranch(theme, "│", cwd));
	lines.push(...renderTaskGroup(title, tasks, theme, cwd, isLastGroup));
}

function renderPanelLines(state: TaskPanelState, theme: Theme, cwd: string): string[] {
	if (state.tasks.length === 0 || state.panel === "hidden") return [];
	const remaining = remainingCount(state);
	const active = activeTask(state);
	const hint = panelToggleHint(cwd);
	const header = renderPanelHeader(state, theme, active, hint);
	if (state.panel === "compact") {
		const limit = Math.max(1, Math.floor(settingNumber("maxCompactTasks", 4, cwd)));
		const candidates = active?.phaseId ? sortTasks(state.tasks.filter((task) => task.phaseId === active.phaseId)) : sortTasks(state.tasks);
		const incomplete = candidates.filter((task) => task.status !== "completed" && task.status !== "abandoned");
		const visible = incomplete.filter((task) => task.id !== active?.id).slice(0, Math.max(0, limit - (active ? 1 : 0)));
		const lines = [header];
		const compactTasks = [active, ...visible].filter((task): task is TaskItem => Boolean(task));
		for (const [index, task] of compactTasks.entries()) {
			const isLast = index === compactTasks.length - 1 && remaining <= compactTasks.length;
			lines.push(renderTaskLine(task, theme, task.id === active?.id, panelBranch(theme, isLast ? "└" : "├", cwd)));
		}
		const shown = visible.length + (active ? 1 : 0);
		const hidden = Math.max(0, remaining - shown);
		if (hidden > 0) lines.push(`${panelBranch(theme, "└", cwd)}${theme.fg("muted", `… ${hidden} more`)}`);
		return lines;
	}
	const lines = [header];
	const groups: Array<{ title: string; tasks: TaskItem[] }> = [];
	const unphased = sortTasks(state.tasks.filter((task) => !task.phaseId));
	if (unphased.length) groups.push({ title: "Unphased", tasks: unphased });
	const phases = [...state.phases].sort((a, b) => a.order - b.order);
	for (const phase of phases) {
		const tasks = sortTasks(state.tasks.filter((task) => task.phaseId === phase.id));
		if (tasks.length) groups.push({ title: phase.title, tasks });
	}
	for (const [index, group] of groups.entries()) {
		pushTaskGroup(lines, group.title, group.tasks, theme, cwd, index === groups.length - 1);
	}
	return lines;
}

function renderTaskGroup(title: string, tasks: TaskItem[], theme: Theme, cwd: string, isLastGroup: boolean): string[] {
	const lines = [panelGroupRoot(theme, title, tasks.length, isLastGroup, cwd)];
	const active = tasks.find((task) => task.status === "in_progress");
	for (let index = 0; index < tasks.length; index++) {
		const task = tasks[index]!;
		const isLastTask = index === tasks.length - 1;
		const isActive = active?.id === task.id;
		const branch = panelGroupBranch(theme, isLastTask, isLastGroup, cwd);
		const stem = panelGroupStem(theme, isLastTask, isLastGroup, cwd);
		lines.push(renderTaskLine(task, theme, isActive, branch));
		if (isActive && settingBoolean("showNotesInExpanded", true, cwd)) {
			for (const note of task.notes) lines.push(`${stem}${theme.fg("dim", `note: ${note}`)}`);
		}
	}
	return lines;
}

function writeFileSafe(path: string, text: string): void {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, text, "utf8");
}

function summarize(state: TaskPanelState): string {
	return `${state.tasks.length} task(s), ${remainingCount(state)} remaining, panel=${state.panel}`;
}

function quoteTask(content: string): string {
	return `"${content.replace(/\s+/g, " ").trim().replace(/"/g, "'")}"`;
}

function taskSuffix(state: TaskPanelState): string {
	const remaining = remainingCount(state);
	return remaining === 0 ? "all complete" : `${remaining} remaining`;
}

function toolResultSummary(action: string, message: string, state: TaskPanelState): string {
	if (message.startsWith("No task")) return message;
	const suffix = taskSuffix(state);
	switch (action) {
		case "replace": return `${state.tasks.length} tasks written (${suffix})`;
		case "add_task": return `Task ${quoteTask(message)} added (${suffix})`;
		case "add_phase": return `Phase ${quoteTask(message)} added`;
		case "start_task": return `Task ${quoteTask(message)} started (${suffix})`;
		case "mark_done": return `Task ${quoteTask(message)} completed (${suffix})`;
		case "drop_task": return `Task ${quoteTask(message)} dropped (${suffix})`;
		case "remove_task": return `Task ${quoteTask(message)} removed (${suffix})`;
		case "append_note": return `Note added to ${quoteTask(message)}`;
		case "set_panel": return `Task panel ${state.panel}`;
		default: return message;
	}
}

function resultColor(action: string, summary: string): string {
	if (summary.startsWith("No task")) return "warning";
	if (action === "mark_done") return "success";
	if (action === "drop_task" || action === "remove_task") return "error";
	if (action === "start_task" || action === "add_task" || action === "replace") return "accent";
	return "muted";
}

function renderTaskToolSummary(summary: string, action: string, theme: Theme): string {
	const color = resultColor(action, summary);
	const bullet = theme.fg(color, "● ");
	const taskMatch = summary.match(/^(Task )("[^"]+")( .+)$/);
	if (taskMatch) {
		return `${bullet}${theme.fg("text", taskMatch[1] ?? "Task ")}${theme.fg("accent", taskMatch[2] ?? "")}${theme.fg(color, taskMatch[3] ?? "")}`;
	}
	return `${bullet}${theme.fg("text", summary)}`;
}

function workflowReminder(state: TaskPanelState): string {
	const active = activeTask(state);
	const head = active ? `active task ${quoteTask(active.content)}` : "no active task";
	return `Task workflow reminder: ${head}. Keep the panel current; reconcile before final reply.`;
}

function taskContextMessage(state: TaskPanelState): string {
	const remaining = sortTasks(state.tasks.filter((task) => task.status === "pending" || task.status === "in_progress"));
	const active = activeTask(state);
	const preview = remaining.slice(0, 8).map((task) => `${task.id === active?.id ? "*" : "-"} ${task.content} [${task.status}]`).join("\n");
	const hidden = Math.max(0, remaining.length - 8);
	return `<task_panel_state>\nActive task: ${active ? active.content : "(none)"}\nProgress: ${completedCount(state)}/${state.tasks.length} done; ${remaining.length} remaining\n${preview}${hidden ? `\n... ${hidden} more remaining` : ""}\n</task_panel_state>`;
}

function toolResultContent(summary: string, state: TaskPanelState, cwd: string): string {
	if (!settingBoolean("showWorkflowReminder", true, cwd) || remainingCount(state) === 0) return `• ${summary}`;
	return `• ${summary}\n${workflowReminder(state)}`;
}

const TaskToolParams = Type.Object({
	action: StringEnum(["replace", "add_phase", "add_task", "start_task", "mark_done", "drop_task", "remove_task", "append_note", "set_panel"] as const),
	tasks: Type.Optional(Type.Array(Type.Object({ content: Type.Optional(Type.String()), task: Type.Optional(Type.String()), status: Type.Optional(Type.String()), phase: Type.Optional(Type.String()), notes: Type.Optional(Type.Array(Type.String())) }))),
	phase: Type.Optional(Type.String()),
	task: Type.Optional(Type.String()),
	note: Type.Optional(Type.String()),
	panel: Type.Optional(StringEnum(["hidden", "compact", "expanded"] as const)),
});

const TASK_COMMAND_COMPLETIONS: AutocompleteItem[] = [
	{ value: "add ", label: "add <task>", description: "Add a task. Use Phase :: task to assign a phase." },
	{ value: "edit", label: "edit", description: "Bulk edit tasks as plain text." },
	{ value: "manage", label: "manage", description: "Open the interactive task manager." },
	{ value: "start ", label: "start <task>", description: "Set a task as active." },
	{ value: "done ", label: "done <task>", description: "Mark a task completed." },
	{ value: "drop ", label: "drop <task>", description: "Mark a task abandoned." },
	{ value: "remove ", label: "remove <task>", description: "Remove a task." },
	{ value: "clear-completed", label: "clear-completed", description: "Remove completed tasks." },
	{ value: "hide", label: "hide", description: "Hide the task panel." },
	{ value: "show", label: "show", description: "Show the compact task panel." },
	{ value: "show-all", label: "show-all", description: "Show the expanded task panel." },
	{ value: "export ", label: "export <path>", description: "Write tasks to a markdown file." },
	{ value: "import ", label: "import <path>", description: "Load tasks from a markdown file." },
];

function commandArgumentCompletions(prefix: string, state: TaskPanelState): AutocompleteItem[] | null {
	const raw = prefix.replace(/^\s+/, "");
	const firstSpace = raw.search(/\s/);
	const command = firstSpace === -1 ? raw : raw.slice(0, firstSpace);
	const rest = firstSpace === -1 ? "" : raw.slice(firstSpace + 1).trim().toLowerCase();
	const taskCommands = new Set(["start", "done", "drop", "remove"]);
	if (firstSpace !== -1 && taskCommands.has(command)) {
		const items = sortTasks(state.tasks)
			.filter((task) => !rest || task.content.toLowerCase().includes(rest))
			.slice(0, 20)
			.map((task) => ({
				value: `${command} ${task.content}`,
				label: task.content,
				description: `${command} · ${editableStatusLabel(task.status)}`,
			}));
		return items.length > 0 ? items : null;
	}
	const query = command.toLowerCase();
	const items = TASK_COMMAND_COMPLETIONS.filter((item) => {
		const value = item.value.toLowerCase();
		const label = (item.label ?? item.value).toLowerCase();
		return value.startsWith(query) || label.startsWith(query);
	});
	return items.length > 0 ? items : null;
}

export default function taskPanel(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;

	let state: TaskPanelState = emptyState();
	let activeCtx: ExtensionContext | undefined;
	let lastReminderAt = 0;
	let pendingCompletionMessage: { action: string; summary: string } | undefined;

	const writeSidecar = (ctx: ExtensionContext | undefined) => {
		if (!ctx) return;
		try {
			const file = sidecarStatePath(ctx);
			mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
			writeFileSync(file, `${JSON.stringify(cloneState(state), null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
		} catch {
			// Session entries and tool-result details remain the primary restore path.
		}
	};

	const readSidecar = (ctx: ExtensionContext): TaskPanelState | undefined => {
		try {
			const file = sidecarStatePath(ctx);
			if (!existsSync(file)) return undefined;
			return normalizeState(JSON.parse(readFileSync(file, "utf8")), ctx.cwd);
		} catch {
			return undefined;
		}
	};

	const persist = () => {
		state.updatedAt = new Date().toISOString();
		pi.appendEntry<TaskPanelState>(STATE_TYPE, cloneState(state));
		writeSidecar(activeCtx);
	};

	const restore = (ctx: ExtensionContext) => {
		activeCtx = ctx;
		state = readSidecar(ctx) ?? emptyState(ctx.cwd);
		for (const entry of ctx.sessionManager.getBranch()) {
			if (entry.type === "custom" && entry.customType === STATE_TYPE) state = normalizeState(entry.data, ctx.cwd);
			if (entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "tasks_write") {
				const restored = normalizeState(entry.message.details?.state, ctx.cwd);
				if (restored.tasks.length > 0 || restored.phases.length > 0) state = restored;
			}
		}
		updatePanelAfterTaskChange(state, ctx.cwd);
		syncWidget(ctx);
	};

	const syncWidget = (ctx: ExtensionContext) => {
		activeCtx = ctx;
		if (!ctx.hasUI || state.tasks.length === 0 || state.panel === "hidden") {
			setMiniDashboardWidget(ctx, WIDGET_KEY, MINI_DASHBOARD_RANK.TASKS, undefined);
			return;
		}
		setMiniDashboardWidget(ctx, WIDGET_KEY, MINI_DASHBOARD_RANK.TASKS, (tui, theme) => ({
			invalidate() {},
			render(width: number): string[] {
				return clampAboveEditorWidget(renderPanelWidgetLines(state, theme, ctx.cwd, width), tui.terminal.rows, theme);
			},
		}), { placement: "aboveEditor" });
	};

	const mutate = (ctx: ExtensionContext | ExtensionCommandContext, fn: () => string): string => {
		activeCtx = ctx as ExtensionContext;
		const message = fn();
		persist();
		syncWidget(ctx as ExtensionContext);
		return message;
	};

	async function editTasks(ctx: ExtensionCommandContext | ExtensionContext): Promise<void> {
		const text = await ctx.ui.editor("Edit tasks — one '- task' per line; optional: (active), (done), (dropped)", toEditableText(state));
		if (text === undefined) return;
		state = parseEditableText(text, ctx.cwd, rememberTaskPanelVisibility(state));
		ctx.ui.notify(mutate(ctx, () => `Saved ${state.tasks.length} task(s)`), "info");
	}

	async function manage(ctx: ExtensionCommandContext | ExtensionContext): Promise<void> {
		if (!ctx.hasUI) {
			ctx.ui.notify(toEditableText(state), "info");
			return;
		}
		let postManageAction: "edit" | undefined;
		const releaseModalLock = acquireVstackModalLock();
		try {
			await ctx.ui.custom((tui, theme, _kb, done) => {
				let selectedId: string | null = activeTask(state)?.id ?? sortTasks(state.tasks)[0]?.id ?? null;
				let scroll = 0;

				const taskList = () => sortTasks(state.tasks);
				const syncSelection = () => {
					const tasks = taskList();
					if (tasks.length === 0) {
						selectedId = null;
						scroll = 0;
						return;
					}
					if (!selectedId || !tasks.some((task) => task.id === selectedId)) selectedId = activeTask(state)?.id ?? tasks[0]?.id ?? null;
					const index = Math.max(0, tasks.findIndex((task) => task.id === selectedId));
					if (index < scroll) scroll = index;
					if (index >= scroll + MANAGE_TASK_ROWS) scroll = index - MANAGE_TASK_ROWS + 1;
					scroll = Math.max(0, Math.min(scroll, Math.max(0, tasks.length - MANAGE_TASK_ROWS)));
				};
				const selectedTask = () => {
					syncSelection();
					return selectedId ? state.tasks.find((task) => task.id === selectedId) : undefined;
				};
				const move = (delta: number) => {
					const tasks = taskList();
					if (tasks.length === 0) return;
					const current = Math.max(0, tasks.findIndex((task) => task.id === selectedId));
					selectedId = tasks[Math.max(0, Math.min(tasks.length - 1, current + delta))]?.id ?? null;
					syncSelection();
					tui.requestRender();
				};
				const applyTaskAction = (action: string, fn: () => string) => {
					const message = mutate(ctx, fn);
					const summary = toolResultSummary(action, message, state);
					ctx.ui.notify(summary, summary.startsWith("No task") ? "warning" : "info");
					syncSelection();
					tui.requestRender();
				};

				return {
					handleInput(data: string) {
						if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) { done(undefined); return; }
						if (matchesKey(data, "up")) { move(-1); return; }
						if (matchesKey(data, "down")) { move(1); return; }
						if (matchesKey(data, "-") || matchesKey(data, "pageup")) { move(-MANAGE_TASK_ROWS); return; }
						if (matchesKey(data, "=") || matchesKey(data, "pagedown")) { move(MANAGE_TASK_ROWS); return; }
						if (matchesKey(data, "home")) { move(-Number.MAX_SAFE_INTEGER); return; }
						if (matchesKey(data, "end")) { move(Number.MAX_SAFE_INTEGER); return; }
						if (matchesKey(data, "return") || matchesKey(data, "enter") || data === "s") {
							const task = selectedTask();
							applyTaskAction("start_task", () => task ? (startTask(state, task.id, ctx.cwd)?.content ?? "No task matched") : "No task selected");
							return;
						}
						if (data === "d") {
							const task = selectedTask();
							applyTaskAction("mark_done", () => task ? (markStatus(state, task.id, "completed", ctx.cwd)?.content ?? "No task matched") : "No task selected");
							return;
						}
						if (data === "x") {
							const task = selectedTask();
							applyTaskAction("drop_task", () => task ? (markStatus(state, task.id, "abandoned", ctx.cwd)?.content ?? "No task matched") : "No task selected");
							return;
						}
						if (data === "r" || matchesKey(data, "delete") || matchesKey(data, "backspace")) {
							const task = selectedTask();
							applyTaskAction("remove_task", () => task ? (removeTask(state, task.id, ctx.cwd) ? task.content : "No task matched") : "No task selected");
							return;
						}
						if (data === "c") {
							applyTaskAction("clear_completed", () => { const before = state.tasks.length; state.tasks = state.tasks.filter((task) => task.status !== "completed"); updatePanelAfterTaskChange(state, ctx.cwd); return `Removed ${before - state.tasks.length} completed task(s)`; });
							return;
						}
						if (data === "e") {
							postManageAction = "edit";
							done(undefined);
						}
					},
					invalidate() {},
					render(width: number) {
						const contentWidth = Math.max(1, width - 2 - POPUP_PADDING_X * 2);
						syncSelection();
						const tasks = taskList();
						const lines: string[] = [];
						if (tasks.length === 0) {
							lines.push(theme.fg("dim", "No tasks. Use /tasks add <task> or /tasks edit."));
						} else {
							if (scroll > 0) lines.push(theme.fg("dim", `↑ ${scroll} earlier task(s)`));
							for (const task of tasks.slice(scroll, scroll + MANAGE_TASK_ROWS)) {
								const selected = task.id === selectedId;
								const active = task.status === "in_progress";
								const marker = theme.fg(markerColor(task.status, active), taskIcon(task.status, active));
								const content = selected ? theme.fg("text", active ? theme.bold(task.content) : task.status === "completed" || task.status === "abandoned" ? theme.strikethrough(task.content) : task.content) : taskText(task, active, theme);
								const phase = task.phaseId ? ` · ${phaseTitle(state, task.phaseId)}` : "";
								const row = ` ${marker} ${content}${theme.fg(selected ? "text" : "dim", `${phase} · ${editableStatusLabel(task.status)}`)}`;
								lines.push(selected ? theme.bg("selectedBg", padAnsi(row, contentWidth)) : row);
							}
							const below = Math.max(0, tasks.length - (scroll + MANAGE_TASK_ROWS));
							if (below > 0) lines.push(theme.fg("dim", `↓ ${below} more task(s)`));
						}
						const body = lines.map((line) => truncateToWidth(line, contentWidth, ""));
						const footerHint = `${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("s")} ${theme.fg("dim", "start · ")}${ansiYellow("d")} ${theme.fg("dim", "done · ")}${ansiYellow("x")} ${theme.fg("dim", "drop · ")}${ansiYellow("r")} ${theme.fg("dim", "remove · ")}${ansiYellow("c")} ${theme.fg("dim", "clear done · ")}${ansiYellow("e")} ${theme.fg("dim", "edit")}`;
						const footer = [mutedRule(theme, contentWidth), ...wrapTextWithAnsi(footerHint, contentWidth)];
						return framePopup([...body, ...footer], width, theme, "Tasks Manager");
					},
				};
			}, { overlay: true, overlayOptions: { anchor: "center", width: 100, maxHeight: "85%" } });
		} finally {
			releaseModalLock();
		}
		if (postManageAction === "edit") await editTasks(ctx);
	}

	function handleTasksCommand(args: string, ctx: ExtensionCommandContext): Promise<void> | void {
		const trimmed = args.trim();
		if (!trimmed || trimmed === "manage") return manage(ctx);
		const [cmd, ...restParts] = trimmed.split(/\s+/);
		const rest = restParts.join(" ").trim();
		let message = "";
		switch (cmd) {
			case "add": {
				const [phase, task] = rest.includes("::") ? rest.split(/\s*::\s*/, 2) : [undefined, rest];
				message = mutate(ctx, () => `Added ${addTask(state, task || rest, phase, ctx.cwd).id}`);
				break;
			}
			case "start": message = mutate(ctx, () => startTask(state, rest, ctx.cwd)?.content ?? `No task matched: ${rest}`); break;
			case "done": message = mutate(ctx, () => markStatus(state, rest, "completed", ctx.cwd)?.content ?? `No task matched: ${rest}`); break;
			case "drop": message = mutate(ctx, () => markStatus(state, rest, "abandoned", ctx.cwd)?.content ?? `No task matched: ${rest}`); break;
			case "remove": message = mutate(ctx, () => removeTask(state, rest, ctx.cwd) ? `Removed ${rest}` : `No task matched: ${rest}`); break;
			case "clear-completed": message = mutate(ctx, () => { const before = state.tasks.length; state.tasks = state.tasks.filter((task) => task.status !== "completed"); updatePanelAfterTaskChange(state, ctx.cwd); return `Removed ${before - state.tasks.length} completed task(s)`; }); break;
			case "hide": message = mutate(ctx, () => { userHideTaskPanel(state); return "Task panel hidden"; }); break;
			case "show": message = mutate(ctx, () => { userShowTaskPanel(state, "compact"); return `Task panel showing ${Math.max(1, Math.floor(settingNumber("maxCompactTasks", 4, ctx.cwd)))} task(s)`; }); break;
			case "show-all": message = mutate(ctx, () => { userShowTaskPanel(state, "expanded"); return "Task panel showing all tasks"; }); break;
			case "toggle": message = mutate(ctx, () => {
				cycleTaskPanelVisibility(state);
				if (state.panel === "hidden") return "Task panel hidden";
				return state.panel === "expanded" ? "Task panel showing all tasks" : `Task panel showing ${Math.max(1, Math.floor(settingNumber("maxCompactTasks", 4, ctx.cwd)))} task(s)`;
			}); break;
			case "export": { const out = rest || join(ctx.cwd, ".pi", "tasks.md"); writeFileSafe(resolve(ctx.cwd, out), toEditableText(state)); message = `Exported tasks to ${out}`; break; }
			case "import": { const input = resolve(ctx.cwd, rest || join(".pi", "tasks.md")); state = parseEditableText(readFileSync(input, "utf8"), ctx.cwd, rememberTaskPanelVisibility(state)); message = mutate(ctx, () => `Imported ${state.tasks.length} task(s)`); break; }
			case "edit": return editTasks(ctx);
			default: message = "Unknown /tasks action. Try add, edit, manage, start, done, drop, remove, hide, show, or show-all.";
		}
		ctx.ui.notify(message, message.startsWith("No task") || message.startsWith("Unknown") ? "warning" : "info");
	}

	pi.registerCommand("tasks", {
		description: "Persistent task panel and task list manager.",
		getArgumentCompletions: (prefix: string) => commandArgumentCompletions(prefix, state),
		handler: async (args, ctx) => handleTasksCommand(args, ctx),
	});

	const taskNameCompletions = (prefix: string) => {
		const query = prefix.trimStart().toLowerCase();
		const items = sortTasks(state.tasks)
			.filter((task) => !query || task.content.toLowerCase().includes(query))
			.slice(0, 20)
			.map((task) => ({ value: task.content, label: task.content, description: editableStatusLabel(task.status) }));
		return items.length > 0 ? items : null;
	};

	const noArgSubs = [
		{ sub: "edit", description: "Bulk edit tasks as plain text" },
		{ sub: "manage", description: "Open the interactive task manager" },
		{ sub: "clear-completed", description: "Remove completed tasks" },
		{ sub: "toggle", description: "Show or hide the mini task panel" },
	] as const;
	for (const { sub, description } of noArgSubs) {
		pi.registerCommand(`tasks:${sub}`, {
			description,
			handler: async (_args, ctx) => handleTasksCommand(sub, ctx),
		});
	}

	pi.registerCommand("tasks:add", {
		description: "Add a task. Use 'Phase :: task' to assign a phase.",
		handler: async (args, ctx) => handleTasksCommand(`add ${args}`.trim(), ctx),
	});

	for (const sub of ["start", "done", "remove"] as const) {
		const description =
			sub === "start" ? "Set a task as active: /tasks:start <task>" :
			sub === "done" ? "Mark a task completed: /tasks:done <task>" :
			"Remove a task: /tasks:remove <task>";
		pi.registerCommand(`tasks:${sub}`, {
			description,
			getArgumentCompletions: taskNameCompletions,
			handler: async (args, ctx) => handleTasksCommand(`${sub} ${args}`.trim(), ctx),
		});
	}

	pi.registerCommand("tasks:export", {
		description: "Write tasks to a markdown file: /tasks:export <path>",
		handler: async (args, ctx) => handleTasksCommand(`export ${args}`.trim(), ctx),
	});
	pi.registerCommand("tasks:import", {
		description: "Load tasks from a markdown file: /tasks:import <path>",
		handler: async (args, ctx) => handleTasksCommand(`import ${args}`.trim(), ctx),
	});

	pi.registerMessageRenderer(TASK_COMPLETE_MESSAGE_TYPE, (message: any, _options: any, theme: Theme) => {
		const summary = typeof message?.details?.summary === "string" ? message.details.summary : typeof message?.content === "string" ? message.content : "Tasks complete";
		const action = typeof message?.details?.action === "string" ? message.details.action : "mark_done";
		return ruledSingleLine(renderTaskToolSummary(summary, action, theme), theme);
	});

	const compactToolOutput = settingBoolean("compactToolOutput", true);

	pi.registerTool({
		...(compactToolOutput ? { renderShell: "self" as const } : {}),
		executionMode: "sequential" as ToolExecutionMode,
		name: "tasks_write",
		label: "Tasks Write",
		description: "Structured task panel updates: replace/add/start/done/drop/remove/note/panel.",
		promptSnippet: "Create and update the persistent task panel for multi-step work.",
		promptGuidelines: [
			"Use tasks_write to keep a visible task list when the user asks for multi-step work or when you need to track progress across tool calls.",
			"Update tasks proactively when scope changes: start_task for the work you are actually doing, add_task for discovered follow-ups, and drop_task for obsolete or out-of-scope tasks.",
			"Mark tasks done promptly with mark_done when completed; do not move on while leaving completed work in_progress.",
			"Param shape differs by action. replace: { action: 'replace', tasks: [{ content: '<text>', phase?: '<phase>', status?: 'pending' }] }. Single-task actions (add_task/start_task/mark_done/drop_task/remove_task/append_note): top-level { task: '<text or id>', phase?, note? } — no tasks[] array.",
			"Before final replies that claim work is done, fixed, committed, verified, or no longer relevant, call tasks_write to reconcile the panel first: mark_done completed tasks, drop_task obsolete tasks, and add_task follow-ups.",
			"Do not leave stale in_progress tasks; if the active task no longer matches the work, call start_task or drop_task before continuing.",
			"tasks_write runs sequentially and automatically advances to the next pending task after mark_done/drop_task; do not issue a separate start_task unless switching to a non-next task.",
			"tasks_write hides the panel when all tasks are complete; auto-show happens only for the first non-empty task state in a session and never overrides a user-hidden panel.",
		],
		parameters: TaskToolParams,
		async execute(_id, params, _signal, _onUpdate, ctx): Promise<AgentToolResult<unknown>> {
			const runCtx = ctx ?? activeCtx;
			if (!runCtx) throw new Error("No active Pi context for tasks_write");
			const message = mutate(runCtx, () => {
				switch (params.action) {
					case "replace": { const visibility = rememberTaskPanelVisibility(state); state = emptyState(runCtx.cwd); restoreTaskPanelVisibility(state, visibility); for (const input of params.tasks ?? []) { const text = input.content ?? input.task ?? ""; if (!text) continue; const task = addTask(state, text, input.phase, runCtx.cwd); task.status = isStatus(input.status) ? input.status : "pending"; task.notes = input.notes ?? []; } updatePanelAfterTaskChange(state, runCtx.cwd); return `Replaced tasks (${state.tasks.length})`; }
					case "add_phase": ensurePhase(state, params.phase ?? "General"); return params.phase ?? "General";
					case "add_task": return addTask(state, params.task ?? "Task", params.phase, runCtx.cwd).content;
					case "start_task": return startTask(state, params.task ?? "", runCtx.cwd)?.content ?? "No task matched";
					case "mark_done": return markStatus(state, params.task ?? "", "completed", runCtx.cwd)?.content ?? "No task matched";
					case "drop_task": return markStatus(state, params.task ?? "", "abandoned", runCtx.cwd)?.content ?? "No task matched";
					case "remove_task": { const task = findTask(state, params.task ?? ""); if (!task) return "No task matched"; state.tasks = state.tasks.filter((candidate) => candidate.id !== task.id); updatePanelAfterTaskChange(state, runCtx.cwd); return task.content; }
					case "append_note": { const task = findTaskOrActive(state, params.task ?? ""); if (!task) return "No task matched"; task.notes.push(params.note ?? ""); return task.content; }
					case "set_panel": if (params.panel === "hidden") userHideTaskPanel(state); else userShowTaskPanel(state, params.panel === "expanded" ? "expanded" : "compact"); return `Panel ${state.panel}`;
					default: return "No task action matched";
				}
			});
			const summary = toolResultSummary(params.action, message, state);
			const deferAllCompleteDisplay = state.tasks.length > 0 && remainingCount(state) === 0 && !summary.startsWith("No task");
			pendingCompletionMessage = deferAllCompleteDisplay ? { action: params.action, summary } : undefined;
			return { content: [{ type: "text", text: toolResultContent(summary, state, runCtx.cwd) }], details: { action: params.action, deferDisplay: deferAllCompleteDisplay, message, summary, state: cloneState(state) } };
		},
		renderCall(_args, theme) {
			return compactToolOutput ? singleLine("") : singleLine(theme.fg("toolTitle", "tasks_write"));
		},
		renderResult(result, _options, theme) {
			if (result.details?.deferDisplay) return singleLine("");
			const summary = result.details?.summary ?? result.content?.find((part: any) => part?.type === "text")?.text?.replace(/^•\s*/, "") ?? "tasks updated";
			const action = result.details?.action ?? "";
			if (compactToolOutput) return singleLine(renderTaskToolSummary(summary, action, theme));
			return singleLine(theme.fg("text", `• ${summary}`));
		},
	});

	pi.on("session_start", (_event, ctx) => {
		restore(ctx);
	});
	pi.on("session_tree", (_event, ctx) => restore(ctx));
	pi.on("context", (event, ctx) => {
		let latestContextIndex = -1;
		for (let index = 0; index < event.messages.length; index++) {
			if ((event.messages[index] as any)?.customType === TASK_CONTEXT_TYPE) latestContextIndex = index;
		}
		const messages = event.messages.filter((message: any, index: number) => {
			if (message?.customType !== TASK_CONTEXT_TYPE) return true;
			if (!settingBoolean("showWorkflowReminder", true, ctx.cwd) || remainingCount(state) === 0) return false;
			return index === latestContextIndex;
		});
		return messages.length === event.messages.length ? undefined : { messages };
	});
	pi.on("before_agent_start", (event, ctx) => {
		if (!settingBoolean("showWorkflowReminder", true, ctx.cwd) || remainingCount(state) === 0) return;
		return {
			message: { customType: TASK_CONTEXT_TYPE, content: taskContextMessage(state), display: false },
			systemPrompt: `${event.systemPrompt}\n\n${workflowReminder(state)}`,
		};
	});
	pi.on("agent_end", (_event, ctx) => {
		if (pendingCompletionMessage && remainingCount(state) === 0) {
			const completion = pendingCompletionMessage;
			pendingCompletionMessage = undefined;
			pi.sendMessage({ customType: TASK_COMPLETE_MESSAGE_TYPE, content: completion.summary, display: true, details: completion }, { triggerTurn: false });
			return;
		}
		pendingCompletionMessage = undefined;
		if (!settingBoolean("showIncompleteReminder", true, ctx.cwd) || remainingCount(state) === 0) return;
		const now = Date.now();
		if (now - lastReminderAt > 60_000) {
			lastReminderAt = now;
			ctx.ui.notify(`${remainingCount(state)} task(s) still incomplete. ${workflowReminder(state)}`, "info");
		}
	});
	pi.on("session_shutdown", (_event, ctx) => setMiniDashboardWidget(ctx, WIDGET_KEY, MINI_DASHBOARD_RANK.TASKS, undefined));

	const toggle = async (ctx: ExtensionContext) => {
		cycleTaskPanelVisibility(state);
		persist();
		syncWidget(ctx);
	};
	const alternateShortcut = settingString("alternateShortcut", "alt+t");
	if (alternateShortcut !== "none") {
		pi.registerShortcut(alternateShortcut, { description: "Toggle task panel", handler: async (ctx) => toggle(ctx as ExtensionContext) });
	}
	if (settingBoolean("takeoverCtrlT", false)) {
		pi.registerShortcut("ctrl+t", { description: "Toggle task panel (vstack takeover)", handler: async (ctx) => toggle(ctx as ExtensionContext) });
	}
	const managerShortcut = settingString("managerShortcut", "alt+shift+t");
	if (managerShortcut !== "none") {
		pi.registerShortcut(managerShortcut, { description: "Open the task manager popup", handler: async (ctx) => manage(ctx as ExtensionContext) });
	}
	if (managerShortcut.toLowerCase() !== "f4") {
		pi.registerShortcut("f4", { description: "Open the task manager popup", handler: async (ctx) => manage(ctx as ExtensionContext) });
	}
}
