import type { ExtensionCommandContext, ExtensionContext, ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { discoverAgents, formatAgentList, type AgentScope } from "./agents.js";
import { activeDashboardItems, openAgentsBrowser, openTraceViewer, traceViewerItems } from "./browser.js";
import { compactPath, oneLinePreview } from "./format.js";
import { ensurePersistentPane, hasSavedPaneSession, paneExists, queuePersistentPaneTask, resetPersistentPaneSession, restoreArchivedPaneSession, stopPersistentPane, tmux } from "./pane.js";
import { formatTraceView, recordTraceRef, resolveTraceRecord } from "./renderers.js";
import { pollPaneCompletions, readPaneRegistry, readTaskRegistry, emitSubagentEvent } from "./tasks.js";
import { runtimeSessionId, sessionRuntimeDir } from "./settings.js";
import type { SubagentDashboardItem } from "./types.js";

type AgentCommandCompletion = { value: string; label: string; description?: string; pane?: boolean };

interface AgentsCommandDeps {
	[key: string]: any;
	pi: ExtensionAPI;
}

export function registerAgentsCommands(deps: AgentsCommandDeps): void {
	const {
		agentCommandCompletions,
		agentsArgumentCompletions,
		dashboardState,
		formatRelativeTime,
		persistRuntimeSnapshot,
		pi,
		removeDashboardAgent,
		syncDashboard,
	} = deps;
	const agentsHandler = async (args: string, ctx: ExtensionCommandContext) => {
		const parts = args.trim().split(/\s+/).filter(Boolean);
		const scopes = new Set<AgentScope>(["user", "project", "both"]);
		const command = parts[0];
		let scope: AgentScope = "project";
		let content = "";
		let messageDetails: Record<string, unknown> | undefined;

		const parentModel = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
		const parentThinkingLevel = pi.getThinkingLevel();
		const parentSessionId = runtimeSessionId(ctx);
		const runtimeRoot = sessionRuntimeDir(parentSessionId);
		const discovery = discoverAgents(ctx.cwd, scopes.has(parts.at(-1) as AgentScope) ? (parts.at(-1) as AgentScope) : scope);
		const findAgent = (name: string | undefined) => discovery.agents.find((candidate) => candidate.name === name);
		const sendMarkdown = (markdown: string) => {
			pi.sendMessage({ customType: "subagent-trace", content: markdown, display: true });
		};

		try {
			if (command === "start" || command === "new" || command === "resume") {
				const agent = findAgent(parts[1]);
				if (!agent) throw new Error(`Unknown agent: ${parts[1] ?? "(missing)"}`);
				if (!agent.pane) throw new Error(`Agent ${agent.name} is not configured for persistent panes. Add \`pane: true\` to its frontmatter to enable.`);
				const beforeRegistry = await readPaneRegistry(runtimeRoot);
				const before = beforeRegistry[agent.name];
				const hadLivePane = Boolean(before && (await paneExists(before.paneId)));
				const hadSavedSessionFlag = hasSavedPaneSession(runtimeRoot, agent.name);
				if (command === "new") {
					if (hadLivePane) await stopPersistentPane(runtimeRoot, agent.name);
					removeDashboardAgent(agent.name);
					await resetPersistentPaneSession(runtimeRoot, agent.name);
				} else if (command === "resume") {
					if (hadLivePane) await stopPersistentPane(runtimeRoot, agent.name);
					removeDashboardAgent(agent.name);
					await restoreArchivedPaneSession(runtimeRoot, agent.name, parts[2] ?? "latest");
				}
				const pane = await ensurePersistentPane(runtimeRoot, parentSessionId, ctx.cwd, agent, parentModel, parentThinkingLevel, pi.getActiveTools());
				if (!hadLivePane || command === "new") {
					emitSubagentEvent(pi, "subagents:created", {
						mode: "pane",
						agent: agent.name,
						paneId: pane.paneId,
						runtimeRoot,
						transcriptPath: pane.sessionFile,
					});
				}
				const startLabel = command === "new" ? "Started new" : command === "resume" ? "Resumed archived" : hadLivePane ? "Reused live" : hadSavedSessionFlag ? "Resumed saved" : "Started new";
				content = `${startLabel} ${agent.name} (${pane.windowName}).\nSession: ${pane.sessionFile}`;
				messageDetails = { action: "start", agent: agent.name, sessionFile: pane.sessionFile, windowName: pane.windowName, status: startLabel };
				await persistRuntimeSnapshot(ctx, runtimeRoot);
			} else if (command === "send") {
				const agent = findAgent(parts[1]);
				if (!agent) throw new Error(`Unknown agent: ${parts[1] ?? "(missing)"}`);
				if (!agent.pane) throw new Error(`Agent ${agent.name} is not configured for persistent panes. Add \`pane: true\` to its frontmatter to enable.`);
				const task = parts.slice(2).join(" ").trim();
				if (!task) throw new Error("Usage: /agents:send <name> <task>");
				const queued = await queuePersistentPaneTask(runtimeRoot, parentSessionId, ctx.cwd, agent, task, undefined, parentModel, parentThinkingLevel, pi, pi.getActiveTools());
				const sessionText = queued.sessionMode === "live" ? "reused live pane" : queued.sessionMode === "resumed" ? "resumed saved pane session" : "started new pane session";
				content = `Queued task for ${agent.name} (${sessionText}).\nArtifacts: inbox=${compactPath(queued.taskFile)} completion=${compactPath(queued.outboxFile)} transcript=${compactPath(queued.pane.sessionFile)}`;
				messageDetails = { action: "send", agent: agent.name, inboxFile: queued.taskFile, outboxFile: queued.outboxFile, taskId: queued.taskId, transcriptPath: queued.pane.sessionFile, status: sessionText };
				await persistRuntimeSnapshot(ctx, runtimeRoot);
			} else if (command === "attach") {
				const registry = await readPaneRegistry(runtimeRoot);
				const entry = registry[parts[1] ?? ""];
				if (!entry || !(await paneExists(entry.paneId))) throw new Error(`No live pane for agent: ${parts[1] ?? "(missing)"}`);
				const result = await tmux(["select-pane", "-t", entry.paneId]);
				if (result.code !== 0) throw new Error(result.stderr || result.stdout || "tmux select-pane failed");
				content = `Attached to ${entry.agent}.`;
				messageDetails = { action: "attach", agent: entry.agent };
			} else if (command === "stop") {
				const stopped = await stopPersistentPane(runtimeRoot, parts[1] ?? "");
				const stoppedAgent = stopped.agent;
				removeDashboardAgent(stoppedAgent);
				content = `Stopped ${stoppedAgent}.`;
				messageDetails = { action: "stop", agent: stoppedAgent };
				await persistRuntimeSnapshot(ctx, runtimeRoot);
			} else if (command === "collect") {
				const collected = await pollPaneCompletions(runtimeRoot, pi, false);
				content = `Collected ${collected} agent completion file${collected === 1 ? "" : "s"}.`;
				messageDetails = { action: "collect", count: collected };
				await persistRuntimeSnapshot(ctx, runtimeRoot);
			} else if (command === "status") {
				const registry = await readPaneRegistry(runtimeRoot);
				const lines = await Promise.all(
					Object.values(registry).map(async (entry) => {
						const live = await paneExists(entry.paneId);
						return `- ${entry.agent}: ${live ? "live" : "dead"} ${entry.windowName} model=${entry.model ?? "default"} lastTask=${entry.lastTaskAt ?? "never"}`;
					}),
				);
				content = [`# Persistent agent panes`, "", lines.join("\n") || "No persistent panes registered."].join("\n");
				messageDetails = { action: "status", count: lines.length };
			} else if (command === "trace") {
				const ref = parts.slice(1).join(" ").trim();
				if (!ref) throw new Error("Usage: /agents:trace <ref>");
				const records = await readTaskRegistry(runtimeRoot);
				const record = resolveTraceRecord(records, ref);
				if (!record) throw new Error(`No agent trace matched: ${ref}`);
				if (ctx.hasUI) {
					await openTraceViewer(ctx as ExtensionContext, `Trace ${recordTraceRef(record)}`, await traceViewerItems(record));
					return;
				}
				sendMarkdown(await formatTraceView(record, parts.includes("--verbose")));
				return;
			} else if (command === "toggle") {
				dashboardState.visible = !dashboardState.visible;
				syncDashboard(ctx as ExtensionContext);
				content = `Agent dashboard ${dashboardState.visible ? `shown (${dashboardState.mode})` : "hidden"}.`;
				messageDetails = { action: "toggle", status: dashboardState.visible ? `shown (${dashboardState.mode})` : "hidden" };
			} else {
				let showName: string | undefined;
				if (command === "show") {
					showName = parts[1];
					if (scopes.has(parts[2] as AgentScope)) scope = parts[2] as AgentScope;
				} else if (scopes.has(command as AgentScope)) {
					scope = command as AgentScope;
				} else if (command) {
					throw new Error(`Unknown /agents action: ${command}`);
				}

				if (ctx.hasUI) {
					await openAgentsBrowser(ctx, scope, showName, runtimeRoot, parentSessionId, parentModel, parentThinkingLevel, pi.getActiveTools(), () => activeDashboardItems(Object.values(dashboardState.items)), removeDashboardAgent);
					return;
				}

				const scopedDiscovery = discoverAgents(ctx.cwd, scope);
				if (showName) {
					const agent = scopedDiscovery.agents.find((candidate) => candidate.name === showName);
					content = agent
						? [
								`# Agent: ${agent.name}`,
								`Source: ${agent.source}`,
								`Path: ${agent.filePath}`,
								`Model: ${agent.model ?? "default"}`,
								`Deny tools: ${agent.denyTools && agent.denyTools.length > 0 ? agent.denyTools.join(", ") : "none"}`,
								`Persistent pane: ${agent.pane ? "yes" : "no"}`,
								"",
								agent.description,
								"",
								"---",
								"",
								agent.systemPrompt.trim(),
							]
							.join("\n")
						: `Unknown agent "${showName}" for scope "${scope}". Available: ${scopedDiscovery.agents
								.map((agent) => agent.name)
								.join(", ") || "none"}.`;
					messageDetails = { action: "show", agent: showName };
				} else {
					const formatted = formatAgentList(scopedDiscovery.agents);
					content = [
						`# Available agents (${scope})`,
						`Project agent dirs: ${scopedDiscovery.projectAgentsDir ?? "none"}`,
						"",
						formatted.text
							.split("; ")
							.map((line) => {
								const name = line.match(/^-?\s*([^ ]+)/)?.[1];
								const agent = scopedDiscovery.agents.find((candidate) => candidate.name === name);
								return `- ${line}${agent?.pane ? " [pane]" : ""}`;
							})
							.join("\n"),
						"",
						"Commands: `/agents show <name>`, `/agents:start <name>` (resume/reuse), `/agents:new <name>` (fresh session), `/agents:resume <name> [latest|archive-file]`, `/agents:send <name> <task>`, `/agents:attach <name>`, `/agents:stop <name>`, `/agents status`, `/agents:trace <ref>`, `/agents:toggle`. The popup's Monitor tab browses past tasks visually.",
					].join("\n");
					messageDetails = { action: "list", count: scopedDiscovery.agents.length };
				}
			}
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			content = `Error: ${message}`;
			messageDetails = { action: "error", error: message };
		}

		pi.sendMessage({ customType: "subagent-agents", content, details: messageDetails, display: true });
	};

	pi.registerCommand("agents", {
		description: "Agent browser and persistent pane manager.",
		getArgumentCompletions: agentsArgumentCompletions,
		handler: agentsHandler,
	});

	const paneAgentNameCompletions = (subcommand: string) => (prefix: string) => {
		const query = prefix.trimStart().toLowerCase();
		const needsPane = subcommand !== "show";
		const items = (agentCommandCompletions as AgentCommandCompletion[])
			.filter((agent) => (!needsPane || agent.pane) && (!query || agent.value.toLowerCase().startsWith(query)))
			.slice(0, 20)
			.map((agent) => ({ value: agent.value, label: agent.label, description: agent.description }));
		return items.length > 0 ? items : null;
	};

	const traceRefCompletions = (prefix: string) => {
		const query = prefix.trimStart().toLowerCase();
		const records = (Object.values(dashboardState.items) as SubagentDashboardItem[]).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
		const completions = records
			.filter((item) => !query || item.taskId.toLowerCase().includes(query) || item.agent.toLowerCase().includes(query))
			.slice(0, 20)
			.map((item) => {
				const when = formatRelativeTime(item.completedAt ?? item.startedAt ?? item.updatedAt);
				const summary = oneLinePreview(item.message, 60);
				return {
					value: item.taskId,
					label: `${item.agent} · ${when}`,
					description: summary ? `${item.status} · ${summary}` : item.status,
				};
			});
		return completions.length > 0 ? completions : null;
	};

	pi.registerCommand("agents:toggle", {
		description: "Toggle the agent dashboard",
		handler: async (_args, ctx) => agentsHandler("toggle", ctx),
	});

	for (const sub of ["start", "new", "resume", "send", "attach", "stop"] as const) {
		const description =
			sub === "start" ? "Start or reuse a persistent pane: /agents:start <name>" :
			sub === "new" ? "Start a persistent pane with a fresh session: /agents:new <name>" :
			sub === "resume" ? "Restore an archived pane session: /agents:resume <name> [latest|archive-file]" :
			sub === "send" ? "Queue a task for a persistent pane: /agents:send <name> <task>" :
			sub === "attach" ? "Focus an existing agent pane: /agents:attach <name>" :
			"Stop an agent pane: /agents:stop <name>";
		pi.registerCommand(`agents:${sub}`, {
			description,
			getArgumentCompletions: paneAgentNameCompletions(sub),
			handler: async (args, ctx) => agentsHandler(`${sub} ${args}`.trim(), ctx),
		});
	}

	pi.registerCommand("agents:trace", {
		description: "View an agent trace by ref/task id: /agents:trace <ref>",
		getArgumentCompletions: traceRefCompletions,
		handler: async (args, ctx) => agentsHandler(`trace ${args}`.trim(), ctx),
	});

}
