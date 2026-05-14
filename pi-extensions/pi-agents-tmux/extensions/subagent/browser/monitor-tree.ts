import { type Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";
import { dashboardStatusIcon } from "../dashboard.js";
import {
	ansiMagenta,
	shortTaskSuffix,
	sessionModeChipLabel,
	truncateSessionKeyForChip,
} from "../format.js";
import { paneCompletionTone } from "../renderers.js";
import { taskNumberById } from "../task-records.js";
import {
	ICONS,
	type AgentBrowserUiState,
	type MonitorFilter,
	type PaneTaskRecord,
	type PaneTaskRegistry,
	type PaneTaskStatus,
	type UsageStats,
} from "../types.js";
import { agentActivePill, agentInactivePill, agentPad, agentPaneTitle } from "./shared.js";

export function formatRelativeTime(iso: string | undefined): string {
	if (!iso) return "—";
	const ts = Date.parse(iso);
	if (!Number.isFinite(ts)) return "—";
	const delta = Date.now() - ts;
	if (delta < 0) return "just now";
	const sec = Math.floor(delta / 1000);
	if (sec < 60) return `${sec}s ago`;
	const min = Math.floor(sec / 60);
	if (min < 60) return `${min}m ago`;
	const hr = Math.floor(min / 60);
	if (hr < 24) return `${hr}h ago`;
	const day = Math.floor(hr / 24);
	if (day < 30) return `${day}d ago`;
	const mo = Math.floor(day / 30);
	if (mo < 12) return `${mo}mo ago`;
	return new Date(ts).toISOString().slice(0, 10);
}

export function monitorStatusIcon(status: PaneTaskStatus, theme: Theme): string {
	if (status === "completed") return theme.fg("success", ICONS.check);
	if (status === "failed") return theme.fg("error", ICONS.times);
	if (status === "blocked") return theme.fg("warning", ICONS.times);
	if (status === "running") return dashboardStatusIcon("running", theme);
	if (status === "queued") return theme.fg("warning", ICONS.clock);
	return theme.fg("muted", "·");
}

export function monitorStatusText(status: PaneTaskStatus, theme: Theme): string {
	return theme.fg(paneCompletionTone(status), status);
}

export type MonitorSessionType = "pane" | "bg-lane" | "bg-one-shot";

export interface MonitorSessionGroup {
	agent: string;
	createdAt: string;
	id: string;
	isActive: boolean;
	isCompleted: boolean;
	kind: "pane" | "oneshot";
	latestAt: string;
	paneId?: string;
	records: PaneTaskRecord[];
	sessionKey?: string;
	sessionMode?: PaneTaskRecord["sessionMode"];
	taskCount: number;
	transcriptPath?: string;
	type: MonitorSessionType;
	usage?: UsageStats;
}

export type MonitorTreeRow =
	| { key: string; kind: "section"; label: string }
	| { group: MonitorSessionGroup; key: string; kind: "session" }
	| { group: MonitorSessionGroup; key: string; kind: "task"; record: PaneTaskRecord };

const MONITOR_FILTERS: MonitorFilter[] = ["active", "completed", "all"];

export function sortedMonitorRecords(registry: PaneTaskRegistry): PaneTaskRecord[] {
	return Object.values(registry)
		.filter((record) => record.taskId && record.agent)
		.sort((a, b) => recordLatestTimestamp(b) - recordLatestTimestamp(a));
}

function recordClockTime(record: PaneTaskRecord): string {
	const raw = record.completedAt ?? record.updatedAt ?? record.createdAt;
	if (!raw) return "--:--";
	const date = new Date(raw);
	if (!Number.isFinite(date.getTime())) return "--:--";
	return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

export function monitorRecordLabel(record: PaneTaskRecord, taskNumbers: Map<string, number>): string {
	const number = taskNumbers.get(record.taskId);
	const numberText = number ? ` #${number}` : "";
	return `${record.agent}${numberText} · ${recordClockTime(record)} · ${shortTaskSuffix(record.taskId)}`;
}

export function monitorTaskRowLabel(record: PaneTaskRecord, taskNumbers: Map<string, number>): string {
	const number = taskNumbers.get(record.taskId);
	const numberText = number ? `#${number}` : "Task";
	return `${numberText} · ${recordClockTime(record)} · ${shortTaskSuffix(record.taskId)}`;
}

function recordLatestTimestamp(record: PaneTaskRecord): number {
	const value = Date.parse(record.completedAt ?? record.updatedAt ?? record.createdAt ?? "");
	return Number.isFinite(value) ? value : 0;
}

export function recordMonitorKind(record: PaneTaskRecord): "pane" | "oneshot" {
	if (record.kind === "pane" || record.kind === "oneshot") return record.kind;
	if (record.paneId || record.inboxFile || record.processingFile || record.doneFile || record.outboxFile || record.completionSourcePath || record.completionArchivePath) return "pane";
	return "oneshot";
}

function monitorStatusIsActive(status: PaneTaskStatus | string | undefined): boolean {
	return !monitorStatusIsTerminal(status);
}

function monitorStatusIsTerminal(status: PaneTaskStatus | string | undefined): boolean {
	return status === "completed" || status === "failed" || status === "blocked" || status === "needs_completion" || status === "cancelled";
}

function monitorSessionKey(record: PaneTaskRecord): { id: string; type: MonitorSessionType } {
	const kind = recordMonitorKind(record);
	if (kind === "pane") {
		if (record.paneId?.trim()) return { id: `pane:${record.paneId.trim()}`, type: "pane" };
		if (record.transcriptPath?.trim()) return { id: `pane-transcript:${record.transcriptPath.trim()}`, type: "pane" };
		return { id: `pane-task:${record.taskId}`, type: "pane" };
	}
	if (record.sessionKey?.trim()) return { id: `bg-lane:${record.agent}:${record.sessionKey.trim()}`, type: "bg-lane" };
	return { id: `bg-one-shot:${record.taskId}`, type: "bg-one-shot" };
}

function usageSum(records: PaneTaskRecord[]): UsageStats | undefined {
	const total: UsageStats = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
	let seen = false;
	for (const usage of records.map((record) => record.usage).filter(Boolean) as UsageStats[]) {
		seen = true;
		total.input += usage.input || 0;
		total.output += usage.output || 0;
		total.cacheRead += usage.cacheRead || 0;
		total.cacheWrite += usage.cacheWrite || 0;
		total.cost += usage.cost || 0;
		total.contextTokens += usage.contextTokens || 0;
		total.turns += usage.turns || 0;
	}
	return seen ? total : undefined;
}

export function buildMonitorSessionGroups(records: PaneTaskRecord[]): MonitorSessionGroup[] {
	const bySession = new Map<string, { records: PaneTaskRecord[]; type: MonitorSessionType }>();
	for (const record of records.filter((item) => item.taskId && item.agent)) {
		const session = monitorSessionKey(record);
		const bucket = bySession.get(session.id) ?? { records: [], type: session.type };
		bucket.records.push(record);
		bySession.set(session.id, bucket);
	}
	const groups: MonitorSessionGroup[] = [];
	for (const [id, bucket] of bySession) {
		const groupRecords = [...bucket.records].sort((a, b) => {
			const delta = recordLatestTimestamp(b) - recordLatestTimestamp(a);
			return delta !== 0 ? delta : b.taskId.localeCompare(a.taskId);
		});
		const latest = groupRecords[0];
		if (!latest) continue;
		const created = groupRecords.reduce((min, record) => Math.min(min, Date.parse(record.createdAt) || min), Number.POSITIVE_INFINITY);
		const latestAtTs = groupRecords.reduce((max, record) => Math.max(max, recordLatestTimestamp(record)), 0);
		const kind = bucket.type === "pane" ? "pane" : "oneshot";
		groups.push({
			agent: latest.agent,
			createdAt: Number.isFinite(created) ? new Date(created).toISOString() : latest.createdAt,
			id,
			isActive: groupRecords.some((record) => monitorStatusIsActive(record.status)),
			isCompleted: groupRecords.every((record) => monitorStatusIsTerminal(record.status)),
			kind,
			latestAt: latestAtTs ? new Date(latestAtTs).toISOString() : latest.completedAt ?? latest.updatedAt ?? latest.createdAt,
			paneId: groupRecords.find((record) => record.paneId)?.paneId,
			records: groupRecords,
			sessionKey: groupRecords.find((record) => record.sessionKey)?.sessionKey,
			sessionMode: latest.sessionMode,
			taskCount: groupRecords.length,
			transcriptPath: groupRecords.find((record) => record.transcriptPath)?.transcriptPath,
			type: bucket.type,
			usage: usageSum(groupRecords),
		});
	}
	return groups.sort((a, b) => {
		const delta = Date.parse(b.latestAt) - Date.parse(a.latestAt);
		return delta !== 0 ? delta : a.id.localeCompare(b.id);
	});
}

export function filteredMonitorSessionGroups(groups: MonitorSessionGroup[], filter: MonitorFilter): MonitorSessionGroup[] {
	if (filter === "active") return groups.filter((group) => group.isActive);
	if (filter === "completed") return groups.filter((group) => group.isCompleted);
	return groups;
}

export function monitorTreeRows(groups: MonitorSessionGroup[], filter: MonitorFilter, collapsedSessionIds: Set<string> = new Set()): MonitorTreeRow[] {
	const filtered = filteredMonitorSessionGroups(groups, filter);
	const rows: MonitorTreeRow[] = [];
	const pushGroup = (group: MonitorSessionGroup) => {
		rows.push({ group, key: group.id, kind: "session" });
		if (!collapsedSessionIds.has(group.id)) {
			for (const record of group.records) rows.push({ group, key: `${group.id}:${record.taskId}`, kind: "task", record });
		}
	};
	const pushSection = (label: string, sectionGroups: MonitorSessionGroup[]) => {
		if (filter === "all" && sectionGroups.length === 0) return;
		rows.push({ key: `section:${label.toLowerCase()}`, kind: "section", label: `${label} (${sectionGroups.length})` });
		for (const group of sectionGroups) pushGroup(group);
	};
	if (filter === "active") pushSection("Active", filtered);
	else if (filter === "completed") pushSection("Completed", filtered);
	else {
		pushSection("Active", groups.filter((group) => group.isActive));
		pushSection("Completed", groups.filter((group) => group.isCompleted));
	}
	return rows;
}

export function selectableMonitorRows(rows: MonitorTreeRow[]): MonitorTreeRow[] {
	return rows.filter((row) => row.kind !== "section");
}

export function selectedMonitorRow(rows: MonitorTreeRow[], ui: AgentBrowserUiState): MonitorTreeRow | undefined {
	return selectableMonitorRows(rows)[ui.monitorSelected];
}

export function selectedMonitorRowIndex(rows: MonitorTreeRow[], ui: AgentBrowserUiState): number {
	const selected = selectedMonitorRow(rows, ui);
	return selected ? rows.findIndex((row) => row.key === selected.key) : -1;
}

export function clampMonitorUiToRows(ui: AgentBrowserUiState, rows: MonitorTreeRow[], listRows: number): void {
	const selectable = selectableMonitorRows(rows);
	ui.monitorSelected = Math.max(0, Math.min(ui.monitorSelected, Math.max(0, selectable.length - 1)));
	const selectedIndex = selectedMonitorRowIndex(rows, ui);
	if (selectedIndex >= 0 && selectedIndex < ui.monitorScroll) ui.monitorScroll = selectedIndex;
	if (selectedIndex >= 0 && selectedIndex >= ui.monitorScroll + listRows) ui.monitorScroll = selectedIndex - listRows + 1;
	ui.monitorScroll = Math.max(0, Math.min(ui.monitorScroll, Math.max(0, rows.length - listRows)));
}

export function monitorFilter(ui: AgentBrowserUiState): MonitorFilter {
	return ui.monitorFilter ?? "all";
}

export function cycleMonitorFilter(filter: MonitorFilter): MonitorFilter {
	return MONITOR_FILTERS[(MONITOR_FILTERS.indexOf(filter) + 1) % MONITOR_FILTERS.length] ?? "all";
}

function renderMonitorFilterBar(filter: MonitorFilter, width: number, theme: Theme): string {
	const parts = MONITOR_FILTERS.map((value) => {
		const label = ` ${value} `;
		return value === filter ? agentActivePill(theme, label) : agentInactivePill(theme, label);
	});
	return truncateToWidth(`${parts.join(" ")} ${theme.fg("dim", "f cycle")}`, width, "");
}

export function monitorSessionKindLabel(group: MonitorSessionGroup): string {
	if (group.type === "pane") return "pane";
	if (group.type === "bg-lane") return `bg lane:${truncateSessionKeyForChip(group.sessionKey) ?? "?"}`;
	return "bg";
}

export function monitorSessionModeLabel(group: MonitorSessionGroup): string | undefined {
	if (group.type === "bg-lane") return group.sessionMode === "fresh" ? "fresh" : "resumed";
	return sessionModeChipLabel({ kind: group.kind, sessionMode: group.sessionMode, sessionKey: group.sessionKey });
}

function monitorSessionRowLabel(group: MonitorSessionGroup, theme: Theme): string {
	const mode = monitorSessionModeLabel(group);
	const modeSuffix = mode ? `${theme.fg("dim", " · ")}${theme.fg("muted", mode)}` : "";
	const tasksText = group.taskCount === 1 ? "1 task" : `${group.taskCount} tasks`;
	const meta = theme.fg("dim", ` (${tasksText} · last ${formatRelativeTime(group.latestAt)})`);
	return `${theme.fg("muted", monitorSessionKindLabel(group))}${theme.fg("dim", " · ")}${ansiMagenta(group.agent)}${modeSuffix}${meta}`;
}

export function renderMonitorTree(rows: MonitorTreeRow[], records: PaneTaskRecord[], collapsedSessionIds: Set<string>, ui: AgentBrowserUiState, width: number, theme: Theme, listRows: number): string[] {
	const filter = monitorFilter(ui);
	const groups = rows.filter((row) => row.kind === "session").length;
	const lines = [`${agentPaneTitle(theme, "Monitor", ui.pane === "list")} ${theme.fg("dim", `(${groups})`)}`, renderMonitorFilterBar(filter, width, theme), ""];
	if (rows.length === 0 || selectableMonitorRows(rows).length === 0) {
		lines.push(theme.fg("dim", "No tasks yet. Dispatch via `subagent` or `/agents`."));
		return lines;
	}
	if (ui.monitorScroll > 0) lines.push(theme.fg("dim", `↑ ${ui.monitorScroll} earlier`));
	const taskNumbers = taskNumberById(records);
	const selectedKey = selectedMonitorRow(rows, ui)?.key;
	for (const row of rows.slice(ui.monitorScroll, ui.monitorScroll + listRows)) {
		let rendered = "";
		if (row.kind === "section") rendered = `${theme.fg("muted", "▼")} ${theme.fg("accent", row.label)}`;
		else if (row.kind === "session") {
			const expander = collapsedSessionIds.has(row.group.id) ? "▶" : "▼";
			rendered = `  ${theme.fg("muted", expander)} ${monitorSessionRowLabel(row.group, theme)}`;
		} else {
			const label = monitorTaskRowLabel(row.record, taskNumbers);
			rendered = `    ${monitorStatusIcon(row.record.status, theme)} ${theme.fg("text", `Task ${label}`)}${theme.fg("dim", " · ")}${monitorStatusText(row.record.status, theme)}`;
		}
		const line = truncateToWidth(rendered, width, "…");
		lines.push(row.key === selectedKey ? theme.bg("selectedBg", agentPad(line, width)) : line);
	}
	const hidden = Math.max(0, rows.length - (ui.monitorScroll + listRows));
	if (hidden > 0) lines.push(theme.fg("dim", `↓ ${hidden} more`));
	return lines;
}
