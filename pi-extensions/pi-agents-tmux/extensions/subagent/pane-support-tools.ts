import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Container } from "@earendil-works/pi-tui";
import {
	addArtifactPathSection,
	addWrappedSection,
	agentStatusLine,
	completionBodyWithoutPromptEcho,
	wrappedText,
} from "./format.js";
import { sanitizeCwdSnapshot } from "./cwd-snapshot.js";
import {
	GetSubagentResultParams,
	SteerSubagentParams,
	StopSubagentParams,
	WaitForSubagentIdleParams,
} from "./tools.js";
import {
	ICONS,
	type BridgeMetadata,
	type GetSubagentResultDetails,
	type PaneRegistryEntry,
	type PaneTaskRecord,
	type SteerSubagentDetails,
	type WaitForSubagentIdleDetails,
} from "./types.js";

interface PaneSupportToolDeps {
	[key: string]: any;
	ensurePaneBridgeMetadata: (runtimeRoot: string, entry: PaneRegistryEntry) => Promise<BridgeMetadata | undefined>;
	pi: ExtensionAPI;
}

export function registerPaneSupportTools(deps: PaneSupportToolDeps): void {
	const {
		bridgeTargetArgs,
		backfillTaskSummaryFromTranscript,
		createFollowUpTask,
		dashboardStatusFor,
		emitSubagentEvent,
		ensurePaneBridgeMetadata,
		execCapture,
		formatSteeringForChild,
		formatTaskRecordResult,
		inferTaskRecordKind,
		isFollowUpDelivery,
		isTerminalTaskStatus,
		latestTaskRecord,
		paneExists,
		paneSessionBelongsToRuntime,
		patchDashboard,
		pi,
		pollPaneCompletions,
		queueSteeringFallback,
		readPaneRegistry,
		readTaskRegistry,
		refreshTaskDiagnostics,
		taskNeedsSummaryBackfill,
		removeDashboardAgent,
		resolvePiBridgeBin,
		runtimeSessionId,
		sessionRuntimeDir,
		steerDiagnostics,
		stopPersistentPane,
		updateDashboard,
		updateDashboardFromTaskRecord,
		persistRuntimeSnapshot,
		waitForPaneIdle,
	} = deps;
	pi.registerTool({
		renderShell: "self",
		name: "get_subagent_result",
		label: "Get Agent Result",
		description: "Retrieve status/results for persistent pane agent tasks by taskId or latest agent task. Use waitFor: \"idle\" to wait for pane isIdle transition without shell polling. This is a recovery/status tool for pane tasks and does not change Flightdeck or Orchestration ownership.",
		parameters: GetSubagentResultParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			if (!params.taskId && !params.agent) {
				return {
					content: [{ type: "text", text: "Provide either taskId or agent." }],
					details: {} satisfies GetSubagentResultDetails,
					isError: true,
				};
			}
			const runtimeRoot = sessionRuntimeDir(runtimeSessionId(ctx));
			if ((params.waitFor ?? "completion") === "idle") {
				let agentName = params.agent;
				if (!agentName && params.taskId) {
					const records = await readTaskRegistry(runtimeRoot);
					agentName = records[params.taskId]?.agent;
				}
				if (!agentName) {
					return {
						content: [{ type: "text", text: `No task record found for ${params.taskId}; provide agent to wait for pane idle.` }],
						details: { taskId: params.taskId, waitFor: "idle" } satisfies GetSubagentResultDetails,
						isError: true,
					};
				}
				const waited = await waitForPaneIdle(ctx, agentName, params.timeoutMs ?? 30000);
				return {
					content: [{ type: "text", text: waited.text }],
					details: { agent: agentName, paneId: waited.details.paneId, taskId: params.taskId, waitFor: "idle", waitTimedOut: waited.details.timedOut } satisfies GetSubagentResultDetails,
					isError: waited.isError,
				};
			}
			const deadline = Date.now() + Math.max(0, Math.floor(params.timeoutMs ?? 30000));
			let record: PaneTaskRecord | undefined;
			let diagnostics: string[] = [];
			let completionMessageEmitted = false;
			do {
				completionMessageEmitted = (await pollPaneCompletions(runtimeRoot, pi, false)) > 0 || completionMessageEmitted;
				const records = await readTaskRegistry(runtimeRoot);
				record = params.taskId ? records[params.taskId] : latestTaskRecord(records, params.agent);
				if (record) {
					const refreshed = await refreshTaskDiagnostics(runtimeRoot, record);
					record = refreshed.record;
					diagnostics = refreshed.diagnostics;
				}
				if (!params.wait || (record && (isTerminalTaskStatus(record.status) || record.status === "needs_completion"))) break;
				if (Date.now() >= deadline) break;
				await new Promise((resolve) => setTimeout(resolve, 500));
			} while (true);

			if (!record) {
				const selector = params.taskId ? `taskId ${params.taskId}` : `agent ${params.agent}`;
				return { content: [{ type: "text", text: `No persistent agent task record found for ${selector}.` }], details: { agent: params.agent, taskId: params.taskId } satisfies GetSubagentResultDetails, isError: true };
			}
			if (typeof taskNeedsSummaryBackfill === "function" && typeof backfillTaskSummaryFromTranscript === "function" && taskNeedsSummaryBackfill(record)) {
				const backfilled = await backfillTaskSummaryFromTranscript(runtimeRoot, record);
				record = backfilled.record;
			}
			const finalRecord = record as PaneTaskRecord;
			updateDashboardFromTaskRecord({ ...finalRecord, updatedAt: new Date().toISOString() }, runtimeRoot);
			await persistRuntimeSnapshot(ctx, runtimeRoot);
			const diagnosticBlock = params.verbose && diagnostics.length > 0 ? `\n\n### Artifact diagnostics\n${diagnostics.map((line) => `- ${line}`).join("\n")}` : "";
			return {
				content: [{ type: "text", text: `${formatTaskRecordResult(finalRecord, params.verbose ?? false)}${diagnosticBlock}` }],
				details: { agent: finalRecord.agent, paneId: finalRecord.paneId, summary: finalRecord.summary, status: finalRecord.status, taskId: finalRecord.taskId, notes: finalRecord.notes, cwdSnapshot: sanitizeCwdSnapshot(finalRecord.cwdSnapshot), diagnostics: finalRecord.diagnostics, completionMessageEmitted } satisfies GetSubagentResultDetails,
			};
		},
		renderCall(_args, _theme, _context) {
			return new Container();
		},
		renderResult(result, _options, theme, context) {
			const raw = (result.content as any[] | undefined)?.find?.((part: any) => part?.type === "text" && typeof part.text === "string")?.text ?? "";
			const details = result.details as GetSubagentResultDetails | undefined;
			if (context?.isError) return wrappedText(`${theme.fg("error", ICONS.times)} ${theme.fg("toolTitle", "Agent result lookup failed")}\n${theme.fg("muted", raw)}`);
			if (details?.completionMessageEmitted) return new Container();
			const target = details?.agent ? details.agent : "unknown";
			const tone = details?.status === "completed" ? "success" : details?.status === "failed" ? "error" : "warning";
			return wrappedText(agentStatusLine(theme, target, details?.status ?? "result", tone));
		},
	});

	pi.registerTool({
		renderShell: "self",
		name: "wait_for_subagent_idle",
		label: "Wait Agent Idle",
		description: "Wait for a persistent pane agent's pi-bridge state to transition to isIdle=true. Use this instead of polling pi-bridge state in shell loops.",
		parameters: WaitForSubagentIdleParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const waited = await waitForPaneIdle(ctx, params.agent, params.timeoutMs ?? 30000);
			return {
				content: [{ type: "text", text: waited.text }],
				details: waited.details,
				isError: waited.isError,
			};
		},
		renderCall(_args, _theme, _context) {
			return new Container();
		},
		renderResult(result, _options, theme, context) {
			const raw = (result.content as any[] | undefined)?.find?.((part: any) => part?.type === "text" && typeof part.text === "string")?.text ?? "";
			const details = result.details as WaitForSubagentIdleDetails | undefined;
			if (context?.isError) return wrappedText(`${theme.fg("error", ICONS.times)} ${theme.fg("toolTitle", "Agent idle wait failed")}\n${theme.fg("muted", raw)}`);
			return wrappedText(agentStatusLine(theme, details?.agent ?? "agent", "idle", "success"));
		},
	});

	pi.registerTool({
		renderShell: "self",
		name: "steer_subagent",
		label: "Steer Agent",
		description: "Send a steering message to a persistent pane agent via pi-session-bridge. Bridge targeting requires the agent's child session to live under this parent session's runtime; otherwise an inbox-file fallback is queued instead.",
		parameters: SteerSubagentParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const runtimeRoot = sessionRuntimeDir(runtimeSessionId(ctx));
			const records = await readTaskRegistry(runtimeRoot);
			let agentName = params.agent;
			let record: PaneTaskRecord | undefined;
			if (params.taskId) {
				record = records[params.taskId];
				if (!record && !agentName) return { content: [{ type: "text", text: `No task record found for ${params.taskId}; provide agent to steer directly.` }], details: {}, isError: true };
				agentName = agentName ?? record?.agent;
			}
			if (!agentName) return { content: [{ type: "text", text: "Provide either agent or taskId." }], details: {}, isError: true };
			if (params.taskId && record) {
				const steerKind = inferTaskRecordKind(runtimeRoot, record);
				// Dashboard status lookup is metadata-only; never let a missing helper
				// (regression vstack#62) block the actual steer delivery.
				let steerDashboardStatus: any = record.status;
				try {
					if (typeof dashboardStatusFor === "function") {
						steerDashboardStatus = dashboardStatusFor(record.status, steerKind);
					} else {
						console.warn("steer_subagent: dashboardStatusFor missing from deps; using raw record.status for dashboard update.");
					}
				} catch (err) {
					console.warn(`steer_subagent: dashboardStatusFor threw (${(err as Error)?.message ?? err}); using raw record.status for dashboard update.`);
				}
				try {
					updateDashboard({
						agent: record.agent,
						artifacts: steerKind === "pane" ? Boolean(record.completionArchivePath || record.outboxFile || record.transcriptPath) : Boolean(record.transcriptPath),
						completedAt: record.completedAt,
						kind: steerKind,
						message: completionBodyWithoutPromptEcho(record.summary, record.task),
						model: record.model,
						effort: record.effort,
						paneId: record.paneId,
						startedAt: record.createdAt,
						status: steerDashboardStatus,
						task: record.task,
						taskId: record.taskId,
						transcriptPath: record.transcriptPath,
						updatedAt: new Date().toISOString(),
						usage: record.usage,
					});
				} catch (err) {
					console.warn(`steer_subagent: updateDashboard threw (${(err as Error)?.message ?? err}); continuing with steer delivery.`);
				}
			}

			const registry = await readPaneRegistry(runtimeRoot);
			const entry = registry[agentName];
			if (!entry) return { content: [{ type: "text", text: `No persistent pane registry entry for ${agentName} in runtime ${runtimeRoot}.` }], details: {}, isError: true };
			if (!paneSessionBelongsToRuntime(runtimeRoot, entry)) return { content: [{ type: "text", text: `Refusing to steer ${agentName}: pane session file is outside this runtime. Session: ${entry.sessionFile}. Runtime: ${runtimeRoot}` }], details: {}, isError: true };
			if (!(await paneExists(entry.paneId))) return { content: [{ type: "text", text: `Agent ${agentName} is not live.` }], details: {}, isError: true };

			const deliverAs = params.deliverAs ?? "steer";
			const followUpTask = isFollowUpDelivery(deliverAs) ? await createFollowUpTask(runtimeRoot, agentName, entry, params.message, deliverAs) : undefined;
			const metadata = await ensurePaneBridgeMetadata(runtimeRoot, entry);
			const bridgeBin = metadata ? await resolvePiBridgeBin() : undefined;
			const targetArgs = metadata ? bridgeTargetArgs(metadata) : [];
			const baseDetails = {
				agent: agentName,
				bridge: Boolean(bridgeBin && targetArgs.length > 0),
				bridgePid: metadata?.pid,
				bridgeSocket: metadata?.socket,
				deliverAs,
				paneId: entry.paneId,
				runtimeRoot,
				sessionFile: entry.sessionFile,
				taskId: followUpTask?.taskId ?? params.taskId ?? record?.taskId,
				outboxFile: followUpTask?.outboxFile,
			} satisfies SteerSubagentDetails;

			if (bridgeBin && targetArgs.length > 0) {
				const command = deliverAs === "follow-up" ? "follow-up" : deliverAs === "send" ? "send" : "steer";
				const args = [command, ...targetArgs];
				if (command === "send") args.push("--auto");
				args.push(formatSteeringForChild(agentName, params.message, true, deliverAs, followUpTask));
				const result = await execCapture(bridgeBin, args, { cwd: entry.cwd });
				if (result.code === 0) {
					patchDashboard(followUpTask?.taskId ?? params.taskId ?? record?.taskId, { bridge: true, paneId: entry.paneId });
					emitSubagentEvent(pi, "subagents:steered", {
						mode: "pane",
						agent: agentName,
						taskId: followUpTask?.taskId ?? params.taskId ?? record?.taskId,
						paneId: entry.paneId,
						bridge: true,
						bridgePid: metadata?.pid,
						bridgeSocket: metadata?.socket,
						deliverAs,
						runtimeRoot,
						transcriptPath: entry.sessionFile,
					});
					await persistRuntimeSnapshot(ctx, runtimeRoot);
					return {
						content: [{ type: "text", text: [`Steered ${agentName} via bridge (${deliverAs}).`, ...steerDiagnostics(baseDetails)].join("\n") }],
						details: baseDetails,
					};
				}
				const fallbackFile = await queueSteeringFallback(runtimeRoot, agentName, params.message, deliverAs, followUpTask);
				const details = { ...baseDetails, bridge: false, fallbackFile } satisfies SteerSubagentDetails;
				patchDashboard(followUpTask?.taskId ?? params.taskId ?? record?.taskId, { bridge: false, paneId: entry.paneId });
				emitSubagentEvent(pi, "subagents:steered", {
					mode: "pane",
					agent: agentName,
					taskId: followUpTask?.taskId ?? params.taskId ?? record?.taskId,
					paneId: entry.paneId,
					bridge: false,
					deliverAs,
					runtimeRoot,
					transcriptPath: entry.sessionFile,
				});
				await persistRuntimeSnapshot(ctx, runtimeRoot);
				return {
					content: [{ type: "text", text: [`Bridge for ${agentName} found, but pi-bridge ${command} failed (exit ${result.code}); queued inbox fallback instead.`, result.stderr || result.stdout ? `Bridge output: ${(result.stderr || result.stdout).trim()}` : "", ...steerDiagnostics(details)].filter(Boolean).join("\n") }],
					details,
				};
			}

			const fallbackFile = await queueSteeringFallback(runtimeRoot, agentName, params.message, deliverAs, followUpTask);
			const details = { ...baseDetails, bridge: false, fallbackFile } satisfies SteerSubagentDetails;
			patchDashboard(followUpTask?.taskId ?? params.taskId ?? record?.taskId, { bridge: false, paneId: entry.paneId });
			emitSubagentEvent(pi, "subagents:steered", {
				mode: "pane",
				agent: agentName,
				taskId: followUpTask?.taskId ?? params.taskId ?? record?.taskId,
				paneId: entry.paneId,
				bridge: false,
				deliverAs,
				runtimeRoot,
				transcriptPath: entry.sessionFile,
			});
			await persistRuntimeSnapshot(ctx, runtimeRoot);
			return {
				content: [
					{
						type: "text",
						text: [`No live bridge for ${agentName}; no bridge message was sent. Queued inbox fallback instead, which is not true mid-run steering and will be read when the pane is idle.`, ...steerDiagnostics(details)].join("\n"),
					},
				],
				details,
			};
		},
		renderCall(_args, _theme, _context) {
			return new Container();
		},
		renderResult(result, { expanded }, theme, context) {
			const raw = (result.content as any[] | undefined)?.find?.((part: any) => part?.type === "text" && typeof part.text === "string")?.text ?? "";
			const details = result.details as SteerSubagentDetails | undefined;
			if (context?.isError) return wrappedText(`${theme.fg("error", ICONS.times)} ${theme.fg("toolTitle", "Steer agent failed")}\n${theme.fg("muted", raw)}`);
			if (!details) return wrappedText(raw);
			const status = details.bridge ? "steered" : "queued steering";
			const via = details.bridge ? theme.fg("success", "bridge") : theme.fg("warning", "inbox fallback");
			if (expanded) {
				const container = new Container();
				container.addChild(wrappedText(`${agentStatusLine(theme, details.agent, status, details.bridge ? "success" : "warning")} ${theme.fg("dim", "via")} ${via}`));
				addWrappedSection(container, theme, "Delivery", details.deliverAs, "toolOutput");
				if (details.taskId) addWrappedSection(container, theme, "Task ID", details.taskId, "dim");
				addWrappedSection(container, theme, "Bridge", details.bridge ? "active" : "not used", details.bridge ? "toolOutput" : "muted");
				if (details.bridgePid) addWrappedSection(container, theme, "Bridge PID", details.bridgePid, "dim");
				addWrappedSection(container, theme, "Pane ID", details.paneId, "dim");
				addArtifactPathSection(container, theme, "Bridge socket", details.bridgeSocket);
				addArtifactPathSection(container, theme, "Child session", details.sessionFile);
				addArtifactPathSection(container, theme, "Runtime root", details.runtimeRoot);
				addArtifactPathSection(container, theme, "Inbox fallback", details.fallbackFile);
				addArtifactPathSection(container, theme, "Expected outbox", details.outboxFile);
				return container;
			}
			return wrappedText(`${agentStatusLine(theme, details.agent, status, details.bridge ? "success" : "warning")} ${theme.fg("dim", "via")} ${via}`);
		},
	});

	pi.registerTool({
		renderShell: "self",
		name: "stop_subagent",
		label: "Stop Agent",
		description: "Stop a persistent pane agent, kill its tmux pane, remove it from the live pane registry/dashboard, and mark any non-terminal active task as blocked. The pane session file is preserved; a later subagent call or /agents start resumes it unless forceSpawn or /agents new is used.",
		parameters: StopSubagentParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const runtimeRoot = sessionRuntimeDir(runtimeSessionId(ctx));
			const stopped = await stopPersistentPane(runtimeRoot, params.agent);
			removeDashboardAgent(stopped.agent);
			await persistRuntimeSnapshot(ctx, runtimeRoot);
			return {
				content: [{ type: "text", text: `Stopped ${stopped.agent}. Pane ${stopped.paneId} was killed and removed from the active registry. Session preserved at ${stopped.sessionFile}; default start/subagent will resume it. Use forceSpawn or /agents new for a fresh session.` }],
				details: { agent: stopped.agent, paneId: stopped.paneId, sessionFile: stopped.sessionFile },
			};
		},
		renderCall(_args, _theme, _context) {
			return new Container();
		},
		renderResult(result, _options, theme, context) {
			const raw = (result.content as any[] | undefined)?.find?.((part: any) => part?.type === "text" && typeof part.text === "string")?.text ?? "";
			const details = result.details as { agent?: string } | undefined;
			if (context?.isError) return wrappedText(`${theme.fg("error", ICONS.times)} ${theme.fg("toolTitle", "Stop agent failed")}\n${theme.fg("muted", raw)}`);
			return wrappedText(agentStatusLine(theme, details?.agent ?? "agent", "stopped", "success"));
		},
	});

}
