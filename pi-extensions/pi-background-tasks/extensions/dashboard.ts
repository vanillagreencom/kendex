import type { ExtensionCommandContext, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";

import {
	DASHBOARD_FRAME_VERTICAL_OVERHEAD,
	DASHBOARD_MAX_HEIGHT,
	DASHBOARD_MIN_FRAME_ROWS,
	DASHBOARD_WIDTH,
	TASK_PANE_MAX_WIDTH,
	TASK_PANE_MIN_WIDTH,
	ansiYellow,
	clamp,
} from "./constants.js";
import {
	compactText,
	formatDuration,
	formatRelativeTime,
	summarizeTaskStatus,
	taskDisplayName,
	taskElapsedMs,
} from "./format.js";
import {
	acquireVstackModalLock,
	activePill,
	bgStatusIcon,
	bgStatusText,
	dashboardContentWidth,
	frameDashboard,
	inactivePill,
	padAnsi,
	splitOutputLines,
} from "./render.js";
import { taskSnapshot } from "./snapshot.js";
import type { ManagedTask } from "./types.js";

export interface DashboardDeps {
	sortedTasks(): ManagedTask[];
	getTask(id: string): ManagedTask | null;
	getTaskOutput(task: ManagedTask): string;
	requestStop(task: ManagedTask | null, reason: "user"): { ok: boolean; message: string };
	clearFinishedTasks(): number;
	formatTaskListText(): string;
}

export async function openDashboard(
	ctx: ExtensionCommandContext | ExtensionContext,
	deps: DashboardDeps,
	initialTask: ManagedTask | null = null,
): Promise<void> {
	if (!ctx.hasUI) {
		ctx.ui.notify(deps.formatTaskListText(), "info");
		return;
	}

	const releaseModalLock = acquireVstackModalLock();
	try {
		await ctx.ui.custom(
			(tui, theme, _keybindings, done) => {
				let selectedId: string | null = initialTask?.id ?? deps.sortedTasks()[0]?.id ?? null;
				let taskScroll = 0;
				let rightScroll = 0;
				let lastRightMaxScroll = 0;
				let followOutput = false;
				let commandExpanded = false;
				let activePane: "tasks" | "output" = "tasks";
				let timer: ReturnType<typeof setInterval> | null = null;

				const ensureDashboardTimer = () => {
					const hasRunning = deps.sortedTasks().some((task) => task.status === "running");
					if (!hasRunning) {
						if (timer) clearInterval(timer);
						timer = null;
						return;
					}
					if (timer) return;
					timer = setInterval(() => tui.requestRender(), 1_000);
					timer.unref?.();
				};

				const selectedTask = (): ManagedTask | null => {
					const sorted = deps.sortedTasks();
					if (sorted.length === 0) return null;
					const current = selectedId ? deps.getTask(selectedId) : null;
					if (current) return current;
					selectedId = sorted[0]?.id ?? null;
					return selectedId ? deps.getTask(selectedId) : null;
				};

				const dashboardFrameRows = (): number => {
					const rows = Number(tui.terminal?.rows ?? 32);
					return Math.max(DASHBOARD_MIN_FRAME_ROWS, Math.floor(Math.max(1, rows) * 0.72));
				};
				const dashboardInnerRows = (): number => Math.max(4, dashboardFrameRows() - DASHBOARD_FRAME_VERTICAL_OVERHEAD);
				const dashboardBodyRows = (): number => Math.max(1, dashboardInnerRows() - 2);
				const taskRows = (): number => Math.max(1, dashboardBodyRows() - 1);
				const getOutputLines = (task: ManagedTask | null): string[] => splitOutputLines(task ? deps.getTaskOutput(task) : "");
				const sanitizeDashboardLine = (line: string): string => line
					.replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, "")
					.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
					.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "")
					.replace(/\t/g, "  ");
				const wrapDashboardLine = (line: string, targetWidth: number): string[] => {
					const sanitized = sanitizeDashboardLine(line).replace(/\r/g, "");
					const wrapped = wrapTextWithAnsi(sanitized, Math.max(1, targetWidth));
					return wrapped.length > 0 ? wrapped : [""];
				};
				const pushDetail = (target: string[], label: string, value: string, detailWidth: number, maxLines = 6): number => {
					const prefix = `${theme.fg("muted", label)}: `;
					const indent = " ".repeat(Math.max(0, `${label}: `.length));
					const chunks = String(value).split(/\r?\n/);
					const lines: string[] = [];
					chunks.forEach((chunk, index) => {
						const lead = index === 0 ? prefix : theme.fg("muted", indent);
						const available = Math.max(1, detailWidth - (index === 0 ? visibleWidth(`${label}: `) : indent.length));
						const wrapped = wrapDashboardLine(chunk, available);
						wrapped.forEach((part, partIndex) => {
							lines.push(`${partIndex === 0 ? lead : theme.fg("muted", indent)}${part}`);
						});
					});
					if (lines.length > maxLines) {
						target.push(...lines.slice(0, Math.max(1, maxLines - 1)));
						target.push(`${theme.fg("muted", indent)}… ${lines.length - (maxLines - 1)} more line(s)`);
						return lines.length - (maxLines - 1);
					}
					target.push(...lines);
					return 0;
				};

				const syncTaskScroll = () => {
					const sorted = deps.sortedTasks();
					const index = Math.max(0, sorted.findIndex((task) => task.id === selectedId));
					const rows = taskRows();
					const max = Math.max(0, sorted.length - rows);
					if (index < taskScroll) taskScroll = index;
					if (index >= taskScroll + rows) taskScroll = index - rows + 1;
					taskScroll = clamp(taskScroll, 0, max);
				};

				const moveSelection = (delta: number) => {
					const sorted = deps.sortedTasks();
					if (sorted.length === 0) {
						selectedId = null;
						return;
					}
					const currentIndex = Math.max(0, sorted.findIndex((task) => task.id === selectedId));
					selectedId = sorted[clamp(currentIndex + delta, 0, sorted.length - 1)]?.id ?? null;
					commandExpanded = false;
					rightScroll = 0;
					followOutput = false;
					syncTaskScroll();
					tui.requestRender();
				};

				const moveRightPane = (delta: number) => {
					followOutput = false;
					rightScroll = clamp(rightScroll + delta, 0, lastRightMaxScroll);
					tui.requestRender();
				};

				const renderLines = (width: number): string[] => {
					const sorted = deps.sortedTasks();
					const selected = selectedTask();
					const bodyRows = dashboardBodyRows();
					const taskViewportRows = taskRows();
					syncTaskScroll();

					const lines: string[] = [];
					const footerFor = (commandHidden = 0) => {
						const commandHint = commandExpanded
							? `${theme.fg("dim", " · ")}${ansiYellow("x")} ${theme.fg("dim", "collapse command")}`
							: commandHidden > 0
								? `${theme.fg("dim", " · ")}${ansiYellow("x")} ${theme.fg("dim", "expand command")}`
								: "";
						return `${ansiYellow("←/→ tab")} ${theme.fg("dim", "pane · ")}${ansiYellow("s")} ${theme.fg("dim", "stop · ")}${ansiYellow("c")} ${theme.fg("dim", "clear · ")}${ansiYellow("f")} ${theme.fg("dim", "follow · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page right")}${commandHint}`;
					};

					if (sorted.length === 0) {
						lines.push(theme.fg("dim", "No background tasks yet. Use /bg run <command> or the bg_task tool."));
						while (lines.length < bodyRows) lines.push("");
						lines.push("", ...wrapTextWithAnsi(footerFor(), Math.max(1, width)));
						return lines.map((line) => truncateToWidth(line, width, ""));
					}

					const taskPaneWidth = clamp(Math.floor(width * 0.34), TASK_PANE_MIN_WIDTH, TASK_PANE_MAX_WIDTH);
					const detailPaneWidth = Math.max(24, width - taskPaneWidth - 3);
					const left: string[] = [];
					const right: string[] = [];
					let commandHidden = 0;

					left.push(`${activePane === "tasks" ? activePill(theme, " Tasks ") : inactivePill(theme, " Tasks ")} ${theme.fg("dim", `(${sorted.length})`)}`);
					left.push("");
					if (taskScroll > 0) left.push(theme.fg("dim", `↑ ${taskScroll} earlier task(s)`));
					for (const task of sorted.slice(taskScroll, taskScroll + taskViewportRows)) {
						const isSelected = task.id === selected?.id;
						const row = ` ${bgStatusIcon(task.status, theme)} ${theme.fg("accent", task.id)} ${theme.fg(
							isSelected ? "text" : "dim",
							`${summarizeTaskStatus(task.status, task.exitCode)} · ${compactText(taskDisplayName(task), Math.max(12, taskPaneWidth - 24))}`,
						)}`;
						left.push(isSelected ? theme.bg("selectedBg", padAnsi(row, taskPaneWidth)) : row);
					}
					const hiddenBelow = Math.max(0, sorted.length - (taskScroll + taskViewportRows));
					if (hiddenBelow > 0) left.push(theme.fg("dim", `↓ ${hiddenBelow} more task(s)`));

					if (!selected) {
						right.push(theme.fg("dim", "Select a task to inspect output."));
					} else {
						const outputLines = getOutputLines(selected).map(sanitizeDashboardLine);
						right.push(`${activePane === "output" ? activePill(theme, ` Watch ${selected.id} `) : inactivePill(theme, ` Watch ${selected.id} `)} ${theme.fg("dim", followOutput ? "follow" : rightScroll > 0 ? `line ${rightScroll + 1}` : "top")}`);
						right.push("");
						right.push(`${theme.fg("muted", "Status")}: ${bgStatusText(taskSnapshot(selected), theme)} · pid ${selected.pid}`);
						right.push(`${theme.fg("muted", "Started")}: ${formatRelativeTime(selected.startedAt)} · ${formatDuration(taskElapsedMs(selected))} elapsed`);
						if (selected.expiresAt != null) right.push(`${theme.fg("muted", "Expiry")}: ${formatRelativeTime(selected.expiresAt)}`);
						commandHidden = pushDetail(right, "Command", selected.command, detailPaneWidth, commandExpanded ? Number.MAX_SAFE_INTEGER : 4);
						pushDetail(right, "Cwd", selected.cwd, detailPaneWidth, 2);
						pushDetail(right, "Log", selected.logFile, detailPaneWidth, 2);
						pushDetail(right, "Wakeups", `exit=${selected.notifyOnExit ? "yes" : "no"}, output=${selected.notifyOnOutput ? (selected.notifyPattern ?? "yes") : "no"}, mode=${selected.notifyMode ?? "always"}${selected.dedupeKey ? `, dedupeKey=${selected.dedupeKey}` : ""}`, detailPaneWidth, 2);
						right.push("", theme.fg("muted", theme.bold("Output")));
						right.push(...outputLines);
					}
					lastRightMaxScroll = Math.max(0, right.length - bodyRows);
					if (followOutput) rightScroll = lastRightMaxScroll;
					rightScroll = clamp(rightScroll, 0, lastRightMaxScroll);
					const visibleRight = right.slice(rightScroll, rightScroll + bodyRows);

					const rowCount = Math.min(bodyRows, Math.max(left.length, visibleRight.length));
					for (let i = 0; i < rowCount; i += 1) {
						lines.push(`${padAnsi(left[i] ?? "", taskPaneWidth)}${theme.fg("dim", " │ ")}${truncateToWidth(visibleRight[i] ?? "", detailPaneWidth, "")}`);
					}
					while (lines.length < bodyRows) lines.push("");
					lines.push("", ...wrapTextWithAnsi(footerFor(commandHidden), Math.max(1, width)));
					return lines.map((line) => truncateToWidth(line, width, ""));
				};

				return {
					dispose() {
						if (timer) clearInterval(timer);
						timer = null;
					},
					handleInput(data: string) {
						if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
							done(undefined);
							return;
						}
						if (matchesKey(data, "left")) { activePane = "tasks"; tui.requestRender(); return; }
						if (matchesKey(data, "right")) { activePane = "output"; tui.requestRender(); return; }
						if (matchesKey(data, "tab")) { activePane = activePane === "tasks" ? "output" : "tasks"; tui.requestRender(); return; }
						if (matchesKey(data, "up")) return activePane === "tasks" ? moveSelection(-1) : moveRightPane(-1);
						if (matchesKey(data, "down")) return activePane === "tasks" ? moveSelection(1) : moveRightPane(1);
						if (matchesKey(data, "home")) {
							if (activePane === "tasks") return moveSelection(-Number.MAX_SAFE_INTEGER);
							followOutput = false;
							rightScroll = 0;
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "end")) {
							if (activePane === "tasks") return moveSelection(Number.MAX_SAFE_INTEGER);
							followOutput = true;
							rightScroll = lastRightMaxScroll;
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "-") || matchesKey(data, "pageup") || matchesKey(data, "shift+up")) return moveRightPane(-dashboardBodyRows());
						if (matchesKey(data, "=") || matchesKey(data, "pagedown") || matchesKey(data, "shift+down")) return moveRightPane(dashboardBodyRows());
						if (data === "f") {
							followOutput = !followOutput;
							if (followOutput) rightScroll = lastRightMaxScroll;
							tui.requestRender();
							return;
						}
						if (data === "x") {
							if (selectedTask()) commandExpanded = !commandExpanded;
							tui.requestRender();
							return;
						}
						if (data === "s") {
							deps.requestStop(selectedTask(), "user");
							tui.requestRender();
							return;
						}
						if (data === "c") {
							deps.clearFinishedTasks();
							tui.requestRender();
						}
					},
					invalidate() {},
					render(width: number) {
						ensureDashboardTimer();
						const sorted = deps.sortedTasks();
						const running = sorted.filter((task) => task.status === "running").length;
						return frameDashboard(renderLines(dashboardContentWidth(width)), width, theme, "Background Tasks", `${running} running · ${sorted.length - running} finished`, { paddingBottom: 0 });
					},
				};
			},
			{ overlay: true, overlayOptions: { anchor: "center", maxHeight: DASHBOARD_MAX_HEIGHT, width: DASHBOARD_WIDTH } },
		);
	} finally {
		releaseModalLock();
	}
}
