import { type Theme } from "@earendil-works/pi-coding-agent";
import type { AgentConfig } from "../agents.js";
import { ansiYellow, formatUsageStats, sessionModeDetailLabel } from "../format.js";
import { effortFromModelId, modelWithoutEffortSuffix, normalizeReasoningEffort } from "../settings.js";
import type { AgentBrowserUiState, TraceViewerItem } from "../types.js";
import { recordRunEffort, recordRunModel } from "./agents-tab.js";
import {
	monitorStatusIcon,
	monitorStatusText,
	monitorTaskRowLabel,
	type MonitorSessionGroup,
} from "./monitor-tree.js";
import { renderTraceContentLine } from "./monitor-task-detail.js";
import { agentPaneTitle } from "./shared.js";

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

export function renderMonitorSessionDetail(group: MonitorSessionGroup | undefined, taskNumbers: Map<string, number>, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme, animateSpinners = true, discovery?: { agents: AgentConfig[] }): string[] {
	if (!group) return [`${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${theme.fg("dim", "Select a session or task.")}`];
	const safeWidth = Math.max(8, width);
	const header = agentPaneTitle(theme, "Detail", ui.pane === "inspector");
	const taskCountText = group.taskCount === 1 ? "1 task" : `${group.taskCount} tasks`;
	const representative = group.records[0];
	const agentConfig = discovery?.agents.find((agent) => agent.name === group.agent);
	const model = representative ? recordRunModel(representative, agentConfig) : modelWithoutEffortSuffix(agentConfig?.model);
	const effort = representative ? recordRunEffort(representative, agentConfig) : normalizeReasoningEffort(agentConfig?.effort) ?? effortFromModelId(agentConfig?.model);
	const sessionDetail = sessionModeDetailLabel(group);
	const metadata = [
		"Session",
		"-------",
		`Agent    ${group.agent}`,
		`Session type  ${monitorSessionTypeLabel(group)}`,
		group.sessionNumber ? `Session #  ${group.sessionNumber}` : "",
		model ? `Model    ${model}` : "",
		effort ? `Effort   ${effort}` : "",
		sessionDetail ? `Session  ${sessionDetail}` : "",
		`Start     ${formatDateTime(group.createdAt)}`,
		`Latest    ${formatDateTime(group.latestAt)}`,
		`Duration  ${formatDurationBetween(group.createdAt, group.latestAt)}`,
		`Tasks     ${taskCountText} · ${monitorStatusBreakdown(group)}`,
		group.usage ? `Usage     ${formatUsageStats(group.usage)}` : "Usage     —",
		group.type === "pane" && group.paneId ? `Pane ID   ${group.paneId}` : "",
		group.type === "pane" && group.transcriptPath ? `Transcript  ${group.transcriptPath}` : "",
		group.type === "bg-lane" && group.sessionKey ? `SessionKey  ${group.sessionKey}` : "",
		group.type === "bg-one-shot" && group.transcriptPath ? `Transcript  ${group.transcriptPath}` : "",
		" ",
		"Task list",
		"---------",
		...group.records.map((record) => `${monitorStatusIcon(record.status, theme, animateSpinners)} Task ${monitorTaskRowLabel(record, taskNumbers)} · ${monitorStatusText(record.status, theme)}`),
		"",
		"Select a task row in the Monitor tree to open task detail.",
	].filter(Boolean);
	const headerLines = [header, ""];
	const bodyRows = Math.max(1, rows - headerLines.length);
	return [...headerLines, ...renderScrollableTraceText(metadata, "summary", ui, safeWidth, bodyRows, theme)].slice(0, rows);
}
