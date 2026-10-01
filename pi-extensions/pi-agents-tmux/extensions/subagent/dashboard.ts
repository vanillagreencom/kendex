import { taskStatus } from "./outcomes.js";
import * as path from "node:path";
import { type Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import {
	ansiGreen,
	ansiMagenta,
	ansiYellow,
	formatUsageStatsForDashboard,
	oneLinePreview,
	padAnsi,
	sessionModeChipLabel,
	simpleFrame,
	subagentBranch,
	subagentStem,
} from "./format.js";
import {
	animateSpinnersEnabled,
	dashboardEnabled,
	dashboardMaxItems,
	dashboardShortcut,
	formatShortcutHint,
	popupShortcut,
} from "./settings.js";
import {
	type DashboardKind,
	ICONS,
	PACKAGE_ID,
	type PaneTaskStatus,
	type SubagentDashboardItem,
	type SubagentDashboardState,
	type UsageStats,
} from "./types.js";
import { glyphs, glyphStyle } from "./glyphs.js";
import { ACTIVITY_MAX_CHARS } from "./transcript-tail.js";
import { inputDeliveryLabel, oneLine } from "./transcripts.js";

export function dashboardKindLabel(kind: DashboardKind): string {
	return kind === "oneshot" ? "bg" : kind;
}

export function dashboardStatusFor(rawStatus: PaneTaskStatus | "running" | "waiting", _kind: DashboardKind): SubagentDashboardItem["status"] {
	// Persistent panes stay alive after each task, but the dashboard should reflect
	// the latest task lifecycle. A later queued/running record for the same pane
	// replaces this item and moves it back to working.
	return rawStatus;
}

export function isDashboardWorkingStatus(status: SubagentDashboardItem["status"]): boolean {
	return taskStatus(status).phase === "working";
}

export function isDashboardAnimatingStatus(status: SubagentDashboardItem["status"]): boolean {
	return taskStatus(status).animate === true;
}

export function isDashboardAttentionStatus(status: SubagentDashboardItem["status"]): boolean {
	return taskStatus(status).rank === 1;
}

function dashboardStatusRank(status: SubagentDashboardItem["status"]): number {
	return taskStatus(status).rank;
}

export function sortDashboardItems(items: SubagentDashboardItem[]): SubagentDashboardItem[] {
	return [...items].sort((a, b) => {
		const rank = dashboardStatusRank(a.status) - dashboardStatusRank(b.status);
		if (rank !== 0) return rank;
		const aKey = a.startedAt ?? a.taskId;
		const bKey = b.startedAt ?? b.taskId;
		if (aKey !== bKey) return aKey > bKey ? -1 : 1;
		return a.agent.localeCompare(b.agent) || a.taskId.localeCompare(b.taskId);
	});
}

function timestampValue(value: string | undefined): number {
	const parsed = Date.parse(value ?? "");
	return Number.isFinite(parsed) ? parsed : 0;
}

function taskIdTimestampValue(taskId: string | undefined): number {
	const raw = taskId?.match(/-(\d{10,})-/)?.[1];
	if (!raw) return 0;
	const parsed = Number.parseInt(raw, 10);
	return Number.isFinite(parsed) ? parsed : 0;
}

function dashboardTaskStartValue(item: SubagentDashboardItem): number {
	return timestampValue(item.startedAt) || taskIdTimestampValue(item.taskId) || timestampValue(item.completedAt) || timestampValue(item.updatedAt);
}

export function shouldReplaceDashboardItem(existing: SubagentDashboardItem | undefined, next: SubagentDashboardItem): boolean {
	if (!existing) return true;
	if (existing.kind !== "pane" || next.kind !== "pane") return true;
	if (existing.taskId === next.taskId) return true;

	// A persistent pane can carry many completed tasks in one transcript, but the
	// mini dashboard intentionally collapses that pane session to one row. Full
	// registry syncs iterate historical records from oldest to newest; without
	// this guard, every poll briefly rewinds the collapsed row to an old task and
	// the row jumps down the completed list before the newest task restores it.
	const existingStart = dashboardTaskStartValue(existing);
	const nextStart = dashboardTaskStartValue(next);
	if (existingStart > 0 && nextStart > 0 && nextStart < existingStart) return false;
	if (existingStart > 0 && nextStart > 0 && nextStart === existingStart && next.taskId < existing.taskId) return false;
	return true;
}

const WORKING_SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

function workingSpinnerFrame(): string {
	if (glyphStyle() === "ascii") return "*";
	return WORKING_SPINNER_FRAMES[Math.floor(Date.now() / 120) % WORKING_SPINNER_FRAMES.length] ?? glyphs().emptyBullet.trim();
}

export function dashboardStatusIcon(status: SubagentDashboardItem["status"], theme: Theme, options: { animateSpinners?: boolean } = {}): string {
	const animateSpinners = options.animateSpinners ?? true;
	const ascii = glyphStyle() === "ascii";
	const presentation = taskStatus(status);
	if (isDashboardAnimatingStatus(status)) return theme.fg(presentation.tone, animateSpinners ? workingSpinnerFrame() : presentation.icon);
	const icon = !ascii ? presentation.icon : presentation.icon === ICONS.check ? glyphs().ok : presentation.icon === ICONS.times ? glyphs().fail : presentation.icon === ICONS.warning ? glyphs().warn : presentation.icon;
	return theme.fg(presentation.tone, icon);
}

export function dashboardStatusText(item: SubagentDashboardItem, theme: Theme): string {
	const presentation = taskStatus(item.status);
	return theme.fg(presentation.tone, item.status === "waiting" ? "waiting" : presentation.label);
}

/**
 * The activity line of a working row. It reads only the snapshot the poll
 * cached on the item: render runs on the spinner cadence and never reads a
 * transcript file.
 */
export function latestDashboardActivity(item: SubagentDashboardItem): string | undefined {
	if (item.activity) return item.activity;
	if (item.status === "queued") return item.task ? `queued: ${oneLine(item.task, ACTIVITY_MAX_CHARS)}` : "queued";
	return undefined;
}

function outgoingDashboardMessage(item: SubagentDashboardItem): string | undefined {
	if (isDashboardWorkingStatus(item.status)) return undefined;
	const message = item.message?.trim();
	if (!message || item.messageProvenance === "placeholder" || item.messageProvenance === "task-echo-fallback") return undefined;
	if (item.task && oneLine(message, ACTIVITY_MAX_CHARS) === oneLine(item.task, ACTIVITY_MAX_CHARS)) return undefined;
	return message;
}

function expandedDashboardMessageLines(item: SubagentDashboardItem, stem: string, theme: Theme, width: number, cwd?: string): string[] {
	const entries: Array<{ direction: "->" | "<-"; text: string; delivery?: string }> = [];
	if (item.task?.trim()) entries.push({ direction: "->", text: item.task, delivery: inputDeliveryLabel(item.deliverAs) });
	const outgoing = outgoingDashboardMessage(item);
	if (outgoing) entries.push({ direction: "<-", text: outgoing });
	const maxChars = Math.max(48, width - 24);
	return entries.map((entry, index) => {
		const branch = subagentBranch(theme, index === entries.length - 1 ? "└" : "├", cwd);
		const direction = entry.direction === "->" ? ansiYellow("->") : ansiGreen("<-");
		const delivery = entry.delivery ? `${theme.fg("muted", `${entry.delivery} `)}` : "";
		return `${stem}${branch}${direction} ${delivery}${theme.fg("toolOutput", oneLinePreview(entry.text, maxChars))}`;
	});
}

function dashboardFrame(lines: string[], width: number, theme: Theme): string[] {
	return simpleFrame(lines, width, theme);
}

export function shortRuntimeSessionIdFromPath(filePath: string | undefined): string {
	if (!filePath) return "session";
	const parts = path.normalize(filePath).split(path.sep).filter(Boolean);
	const rootIndex = parts.lastIndexOf(PACKAGE_ID);
	const sessionsIndex = rootIndex >= 0 ? parts.indexOf("sessions", rootIndex + 1) : parts.lastIndexOf("sessions");
	const parentSession = sessionsIndex >= 0 ? parts[sessionsIndex + 1] : undefined;
	return parentSession ? oneLinePreview(parentSession, 8) : "session";
}

export function shortTaskRef(taskId: string | undefined): string {
	if (!taskId) return "task";
	const hash = taskId.match(/-([a-f0-9]{8,})$/)?.[1]?.slice(0, 8);
	const timestamp = taskId.match(/-(\d{10,})-/)?.[1];
	return hash ? `${timestamp ? `${timestamp.slice(-6)}-` : ""}${hash}` : oneLinePreview(taskId, 16);
}

export function dashboardTraceRef(item: Pick<SubagentDashboardItem, "agent" | "taskId" | "transcriptPath" | "kind">): string {
	const session = shortRuntimeSessionIdFromPath(item.transcriptPath);
	if (item.kind === "pane") return `${session}/${item.agent}/${shortTaskRef(item.taskId)}`;
	return dashboardTranscriptRef(item.transcriptPath) || `${session}/${item.agent}/${shortTaskRef(item.taskId)}`;
}

export function dashboardTranscriptRef(filePath: string | undefined): string {
	if (!filePath) return "";
	const parts = path.normalize(filePath).split(path.sep).filter(Boolean);
	const rootIndex = parts.lastIndexOf(PACKAGE_ID);
	const sessionsIndex = rootIndex >= 0 ? parts.indexOf("sessions", rootIndex + 1) : parts.lastIndexOf("sessions");
	const parentSession = sessionsIndex >= 0 ? parts[sessionsIndex + 1] : undefined;
	const shortSession = parentSession ? oneLinePreview(parentSession, 8) : "session";
	const runtimeRelative = sessionsIndex >= 0 && parentSession ? parts.slice(sessionsIndex + 2) : [];
	const file = path.basename(filePath, path.extname(filePath));
	if (runtimeRelative[0] === "sessions") return `${shortSession}/${file}`;
	if (runtimeRelative[0] === "transcripts" && runtimeRelative[1]) {
		const hash = file.match(/-([a-f0-9]{8,})$/)?.[1]?.slice(0, 8);
		const timestamp = file.match(/-(\d{10,})-/)?.[1];
		const suffix = hash ? `${timestamp ? `${timestamp.slice(-6)}-` : ""}${hash}` : "";
		return `${shortSession}/${runtimeRelative[1]}${suffix ? `/${suffix}` : ""}`;
	}
	return `${shortSession}/${file}`;
}

export function dashboardTranscriptLabel(items: SubagentDashboardItem[], cwd: string): string {
	const refs = [...new Set(items.map((item) => dashboardTraceRef(item)).filter(Boolean))];
	void cwd;
	if (refs.length === 0) return "transcripts available";
	if (refs.length === 1) return `transcript ${refs[0]}`;
	const sessionRefs = [...new Set(refs.map((ref) => ref.split("/")[0]).filter(Boolean))];
	if (sessionRefs.length === 1) return `${refs.length} transcripts · session ${sessionRefs[0]}`;
	return `${refs.length} transcripts · ${refs[0]} +${refs.length - 1}`;
}

// Disambiguate repeat bg launches: the second "reviewer" of the session
// renders as "reviewer 2" so two rows with the same agent name aren't
// indistinguishable. Uses taskId for identity and start-time for occurrence
// order; mirrors browser.ts dashboardDisplayLabels.
function dashboardLabelsForItems(items: SubagentDashboardItem[], persistentTaskNumbers?: Map<string, number>): Map<string, string> {
	// Mirror browser.ts dashboardDisplayLabels: when a persistent #N is
	// available from the task registry, use it so the same task reads as
	// the same `<agent> #N` in the mini widget, the /agents popup's
	// active-list, its task-children rows, and the Inspector header.
	// Fall back to in-memory occurrence count for items that haven't been
	// persisted yet (rare; mid-dispatch).
	const total = new Map<string, number>();
	for (const item of items) total.set(item.agent, (total.get(item.agent) ?? 0) + 1);
	const occurrence = new Map<string, number>();
	const labels = new Map<string, string>();
	const stable = [...items].sort((a, b) => {
		const aKey = a.startedAt ?? a.taskId;
		const bKey = b.startedAt ?? b.taskId;
		if (aKey !== bKey) return aKey < bKey ? -1 : 1;
		return a.agent.localeCompare(b.agent) || a.taskId.localeCompare(b.taskId);
	});
	for (const item of stable) {
		const next = (occurrence.get(item.agent) ?? 0) + 1;
		occurrence.set(item.agent, next);
		const persistentN = persistentTaskNumbers?.get(item.taskId);
		// Persistent numbers are session-scoped, so two bg one-shot tasks for the
		// same agent both land on session-local `1`. Fall through to the
		// in-memory occurrence counter unless the persistent number actually
		// disambiguates (`> 1`). `#1` is always suppressed.
		const n = persistentN !== undefined && persistentN > 1 ? persistentN : next;
		const showNumber = (total.get(item.agent) ?? 1) > 1 && n > 1;
		const label = showNumber ? `${item.agent} #${n}` : item.agent;
		labels.set(item.taskId, label);
	}
	return labels;
}

export function renderDashboardWidgetLines(state: SubagentDashboardState, theme: Theme, cwd: string, width: number, persistentTaskNumbers?: Map<string, number>): string[] {
	const items = sortDashboardItems(Object.values(state.items));
	const animateSpinners = animateSpinnersEnabled(cwd);
	// Caller owns registry reads. Render can run on a 120ms spinner cadence, so
	// never synchronously read/parse tasks.json here.
	const displayLabels = dashboardLabelsForItems(items, persistentTaskNumbers);
	if (!dashboardEnabled(cwd) || !state.visible || items.length === 0) return [];
	const working = items.filter((item) => isDashboardWorkingStatus(item.status)).length;
	const done = items.filter((item) => item.status === "completed").length;
	const attention = items.filter((item) => isDashboardAttentionStatus(item.status)).length;
	const shortcut = dashboardShortcut(cwd);
	const popup = popupShortcut(cwd);
	const toggleHint = shortcut === "none" ? "" : theme.fg("dim", ` · ${formatShortcutHint(shortcut)} toggle`);
	const popupHint = popup === "none" ? "" : theme.fg("dim", ` · ${formatShortcutHint(popup)} popup`);
	const hint = `${toggleHint}${popupHint}`;
	const headerParts = [
		theme.fg("success", `${done} completed`),
		theme.fg("warning", `${working} working`),
		attention ? theme.fg("error", `${attention} attention`) : "",
	].filter(Boolean);
	const title = `${theme.fg("customMessageLabel", theme.bold("Agents"))} ${theme.fg("muted", headerParts.join(" · "))}${hint}`;
	const lines = [title];
	const aggregateDashboardUsage = (entries: SubagentDashboardItem[]): UsageStats | undefined => {
		const total: UsageStats = { input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
		let any = false;
		for (const entry of entries) {
			if (!entry.usage) continue;
			any = true;
			total.input += entry.usage.input || 0;
			total.output += entry.usage.output || 0;
			total.reasoning = (total.reasoning ?? 0) + (entry.usage.reasoning || 0);
			total.cacheRead += entry.usage.cacheRead || 0;
			total.cacheWrite += entry.usage.cacheWrite || 0;
			total.cost += entry.usage.cost || 0;
			total.contextTokens = Math.max(total.contextTokens, entry.usage.contextTokens || 0);
			total.turns = (total.turns ?? 0) + (entry.usage.turns ?? 0);
		}
		return any ? total : undefined;
	};
	const dotSep = theme.fg("dim", " · ");
	if (items.every((item) => item.status === "completed" && !item.reuseNotice) && state.mode === "compact") {
		const aggregated = aggregateDashboardUsage(items);
		const usageParts = aggregated ? formatUsageStatsForDashboard(aggregated) : [];
		const body = usageParts.length > 0
			? usageParts.map((part) => theme.fg("dim", part)).join(dotSep)
			: theme.fg("dim", `${items.length} transcript${items.length === 1 ? "" : "s"}`);
		lines.push(`${subagentBranch(theme, "└", cwd)}${body}`);
		return dashboardFrame(lines.map((line) => truncateToWidth(line, Math.max(1, width - 4), "")), Math.max(1, width), theme);
	}
	const maxItems = state.mode === "compact" || state.collapsed ? 1 : state.mode === "normal" ? Math.min(3, dashboardMaxItems(cwd)) : dashboardMaxItems(cwd);
	const shown = items.slice(0, maxItems);
	const shownLabels = shown.map((item) => displayLabels.get(item.taskId) ?? item.agent);
	const nameWidth = Math.min(24, Math.max(0, ...shownLabels.map((label) => visibleWidth(label))));
	for (const [index, item] of shown.entries()) {
		const branch = subagentBranch(theme, index === shown.length - 1 && items.length <= shown.length ? "└" : "├", cwd);
		const name = padAnsi(ansiMagenta(theme.bold(shownLabels[index])), nameWidth);
		const rowParts: string[] = [
			dashboardStatusText(item, theme),
			theme.fg("dim", dashboardKindLabel(item.kind)),
		];
		const sessionChip = sessionModeChipLabel(item);
		if (sessionChip) rowParts.push(theme.fg("dim", sessionChip));
		if (item.bridge) rowParts.push(theme.fg("success", "bridge"));
		if (isDashboardWorkingStatus(item.status)) {
			const activity = latestDashboardActivity(item);
			if (activity) rowParts.push(theme.fg("toolOutput", activity));
		}
		if (item.usage) {
			for (const part of formatUsageStatsForDashboard(item.usage)) {
				rowParts.push(theme.fg("dim", part));
			}
		}
		lines.push(`${branch}${dashboardStatusIcon(item.status, theme, { animateSpinners })} ${name}${dotSep}${rowParts.join(dotSep)}`);
		if (taskStatus(item.status).diagnostic || item.reuseNotice) {
			const message = outgoingDashboardMessage(item);
			if (message || item.reuseNotice) {
				const preview = oneLinePreview(item.reuseNotice && !message?.includes(item.reuseNotice) ? [item.reuseNotice, message].filter(Boolean).join("\n") : message ?? item.reuseNotice!, 512);
				lines.push(...wrapTextWithAnsi(theme.fg("toolOutput", preview), Math.max(1, width - 8)).map((line) => `    ${line}`));
			}
		}
		if (state.mode === "expanded" && !state.collapsed) {
			lines.push(...expandedDashboardMessageLines(item, subagentStem(theme, index === shown.length - 1 && items.length <= shown.length, cwd), theme, width, cwd));
		}
	}
	const hidden = items.length - shown.length;
	if (hidden > 0) lines.push(`${subagentBranch(theme, "└", cwd)}${theme.fg("muted", `… ${hidden} more · /agents toggle`)}`);
	if (state.mode === "expanded" && !state.collapsed) {
		const aggregated = aggregateDashboardUsage(items);
		if (aggregated) {
			const totalParts = formatUsageStatsForDashboard(aggregated).map((part) => theme.fg("dim", part)).join(dotSep);
			if (totalParts.length > 0) {
				lines.push(`${subagentBranch(theme, "└", cwd)}${theme.fg("dim", "Total")}${dotSep}${totalParts}`);
			}
		}
	}
	return dashboardFrame(lines.map((line) => truncateToWidth(line, Math.max(1, width - 4), "")), Math.max(1, width), theme);
}
