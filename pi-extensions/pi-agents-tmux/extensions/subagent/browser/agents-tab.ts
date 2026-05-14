import { getMarkdownTheme, type Theme } from "@earendil-works/pi-coding-agent";
import { Markdown, truncateToWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { discoverAgents, type AgentConfig } from "../agents.js";
import { ansiMagenta, compactPath } from "../format.js";
import {
	AGENTS_LEFT_MAX_WIDTH,
	AGENTS_LEFT_MIN_WIDTH,
	ICONS,
	type AgentBrowserLayout,
	type AgentBrowserUiState,
	type AgentPaneStatus,
} from "../types.js";
import {
	agentDivider,
	agentEntityTitle,
	agentPad,
	agentPaneTitle,
	compactAgentPath,
} from "./shared.js";

function agentSearchText(agent: AgentConfig, status?: AgentPaneStatus): string {
	return [
		agent.name,
		agent.description,
		agent.source,
		agent.filePath,
		agent.model ?? "",
		agent.denyTools?.join(" ") ?? "",
		agent.pane ? "pane persistent tmux" : "bg background one-shot oneshot",
		status?.live ? "live running" : status?.entry ? "dead stopped" : "",
	].join(" ").toLowerCase();
}

function agentStatus(agent: AgentConfig, status: AgentPaneStatus | undefined): "live" | "dead" | "pane" | "bg" {
	if (!agent.pane) return "bg";
	if (status?.live) return "live";
	if (status?.entry) return "dead";
	return "pane";
}

interface AgentBrowserRow {
	agent: AgentConfig;
	label: string;
}

export function buildAgentRows(agents: AgentConfig[], query: string, statuses: Map<string, AgentPaneStatus>): AgentBrowserRow[] {
	const tokens = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
	const rows: AgentBrowserRow[] = [];
	const catalogAgents = sortAgentsForUnifiedView(agents, statuses);
	for (const agent of catalogAgents) {
		const agentSearch = agentSearchText(agent, statuses.get(agent.name));
		const includeAgent = tokens.length === 0 || tokens.every((token) => agentSearch.includes(token));
		if (!includeAgent) continue;
		rows.push({ agent, label: agent.name });
	}
	return rows;
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

function agentLegend(theme: Theme): string {
	return `${theme.fg("muted", "Legend")}: ${theme.fg("success", ICONS.circleFilled)} live pane · ${theme.fg("dim", ICONS.circleOpen)} idle/static · ${theme.fg("muted", "P/U")} project/user`;
}

function agentKindChip(agent: AgentConfig, theme: Theme): string {
	return theme.fg("muted", agent.pane ? "pane" : "bg");
}

function agentScopeChip(agent: AgentConfig, theme: Theme): string {
	return theme.fg("muted", agent.source === "project" ? "P" : "U");
}

function agentLiveBadge(agent: AgentConfig, status: AgentPaneStatus | undefined, theme: Theme): string {
	if (agent.pane && status?.live) return `${theme.fg("success", ICONS.circleFilled)} ${theme.fg("success", "live")}`;
	return theme.fg("dim", ICONS.circleOpen);
}

function displayAgentModel(agent: AgentConfig): string {
	return agent.model ?? "default";
}

function renderAgentList(rows: AgentBrowserRow[], statuses: Map<string, AgentPaneStatus>, ui: AgentBrowserUiState, width: number, theme: Theme, listRows: number): string[] {
	const lines = [`${agentPaneTitle(theme, "Agents", ui.pane === "list")} ${theme.fg("dim", `(${rows.length})`)}`, ""];
	if (rows.length === 0) {
		lines.push(theme.fg("dim", "No matching agents."));
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
		const model = `${theme.fg("dim", " · ")}${theme.fg("muted", displayAgentModel(agent))}`;
		const meta = `${theme.fg("dim", " · ")}${agentKindChip(agent, theme)}${model}${theme.fg("dim", " · ")}${agentScopeChip(agent, theme)}`;
		const row = truncateToWidth(`${marker}${agentLiveBadge(agent, status, theme)} ${name}${meta}`, width, "…");
		lines.push(selected ? theme.bg("selectedBg", agentPad(row, width)) : row);
	}
	const hidden = Math.max(0, rows.length - (ui.scroll + listRows));
	if (hidden > 0) lines.push(theme.fg("dim", `↓ ${hidden} more`));
	return lines;
}

function renderAgentPromptViewport(agent: AgentConfig, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	const prompt = agent.systemPrompt.trim() || theme.fg("dim", "(empty prompt)");
	const renderedPrompt = new Markdown(prompt, 0, 0, getMarkdownTheme()).render(width);
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
		`${agentPaneTitle(theme, "Inspector", ui.pane === "inspector")} ${agentEntityTitle(theme, agent.name)} ${theme.fg("dim", `[${agent.pane ? "pane" : "bg"}]`)} ${theme.fg("dim", `[${agent.source === "project" ? "P" : "U"}]`)}`,
	);
	lines.push("");
	lines.push(...wrapTextWithAnsi(agent.description || "No description.", safeWidth).slice(0, 3));
	lines.push("");
	pushWrapped(
		lines,
		`${theme.fg("muted", "Kind")}: ${agent.pane ? "persistent pane" : "bg"}    ${theme.fg("muted", "Scope")}: ${agent.source}`,
	);
	pushWrapped(lines, `${theme.fg("muted", "Model")}: ${displayAgentModel(agent)}    ${theme.fg("muted", "Effort")}: ${agent.effort ?? "default"}`);
	pushWrapped(lines, `${theme.fg("muted", "Deny tools")}: ${agent.denyTools && agent.denyTools.length > 0 ? agent.denyTools.join(", ") : "none"}`);
	pushWrapped(lines, `${theme.fg("muted", "Color")}: ${agent.color ?? "default"}`);
	pushWrapped(lines, `${theme.fg("muted", "Source path")}: ${compactPath(agent.filePath, { baseDir: process.cwd(), maxChars: Number.POSITIVE_INFINITY }) || compactAgentPath(agent.filePath)}`);
	const paneLine = paneStaticStatus(agent, status);
	if (paneLine) pushWrapped(lines, `${theme.fg("muted", "Pane")}: ${paneLine}`);
	lines.push("", theme.fg("muted", theme.bold("System Prompt")));
	const promptRows = Math.max(1, rows - lines.length);
	lines.push(...renderAgentPromptViewport(agent, ui, safeWidth, promptRows, theme));
	return lines.slice(0, rows);
}

function renderUnifiedAgentDetail(
	row: AgentBrowserRow | undefined,
	statuses: Map<string, AgentPaneStatus>,
	ui: AgentBrowserUiState,
	width: number,
	rows: number,
	theme: Theme,
): string[] {
	ui.agentSubtab = 0;
	return renderAgentInspector(row?.agent, statuses, ui, width, rows, theme);
}

export function renderAgentsBody(
	discovery: ReturnType<typeof discoverAgents>,
	rowsForList: AgentBrowserRow[],
	statuses: Map<string, AgentPaneStatus>,
	ui: AgentBrowserUiState,
	width: number,
	theme: Theme,
	layout: AgentBrowserLayout,
): string[] {
	const selectedRow = rowsForList[ui.selected];
	const maxLeftWidth = Math.max(10, width - 13);
	const desiredLeftWidth = Math.min(AGENTS_LEFT_MAX_WIDTH, Math.floor(width * 0.38), maxLeftWidth);
	const leftWidth = Math.max(10, Math.min(maxLeftWidth, Math.max(Math.min(AGENTS_LEFT_MIN_WIDTH, maxLeftWidth), desiredLeftWidth)));
	const rightWidth = Math.max(1, width - leftWidth - 3);
	const bodyRows = layout.bodyRows;
	const liveCount = [...statuses.values()].filter((status) => status.live).length;
	const paneCount = discovery.agents.filter((agent) => agent.pane).length;
	const left = renderAgentList(rowsForList, statuses, ui, leftWidth, theme, layout.listRows);
	const right = renderUnifiedAgentDetail(selectedRow, statuses, ui, rightWidth, bodyRows, theme);
	const rows = bodyRows;
	const searchLine = theme.bg("toolPendingBg", agentPad(` > ${ui.search}${theme.inverse(" ")}`, width));
	const filterLine = `${theme.fg("muted", "all scopes")}: ${rowsForList.length} rows · ${discovery.agents.length} agents · ${paneCount} pane · ${liveCount} live`;
	const filterLines = wrapTextWithAnsi(filterLine, width);
	const lines = [searchLine, ...filterLines, agentDivider(width, theme)];
	for (let i = 0; i < rows; i += 1) {
		lines.push(`${agentPad(left[i] ?? "", leftWidth)} ${theme.fg("dim", "│")} ${truncateToWidth(right[i] ?? "", rightWidth, "")}`);
	}
	lines.push("");
	lines.push(...wrapTextWithAnsi(agentLegend(theme), width));
	return lines;
}
