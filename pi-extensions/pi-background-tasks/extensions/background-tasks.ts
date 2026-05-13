/*
 * vstack Pi background tasks.
 *
 * Locally owned package based on ideas and portions of the MIT-licensed
 * @ifi/pi-background-tasks package. See ../THIRD_PARTY_NOTICES.md.
 */

import { StringEnum } from "@earendil-works/pi-ai";
import {
	getShellConfig,
	type AgentToolResult,
	type ExtensionAPI,
	type ExtensionCommandContext,
	type ExtensionContext,
	type Theme,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

import {
	autoBackgroundDecision,
	bashBackgroundAck,
	bashBackgroundAckText,
	forcedBackgroundDecision,
} from "./auto-background.js";
import {
	BG_COMMAND,
	BG_INSTALL_SYMBOL,
	BG_MESSAGE_TYPE,
	BG_STATE_TYPE,
	BG_WIDGET_KEY,
	DEFAULT_BACKGROUND_BASH_SHORTCUT,
	DEFAULT_BG_SHORTCUT,
	DEFAULT_FORCE_KILL_GRACE_MS,
	DEFAULT_FORCED_BACKGROUND_WINDOW_MS,
	DEFAULT_OUTPUT_ALERT_MAX_CHARS,
	DEFAULT_OUTPUT_SETTLE_MS,
	DEFAULT_TIMEOUT_MS,
	DEFAULT_WIDGET_FINISHED_RETENTION_MS,
	DEFAULT_WIDGET_TOGGLE_SHORTCUT,
	WIDGET_COMPACT_TASKS,
} from "./constants.js";
import { openDashboard } from "./dashboard.js";
import {
	buildTaskSummaryLine,
	compactText,
	formatDuration,
	formatRelativeTime,
	formatShortcutHint,
	formatTaskLog,
	parseOutputMatcher,
	summarizeTaskStatus,
	tailText,
	taskDisplayName,
	taskLogTruncation,
	trimOutputBuffer,
} from "./format.js";
import {
	bgStatusIcon,
	bgTree,
	frameWidget,
	makeToolResult,
	renderBgToolResult,
	renderEmpty,
	renderTaskEventMessage,
} from "./render.js";
import { logFilePath, settingBoolean, settingEnum, settingNumber, settingString, taskEnv } from "./settings.js";
import {
	forgetSnapshot,
	rememberSnapshot,
	resolveTaskByToken,
	restoredTaskFromSnapshot,
	selectMissedExits,
	taskSnapshot,
} from "./snapshot.js";
import { MINI_DASHBOARD_RANK, setMiniDashboardWidget } from "./stacked-widget.js";
import type {
	BackgroundTaskEventDetails,
	BackgroundTaskSnapshot,
	BackgroundTaskStatus,
	ManagedTask,
	SpawnTaskOptions,
	TaskEventType,
} from "./types.js";

/**
 * Clamp the rendered line count of an aboveEditor widget so it can never push
 * the chat / status / editor above the terminal viewport top, which is what
 * triggers pi-tui's full-screen redraw (firstChanged < prevViewportTop) and
 * the visible flash. Keeps at least 4 lines visible; reserves enough rows for
 * the editor + footer + a sliver of chat. Drops trailing lines and replaces
 * them with a muted "… N more" hint.
 */
function clampAboveEditorWidget(lines: string[], terminalRows: number, theme: Theme): string[] {
	const reserveForOtherUi = 10;
	const maxLines = Math.max(4, terminalRows - reserveForOtherUi);
	if (lines.length <= maxLines) return lines;
	const hidden = lines.length - (maxLines - 1);
	return [...lines.slice(0, maxLines - 1), theme.fg("muted", `… ${hidden} more (open dashboard for full view)`)];
}

export default function backgroundTasks(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[BG_INSTALL_SYMBOL]) return;
	guard[BG_INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;

	let activeCtx: ExtensionContext | null = null;
	let requestWidgetRender: (() => void) | null = null;
	let forceNextBashBackgroundAt: number | null = null;
	const backgroundBashShortcut = settingString("backgroundBashShortcut", DEFAULT_BACKGROUND_BASH_SHORTCUT);
	const dashboardShortcut = settingString("dashboardShortcut", DEFAULT_BG_SHORTCUT);
	const widgetToggleShortcut = settingString("widgetToggleShortcut", DEFAULT_WIDGET_TOGGLE_SHORTCUT);
	let widgetMode: "compact" | "expanded" | "hidden" = settingEnum("widgetDefaultMode", ["compact", "expanded", "hidden"] as const, "compact");
	let lastVisibleWidgetMode: "compact" | "expanded" = widgetMode === "expanded" ? "expanded" : "compact";
	let taskCounter = 0;
	let shuttingDown = false;
	const tasks = new Map<string, ManagedTask>();

	const piUserDir = (): string => resolve(process.env.PI_CODING_AGENT_DIR?.trim() || `${process.env.HOME ?? ""}/.pi/agent`);
	const safeFileName = (value: string): string => value.replace(/[^\w.-]+/g, "_");
	const sessionIdForContext = (ctx: ExtensionContext): string => {
		const id = ctx.sessionManager.getSessionId();
		if (id && id.trim()) return id;
		const file = ctx.sessionManager.getSessionFile();
		if (file) return file.split(/[\\/]/).pop()?.replace(/\.jsonl$/, "") ?? `ephemeral-${process.pid}`;
		return `ephemeral-${process.pid}`;
	};
	const sidecarStatePath = (ctx: ExtensionContext): string => join(piUserDir(), "vstack", "sessions", safeFileName(sessionIdForContext(ctx)), "pi-background-tasks", "state.json");

	const numericTaskId = (id: string): number => {
		const match = id.match(/^bg-(\d+)$/);
		return match ? Number(match[1]) : 0;
	};

	const rememberRestoredSnapshot = (snapshot: BackgroundTaskSnapshot) => {
		if (!snapshot?.id || !snapshot.command) return;
		const existing = tasks.get(snapshot.id);
		if (existing && existing.updatedAt >= snapshot.updatedAt) return;
		const restored = restoredTaskFromSnapshot(snapshot);
		tasks.set(restored.id, restored);
		taskCounter = Math.max(taskCounter, numericTaskId(restored.id));
		rememberSnapshot(restored);
	};

	const persistSnapshots = () => {
		try {
			const snapshot = sortedTasks().map((task) => rememberSnapshot(task));
			pi.appendEntry(BG_STATE_TYPE, { version: 1, tasks: snapshot, updatedAt: Date.now() });
			if (activeCtx) {
				const file = sidecarStatePath(activeCtx);
				mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
				writeFileSync(file, `${JSON.stringify({ version: 1, tasks: snapshot, updatedAt: Date.now() }, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
			}
		} catch {
			// Tool results and log files remain available even if session state persistence fails.
		}
	};

	const restoreSnapshots = (ctx: ExtensionContext) => {
		tasks.clear();
		taskCounter = 0;
		try {
			const file = sidecarStatePath(ctx);
			if (existsSync(file)) {
				const data = JSON.parse(readFileSync(file, "utf8")) as { tasks?: unknown };
				if (Array.isArray(data?.tasks)) for (const snapshot of data.tasks) rememberRestoredSnapshot(snapshot as BackgroundTaskSnapshot);
			}
		} catch {
			// Fall back to session entries below.
		}
		for (const entry of ctx.sessionManager.getBranch()) {
			if (entry.type === "custom" && entry.customType === BG_STATE_TYPE) {
				const data = entry.data as { tasks?: unknown } | undefined;
				tasks.clear();
				taskCounter = 0;
				if (Array.isArray(data?.tasks)) for (const snapshot of data.tasks) rememberRestoredSnapshot(snapshot as BackgroundTaskSnapshot);
			}
			if (entry.type === "message" && entry.message.role === "toolResult" && (entry.message.toolName === "bg_task" || entry.message.toolName === "bg_status")) {
				const details = entry.message.details as { task?: unknown; tasks?: unknown } | undefined;
				if (details?.task) rememberRestoredSnapshot(details.task as BackgroundTaskSnapshot);
				if (Array.isArray(details?.tasks)) for (const snapshot of details.tasks) rememberRestoredSnapshot(snapshot as BackgroundTaskSnapshot);
			}
		}
		if (tasks.size > 0) persistSnapshots();
	};

	const sortedTasks = (): ManagedTask[] => [...tasks.values()].sort((a, b) => b.startedAt - a.startedAt);

	const getTaskOutput = (task: ManagedTask): string => {
		if (task.output.length > 0) return task.output;
		if (!existsSync(task.logFile)) return "";
		try {
			return readFileSync(task.logFile, "utf8");
		} catch {
			return "";
		}
	};

	const clearTaskTimers = (task: ManagedTask) => {
		if (task.outputTimer) clearTimeout(task.outputTimer);
		if (task.timeoutTimer) clearTimeout(task.timeoutTimer);
		if (task.forceKillTimer) clearTimeout(task.forceKillTimer);
		task.outputTimer = null;
		task.timeoutTimer = null;
		task.forceKillTimer = null;
	};

	const clearWidget = () => {
		if (activeCtx) setMiniDashboardWidget(activeCtx, BG_WIDGET_KEY, MINI_DASHBOARD_RANK.BACKGROUND_TASKS, undefined);
		requestWidgetRender = null;
	};

	const widgetFinishedRetentionMs = (cwd?: string): number =>
		Math.max(0, Math.floor(settingNumber("widgetFinishedRetentionSeconds", DEFAULT_WIDGET_FINISHED_RETENTION_MS / 1_000, cwd) * 1_000));

	const widgetTasks = (now: number = Date.now()): ManagedTask[] => {
		const retention = widgetFinishedRetentionMs(activeCtx?.cwd);
		return sortedTasks().filter((task) => task.status === "running" || now - task.updatedAt <= retention);
	};

	const renderWidgetLines = (theme: Theme): string[] => {
		const sorted = widgetTasks();
		const running = sorted.filter((task) => task.status === "running");
		const display = [...running, ...sorted.filter((task) => task.status !== "running")];
		const finished = sorted.length - running.length;
		const toggleHint = widgetToggleShortcut === "none" ? "" : ` · ${formatShortcutHint(widgetToggleShortcut)} toggle`;
		const dashboardHint = dashboardShortcut === "none" ? "" : ` · ${formatShortcutHint(dashboardShortcut)} dashboard`;
		const summary = `${theme.fg("customMessageLabel", theme.bold("Background tasks"))} ${theme.fg(
			"muted",
			`${running.length} running · ${finished} finished${toggleHint}${dashboardHint}`,
		)}`;
		if (display.length === 0) return [summary];
		const shown = display.slice(0, widgetMode === "expanded" ? display.length : WIDGET_COMPACT_TASKS);
		const lines = [summary];
		shown.forEach((task, index) => {
			const isLast = index === shown.length - 1 && shown.length === display.length;
			const activityAt = task.lastOutputAt ?? task.updatedAt;
			lines.push(`${bgTree(theme, isLast ? "└" : "├", activeCtx?.cwd)}${bgStatusIcon(task.status, theme)} ${theme.fg("accent", task.id)} ${theme.fg(
				"dim",
				`${summarizeTaskStatus(task.status, task.exitCode)} · ${compactText(taskDisplayName(task), 72)} · ${formatRelativeTime(activityAt)}`,
			)}`);
		});
		const hidden = display.length - shown.length;
		if (hidden > 0) lines.push(`${bgTree(theme, "└", activeCtx?.cwd)}${theme.fg("muted", `… ${hidden} more`)}`);
		return lines;
	};

	const syncWidget = (ctx: ExtensionContext) => {
		activeCtx = ctx;
		if (tasks.size === 0 || widgetTasks().length === 0 || !ctx.hasUI || widgetMode === "hidden" || !settingBoolean("showWidget", true, ctx.cwd)) {
			clearWidget();
			return;
		}

		setMiniDashboardWidget(
			ctx,
			BG_WIDGET_KEY,
			MINI_DASHBOARD_RANK.BACKGROUND_TASKS,
			(tui, theme) => {
				requestWidgetRender = () => tui.requestRender();
				// Previously: setInterval(() => tui.requestRender(), 1_000) to refresh
				// formatRelativeTime() output. That forced a TUI render every second purely
				// to advance "5s ago" → "6s ago", which re-diffs the full screen and triggers
				// pi-tui's above-viewport flicker every time the chat overflows. Relative-time
				// text is now refreshed only on real task events (start / output / end / mode
				// toggle / dashboard mutation), accepting a few seconds of staleness between
				// events as a worthwhile tradeoff against the redraw storm.
				return {
					dispose() {
						if (requestWidgetRender) requestWidgetRender = null;
					},
					invalidate() {},
					render(width: number) {
						return clampAboveEditorWidget(frameWidget(renderWidgetLines(theme), width, theme), tui.terminal.rows, theme);
					},
				};
			},
			{ placement: settingString("widgetPlacement", "aboveEditor", ctx.cwd) === "belowEditor" ? "belowEditor" : "aboveEditor" },
		);
	};

	const refreshUi = () => {
		for (const task of tasks.values()) rememberSnapshot(task);
		if (activeCtx) syncWidget(activeCtx);
		requestWidgetRender?.();
	};

	const sendTaskEvent = (
		eventType: TaskEventType,
		task: ManagedTask,
		options: { matchedPattern?: string; newOutputTail?: string } = {},
	): boolean => {
		if (shuttingDown) return false;
		if (eventType === "output" && !task.notifyOnOutput) return false;
		if (eventType === "exit" && !task.notifyOnExit) return false;

		const details: BackgroundTaskEventDetails = {
			eventAt: Date.now(),
			eventType,
			matchedPattern: options.matchedPattern,
			newOutputTail: options.newOutputTail,
			outputTail: tailText(getTaskOutput(task), settingNumber("outputAlertMaxChars", DEFAULT_OUTPUT_ALERT_MAX_CHARS, activeCtx?.cwd)),
			task: rememberSnapshot(task),
		};
		const headline = eventType === "exit"
			? `Background task ${task.id} finished.`
			: `Background task ${task.id} emitted new output.`;

		pi.sendMessage(
			{
				content: `${headline}\nCommand: ${task.command}`,
				customType: BG_MESSAGE_TYPE,
				details,
				display: true,
			},
			eventType === "exit" ? { deliverAs: "followUp", triggerTurn: true } : { deliverAs: "steer", triggerTurn: true },
		);
		return true;
	};

	const scheduleOutputReaction = (task: ManagedTask) => {
		if (!task.notifyOnOutput || task.status !== "running") return;
		if (task.outputTimer) clearTimeout(task.outputTimer);
		task.outputTimer = setTimeout(() => {
			task.outputTimer = null;
			const output = getTaskOutput(task);
			const unseenOutput = output.slice(task.lastAnnouncedLength);
			if (!unseenOutput.trim()) {
				task.lastAnnouncedLength = output.length;
				return;
			}
			if (task.matcher && !(task.matcher(unseenOutput) || task.matcher(output))) return;
			task.lastAnnouncedLength = output.length;
			sendTaskEvent("output", task, {
				matchedPattern: task.notifyPattern,
				newOutputTail: tailText(unseenOutput, settingNumber("outputAlertMaxChars", DEFAULT_OUTPUT_ALERT_MAX_CHARS, activeCtx?.cwd)),
			});
			refreshUi();
		}, settingNumber("outputSettleMs", DEFAULT_OUTPUT_SETTLE_MS, activeCtx?.cwd));
		task.outputTimer.unref?.();
	};

	const finalizeTask = (task: ManagedTask, exitCode: number | null, statusOverride?: BackgroundTaskStatus): ManagedTask => {
		if (task.closed) return task;
		task.closed = true;
		task.updatedAt = Date.now();
		task.exitCode = exitCode;
		clearTaskTimers(task);

		if (statusOverride) {
			task.status = statusOverride;
		} else if (task.stopReason === "timeout") {
			task.status = "timed_out";
		} else if (task.stopReason) {
			task.status = "stopped";
		} else {
			task.status = exitCode === 0 ? "completed" : "failed";
		}
		rememberSnapshot(task);
		persistSnapshots();

		const notified = sendTaskEvent("exit", task);
		if (notified) {
			task.exitNotified = true;
			rememberSnapshot(task);
			persistSnapshots();
		}
		refreshUi();
		return task;
	};

	// Replay 'exit' wakeups for any task we restored in a terminal state
	// without ever notifying the agent. The canonical failure path: a long-
	// running session_shutdown or a mid-session restore coerced status
	// running->stopped (restoredTaskFromSnapshot) and the agent never saw
	// the exit. Without this replay the bg_task silently stalls.
	const replayMissedExits = () => {
		let replayed = 0;
		for (const task of selectMissedExits(tasks.values())) {
			const notified = sendTaskEvent("exit", task);
			if (!notified) continue;
			task.exitNotified = true;
			rememberSnapshot(task);
			replayed += 1;
		}
		if (replayed > 0) persistSnapshots();
	};

	const appendLogLine = (task: ManagedTask, text: string) => {
		try {
			appendFileSync(task.logFile, text);
		} catch {
			// Keep in-memory output even if the log file is temporarily unavailable.
		}
	};

	const killTaskProcess = (task: ManagedTask, signal: NodeJS.Signals): boolean => {
		if (task.pid <= 0) return false;
		try {
			if (process.platform === "win32") {
				process.kill(task.pid, signal);
			} else {
				// We spawn detached on Unix, so -pid targets the task process group.
				process.kill(-task.pid, signal);
			}
			return true;
		} catch (error) {
			const code = (error as NodeJS.ErrnoException).code;
			if (code !== "ESRCH") appendLogLine(task, `\n[kill error] ${String(error)}\n`);
			return false;
		}
	};

	const requestStop = (
		task: ManagedTask | null,
		reason: "user" | "timeout" | "shutdown" = "user",
	): { ok: boolean; message: string } => {
		if (!task) return { ok: false, message: "No background task matched that id or pid." };
		if (task.status !== "running") {
			return { ok: true, message: `${task.id} is already ${summarizeTaskStatus(task.status, task.exitCode)}.` };
		}

		task.stopReason = reason;
		task.updatedAt = Date.now();
		rememberSnapshot(task);
		if (task.outputTimer) clearTimeout(task.outputTimer);
		task.outputTimer = null;
		persistSnapshots();

		const sent = killTaskProcess(task, "SIGTERM");
		if (!sent) {
			finalizeTask(task, task.exitCode, reason === "timeout" ? "timed_out" : "stopped");
			return { ok: true, message: `Stopped ${task.id} (${task.command}).` };
		}

		const forceKillGraceMs = settingNumber("forceKillGraceMs", DEFAULT_FORCE_KILL_GRACE_MS, activeCtx?.cwd);
		task.forceKillTimer = setTimeout(() => {
			if (task.status === "running" && !task.closed) {
				appendLogLine(task, `\n[stop] Escalating to SIGKILL after ${formatDuration(forceKillGraceMs)}.\n`);
				killTaskProcess(task, "SIGKILL");
			}
		}, forceKillGraceMs);
		task.forceKillTimer.unref?.();
		refreshUi();
		return { ok: true, message: `Stopping ${task.id} (${task.command}).` };
	};

	const spawnTask = (options: SpawnTaskOptions): ManagedTask => {
		const command = options.command.trim();
		if (!command) throw new Error("command is required for background task spawn");

		const cwd = options.cwd?.trim() || activeCtx?.cwd || process.cwd();
		const id = `bg-${++taskCounter}`;
		const now = Date.now();
		const timeoutSeconds = typeof options.timeoutSeconds === "number" ? options.timeoutSeconds : settingNumber("defaultTimeoutSeconds", DEFAULT_TIMEOUT_MS / 1_000, cwd);
		const expiresAt = timeoutSeconds > 0 ? now + timeoutSeconds * 1_000 : null;
		const logFile = logFilePath(id, now);
		writeFileSync(logFile, "");

		const { shell, args } = getShellConfig();
		const child = spawn(shell, [...args, command], {
			cwd,
			detached: process.platform !== "win32",
			env: taskEnv(),
			stdio: ["ignore", "pipe", "pipe"],
		});

		const task: ManagedTask = {
			child,
			closed: false,
			command,
			cwd,
			exitCode: null,
			exitNotified: false,
			expiresAt,
			forceKillTimer: null,
			id,
			lastAnnouncedLength: 0,
			lastOutputAt: null,
			logFile,
			matcher: parseOutputMatcher(options.notifyPattern),
			notifyOnExit: options.notifyOnExit ?? true,
			notifyOnOutput: options.notifyOnOutput ?? false,
			notifyPattern: options.notifyPattern?.trim() || undefined,
			output: "",
			outputBytes: 0,
			outputTimer: null,
			pid: child.pid ?? 0,
			startedAt: now,
			status: "running",
			stopReason: null,
			timeoutTimer: null,
			title: options.title?.trim() || command,
			updatedAt: now,
		};
		tasks.set(task.id, task);
		rememberSnapshot(task);
		persistSnapshots();

		const handleChunk = (chunk: Buffer) => {
			const text = chunk.toString();
			task.updatedAt = Date.now();
			task.lastOutputAt = task.updatedAt;
			task.outputBytes += chunk.byteLength;
			task.output += text;
			const trimmed = trimOutputBuffer(task.output, task.lastAnnouncedLength);
			task.output = trimmed.output;
			task.lastAnnouncedLength = trimmed.lastAnnouncedLength;
			appendLogLine(task, text);
			rememberSnapshot(task);
			scheduleOutputReaction(task);
			refreshUi();
		};

		child.stdout?.on("data", handleChunk);
		child.stderr?.on("data", handleChunk);
		child.on("close", (code) => finalizeTask(task, typeof code === "number" ? code : null));
		child.on("error", (error) => {
			handleChunk(Buffer.from(`\n[spawn error] ${error.message}\n`));
			finalizeTask(task, 1, "failed");
		});

		if (expiresAt != null) {
			task.timeoutTimer = setTimeout(() => {
				appendLogLine(task, `\n[timeout] Background task exceeded ${formatDuration(timeoutSeconds * 1_000)}.\n`);
				requestStop(task, "timeout");
			}, Math.max(1, timeoutSeconds * 1_000));
			task.timeoutTimer.unref?.();
		}

		refreshUi();
		return task;
	};

	const clearFinishedTasks = (): number => {
		let removed = 0;
		for (const [id, task] of tasks) {
			if (task.status === "running") continue;
			clearTaskTimers(task);
			tasks.delete(id);
			forgetSnapshot(id);
			removed += 1;
		}
		persistSnapshots();
		refreshUi();
		return removed;
	};

	const formatTaskListText = (): string => {
		const sorted = sortedTasks();
		if (sorted.length === 0) return "No background tasks.";
		return sorted.map((task) => buildTaskSummaryLine(taskSnapshot(task))).join("\n\n");
	};

	const resolveTask = (id?: string, pid?: number): ManagedTask | null =>
		resolveTaskByToken<ManagedTask>(tasks.values(), id ?? pid);

	const forcedBackgroundWindowMs = (cwd?: string): number =>
		Math.max(1_000, settingNumber("forcedBackgroundWindowSeconds", DEFAULT_FORCED_BACKGROUND_WINDOW_MS / 1_000, cwd) * 1_000);

	const consumeForcedBackground = (cwd?: string): boolean => {
		if (forceNextBashBackgroundAt == null) return false;
		if (Date.now() - forceNextBashBackgroundAt > forcedBackgroundWindowMs(cwd)) {
			forceNextBashBackgroundAt = null;
			return false;
		}
		forceNextBashBackgroundAt = null;
		return true;
	};

	const armForcedBackground = (ctx: ExtensionContext | ExtensionCommandContext, source: "shortcut" | "command") => {
		forceNextBashBackgroundAt = Date.now();
		const seconds = Math.max(1, Math.round(forcedBackgroundWindowMs(ctx.cwd) / 1_000));
		const sourceText = source === "shortcut" ? formatShortcutHint(backgroundBashShortcut) : `/${BG_COMMAND} next`;
		const note = ctx.isIdle?.()
			? `${sourceText} armed. Next bash command in the next ${seconds}s will start as a background task.`
			: `${sourceText} armed. Next not-yet-started bash command in this turn will start as a background task. Already-running bash cannot be detached safely.`;
		ctx.ui.notify(note, "info");
	};

	const decisionForBashCommand = (command: string, cwd?: string) => {
		if (!command.trim()) return null;
		if (consumeForcedBackground(cwd)) return forcedBackgroundDecision(command, cwd);
		if (!settingBoolean("autoBackgroundBash", true, cwd)) return null;
		return autoBackgroundDecision(command, cwd);
	};

	const dashboardDeps = {
		clearFinishedTasks,
		formatTaskListText,
		getTask: (id: string) => tasks.get(id) ?? null,
		getTaskOutput,
		requestStop: (task: ManagedTask | null, reason: "user") => requestStop(task, reason),
		sortedTasks,
	};

	pi.registerMessageRenderer(BG_MESSAGE_TYPE, (message, { expanded }, theme) => renderTaskEventMessage(message, expanded, theme));

	pi.on("session_start", (_event, ctx) => {
		shuttingDown = false;
		activeCtx = ctx;
		restoreSnapshots(ctx);
		replayMissedExits();
		syncWidget(ctx);
	});
	pi.on("before_agent_start", (_event, ctx) => {
		activeCtx = ctx;
		syncWidget(ctx);
	});
	pi.on("session_tree", (_event, ctx) => {
		activeCtx = ctx;
		syncWidget(ctx);
	});
	pi.on("session_compact", (_event, ctx) => {
		activeCtx = ctx;
		syncWidget(ctx);
	});
	pi.on("session_shutdown", () => {
		shuttingDown = true;
		for (const task of tasks.values()) {
			if (task.status === "running") {
				task.stopReason = "shutdown";
				task.status = "stopped";
				task.updatedAt = Date.now();
				killTaskProcess(task, "SIGTERM");
				killTaskProcess(task, "SIGKILL");
				rememberSnapshot(task);
			}
			clearTaskTimers(task);
		}
		persistSnapshots();
		clearWidget();
		activeCtx = null;
	});

	pi.on("tool_call", async (event: any, ctx: ExtensionContext) => {
		activeCtx = ctx;
		if (event?.toolName !== "bash") return undefined;
		const command = typeof event.input?.command === "string" ? event.input.command : "";
		const decision = decisionForBashCommand(command, ctx.cwd);
		if (!decision) return undefined;

		const task = spawnTask({
			command,
			cwd: ctx.cwd,
			notifyOnExit: decision.notifyOnExit,
			notifyOnOutput: decision.notifyOnOutput,
			notifyPattern: decision.notifyPattern,
			title: decision.title,
		});
		event.input.command = bashBackgroundAck(rememberSnapshot(task), decision);
		if (ctx.hasUI) {
			const label = decision.forced ? "Shortcut moved bash to background" : "Auto-backgrounded bash";
			ctx.ui.notify(`${label}: ${task.id} (pid ${task.pid})`, "info");
		}
		return undefined;
	});

	pi.on("user_bash", (event: any, ctx: ExtensionContext) => {
		activeCtx = ctx;
		const command = typeof event?.command === "string" ? event.command : "";
		const decision = decisionForBashCommand(command, event?.cwd ?? ctx.cwd);
		if (!decision) return undefined;

		const task = spawnTask({
			command,
			cwd: event?.cwd ?? ctx.cwd,
			notifyOnExit: decision.notifyOnExit,
			notifyOnOutput: decision.notifyOnOutput,
			notifyPattern: decision.notifyPattern,
			title: decision.title,
		});
		const output = bashBackgroundAckText(rememberSnapshot(task), decision);
		if (ctx.hasUI) {
			const label = decision.forced ? "Shortcut moved user bash to background" : "Auto-backgrounded user bash";
			ctx.ui.notify(`${label}: ${task.id} (pid ${task.pid})`, "info");
		}
		return { result: { output, exitCode: 0, cancelled: false, truncated: false } };
	});

	pi.registerTool({
		renderShell: "self",
		name: "bg_status",
		label: "Background Process Status",
		description: "List, tail, or stop background tasks spawned by bg_task or /bg. Use pid for log/stop.",
		parameters: Type.Object({
			action: StringEnum(["list", "log", "stop"] as const, {
				description: "list=show tracked tasks, log=view task output by pid, stop=terminate by pid",
			}),
			pid: Type.Optional(Type.Number({ description: "Task pid for action=log or action=stop" })),
		}),
		async execute(_toolCallId, params): Promise<AgentToolResult<unknown>> {
			if (params.action === "list") return makeToolResult(formatTaskListText(), { action: "list", tasks: sortedTasks().map(rememberSnapshot) });
			const task = resolveTask(undefined, params.pid);
			if (!task) throw new Error("No background task matched that pid.");
			if (params.action === "log") {
				const output = getTaskOutput(task);
				const truncation = taskLogTruncation(output, task.logFile, activeCtx?.cwd);
				return makeToolResult(formatTaskLog(output, task.logFile, activeCtx?.cwd), {
					action: "log",
					task: rememberSnapshot(task),
					...(truncation ? { fullOutputPath: task.logFile, truncation } : {}),
				});
			}
			const stopped = requestStop(task, "user");
			if (!stopped.ok) throw new Error(stopped.message);
			return makeToolResult(stopped.message, { action: "stop", task: rememberSnapshot(task) });
		},
		renderCall() {
			return renderEmpty();
		},
		renderResult(result: any, options: any, theme: Theme, context: any) {
			return renderBgToolResult(result, options, theme, context);
		},
	});

	pi.registerTool({
		renderShell: "self",
		name: "bg_task",
		label: "Background Task",
		description:
			"Spawn, inspect, and stop explicit background shell tasks without blocking the current turn. Tasks write persistent logs, do not time out by default, stop as a process group on Unix, and can wake the agent on exit or matching output. The background-tasks extension also auto-diverts recognized bash monitoring loops before they block.",
		promptSnippet: "Spawn, inspect, and stop explicit non-blocking background shell tasks.",
		promptGuidelines: [
			"Use bg_task instead of bash backgrounding/nohup when the user wants a long-running command to continue while the conversation remains usable.",
			"Use bg_task list/log/stop to inspect or terminate tasks started by bg_task or /bg.",
			"Use bg_task for pi-bridge, session, tmux, agent/delegate, or log monitoring instead of raw foreground bash polling loops.",
			"If a bash monitor is auto-backgrounded, continue the turn and inspect it later with bg_task log/list/stop rather than waiting on foreground bash.",
		],
		parameters: Type.Object({
			action: StringEnum(["spawn", "list", "log", "stop", "clear"] as const, {
				description: "spawn=start a task, list=show tasks, log=view output, stop=terminate, clear=remove finished tasks",
			}),
			command: Type.Optional(Type.String({ description: "Shell command for action=spawn" })),
			cwd: Type.Optional(Type.String({ description: "Working directory for action=spawn" })),
			id: Type.Optional(Type.String({ description: "Task id for action=log or action=stop" })),
			notifyOnExit: Type.Optional(Type.Boolean({ description: "Wake the agent when the task exits. Defaults to true." })),
			notifyOnOutput: Type.Optional(Type.Boolean({ description: "Wake the agent when new output arrives. Defaults to false." })),
			notifyPattern: Type.Optional(Type.String({ description: "Substring or /regex/flags gate for output wakeups." })),
			pid: Type.Optional(Type.Number({ description: "PID for action=log or action=stop" })),
			timeoutSeconds: Type.Optional(Type.Number({ description: "Timeout for spawned tasks. Defaults to 0 (disabled)." })),
			title: Type.Optional(Type.String({ description: "Optional display label for action=spawn" })),
		}),
		async execute(_toolCallId, params): Promise<AgentToolResult<unknown>> {
			if (params.action === "list") return makeToolResult(formatTaskListText(), { action: "list", tasks: sortedTasks().map(rememberSnapshot) });
			if (params.action === "clear") {
				const removed = clearFinishedTasks();
				return makeToolResult(`Removed ${removed} finished background task(s).`, { action: "clear", removed });
			}

			if (params.action === "spawn") {
				const task = spawnTask({
					command: params.command ?? "",
					cwd: params.cwd,
					notifyOnExit: params.notifyOnExit,
					notifyOnOutput: params.notifyOnOutput,
					notifyPattern: params.notifyPattern,
					timeoutSeconds: params.timeoutSeconds,
					title: params.title,
				});
				return makeToolResult(
					`Started ${task.id} (pid ${task.pid}) in the background.\nCommand: ${task.command}\nCwd: ${task.cwd}\nLog: ${task.logFile}\nExpiry: ${
						task.expiresAt != null ? formatRelativeTime(task.expiresAt) : "none"
					}\nWakeups: exit=${task.notifyOnExit ? "yes" : "no"}, output=${
						task.notifyOnOutput ? (task.notifyPattern ?? "yes") : "no"
					}`,
					{ action: "spawn", task: rememberSnapshot(task) },
				);
			}

			const task = resolveTask(params.id, params.pid);
			if (!task) throw new Error("No background task matched that id or pid.");
			if (params.action === "log") {
				const output = getTaskOutput(task);
				const truncation = taskLogTruncation(output, task.logFile, activeCtx?.cwd);
				return makeToolResult(formatTaskLog(output, task.logFile, activeCtx?.cwd), {
					action: "log",
					task: rememberSnapshot(task),
					...(truncation ? { fullOutputPath: task.logFile, truncation } : {}),
				});
			}
			const stopped = requestStop(task, "user");
			if (!stopped.ok) throw new Error(stopped.message);
			return makeToolResult(stopped.message, { action: "stop", task: rememberSnapshot(task) });
		},
		renderCall() {
			return renderEmpty();
		},
		renderResult(result: any, options: any, theme: Theme, context: any) {
			return renderBgToolResult(result, options, theme, context);
		},
	});

	const taskIdCompletions = (prefix: string) => {
		const query = prefix.trimStart().toLowerCase();
		const items = sortedTasks()
			.filter((task) => !query || task.id.toLowerCase().startsWith(query) || String(task.pid).startsWith(query))
			.map((task) => ({
				description: `${summarizeTaskStatus(task.status, task.exitCode)} · ${task.command}`,
				label: task.id,
				value: task.id,
			}));
		return items.length > 0 ? items : null;
	};

	pi.registerCommand(BG_COMMAND, {
		description: "Background shell task dashboard and controls.",
		getArgumentCompletions(prefix) {
			const trimmed = prefix.trimStart();
			const parts = trimmed.split(/\s+/).filter(Boolean);
			if (parts.length === 0 || (parts.length === 1 && !trimmed.endsWith(" "))) {
				return [
					{ label: "list", value: "list", description: "Show tracked tasks" },
					{ label: "next", value: "next", description: "Move the next bash command to background" },
					{ label: "run", value: "run ", description: "Spawn a background shell task" },
					{ label: "log", value: "log ", description: "Show task log tail" },
					{ label: "watch", value: "watch ", description: "Open the dashboard focused on a task" },
					{ label: "stop", value: "stop ", description: "Terminate a running task" },
					{ label: "clear", value: "clear", description: "Remove finished tasks" },
				].filter((option) => option.value.trim().startsWith(trimmed.toLowerCase()));
			}
			const [subcommand] = parts;
			if (!(subcommand === "log" || subcommand === "stop" || subcommand === "watch")) return null;
			if (parts.length > 2 || (parts.length === 2 && trimmed.endsWith(" "))) return null;
			const taskQuery = parts[1]?.toLowerCase() ?? "";
			const taskItems = sortedTasks()
				.filter((task) => !taskQuery || task.id.toLowerCase().startsWith(taskQuery) || String(task.pid).startsWith(taskQuery))
				.map((task) => ({
					description: `${summarizeTaskStatus(task.status, task.exitCode)} · ${task.command}`,
					label: task.id,
					value: `${subcommand} ${task.id}`,
				}));
			return taskItems.length > 0 ? taskItems : null;
		},
		handler: async (args, ctx) => {
			activeCtx = ctx;
			const trimmed = args.trim();
			if (!trimmed) {
				await openDashboard(ctx, dashboardDeps);
				return;
			}
			if (trimmed === "list") {
				ctx.ui.notify(formatTaskListText(), "info");
				return;
			}
			if (trimmed === "next") {
				armForcedBackground(ctx, "command");
				return;
			}
			if (trimmed === "clear") {
				ctx.ui.notify(`Removed ${clearFinishedTasks()} finished background task(s).`, "info");
				return;
			}
			if (trimmed.startsWith("run ")) {
				const task = spawnTask({ command: trimmed.slice(4), cwd: ctx.cwd });
				ctx.ui.notify(`Started ${task.id} (pid ${task.pid}) in the background.`, "info");
				return;
			}
			const inspectMatch = trimmed.match(/^(?:watch|log)\s+(.+)$/);
			if (inspectMatch) {
				const task = resolveTask(inspectMatch[1]?.trim());
				if (!task) {
					ctx.ui.notify("No background task matched that id or pid.", "warning");
					return;
				}
				if (trimmed.startsWith("log ")) ctx.ui.notify(formatTaskLog(getTaskOutput(task), task.logFile, ctx.cwd), "info");
				else await openDashboard(ctx, dashboardDeps, task);
				return;
			}
			if (trimmed.startsWith("stop ")) {
				const stopped = requestStop(resolveTask(trimmed.slice(5).trim()), "user");
				ctx.ui.notify(stopped.message, stopped.ok ? "info" : "warning");
				return;
			}
			ctx.ui.notify(
				`Unknown /${BG_COMMAND} action. Try run <command>, list, log <id>, watch <id>, stop <id>, or clear.`,
				"warning",
			);
		},
	});

	pi.registerCommand(`${BG_COMMAND}:list`, {
		description: "Show tracked background tasks",
		handler: async (_args, ctx) => {
			activeCtx = ctx;
			ctx.ui.notify(formatTaskListText(), "info");
		},
	});
	pi.registerCommand(`${BG_COMMAND}:next`, {
		description: "Move the next bash command to a background task",
		handler: async (_args, ctx) => {
			activeCtx = ctx;
			armForcedBackground(ctx, "command");
		},
	});
	pi.registerCommand(`${BG_COMMAND}:clear`, {
		description: "Remove finished background tasks",
		handler: async (_args, ctx) => {
			activeCtx = ctx;
			ctx.ui.notify(`Removed ${clearFinishedTasks()} finished background task(s).`, "info");
		},
	});
	pi.registerCommand(`${BG_COMMAND}:run`, {
		description: "Spawn a background shell task: /bg:run <command>",
		handler: async (args, ctx) => {
			activeCtx = ctx;
			const command = args.trim();
			if (!command) {
				ctx.ui.notify("Usage: /bg:run <command>", "warning");
				return;
			}
			const task = spawnTask({ command, cwd: ctx.cwd });
			ctx.ui.notify(`Started ${task.id} (pid ${task.pid}) in the background.`, "info");
		},
	});
	pi.registerCommand(`${BG_COMMAND}:stop`, {
		description: "Terminate a running background task: /bg:stop <id>",
		getArgumentCompletions: taskIdCompletions,
		handler: async (args, ctx) => {
			activeCtx = ctx;
			const stopped = requestStop(resolveTask(args.trim()), "user");
			ctx.ui.notify(stopped.message, stopped.ok ? "info" : "warning");
		},
	});

	if (dashboardShortcut !== "none") {
		pi.registerShortcut(dashboardShortcut, {
			description: "Open the background task dashboard",
			handler: async (ctx) => {
				activeCtx = ctx as ExtensionContext;
				await openDashboard(ctx as ExtensionContext, dashboardDeps);
			},
		});
	}
	if (dashboardShortcut.toLowerCase() !== "f5") {
		pi.registerShortcut("f5", {
			description: "Open the background task dashboard",
			handler: async (ctx) => {
				activeCtx = ctx as ExtensionContext;
				await openDashboard(ctx as ExtensionContext, dashboardDeps);
			},
		});
	}
	if (backgroundBashShortcut !== "none") {
		pi.registerShortcut(backgroundBashShortcut, {
			description: "Move the next not-yet-started bash command to a background task",
			handler: async (ctx) => {
				activeCtx = ctx as ExtensionContext;
				armForcedBackground(ctx as ExtensionContext, "shortcut");
			},
		});
	}
	if (widgetToggleShortcut !== "none") {
		pi.registerShortcut(widgetToggleShortcut, {
			description: "Toggle background task mini-dashboard",
			handler: async (ctx) => {
				activeCtx = ctx as ExtensionContext;
				if (widgetMode === "hidden") widgetMode = lastVisibleWidgetMode;
				else {
					lastVisibleWidgetMode = widgetMode;
					widgetMode = "hidden";
				}
				syncWidget(ctx as ExtensionContext);
			},
		});
	}
}
