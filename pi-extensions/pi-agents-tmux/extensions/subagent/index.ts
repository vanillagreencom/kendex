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
	dashboardStatusFor,
	isDashboardWorkingStatus,
	renderDashboardWidgetLines,
	sortDashboardItems,
} from "./dashboard.js";
import {
	addArtifactPathSection,
	addSectionHeading,
	addWrappedSection,
	agentStatusLine,
	agentsCommandBullet,
	agentWord,
	ansiMagenta,
	compactPath,
	finalOutputLooksLikeToolEcho,
	finalResponseSuppressedLine,
	formatToolCall,
	formatUsageStats,
	framedComponent,
	framedMessage,
	getDisplayItems,
	getFinalOutput,
	oneLinePreview,
	parseTranscriptUsage,
	resolveSubagentStatuslineInfo,
	shortTaskId,
	subagentBranch,
	wrappedText,
} from "./format.js";
import {
	assignEphemeralSessionKeys,
	formatInventoryValidationError,
	mapInBatchesWithConcurrencyLimit,
	validateAgentInventory,
	type AgentInventory,
} from "./dispatch.js";
import {
	ensurePaneBridgeMetadata,
	ensurePersistentPane,
	execCapture,
	migrateLegacyPackageRuntime,
	migrateLegacyProjectRuntime,
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
	stableSessionSnapshotFingerprint,
} from "./session-persistence.js";
import {
	cloneMessagesForDetails,
	prepareSingleResultForReturn,
	runSingleAgent,
	truncateForDetails,
	detailsWithTruncation,
	type OnUpdateCallback,
} from "./runner.js";
import {
	dashboardDefaultCollapsed,
	dashboardEnabled,
	dashboardMaxItems,
	dashboardShortcut,
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
	refreshTaskDiagnostics,
	updateTaskRegistry,
	upsertTaskRecord,
	writePaneRegistry,
	writeTaskRegistry,
} from "./tasks.js";
import {
	CompleteSubagentParams,
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
	MAX_PARALLEL_TASKS,
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

async function createFollowUpTask(runtimeRoot: string, agentName: string, entry: { paneId: string; sessionFile: string }, message: string): Promise<FollowUpTask> {
	const taskId = createTaskId(agentName);
	const outboxFile = completionPath(runtimeRoot, agentName, taskId);
	await upsertTaskRecord(runtimeRoot, {
		taskId,
		agent: agentName,
		task: message,
		status: "running",
		kind: "pane",
		paneId: entry.paneId,
		outboxFile,
		transcriptPath: entry.sessionFile,
		createdAt: new Date().toISOString(),
		updatedAt: new Date().toISOString(),
	});
	return { taskId, outboxFile };
}

async function queueSteeringFallback(runtimeRoot: string, agentName: string, message: string, deliverAs: string = "steer", followUpTask?: FollowUpTask): Promise<string> {
	const steeringId = followUpTask?.taskId ?? `${safeFileName(`${agentName}-steer`)}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
	const filePath = path.join(inboxDir(runtimeRoot, agentName), `${safeFileName(steeringId)}.md`);
	const content = formatSteeringForChild(agentName, message, false, deliverAs, followUpTask);
	await fs.promises.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 });
	await fs.promises.writeFile(filePath, content, { encoding: "utf-8", mode: 0o600 });
	if (followUpTask) {
		await updateTaskRegistry(runtimeRoot, (records) => {
			const existing = records[followUpTask.taskId];
			if (existing) records[followUpTask.taskId] = { ...existing, kind: "pane", status: "queued", inboxFile: filePath, updatedAt: new Date().toISOString() };
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

export default function (pi: ExtensionAPI) {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;

	const childAgentName = process.env.PI_SUBAGENT_CHILD_AGENT;
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
	let dashboardState: SubagentDashboardState = { collapsed: false, mode: "normal", visible: true, items: {} };
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
			const fingerprint = stableSessionSnapshotFingerprint({ panes, tasks });
			const sessionKey = ctx.sessionManager.getSessionFile?.() ?? ctx.sessionManager.getSessionId?.() ?? runtimeRoot;
			if (lastRuntimeSnapshotFingerprintBySession.get(sessionKey) === fingerprint) return;
			if (!(await sessionFileTailMatchesLeaf(ctx))) return;
			pi.appendEntry<PersistedSubagentRuntimeState>(SUBAGENT_STATE_TYPE, { version: 1, panes, tasks, updatedAt: new Date().toISOString() });
			lastRuntimeSnapshotFingerprintBySession.set(sessionKey, fingerprint);
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
			records[taskId] = {
				...existing,
				taskId,
				agent,
				task: typeof event.task === "string" ? event.task : existing?.task ?? "",
				status,
				kind,
				paneId: kind === "pane" ? (typeof event.paneId === "string" ? event.paneId : existing?.paneId) : undefined,
				inboxFile: kind === "pane" ? existing?.inboxFile : undefined,
				processingFile: kind === "pane" ? existing?.processingFile : undefined,
				doneFile: kind === "pane" ? existing?.doneFile : undefined,
				outboxFile: kind === "pane" ? existing?.outboxFile : undefined,
				completionSourcePath: kind === "pane" ? existing?.completionSourcePath : undefined,
				completionArchivePath: kind === "pane" ? existing?.completionArchivePath : undefined,
				transcriptPath: typeof event.transcriptPath === "string" ? event.transcriptPath : existing?.transcriptPath,
				usage,
				model,
				summary: typeof event.summary === "string" ? event.summary : existing?.summary,
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
		setMiniDashboardWidget(ctx, SUBAGENT_WIDGET_KEY, MINI_DASHBOARD_RANK.AGENTS, (tui, theme) => {
			const animationTimer = (() => {
				if (!Object.values(dashboardState.items).some((item) => isDashboardWorkingStatus(item.status))) return undefined;
				const timer = setInterval(() => tui.requestRender(), 120);
				timer.unref?.();
				return timer;
			})();
			return {
				dispose() {
					if (animationTimer) clearInterval(animationTimer);
				},
				invalidate() {},
				render(width: number): string[] {
					return clampAboveEditorWidget(renderDashboardWidgetLines(dashboardState, theme, ctx.cwd, width), tui.terminal.rows, theme);
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
			usage: item.usage ?? existing?.usage,
			model: item.model ?? existing?.model,
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
			message: record.summary || record.diagnostics?.at(-1) || record.task,
			model: record.model ?? existing?.model,
			paneId: record.paneId,
			startedAt: record.createdAt,
			status: dashboardStatusFor(record.status, kind),
			task: record.task,
			taskId: record.taskId,
			transcriptPath: record.transcriptPath ?? existing?.transcriptPath,
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
				if (refreshed.record.status === "needs_completion") dashboardState.visible = true;
				updateDashboardFromTaskRecord(refreshed.record, runtimeRoot);
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
				return framedMessage(agentStatusLine(theme, detail.agent, detail.status, paneCompletionTone(detail.status), theme.fg("dim", " · ctrl+o expand")), theme);
			}
			if (completions.length > 1) return framedMessage(`${theme.fg("success", ICONS.check)} ${theme.fg("toolTitle", theme.bold(`${completions.length} agents completed`))}${theme.fg("dim", " · ctrl+o expand")}`, theme);
		}
		return renderPaneCompletionMessage(message as { content: string; details?: unknown }, options as { expanded?: boolean } | undefined, theme);
	});

	pi.events.on("subagents:queued", (payload: unknown) => {
		if (!payload || typeof payload !== "object") return;
		const event = payload as Record<string, unknown>;
		const taskId = typeof event.taskId === "string" ? event.taskId : undefined;
		const agent = typeof event.agent === "string" ? event.agent : undefined;
		if (!taskId || !agent) return;
		persistTaskEvent(event, "queued");
		dashboardState.visible = true;
		updateDashboard({
			agent,
			artifacts: true,
			kind: event.mode === "oneshot" ? "oneshot" : "pane",
			message: typeof event.task === "string" ? event.task : undefined,
			paneId: typeof event.paneId === "string" ? event.paneId : undefined,
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
		persistTaskEvent(event, "running");
		dashboardState.visible = true;
		updateDashboard({
			agent,
			kind: event.mode === "pane" ? "pane" : "oneshot",
			message: typeof event.task === "string" ? event.task : undefined,
			paneId: typeof event.paneId === "string" ? event.paneId : undefined,
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
		dashboardState.visible = true;
		const existingKey = dashboardKeyForTask(taskId);
		const paneKey = `pane:${agent}`;
		const currentPane = dashboardState.items[paneKey];
		if (!existingKey && currentPane?.kind === "pane" && currentPane.taskId !== taskId) return;
		const existing = existingKey ? dashboardState.items[existingKey] : currentPane?.taskId === taskId ? currentPane : undefined;
		const transcriptPath = typeof event.transcriptPath === "string" ? event.transcriptPath : existing?.transcriptPath;
		const eventUsage = normalizeUsageStats(event.usage);
		const eventModel = typeof event.model === "string" ? event.model : undefined;
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
			message: typeof event.summary === "string" ? event.summary : existing?.message,
			paneId: kind === "pane" ? existing?.paneId ?? (typeof event.paneId === "string" ? event.paneId : undefined) : undefined,
			startedAt: existing?.startedAt,
			status: effectiveStatus,
			task: existing?.task ?? (typeof event.task === "string" ? event.task : undefined),
			taskId,
			transcriptPath,
			updatedAt: new Date().toISOString(),
			usage: eventUsage ?? existing?.usage,
			model: eventModel ?? existing?.model,
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
		patchDashboard(typeof event.taskId === "string" ? event.taskId : undefined, {
			bridge: Boolean(event.bridge),
			paneId: typeof event.paneId === "string" ? event.paneId : undefined,
		});
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
		dashboardState = { collapsed: dashboardDefaultCollapsed(ctx.cwd), mode: dashboardDefaultCollapsed(ctx.cwd) ? "compact" : "normal", visible: true, items: {} };
		refreshAgentCommandCompletions(ctx);
		if (completionPoller) clearInterval(completionPoller);
		if (childInboxPoller) clearInterval(childInboxPoller);
		if (childTitlePoller) clearInterval(childTitlePoller);

		const runtimeRoot = runtimeDirForContext(ctx);

		if (childAgentName) {
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
					pi.sendUserMessage(prompt);
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
					updateDashboardFromTaskRecord(refreshed.record, runtimeRoot);
					if (refreshed.record.transcriptPath && (refreshed.record.status === "completed" || refreshed.record.status === "failed" || refreshed.record.status === "blocked")) {
						const capturedTaskId = refreshed.record.taskId;
						parseTranscriptUsage(refreshed.record.transcriptPath)
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
	});

	pi.on("agent_end", async (_event, ctx) => {
		if (!childAgentName) return;
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

			if (!pendingMatches && !manualCompletionOk) {
				await markTaskNeedsCompletion(runtimeRoot, childAgentName, taskId, {
					diagnostic: missingDiagnostic,
					outboxFile,
					processingFile: activeTaskFile,
					transcriptPath: ctx.sessionManager.getSessionFile() ?? undefined,
				});
				ctx.ui.setStatus("agent", `${childAgentName} needs completion ${shortTaskId(taskId, 18)}`);
				pi.sendMessage({
					customType: "subagent-missing-completion",
					content: missingDiagnostic,
					details: { agent: childAgentName, taskId, outboxFile, processingFile: activeTaskFile },
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
	});

	pi.on("session_shutdown", () => {
		if (completionPoller) clearInterval(completionPoller);
		if (childInboxPoller) clearInterval(childInboxPoller);
		if (dashboardCtx) setMiniDashboardWidget(dashboardCtx, SUBAGENT_WIDGET_KEY, MINI_DASHBOARD_RANK.AGENTS, undefined);
		completionPoller = undefined;
		childInboxPoller = undefined;
		dashboardCtx = undefined;
	});

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
						"Commands: `/agents show <name>`, `/agents:start <name>` (resume/reuse), `/agents:new <name>` (fresh session), `/agents:send <name> <task>`, `/agents:attach <name>`, `/agents:stop <name>`, `/agents status`, `/agents:trace <ref>`, `/agents:toggle`. The popup's History tab browses past tasks visually.",
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
		const items = agentCommandCompletions
			.filter((agent) => (!needsPane || agent.pane) && (!query || agent.value.toLowerCase().startsWith(query)))
			.slice(0, 20)
			.map((agent) => ({ value: agent.value, label: agent.label, description: agent.description }));
		return items.length > 0 ? items : null;
	};

	const traceRefCompletions = (prefix: string) => {
		const query = prefix.trimStart().toLowerCase();
		const records = Object.values(dashboardState.items).sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
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

	for (const sub of ["start", "new", "send", "attach", "stop"] as const) {
		const description =
			sub === "start" ? "Start or reuse a persistent pane: /agents:start <name>" :
			sub === "new" ? "Start a persistent pane with a fresh session: /agents:new <name>" :
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

	const toggleDashboardMode = async (ctx: ExtensionContext) => {
		dashboardCtx = ctx;
		if (!dashboardState.visible) {
			dashboardState.visible = true;
			dashboardState.mode = "compact";
		} else if (dashboardState.mode === "compact") {
			dashboardState.mode = "normal";
		} else if (dashboardState.mode === "normal") {
			dashboardState.mode = "expanded";
		} else {
			dashboardState.visible = false;
		}
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
		await openAgentsBrowser(ctx, "project", undefined, runtimeRoot, parentSessionId, parentModel, parentThinkingLevel, pi.getActiveTools(), () => activeDashboardItems(Object.values(dashboardState.items)), removeDashboardAgent);
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
				details: { agent: agentName, runtimeRoot, samples: 0, timedOut: false, transitioned: false },
				isError: true,
			};
		}
		if (!paneSessionBelongsToRuntime(runtimeRoot, entry)) {
			return {
				text: `Refusing to wait for ${agentName}: pane session file is outside this runtime. Session: ${entry.sessionFile}. Runtime: ${runtimeRoot}`,
				details: { agent: agentName, paneId: entry.paneId, runtimeRoot, samples: 0, sessionFile: entry.sessionFile, timedOut: false, transitioned: false },
				isError: true,
			};
		}
		if (!(await paneExists(entry.paneId))) {
			return {
				text: `Agent ${agentName} is not live.`,
				details: { agent: agentName, paneId: entry.paneId, runtimeRoot, samples: 0, sessionFile: entry.sessionFile, timedOut: false, transitioned: false },
				isError: true,
			};
		}
		const metadata = await ensurePaneBridgeMetadata(runtimeRoot, entry);
		const bridgeBin = metadata ? await resolvePiBridgeBin() : undefined;
		const targetArgs = metadata ? bridgeTargetArgs(metadata) : [];
		if (!bridgeBin || targetArgs.length === 0) {
			return {
				text: `No live pi-bridge target for ${agentName}; cannot wait for isIdle transition.`,
				details: { agent: agentName, paneId: entry.paneId, runtimeRoot, samples: 0, sessionFile: entry.sessionFile, timedOut: false, transitioned: false },
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
			timedOut: wait.timedOut,
			transitioned: wait.transitioned,
		};
		return {
			text: wait.transitioned
				? `${agentName} is idle (pane ${entry.paneId}).`
				: `Timed out waiting for ${agentName} idle transition after ${timeoutMs}ms.`,
			details,
			isError: !wait.transitioned,
		};
	};

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
			updateDashboardFromTaskRecord({ ...record, updatedAt: new Date().toISOString() }, runtimeRoot);
			await persistRuntimeSnapshot(ctx, runtimeRoot);
			const diagnosticBlock = params.verbose && diagnostics.length > 0 ? `\n\n### Artifact diagnostics\n${diagnostics.map((line) => `- ${line}`).join("\n")}` : "";
			return {
				content: [{ type: "text", text: `${formatTaskRecordResult(record, params.verbose ?? false)}${diagnosticBlock}` }],
				details: { agent: record.agent, paneId: record.paneId, summary: record.summary, status: record.status, taskId: record.taskId, notes: record.notes, diagnostics: record.diagnostics, completionMessageEmitted } satisfies GetSubagentResultDetails,
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
				updateDashboard({
					agent: record.agent,
					artifacts: steerKind === "pane" ? Boolean(record.completionArchivePath || record.outboxFile || record.transcriptPath) : Boolean(record.transcriptPath),
					completedAt: record.completedAt,
					kind: steerKind,
					message: record.summary || record.task,
					model: record.model,
					paneId: record.paneId,
					startedAt: record.createdAt,
					status: dashboardStatusFor(record.status, steerKind),
					task: record.task,
					taskId: record.taskId,
					transcriptPath: record.transcriptPath,
					updatedAt: new Date().toISOString(),
					usage: record.usage,
				});
			}

			const registry = await readPaneRegistry(runtimeRoot);
			const entry = registry[agentName];
			if (!entry) return { content: [{ type: "text", text: `No persistent pane registry entry for ${agentName} in runtime ${runtimeRoot}.` }], details: {}, isError: true };
			if (!paneSessionBelongsToRuntime(runtimeRoot, entry)) return { content: [{ type: "text", text: `Refusing to steer ${agentName}: pane session file is outside this runtime. Session: ${entry.sessionFile}. Runtime: ${runtimeRoot}` }], details: {}, isError: true };
			if (!(await paneExists(entry.paneId))) return { content: [{ type: "text", text: `Agent ${agentName} is not live.` }], details: {}, isError: true };

			const deliverAs = params.deliverAs ?? "steer";
			const followUpTask = isFollowUpDelivery(deliverAs) ? await createFollowUpTask(runtimeRoot, agentName, entry, params.message) : undefined;
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

	pi.on("before_agent_start", (event, ctx) => {
		if (!pi.getActiveTools().includes("subagent")) return;

		const discovery = discoverAgents(ctx.cwd, "project");
		if (discovery.agents.length === 0) return;

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
	});

	pi.registerTool({
		renderShell: "self",
		name: "subagent",
		label: "Agent",
		description: [
			"Delegate tasks to specialized agents with isolated context.",
			"Modes: single (agent + task), parallel (tasks array), chain (sequential with {previous} placeholder).",
			"Bg agents use fresh one-shot sessions by default; pass sessionKey only when you want continuity.",
			`Parallel calls above ${MAX_PARALLEL_TASKS} items are internally batched; callers do not need to split requests.`,
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
				const chainSteps = assignEphemeralSessionKeys(params.chain as Array<{ agent: string; task: string; cwd?: string; sessionKey?: string }>);
				const results: SingleResult[] = [];
				let previousOutput = "";

				for (let i = 0; i < chainSteps.length; i++) {
					const step = chainSteps[i];
					const taskWithContext = step.task.replace(/\{previous\}/g, previousOutput);

					const chainUpdate: OnUpdateCallback | undefined = onUpdate
						? (partial) => {
								const currentResult = partial.details?.results[0];
								if (currentResult) {
									const allResults = [...results, currentResult].map((result) => {
										const rawOutput = getFinalOutput(result.messages);
										return {
											...result,
											messages: cloneMessagesForDetails(
												result.messages,
												rawOutput ? truncateForDetails(rawOutput, ctx.cwd) : undefined,
												ctx.cwd,
											),
										};
									});
									onUpdate({
										content: partial.content,
										details: makeDetails("chain")(allResults),
									});
								}
							}
						: undefined;

					const stepAgent = agents.find((agent) => agent.name === step.agent);
					const result = stepAgent?.pane
						? await runPersistentPaneAgent(
								ctx.cwd,
								runtimeRoot,
								parentSessionId,
								agents,
								step.agent,
								taskWithContext,
								step.cwd,
								parentModel,
								parentThinkingLevel,
								i + 1,
								pi,
								params.forceSpawn ?? false,
								params.resumeSession,
								removeDashboardAgent,
							)
						: await runSingleAgent(
								ctx.cwd,
								runtimeRoot,
								agents,
								step.agent,
								taskWithContext,
								step.cwd,
								parentModel,
								parentThinkingLevel,
								i + 1,
								pi,
								signal,
								chainUpdate,
								makeDetails("chain"),
								step.sessionKey,
							);
					results.push(result);
					if (!stepAgent?.pane) {
						updateDashboard({
							agent: result.agent,
							kind: "oneshot",
							message: oneLinePreview(getFinalOutput(result.messages), 120) || result.task,
							model: result.model,
							status: result.exitCode === 0 ? "completed" : "failed",
							task: result.task,
							taskId: result.taskId ?? `${result.agent}-step-${i + 1}`,
							transcriptPath: result.transcriptPath,
							updatedAt: new Date().toISOString(),
							usage: result.usage,
						});
					}

					const isError = result.exitCode !== 0 || result.stopReason === "error" || result.stopReason === "aborted";
					if (isError) {
						const errorMsg = result.errorMessage || result.stderr || getFinalOutput(result.messages) || "(no output)";
						const preparedResults = await Promise.all(
							results.map((candidate, index) =>
								prepareSingleResultForReturn(
									candidate,
									runtimeRoot,
									ctx.cwd,
									`chain-step-${candidate.step ?? index + 1}`,
									candidate === result ? errorMsg : undefined,
								),
							),
						);
						const failed = preparedResults[preparedResults.length - 1];
						failed.result.errorMessage = failed.text || errorMsg;
						const details = makeDetails("chain")(preparedResults.map((prepared) => prepared.result));
						return {
							content: [{ type: "text", text: `Chain stopped at step ${i + 1} (${step.agent}): ${failed.text || "(no output)"}` }],
							details: detailsWithTruncation(details, failed),
							isError: true,
						};
					}
					previousOutput = getFinalOutput(result.messages);
				}
				const preparedResults = await Promise.all(
					results.map((result, index) =>
						prepareSingleResultForReturn(result, runtimeRoot, ctx.cwd, `chain-step-${result.step ?? index + 1}`),
					),
				);
				const last = preparedResults[preparedResults.length - 1];
				const details = makeDetails("chain")(preparedResults.map((prepared) => prepared.result));
				return {
					content: [{ type: "text", text: last.text || "(no output)" }],
					details: detailsWithTruncation(details, last),
				};
			}

			if (params.tasks && params.tasks.length > 0) {
				const parallelTasks = assignEphemeralSessionKeys(params.tasks as Array<{ agent: string; task: string; cwd?: string; sessionKey?: string }>);
				const parallelBatchSize = Math.max(1, Math.floor(settingNumber("maxParallelTasks", MAX_PARALLEL_TASKS, ctx.cwd)));

				const allResults: SingleResult[] = new Array(params.tasks.length);
				for (let i = 0; i < params.tasks.length; i++) {
					allResults[i] = {
						agent: parallelTasks[i].agent,
						agentSource: "unknown",
						task: parallelTasks[i].task,
						exitCode: -1,
						messages: [],
						stderr: "",
						usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
					};
				}

				const emitParallelUpdate = () => {
					if (onUpdate) {
						const running = allResults.filter((r) => r.exitCode === -1).length;
						const done = allResults.filter((r) => r.exitCode !== -1).length;
						const updateResults = allResults.map((result) => {
							const rawOutput = getFinalOutput(result.messages);
							return {
								...result,
								messages: cloneMessagesForDetails(
									result.messages,
									rawOutput ? truncateForDetails(rawOutput, ctx.cwd) : undefined,
									ctx.cwd,
								),
							};
						});
						onUpdate({
							content: [{ type: "text", text: `Parallel: ${done}/${allResults.length} done, ${running} running...` }],
							details: makeDetails("parallel")(updateResults),
						});
					}
				};

				const maxConcurrency = Math.max(1, Math.floor(settingNumber("maxConcurrency", MAX_CONCURRENCY, ctx.cwd)));
				const results = await mapInBatchesWithConcurrencyLimit(parallelTasks, parallelBatchSize, maxConcurrency, async (t: { agent: string; task: string; cwd?: string; sessionKey?: string }, index) => {
					const updateOneshotDashboard = (item: SingleResult) => {
						updateDashboard({
							agent: item.agent,
							kind: "oneshot",
							message: oneLinePreview(getFinalOutput(item.messages), 120) || item.task,
							model: item.model,
							status: item.exitCode === -1 ? "running" : item.exitCode === 0 ? "completed" : "failed",
							task: item.task,
							taskId: item.taskId ?? `${item.agent}-${index}`,
							transcriptPath: item.transcriptPath,
							updatedAt: new Date().toISOString(),
							usage: item.usage,
						});
					};
					const taskAgent = agents.find((agent) => agent.name === t.agent);
					const result = taskAgent?.pane
						? await runPersistentPaneAgent(
								ctx.cwd,
								runtimeRoot,
								parentSessionId,
								agents,
								t.agent,
								t.task,
								t.cwd,
								parentModel,
								parentThinkingLevel,
								undefined,
								pi,
								params.forceSpawn ?? false,
								params.resumeSession,
								removeDashboardAgent,
							)
						: await runSingleAgent(
								ctx.cwd,
								runtimeRoot,
								agents,
								t.agent,
								t.task,
								t.cwd,
								parentModel,
								parentThinkingLevel,
								undefined,
								pi,
								signal,
								(partial) => {
									if (partial.details?.results[0]) {
										allResults[index] = partial.details.results[0];
										updateOneshotDashboard(partial.details.results[0]);
										emitParallelUpdate();
									}
								},
								makeDetails("parallel"),
								t.sessionKey,
							);
					allResults[index] = result;
					if (!taskAgent?.pane) updateOneshotDashboard(result);
					emitParallelUpdate();
					return result;
				});

				const successCount = results.filter((r) => r.exitCode === 0).length;
				const perResultLimits = (() => {
					const total = { maxBytes: Math.max(1, Math.floor(settingNumber("resultMaxBytes", DEFAULT_RESULT_MAX_BYTES, ctx.cwd))), maxLines: Math.max(1, Math.floor(settingNumber("resultMaxLines", DEFAULT_RESULT_MAX_LINES, ctx.cwd))) };
					const count = Math.max(1, results.length);
					return { maxBytes: Math.max(1024, Math.floor(total.maxBytes / count)), maxLines: Math.max(40, Math.floor(total.maxLines / count)) };
				})();
				const preparedResults = await Promise.all(
					results.map((result, index) =>
						prepareSingleResultForReturn(
							result,
							runtimeRoot,
							ctx.cwd,
							`parallel-${index + 1}-${result.agent}`,
							undefined,
							perResultLimits,
						),
					),
				);
				const sections = preparedResults.map((prepared) => {
					const r = prepared.result;
					const status = r.exitCode === 0 ? "completed" : r.exitCode === -1 ? "running" : "failed";
					return `## ${r.agent} (${status})\n${prepared.text || "(no output)"}`;
				});
				return {
					content: [{ type: "text", text: `Parallel: ${successCount}/${results.length} succeeded\n\n${sections.join("\n\n")}` }],
					details: makeDetails("parallel")(preparedResults.map((prepared) => prepared.result)),
				};
			}

			if (params.agent && params.task) {
				const agent = agents.find((candidate) => candidate.name === params.agent);
				const result = agent?.pane
					? await runPersistentPaneAgent(
							ctx.cwd,
							runtimeRoot,
							parentSessionId,
							agents,
							params.agent,
							params.task,
							params.cwd,
							parentModel,
							parentThinkingLevel,
							undefined,
							pi,
							params.forceSpawn ?? false,
							params.resumeSession,
							removeDashboardAgent,
						)
					: await runSingleAgent(
							ctx.cwd,
							runtimeRoot,
							agents,
							params.agent,
							params.task,
							params.cwd,
							parentModel,
							parentThinkingLevel,
							undefined,
							pi,
							signal,
							onUpdate,
							makeDetails("single"),
							params.sessionKey,
						);
				if (!agent?.pane) {
					updateDashboard({
						agent: result.agent,
						kind: "oneshot",
						message: oneLinePreview(getFinalOutput(result.messages), 120) || result.task,
						model: result.model,
						status: result.exitCode === 0 ? "completed" : "failed",
						task: result.task,
						taskId: result.taskId ?? result.agent,
						transcriptPath: result.transcriptPath,
						updatedAt: new Date().toISOString(),
						usage: result.usage,
					});
				}
				const isError = result.exitCode !== 0 || result.stopReason === "error" || result.stopReason === "aborted";
				if (isError) {
					const errorMsg = result.errorMessage || result.stderr || getFinalOutput(result.messages) || "(no output)";
					const prepared = await prepareSingleResultForReturn(result, runtimeRoot, ctx.cwd, "single-error", errorMsg);
					prepared.result.errorMessage = prepared.text || errorMsg;
					const details = makeDetails("single")([prepared.result]);
					return {
						content: [{ type: "text", text: `Agent ${result.stopReason || "failed"}: ${prepared.text || "(no output)"}` }],
						details: detailsWithTruncation(details, prepared),
						isError: true,
					};
				}
				const prepared = await prepareSingleResultForReturn(result, runtimeRoot, ctx.cwd, "single");
				const details = makeDetails("single")([prepared.result]);
				return {
					content: [{ type: "text", text: prepared.text || "(no output)" }],
					details: detailsWithTruncation(details, prepared),
				};
			}

			const available = agents.map((a) => `${a.name} (${a.source})`).join(", ") || "none";
			return {
				content: [{ type: "text", text: `Invalid parameters. Available agents: ${available}` }],
				details: makeDetails("single")([]),
			};
		},

		renderCall(args, theme, _context) {
			const scope: AgentScope = args.agentScope ?? "project";
			if (args.chain && args.chain.length > 0) {
				let text =
					theme.fg("toolTitle", theme.bold("agents ")) +
					theme.fg("accent", `chain (${args.chain.length} steps)`) +
					theme.fg("muted", ` [${scope}]`);
				for (let i = 0; i < Math.min(args.chain.length, 3); i++) {
					const step = args.chain[i];
					const cleanTask = step.task.replace(/\{previous\}/g, "").trim();
					const preview = cleanTask.length > 40 ? `${cleanTask.slice(0, 40)}...` : cleanTask;
					text +=
						"\n  " +
						theme.fg("muted", `${i + 1}.`) +
						" " +
						theme.fg("accent", step.agent) +
						theme.fg("dim", ` ${preview}`);
				}
				if (args.chain.length > 3) text += `\n  ${theme.fg("muted", `... +${args.chain.length - 3} more`)}`;
				return wrappedText(text);
			}
			if (args.tasks && args.tasks.length > 0) {
				return new Container();
			}
			const agentName = args.agent || "...";
			try {
				const agent = discoverAgents(_context?.cwd ?? process.cwd(), scope).agents.find((candidate) => candidate.name === agentName);
				if (agent?.pane) return new Container();
			} catch {
				// Keep the generic call preview if discovery fails.
			}
			const preview = args.task ? oneLinePreview(args.task, 56) : "...";
			let text = `${agentsCommandBullet(theme)}${agentWord(theme)} ${ansiMagenta(theme.bold(agentName))}`;
			if (scope !== "project") text += theme.fg("dim", ` · ${scope}`);
			text += `\n${subagentBranch(theme, "└", _context?.cwd)}${theme.fg("dim", preview)}`;
			return wrappedText(text);
		},

		renderResult(result, { expanded }, theme, context) {
			const cwd = context?.cwd;
			const collapsedItemCount = Math.max(1, Math.floor(settingNumber("collapsedItemCount", COLLAPSED_ITEM_COUNT, context?.cwd)));
			const details = result.details as SubagentDetails | undefined;
			if (!details || details.results.length === 0) {
				const text = result.content[0];
				return wrappedText(text?.type === "text" ? text.text : "(no output)");
			}

			const mdTheme = getMarkdownTheme();
			const truncationBadge = (r: SingleResult) => (r.truncation?.truncated ? theme.fg("warning", " · truncated") : "");
			const fullOutputLine = (r: SingleResult) =>
				r.fullOutputPath
					? theme.fg("dim", `Full output: ${compactPath(r.fullOutputPath)}`)
					: r.fullOutputError
						? theme.fg("warning", `Full output unavailable: ${r.fullOutputError}`)
						: "";
			const transcriptLine = (r: SingleResult) => (r.transcriptPath ? theme.fg("dim", `Transcript: ${compactPath(r.transcriptPath)}`) : "");
			const queuedPaneLine = (r: SingleResult, _dashboard = false) => {
				if (!r.taskId || !r.paneId) return "";
				const mode = r.paneSessionMode === "live" ? "reused live pane" : r.paneSessionMode === "resumed" ? "resumed pane" : "new pane";
				const suffix = `${theme.fg("dim", ` · ${mode}`)}${theme.fg("dim", " · ctrl+o expand")}`;
				return agentStatusLine(theme, r.agent, "Queued task", "warning", suffix);
			};
			const queuedTaskPreviewComponent = (r: SingleResult, dashboard = false) => ({
				invalidate() {},
				render(width: number): string[] {
					const header = queuedPaneLine(r, dashboard);
					const task = r.task.replace(/\s+/g, " ").trim() || "queued task";
					const firstPrefix = subagentBranch(theme, "└", cwd);
					const nextPrefix = " ".repeat(Math.max(0, visibleWidth(firstPrefix)));
					const textWidth = Math.max(20, width - Math.max(visibleWidth(firstPrefix), visibleWidth(nextPrefix)));
					const wrapped = wrapTextWithAnsi(task, textWidth);
					const shown = wrapped.slice(0, 2);
					if (wrapped.length > shown.length && shown.length > 0) shown[shown.length - 1] = truncateToWidth(`${shown[shown.length - 1]}…`, textWidth, "…");
					return [
						header,
						`${firstPrefix}${theme.fg("dim", shown[0] ?? "queued task")}`,
						...(shown[1] ? [`${nextPrefix}${theme.fg("dim", shown[1])}`] : []),
					];
				},
			});
			const expandedQueuedTaskComponent = (r: SingleResult) => {
				const container = new Container();
				container.addChild(wrappedText(queuedPaneLine(r)));
				addSectionHeading(container, theme, "Queued task");
				container.addChild(new Markdown(r.task.trim() || "(empty task)", 0, 0, mdTheme));
				if (r.taskId || r.queuedTaskFile || r.queuedOutboxFile || r.transcriptPath) {
					if (r.paneSessionMode) addWrappedSection(container, theme, "Pane session", r.paneSessionMode === "live" ? "Reused live pane" : r.paneSessionMode === "resumed" ? "Resumed saved pane session" : "Started new pane session", "dim");
					if (r.taskId) addWrappedSection(container, theme, "Task ID", r.taskId, "dim");
					addArtifactPathSection(container, theme, "Inbox", r.queuedTaskFile);
					addArtifactPathSection(container, theme, "Completion", r.queuedOutboxFile);
					addArtifactPathSection(container, theme, "Transcript", r.transcriptPath);
				}
				return container;
			};
			const addFinalResponseMarkdown = (container: Container, finalOutput: string, toolCalls: DisplayItem[]) => {
				if (!finalOutput.trim()) {
					container.addChild(wrappedText(theme.fg("muted", "(no final response)")));
					return;
				}
				if (finalOutputLooksLikeToolEcho(finalOutput, toolCalls)) {
					container.addChild(wrappedText(finalResponseSuppressedLine(theme)));
					return;
				}
				container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme));
			};

			const renderDisplayItems = (items: DisplayItem[], limit?: number) => {
				const toShow = limit ? items.slice(-limit) : items;
				const skipped = limit && items.length > limit ? items.length - limit : 0;
				let text = "";
				if (skipped > 0) text += theme.fg("muted", `... ${skipped} earlier items\n`);
				for (const [index, item] of toShow.entries()) {
					const branch = subagentBranch(theme, index === toShow.length - 1 ? "└" : "├", cwd);
					if (item.type === "text") {
						const preview = expanded ? item.text : item.text.split("\n").slice(0, 3).join("\n");
						const lines = preview.split(/\r?\n/);
						text += `${branch}${theme.fg("toolOutput", lines[0] ?? "")}\n`;
						for (const line of lines.slice(1)) text += `${subagentBranch(theme, "│", cwd)}${theme.fg("toolOutput", line)}\n`;
					} else {
						text += `${branch}${formatToolCall(item.name, item.args, theme.fg.bind(theme))}\n`;
					}
				}
				return text.trimEnd();
			};

			if (details.mode === "single" && details.results.length === 1) {
				const r = details.results[0];
				if (r.duplicateQueued) return new Container();
				// runSingleAgent uses exitCode -1 as the still-running sentinel while
				// emitting streaming partials; only a positive exitCode (or a terminal
				// stopReason) is a real failure.
				const isRunning = r.exitCode === -1;
				const isError = !isRunning && (r.exitCode > 0 || r.stopReason === "error" || r.stopReason === "aborted");
				const isQueued = !isError && !isRunning && Boolean(r.taskId && r.paneId);
				const displayItems = getDisplayItems(r.messages);
				const finalOutput = getFinalOutput(r.messages);
				const queued = queuedPaneLine(r);
				const quietDashboard = !expanded && dashboardEnabled(cwd) && quietInline(cwd);

				if (expanded) {
					if (isQueued) return expandedQueuedTaskComponent(r);
					const container = new Container();
					const statusLabel = isQueued ? "Queued task" : isRunning ? "working" : isError ? "failed" : "completed";
					const statusTone = isQueued || isRunning ? "warning" : isError ? "error" : "success";
					let header = agentStatusLine(theme, r.agent, statusLabel, statusTone, theme.fg("dim", ` · ${isQueued ? "pane" : "bg"}`));
					if (isError && r.stopReason) header += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
					header += truncationBadge(r);
					container.addChild(wrappedText(header));
					if (isError && r.errorMessage) container.addChild(wrappedText(theme.fg("error", `Error: ${r.errorMessage}`)));
					container.addChild(new Spacer(1));
					container.addChild(wrappedText(theme.fg("muted", "─── Task ───")));
					container.addChild(wrappedText(theme.fg("dim", r.task)));
					container.addChild(new Spacer(1));
					const toolCalls = displayItems.filter((item) => item.type === "toolCall");
					container.addChild(wrappedText(theme.fg("muted", "─── Tools used ───")));
					if (toolCalls.length === 0) container.addChild(wrappedText(theme.fg("muted", "(none)")));
					else {
						for (const item of toolCalls) {
							container.addChild(
								wrappedText(theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme))),
							);
						}
					}
					container.addChild(new Spacer(1));
					container.addChild(wrappedText(theme.fg("muted", "─── Final response ───")));
					addFinalResponseMarkdown(container, finalOutput, toolCalls);
					const outputPath = fullOutputLine(r);
					if (outputPath) container.addChild(wrappedText(outputPath));
					const transcript = transcriptLine(r);
					if (transcript) container.addChild(wrappedText(transcript));
					const usageStr = queued ? "" : formatUsageStats(r.usage, r.model);
					if (usageStr) {
						container.addChild(new Spacer(1));
						container.addChild(wrappedText(theme.fg("dim", usageStr)));
					}
					return container;
				}


				if (queued) return queuedTaskPreviewComponent(r, quietDashboard);

				if (quietDashboard && !queued && !isError) {
					const toolCalls = displayItems.filter((item) => item.type === "toolCall");
					const preview = finalOutput && !finalOutputLooksLikeToolEcho(finalOutput, toolCalls)
						? oneLinePreview(finalOutput, 180)
						: r.task
							? oneLinePreview(r.task, 140)
							: "completed";
					let text = `${theme.fg("toolTitle", theme.bold("Result from"))} ${ansiMagenta(theme.bold(r.agent))}${theme.fg("dim", " · bg · ctrl+o")}${truncationBadge(r)}`;
					if (preview) text += `\n${subagentBranch(theme, "└", cwd)}${theme.fg("toolOutput", preview)}`;
					const outputPath = fullOutputLine(r);
					if (outputPath) text += `\n${outputPath}`;
					return wrappedText(text);
				}

				const compactStatusLabel = isRunning ? "working" : isError ? "failed" : "completed";
				const compactStatusTone = isRunning ? "warning" : isError ? "error" : "success";
				let text = queued || agentStatusLine(theme, r.agent, compactStatusLabel, compactStatusTone, `${theme.fg("dim", " · bg")}${theme.fg("dim", " · ctrl+o")}`);
				if (isError && r.stopReason) text += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
				text += truncationBadge(r);
				if (queued) text += `\n${subagentBranch(theme, "└", cwd)}${theme.fg("dim", r.task ? oneLinePreview(r.task, 120) : "queued task")}`;
				else if (isError && r.errorMessage) text += `\n${theme.fg("error", `Error: ${r.errorMessage}`)}`;
				else if (displayItems.length === 0) text += `\n${subagentBranch(theme, "└", cwd)}${theme.fg("dim", r.task ? oneLinePreview(r.task, 120) : "(no output)")}`;
				else {
					if (r.task) text += `\n${subagentBranch(theme, "├", cwd)}${theme.fg("dim", oneLinePreview(r.task, 120))}`;
					text += `\n${renderDisplayItems(displayItems, collapsedItemCount)}`;
					if (displayItems.length > collapsedItemCount) text += `\n${theme.fg("muted", "… more in ctrl+o")}`;
				}
				const outputPath = queued ? "" : fullOutputLine(r);
				if (outputPath) text += `\n${outputPath}`;
				const usageStr = formatUsageStats(r.usage, r.model);
				if (usageStr) text += `\n${theme.fg("dim", usageStr)}`;
				return wrappedText(text);
			}

			const aggregateUsage = (results: SingleResult[]) => {
				const total: UsageStats = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
				for (const r of results) {
					total.input += r.usage.input;
					total.output += r.usage.output;
					total.cacheRead += r.usage.cacheRead;
					total.cacheWrite += r.usage.cacheWrite;
					total.cost += r.usage.cost;
					total.contextTokens = Math.max(total.contextTokens, r.usage.contextTokens || 0);
					total.turns += r.usage.turns;
				}
				return total;
			};

			if (details.mode === "chain") {
				const successCount = details.results.filter((r) => r.exitCode === 0).length;
				const runningCount = details.results.filter((r) => r.exitCode === -1).length;
				const chainStepIcon = (r: SingleResult) =>
					r.exitCode === -1
						? theme.fg("warning", ICONS.cog)
						: r.exitCode === 0
							? theme.fg("success", ICONS.check)
							: theme.fg("error", ICONS.times);
				const icon = runningCount > 0
					? theme.fg("warning", ICONS.cog)
					: successCount === details.results.length
						? theme.fg("success", ICONS.check)
						: theme.fg("error", ICONS.times);

				if (expanded) {
					const container = new Container();
					container.addChild(
						wrappedText(
							icon +
								" " +
								theme.fg("toolTitle", theme.bold("chain ")) +
								theme.fg("accent", `${successCount}/${details.results.length} steps`),
						),
					);

					for (const r of details.results) {
						const rIcon = chainStepIcon(r);
						const displayItems = getDisplayItems(r.messages);
						const finalOutput = getFinalOutput(r.messages);

						container.addChild(new Spacer(1));
						container.addChild(
							wrappedText(
								`${theme.fg("muted", `─── Step ${r.step}: `) + theme.fg("accent", r.agent)} ${rIcon}${truncationBadge(r)}`,
							),
						);
						container.addChild(wrappedText(theme.fg("muted", "Task: ") + theme.fg("dim", r.task)));
						const toolCalls = displayItems.filter((item) => item.type === "toolCall");
						container.addChild(wrappedText(theme.fg("muted", "Tools used:")));
						if (toolCalls.length === 0) container.addChild(wrappedText(theme.fg("muted", "(none)")));
						else {
							for (const item of toolCalls) {
								container.addChild(
									wrappedText(theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme))),
								);
							}
						}

						container.addChild(wrappedText(theme.fg("muted", "Final response:")));
						addFinalResponseMarkdown(container, finalOutput, toolCalls);

						const outputPath = fullOutputLine(r);
						if (outputPath) container.addChild(wrappedText(outputPath));
						const transcript = transcriptLine(r);
						if (transcript) container.addChild(wrappedText(transcript));
						const stepUsage = formatUsageStats(r.usage, r.model);
						if (stepUsage) container.addChild(wrappedText(theme.fg("dim", stepUsage)));
					}

					const usageStr = formatUsageStats(aggregateUsage(details.results));
					if (usageStr) {
						container.addChild(new Spacer(1));
						container.addChild(wrappedText(theme.fg("dim", `Total: ${usageStr}`)));
					}
					return container;
				}

				let text =
					icon +
					" " +
					theme.fg("toolTitle", theme.bold("chain ")) +
					theme.fg("accent", `${successCount}/${details.results.length} steps`);
				for (const r of details.results) {
					const rIcon = chainStepIcon(r);
					const displayItems = getDisplayItems(r.messages);
					text += `\n\n${theme.fg("muted", `─── Step ${r.step}: `)}${theme.fg("accent", r.agent)} ${rIcon}${truncationBadge(r)}`;
					if (displayItems.length === 0) text += `\n${theme.fg("muted", "(no output)")}`;
					else text += `\n${renderDisplayItems(displayItems, 5)}`;
					const outputPath = fullOutputLine(r);
					if (outputPath) text += `\n${outputPath}`;
					const transcript = transcriptLine(r);
					if (transcript) text += `\n${transcript}`;
				}
				const usageStr = formatUsageStats(aggregateUsage(details.results));
				if (usageStr) text += `\n\n${theme.fg("dim", `Total: ${usageStr}`)}`;
				text += `\n${theme.fg("muted", "(ctrl+o to expand)")}`;
				return wrappedText(text);
			}

			if (details.mode === "parallel") {
				const running = details.results.filter((r) => r.exitCode === -1).length;
				const successCount = details.results.filter((r) => r.exitCode === 0).length;
				const failCount = details.results.filter((r) => r.exitCode > 0).length;
				const queuedPaneCount = details.results.filter((r) => r.exitCode === 0 && r.taskId && r.paneId).length;
				const oneshotCompletedCount = successCount - queuedPaneCount;
				const isRunning = running > 0;
				const total = details.results.length;
				const pluralN = (n: number) => (n === 1 ? "" : "s");
				const headerLabel = isRunning
					? `${total} agent${pluralN(total)} running`
					: failCount > 0
						? `${successCount}/${total} agent${pluralN(total)} completed`
						: queuedPaneCount === total
							? `${total} agent${pluralN(total)} launched`
							: queuedPaneCount > 0
								? `${total} agents launched (${oneshotCompletedCount} bg, ${queuedPaneCount} pane)`
								: `${total} agent${pluralN(total)} completed`;
				const hint = isRunning
					? ""
					: queuedPaneCount > 0
						? theme.fg("muted", " · see dashboard for live status")
						: dashboardEnabled(cwd) && quietInline(cwd) && !expanded
							? theme.fg("muted", " · lifecycle in dashboard")
						: expanded
							? ""
							: theme.fg("muted", " (ctrl+o to inspect)");
				const headerText =
					theme.fg("accent", "● ") +
					theme.fg("toolTitle", theme.bold(headerLabel)) +
					hint;
				const nameWidth = Math.min(28, Math.max(0, ...details.results.map((r) => visibleWidth(r.agent))));
				const rowTaskPreview = (r: SingleResult, maxChars: number) =>
					r.task ? theme.fg("dim", ` · ${oneLinePreview(r.task, maxChars)}`) : "";
				const treeText = details.results
					.map((r, index) => {
						const prefix = index === details.results.length - 1 ? "└" : "├";
						const name = ((text: string, width: number) => `${text}${" ".repeat(Math.max(0, width - visibleWidth(text)))}`)(ansiMagenta(theme.bold(r.agent)), nameWidth);
						return `${subagentBranch(theme, prefix, cwd)}${name}${rowTaskPreview(r, 100)}${truncationBadge(r)}`;
					})
					.join("\n");

				return wrappedText(`${headerText}\n${treeText}`);
			}

			const text = result.content[0];
			return wrappedText(text?.type === "text" ? text.text : "(no output)");
		},
	});

	emitSubagentEvent(pi, "subagents:ready", { mode: "extension" });
}
