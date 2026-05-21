import type { Message } from "@earendil-works/pi-ai";
import type { TruncationResult } from "@earendil-works/pi-coding-agent";
import type { AgentScope } from "./agents.js";

export const PACKAGE_ID = "pi-agents-tmux";
export const CONFIG_ID = "@vanillagreen/pi-agents-tmux";
export const SESSION_BRIDGE_PACKAGE_ID = "@vanillagreen/pi-session-bridge";
export const INSTALL_SYMBOL = Symbol.for("vstack.pi-agents-tmux.installed");
export const STATUSLINE_SYMBOL = Symbol.for("vstack.pi-agents-tmux.statusline");
export const STATS_BRIDGE_SYMBOL = Symbol.for("vstack.pi.agents");
export const SUBAGENT_STATE_TYPE = "vstack-subagents:runtime-state";
export const MAX_PARALLEL_TASKS = 8;
export const MAX_CONCURRENCY = 4;
export const COLLAPSED_ITEM_COUNT = 10;
export const PANE_LAUNCHER_VERSION = 9;
export const SUBAGENT_WIDGET_KEY = "vstack-agents-dashboard";
export const FIRST_AGENT_COLUMN_ROWS = 3;
export const NEXT_AGENT_COLUMN_ROWS = 4;
export const DETAIL_STRING_MAX_CHARS = 8 * 1024;
export const DEFAULT_RESULT_MAX_BYTES = 100 * 1024;
export const DEFAULT_RESULT_MAX_LINES = 4_000;
export const TRACE_VIEWER_WIDTH = "92%";
export const TRACE_VIEWER_MAX_HEIGHT = "88%";
export const AGENT_EDIT_CONFIRM_WIDTH = 96;
export const MALFORMED_COMPLETION_GRACE_MS = 1_500;

export type AgentAsciiColor = "red" | "green" | "yellow" | "blue" | "magenta" | "cyan";

export interface SubagentStatuslineInfo {
	name: string;
	color?: AgentAsciiColor;
}

export interface SubagentStatuslineBridge {
	getCurrentSubagent(cwd?: string): SubagentStatuslineInfo | undefined;
}

export interface SubagentStatsItem {
	agent: string;
	paneId?: string;
	status?: string;
	kind?: string;
	model?: string;
	effort?: string;
	usage?: { input: number; output: number; cacheRead: number; cacheWrite: number; cost: number; contextTokens: number; turns: number };
	updatedAt?: string;
}

export interface SubagentStatsBridge {
	getByPaneId(paneId: string): SubagentStatsItem | undefined;
	list(): SubagentStatsItem[];
}

export const AGENT_ASCII_COLOR_SEQUENCE: AgentAsciiColor[] = ["magenta", "green", "blue", "cyan", "yellow", "red"];

// Nerd Font glyphs (Font Awesome subset). All terminal output uses these
// instead of unicode geometric/emoji shapes so rendering is consistent
// regardless of font fallback behavior.
export const ICONS = {
	check: "\uf00c",
	times: "\uf00d",
	circleFilled: "\uf111",
	circleOpen: "\uf10c",
	clock: "\uf017",
	cog: "\uf013",
	refresh: "\uf021",
	hourglass: "\uf252",
	warning: "\uf071",
	dotSmall: "\uf444",
} as const;

export type VstackConfig = Record<string, unknown>;

export const AGENTS_BROWSER_WIDTH = "92%";
export const AGENTS_BROWSER_MAX_HEIGHT = "90%";
export const AGENTS_BROWSER_HEIGHT_RATIO = 0.9;
export const AGENTS_LEFT_MIN_WIDTH = 34;
export const AGENTS_LEFT_MAX_WIDTH = 48;
export const AGENTS_POPUP_PADDING_X = 2;
export const AGENTS_POPUP_PADDING_Y = 1;
export const AGENTS_POPUP_FRAME_ROWS = 2 + AGENTS_POPUP_PADDING_Y * 2;
export const VSTACK_MODAL_LOCK_SYMBOL = Symbol.for("vstack.pi.modal-lock");

export type AgentBrowserTabId = "agents" | "monitor";
export type AgentBrowserTabDef = { id: AgentBrowserTabId; label: string };
export const AGENTS_BROWSER_TAB: AgentBrowserTabDef = { id: "agents", label: "Agents" };
export const MONITOR_BROWSER_TAB: AgentBrowserTabDef = { id: "monitor", label: "Monitor" };
export const MONITOR_SUBTAB_LABELS = ["Summary", "Completion"] as const;

export type AgentBrowserAction =
	| { type: "attach"; agentName: string }
	| { type: "close" }
	| { type: "editFrontmatter"; agentName: string }
	| { type: "insert"; agentName: string }
	| { type: "reload" }
	| { type: "start"; agentName: string }
	| { type: "stop"; agentName: string };

export type AgentPaneStatus = { entry?: PaneRegistryEntry; live: boolean };

export interface AgentBrowserUiState {
	inspectorScroll: number;
	pane: "list" | "inspector";
	tab: AgentBrowserTabId;
	scope: AgentScope;
	selected: number;
	scroll: number;
	monitorSelected: number;
	monitorScroll: number;
	monitorSubtab: number;
}

export type MonitorDetailEntry = { items?: TraceViewerItem[]; loading?: boolean; error?: string };

export interface AgentBrowserLayout {
	bodyRows: number;
	innerRows: number;
	listRows: number;
}

export interface VstackModalLock {
	depth: number;
}

export interface AgentFrontmatterEdit {
	model: string;
	denyTools: string[];
	color: string;
}

export interface ChatMessage {
	timestamp: number;
	agent: string;
	taskId?: string;
	kind: "delegation" | "completion" | "steering";
	from: string;
	to: string;
	body: string;
	status?: string;
	filesChanged?: string[];
	notes?: string;
}

export interface UsageStats {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
	contextTokens: number;
	turns: number;
}

export interface AttemptSummary {
	attempt: number;
	errorEnvelope?: string;
	errorMessage?: string;
	exitCode: number;
	sessionKey?: string;
	sessionPath?: string;
	stderr?: string;
	stopReason?: string;
	taskId?: string;
	transcriptPath?: string;
}

export interface CwdSnapshot {
	cwd: string;
	head: string;
	dirty: boolean;
	status: string;
	lastCommit: {
		subject: string;
	};
	/** @deprecated Use status. */
	dirtyStatus: string;
	/** @deprecated Use lastCommit.subject. */
	lastCommitSubject: string;
}

export interface SingleResult {
	agent: string;
	agentSource: "user" | "project" | "unknown";
	task: string;
	sessionMode?: SessionMode;
	status?: PaneTaskStatus;
	needsCompletionReason?: string;
	cwdSnapshot?: CwdSnapshot;
	diagnostics?: string[];
	exitCode: number;
	attempt?: number;
	attempts?: AttemptSummary[];
	errorEnvelope?: string;
	messages: Message[];
	stderr: string;
	usage: UsageStats;
	model?: string;
	effort?: string;
	sessionKey?: string;
	sessionKeyExplicit?: boolean;
	sessionPath?: string;
	ephemeralSession?: boolean;
	taskId?: string;
	paneId?: string;
	queuedTaskFile?: string;
	queuedOutboxFile?: string;
	paneSessionMode?: "live" | "resumed" | "new";
	duplicateQueued?: boolean;
	transcriptPath?: string;
	stopReason?: string;
	errorMessage?: string;
	fullOutputError?: string;
	fullOutputPath?: string;
	step?: number;
	truncation?: TruncationResult;
}

export interface SubagentDetails {
	mode: "single" | "parallel" | "chain";
	agentScope: AgentScope;
	projectAgentsDir: string | null;
	results: SingleResult[];
	inventoryError?: {
		available: {
			allowed: string[];
			project: string[];
			user: string[];
		};
		missing: string[];
		scope: AgentScope;
	};
	fullOutputError?: string;
	fullOutputPath?: string;
	truncation?: TruncationResult;
}

export type DisplayItem = { type: "text"; text: string } | { type: "toolCall"; name: string; args: Record<string, any> };

export interface PaneRegistryEntry {
	agent: string;
	paneId: string;
	windowName: string;
	cwd: string;
	sessionFile: string;
	promptFile: string;
	launcherFile: string;
	model?: string;
	effort?: string;
	thinkingLevel?: string;
	startedAt: string;
	lastTaskAt?: string;
	lastTaskId?: string;
	launcherVersion?: number;
	layoutGroup?: number;
	primaryPaneId?: string;
	bridgePid?: string;
	bridgeSocket?: string;
}

export type PaneTaskStatus = "queued" | "running" | "completed" | "blocked" | "failed" | "needs_completion" | "unknown";
export type SessionMode = "fresh" | "resumed" | "new";

export interface PaneCompletion {
	agent?: string;
	taskId?: string;
	status?: PaneTaskStatus;
	reason?: string;
	summary?: string;
	filesChanged?: string[];
	validation?: string[];
	notes?: string;
}

export interface PaneCompletionDetails {
	agent: string;
	taskId: string;
	status: PaneTaskStatus;
	summary: string;
	filesChanged: string[];
	validation: string[];
	notes?: string;
	sourcePath: string;
	archivePath?: string;
	transcriptPath?: string;
	completedAt: string;
	paneId?: string;
}

export interface PaneCompletionMessageDetails {
	completions: PaneCompletionDetails[];
	partial?: boolean;
}

export interface AgentsCommandMessageDetails {
	action?: string;
	agent?: string;
	count?: number;
	error?: string;
	inboxFile?: string;
	outboxFile?: string;
	sessionFile?: string;
	status?: string;
	taskId?: string;
	transcriptPath?: string;
	windowName?: string;
}

export interface PaneTaskRecord {
	taskId: string;
	agent: string;
	task: string;
	status: PaneTaskStatus;
	sessionMode?: SessionMode;
	sessionKey?: string;
	kind?: DashboardKind;
	paneId?: string;
	inboxFile?: string;
	processingFile?: string;
	doneFile?: string;
	outboxFile?: string;
	completionSourcePath?: string;
	completionArchivePath?: string;
	transcriptPath?: string;
	usage?: UsageStats;
	model?: string;
	effort?: string;
	summary?: string;
	filesChanged?: string[];
	validation?: string[];
	notes?: string;
	cwdSnapshot?: CwdSnapshot;
	diagnostics?: string[];
	createdAt: string;
	updatedAt?: string;
	completedAt?: string;
}

export type PaneRegistry = Record<string, PaneRegistryEntry>;
export type PaneTaskRegistry = Record<string, PaneTaskRecord>;

export type DashboardDisplayMode = "compact" | "normal" | "expanded";
export type DashboardKind = "pane" | "oneshot";
export type CompletionMessageProvenance = "persisted" | "task-echo-fallback" | "fallback" | "placeholder" | "diagnostic";

export type SubagentDashboardStatus = PaneTaskStatus | "running" | "waiting";

export interface SubagentDashboardItem {
	agent: string;
	artifacts?: boolean;
	bridge?: boolean;
	completedAt?: string;
	kind: DashboardKind;
	message?: string;
	messageProvenance?: CompletionMessageProvenance;
	paneId?: string;
	sessionMode?: SessionMode;
	sessionKey?: string;
	startedAt?: string;
	status: SubagentDashboardStatus;
	task?: string;
	taskId: string;
	transcriptPath?: string;
	updatedAt: string;
	usage?: UsageStats;
	model?: string;
	effort?: string;
}

export interface SubagentDashboardState {
	collapsed: boolean;
	mode: DashboardDisplayMode;
	visible: boolean;
	lastVisibleMode?: DashboardDisplayMode;
	hiddenByUser?: boolean;
	autoShownThisSession?: boolean;
	items: Record<string, SubagentDashboardItem>;
}

export type ResultLimits = { maxBytes: number; maxLines: number };

export type PreparedSingleResult = {
	fullOutputError?: string;
	fullOutputPath?: string;
	result: SingleResult;
	text: string;
	truncation?: TruncationResult;
};

export interface BridgeMetadata {
	pid?: string;
	sessionFile?: string;
	socket?: string;
}

export interface QueuedPaneTask {
	pane: PaneRegistryEntry;
	taskId: string;
	outboxFile: string;
	taskFile: string;
	sessionMode: "live" | "resumed" | "new";
	duplicate?: boolean;
}

export interface TaskArtifactPaths {
	inboxFile: string;
	processingFile: string;
	doneFile: string;
	outboxFile: string;
	completionArchivePath?: string;
	transcriptPath?: string;
}

export interface GetSubagentResultDetails {
	agent?: string;
	paneId?: string;
	summary?: string;
	status?: PaneTaskStatus;
	taskId?: string;
	notes?: string;
	cwdSnapshot?: CwdSnapshot;
	diagnostics?: string[];
	completionMessageEmitted?: boolean;
	waitFor?: "completion" | "idle";
	waitTimedOut?: boolean;
}

export interface WaitForSubagentIdleDetails {
	agent: string;
	bridgePid?: string;
	bridgeSocket?: string;
	isIdle?: boolean;
	paneId?: string;
	runtimeRoot: string;
	samples: number;
	sessionFile?: string;
	status: "idle-after-busy" | "never-busy" | "timeout";
	timedOut: boolean;
	transitioned: boolean;
}

export interface SteerSubagentDetails {
	agent: string;
	bridge: boolean;
	bridgePid?: string;
	bridgeSocket?: string;
	deliverAs: string;
	fallbackFile?: string;
	outboxFile?: string;
	paneId: string;
	runtimeRoot: string;
	sessionFile: string;
	taskId?: string;
}

export interface TraceViewerItem {
	agent?: string;
	createdAt?: string;
	summary?: string;
	label: string;
	path?: string;
	ref?: string;
	status?: string;
	text: string;
	type?: "index" | "summary" | "completion";
}

export interface TraceViewerState {
	items: TraceViewerItem[];
	selected: number;
	scroll: number;
	title: string;
}
