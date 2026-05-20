import * as fs from "node:fs";
import * as path from "node:path";
import { type Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { loadTaskRegistrySync, taskNumberById } from "./task-records.js";
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
	return status === "running" || status === "queued" || status === "waiting";
}

export function isDashboardAnimatingStatus(status: SubagentDashboardItem["status"]): boolean {
	return status === "running";
}

export function isDashboardAttentionStatus(status: SubagentDashboardItem["status"]): boolean {
	return status === "failed" || status === "blocked" || status === "needs_completion" || status === "unknown";
}

function dashboardStatusRank(status: SubagentDashboardItem["status"]): number {
	if (isDashboardWorkingStatus(status)) return 0;
	if (isDashboardAttentionStatus(status)) return 1;
	if (status === "completed") return 2;
	return 3;
}

export function sortDashboardItems(items: SubagentDashboardItem[]): SubagentDashboardItem[] {
	return [...items].sort((a, b) => {
		const rank = dashboardStatusRank(a.status) - dashboardStatusRank(b.status);
		if (rank !== 0) return rank;
		const aKey = a.startedAt ?? a.taskId;
		const bKey = b.startedAt ?? b.taskId;
		if (aKey !== bKey) return aKey < bKey ? -1 : 1;
		return a.agent.localeCompare(b.agent) || a.taskId.localeCompare(b.taskId);
	});
}

const WORKING_SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

function workingSpinnerFrame(): string {
	if (glyphStyle() === "ascii") return "*";
	return WORKING_SPINNER_FRAMES[Math.floor(Date.now() / 120) % WORKING_SPINNER_FRAMES.length] ?? glyphs().emptyBullet.trim();
}

export function dashboardStatusIcon(status: SubagentDashboardItem["status"], theme: Theme, options: { animateSpinners?: boolean } = {}): string {
	const animateSpinners = options.animateSpinners ?? true;
	const ascii = glyphStyle() === "ascii";
	if (status === "completed") return theme.fg("success", ascii ? glyphs().ok : ICONS.check);
	if (status === "failed") return theme.fg("error", ascii ? glyphs().fail : ICONS.times);
	if (status === "blocked") return theme.fg("error", ascii ? glyphs().fail : ICONS.times);
	if (status === "needs_completion") return theme.fg("warning", ascii ? glyphs().warn : ICONS.warning);
	if (status === "running") return theme.fg("warning", animateSpinners ? workingSpinnerFrame() : ICONS.cog);
	if (status === "waiting") return theme.fg("warning", ICONS.clock);
	if (status === "queued") return theme.fg("warning", ICONS.clock);
	if (status === "unknown") return theme.fg("warning", ascii ? glyphs().warn : ICONS.warning);
	return theme.fg("accent", ascii ? glyphs().bullet.trim() : ICONS.circleFilled);
}

export function dashboardStatusText(item: SubagentDashboardItem, theme: Theme): string {
	if (item.status === "completed") return theme.fg("success", "completed");
	if (item.status === "failed") return theme.fg("error", "failed");
	if (item.status === "blocked") return theme.fg("warning", "blocked");
	if (item.status === "needs_completion") return theme.fg("warning", "needs completion");
	if (item.status === "running") return theme.fg("warning", "working");
	if (item.status === "waiting") return theme.fg("warning", "waiting");
	if (item.status === "queued") return theme.fg("warning", "queued");
	if (item.status === "unknown") return theme.fg("warning", "stale");
	return theme.fg("accent", item.status);
}

function recentTranscriptLines(filePath: string | undefined, maxBytes = 96 * 1024): string[] {
	if (!filePath) return [];
	let fd: number | undefined;
	try {
		const stat = fs.statSync(filePath);
		if (!stat.isFile() || stat.size <= 0) return [];
		const readBytes = Math.min(maxBytes, stat.size);
		const offset = Math.max(0, stat.size - readBytes);
		const buffer = Buffer.alloc(readBytes);
		fd = fs.openSync(filePath, "r");
		fs.readSync(fd, buffer, 0, readBytes, offset);
		const lines = buffer.toString("utf-8").split(/\r?\n/).filter((line) => line.trim());
		if (offset > 0 && lines.length > 0) lines.shift();
		return lines;
	} catch {
		return [];
	} finally {
		if (fd !== undefined) {
			try { fs.closeSync(fd); } catch { /* ignore */ }
		}
	}
}

function compactActivityText(text: string, maxChars = 180): string {
	const compact = text.replace(/\s+/g, " ").trim();
	return compact.length > maxChars ? `${compact.slice(0, maxChars - 1)}…` : compact;
}

type ActivityContent = { kind: "text" | "tool"; text: string };

function toolNameFromPart(part: any): string | undefined {
	return typeof part?.name === "string" && part.name.trim()
		? part.name.trim()
		: typeof part?.toolName === "string" && part.toolName.trim()
			? part.toolName.trim()
			: undefined;
}

function activityContentFromMessageContent(content: unknown): ActivityContent | undefined {
	if (typeof content === "string") return { kind: "text", text: compactActivityText(content) };
	if (!Array.isArray(content)) return undefined;
	const tool = content.find((part: any) => part?.type === "toolCall" || part?.type === "tool_call" || part?.type === "tool-call");
	if (tool) return { kind: "tool", text: toolNameFromPart(tool) ?? "call" };
	const text = content.find((part: any) => part?.type === "text" && typeof part.text === "string");
	if (text?.text) return { kind: "text", text: compactActivityText(String(text.text)) };
	return undefined;
}

function activityFromParsedEvent(parsed: any): string | undefined {
	if (!parsed || typeof parsed !== "object") return undefined;
	if (typeof parsed.text === "string" && parsed.stream === "stderr") return `stderr: ${compactActivityText(parsed.text)}`;
	if (parsed.type === "exit" && typeof parsed.code !== "undefined") return `exit ${parsed.code}`;
	const event = parsed.event && typeof parsed.event === "object" ? parsed.event : parsed;
	const inner = event?.event && typeof event.event === "object" ? event.event : event;
	const type = typeof inner?.type === "string" ? inner.type : undefined;
	const toolName = typeof inner?.toolName === "string" ? inner.toolName : toolNameFromPart(inner?.toolCall) ?? toolNameFromPart(inner?.tool_call);
	if (type === "tool_execution_start" && toolName) return `tool: ${toolName}`;
	if ((type === "tool_execution_end" || type === "tool_result_end") && toolName) return `tool: ${toolName}`;
	if (type === "tool_result_end") return "tool: result";
	const msg = inner?.message && typeof inner.message === "object" ? inner.message : undefined;
	if (msg) {
		const rendered = activityContentFromMessageContent(msg.content);
		if (rendered?.kind === "tool") return `tool: ${rendered.text}`;
		if (rendered?.kind === "text" && msg.role === "assistant") return `said: ${rendered.text}`;
		if (rendered?.kind === "text" && msg.role === "tool") return `tool: ${rendered.text}`;
		return undefined;
	}
	if (type === "message_end") return "message complete";
	return undefined;
}

export function latestDashboardActivity(item: SubagentDashboardItem): string | undefined {
	for (const line of recentTranscriptLines(item.transcriptPath).reverse()) {
		try {
			const activity = activityFromParsedEvent(JSON.parse(line));
			if (activity) return activity;
		} catch {
			const compact = compactActivityText(line);
			if (compact) return compact;
		}
	}
	if (item.status === "queued") return item.task ? `queued: ${compactActivityText(item.task)}` : "queued";
	return undefined;
}

function outgoingDashboardMessage(item: SubagentDashboardItem): string | undefined {
	if (isDashboardWorkingStatus(item.status)) return undefined;
	const message = item.message?.trim();
	if (!message || item.messageProvenance === "placeholder" || item.messageProvenance === "task-echo-fallback") return undefined;
	if (item.task && compactActivityText(message) === compactActivityText(item.task)) return undefined;
	return message;
}

function expandedDashboardMessageLines(item: SubagentDashboardItem, stem: string, theme: Theme, width: number, cwd?: string): string[] {
	const entries: Array<{ direction: "->" | "<-"; text: string }> = [];
	if (item.task?.trim()) entries.push({ direction: "->", text: item.task });
	const outgoing = outgoingDashboardMessage(item);
	if (outgoing) entries.push({ direction: "<-", text: outgoing });
	const maxChars = Math.max(48, width - 24);
	return entries.map((entry, index) => {
		const branch = subagentBranch(theme, index === entries.length - 1 ? "└" : "├", cwd);
		const direction = entry.direction === "->" ? ansiYellow("->") : ansiGreen("<-");
		return `${stem}${branch}${direction} ${theme.fg("toolOutput", oneLinePreview(entry.text, maxChars))}`;
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

// Disambiguate repeat bg launches: the 2nd "reviewer-arch" of the session
// renders as "reviewer-arch 2" so two rows with the same agent name aren't
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

export function renderDashboardWidgetLines(state: SubagentDashboardState, theme: Theme, cwd: string, width: number, runtimeRoot?: string): string[] {
	const items = sortDashboardItems(Object.values(state.items));
	const animateSpinners = animateSpinnersEnabled(cwd);
	// Cheap sync read of the persisted task registry once per widget render
	// gives the mini widget the same `<agent> #N` numbers as the popup, so
	// a task reads identically across surfaces. Skipped when runtimeRoot is
	// missing (legacy call sites); labels fall back to local counter.
	const persistentTaskNumbers = runtimeRoot
		? taskNumberById(Object.values(loadTaskRegistrySync(runtimeRoot)))
		: undefined;
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
		const total: UsageStats = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
		let any = false;
		for (const entry of entries) {
			if (!entry.usage) continue;
			any = true;
			total.input += entry.usage.input || 0;
			total.output += entry.usage.output || 0;
			total.cacheRead += entry.usage.cacheRead || 0;
			total.cacheWrite += entry.usage.cacheWrite || 0;
			total.cost += entry.usage.cost || 0;
			total.contextTokens = Math.max(total.contextTokens, entry.usage.contextTokens || 0);
			total.turns = (total.turns ?? 0) + (entry.usage.turns ?? 0);
		}
		return any ? total : undefined;
	};
	const dotSep = theme.fg("dim", " · ");
	if (working === 0 && state.mode === "compact") {
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
		if (item.usage) {
			for (const part of formatUsageStatsForDashboard(item.usage)) {
				rowParts.push(theme.fg("dim", part));
			}
		}
		if (isDashboardWorkingStatus(item.status)) {
			const activity = latestDashboardActivity(item);
			if (activity) rowParts.push(theme.fg("toolOutput", activity));
		}
		lines.push(`${branch}${dashboardStatusIcon(item.status, theme, { animateSpinners })} ${name}${dotSep}${rowParts.join(dotSep)}`);
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
