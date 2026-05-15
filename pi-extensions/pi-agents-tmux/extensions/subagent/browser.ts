import {
	type ExtensionContext,
	type Theme,
} from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, wrapTextWithAnsi, type TUI } from "@earendil-works/pi-tui";
import { discoverAgents, type AgentScope } from "./agents.js";
import { isDashboardAnimatingStatus } from "./dashboard.js";
import { ansiYellow } from "./format.js";
import { ensurePersistentPane, paneExists, stopPersistentPane, tmux } from "./pane.js";
import { readPaneRegistry, readTaskRegistry } from "./tasks.js";
import { loadAgentPaneStatuses } from "./browser/shared.js";
import { animateSpinnersEnabled } from "./settings.js";
import { sortedMonitorRecords, taskNumberById } from "./task-records.js";
import {
	AGENTS_BROWSER_MAX_HEIGHT,
	AGENTS_BROWSER_WIDTH,
	AGENTS_LEFT_MAX_WIDTH,
	AGENTS_LEFT_MIN_WIDTH,
	MONITOR_SUBTAB_LABELS,
	type AgentBrowserAction,
	type AgentBrowserLayout,
	type AgentBrowserUiState,
	type AgentPaneStatus,
	type MonitorDetailEntry,
	type PaneTaskRecord,
	type PaneTaskRegistry,
	type SubagentDashboardItem,
} from "./types.js";
import {
	buildAgentRows,
	renderAgentInspector,
	sortAgentsForUnifiedView,
	agentLegend,
	renderAgentList,
	type AgentBrowserRow,
} from "./browser/agents-tab.js";
import {
	editAgentFrontmatterOverrides,
	showAgentEditConfirmation,
} from "./browser/frontmatter-editor.js";
import {
	buildMonitorSessionGroups,
	clampMonitorUiToRows,
	monitorTreeRows,
	renderMonitorTree,
	selectableMonitorRows,
	selectedMonitorRow,
	type MonitorSectionKind,
	type MonitorSessionGroup,
} from "./browser/monitor-tree.js";
import {
	monitorFooterHint,
	renderMonitorDetail,
	traceViewerItems,
} from "./browser/monitor-task-detail.js";
import { renderMonitorSessionDetail } from "./browser/monitor-session-detail.js";
import {
	acquireVstackModalLock,
	agentBrowserLayout,
	agentDivider,
	agentFrame,
	agentFrameContentWidth,
	agentPad,
	isAgentBrowserCancelInput,
	renderAgentBrowserTabs,
	tabNext,
} from "./browser/shared.js";

export { acquireVstackModalLock, renderAgentBrowserTabs } from "./browser/shared.js";
export {
	agentSystemPromptMarkdownTheme,
	buildAgentRows,
	renderAgentInspector,
	renderAgentList,
} from "./browser/agents-tab.js";
export {
	buildMonitorSessionGroups,
	clampMonitorUiToRows,
	formatRelativeTime,
	monitorTaskRowLabel,
	monitorTreeRows,
	renderMonitorTree,
	type MonitorSectionKind,
	type MonitorSessionGroup,
	type MonitorTreeRow,
} from "./browser/monitor-tree.js";
export { type MonitorSessionType } from "./task-records.js";
export {
	monitorFooterHint,
	renderMonitorDetail,
	traceViewerItems,
} from "./browser/monitor-task-detail.js";
export { renderMonitorSessionDetail } from "./browser/monitor-session-detail.js";
export {
	editAgentFrontmatterOverrides,
	showAgentEditConfirmation,
} from "./browser/frontmatter-editor.js";
export {
	activeDashboardItems,
	appendBgChatMessages,
	dashboardDisplayLabels,
} from "./browser/dashboard-integration.js";
export { openTraceViewer } from "./browser/trace-viewer.js";
export { loadTaskRegistrySync, taskNumberById } from "./task-records.js";

function renderMonitorTabBody(
	records: PaneTaskRecord[],
	rows: ReturnType<typeof monitorTreeRows>,
	collapsedSessionIds: Set<string>,
	cache: Map<string, MonitorDetailEntry>,
	discovery: ReturnType<typeof discoverAgents>,
	ui: AgentBrowserUiState,
	width: number,
	theme: Theme,
	layout: AgentBrowserLayout,
	animateSpinners = true,
): string[] {
	const maxLeftWidth = Math.max(10, width - 13);
	const desiredLeftWidth = Math.min(AGENTS_LEFT_MAX_WIDTH, Math.floor(width * 0.36), maxLeftWidth);
	const leftWidth = Math.max(10, Math.min(maxLeftWidth, Math.max(Math.min(AGENTS_LEFT_MIN_WIDTH, maxLeftWidth), desiredLeftWidth)));
	const rightWidth = Math.max(1, width - leftWidth - 3);
	const bodyRows = layout.bodyRows;
	const left = renderMonitorTree(rows, records, collapsedSessionIds, ui, leftWidth, theme, layout.listRows, animateSpinners);
	const selection = selectedMonitorRow(rows, ui);
	const taskNumbers = taskNumberById(records);
	const right = selection?.kind === "task"
		? renderMonitorDetail(selection.record, cache, ui, rightWidth, bodyRows, theme)
		: renderMonitorSessionDetail(selection?.kind === "session" ? selection.group : undefined, taskNumbers, ui, rightWidth, bodyRows, theme, animateSpinners, discovery);
	const lines: string[] = [agentDivider(width, theme)];
	for (let i = 0; i < bodyRows; i += 1) {
		lines.push(`${agentPad(left[i] ?? "", leftWidth)} ${theme.fg("dim", "│")} ${truncateToWidth(right[i] ?? "", rightWidth, "")}`);
	}
	const legend = `${theme.fg("muted", "Status")}: ${theme.fg("success", "completed")} · ${theme.fg("warning", "running/queued/blocked")} · ${theme.fg("error", "failed")}`;
	lines.push("");
	lines.push(...wrapTextWithAnsi(legend, width));
	return lines;
}

function renderUnifiedAgentDetail(
	row: AgentBrowserRow | undefined,
	statuses: Map<string, AgentPaneStatus>,
	ui: AgentBrowserUiState,
	width: number,
	rows: number,
	theme: Theme,
): string[] {
	return renderAgentInspector(row?.agent, statuses, ui, width, rows, theme);
}

function renderAgentsBody(
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
	const left = renderAgentList(rowsForList, statuses, ui, leftWidth, theme, layout.listRows);
	const right = renderUnifiedAgentDetail(selectedRow, statuses, ui, rightWidth, bodyRows, theme);
	const rows = bodyRows;
	const lines = [agentDivider(width, theme)];
	for (let i = 0; i < rows; i += 1) {
		lines.push(`${agentPad(left[i] ?? "", leftWidth)} ${theme.fg("dim", "│")} ${truncateToWidth(right[i] ?? "", rightWidth, "")}`);
	}
	lines.push("");
	lines.push(...wrapTextWithAnsi(agentLegend(theme), width));
	return lines;
}

function createAgentsBrowserComponent(
	discovery: ReturnType<typeof discoverAgents>,
	statuses: Map<string, AgentPaneStatus>,
	taskRegistry: PaneTaskRegistry,
	ui: AgentBrowserUiState,
	theme: Theme,
	requestRender: () => void,
	getLayout: () => AgentBrowserLayout,
	done: (action: AgentBrowserAction) => void,
	getActiveItems: () => SubagentDashboardItem[],
	cwd: string,
) {
	let closed = false;
	let resizeTimer: ReturnType<typeof setTimeout> | undefined;
	const spinnersAnimated = () => animateSpinnersEnabled(cwd);
	const animationTimer = getActiveItems().some((item) => isDashboardAnimatingStatus(item.status)) ? setInterval(() => {
		if (!closed && spinnersAnimated() && getActiveItems().some((item) => isDashboardAnimatingStatus(item.status))) requestRender();
	}, 120) : undefined;
	animationTimer?.unref?.();
	const scheduleResizeRender = () => {
		if (closed) return;
		requestRender();
		if (resizeTimer) clearTimeout(resizeTimer);
		resizeTimer = setTimeout(() => {
			resizeTimer = undefined;
			if (!closed) requestRender();
		}, 80);
		resizeTimer.unref?.();
	};
	const cleanup = () => {
		closed = true;
		if (resizeTimer) clearTimeout(resizeTimer);
		resizeTimer = undefined;
		if (animationTimer) clearInterval(animationTimer);
		process.off("SIGWINCH", scheduleResizeRender);
	};
	const finish = (action: AgentBrowserAction) => {
		cleanup();
		done(action);
	};
	process.on("SIGWINCH", scheduleResizeRender);
	const agentRows = () => buildAgentRows(discovery.agents, statuses);
	const selectedRow = () => agentRows()[ui.selected];
	const selectedAgent = () => selectedRow()?.agent;
	const clamp = () => {
		const layout = getLayout();
		const list = agentRows();
		ui.selected = Math.max(0, Math.min(ui.selected, Math.max(0, list.length - 1)));
		if (ui.selected < ui.scroll) ui.scroll = ui.selected;
		if (ui.selected >= ui.scroll + layout.listRows) ui.scroll = ui.selected - layout.listRows + 1;
		ui.scroll = Math.max(0, Math.min(ui.scroll, Math.max(0, list.length - layout.listRows)));
	};
	const monitorRecords = sortedMonitorRecords(taskRegistry);
	const monitorGroups = buildMonitorSessionGroups(monitorRecords);
	const monitorCollapsedSections = new Set<MonitorSectionKind>();
	const monitorCollapsedSessions = new Set<string>();
	const currentMonitorRows = () => monitorTreeRows(monitorGroups, monitorCollapsedSections, monitorCollapsedSessions);
	const monitorCache = new Map<string, MonitorDetailEntry>();
	const monitorTaskNumbers = taskNumberById(monitorRecords);
	const loadMonitorRecord = (record: PaneTaskRecord | undefined, group?: MonitorSessionGroup) => {
		if (!record) return;
		const cacheKey = record.taskId;
		const entry = monitorCache.get(cacheKey);
		if (entry?.items || entry?.loading || entry?.error) return;
		monitorCache.set(cacheKey, { loading: true });
		void traceViewerItems(record, monitorTaskNumbers.get(record.taskId), discovery, group?.sessionNumber).then((items) => {
			monitorCache.set(cacheKey, { items });
			requestRender();
		}).catch((error) => {
			monitorCache.set(cacheKey, { error: error instanceof Error ? error.message : String(error) });
			requestRender();
		});
	};
	const loadMonitorSelection = () => {
		const row = selectedMonitorRow(currentMonitorRows(), ui);
		if (row?.kind === "task") loadMonitorRecord(row.record, row.group);
	};
	const clampMonitor = () => {
		const layout = getLayout();
		const rows = currentMonitorRows();
		clampMonitorUiToRows(ui, rows, layout.listRows);
	};

	const switchTab = (delta: number) => {
		const next = tabNext(ui.tab, delta);
		if (next === "monitor") {
			ui.tab = "monitor";
			ui.monitorSelected = 0;
			ui.monitorScroll = 0;
			ui.monitorSubtab = 0;
			ui.inspectorScroll = 0;
			ui.pane = "list";
			clampMonitor();
			loadMonitorSelection();
			requestRender();
			return;
		}
		ui.tab = "agents";
		ui.selected = 0;
		ui.scroll = 0;
		ui.inspectorScroll = 0;
		ui.pane = "list";
		requestRender();
	};
	const insertSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "insert", agentName: agent.name });
	};
	const startSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "start", agentName: agent.name });
	};
	const attachSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "attach", agentName: agent.name });
	};
	const stopSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "stop", agentName: agent.name });
	};
	const editFrontmatterSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "editFrontmatter", agentName: agent.name });
	};
	function handleInput(data: string): void {
		if (isAgentBrowserCancelInput(data)) {
			finish({ type: "close" });
			return;
		}
		if (matchesKey(data, "tab")) return switchTab(1);
		if (matchesKey(data, "shift+tab")) return switchTab(-1);
		if (matchesKey(data, "left")) {
			if (ui.tab === "agents" && ui.pane === "inspector") {
				ui.pane = "list";
				requestRender();
				return;
			}
			if (ui.tab === "monitor" && ui.pane === "inspector") {
				if (ui.monitorSubtab === 0) {
					ui.pane = "list";
				} else {
					ui.monitorSubtab -= 1;
					ui.inspectorScroll = 0;
				}
				requestRender();
				return;
			}
			ui.pane = "list";
			requestRender();
			return;
		}
		if (matchesKey(data, "right")) {
			if (ui.tab === "agents") {
				if (ui.pane !== "inspector") {
					ui.pane = "inspector";
					requestRender();
					return;
				}
				return;
			}
			if (ui.tab === "monitor" && ui.pane === "inspector") {
				const total = MONITOR_SUBTAB_LABELS.length;
				if (ui.monitorSubtab < total - 1) {
					ui.monitorSubtab += 1;
					ui.inspectorScroll = 0;
					requestRender();
				}
				return;
			}
			if (ui.tab === "monitor" && selectedMonitorRow(currentMonitorRows(), ui)?.kind === "section") return;
			ui.pane = "inspector";
			requestRender();
			return;
		}
		if (matchesKey(data, "-") || matchesKey(data, "=")) {
			const layout = getLayout();
			const page = Math.max(1, layout.bodyRows);
			const delta = matchesKey(data, "-") ? -page : page;
			if (ui.tab === "monitor") {
				if (ui.pane === "inspector") {
					ui.inspectorScroll = Math.max(0, ui.inspectorScroll + delta);
				} else {
					ui.monitorSelected = Math.max(0, ui.monitorSelected + delta);
					ui.monitorSubtab = 0;
					ui.inspectorScroll = 0;
					clampMonitor();
					loadMonitorSelection();
				}
			} else if (ui.pane === "inspector") {
				ui.inspectorScroll = Math.max(0, ui.inspectorScroll + delta);
			} else {
				ui.selected = Math.max(0, ui.selected + delta);
				ui.inspectorScroll = 0;
				clamp();
			}
			requestRender();
			return;
		}
		if (ui.tab === "monitor") {
			const layout = getLayout();
			if (matchesKey(data, "up")) {
				if (ui.pane === "inspector") ui.inspectorScroll = Math.max(0, ui.inspectorScroll - 1);
				else { ui.monitorSelected = Math.max(0, ui.monitorSelected - 1); ui.monitorSubtab = 0; ui.inspectorScroll = 0; clampMonitor(); loadMonitorSelection(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "down")) {
				if (ui.pane === "inspector") ui.inspectorScroll += 1;
				else { ui.monitorSelected += 1; ui.monitorSubtab = 0; ui.inspectorScroll = 0; clampMonitor(); loadMonitorSelection(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "pageup" as any)) {
				if (ui.pane === "inspector") ui.inspectorScroll = Math.max(0, ui.inspectorScroll - Math.max(1, layout.bodyRows));
				else { ui.monitorSelected = Math.max(0, ui.monitorSelected - layout.listRows); ui.monitorSubtab = 0; ui.inspectorScroll = 0; clampMonitor(); loadMonitorSelection(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "pagedown" as any)) {
				if (ui.pane === "inspector") ui.inspectorScroll += Math.max(1, layout.bodyRows);
				else { ui.monitorSelected += layout.listRows; ui.monitorSubtab = 0; ui.inspectorScroll = 0; clampMonitor(); loadMonitorSelection(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "home")) { if (ui.pane === "inspector") ui.inspectorScroll = 0; else { ui.monitorSelected = 0; ui.monitorScroll = 0; ui.monitorSubtab = 0; clampMonitor(); loadMonitorSelection(); } requestRender(); return; }
			if (matchesKey(data, "end")) { if (ui.pane === "inspector") ui.inspectorScroll = Number.MAX_SAFE_INTEGER; else { ui.monitorSelected = Math.max(0, selectableMonitorRows(currentMonitorRows()).length - 1); ui.monitorSubtab = 0; clampMonitor(); loadMonitorSelection(); } requestRender(); return; }
			if (matchesKey(data, "enter") || matchesKey(data, "return")) {
				if (ui.pane === "list") {
					const selected = selectedMonitorRow(currentMonitorRows(), ui);
					if (selected?.kind === "section") {
						if (monitorCollapsedSections.has(selected.section)) monitorCollapsedSections.delete(selected.section);
						else monitorCollapsedSections.add(selected.section);
						clampMonitor();
						requestRender();
						return;
					}
					if (selected?.kind === "session") {
						if (monitorCollapsedSessions.has(selected.group.id)) monitorCollapsedSessions.delete(selected.group.id);
						else monitorCollapsedSessions.add(selected.group.id);
						clampMonitor();
						requestRender();
						return;
					}
					ui.pane = "inspector";
					loadMonitorSelection();
					requestRender();
					return;
				}
				return;
			}
			return;
		}
		if (matchesKey(data, "up")) {
			if (ui.pane === "inspector") ui.inspectorScroll -= 1;
			else { ui.selected -= 1; ui.inspectorScroll = 0; clamp(); }
			requestRender();
			return;
		}
		if (matchesKey(data, "down")) {
			if (ui.pane === "inspector") ui.inspectorScroll += 1;
			else { ui.selected += 1; ui.inspectorScroll = 0; clamp(); }
			requestRender();
			return;
		}
		if (matchesKey(data, "pageup" as any)) {
			const layout = getLayout();
			if (ui.pane === "inspector") ui.inspectorScroll -= Math.max(1, layout.bodyRows);
			else { ui.selected -= layout.listRows; ui.inspectorScroll = 0; clamp(); }
			requestRender();
			return;
		}
		if (matchesKey(data, "pagedown" as any)) {
			const layout = getLayout();
			if (ui.pane === "inspector") ui.inspectorScroll += Math.max(1, layout.bodyRows);
			else { ui.selected += layout.listRows; ui.inspectorScroll = 0; clamp(); }
			requestRender();
			return;
		}
		if (matchesKey(data, "home")) { if (ui.pane === "inspector") ui.inspectorScroll = 0; else { ui.selected = 0; ui.scroll = 0; } requestRender(); return; }
		if (matchesKey(data, "end")) { if (ui.pane === "inspector") ui.inspectorScroll = Number.MAX_SAFE_INTEGER; else { ui.selected = Math.max(0, agentRows().length - 1); clamp(); } requestRender(); return; }
		if (matchesKey(data, "enter") || matchesKey(data, "return")) return insertSelected();
		if (matchesKey(data, "alt+m") || matchesKey(data, "ctrl+m")) return editFrontmatterSelected();
		if (matchesKey(data, "alt+p") || matchesKey(data, "ctrl+p")) return startSelected();
		if (matchesKey(data, "alt+o") || matchesKey(data, "ctrl+o")) return attachSelected();
		if (matchesKey(data, "alt+x") || matchesKey(data, "ctrl+x")) return stopSelected();
	}

	function render(width: number): string[] {
		const layout = getLayout();
		const safeWidth = Math.max(1, width);
		const bodyWidth = agentFrameContentWidth(safeWidth);
		const tabLine = renderAgentBrowserTabs(ui.tab, bodyWidth, theme);
		if (ui.tab === "monitor") {
			clampMonitor();
			loadMonitorSelection();
			const rows = currentMonitorRows();
			const footer = monitorFooterHint(theme);
			const lines = [tabLine, "", ...renderMonitorTabBody(monitorRecords, rows, monitorCollapsedSessions, monitorCache, discovery, ui, bodyWidth, theme, layout, spinnersAnimated()), agentDivider(bodyWidth, theme), ...wrapTextWithAnsi(footer, bodyWidth)];
			return agentFrame(lines, safeWidth, theme, layout.innerRows, "Monitor");
		}
		clamp();
		const footer = `${ansiYellow("tab")} ${theme.fg("dim", "view · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("←/→")} ${theme.fg("dim", "pane · ")}${ansiYellow("alt+m")} ${theme.fg("dim", "edit frontmatter · ")}${ansiYellow("alt+p")} ${theme.fg("dim", "start pane · ")}${ansiYellow("alt+o")} ${theme.fg("dim", "attach · ")}${ansiYellow("alt+x")} ${theme.fg("dim", "stop")}`;
		const lines = [
			tabLine,
			"",
			...renderAgentsBody(agentRows(), statuses, ui, bodyWidth, theme, layout),
			agentDivider(bodyWidth, theme),
			...wrapTextWithAnsi(footer, bodyWidth),
		];
		return agentFrame(lines, safeWidth, theme, layout.innerRows, "Agents");
	}

	return { handleInput, invalidate() {}, render };
}

export async function openAgentsBrowser(
	ctx: ExtensionContext,
	initialScope: AgentScope,
	initialAgentName: string | undefined,
	runtimeRoot: string,
	parentSessionId: string,
	parentModel: string | undefined,
	parentThinkingLevel: string | undefined,
	activeTools: string[] | undefined,
	getActiveItems: () => SubagentDashboardItem[],
	onAgentStopped?: (agentName: string) => void,
): Promise<void> {
	const releaseModalLock = acquireVstackModalLock();
	try {
	const ui: AgentBrowserUiState = {
		inspectorScroll: 0,
		pane: initialAgentName ? "inspector" : "list",
		tab: "agents",
		scope: initialScope,
		selected: 0,
		scroll: 0,
		monitorSelected: 0,
		monitorScroll: 0,
		monitorSubtab: 0,
	};
	while (true) {
		const discovery = discoverAgents(ctx.cwd, ui.scope);
		const statuses = await loadAgentPaneStatuses(runtimeRoot);
		if (initialAgentName) {
			const selected = sortAgentsForUnifiedView(discovery.agents, statuses).findIndex((agent) => agent.name === initialAgentName);
			if (selected >= 0) ui.selected = selected;
			else {
				ctx.ui.notify(`Unknown agent "${initialAgentName}"`, "warning");
				ui.pane = "list";
			}
		}
		const taskRegistry = await readTaskRegistry(runtimeRoot).catch(() => ({} as PaneTaskRegistry));
		const action = await ctx.ui.custom<AgentBrowserAction>(
			(tui: TUI, theme: Theme, _keybindings, done) => createAgentsBrowserComponent(
				discovery,
				statuses,
				taskRegistry,
				ui,
				theme,
				() => tui.requestRender(),
				() => agentBrowserLayout(tui.terminal.rows),
				done,
				getActiveItems,
				ctx.cwd,
			),
			{ overlay: true, overlayOptions: { anchor: "center", maxHeight: AGENTS_BROWSER_MAX_HEIGHT, width: AGENTS_BROWSER_WIDTH } },
		);
		initialAgentName = undefined;
		if (!action || action.type === "close") return;
		if (action.type === "reload") continue;
		const agent = discovery.agents.find((candidate) => candidate.name === action.agentName);
		if (!agent) {
			ctx.ui.notify(`Unknown agent: ${action.agentName}`, "error");
			continue;
		}
		try {
			if (action.type === "editFrontmatter") {
				const message = await editAgentFrontmatterOverrides(ctx, agent);
				if (message) await showAgentEditConfirmation(ctx, message);
				continue;
			}
			if (action.type === "insert") {
				ctx.ui.pasteToEditor(`Use agent ${agent.name} to: `);
				return;
			}
			if (action.type === "start") {
				if (!agent.pane) throw new Error(`${agent.name} is not configured with pane: true.`);
				await ensurePersistentPane(runtimeRoot, parentSessionId, ctx.cwd, agent, parentModel, parentThinkingLevel, activeTools);
				ctx.ui.notify(`Started/reused ${agent.name}`, "info");
				continue;
			}
			if (action.type === "attach") {
				const registry = await readPaneRegistry(runtimeRoot);
				const entry = registry[agent.name];
				if (!entry || !(await paneExists(entry.paneId))) throw new Error(`No live pane for ${agent.name}.`);
				const result = await tmux(["select-pane", "-t", entry.paneId]);
				if (result.code !== 0) throw new Error(result.stderr || result.stdout || "tmux select-pane failed");
				ctx.ui.notify(`Attached to ${agent.name}`, "info");
				return;
			}
			if (action.type === "stop") {
				await stopPersistentPane(runtimeRoot, agent.name);
				onAgentStopped?.(agent.name);
				ctx.ui.notify(`Stopped ${agent.name}`, "info");
				continue;
			}
		} catch (error) {
			ctx.ui.notify(error instanceof Error ? error.message : String(error) , "error");
		}
	}
	} finally {
		releaseModalLock();
	}
}
