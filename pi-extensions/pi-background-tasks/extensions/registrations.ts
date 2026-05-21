// Pi tool / command / shortcut registrations for pi-background-tasks.
//
// Extracted from background-tasks.ts (vstack#15 reviewer-structure
// BLOCKER #2 size target). The host closure builds a RegistrationDeps
// object from its private state and calls registerAll(pi, deps). Each
// registration handler captures `deps` via closure, so the extracted
// module stays free of cross-module mutable state.

import { StringEnum } from "@earendil-works/pi-ai";
import type {
	AgentToolResult,
	ExtensionAPI,
	ExtensionContext,
	Theme,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import { BG_COMMAND } from "./constants.js";
import { openDashboard, type DashboardDeps } from "./dashboard.js";
import { formatRelativeTime, formatTaskLog, summarizeTaskStatus, taskLogTruncation } from "./format.js";
import { makeToolResult, renderBgToolResult, renderEmpty } from "./render.js";
import { bgToolResultTasks } from "./tool-result-details.js";
import type { BackgroundTaskSnapshot, ManagedTask, SpawnTaskOptions } from "./types.js";
import { NOTIFY_MODES } from "./wake-events.js";

export interface RegistrationDeps {
	getActiveCtx: () => ExtensionContext | null;
	setActiveCtx: (ctx: ExtensionContext) => void;
	rememberSnapshot: (task: ManagedTask) => BackgroundTaskSnapshot;
	sortedTasks: () => ManagedTask[];
	formatTaskListText: () => string;
	getTaskOutput: (task: ManagedTask) => string;
	resolveTask: (id?: string, pid?: number) => ManagedTask | null;
	requestStop: (task: ManagedTask | null, reason: "user") => { ok: boolean; message: string };
	spawnTask: (options: SpawnTaskOptions) => ManagedTask;
	clearFinishedTasks: () => number;
	armForcedBackground: (ctx: ExtensionContext, source: "shortcut" | "command") => void;
	toggleWidget: () => void;
	dashboardDeps: DashboardDeps;
	dashboardShortcut: string;
	backgroundBashShortcut: string;
	widgetToggleShortcut: string;
}

function registerTools(pi: ExtensionAPI, deps: RegistrationDeps): void {
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
			if (params.action === "list") {
				const tasks = deps.sortedTasks().map(deps.rememberSnapshot);
				return makeToolResult(deps.formatTaskListText(), { action: "list", tasks: bgToolResultTasks(tasks) });
			}
			const task = deps.resolveTask(undefined, params.pid);
			if (!task) throw new Error("No background task matched that pid.");
			if (params.action === "log") {
				const output = deps.getTaskOutput(task);
				const cwd = deps.getActiveCtx()?.cwd;
				const truncation = taskLogTruncation(output, task.logFile, cwd);
				return makeToolResult(formatTaskLog(output, task.logFile, cwd), {
					action: "log",
					task: deps.rememberSnapshot(task),
					...(truncation ? { fullOutputPath: task.logFile, truncation } : {}),
				});
			}
			const stopped = deps.requestStop(task, "user");
			if (!stopped.ok) throw new Error(stopped.message);
			return makeToolResult(stopped.message, { action: "stop", task: deps.rememberSnapshot(task) });
		},
		renderCall() { return renderEmpty(); },
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
			notifyMode: Type.Optional(StringEnum(NOTIFY_MODES, {
				description: "Output wake mode: always=every output update, transition=only changed output tail hash, first-match-only=one notifyPattern match then suppress output wakes.",
			})),
			dedupeKey: Type.Optional(Type.String({ description: "Optional key used by notifyMode=transition to coalesce matching output wakes across tasks." })),
			pid: Type.Optional(Type.Number({ description: "PID for action=log or action=stop" })),
			timeoutSeconds: Type.Optional(Type.Number({ description: "Timeout for spawned tasks. Defaults to 0 (disabled)." })),
			title: Type.Optional(Type.String({ description: "Optional display label for action=spawn" })),
		}),
		async execute(_toolCallId, params): Promise<AgentToolResult<unknown>> {
			if (params.action === "list") {
				const tasks = deps.sortedTasks().map(deps.rememberSnapshot);
				return makeToolResult(deps.formatTaskListText(), { action: "list", tasks: bgToolResultTasks(tasks) });
			}
			if (params.action === "clear") {
				const removed = deps.clearFinishedTasks();
				return makeToolResult(`Removed ${removed} finished background task(s).`, { action: "clear", removed });
			}
			if (params.action === "spawn") {
				const task = deps.spawnTask({
					command: params.command ?? "",
					cwd: params.cwd,
					notifyOnExit: params.notifyOnExit,
					notifyOnOutput: params.notifyOnOutput,
					notifyPattern: params.notifyPattern,
					notifyMode: params.notifyMode,
					dedupeKey: params.dedupeKey,
					timeoutSeconds: params.timeoutSeconds,
					title: params.title,
				});
				return makeToolResult(
					`Started ${task.id} (pid ${task.pid}) in the background.\nCommand: ${task.command}\nCwd: ${task.cwd}\nLog: ${task.logFile}\nExpiry: ${
						task.expiresAt != null ? formatRelativeTime(task.expiresAt) : "none"
					}\nWakeups: exit=${task.notifyOnExit ? "yes" : "no"}, output=${
						task.notifyOnOutput ? (task.notifyPattern ?? "yes") : "no"
					}, mode=${task.notifyMode ?? "always"}${task.dedupeKey ? `, dedupeKey=${task.dedupeKey}` : ""}`,
					{ action: "spawn", task: deps.rememberSnapshot(task) },
				);
			}
			const task = deps.resolveTask(params.id, params.pid);
			if (!task) throw new Error("No background task matched that id or pid.");
			if (params.action === "log") {
				const output = deps.getTaskOutput(task);
				const cwd = deps.getActiveCtx()?.cwd;
				const truncation = taskLogTruncation(output, task.logFile, cwd);
				return makeToolResult(formatTaskLog(output, task.logFile, cwd), {
					action: "log",
					task: deps.rememberSnapshot(task),
					...(truncation ? { fullOutputPath: task.logFile, truncation } : {}),
				});
			}
			const stopped = deps.requestStop(task, "user");
			if (!stopped.ok) throw new Error(stopped.message);
			return makeToolResult(stopped.message, { action: "stop", task: deps.rememberSnapshot(task) });
		},
		renderCall() { return renderEmpty(); },
		renderResult(result: any, options: any, theme: Theme, context: any) {
			return renderBgToolResult(result, options, theme, context);
		},
	});
}

function registerCommands(pi: ExtensionAPI, deps: RegistrationDeps): void {
	const taskIdCompletions = (prefix: string) => {
		const query = prefix.trimStart().toLowerCase();
		const items = deps.sortedTasks()
			.filter((task) => !query || task.id.toLowerCase().startsWith(query) || String(task.pid).startsWith(query))
			.map((task) => ({
				description: `${summarizeTaskStatus(task.status, task.exitCode, task.terminationReason)} · ${task.command}`,
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
			const taskItems = deps.sortedTasks()
				.filter((task) => !taskQuery || task.id.toLowerCase().startsWith(taskQuery) || String(task.pid).startsWith(taskQuery))
				.map((task) => ({
					description: `${summarizeTaskStatus(task.status, task.exitCode, task.terminationReason)} · ${task.command}`,
					label: task.id,
					value: `${subcommand} ${task.id}`,
				}));
			return taskItems.length > 0 ? taskItems : null;
		},
		handler: async (args, ctx) => {
			deps.setActiveCtx(ctx);
			const trimmed = args.trim();
			if (!trimmed) { await openDashboard(ctx, deps.dashboardDeps); return; }
			if (trimmed === "list") { ctx.ui.notify(deps.formatTaskListText(), "info"); return; }
			if (trimmed === "next") { deps.armForcedBackground(ctx, "command"); return; }
			if (trimmed === "clear") { ctx.ui.notify(`Removed ${deps.clearFinishedTasks()} finished background task(s).`, "info"); return; }
			if (trimmed.startsWith("run ")) {
				const task = deps.spawnTask({ command: trimmed.slice(4), cwd: ctx.cwd });
				ctx.ui.notify(`Started ${task.id} (pid ${task.pid}) in the background.`, "info");
				return;
			}
			const inspectMatch = trimmed.match(/^(?:watch|log)\s+(.+)$/);
			if (inspectMatch) {
				const task = deps.resolveTask(inspectMatch[1]?.trim());
				if (!task) { ctx.ui.notify("No background task matched that id or pid.", "warning"); return; }
				if (trimmed.startsWith("log ")) ctx.ui.notify(formatTaskLog(deps.getTaskOutput(task), task.logFile, ctx.cwd), "info");
				else await openDashboard(ctx, deps.dashboardDeps, task);
				return;
			}
			if (trimmed.startsWith("stop ")) {
				const stopped = deps.requestStop(deps.resolveTask(trimmed.slice(5).trim()), "user");
				ctx.ui.notify(stopped.message, stopped.ok ? "info" : "warning");
				return;
			}
			ctx.ui.notify(`Unknown /${BG_COMMAND} action. Try run <command>, list, log <id>, watch <id>, stop <id>, or clear.`, "warning");
		},
	});

	pi.registerCommand(`${BG_COMMAND}:list`, {
		description: "Show tracked background tasks",
		handler: async (_args, ctx) => { deps.setActiveCtx(ctx); ctx.ui.notify(deps.formatTaskListText(), "info"); },
	});
	pi.registerCommand(`${BG_COMMAND}:next`, {
		description: "Move the next bash command to a background task",
		handler: async (_args, ctx) => { deps.setActiveCtx(ctx); deps.armForcedBackground(ctx, "command"); },
	});
	pi.registerCommand(`${BG_COMMAND}:clear`, {
		description: "Remove finished background tasks",
		handler: async (_args, ctx) => { deps.setActiveCtx(ctx); ctx.ui.notify(`Removed ${deps.clearFinishedTasks()} finished background task(s).`, "info"); },
	});
	pi.registerCommand(`${BG_COMMAND}:run`, {
		description: "Spawn a background shell task: /bg:run <command>",
		handler: async (args, ctx) => {
			deps.setActiveCtx(ctx);
			const command = args.trim();
			if (!command) { ctx.ui.notify("Usage: /bg:run <command>", "warning"); return; }
			const task = deps.spawnTask({ command, cwd: ctx.cwd });
			ctx.ui.notify(`Started ${task.id} (pid ${task.pid}) in the background.`, "info");
		},
	});
	pi.registerCommand(`${BG_COMMAND}:stop`, {
		description: "Terminate a running background task: /bg:stop <id>",
		getArgumentCompletions: taskIdCompletions,
		handler: async (args, ctx) => {
			deps.setActiveCtx(ctx);
			const stopped = deps.requestStop(deps.resolveTask(args.trim()), "user");
			ctx.ui.notify(stopped.message, stopped.ok ? "info" : "warning");
		},
	});
}

function registerShortcuts(pi: ExtensionAPI, deps: RegistrationDeps): void {
	if (deps.dashboardShortcut !== "none") {
		pi.registerShortcut(deps.dashboardShortcut, {
			description: "Open the background task dashboard",
			handler: async (ctx) => {
				deps.setActiveCtx(ctx as ExtensionContext);
				await openDashboard(ctx as ExtensionContext, deps.dashboardDeps);
			},
		});
	}
	if (deps.dashboardShortcut.toLowerCase() !== "f5") {
		pi.registerShortcut("f5", {
			description: "Open the background task dashboard",
			handler: async (ctx) => {
				deps.setActiveCtx(ctx as ExtensionContext);
				await openDashboard(ctx as ExtensionContext, deps.dashboardDeps);
			},
		});
	}
	if (deps.backgroundBashShortcut !== "none") {
		pi.registerShortcut(deps.backgroundBashShortcut, {
			description: "Move the next not-yet-started bash command to a background task",
			handler: async (ctx) => {
				deps.setActiveCtx(ctx as ExtensionContext);
				deps.armForcedBackground(ctx as ExtensionContext, "shortcut");
			},
		});
	}
	if (deps.widgetToggleShortcut !== "none") {
		pi.registerShortcut(deps.widgetToggleShortcut, {
			description: "Toggle background task mini-dashboard",
			handler: async (ctx) => {
				deps.setActiveCtx(ctx as ExtensionContext);
				deps.toggleWidget();
			},
		});
	}
}

export function registerAll(pi: ExtensionAPI, deps: RegistrationDeps): void {
	registerTools(pi, deps);
	registerCommands(pi, deps);
	registerShortcuts(pi, deps);
}
