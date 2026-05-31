/**
 * Agent delegation tool — delegate tasks to specialized agents.
 *
 * Spawns a separate `pi` process for each agent invocation, giving it an
 * isolated context window. Supports single, parallel, and chain modes plus
 * persistent tmux pane agents.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { formatSize, getMarkdownTheme, type ExtensionAPI, type ExtensionCommandContext, type ExtensionContext, type Theme } from "@earendil-works/pi-coding-agent";
import { Container, Markdown, Spacer, truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { discoverAgents, formatAgentList, type AgentConfig, type AgentScope } from "./agents.js";
import { registerAgentsCommands } from "./agents-command.js";
import {
	activeDashboardItems,
	editAgentFrontmatterOverrides,
	formatRelativeTime,
	openAgentsBrowser,
	openTraceViewer,
	showAgentEditConfirmation,
	traceViewerItems,
} from "./browser.js";
import {
	isDashboardAnimatingStatus,
	dashboardStatusFor,
	isDashboardWorkingStatus,
	renderDashboardWidgetLines,
	sortDashboardItems,
} from "./dashboard.js";
import { sanitizeCwdSnapshot, sanitizeCwdSnapshotText } from "./cwd-snapshot.js";
import {
	autoShowAgentDashboardOnce,
	cycleAgentDashboard,
	normalizeAgentDashboardVisibility,
} from "./dashboard-visibility.js";
import {
	addArtifactPathSection,
	addSectionHeading,
	addWrappedSection,
	agentStatusLine,
	agentsCommandBullet,
	agentWord,
	ansiMagenta,
	COMPLETION_SUMMARY_UNAVAILABLE,
	compactPath,
	completionBodyWithoutPromptEcho,
	finalOutputLooksLikeToolEcho,
	finalResponseSuppressedLine,
	formatToolCall,
	formatUsageStats,
	framedComponent,
	framedMessage,
	getDisplayItems,
	getFinalOutput,
	normalizeSummaryText,
	oneLinePreview,
	parseTranscriptUsage,
	resolveSubagentStatuslineInfo,
	shortTaskId,
	subagentBranch,
	wrappedText,
} from "./format.js";
import {
	formatInventoryValidationError,
	runChainDispatch,
	runParallelDispatch,
	runSingleDispatch,
	validateAgentInventory,
	type AgentInventory,
} from "./dispatch.js";
import {
	ensurePaneBridgeMetadata,
	ensurePersistentPane,
	execCapture,
	createCachedPiBridgeResolver,
	migrateLegacyPackageRuntime,
	migrateLegacyProjectRuntime,
	PI_SUBAGENT_CHILD_PANE_ENV,
	paneExists,
	queuePersistentPaneTask,
	resetPersistentPaneSession,
	resolvePiBridgeBin,
	restoreArchivedPaneSession,
	runPersistentPaneAgent,
	setCurrentTmuxPaneTitle,
	stopPersistentPane,
	tmux,
	hasSavedPaneSession,
} from "./pane.js";
import { safeFileName } from "./names.js";
import {
	completionPath,
	doneDir,
	inboxDir,
	processingDir,
} from "./paths.js";
import { randomHex } from "./random.js";
import {
	createAgentEndWatchdog,
	defaultOutboxExists,
	defaultScheduleAfter,
	defaultWriteSyntheticOutbox,
	WATCHDOG_REASON,
	watchdogEnabledFromEnv,
	watchdogGraceMsFromEnv,
} from "./agent-end-watchdog.js";
import {
	backoffLadderSecFromEnv as rateLimitBackoffLadderSecFromEnv,
	createSubagentRateLimitWatchdog,
	defaultScheduleAfter as rateLimitDefaultScheduleAfter,
	maxAttemptsFromEnv as rateLimitMaxAttemptsFromEnv,
	watchdogEnabledFromEnv as rateLimitWatchdogEnabledFromEnv,
} from "./rate-limit-watchdog.js";
import {
	createIdleStallWatchdog,
	STALL_WATCHDOG_REASON,
	stallWatchdogEnabledFromEnv,
	stallWatchdogIntervalMsFromEnv,
	stallWatchdogThresholdMsFromEnv,
} from "./idle-stall-watchdog.js";
import {
	probePaneIdle,
	BRIDGE_IDLE_PROBE_DEFAULT_TIMEOUT_MS,
} from "./idle-stall-probe.js";
import { registerPaneSupportTools } from "./pane-support-tools.js";
import { MINI_DASHBOARD_RANK, setMiniDashboardWidget } from "./stacked-widget.js";
import {
	formatTaskRecordResult,
	formatTraceView,
	paneCompletionTone,
	recordTraceRef,
	renderAgentsCommandMessage,
	renderPaneCompletionMessage,
	resolveTraceRecord,
} from "./renderers.js";
import {
	sessionFileTailMatchesLeaf,
	appendBoundedSnapshot,
	stableSessionSnapshotFingerprint,
} from "./session-persistence.js";
import { subagentToolRenderers } from "./subagent-render.js";
import { loadTaskRegistrySync, taskNumberById } from "./task-records.js";
import {
	prepareSingleResultForReturn,
	runSingleAgent,
	detailsWithTruncation,
} from "./runner.js";
import {
	animateSpinnersEnabled,
	dashboardDefaultCollapsed,
	dashboardEnabled,
	dashboardMaxItems,
	dashboardShortcut,
	normalizeReasoningEffort,
	popupShortcut,
	quietInline,
	runtimeDirForContext,
	runtimeSessionId,
	sessionRuntimeDir,
	settingBoolean,
	settingNumber,
} from "./settings.js";
import {
	appendUniqueDiagnostic,
	backfillTaskSummaryFromTranscript,
	completionParseErrorMessage,
	createTaskId,
	emitSubagentEvent,
	inferTaskRecordKind,
	isTerminalTaskStatus,
	latestTaskRecord,
	markTaskNeedsCompletion,
	normalizeUsageStats,
	paneSessionBelongsToRuntime,
	pollPaneCompletions,
	readPaneCompletionFile,
	readPaneRegistry,
	readTaskRegistry,
	recordTaskDispatchFailure,
	refreshTaskDiagnostics,
	taskNeedsSummaryBackfill,
	updateTaskRegistry,
	upsertTaskRecord,
	writePaneRegistry,
	writeTaskRegistry,
} from "./tasks.js";
import {
	CompleteSubagentParams,
	DelegateSubagentParams,
	GetSubagentResultParams,
	SteerSubagentParams,
	StopSubagentParams,
	SubagentParams,
	WaitForSubagentIdleParams,
} from "./tools.js";
import {
	COLLAPSED_ITEM_COUNT,
	DEFAULT_RESULT_MAX_BYTES,
	DEFAULT_RESULT_MAX_LINES,
	type DashboardKind,
	type DisplayItem,
	type GetSubagentResultDetails,
	ICONS,
	INSTALL_SYMBOL,
	MAX_CONCURRENCY,
	type PaneCompletionMessageDetails,
	type PaneRegistry,
	type PaneTaskRegistry,
	type PaneTaskRecord,
	type PaneTaskStatus,
	type SingleResult,
	type SteerSubagentDetails,
	STATS_BRIDGE_SYMBOL,
	STATUSLINE_SYMBOL,
	SUBAGENT_STATE_TYPE,
	type SubagentDashboardItem,
	type SubagentDashboardState,
	type SubagentDetails,
	type SubagentStatsBridge,
	type SubagentStatsItem,
	type SubagentStatuslineBridge,
	type WaitForSubagentIdleDetails,
	SUBAGENT_WIDGET_KEY,
	type UsageStats,
} from "./types.js";
import { extractBridgeState, waitForIdleTransition } from "./wait.js";

function bridgeTargetArgs(metadata: { socket?: string; pid?: string }): string[] {
	if (metadata.socket) return ["--socket", metadata.socket];
	if (metadata.pid) return ["--pid", metadata.pid];
	return [];
}

function envFlag(value: string | undefined): boolean {
	return /^(1|true|yes|on)$/i.test(value?.trim() ?? "");
}

function launchInventory(cwd: string, scope: AgentScope, allowed: AgentConfig[]): AgentInventory {
	void scope;
	const project = discoverAgents(cwd, "project").agents;
	const user = discoverAgents(cwd, "user").agents;
	return { allowed, project, user };
}

function collectRequestedAgentNames(params: Record<string, any>): Set<string> {
	const requested = new Set<string>();
	if (Array.isArray(params.chain)) for (const step of params.chain) if (typeof step?.agent === "string") requested.add(step.agent);
	if (Array.isArray(params.tasks)) for (const task of params.tasks) if (typeof task?.agent === "string") requested.add(task.agent);
	if (typeof params.agent === "string") requested.add(params.agent);
	return requested;
}

type FollowUpTask = { taskId: string; outboxFile: string; taskFile?: string };

interface PersistedSubagentRuntimeState {
	version: 1;
	panes: PaneRegistry;
	tasks: PaneTaskRegistry;
	updatedAt: string;
}

function latestRecordTimestamp(record: PaneTaskRecord | undefined): string {
	return record?.updatedAt ?? record?.completedAt ?? record?.createdAt ?? "";
}

function isLiveDashboardStatus(status: SubagentDashboardItem["status"] | undefined): boolean {
	return status === "queued" || status === "running" || status === "waiting";
}

function timestampMs(value: string | undefined): number {
	const parsed = Date.parse(value ?? "");
	return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeEventSessionMode(value: unknown): "fresh" | "resumed" | "new" | undefined {
	return value === "fresh" || value === "resumed" || value === "new" ? value : undefined;
}

function normalizeEventSessionKey(value: unknown): string | undefined {
	const trimmed = typeof value === "string" ? value.trim() : "";
	return trimmed || undefined;
}

function isPersistedSubagentRuntimeState(value: unknown): value is PersistedSubagentRuntimeState {
	if (!value || typeof value !== "object" || Array.isArray(value)) return false;
	const candidate = value as Partial<PersistedSubagentRuntimeState>;
	return candidate.version === 1
		&& Boolean(candidate.panes && typeof candidate.panes === "object" && !Array.isArray(candidate.panes))
		&& Boolean(candidate.tasks && typeof candidate.tasks === "object" && !Array.isArray(candidate.tasks));
}

function isFollowUpDelivery(deliverAs: string): boolean {
	return deliverAs === "follow-up" || deliverAs === "send";
}

function steerDiagnostics(details: SteerSubagentDetails): string[] {
	return [
		`Target agent: ${details.agent}`,
		details.taskId ? `Task ID: ${details.taskId}` : "Task ID: (not specified)",
		`Delivery: ${details.deliverAs}`,
		`Bridge: ${details.bridge ? "active" : "not used"}`,
		details.bridgePid ? `Bridge PID: ${details.bridgePid}` : "Bridge PID: (none)",
		details.bridgeSocket ? `Bridge socket: ${details.bridgeSocket}` : "Bridge socket: (none)",
		`Child session file: ${details.sessionFile}`,
		`Runtime root: ${details.runtimeRoot}`,
		details.fallbackFile ? `Inbox fallback: ${details.fallbackFile}` : "",
		details.outboxFile ? `Expected outbox: ${details.outboxFile}` : "",
	].filter(Boolean);
}

async function createFollowUpTask(runtimeRoot: string, agentName: string, entry: { paneId: string; sessionFile: string }, message: string, deliverAs = "follow-up"): Promise<FollowUpTask> {
	const taskId = createTaskId(agentName);
	const outboxFile = completionPath(runtimeRoot, agentName, taskId);
	await upsertTaskRecord(runtimeRoot, {
		taskId,
		agent: agentName,
		task: message,
		status: "running",
		sessionMode: "resumed",
		kind: "pane",
		paneId: entry.paneId,
		outboxFile,
		transcriptPath: entry.sessionFile,
		deliverAs,
		createdAt: new Date().toISOString(),
		updatedAt: new Date().toISOString(),
	});
	return { taskId, outboxFile };
}

async function queueSteeringFallback(runtimeRoot: string, agentName: string, message: string, deliverAs: string = "steer", followUpTask?: FollowUpTask): Promise<string> {
	const steeringId = followUpTask?.taskId ?? `${safeFileName(`${agentName}-steer`)}-${Date.now()}-${randomHex(8)}`;
	const filePath = path.join(inboxDir(runtimeRoot, agentName), `${safeFileName(steeringId)}.md`);
	const content = formatSteeringForChild(agentName, message, false, deliverAs, followUpTask);
	await fs.promises.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
	await fs.promises.writeFile(filePath, content, { encoding: "utf-8", mode: 0o600 });
	if (followUpTask) {
		await updateTaskRegistry(runtimeRoot, (records) => {
			const existing = records[followUpTask.taskId];
			if (existing) records[followUpTask.taskId] = { ...existing, kind: "pane", status: "queued", inboxFile: filePath, deliverAs, updatedAt: new Date().toISOString() };
		});
		followUpTask.taskFile = filePath;
	}
	return filePath;
}

function formatSteeringForChild(agentName: string, message: string, liveBridge: boolean, deliverAs: string = "steer", followUpTask?: FollowUpTask): string {
	const followUp = isFollowUpDelivery(deliverAs);
	const schema = followUpTask ? JSON.stringify({ agent: agentName, taskId: followUpTask.taskId, status: "completed|blocked|failed", summary: "1-3 sentence result", filesChanged: ["path/or empty"], validation: ["command/result or empty"], notes: "optional" }) : "";
	return [
		`${followUp ? "Follow-up task" : "Steering update"} for ${agentName}${liveBridge ? " (live bridge)" : " (queued fallback)"}:`,
		...(followUpTask ? [`Task ID: ${followUpTask.taskId}`, `Completion outbox: ${followUpTask.outboxFile}`] : []),
		"",
		message.trim(),
		...(followUp ? ["", "When done, call complete_subagent with status, summary, filesChanged, validation, and optional notes.", ...(followUpTask ? [`If complete_subagent is unavailable, write exactly one JSON object to ${followUpTask.outboxFile} using this schema: ${schema}`] : [])] : []),
	].join("\n");
}

/**
 * Cap an aboveEditor widget's line count so it can never push chat / status above
 * the terminal viewport top — the trigger for pi-tui's full-screen redraw
 * (firstChanged < prevViewportTop). Reserves room for editor + footer + chat sliver.
 */
function clampAboveEditorWidget(lines: string[], terminalRows: number, theme: Theme): string[] {
	const reserveForOtherUi = 10;
	const maxLines = Math.max(4, terminalRows - reserveForOtherUi);
	if (lines.length <= maxLines) return lines;
	const hidden = lines.length - (maxLines - 1);
	return [...lines.slice(0, maxLines - 1), theme.fg("muted", `… ${hidden} more (open agents browser for full view)`)];
}

function appendRuntimeDiagnostic(runtimeRoot: string | undefined, source: string, message: string): void {
	if (!runtimeRoot) return;
	const logFile = path.join(runtimeRoot, "subagent-diagnostics.jsonl");
	const entry = { ts: new Date().toISOString(), source, message };
	void fs.promises.appendFile(logFile, `${JSON.stringify(entry)}\n`, { encoding: "utf-8", mode: 0o600 }).catch(() => undefined);
}

export default function (pi: ExtensionAPI) {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;

	let currentRuntimeRoot: string | undefined;
	const pendingRuntimeDiagnostics: Array<{ source: string; message: string }> = [];
	const logRuntimeDiagnostic = (source: string, message: string) => {
		if (!currentRuntimeRoot) {
			pendingRuntimeDiagnostics.push({ source, message });
			return;
		}
		appendRuntimeDiagnostic(currentRuntimeRoot, source, message);
	};
	const flushRuntimeDiagnostics = () => {
		if (!currentRuntimeRoot || pendingRuntimeDiagnostics.length === 0) return;
		for (const pending of pendingRuntimeDiagnostics.splice(0)) appendRuntimeDiagnostic(currentRuntimeRoot, pending.source, pending.message);
	};
	const logIdleStallDiagnostic = (message: string) => logRuntimeDiagnostic("idle-stall-watchdog", message);
	const resolveIdleProbeBridgeBin = createCachedPiBridgeResolver(resolvePiBridgeBin, logIdleStallDiagnostic);

	const childAgentName = process.env.PI_SUBAGENT_CHILD_AGENT;
	const childOwnsVisiblePane = envFlag(process.env[PI_SUBAGENT_CHILD_PANE_ENV]);
	const statuslineBridge: SubagentStatuslineBridge = {
		getCurrentSubagent(cwd?: string) {
			return resolveSubagentStatuslineInfo(childAgentName, cwd);
		},
	};
	(globalThis as unknown as Record<PropertyKey, unknown>)[STATUSLINE_SYMBOL] = statuslineBridge;
	let pendingChildCompletion: { agent: string; taskId: string; status: string; outboxFile: string } | undefined;
	let completionPoller: ReturnType<typeof setInterval> | undefined;
	let completionPollInFlight = false;
	let childInboxPoller: ReturnType<typeof setInterval> | undefined;
	let childTitlePoller: ReturnType<typeof setInterval> | undefined;
	let childPollInFlight = false;
	let childCurrentTaskFile: string | undefined;
	let agentCommandCompletions: Array<{ value: string; label: string; description: string; pane: boolean }> = [];

	// Agent-end watchdog (vstack#66): rides on `pi.on("agent_end")` for tasks
	// delivered without an inbox file (bridge follow-ups). The existing handler
	// above already covers the childCurrentTaskFile path; this watchdog covers
	// active task records for the same agent that lack a processing file.
	let lastChildAgentEndCtx: ExtensionContext | undefined;
	const agentEndWatchdog = createAgentEndWatchdog({
		graceMs: watchdogGraceMsFromEnv(),
		now: () => Date.now(),
		scheduleAfter: defaultScheduleAfter,
		isEnabled: () => watchdogEnabledFromEnv(),
		outboxPathFor: (runtimeRoot, agentName, taskId) => completionPath(runtimeRoot, agentName, taskId),
		readTaskRecord: async (runtimeRoot, taskId) => {
			const records = await readTaskRegistry(runtimeRoot);
			return records[taskId];
		},
		outboxExists: defaultOutboxExists,
		isPaneIdle: async () => {
			try {
				return lastChildAgentEndCtx?.isIdle?.() ?? true;
			} catch {
				return true;
			}
		},
		writeSyntheticOutbox: defaultWriteSyntheticOutbox,
		markFired: async (runtimeRoot, agentName, taskId, payload) => {
			await markTaskNeedsCompletion(runtimeRoot, agentName, taskId, {
				diagnostic: `${payload.summary} (reason: ${WATCHDOG_REASON})`,
				outboxFile: completionPath(runtimeRoot, agentName, taskId),
			});
		},
		logWarn: (msg) => {
			console.warn(msg);
		},
	});

	// Rate-limit watchdog (vstack#108): rides on `pi.on("message_end")` for
	// the canonical Claude / pi-coding-agent rate-limit error shape.
	// Schedules a retry-with-backoff steer via pi.sendUserMessage and
	// gates the agent-end watchdog so its synthetic needs_completion
	// outbox does not race the recovery.
	const rateLimitWatchdog = createSubagentRateLimitWatchdog({
		now: () => Date.now(),
		scheduleAfter: rateLimitDefaultScheduleAfter,
		isEnabled: () => rateLimitWatchdogEnabledFromEnv(),
		maxAttempts: () => rateLimitMaxAttemptsFromEnv(),
		backoffLadderSec: () => rateLimitBackoffLadderSecFromEnv(),
		sendUserMessage: (message) => pi.sendUserMessage(message, { deliverAs: "steer" }),
		emitActivity: (eventName, payload) => {
			emitSubagentEvent(pi, eventName, payload);
		},
		onExhausted: (_paneId, attempt, reason) => {
			// Fall through to the existing agent-end watchdog: clearing the
			// retry state lets the next agent_end handler run the synthetic
			// needs_completion outbox flow without further interference.
			console.warn(`rate-limit-watchdog: exhausted after ${attempt} attempt(s) — falling back to needs_completion (${reason})`);
		},
		logWarn: (message) => console.warn(message),
	});

	// Idle-stall watchdog (vstack#63 workaround): polls active tasks for
	// pi-core post-compaction stalls where agent_end never fires. Reuses
	// the W5 O_EXCL writer so a racing real complete_subagent always wins.

	const idleStallWatchdog = createIdleStallWatchdog({
		intervalMs: stallWatchdogIntervalMsFromEnv(),
		thresholdMs: stallWatchdogThresholdMsFromEnv(),
		isEnabled: () => stallWatchdogEnabledFromEnv(),
		now: () => Date.now(),
		listActiveTasks: async () => {
			if (!currentRuntimeRoot) return [];
			const records = await readTaskRegistry(currentRuntimeRoot);
			return Object.values(records).filter(
				(record) =>
					record?.taskId &&
					record.status !== "completed" &&
					record.status !== "failed" &&
					record.status !== "blocked" &&
					record.status !== "needs_completion",
			);
		},
		outboxExists: defaultOutboxExists,
		outboxPathFor: (record) =>
			record.outboxFile ??
			completionPath(currentRuntimeRoot ?? "", record.agent, record.taskId),
		isPaneIdle: async (record) => {
			// Round-2 fix (reviewer-arch + reviewer-error major): probe the
			// child Pi's bridge state directly via pi-bridge state and treat
			// the response's data.isIdle === true as the authoritative
			// signal. Any error / timeout / missing-metadata defaults to
			// FALSE so the watchdog skips rather than false-fires against a
			// long-running tool call that simply hasn't poked the registry.
			if (!currentRuntimeRoot) return false;
			const registry = await readPaneRegistry(currentRuntimeRoot);
			const probe = await probePaneIdle(record, {
				resolveBridgeBin: resolveIdleProbeBridgeBin,
				execCapture: async (command, args, options) => {
					const timeoutMs = options?.timeoutMs ?? BRIDGE_IDLE_PROBE_DEFAULT_TIMEOUT_MS;
					return Promise.race([
						execCapture(command, args, options),
						new Promise<{ code: number; stdout: string; stderr: string }>((_, reject) =>
							setTimeout(() => reject(new Error(`pi-bridge state timed out after ${timeoutMs}ms`)), timeoutMs),
						),
					]);
				},
				readPaneRegistryEntry: async (agent) => registry[agent],
				logWarn: logIdleStallDiagnostic,
			});
			return probe.idle;
		},
		lastActivityAt: (record) => {
			const raw = record.updatedAt ?? record.completedAt ?? record.createdAt;
			if (!raw) return 0;
			const ts = Date.parse(raw);
			return Number.isFinite(ts) ? ts : 0;
		},
		writeSyntheticOutbox: defaultWriteSyntheticOutbox,
		markFired: async (record, payload) => {
			if (!currentRuntimeRoot) return;
			await markTaskNeedsCompletion(currentRuntimeRoot, record.agent, record.taskId, {
				diagnostic: `${payload.summary} (reason: ${STALL_WATCHDOG_REASON})`,
				outboxFile:
					record.outboxFile ??
					completionPath(currentRuntimeRoot, record.agent, record.taskId),
			});
		},
		logWarn: logIdleStallDiagnostic,
	});
	const defaultDashboardMode = (cwd?: string) => dashboardDefaultCollapsed(cwd) ? "compact" as const : "normal" as const;
	let dashboardState: SubagentDashboardState = { collapsed: false, mode: "normal", visible: true, lastVisibleMode: "normal", hiddenByUser: false, autoShownThisSession: false, items: {} };
	let dashboardCtx: ExtensionContext | undefined;
	let dashboardBatchDepth = 0;
	let dashboardSyncPending = false;
	const lastRuntimeSnapshotFingerprintBySession = new Map<string, string>();

	const toStatsItem = (item: SubagentDashboardItem): SubagentStatsItem => ({
		agent: item.agent,
		paneId: item.paneId,
		status: item.status,
		kind: item.kind,
		model: item.model,
		effort: item.effort,
		usage: item.usage,
		updatedAt: item.updatedAt,
	});
	const statsBridge: SubagentStatsBridge = {
		getByPaneId(paneId: string) {
			if (!paneId) return undefined;
			const match = Object.values(dashboardState.items).find((item) => item.paneId === paneId);
			return match ? toStatsItem(match) : undefined;
		},
		list() {
			return Object.values(dashboardState.items).map(toStatsItem);
		},
	};
	(globalThis as unknown as Record<PropertyKey, unknown>)[STATS_BRIDGE_SYMBOL] = statsBridge;

	const persistRuntimeSnapshot = async (ctx: ExtensionContext, runtimeRoot: string) => {
		if (childAgentName) return;
		try {
			const [panes, tasks] = await Promise.all([readPaneRegistry(runtimeRoot), readTaskRegistry(runtimeRoot)]);
			const sessionKey = ctx.sessionManager.getSessionFile?.() ?? ctx.sessionManager.getSessionId?.() ?? runtimeRoot;
			// Fingerprint over registry only (not updatedAt) so cosmetic bumps don't burn a session entry.
			const fingerprintInput = { panes, tasks };
			const fingerprint = stableSessionSnapshotFingerprint(fingerprintInput);
			if (lastRuntimeSnapshotFingerprintBySession.get(sessionKey) === fingerprint) return;
			if (!(await sessionFileTailMatchesLeaf(ctx))) return;
			const payload: PersistedSubagentRuntimeState = { version: 1, panes, tasks, updatedAt: new Date().toISOString() };
			// Bounded append: full payload only when within the size cap, otherwise a tiny manifest. The on-disk
			// pane and task registries remain canonical, so a manifest-only session entry still restores fully
			// on /resume (vstack#177).
			appendBoundedSnapshot({
				appender: pi,
				customType: SUBAGENT_STATE_TYPE,
				payload,
				sessionKey,
				fingerprintInput,
				fingerprintCache: lastRuntimeSnapshotFingerprintBySession,
				counts: () => ({ panes: Object.keys(panes).length, tasks: Object.keys(tasks).length }),
			});
		} catch {
			// Session-backed persistence is best-effort; file registries remain canonical at runtime. A stale
			// duplicate Pi process must not advance the session leaf from an older in-memory branch.
		}
	};

	const restoreRuntimeSnapshot = async (ctx: ExtensionContext, runtimeRoot: string) => {
		let snapshot: PersistedSubagentRuntimeState | undefined;
		for (const entry of ctx.sessionManager.getBranch()) {
			if (entry.type !== "custom" || entry.customType !== SUBAGENT_STATE_TYPE) continue;
			if (isPersistedSubagentRuntimeState(entry.data)) snapshot = entry.data;
		}
		if (!snapshot) return;
		try {
			const [diskPanes, diskTasks] = await Promise.all([readPaneRegistry(runtimeRoot), readTaskRegistry(runtimeRoot)]);
			const mergedPanes: PaneRegistry = { ...snapshot.panes, ...diskPanes };
			const mergedTasks: PaneTaskRegistry = { ...diskTasks };
			for (const [taskId, task] of Object.entries(snapshot.tasks)) {
				const existing = mergedTasks[taskId];
				if (!existing || latestRecordTimestamp(task) > latestRecordTimestamp(existing)) mergedTasks[taskId] = task;
			}
			if (JSON.stringify(mergedPanes) !== JSON.stringify(diskPanes)) await writePaneRegistry(runtimeRoot, mergedPanes);
			if (JSON.stringify(mergedTasks) !== JSON.stringify(diskTasks)) await writeTaskRegistry(runtimeRoot, mergedTasks);
		} catch {
			// Dashboard restore is best-effort; an unreadable sidecar should not block Pi startup.
		}
	};

	const diagnosticsFromEvent = (event: Record<string, unknown>, existing: string[] | undefined): string[] | undefined => {
		let diagnostics = existing;
		const values = Array.isArray(event.diagnostics) ? event.diagnostics : [];
		for (const value of values) {
			if (typeof value !== "string") continue;
			diagnostics = appendUniqueDiagnostic(diagnostics, sanitizeCwdSnapshotText(value, { multiline: true }));
		}
		return diagnostics;
	};

	const persistTaskEvent = (event: Record<string, unknown>, status: PaneTaskStatus) => {
		const runtimeRoot = typeof event.runtimeRoot === "string" ? event.runtimeRoot : undefined;
		const taskId = typeof event.taskId === "string" ? event.taskId : undefined;
		const agent = typeof event.agent === "string" ? event.agent : undefined;
		if (!runtimeRoot || !taskId || !agent) return;
		void updateTaskRegistry(runtimeRoot, (records) => {
			const existing = records[taskId];
			const now = new Date().toISOString();
			const kind: DashboardKind = event.mode === "oneshot" ? "oneshot" : event.mode === "pane" ? "pane" : existing?.kind ?? (typeof event.paneId === "string" ? "pane" : "oneshot");
			const usage = normalizeUsageStats(event.usage) ?? existing?.usage;
			const model = typeof event.model === "string" ? event.model : existing?.model;
			const effort = normalizeReasoningEffort(event.effort) ?? existing?.effort;
			const summary = normalizeSummaryText(typeof event.summary === "string" ? event.summary : typeof event.finalOutput === "string" ? event.finalOutput : typeof event.error === "string" ? event.error : undefined) ?? existing?.summary;
			const sessionMode = normalizeEventSessionMode(event.sessionMode) ?? existing?.sessionMode;
			const sessionKey = normalizeEventSessionKey(event.sessionKey) ?? existing?.sessionKey;
			const cwdSnapshot = sanitizeCwdSnapshot(event.cwdSnapshot) ?? sanitizeCwdSnapshot(existing?.cwdSnapshot);
			const diagnostics = diagnosticsFromEvent(event, existing?.diagnostics);
			const deliverAs = typeof event.deliverAs === "string" ? event.deliverAs : existing?.deliverAs;
			records[taskId] = {
				...existing,
				taskId,
				agent,
				task: typeof event.task === "string" ? event.task : existing?.task ?? "",
				status,
				sessionMode,
				sessionKey,
				kind,
				paneId: kind === "pane" ? (typeof event.paneId === "string" ? event.paneId : existing?.paneId) : undefined,
				inboxFile: kind === "pane" ? existing?.inboxFile : undefined,
				processingFile: kind === "pane" ? existing?.processingFile : undefined,
				doneFile: kind === "pane" ? existing?.doneFile : undefined,
				outboxFile: kind === "pane" ? existing?.outboxFile : undefined,
				completionSourcePath: kind === "pane" ? existing?.completionSourcePath : undefined,
				completionArchivePath: kind === "pane" ? existing?.completionArchivePath : undefined,
				transcriptPath: typeof event.transcriptPath === "string" ? event.transcriptPath : existing?.transcriptPath,
				deliverAs,
				usage,
				model,
				effort,
				summary,
				cwdSnapshot,
				diagnostics,
				createdAt: existing?.createdAt ?? (typeof event.timestamp === "string" ? event.timestamp : now),
				updatedAt: now,
				...(isTerminalTaskStatus(status) ? { completedAt: now } : {}),
			};
		}).then(() => {
			if (dashboardCtx) return persistRuntimeSnapshot(dashboardCtx, runtimeRoot);
			return undefined;
		}).catch(() => undefined);
	};

	const syncDashboard = (ctx = dashboardCtx) => {
		if (!ctx?.hasUI || childAgentName || !dashboardEnabled(ctx.cwd) || !dashboardState.visible) {
			if (ctx) setMiniDashboardWidget(ctx, SUBAGENT_WIDGET_KEY, MINI_DASHBOARD_RANK.AGENTS, undefined);
			return;
		}
		dashboardCtx = ctx;
		const hasItems = Object.keys(dashboardState.items).length > 0;
		if (!hasItems) {
			setMiniDashboardWidget(ctx, SUBAGENT_WIDGET_KEY, MINI_DASHBOARD_RANK.AGENTS, undefined);
			return;
		}
		const widgetRuntimeRoot = sessionRuntimeDir(runtimeSessionId(ctx));
		const widgetTaskNumbers = taskNumberById(Object.values(loadTaskRegistrySync(widgetRuntimeRoot)));
		setMiniDashboardWidget(ctx, SUBAGENT_WIDGET_KEY, MINI_DASHBOARD_RANK.AGENTS, (tui, theme) => {
			const animationTimer = (() => {
				if (!Object.values(dashboardState.items).some((item) => isDashboardAnimatingStatus(item.status))) return undefined;
				const timer = setInterval(() => {
					if (animateSpinnersEnabled(ctx.cwd)) tui.requestRender();
				}, 120);
				timer.unref?.();
				return timer;
			})();
			return {
				dispose() {
					if (animationTimer) clearInterval(animationTimer);
				},
				invalidate() {},
				render(width: number): string[] {
					return clampAboveEditorWidget(renderDashboardWidgetLines(dashboardState, theme, ctx.cwd, width, widgetTaskNumbers), tui.terminal.rows, theme);
				},
			};
		}, { placement: "aboveEditor" });
	};
	const requestDashboardSync = () => {
		if (dashboardBatchDepth > 0) {
			dashboardSyncPending = true;
			return;
		}
		syncDashboard();
	};
	const withDashboardBatch = async <T>(fn: () => Promise<T>): Promise<T> => {
		dashboardBatchDepth += 1;
		try {
			return await fn();
		} finally {
			dashboardBatchDepth = Math.max(0, dashboardBatchDepth - 1);
			if (dashboardBatchDepth === 0 && dashboardSyncPending) {
				dashboardSyncPending = false;
				syncDashboard();
			}
		}
	};

	const dashboardPaneIdentity = (item: Pick<SubagentDashboardItem, "agent" | "kind" | "taskId" | "transcriptPath" | "paneId">) => item.transcriptPath || item.paneId || item.taskId || item.agent;
	const dashboardItemKey = (item: Pick<SubagentDashboardItem, "agent" | "kind" | "taskId" | "transcriptPath" | "paneId">) => item.kind === "pane" ? `pane:${item.agent}:${dashboardPaneIdentity(item)}` : item.taskId || `${item.kind}:${item.agent}`;
	const dashboardKeyForTask = (taskId: string | undefined): string | undefined => {
		if (!taskId) return undefined;
		if (dashboardState.items[taskId]) return taskId;
		return Object.entries(dashboardState.items).find(([, item]) => item.taskId === taskId)?.[0];
	};

	const updateDashboard = (item: SubagentDashboardItem) => {
		autoShowAgentDashboardOnce(dashboardState, defaultDashboardMode(dashboardCtx?.cwd));
		const key = dashboardItemKey(item);
		const duplicateKeys = Object.entries(dashboardState.items)
			.filter(([existingKey, existingItem]) => {
				if (existingKey === key) return false;
				if (existingItem.taskId === item.taskId) return true;
				return item.kind === "pane"
					&& existingItem.kind === "pane"
					&& existingItem.agent === item.agent
					&& dashboardPaneIdentity(existingItem) === dashboardPaneIdentity(item);
			})
			.map(([existingKey]) => existingKey);
		const existing = dashboardState.items[key] ?? (duplicateKeys[0] ? dashboardState.items[duplicateKeys[0]] : undefined);
		for (const duplicateKey of duplicateKeys) delete dashboardState.items[duplicateKey];
		// Carry lifecycle timestamps forward when the caller omitted them. Bg
		// updaters in parallel/single/chain mode (updateOneshotDashboard, the
		// post-await dashboard refreshes) write only status/message/usage and
		// would otherwise blow away the startedAt set by subagents:started —
		// without which appendBgChatMessages cannot emit a delegation row.
		dashboardState.items[key] = {
			...item,
			startedAt: item.startedAt ?? existing?.startedAt,
			completedAt: item.completedAt ?? existing?.completedAt,
			sessionMode: item.sessionMode ?? existing?.sessionMode,
			sessionKey: item.sessionKey ?? existing?.sessionKey,
			usage: item.usage ?? existing?.usage,
			model: item.model ?? existing?.model,
			effort: item.effort ?? existing?.effort,
		};
		const maxKeep = Math.max(10, dashboardMaxItems(dashboardCtx?.cwd) * 3);
		const sorted = Object.values(dashboardState.items).sort((a, b) => {
			const activeRank = Number(isDashboardWorkingStatus(b.status)) - Number(isDashboardWorkingStatus(a.status));
			if (activeRank !== 0) return activeRank;
			const aTime = a.completedAt ?? a.startedAt ?? a.updatedAt;
			const bTime = b.completedAt ?? b.startedAt ?? b.updatedAt;
			const timeRank = bTime.localeCompare(aTime);
			if (timeRank !== 0) return timeRank;
			return sortDashboardItems([a, b])[0] === a ? -1 : 1;
		});
		dashboardState.items = Object.fromEntries(sorted.slice(0, maxKeep).map((entry) => [dashboardItemKey(entry), entry]));
		requestDashboardSync();
	};

	const patchDashboard = (taskId: string | undefined, patch: Partial<SubagentDashboardItem>) => {
		const key = dashboardKeyForTask(taskId);
		if (!key) return;
		const existing = dashboardState.items[key];
		if (!existing) return;
		updateDashboard({ ...existing, ...patch, updatedAt: new Date().toISOString() });
	};

	const patchDashboardUsage = (runtimeRoot: string, taskId: string | undefined, parsed: { usage: UsageStats; model?: string } | undefined) => {
		if (!taskId || !parsed) return;
		patchDashboard(taskId, { usage: parsed.usage, model: parsed.model });
		void updateTaskRegistry(runtimeRoot, (records) => {
			const existing = records[taskId];
			if (!existing) return;
			records[taskId] = { ...existing, usage: parsed.usage, model: parsed.model ?? existing.model };
		}).catch(() => undefined);
	};

	const removeDashboardAgent = (agentName: string | undefined) => {
		if (!agentName) return;
		for (const [key, item] of Object.entries(dashboardState.items)) {
			if (item.agent === agentName) delete dashboardState.items[key];
		}
		syncDashboard();
	};

	const taskRecordDashboardMessage = (record: PaneTaskRecord): string | undefined => {
		const summary = normalizeSummaryText(record.summary);
		if (summary) return summary;
		if (record.status === "needs_completion") {
			const base = record.diagnostics?.at(-1) ?? COMPLETION_SUMMARY_UNAVAILABLE;
			const snapshot = sanitizeCwdSnapshot(record.cwdSnapshot);
			if (!snapshot) return base;
			const dirty = snapshot.dirty ? "dirty" : "clean";
			return `${base} · HEAD ${snapshot.head.slice(0, 12)} (${dirty}) ${snapshot.lastCommit.subject}`;
		}
		if (isTerminalTaskStatus(record.status)) return COMPLETION_SUMMARY_UNAVAILABLE;
		return record.diagnostics?.at(-1) ?? record.task;
	};
	const taskRecordDashboardMessageProvenance = (record: PaneTaskRecord): SubagentDashboardItem["messageProvenance"] => {
		if (normalizeSummaryText(record.summary)) return "persisted";
		if (record.status === "needs_completion") return record.diagnostics?.length ? "diagnostic" : "placeholder";
		if (isTerminalTaskStatus(record.status)) return "placeholder";
		return record.diagnostics?.length ? "diagnostic" : "task-echo-fallback";
	};

	const updateDashboardFromTaskRecord = (record: PaneTaskRecord, runtimeRoot: string) => {
		const kind = inferTaskRecordKind(runtimeRoot, record);
		const candidateKey = dashboardItemKey({ agent: record.agent, kind, taskId: record.taskId, transcriptPath: record.transcriptPath, paneId: record.paneId });
		const existingKey = dashboardKeyForTask(record.taskId) ?? (dashboardState.items[candidateKey] ? candidateKey : undefined);
		const existing = existingKey ? dashboardState.items[existingKey] : undefined;
		if (record.status === "unknown") {
			if (existing && isLiveDashboardStatus(existing.status) && timestampMs(record.updatedAt ?? record.completedAt ?? record.createdAt) < timestampMs(existing.updatedAt)) return;
			if (kind === "oneshot") {
				if (existingKey) {
					delete dashboardState.items[existingKey];
					requestDashboardSync();
				}
				return;
			}
		}
		updateDashboard({
			agent: record.agent,
			artifacts: kind === "pane" ? Boolean(record.completionArchivePath || record.outboxFile || record.transcriptPath || record.processingFile || record.doneFile) : Boolean(record.transcriptPath),
			bridge: existing?.bridge,
			completedAt: record.completedAt,
			kind,
			message: taskRecordDashboardMessage(record),
			messageProvenance: taskRecordDashboardMessageProvenance(record),
			model: record.model ?? existing?.model,
			effort: record.effort ?? existing?.effort,
			paneId: record.paneId,
			sessionMode: record.sessionMode ?? existing?.sessionMode,
			sessionKey: record.sessionKey ?? existing?.sessionKey,
			startedAt: record.createdAt,
			status: dashboardStatusFor(record.status, kind),
			task: record.task,
			taskId: record.taskId,
			transcriptPath: record.transcriptPath ?? existing?.transcriptPath,
			deliverAs: record.deliverAs ?? existing?.deliverAs,
			updatedAt: record.updatedAt ?? record.completedAt ?? record.createdAt,
			usage: record.usage ?? existing?.usage,
		});
	};

	const syncDashboardFromTaskRegistry = async (ctx: ExtensionContext, runtimeRoot: string) => {
		await withDashboardBatch(async () => {
			const records = await readTaskRegistry(runtimeRoot);
			const registry = await readPaneRegistry(runtimeRoot);
			const sorted = Object.values(records).sort((a, b) => (a.createdAt ?? a.completedAt ?? a.updatedAt).localeCompare(b.createdAt ?? b.completedAt ?? b.updatedAt));
			for (const record of sorted) {
				if (!record.taskId || !record.agent) continue;
				if (inferTaskRecordKind(runtimeRoot, record) === "pane" && record.paneId && isTerminalTaskStatus(record.status) && !registry[record.agent]) continue;
				const refreshed = await refreshTaskDiagnostics(runtimeRoot, record);
				const backfilled = taskNeedsSummaryBackfill(refreshed.record)
					? await backfillTaskSummaryFromTranscript(runtimeRoot, refreshed.record)
					: { record: refreshed.record, updated: false };
				updateDashboardFromTaskRecord(backfilled.record, runtimeRoot);
			}
		});
		await persistRuntimeSnapshot(ctx, runtimeRoot);
	};

	const refreshAgentCommandCompletions = (ctx: ExtensionContext) => {
		try {
			agentCommandCompletions = discoverAgents(ctx.cwd, "both").agents.map((agent) => ({
				value: agent.name,
				label: agent.name,
				description: `${agent.source}${agent.pane ? " · pane" : ""}${agent.description ? ` · ${agent.description}` : ""}`,
				pane: agent.pane === true,
			}));
		} catch {
			agentCommandCompletions = [];
		}
	};

	const agentsArgumentCompletions = (prefix: string) => {
		const raw = prefix.trimStart();
		const parts = raw.split(/\s+/).filter(Boolean);
		const first = parts[0]?.toLowerCase() ?? "";
		if (parts.length === 0 || (parts.length <= 1 && !raw.endsWith(" "))) {
			const topLevel = [
				{ value: "show ", label: "show <name>", description: "Inspect an agent" },
				{ value: "start ", label: "start <name>", description: "Start or reuse a persistent pane" },
				{ value: "new ", label: "new <name>", description: "Start a persistent pane with a fresh session" },
				{ value: "send ", label: "send <name> <task>", description: "Queue a task for a persistent pane" },
				{ value: "attach ", label: "attach <name>", description: "Focus an existing agent pane" },
				{ value: "stop ", label: "stop <name>", description: "Stop an agent pane" },
				{ value: "status", label: "status", description: "Show persistent pane status" },
				{ value: "trace ", label: "trace <task-id>", description: "Open a past task in the trace viewer" },
				{ value: "toggle", label: "toggle", description: "Toggle the agent dashboard" },
			];
			const filtered = topLevel.filter((item) => item.value.trim().startsWith(first) || item.label.startsWith(first));
			return filtered.length > 0 ? filtered : null;
		}
		if (first === "trace") {
			const rest = parts[1]?.toLowerCase() ?? "";
			const records = Object.values(dashboardState.items).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
			const completions = records
				.filter((item) => !rest || item.taskId.toLowerCase().includes(rest) || item.agent.toLowerCase().includes(rest))
				.slice(0, 20)
				.map((item) => {
					const when = formatRelativeTime(item.completedAt ?? item.startedAt ?? item.updatedAt);
					const summary = oneLinePreview(item.message, 60);
					return {
						value: `trace ${item.taskId}`,
						label: `${item.agent} · ${when}`,
						description: summary ? `${item.status} · ${summary}` : item.status,
					};
				});
			return completions.length > 0 ? completions : null;
		}
		if (["show", "start", "new", "resume", "send", "attach", "stop"].includes(first)) {
			if (first === "show" && parts.length === 1 && raw.endsWith(" ")) return null;
			if (parts.length > 2 || (parts.length === 2 && raw.endsWith(" "))) return null;
			const rest = parts[1]?.toLowerCase() ?? "";
			const needsPane = first !== "show";
			const suffix = first === "send" ? " " : "";
			const filtered = agentCommandCompletions
				.filter((agent) => (!needsPane || agent.pane) && (!rest || agent.value.toLowerCase().startsWith(rest)))
				.slice(0, 20)
				.map((agent) => ({ value: `${first} ${agent.value}${suffix}`, label: agent.label, description: agent.description }));
			return filtered.length > 0 ? filtered : null;
		}
		return null;
	};

	pi.registerMessageRenderer("subagent-agents", (message, options, theme) => {
		return renderAgentsCommandMessage(message as { content: string; details?: unknown }, options, theme);
	});

	pi.registerMessageRenderer("subagent-trace", (message, _options, theme) => {
		const content = typeof message.content === "string" ? message.content : "";
		return framedComponent(new Markdown(content, 0, 0, getMarkdownTheme()), theme);
	});

	pi.registerMessageRenderer("subagent-completion", (message, options, theme) => {
		const quiet = quietInline(dashboardCtx?.cwd) && dashboardEnabled(dashboardCtx?.cwd);
		if (quiet && !options?.expanded) {
			const details = message.details as PaneCompletionMessageDetails | undefined;
			const completions = details?.completions ?? [];
			if (completions.length === 1) {
				const detail = completions[0]!;
				return framedMessage(agentStatusLine(theme, detail.agent, detail.status, paneCompletionTone(detail.status), theme.fg("dim", " · ctrl+o to expand")), theme);
			}
			if (completions.length > 1) return framedMessage(`${theme.fg("success", ICONS.check)} ${theme.fg("toolTitle", theme.bold(`${completions.length} agents completed`))}${theme.fg("dim", " · ctrl+o to expand")}`, theme);
		}
		return renderPaneCompletionMessage(message as { content: string; details?: unknown }, options as { expanded?: boolean } | undefined, theme);
	});

	pi.events.on("subagents:queued", (payload: unknown) => {
		if (!payload || typeof payload !== "object") return;
		const event = payload as Record<string, unknown>;
		const taskId = typeof event.taskId === "string" ? event.taskId : undefined;
		const agent = typeof event.agent === "string" ? event.agent : undefined;
		if (!taskId || !agent) return;
		const sessionMode = normalizeEventSessionMode(event.sessionMode);
		const sessionKey = normalizeEventSessionKey(event.sessionKey);
		const eventEffort = normalizeReasoningEffort(event.effort);
		persistTaskEvent(event, "queued");
		updateDashboard({
			agent,
			artifacts: true,
			kind: event.mode === "oneshot" ? "oneshot" : "pane",
			message: typeof event.task === "string" ? event.task : undefined,
			model: typeof event.model === "string" ? event.model : undefined,
			effort: eventEffort,
			paneId: typeof event.paneId === "string" ? event.paneId : undefined,
			sessionMode,
			sessionKey,
			status: "queued",
			startedAt: typeof event.timestamp === "string" ? event.timestamp : new Date().toISOString(),
			task: typeof event.task === "string" ? event.task : undefined,
			taskId,
			transcriptPath: typeof event.transcriptPath === "string" ? event.transcriptPath : undefined,
			updatedAt: new Date().toISOString(),
		});
	});

	pi.events.on("subagents:started", (payload: unknown) => {
		if (!payload || typeof payload !== "object") return;
		const event = payload as Record<string, unknown>;
		const taskId = typeof event.taskId === "string" ? event.taskId : undefined;
		const agent = typeof event.agent === "string" ? event.agent : undefined;
		if (!taskId || !agent) return;
		const sessionMode = normalizeEventSessionMode(event.sessionMode);
		const sessionKey = normalizeEventSessionKey(event.sessionKey);
		const eventEffort = normalizeReasoningEffort(event.effort);
		persistTaskEvent(event, "running");
		updateDashboard({
			agent,
			kind: event.mode === "pane" ? "pane" : "oneshot",
			message: typeof event.task === "string" ? event.task : undefined,
			model: typeof event.model === "string" ? event.model : undefined,
			effort: eventEffort,
			paneId: typeof event.paneId === "string" ? event.paneId : undefined,
			sessionMode,
			sessionKey,
			status: "running",
			startedAt: typeof event.timestamp === "string" ? event.timestamp : new Date().toISOString(),
			task: typeof event.task === "string" ? event.task : undefined,
			taskId,
			transcriptPath: typeof event.transcriptPath === "string" ? event.transcriptPath : undefined,
			updatedAt: new Date().toISOString(),
		});
	});

	const completeDashboardFromEvent = (payload: unknown, status: PaneTaskStatus) => {
		if (!payload || typeof payload !== "object") return;
		const event = payload as Record<string, unknown>;
		const taskId = typeof event.taskId === "string" ? event.taskId : undefined;
		const agent = typeof event.agent === "string" ? event.agent : undefined;
		const runtimeRoot = typeof event.runtimeRoot === "string" ? event.runtimeRoot : undefined;
		if (!taskId || !agent) return;
		const existingKey = dashboardKeyForTask(taskId);
		const paneKey = `pane:${agent}`;
		const currentPane = dashboardState.items[paneKey];
		if (!existingKey && currentPane?.kind === "pane" && currentPane.taskId !== taskId) return;
		const existing = existingKey ? dashboardState.items[existingKey] : currentPane?.taskId === taskId ? currentPane : undefined;
		const transcriptPath = typeof event.transcriptPath === "string" ? event.transcriptPath : existing?.transcriptPath;
		const eventUsage = normalizeUsageStats(event.usage);
		const eventModel = typeof event.model === "string" ? event.model : undefined;
		const eventEffort = normalizeReasoningEffort(event.effort) ?? existing?.effort;
		const sessionMode = normalizeEventSessionMode(event.sessionMode) ?? existing?.sessionMode;
		const sessionKey = normalizeEventSessionKey(event.sessionKey) ?? existing?.sessionKey;
		const eventSummary = normalizeSummaryText(typeof event.summary === "string" ? event.summary : typeof event.finalOutput === "string" ? event.finalOutput : typeof event.error === "string" ? event.error : undefined);
		const kind = event.mode === "oneshot" ? "oneshot" : event.mode === "pane" ? "pane" : existing?.kind ?? "pane";
		const payloadStatus = ((): PaneTaskStatus => {
			const raw = event.status;
			return raw === "queued" || raw === "running" || raw === "completed" || raw === "blocked" || raw === "failed" || raw === "needs_completion" ? raw : "unknown";
		})();
		const eventStatus = payloadStatus === "unknown" ? status : payloadStatus;
		const effectiveStatus = dashboardStatusFor(eventStatus, kind);
		persistTaskEvent(event, eventStatus);
		updateDashboard({
			agent,
			artifacts: true,
			bridge: existing?.bridge,
			completedAt: typeof event.timestamp === "string" ? event.timestamp : new Date().toISOString(),
			kind,
			message: eventSummary ?? (isTerminalTaskStatus(eventStatus) || eventStatus === "needs_completion" ? completionBodyWithoutPromptEcho(existing?.message, existing?.task) : existing?.message),
			paneId: kind === "pane" ? existing?.paneId ?? (typeof event.paneId === "string" ? event.paneId : undefined) : undefined,
			sessionMode,
			sessionKey,
			startedAt: existing?.startedAt,
			status: effectiveStatus,
			task: existing?.task ?? (typeof event.task === "string" ? event.task : undefined),
			taskId,
			transcriptPath,
			updatedAt: new Date().toISOString(),
			usage: eventUsage ?? existing?.usage,
			model: eventModel ?? existing?.model,
			effort: eventEffort,
		});
		if (transcriptPath && runtimeRoot) {
			parseTranscriptUsage(transcriptPath)
				.then((parsed) => patchDashboardUsage(runtimeRoot, taskId, parsed))
				.catch(() => undefined);
		}
	};

	pi.events.on("subagents:completed", (payload: unknown) => completeDashboardFromEvent(payload, "completed"));
	pi.events.on("subagents:failed", (payload: unknown) => completeDashboardFromEvent(payload, "failed"));
	pi.events.on("subagents:needs_completion", (payload: unknown) => completeDashboardFromEvent(payload, "needs_completion"));

	pi.events.on("subagents:steered", (payload: unknown) => {
		if (!payload || typeof payload !== "object") return;
		const event = payload as Record<string, unknown>;
		const taskId = typeof event.taskId === "string" ? event.taskId : undefined;
		const deliverAs = typeof event.deliverAs === "string" ? event.deliverAs : undefined;
		patchDashboard(taskId, {
			bridge: Boolean(event.bridge),
			paneId: typeof event.paneId === "string" ? event.paneId : undefined,
			deliverAs,
		});
		const runtimeRoot = typeof event.runtimeRoot === "string" ? event.runtimeRoot : undefined;
		if (runtimeRoot && taskId && deliverAs) {
			void updateTaskRegistry(runtimeRoot, (records) => {
				const existing = records[taskId];
				if (existing) records[taskId] = { ...existing, deliverAs, updatedAt: new Date().toISOString() };
			});
		}
	});

	pi.registerTool({
		renderShell: "self",
		name: "complete_subagent",
		label: "Complete Agent Task",
		description: "Child-pane-only helper that writes the persistent agent completion record without exposing outbox JSON mechanics in the visible pane.",
		parameters: CompleteSubagentParams,
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			if (!childAgentName) return { content: [{ type: "text", text: "complete_subagent is only available inside a persistent agent pane." }], details: {}, isError: true };
			const runtimeRoot = runtimeDirForContext(ctx);
			let taskId = childCurrentTaskFile ? path.basename(childCurrentTaskFile, path.extname(childCurrentTaskFile)) : "";
			let outboxFile = taskId ? completionPath(runtimeRoot, childAgentName, taskId) : "";
			if (!taskId) {
				const records = Object.values(await readTaskRegistry(runtimeRoot))
					.filter((record) => record.agent === childAgentName && (record.status === "queued" || record.status === "running"))
					.sort((a, b) => (b.updatedAt ?? b.createdAt).localeCompare(a.updatedAt ?? a.createdAt));
				const record = records[0];
				if (!record) return { content: [{ type: "text", text: "No active agent task file or bridge follow-up task is being processed." }], details: {}, isError: true };
				taskId = record.taskId;
				outboxFile = record.outboxFile ?? completionPath(runtimeRoot, childAgentName, taskId);
			}
			const completion = {
				agent: childAgentName,
				taskId,
				status: params.status,
				summary: params.summary,
				filesChanged: params.filesChanged ?? [],
				validation: params.validation ?? [],
				...(params.notes ? { notes: params.notes } : {}),
			};
			await fs.promises.mkdir(path.dirname(outboxFile), { recursive: true, mode: 0o700 });
			await fs.promises.writeFile(outboxFile, JSON.stringify(completion, null, 2), { encoding: "utf-8", mode: 0o600 });
			pendingChildCompletion = { agent: childAgentName, taskId, status: params.status, outboxFile };
			return {
				content: [{ type: "text", text: `Completed ${childAgentName} task ${taskId} (${params.status}).` }],
				details: { agent: childAgentName, taskId, status: params.status, outboxFile },
			};
		},
		renderCall(_args, _theme, _context) {
			return new Container();
		},
		renderResult(result, _options, theme, _context) {
			const details = result.details as { agent?: string; status?: string; outboxFile?: string } | undefined;
			const agent = details?.agent ?? childAgentName ?? "agent";
			const statusWord = details?.status === "failed" ? "failed" : details?.status === "blocked" ? "blocked" : "completed";
			const tone = details?.status === "failed" || details?.status === "blocked" ? "error" : "success";
			return wrappedText(agentStatusLine(theme, agent, statusWord, tone, theme.fg("muted", " · reported")));
		},
	});

	pi.registerMessageRenderer("subagent-self-completion", (message, options, theme) => {
		const details = message.details as { agent?: string; status?: string; outboxFile?: string } | undefined;
		const agent = details?.agent ?? "unknown";
		const statusWord = details?.status === "failed" ? "failed" : details?.status === "blocked" ? "blocked" : "completed";
		const tone = details?.status === "failed" || details?.status === "blocked" ? "error" : "success";
		const tail = statusWord === "completed" ? theme.fg("muted", " · now waiting") : "";
		const headline = agentStatusLine(theme, agent, statusWord, tone, tail);
		if (options?.expanded && details?.outboxFile) {
			return framedMessage(`${headline}\n${theme.fg("dim", `Outbox: ${compactPath(details.outboxFile)}`)}`, theme);
		}
		return framedMessage(headline, theme);
	});

	pi.registerMessageRenderer("subagent-missing-completion", (message, options, theme) => {
		const details = message.details as { agent?: string; taskId?: string; outboxFile?: string; processingFile?: string } | undefined;
		const agent = details?.agent ?? "unknown";
		const task = details?.taskId ? ` · ${shortTaskId(details.taskId)}` : "";
		const headline = agentStatusLine(theme, agent, "needs completion", "warning", theme.fg("dim", task));
		if (options?.expanded) {
			const content = typeof message.content === "string" ? message.content : "Call complete_subagent to finish this task.";
			const artifacts = [
				details?.outboxFile ? `Expected outbox: ${compactPath(details.outboxFile)}` : "",
				details?.processingFile ? `Processing task: ${compactPath(details.processingFile)}` : "",
			]
				.filter(Boolean)
				.map((line) => theme.fg("dim", line))
				.join("\n");
			return framedMessage(`${headline}\n${theme.fg("toolOutput", content)}${artifacts ? `\n${artifacts}` : ""}`, theme);
		}
		return framedMessage(`${headline}\n${subagentBranch(theme, "└")}${theme.fg("toolOutput", "Call complete_subagent; task kept active.")}`, theme);
	});

	pi.on("session_start", async (_event, ctx) => {
		dashboardCtx = ctx;
		const mode = defaultDashboardMode(ctx.cwd);
		Object.assign(dashboardState, { collapsed: dashboardDefaultCollapsed(ctx.cwd), mode, visible: true, lastVisibleMode: mode, hiddenByUser: false, autoShownThisSession: false, items: {} });
		normalizeAgentDashboardVisibility(dashboardState, mode);
		refreshAgentCommandCompletions(ctx);
		if (completionPoller) clearInterval(completionPoller);
		if (childInboxPoller) clearInterval(childInboxPoller);
		if (childTitlePoller) clearInterval(childTitlePoller);

		const runtimeRoot = runtimeDirForContext(ctx);

		if (childAgentName) {
			if (!childOwnsVisiblePane) {
				// Bg/one-shot agents set PI_SUBAGENT_CHILD_AGENT for
				// delegate_subagent authorization and statusline context, but
				// they are subprocesses inside the parent pane. Do not mutate the
				// inherited TMUX_PANE title or poll the persistent-pane inbox.
				return;
			}
			ctx.ui.setTitle(`pi agent - ${childAgentName}`);
			setCurrentTmuxPaneTitle(`agent:${childAgentName}`);
			childTitlePoller = setInterval(() => setCurrentTmuxPaneTitle(`agent:${childAgentName}`), 1000);
			childTitlePoller.unref?.();
			ctx.ui.setStatus("agent", `${childAgentName} idle`);
			if (ctx.hasUI) ctx.ui.setWidget("subagent-marker", undefined);
			const pollInbox = () => {
				if (childPollInFlight || childCurrentTaskFile || !ctx.isIdle()) return;
				childPollInFlight = true;
				(async () => {
					const inbox = inboxDir(runtimeRoot, childAgentName);
					let files: string[];
					try {
						files = (await fs.promises.readdir(inbox)).filter((file) => file.endsWith(".md")).sort();
					} catch {
						return;
					}
					const file = files[0];
					if (!file) return;

					const source = path.join(inbox, file);
					const processing = path.join(processingDir(runtimeRoot, childAgentName), file);
					await fs.promises.mkdir(path.dirname(processing), { recursive: true, mode: 0o700 });
					try {
						await fs.promises.rename(source, processing);
					} catch {
						return;
					}

					const prompt = await fs.promises.readFile(processing, "utf-8");
					childCurrentTaskFile = processing;
					const taskId = path.basename(processing, path.extname(processing));
					const now = new Date().toISOString();
					await updateTaskRegistry(runtimeRoot, (records) => {
						const existing = records[taskId];
						records[taskId] = {
							...existing,
							taskId,
							agent: existing?.agent ?? childAgentName,
							task: existing?.task ?? "",
							status: "running",
							kind: "pane",
							inboxFile: existing?.inboxFile ?? source,
							processingFile: processing,
							outboxFile: existing?.outboxFile ?? completionPath(runtimeRoot, childAgentName, taskId),
							transcriptPath: existing?.transcriptPath ?? ctx.sessionManager.getSessionFile() ?? undefined,
							createdAt: existing?.createdAt ?? now,
							updatedAt: now,
						};
					});
					emitSubagentEvent(pi, "subagents:started", {
						mode: "pane",
						agent: childAgentName,
						taskId,
						status: "running",
						runtimeRoot,
						transcriptPath: ctx.sessionManager.getSessionFile() ?? undefined,
						completionPath: completionPath(runtimeRoot, childAgentName, taskId),
					});
					ctx.ui.setStatus("agent", `${childAgentName} running ${file}`);
					try {
						await pi.sendUserMessage(prompt, { deliverAs: "followUp" });
					} catch (error) {
						const diagnostic = `Unable to dispatch child task prompt: ${(error as Error)?.message ?? error}`;
						console.warn(`subagent child inbox dispatch failed for ${childAgentName} ${taskId}: ${diagnostic}`);
						childCurrentTaskFile = undefined;
						await recordTaskDispatchFailure(runtimeRoot, taskId, { processing, source }, diagnostic);
						ctx.ui.setStatus("agent", `${childAgentName} idle`);
					}
				})().finally(() => {
					childPollInFlight = false;
				});
			};
			pollInbox();
			childInboxPoller = setInterval(pollInbox, Math.max(500, Math.floor(settingNumber("childInboxPollMs", 1000, ctx.cwd))));
			return;
		}

		ctx.ui.setStatus("agent", undefined);
		await migrateLegacyPackageRuntime(runtimeSessionId(ctx), runtimeRoot);
		await migrateLegacyProjectRuntime(ctx.cwd, runtimeRoot);
		await restoreRuntimeSnapshot(ctx, runtimeRoot);
		try {
			await withDashboardBatch(async () => {
				const records = await readTaskRegistry(runtimeRoot);
				const sortedRecords = Object.values(records).sort((a, b) => (a.createdAt ?? "").localeCompare(b.createdAt ?? ""));
				for (const record of sortedRecords) {
					if (!record.taskId || !record.agent) continue;
					const refreshed = await refreshTaskDiagnostics(runtimeRoot, record);
					const backfilled = taskNeedsSummaryBackfill(refreshed.record)
						? await backfillTaskSummaryFromTranscript(runtimeRoot, refreshed.record)
						: { record: refreshed.record, updated: false };
					updateDashboardFromTaskRecord(backfilled.record, runtimeRoot);
					if (backfilled.record.transcriptPath && (backfilled.record.status === "completed" || backfilled.record.status === "failed" || backfilled.record.status === "blocked")) {
						const capturedTaskId = backfilled.record.taskId;
						parseTranscriptUsage(backfilled.record.transcriptPath)
							.then((parsed) => patchDashboardUsage(runtimeRoot, capturedTaskId, parsed))
							.catch(() => undefined);
					}
				}
			});
		} catch {
			// Dashboard is best-effort; registry lookup may fail before first pane task.
		}
		syncDashboard(ctx);
		if (!ctx.hasUI) return;
		const refreshLiveUsage = async () => {
			const snapshot = Object.values(dashboardState.items).filter((item) => {
				if (item.status === "failed" || item.status === "blocked") return false;
				if (!item.transcriptPath) return false;
				return true;
			});
			for (const item of snapshot) {
				const parsed = await parseTranscriptUsage(item.transcriptPath).catch(() => undefined);
				patchDashboardUsage(runtimeRoot, item.taskId, parsed);
			}
		};
		const poll = () => {
			if (completionPollInFlight) return;
			completionPollInFlight = true;
			pollPaneCompletions(runtimeRoot, pi, true)
				.then(async () => {
					await syncDashboardFromTaskRegistry(ctx, runtimeRoot);
					await refreshLiveUsage();
				})
				.finally(() => {
					completionPollInFlight = false;
				});
		};
		poll();
		completionPoller = setInterval(poll, Math.max(500, Math.floor(settingNumber("completionPollMs", 2000, ctx.cwd))));

		// vstack#63 workaround: idle-stall watchdog rides on the parent
		// session and polls active tasks for post-compaction stalls.
		currentRuntimeRoot = runtimeRoot;
		flushRuntimeDiagnostics();
		idleStallWatchdog.start();
	});

	// vstack#108: rate-limit-watchdog rides on message_end so it can
	// observe the canonical Claude rate-limit signature (assistant turn
	// with stopReason==="error" + "temporarily limiting requests" prose)
	// before agent_end fires its existing missing-completion path. The
	// pane id passed downstream is the child agent name — each subagent
	// pane runs its own Pi instance with a single in-pane child so a
	// per-agent counter is the right granularity.
	pi.on("message_end", async (event: any) => {
		if (!childAgentName) return;
		try {
			const taskId = childCurrentTaskFile
				? path.basename(childCurrentTaskFile, path.extname(childCurrentTaskFile))
				: undefined;
			rateLimitWatchdog.onMessageEnd(event, childAgentName, childAgentName, taskId);
		} catch (error) {
			console.warn(`rate-limit-watchdog: message_end handler failed (${(error as Error)?.message ?? error})`);
		}
	});

	pi.on("agent_end", async (_event, ctx) => {
		if (!childAgentName) return;
		lastChildAgentEndCtx = ctx;
		// vstack#108: when the rate-limit watchdog has a retry scheduled for
		// this pane, skip the agent-end-watchdog's needs_completion path so
		// the steer can race the synthetic outbox.
		const rateLimitAwaitingRetry = rateLimitWatchdog.isAwaitingRetry(childAgentName);
		if (childCurrentTaskFile) {
			const runtimeRoot = runtimeDirForContext(ctx);
			const activeTaskFile = childCurrentTaskFile;
			const taskId = path.basename(activeTaskFile, path.extname(activeTaskFile));
			const outboxFile = completionPath(runtimeRoot, childAgentName, taskId);
			const pendingMatches = pendingChildCompletion?.taskId === taskId;
			let manualCompletionOk = false;
			let missingDiagnostic = `Task turn ended but ${childAgentName} did not call complete_subagent. Expected completion outbox: ${outboxFile}`;
			if (!pendingMatches) {
				const parsed = await readPaneCompletionFile(outboxFile);
				if (parsed.completion) manualCompletionOk = true;
				else if (parsed.exists && parsed.error) missingDiagnostic = completionParseErrorMessage(outboxFile, parsed.error);
				else {
					// Parent's pollPaneCompletions may have already archived the outbox file via
					// fs.rename before this hook ran; trust the registry as the source of truth.
					const records = await readTaskRegistry(runtimeRoot);
					if (isTerminalTaskStatus(records[taskId]?.status)) manualCompletionOk = true;
				}
			}

			if (!pendingMatches && !manualCompletionOk && rateLimitAwaitingRetry) {
				// vstack#108: rate-limit retry will reissue the steer; defer
				// the immediate needs_completion mark + UI status until the
				// retry either succeeds (rate_limit_resolved) or exhausts.
				return;
			}

			if (!pendingMatches && !manualCompletionOk) {
				const updatedNeedsCompletion = await markTaskNeedsCompletion(runtimeRoot, childAgentName, taskId, {
					diagnostic: missingDiagnostic,
					outboxFile,
					processingFile: activeTaskFile,
					transcriptPath: ctx.sessionManager.getSessionFile() ?? undefined,
				});
				ctx.ui.setStatus("agent", `${childAgentName} needs completion ${shortTaskId(taskId, 18)}`);
				pi.sendMessage({
					customType: "subagent-missing-completion",
					content: missingDiagnostic,
					details: { agent: childAgentName, taskId, outboxFile, processingFile: activeTaskFile, cwdSnapshot: updatedNeedsCompletion?.cwdSnapshot },
					display: true,
				});
				// Intentionally do NOT clear childCurrentTaskFile: the inbox poll guard
				// blocks new task pickup while it is set, which keeps a misbehaving agent
				// pinned in needs_completion until a human resets the pane instead of
				// silently piling up additional partial tasks. pendingChildCompletion is
				// also left as-is; later completions are matched by taskId equality.
				return;
			}

			const doneFile = path.join(doneDir(runtimeRoot, childAgentName), path.basename(activeTaskFile));
			try {
				await fs.promises.mkdir(path.dirname(doneFile), { recursive: true, mode: 0o700 });
				await fs.promises.rename(activeTaskFile, doneFile);
				await updateTaskRegistry(runtimeRoot, (records) => {
					const existing = records[taskId];
					if (!existing) return;
					records[taskId] = {
						...existing,
						kind: "pane",
						doneFile,
						processingFile: existing.processingFile ?? activeTaskFile,
						outboxFile: existing.outboxFile ?? outboxFile,
						updatedAt: new Date().toISOString(),
					};
				});
			} catch (error) {
				await updateTaskRegistry(runtimeRoot, (records) => {
					const existing = records[taskId];
					if (!existing) return;
					records[taskId] = {
						...existing,
						kind: "pane",
						processingFile: existing.processingFile ?? activeTaskFile,
						outboxFile: existing.outboxFile ?? outboxFile,
						transcriptPath: existing.transcriptPath ?? ctx.sessionManager.getSessionFile() ?? undefined,
						updatedAt: new Date().toISOString(),
						diagnostics: appendUniqueDiagnostic(existing.diagnostics, `Task completion was recorded, but processing-file archival failed for ${activeTaskFile}: ${String(error)}`),
					};
				});
			}
			childCurrentTaskFile = undefined;
		}
		ctx.ui.setStatus("agent", `${childAgentName} idle`);
		pendingChildCompletion = undefined;

		// Fallback watchdog for tasks delivered without an inbox file (bridge
		// follow-ups, sessionless steers, etc.). If any task record for this
		// agent is still active and has no outbox after the grace window, write
		// a synthetic needs_completion outbox so the parent's wake handler runs.
		//
		// vstack#108: skip this scan when the rate-limit watchdog has a retry
		// in flight for this pane — otherwise the synthetic outbox races the
		// scheduled steer and the parent gets a misleading 'needs completion'.
		if (rateLimitAwaitingRetry) return;
		try {
			const runtimeRoot = runtimeDirForContext(ctx);
			const records = await readTaskRegistry(runtimeRoot);
			for (const record of Object.values(records)) {
				if (!record?.taskId || record.agent !== childAgentName) continue;
				if (isTerminalTaskStatus(record.status) || record.status === "needs_completion") continue;
				agentEndWatchdog.onAgentEnd({ runtimeRoot, agentName: childAgentName, taskId: record.taskId });
			}
		} catch (err) {
			console.warn(`agent-end watchdog: scan failed: ${(err as Error)?.message ?? err}`);
		}
	});

	pi.on("session_shutdown", () => {
		if (completionPoller) clearInterval(completionPoller);
		if (childInboxPoller) clearInterval(childInboxPoller);
		if (dashboardCtx) setMiniDashboardWidget(dashboardCtx, SUBAGENT_WIDGET_KEY, MINI_DASHBOARD_RANK.AGENTS, undefined);
		completionPoller = undefined;
		childInboxPoller = undefined;
		dashboardCtx = undefined;
		idleStallWatchdog.stop();
		currentRuntimeRoot = undefined;
	});

	registerAgentsCommands({
		agentCommandCompletions,
		agentsArgumentCompletions,
		dashboardState,
		formatRelativeTime,
		persistRuntimeSnapshot,
		pi,
		removeDashboardAgent,
		syncDashboard,
	});

	const toggleDashboardMode = async (ctx: ExtensionContext) => {
		dashboardCtx = ctx;
		cycleAgentDashboard(dashboardState);
		dashboardState.collapsed = false;
		syncDashboard(ctx);
	};
	const shortcut = dashboardShortcut();
	if (shortcut !== "none") {
		pi.registerShortcut(shortcut as any, { description: "Cycle agent dashboard display", handler: async (ctx) => toggleDashboardMode(ctx as ExtensionContext) });
	}
	const openAgentsPopup = async (ctx: ExtensionContext) => {
		dashboardCtx = ctx;
		if (!ctx.hasUI) return;
		const parentModel = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
		const parentThinkingLevel = pi.getThinkingLevel();
		const parentSessionId = runtimeSessionId(ctx);
		const runtimeRoot = sessionRuntimeDir(parentSessionId);
		await openAgentsBrowser(ctx, "both", undefined, runtimeRoot, parentSessionId, parentModel, parentThinkingLevel, pi.getActiveTools(), () => activeDashboardItems(Object.values(dashboardState.items)), removeDashboardAgent);
	};
	const popup = popupShortcut();
	if (popup !== "none") {
		pi.registerShortcut(popup as any, {
			description: "Open the /agents browser popup",
			handler: async (ctx) => openAgentsPopup(ctx as ExtensionContext),
		});
	}
	if (popup.toLowerCase() !== "f3") {
		pi.registerShortcut("f3" as any, {
			description: "Open the /agents browser popup",
			handler: async (ctx) => openAgentsPopup(ctx as ExtensionContext),
		});
	}

	const waitForPaneIdle = async (ctx: ExtensionCommandContext | ExtensionContext, agentName: string, timeoutMs = 30000): Promise<{ text: string; details: WaitForSubagentIdleDetails; isError?: boolean }> => {
		const runtimeRoot = sessionRuntimeDir(runtimeSessionId(ctx as ExtensionContext));
		const registry = await readPaneRegistry(runtimeRoot);
		const entry = registry[agentName];
		if (!entry) {
			return {
				text: `No persistent pane registry entry for ${agentName} in runtime ${runtimeRoot}.`,
				details: { agent: agentName, runtimeRoot, samples: 0, status: "timeout", timedOut: false, transitioned: false },
				isError: true,
			};
		}
		if (!paneSessionBelongsToRuntime(runtimeRoot, entry)) {
			return {
				text: `Refusing to wait for ${agentName}: pane session file is outside this runtime. Session: ${entry.sessionFile}. Runtime: ${runtimeRoot}`,
				details: { agent: agentName, paneId: entry.paneId, runtimeRoot, samples: 0, sessionFile: entry.sessionFile, status: "timeout", timedOut: false, transitioned: false },
				isError: true,
			};
		}
		if (!(await paneExists(entry.paneId))) {
			return {
				text: `Agent ${agentName} is not live.`,
				details: { agent: agentName, paneId: entry.paneId, runtimeRoot, samples: 0, sessionFile: entry.sessionFile, status: "timeout", timedOut: false, transitioned: false },
				isError: true,
			};
		}
		const metadata = await ensurePaneBridgeMetadata(runtimeRoot, entry);
		const bridgeBin = metadata ? await resolvePiBridgeBin() : undefined;
		const targetArgs = metadata ? bridgeTargetArgs(metadata) : [];
		if (!bridgeBin || targetArgs.length === 0) {
			return {
				text: `No live pi-bridge target for ${agentName}; cannot wait for isIdle transition.`,
				details: { agent: agentName, paneId: entry.paneId, runtimeRoot, samples: 0, sessionFile: entry.sessionFile, status: "timeout", timedOut: false, transitioned: false },
				isError: true,
			};
		}
		const wait = await waitForIdleTransition(async () => {
			const result = await execCapture(bridgeBin, ["state", ...targetArgs], { cwd: entry.cwd });
			if (result.code !== 0) return undefined;
			return extractBridgeState(result.stdout);
		}, timeoutMs, 500);
		const details: WaitForSubagentIdleDetails = {
			agent: agentName,
			bridgePid: metadata?.pid,
			bridgeSocket: metadata?.socket,
			isIdle: wait.lastState?.isIdle,
			paneId: entry.paneId,
			runtimeRoot,
			samples: wait.samples,
			sessionFile: entry.sessionFile,
			status: wait.status,
			timedOut: wait.timedOut,
			transitioned: wait.transitioned,
		};
		return {
			text: wait.status === "idle-after-busy"
				? `${agentName} is idle after busy transition (pane ${entry.paneId}).`
				: wait.status === "never-busy"
					? `${agentName} never became busy before idle wait timeout (${timeoutMs}ms).`
					: `Timed out waiting for ${agentName} idle transition after it became busy (${timeoutMs}ms).`,
			details,
			isError: !wait.transitioned,
		};
	};

	registerPaneSupportTools({
		backfillTaskSummaryFromTranscript,
		bridgeTargetArgs,
		createFollowUpTask,
		dashboardStatusFor,
		emitSubagentEvent,
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
		removeDashboardAgent,
		resolvePiBridgeBin,
		runtimeSessionId,
		sessionRuntimeDir,
		steerDiagnostics,
		stopPersistentPane,
		taskNeedsSummaryBackfill,
		updateDashboard,
		updateDashboardFromTaskRecord,
		persistRuntimeSnapshot,
		waitForPaneIdle,
	});

	pi.on("before_agent_start", (event, ctx) => {
		const activeTools = pi.getActiveTools();
		const hasSubagent = activeTools.includes("subagent");
		const hasDelegate = activeTools.includes("delegate_subagent");
		if (!hasSubagent && !hasDelegate) return;

		const discovery = discoverAgents(ctx.cwd, "project");
		if (discovery.agents.length === 0) return;

		// Full orchestrator tool: emit the complete project agent list so the
		// orchestrator can pick targets directly.
		if (hasSubagent) {
			const agentLines = discovery.agents
				.map((agent) => {
					const model = agent.model ? ` model=${agent.model}` : "";
					const denyTools = agent.denyTools && agent.denyTools.length > 0 ? ` deny-tools=${agent.denyTools.join(",")}` : "";
					const pane = agent.pane ? " pane=true" : "";
					return `- ${agent.name}: ${agent.description} (${agent.source}${model}${denyTools}${pane})`;
				})
				.join("\n");

			return {
				systemPrompt: `${event.systemPrompt}\n\n## Project Agents\nProject-local agents available to \`subagent\` (default \`agentScope: "project"\`; pass \`"both"\` only for user-level agents at \`~/.pi/agent/agents\`):\n${agentLines}`,
			};
		}

		// Restricted delegation only: emit a compact list of the caller's
		// allowed targets. Falls back to a hint when the caller identity is
		// missing (parent session without PI_SUBAGENT_CHILD_AGENT).
		const callerName = childAgentName?.trim();
		if (!callerName) {
			return {
				systemPrompt: `${event.systemPrompt}\n\n## Restricted Subagent Delegation\n\`delegate_subagent\` is only usable from a child agent process with PI_SUBAGENT_CHILD_AGENT set; it is unavailable from the root session.`,
			};
		}
		const caller = discovery.agents.find((agent) => agent.name === callerName);
		const allowedList = (caller?.allowedSubagents ?? []).filter((name) => name && name.trim().length > 0);
		if (allowedList.length === 0) {
			return {
				systemPrompt: `${event.systemPrompt}\n\n## Restricted Subagent Delegation\n\`delegate_subagent\` is registered but ${callerName} has no \`allowed-subagents\` configured; the tool will refuse every call.`,
			};
		}
		const targetMap = new Map<string, typeof discovery.agents[number]>();
		for (const agent of discovery.agents) targetMap.set(agent.name, agent);
		const targetLines = allowedList
			.map((name) => {
				const target = targetMap.get(name);
				if (!target) return `- ${name}: (not discovered)`;
				const model = target.model ? ` model=${target.model}` : "";
				const pane = target.pane ? " pane=true (delegate_subagent will refuse)" : "";
				return `- ${target.name}: ${target.description} (${target.source}${model}${pane})`;
			})
			.join("\n");

		return {
			systemPrompt: `${event.systemPrompt}\n\n## Restricted Subagent Delegation\nUse \`delegate_subagent\` only for context-protecting exploratory or reconnaissance work — read exact files yourself before editing. Include all needed context in the task; parent conversation is not shared with the child. The child returns a single text summary.\n\nAllowed targets for ${callerName}:\n${targetLines}`,
		};
	});

	pi.registerTool({
		renderShell: "self",
		name: "delegate_subagent",
		label: "Delegate",
		description: [
			"Restricted exploratory delegation. Spawn a single child agent in its own context window and return its summary.",
			"Only callable from a child Pi process whose PI_SUBAGENT_CHILD_AGENT is set; targets must appear in the caller agent's `allowed-subagents` frontmatter.",
			"Single dispatch only — no parallel `tasks`, no `chain`, no session reuse, no pane control. Pane targets are rejected.",
			"Include every fact and constraint in `task`; parent conversation is not shared.",
			"Intended for context-protecting reconnaissance and research (for example, an engineer agent dispatching `scout` to map an unknown area). Read exact files yourself before editing.",
		].join(" "),
		parameters: DelegateSubagentParams,

		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			const callerName = childAgentName?.trim();
			const agentScope: AgentScope = "project";
			const discovery = discoverAgents(ctx.cwd, agentScope);
			const agents = discovery.agents;
			const parentModel = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
			const parentThinkingLevel = pi.getThinkingLevel();
			const parentSessionId = runtimeSessionId(ctx);
			const runtimeRoot = sessionRuntimeDir(parentSessionId);
			const makeDetails =
				(_mode: "single" | "parallel" | "chain") =>
				(results: SingleResult[]): SubagentDetails => ({
					mode: "single",
					agentScope,
					projectAgentsDir: discovery.projectAgentsDir,
					results,
				});

			if (!callerName) {
				return {
					content: [{ type: "text", text: "delegate_subagent is only callable from a child agent process (PI_SUBAGENT_CHILD_AGENT must be set). Use `subagent` from a root session instead." }],
					details: makeDetails("single")([]),
					isError: true,
				};
			}

			const caller = agents.find((agent) => agent.name === callerName);
			const allowedList = (caller?.allowedSubagents ?? [])
				.map((name) => name.trim())
				.filter((name) => name.length > 0);
			if (!caller) {
				return {
					content: [{ type: "text", text: `delegate_subagent: caller agent '${callerName}' is not in the discovered project inventory; cannot authorize delegation.` }],
					details: makeDetails("single")([]),
					isError: true,
				};
			}
			if (allowedList.length === 0) {
				return {
					content: [{ type: "text", text: `delegate_subagent: ${callerName} has no allowed-subagents configured. Add a list to the agent frontmatter (vstack.toml [agent-frontmatter.pi]) or use the full subagent tool from a parent session.` }],
					details: makeDetails("single")([]),
					isError: true,
				};
			}

			const requestedTarget = (params.agent ?? "").trim();
			if (!requestedTarget) {
				return {
					content: [{ type: "text", text: "delegate_subagent: 'agent' parameter is required." }],
					details: makeDetails("single")([]),
					isError: true,
				};
			}
			if (!allowedList.includes(requestedTarget)) {
				return {
					content: [{ type: "text", text: `delegate_subagent: '${requestedTarget}' is not in ${callerName}'s allowed-subagents list. Allowed: ${allowedList.join(", ")}.` }],
					details: makeDetails("single")([]),
					isError: true,
				};
			}

			const target = agents.find((agent) => agent.name === requestedTarget);
			if (!target) {
				const available = agents.map((a) => a.name).join(", ") || "none";
				return {
					content: [{ type: "text", text: `delegate_subagent: target '${requestedTarget}' is not discovered in project agents. Discovered: ${available}.` }],
					details: makeDetails("single")([]),
					isError: true,
				};
			}
			if (target.pane) {
				return {
					content: [{ type: "text", text: `delegate_subagent: target '${requestedTarget}' is a persistent pane agent; restricted delegation is bg-only. Configure a non-pane agent or use the full subagent tool.` }],
					details: makeDetails("single")([]),
					isError: true,
				};
			}

			const task = (params.task ?? "").trim();
			if (!task) {
				return {
					content: [{ type: "text", text: "delegate_subagent: 'task' parameter is required." }],
					details: makeDetails("single")([]),
					isError: true,
				};
			}

			return runSingleDispatch({
				agent: requestedTarget,
				agents,
				cwd: ctx.cwd,
				cwdOverride: params.cwd,
				forceSpawn: false,
				makeDetails,
				onUpdate,
				parentModel,
				parentSessionId,
				parentThinkingLevel,
				pi,
				removeDashboardAgent,
				resumeSession: undefined,
				runtimeRoot,
				sessionKey: undefined,
				signal,
				task,
				updateDashboard,
			});
		},

		...subagentToolRenderers,
	});

	pi.registerTool({
		renderShell: "self",
		name: "subagent",
		label: "Agent",
		description: [
			"Delegate tasks to specialized agents with isolated context.",
			"Modes: single (agent + task), parallel (tasks array), chain (sequential with {previous} placeholder).",
			"Bg agents use fresh one-shot sessions by default; pass sessionKey only when you want continuity.",
			"Agent names are checked against selected inventory before launch; unknown names fail with available agents.",
			`Parallel calls run through a flat worker pool capped at maxConcurrency (default ${MAX_CONCURRENCY}); callers do not need to split requests.`,
			`Results are truncated by default to ${DEFAULT_RESULT_MAX_LINES} lines or ${formatSize(DEFAULT_RESULT_MAX_BYTES)}; full oversized output is saved under the session runtime when enabled.`,
			'Default agent scope is "project" (.pi/agents plus .claude/agents compatibility).',
			'Use agentScope: "both" to include user-level agents from ~/.pi/agent/agents.',
		].join(" "),
		parameters: SubagentParams,

		async execute(_toolCallId, params, signal, onUpdate, ctx) {
			const agentScope: AgentScope = params.agentScope ?? "project";
			const discovery = discoverAgents(ctx.cwd, agentScope);
			const agents = discovery.agents;
			const confirmProjectAgents = params.confirmProjectAgents ?? false;
			const parentModel = ctx.model ? `${ctx.model.provider}/${ctx.model.id}` : undefined;
			const parentThinkingLevel = pi.getThinkingLevel();
			const parentSessionId = runtimeSessionId(ctx);
			const runtimeRoot = sessionRuntimeDir(parentSessionId);

			const hasChain = (params.chain?.length ?? 0) > 0;
			const hasTasks = (params.tasks?.length ?? 0) > 0;
			const hasSingle = Boolean(params.agent && params.task);
			const modeCount = Number(hasChain) + Number(hasTasks) + Number(hasSingle);

			const makeDetails =
				(mode: "single" | "parallel" | "chain") =>
				(results: SingleResult[]): SubagentDetails => ({
					mode,
					agentScope,
					projectAgentsDir: discovery.projectAgentsDir,
					results,
				});

			if (modeCount !== 1) {
				const available = agents.map((a) => `${a.name} (${a.source})`).join(", ") || "none";
				return {
					content: [{ type: "text", text: `Invalid parameters. Provide exactly one mode.\nAvailable agents: ${available}` }],
					details: makeDetails("single")([]),
				};
			}

			const requestedAgentNames = collectRequestedAgentNames(params as Record<string, any>);
			const inventoryError = validateAgentInventory(requestedAgentNames, launchInventory(ctx.cwd, agentScope, agents), agentScope);
			if (inventoryError) {
				const mode = hasChain ? "chain" : hasTasks ? "parallel" : "single";
				return {
					content: [{ type: "text", text: formatInventoryValidationError(inventoryError) }],
					details: { ...makeDetails(mode)([]), inventoryError },
					isError: true,
				};
			}

			if ((agentScope === "project" || agentScope === "both") && confirmProjectAgents && ctx.hasUI) {
				const projectAgentsRequested = Array.from(requestedAgentNames)
					.map((name) => agents.find((a) => a.name === name))
					.filter((a): a is AgentConfig => a?.source === "project");

				if (projectAgentsRequested.length > 0) {
					const names = projectAgentsRequested.map((a) => a.name).join(", ");
					const dir = discovery.projectAgentsDir ?? "(unknown)";
					const ok = await ctx.ui.confirm(
						"Run project-local agents?",
						`Agents: ${names}\nSource: ${dir}\n\nProject agents are repo-controlled. Only continue for trusted repositories.`,
					);
					if (!ok)
						return {
							content: [{ type: "text", text: "Canceled: project-local agents not approved." }],
							details: makeDetails(hasChain ? "chain" : hasTasks ? "parallel" : "single")([]),
						};
				}
			}

			if (params.chain && params.chain.length > 0) {
				return runChainDispatch({
					agents,
					chain: params.chain as Array<{ agent: string; task: string; cwd?: string; sessionKey?: string }>,
					cwd: ctx.cwd,
					forceSpawn: params.forceSpawn ?? false,
					makeDetails,
					onUpdate,
					parentModel,
					parentSessionId,
					parentThinkingLevel,
					pi,
					removeDashboardAgent,
					resumeSession: params.resumeSession,
					runtimeRoot,
					signal,
					updateDashboard,
				});
			}

			if (params.tasks && params.tasks.length > 0) {
				return runParallelDispatch({
					agents,
					cwd: ctx.cwd,
					forceSpawn: params.forceSpawn ?? false,
					makeDetails,
					onUpdate,
					parentModel,
					parentSessionId,
					parentThinkingLevel,
					pi,
					removeDashboardAgent,
					resumeSession: params.resumeSession,
					runtimeRoot,
					signal,
					tasks: params.tasks as Array<{ agent: string; task: string; cwd?: string; sessionKey?: string }>,
					updateDashboard,
				});
			}

			if (params.agent && params.task) {
				return runSingleDispatch({
					agent: params.agent,
					agents,
					cwd: ctx.cwd,
					cwdOverride: params.cwd,
					forceSpawn: params.forceSpawn ?? false,
					makeDetails,
					onUpdate,
					parentModel,
					parentSessionId,
					parentThinkingLevel,
					pi,
					removeDashboardAgent,
					resumeSession: params.resumeSession,
					runtimeRoot,
					sessionKey: params.sessionKey,
					signal,
					task: params.task,
					updateDashboard,
				});
			}

			const available = agents.map((a) => `${a.name} (${a.source})`).join(", ") || "none";
			return {
				content: [{ type: "text", text: `Invalid parameters. Available agents: ${available}` }],
				details: makeDetails("single")([]),
			};
		},

		...subagentToolRenderers,
	});

	emitSubagentEvent(pi, "subagents:ready", { mode: "extension" });
}
