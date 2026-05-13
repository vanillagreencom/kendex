/*
 * vstack Pi background tasks.
 *
 * Locally owned package based on ideas and portions of the MIT-licensed
 * @ifi/pi-background-tasks package. See ../THIRD_PARTY_NOTICES.md.
 */

import {
	getShellConfig,
	type ExtensionAPI,
	type ExtensionCommandContext,
	type ExtensionContext,
	type Theme,
} from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";

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

import {
	buildTaskSummaryLine,
	compactText,
	formatDuration,
	formatRelativeTime,
	formatShortcutHint,
	parseOutputMatcher,
	summarizeTaskStatus,
	tailText,
	taskDisplayName,
	trimOutputBuffer,
} from "./format.js";
import {
	bgStatusIcon,
	bgTree,
	frameWidget,
	renderTaskEventMessage,
} from "./render.js";
import { registerAll } from "./registrations.js";
import { finalizeTaskLifecycle, replayMissedExitsLifecycle, type LifecycleHooks } from "./lifecycle.js";
import { createOrphanWatcher, type OrphanWatcher } from "./orphan-watcher.js";
import { createPersistence, sessionIdForContext, sidecarStatePath } from "./persistence.js";
import { logFilePath, settingBoolean, settingEnum, settingNumber, settingString, taskEnv } from "./settings.js";
import {
	defaultReadProcessIdentity,
	forgetSnapshot,
	rememberSnapshot,
	resolveTaskByToken,
	restoredTaskFromSnapshot,
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

	const numericTaskId = (id: string): number => {
		const match = id.match(/^bg-(\d+)$/);
		return match ? Number(match[1]) : 0;
	};

	// Track the active session id so spawn/restore/replay can scope snapshots
	// to the current Pi session and reject cross-session leaks.
	let activeSessionId: string | null = null;

	const persistenceLayer = createPersistence({
		pi,
		customType: BG_STATE_TYPE,
		getActiveCtx: () => activeCtx,
		listSnapshots: () => sortedTasks().map((task) => rememberSnapshot(task)),
		notify: (where) => activeCtx?.ui.notify?.(
			`Background task state persistence failed (${where}). Recent task transitions may not survive a restart.`,
			"warning",
		),
	});

	const rememberRestoredSnapshot = (snapshot: BackgroundTaskSnapshot) => {
		if (!snapshot?.id || !snapshot.command) return;
		const existing = tasks.get(snapshot.id);
		if (existing && existing.updatedAt >= snapshot.updatedAt) return;
		const restored = restoredTaskFromSnapshot(snapshot, {
			sessionId: activeSessionId ?? undefined,
		});
		tasks.set(restored.id, restored);
		taskCounter = Math.max(taskCounter, numericTaskId(restored.id));
		rememberSnapshot(restored);
	};

	const persistSnapshots = (): { appendEntry: boolean; sidecar: boolean } =>
		persistenceLayer.persistSnapshots();

	const restoreSnapshots = (ctx: ExtensionContext) => {
		tasks.clear();
		taskCounter = 0;
		activeSessionId = sessionIdForContext(ctx);
		try {
			const file = sidecarStatePath(ctx);
			if (existsSync(file)) {
				const data = JSON.parse(readFileSync(file, "utf8")) as { tasks?: unknown };
				if (Array.isArray(data?.tasks)) for (const snapshot of data.tasks) rememberRestoredSnapshot(snapshot as BackgroundTaskSnapshot);
			}
		} catch (error) {
			const msg = error instanceof Error ? error.message : String(error);
			process.stderr.write(`[pi-background-tasks] persistence failed (sidecar-read): ${msg}\n`);
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

	const lifecycleHooks: LifecycleHooks = {
		rememberSnapshot,
		persistSnapshots,
		sendTaskEvent,
		refreshUi,
		clearTaskTimers,
	};

	const finalizeTask = (task: ManagedTask, exitCode: number | null, statusOverride?: BackgroundTaskStatus): ManagedTask =>
		finalizeTaskLifecycle(task, exitCode, lifecycleHooks, statusOverride);

	// vstack#15 (reviewer-error BLOCK): orphan-running tasks (status=
	// running, child=null, restored=true) need a liveness watcher.
	// When the recorded pid eventually disappears, finalize and emit
	// the canonical exit wake so the silent stall does not survive Pi
	// dying mid-bg_task.
	let orphanWatcher: OrphanWatcher | null = null;
	const ensureOrphanWatcher = () => {
		if (orphanWatcher) return;
		orphanWatcher = createOrphanWatcher({
			getTasks: () => tasks.values(),
			hooks: lifecycleHooks,
			onFinalize: (task, reason) => {
				process.stderr.write(`[pi-background-tasks] orphan task ${task.id} (pid ${task.pid}) ${reason}; finalized as ${task.status}\n`);
			},
		});
		orphanWatcher.start();
	};

	// vstack#15 round 5 reviewer-error MINOR: pre-1.2.2 snapshots have
	// no procIdent, so liveness on restore falls back to PID-only. That
	// is intentional backward-compat but unobservable in operations.
	// Emit a one-time warning per legacy task so operators notice when
	// long-running pre-upgrade bg_tasks linger across restarts. Dedup by
	// task id so repeated session_start calls don't spam.
	const legacyFallbackWarned = new Set<string>();
	const warnLegacyFallback = () => {
		for (const task of tasks.values()) {
			if (task.status !== "running") continue;
			if (task.restored !== true) continue;
			if (task.procIdent !== undefined) continue;
			if (legacyFallbackWarned.has(task.id)) continue;
			legacyFallbackWarned.add(task.id);
			const msg = `Background task ${task.id} (pid ${task.pid}) restored from a pre-1.2.2 snapshot without process identity. Liveness will degrade to PID-only, so a pid reuse could falsely keep the task alive. Restart will recapture identity for any task spawned after this upgrade.`;
			process.stderr.write(`[pi-background-tasks] ${msg}\n`);
			activeCtx?.ui.notify?.(msg, "warning");
		}
	};

	// Replay 'exit' wakeups for any task we restored in a terminal state
	// without ever notifying the agent. The canonical failure path: a long-
	// running session_shutdown or a mid-session restore coerced status
	// running->stopped (restoredTaskFromSnapshot) and the agent never saw
	// the exit. Without this replay the bg_task silently stalls (vstack#15).
	//
	// Restored tasks whose process is still alive remain status='running'
	// (handled by restoredTaskFromSnapshot) and are skipped by
	// selectMissedExits, so kill -9 / OOM with an orphaned-but-alive child
	// does not get a fake exit.
	const replayMissedExits = () => {
		const replayed = replayMissedExitsLifecycle(tasks.values(), lifecycleHooks);
		if (replayed > 0) {
			process.stderr.write(`[pi-background-tasks] replayed ${replayed} missed exit wake(s) for session=${activeSessionId ?? "unknown"}\n`);
		}
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

		const spawnedPid = child.pid ?? 0;
		const procIdent = spawnedPid > 0 ? (defaultReadProcessIdentity(spawnedPid) ?? undefined) : undefined;
		const task: ManagedTask = {
			child,
			closed: false,
			command,
			cwd,
			exitCode: null,
			exitNotified: false,
			procIdent,
			sessionId: activeSessionId ?? undefined,
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
			pid: spawnedPid,
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
		// Run one synchronous orphan-check before arming the interval so a
		// task whose pid already died between Pi shutdown and Pi restart
		// gets its exit wake without waiting one poll cycle.
		ensureOrphanWatcher();
		orphanWatcher?.checkOnce();
		warnLegacyFallback();
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
		orphanWatcher?.stop();
		orphanWatcher = null;
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

	registerAll(pi, {
		getActiveCtx: () => activeCtx,
		setActiveCtx: (ctx) => { activeCtx = ctx; },
		rememberSnapshot,
		sortedTasks,
		formatTaskListText,
		getTaskOutput,
		resolveTask,
		requestStop: (task, _reason) => requestStop(task, "user"),
		spawnTask,
		clearFinishedTasks,
		armForcedBackground,
		toggleWidget: () => {
			if (widgetMode === "hidden") widgetMode = lastVisibleWidgetMode;
			else {
				lastVisibleWidgetMode = widgetMode;
				widgetMode = "hidden";
			}
			if (activeCtx) syncWidget(activeCtx);
		},
		dashboardDeps,
		dashboardShortcut,
		backgroundBashShortcut,
		widgetToggleShortcut,
	});
}

