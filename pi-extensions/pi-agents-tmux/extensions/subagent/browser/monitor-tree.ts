import { type Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";
import { dashboardStatusIcon } from "../dashboard.js";
import { ansiMagenta } from "../format.js";
import { paneCompletionTone } from "../renderers.js";
import {
	monitorSessionKey,
	monitorStatusIsActive,
	monitorStatusIsTerminal,
	recordLatestTimestamp,
	taskNumberById,
	usageSum,
	type MonitorSessionType,
} from "../task-records.js";
import {
	ICONS,
	type AgentBrowserUiState,
	type PaneTaskRecord,
	type PaneTaskStatus,
	type UsageStats,
} from "../types.js";
import { agentPad, agentPaneTitle } from "./shared.js";

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
	sessionNumber?: number;
	sessionKey?: string;
	sessionMode?: PaneTaskRecord["sessionMode"];
	taskCount: number;
	transcriptPath?: string;
	type: MonitorSessionType;
	usage?: UsageStats;
}

export type MonitorSectionKind = "active" | "completed";

export type MonitorTreeRow =
	| { collapsed: boolean; count: number; key: string; kind: "section"; label: string; section: MonitorSectionKind }
	| { group: MonitorSessionGroup; key: string; kind: "session" }
	| { group: MonitorSessionGroup; key: string; kind: "task"; record: PaneTaskRecord };

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

export function monitorStatusIcon(status: PaneTaskStatus, theme: Theme, animateSpinners = true): string {
	if (status === "completed") return theme.fg("success", ICONS.check);
	if (status === "failed") return theme.fg("error", ICONS.times);
	if (status === "blocked") return theme.fg("warning", ICONS.times);
	if (status === "needs_completion") return theme.fg("warning", ICONS.warning);
	if (status === "running") return dashboardStatusIcon("running", theme, { animateSpinners });
	if (status === "queued") return theme.fg("warning", ICONS.clock);
	if (status === "unknown") return theme.fg("warning", ICONS.warning);
	return theme.fg("muted", "·");
}

export function monitorStatusText(status: PaneTaskStatus, theme: Theme): string {
	return theme.fg(paneCompletionTone(status), status);
}

function recordClockTime(record: PaneTaskRecord): string {
	const raw = record.completedAt ?? record.updatedAt ?? record.createdAt;
	if (!raw) return "--:--";
	const date = new Date(raw);
	if (!Number.isFinite(date.getTime())) return "--:--";
	return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

export function monitorTaskRowLabel(record: PaneTaskRecord, taskNumbers: Map<string, number>): string {
	const number = taskNumbers.get(record.taskId);
	const clock = recordClockTime(record);
	// `#1` is suppressed so the first task per session reads as plain `Task · <time>`.
	// Numbers only appear from the second task onward.
	return number && number > 1 ? `#${number} · ${clock}` : `· ${clock}`;
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
	const groupsByAgent = new Map<string, MonitorSessionGroup[]>();
	for (const group of groups) {
		const list = groupsByAgent.get(group.agent) ?? [];
		list.push(group);
		groupsByAgent.set(group.agent, list);
	}
	for (const list of groupsByAgent.values()) {
		if (list.length <= 1) continue;
		list
			.sort((a, b) => {
				const delta = Date.parse(a.createdAt) - Date.parse(b.createdAt);
				return delta !== 0 ? delta : a.id.localeCompare(b.id);
			})
			.forEach((group, index) => { group.sessionNumber = index + 1; });
	}
	return groups.sort((a, b) => {
		const delta = Date.parse(b.latestAt) - Date.parse(a.latestAt);
		return delta !== 0 ? delta : a.id.localeCompare(b.id);
	});
}

export function monitorTreeRows(groups: MonitorSessionGroup[], collapsedSectionIds: Set<MonitorSectionKind> = new Set(), collapsedSessionIds: Set<string> = new Set()): MonitorTreeRow[] {
	const rows: MonitorTreeRow[] = [];
	const pushGroup = (group: MonitorSessionGroup) => {
		rows.push({ group, key: group.id, kind: "session" });
		if (!collapsedSessionIds.has(group.id)) {
			for (const record of group.records) rows.push({ group, key: `${group.id}:${record.taskId}`, kind: "task", record });
		}
	};
	const pushSection = (section: MonitorSectionKind, label: string, sectionGroups: MonitorSessionGroup[]) => {
		const collapsed = collapsedSectionIds.has(section);
		rows.push({ collapsed, count: sectionGroups.length, key: `section:${section}`, kind: "section", label: `${label} (${sectionGroups.length})`, section });
		if (collapsed) return;
		for (const group of sectionGroups) pushGroup(group);
	};
	pushSection("active", "Active", groups.filter((group) => group.isActive));
	pushSection("completed", "Completed", groups.filter((group) => group.isCompleted));
	return rows;
}

export function selectableMonitorRows(rows: MonitorTreeRow[]): MonitorTreeRow[] {
	return rows;
}

export function selectedMonitorRow(rows: MonitorTreeRow[], ui: AgentBrowserUiState): MonitorTreeRow | undefined {
	return selectableMonitorRows(rows)[ui.monitorSelected];
}

function selectedMonitorRowIndex(rows: MonitorTreeRow[], ui: AgentBrowserUiState): number {
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

function monitorSessionRowLabel(group: MonitorSessionGroup, theme: Theme): string {
	const tasksText = group.taskCount === 1 ? "1 task" : `${group.taskCount} tasks`;
	const meta = theme.fg("dim", ` · ${tasksText} · ${formatRelativeTime(group.latestAt)}`);
	return `${ansiMagenta(group.agent)}${meta}`;
}

export function renderMonitorTree(rows: MonitorTreeRow[], records: PaneTaskRecord[], collapsedSessionIds: Set<string>, ui: AgentBrowserUiState, width: number, theme: Theme, listRows: number, animateSpinners = true): string[] {
	const groups = buildMonitorSessionGroups(records).length;
	const lines = [`${agentPaneTitle(theme, "Sessions", ui.pane === "list")} ${theme.fg("dim", `(${groups})`)}`, ""];
	if (records.length === 0 || rows.length === 0 || selectableMonitorRows(rows).length === 0) {
		lines.push(theme.fg("dim", "No tasks yet. Dispatch via `subagent` or `/agents`."));
		return lines;
	}
	if (ui.monitorScroll > 0) lines.push(theme.fg("dim", `↑ ${ui.monitorScroll} earlier`));
	const taskNumbers = taskNumberById(records);
	const selectedKey = selectedMonitorRow(rows, ui)?.key;
	for (const row of rows.slice(ui.monitorScroll, ui.monitorScroll + listRows)) {
		let rendered = "";
		if (row.kind === "section") {
			const expander = row.collapsed ? "▶" : "▼";
			rendered = `${theme.fg("muted", expander)} ${ansiMagenta(theme.bold(row.label))}`;
		}
		else if (row.kind === "session") {
			const expander = collapsedSessionIds.has(row.group.id) ? "▶" : "▼";
			rendered = `  ${theme.fg("muted", expander)} ${monitorSessionRowLabel(row.group, theme)}`;
		} else {
			const label = monitorTaskRowLabel(row.record, taskNumbers);
			rendered = `    ${monitorStatusIcon(row.record.status, theme, animateSpinners)} ${theme.fg("text", `Task ${label}`)}${theme.fg("dim", " · ")}${monitorStatusText(row.record.status, theme)}`;
		}
		const line = truncateToWidth(rendered, width, "…");
		lines.push(row.key === selectedKey ? theme.bg("selectedBg", agentPad(line, width)) : line);
	}
	const hidden = Math.max(0, rows.length - (ui.monitorScroll + listRows));
	if (hidden > 0) lines.push(theme.fg("dim", `↓ ${hidden} more`));
	return lines;
}
