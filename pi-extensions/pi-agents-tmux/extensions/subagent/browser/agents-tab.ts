import { type Theme } from "@earendil-works/pi-coding-agent";
import { Markdown, truncateToWidth, wrapTextWithAnsi, type MarkdownTheme } from "@earendil-works/pi-tui";
import type { AgentConfig } from "../agents.js";
import { ansiMagenta, compactPath } from "../format.js";
import { effortFromModelId, modelWithoutEffortSuffix, normalizeReasoningEffort } from "../settings.js";
import {
	ICONS,
	type AgentBrowserUiState,
	type AgentPaneStatus,
	type PaneTaskRecord,
} from "../types.js";
import {
	agentEntityTitle,
	agentPad,
	agentPaneTitle,
	compactAgentPath,
} from "./shared.js";

export interface AgentBrowserRow {
	agent: AgentConfig;
	label: string;
}

function agentStatus(agent: AgentConfig, status: AgentPaneStatus | undefined): "live" | "dead" | "pane" | "bg" {
	if (!agent.pane) return "bg";
	if (status?.live) return "live";
	if (status?.entry) return "dead";
	return "pane";
}

export function buildAgentRows(agents: AgentConfig[], statuses: Map<string, AgentPaneStatus>): AgentBrowserRow[] {
	return sortAgentsForUnifiedView(agents, statuses).map((agent) => ({ agent, label: agent.name }));
}

function unifiedAgentRank(agent: AgentConfig, status: AgentPaneStatus | undefined): number {
	const state = agentStatus(agent, status);
	if (state === "live") return 0;
	if (state === "dead") return 1;
	if (state === "pane") return 2;
	return 3;
}

export function sortAgentsForUnifiedView(agents: AgentConfig[], statuses: Map<string, AgentPaneStatus>): AgentConfig[] {
	return [...agents].sort((a, b) => {
		const rank = unifiedAgentRank(a, statuses.get(a.name)) - unifiedAgentRank(b, statuses.get(b.name));
		if (rank !== 0) return rank;
		return a.name.localeCompare(b.name);
	});
}

export function agentLegend(theme: Theme): string {
	return `${theme.fg("muted", "Legend")}: ${theme.fg("success", ICONS.circleFilled)} live pane · ${theme.fg("dim", ICONS.circleOpen)} idle/static · pane/bg · project/user`;
}

function agentKindChip(agent: AgentConfig, theme: Theme): string {
	return theme.fg("muted", agent.pane ? "pane" : "bg");
}

function agentScopeChip(agent: AgentConfig, theme: Theme): string {
	return theme.fg("muted", agent.source === "project" ? "project" : "user");
}

function agentLiveBadge(agent: AgentConfig, status: AgentPaneStatus | undefined, theme: Theme): string {
	if (agent.pane && status?.live) return `${theme.fg("success", ICONS.circleFilled)} ${theme.fg("success", "live")}`;
	return theme.fg("dim", ICONS.circleOpen);
}

function displayAgentModel(agent: AgentConfig): string {
	return modelWithoutEffortSuffix(agent.model) ?? "default";
}

function displayAgentEffort(agent: AgentConfig): string {
	return normalizeReasoningEffort(agent.effort) ?? effortFromModelId(agent.model) ?? "default";
}

export function agentSystemPromptMarkdownTheme(theme: Theme): MarkdownTheme {
	return {
		heading: (text: string) => theme.fg("accent", text),
		link: (text: string) => theme.fg("accent", text),
		linkUrl: (text: string) => theme.fg("accent", text),
		code: (text: string) => theme.fg("accent", text),
		codeBlock: (text: string) => theme.fg("toolOutput", text),
		codeBlockBorder: (text: string) => theme.fg("dim", text),
		quote: (text: string) => theme.fg("toolOutput", text),
		quoteBorder: (text: string) => theme.fg("dim", text),
		hr: (text: string) => theme.fg("dim", text),
		listBullet: (text: string) => theme.fg("accent", text),
		bold: (text: string) => theme.bold(text),
		italic: (text: string) => text,
		underline: (text: string) => text,
		strikethrough: (text: string) => text,
		highlightCode: (code: string) => code.split(/\r?\n/).map((line) => theme.fg("toolOutput", line)),
	};
}

export function recordRunEffort(record: PaneTaskRecord, agentConfig: AgentConfig | undefined): string | undefined {
	return normalizeReasoningEffort(record.effort) ?? effortFromModelId(record.model) ?? normalizeReasoningEffort(agentConfig?.effort) ?? effortFromModelId(agentConfig?.model);
}

export function recordRunModel(record: PaneTaskRecord, agentConfig: AgentConfig | undefined): string | undefined {
	return modelWithoutEffortSuffix(record.model ?? agentConfig?.model);
}

export function renderAgentList(rows: AgentBrowserRow[], statuses: Map<string, AgentPaneStatus>, ui: AgentBrowserUiState, width: number, theme: Theme, listRows: number): string[] {
	const lines = [`${agentPaneTitle(theme, "Agents", ui.pane === "list")} ${theme.fg("dim", `(${rows.length})`)}`, ""];
	if (rows.length === 0) {
		lines.push(theme.fg("dim", "No agents found."));
		return lines;
	}
	if (ui.scroll > 0) lines.push(theme.fg("dim", `↑ ${ui.scroll} earlier`));
	for (const [visibleIndex, rowInfo] of rows.slice(ui.scroll, ui.scroll + listRows).entries()) {
		const index = ui.scroll + visibleIndex;
		const selected = index === ui.selected;
		const agent = rowInfo.agent;
		const status = statuses.get(agent.name);
		const marker = " ";
		const name = ansiMagenta(selected ? theme.bold(rowInfo.label) : rowInfo.label);
		const meta = `${theme.fg("dim", " · ")}${agentKindChip(agent, theme)}${theme.fg("dim", " · ")}${agentScopeChip(agent, theme)}`;
		const row = truncateToWidth(`${marker}${agentLiveBadge(agent, status, theme)} ${name}${meta}`, width, "…");
		lines.push(selected ? theme.bg("selectedBg", agentPad(row, width)) : row);
	}
	const hidden = Math.max(0, rows.length - (ui.scroll + listRows));
	if (hidden > 0) lines.push(theme.fg("dim", `↓ ${hidden} more`));
	return lines;
}

function renderAgentPromptViewport(agent: AgentConfig, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	const prompt = agent.systemPrompt.trim() || theme.fg("dim", "(empty prompt)");
	const renderedPrompt = new Markdown(prompt, 0, 0, agentSystemPromptMarkdownTheme(theme)).render(width);
	const promptLines = renderedPrompt.length > 0 ? renderedPrompt : wrapTextWithAnsi(prompt, width);
	const visibleRows = Math.max(1, rows - 1);
	const maxScroll = Math.max(0, promptLines.length - visibleRows);
	ui.inspectorScroll = Math.max(0, Math.min(ui.inspectorScroll, maxScroll));
	const visible = promptLines.slice(ui.inspectorScroll, ui.inspectorScroll + visibleRows);
	const before = ui.inspectorScroll > 0 ? `↑ ${ui.inspectorScroll}` : "";
	const afterCount = Math.max(0, promptLines.length - ui.inspectorScroll - visibleRows);
	const after = afterCount > 0 ? `↓ ${afterCount}` : "";
	const scroll = [before, after].filter(Boolean).join(" · ");
	return scroll ? [...visible, theme.fg("dim", scroll)] : visible;
}

function clockTime(raw: string | undefined): string | undefined {
	if (!raw) return undefined;
	const date = new Date(raw);
	if (!Number.isFinite(date.getTime())) return undefined;
	return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function paneStaticStatus(agent: AgentConfig, status: AgentPaneStatus | undefined): string | undefined {
	if (!agent.pane) return undefined;
	if (status?.live) {
		const started = clockTime(status.entry?.startedAt);
		return `running${started ? ` (started ${started})` : ""}`;
	}
	if (status?.entry) return "stopped";
	return "not started";
}

export function renderAgentInspector(agent: AgentConfig | undefined, statuses: Map<string, AgentPaneStatus>, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	if (!agent) return [`${agentPaneTitle(theme, "Inspector", ui.pane === "inspector")} ${theme.fg("dim", "Select an agent to inspect it.")}`];
	const status = statuses.get(agent.name);
	const safeWidth = Math.max(8, width);
	const pushWrapped = (target: string[], text: string) => {
		const wrapped = wrapTextWithAnsi(text, safeWidth);
		target.push(...(wrapped.length > 0 ? wrapped : [""]));
	};
	const lines: string[] = [];
	pushWrapped(
		lines,
		`${agentPaneTitle(theme, "Inspector", ui.pane === "inspector")} ${agentEntityTitle(theme, agent.name)}`,
	);
	lines.push("");
	lines.push(...wrapTextWithAnsi(agent.description || "No description.", safeWidth).slice(0, 3));
	lines.push("");
	pushWrapped(
		lines,
		`${theme.fg("muted", "Kind")}: ${agent.pane ? "persistent pane" : "bg"}    ${theme.fg("muted", "Scope")}: ${agent.source}`,
	);
	pushWrapped(lines, `${theme.fg("muted", "Model")}: ${displayAgentModel(agent)}    ${theme.fg("muted", "Effort")}: ${displayAgentEffort(agent)}`);
	pushWrapped(lines, `${theme.fg("muted", "Deny tools")}: ${agent.denyTools && agent.denyTools.length > 0 ? agent.denyTools.join(", ") : "none"}`);
	pushWrapped(lines, `${theme.fg("muted", "Color")}: ${agent.color ?? "default"}`);
	pushWrapped(lines, `${theme.fg("muted", "Source path")}: ${compactPath(agent.filePath, { baseDir: process.cwd(), maxChars: Number.POSITIVE_INFINITY }) || compactAgentPath(agent.filePath)}`);
	const paneLine = paneStaticStatus(agent, status);
	if (paneLine) pushWrapped(lines, `${theme.fg("muted", "Pane")}: ${paneLine}`);
	lines.push("", ansiMagenta(theme.bold("System Prompt")));
	const promptRows = Math.max(1, rows - lines.length);
	lines.push(...renderAgentPromptViewport(agent, ui, safeWidth, promptRows, theme));
	return lines.slice(0, rows);
}
