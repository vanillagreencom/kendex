import { type Theme } from "@earendil-works/pi-coding-agent";
import { ansiMagenta, ansiYellow, formatUsageStats } from "../format.js";
import {
	type AgentBrowserUiState,
	type TraceViewerItem,
} from "../types.js";
import { agentPaneTitle } from "./shared.js";
import { renderTraceContentLine } from "./monitor-task-detail.js";
import {
	monitorSessionKindLabel,
	monitorSessionModeLabel,
	monitorStatusIcon,
	monitorTaskRowLabel,
	type MonitorSessionGroup,
} from "./monitor-tree.js";

function formatDateTime(raw: string | undefined): string {
	if (!raw) return "—";
	const date = new Date(raw);
	if (!Number.isFinite(date.getTime())) return raw;
	return date.toISOString().replace("T", " ").replace(/\.\d{3}Z$/, "Z");
}

function formatDurationBetween(start: string | undefined, end: string | undefined): string {
	const startMs = Date.parse(start ?? "");
	const endMs = Date.parse(end ?? "");
	if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs < startMs) return "—";
	const totalSeconds = Math.floor((endMs - startMs) / 1000);
	const hours = Math.floor(totalSeconds / 3600);
	const minutes = Math.floor((totalSeconds % 3600) / 60);
	const seconds = totalSeconds % 60;
	if (hours > 0) return `${hours}h ${minutes}m`;
	if (minutes > 0) return `${minutes}m ${seconds}s`;
	return `${seconds}s`;
}

function monitorSessionTypeLabel(group: MonitorSessionGroup): string {
	if (group.type === "pane") return "pane";
	if (group.type === "bg-lane") return "bg-lane";
	return "bg-one-shot";
}

function monitorStatusBreakdown(group: MonitorSessionGroup): string {
	const counts = new Map<string, number>();
	for (const record of group.records) counts.set(record.status, (counts.get(record.status) ?? 0) + 1);
	return [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([status, count]) => `${status}:${count}`).join(" · ");
}

function renderScrollableTraceText(rawLines: string[], type: TraceViewerItem["type"] | undefined, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	const wrapped: string[] = [];
	for (const raw of rawLines) {
		const chunk = renderTraceContentLine(raw, type, width, theme);
		wrapped.push(...(chunk.length > 0 ? chunk : [""]));
	}
	const visibleRows = Math.max(1, rows - 1);
	const maxScroll = Math.max(0, wrapped.length - visibleRows);
	ui.inspectorScroll = Math.max(0, Math.min(ui.inspectorScroll, maxScroll));
	const slice = wrapped.slice(ui.inspectorScroll, ui.inspectorScroll + visibleRows);
	const before = ui.inspectorScroll > 0 ? `↑ ${ui.inspectorScroll}` : "";
	const afterCount = Math.max(0, wrapped.length - ui.inspectorScroll - visibleRows);
	const after = afterCount > 0 ? `↓ ${afterCount}` : "";
	const scrollHint = [before, after].filter(Boolean).join(" · ");
	return scrollHint ? [...slice, ansiYellow(scrollHint)] : [...slice, ""];
}

export function renderMonitorSessionDetail(group: MonitorSessionGroup | undefined, taskNumbers: Map<string, number>, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	if (!group) return [`${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${theme.fg("dim", "Select a session or task.")}`];
	const safeWidth = Math.max(8, width);
	const mode = monitorSessionModeLabel(group);
	const header = `${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${theme.fg("muted", monitorSessionKindLabel(group))}${theme.fg("dim", " · ")}${ansiMagenta(theme.bold(group.agent))}${mode ? `${theme.fg("dim", " · ")}${theme.fg("muted", mode)}` : ""}`;
	const taskCountText = group.taskCount === 1 ? "1 task" : `${group.taskCount} tasks`;
	const metadata = [
		"Session",
		"-------",
		`Session type  ${monitorSessionTypeLabel(group)}`,
		`Start     ${formatDateTime(group.createdAt)}`,
		`Latest    ${formatDateTime(group.latestAt)}`,
		`Duration  ${formatDurationBetween(group.createdAt, group.latestAt)}`,
		`Tasks     ${taskCountText} · ${monitorStatusBreakdown(group)}`,
		group.usage ? `Usage     ${formatUsageStats(group.usage)}` : "Usage     —",
		group.type === "pane" && group.paneId ? `Pane ID   ${group.paneId}` : "",
		group.type === "pane" && group.transcriptPath ? `Transcript  ${group.transcriptPath}` : "",
		group.type === "bg-lane" && group.sessionKey ? `SessionKey  ${group.sessionKey}` : "",
		group.type === "bg-one-shot" && group.transcriptPath ? `Transcript  ${group.transcriptPath}` : "",
		"",
		"Task list",
		"---------",
		...group.records.map((record) => `${monitorStatusIcon(record.status, theme)} Task ${monitorTaskRowLabel(record, taskNumbers)} · ${record.status}`),
		"",
		"Select a task row in the Monitor tree to open task detail.",
	].filter(Boolean);
	const headerLines = [header, ""];
	const bodyRows = Math.max(1, rows - headerLines.length);
	return [...headerLines, ...renderScrollableTraceText(metadata, "summary", ui, safeWidth, bodyRows, theme)].slice(0, rows);
}
