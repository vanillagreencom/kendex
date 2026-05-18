/**
 * pi-flightdeck — read-only mission control for the flightdeck skill.
 *
 * Reads on-disk artifacts produced by skills/flightdeck/scripts/* — never
 * mutates them. Renders persistent dashboard, pause banner, and /flightdeck popup.
 *
 * Pi extension only — the underlying flightdeck skill works without this
 * extension via the same on-disk files.
 */

import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

import {
	type ConversationTurn,
	type FlightdeckSnapshot,
	type TrackedSession,
	ageSecondsSince,
	buildSnapshot,
	findTrackedEntry,
	flatDecisionsLog,
	flightdeckSessionStatus,
	daemonEverStarted,
	foldWakeEventsIntoConversations,
	formatAge,
	isPaneGone,
	mostRecentPollMs,
	readAwaitingWatchTrackedEntries,
	readOwnerVisibilityProbe,
	readTrackedEntries,
	resolveProjectRoot,
	type SettingsLike,
} from "./state.js";
import { dashboardVisibleForSnapshot, dashboardVisibleInPane, isInFlightdeckChildPane, normalizeDashboardVisibility, renderObserverHeader, type DashboardVisibility } from "./dashboard-visibility.js";
import {
	buildPaneTargetToIdMap,
	formatUsageCompact,
	getAgentsBridge,
	type AgentsBridgeItem,
} from "./agents-bridge.js";
import {
	ANSI_BELL,
	ansiGreen,
	ansiYellow,
	daemonHealthChip,
	divider,
	dotIndicator,
	formatShortcutHint,
	frameContentWidth,
	framePanel,
	framePopup,
	harnessChip,
	label,
	pad,
	panelBranch,
	searchRow,
	selectedRow,
	stateBadge,
	tagBadge,
	type TreeStyle,
	wrapLine,
} from "./render.js";
import { headerChipForSnapshot, renderArchiveErrorBanner, renderTerminatedConflictsSection, renderTerminatedOverviewBanner } from "./render-terminated.js";
import { formatOverviewHeader, formatOverviewRow, formatSessionTotals, formatStateBreakdown, hasIssueSessions, issueDomain, kindBadge, renderSessionDetailBlock, renderSessionDetailLines, renderSessionLine, sessionLabel, sessionPaneTargetLabel, sessionSearchText } from "./session-ui.js";
import { MINI_DASHBOARD_RANK, setMiniDashboardWidget } from "./stacked-widget.js";
const INSTALL_SYMBOL = Symbol.for("vstack.pi-flightdeck.installed");
const CONFIG_ID = "@vanillagreen/pi-flightdeck";
const SETTINGS_EVENT = "vstack:extension-settings-changed";
const VSTACK_MODAL_LOCK_SYMBOL = Symbol.for("vstack.pi.modal-lock");
const WIDGET_KEY = "vstack-flightdeck-widget";
const POPUP_WIDTH_PERCENT = "92%";
const POPUP_MAX_HEIGHT = "85%";
export type DashboardState = "hidden" | "compact" | "expanded";
interface VstackModalLock { depth: number }
function expandHome(input: string): string {
	if (!input) return input;
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

function userPiDir(): string {
	return resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
}

function projectPiSettingsPath(cwd: string): string {
	let current = resolve(cwd);
	while (true) {
		const candidate = join(current, ".pi", "settings.json");
		if (existsSync(candidate)) return candidate;
		if (existsSync(join(current, ".pi")) || existsSync(join(current, ".git")) || existsSync(join(current, ".vstack-lock.json"))) return candidate;
		const parent = dirname(current);
		if (parent === current) return join(resolve(cwd), ".pi", "settings.json");
		current = parent;
	}
}

function piSettingsPaths(cwd = process.cwd()): string[] {
	return [join(userPiDir(), "settings.json"), projectPiSettingsPath(cwd)];
}

type ConfigBag = Record<string, unknown>;

function readVstackConfig(cwd?: string): ConfigBag {
	const merged: ConfigBag = {};
	for (const path of piSettingsPaths(cwd)) {
		if (!existsSync(path)) continue;
		try {
			const parsed = JSON.parse(readFileSync(path, "utf8"));
			const config = parsed?.vstack?.extensionManager?.config?.[CONFIG_ID];
			if (config && typeof config === "object" && !Array.isArray(config)) Object.assign(merged, config);
		} catch {
			// Ignore malformed optional manager config.
		}
	}
	return merged;
}

function settingNumber(key: string, fallback: number, cwd?: string): number {
	const value = readVstackConfig(cwd)[key];
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
	return Number.isFinite(parsed) ? parsed : fallback;
}

function settingBoolean(key: string, fallback: boolean, cwd?: string): boolean {
	const value = readVstackConfig(cwd)[key];
	return typeof value === "boolean" ? value : fallback;
}

function settingString(key: string, fallback: string, cwd?: string): string {
	const value = readVstackConfig(cwd)[key];
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
}

function settingsLike(cwd?: string): SettingsLike {
	const stateDir = settingString("stateDir", "", cwd);
	const flightdeckStateDir = settingString("flightdeckStateDir", "tmp", cwd);
	return {
		flightdeckStateDir,
		stateDir: stateDir || undefined,
	};
}

function acquireVstackModalLock(): () => void {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[VSTACK_MODAL_LOCK_SYMBOL] as VstackModalLock | undefined;
	const lock = existing && typeof existing.depth === "number" ? existing : { depth: 0 };
	host[VSTACK_MODAL_LOCK_SYMBOL] = lock;
	lock.depth += 1;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		lock.depth = Math.max(0, lock.depth - 1);
	};
}

function compactPath(input: string): string {
	const home = homedir();
	if (input.startsWith(home)) return `~${input.slice(home.length)}`;
	return input;
}

function classifyDaemonLogLine(line: string): "info" | "warn" | "error" | "wake" | "classify" | "heartbeat" {
	if (/\] (wake|adapter-wake)/i.test(line)) return "wake";
	if (/\[heartbeat\]|\] heartbeat /i.test(line)) return "heartbeat";
	if (/\] (warn|error|fail|stale|gone)/i.test(line)) return "warn";
	if (/\] classify /i.test(line)) return "classify";
	return "info";
}

function selectedSoft(theme: Theme, selected: boolean, text: string): string {
	return theme.fg(selected ? "text" : "dim", text);
}

function colorizeDaemonLogLine(line: string, theme: Theme, selected = false): string {
	const kind = classifyDaemonLogLine(line);
	switch (kind) {
		case "wake": return theme.fg("success", line);
		case "warn": return theme.fg("warning", line);
		case "error": return theme.fg("error", line);
		case "classify": return theme.fg("accent", line);
		case "heartbeat": return selectedSoft(theme, selected, line);
		default: return theme.fg("text", line);
	}
}

interface DashboardCache {
	state: DashboardState;
	conversations: Map<string, ConversationTurn[]>;
	lastSnapshot?: FlightdeckSnapshot;
	pauseSeenIssue?: string;
	pauseSeenAt?: number;
	// Tmux `session:window.pane` → `%N` map, refreshed on each tick so session
	// rows can join against the pi-agents-tmux stats bridge.
	paneTargetToId: Map<string, string>;
	// Last applied syncWidget key. Each poller tick re-runs syncWidget, which
	// always triggers a TUI redraw. Skipping setWidget when this key is unchanged
	// stops the 1.5s polling cadence from re-diffing the entire screen and
	// triggering pi-tui's above-viewport flash whenever chat overflows.
	lastSyncKey?: string;
}

/**
 * Cap an aboveEditor widget's line count so it can never push chat / status above
 * the terminal viewport top, which is the trigger for pi-tui's full-screen redraw
 * (firstChanged < prevViewportTop). Reserves room for editor + footer + chat sliver.
 */
function clampAboveEditorWidget(lines: string[], terminalRows: number, theme: Theme): string[] {
	const reserveForOtherUi = 10;
	const maxLines = Math.max(4, terminalRows - reserveForOtherUi);
	if (lines.length <= maxLines) return lines;
	const hidden = lines.length - (maxLines - 1);
	return [...lines.slice(0, maxLines - 1), theme.fg("muted", `… ${hidden} more (open /flightdeck for full view)`)];
}

function usageForSession(session: TrackedSession, paneMap: Map<string, string>, bridge: ReturnType<typeof getAgentsBridge>): AgentsBridgeItem | undefined {
	if (!bridge) return undefined;
	// Prefer the registry-recorded pane_id (immutable for the life of the
	// pane). Fall back to resolving pane_target via tmux for legacy
	// registry entries that haven't been re-init'd since pane_id support.
	const paneId = session.pane_id || (session.pane_target ? paneMap.get(session.pane_target) : undefined);
	if (!paneId) return undefined;
	return bridge.getByPaneId(paneId);
}

function defaultDashboardState(cwd?: string): DashboardState { const value = settingString("dashboardDefaultState", "compact", cwd); return value === "hidden" || value === "expanded" ? value : "compact"; }

function dashboardVisibility(cwd?: string): DashboardVisibility { return normalizeDashboardVisibility(settingString("dashboardVisibility", "owner", cwd)); }

function pollIntervalMs(cwd?: string): number { return Math.max(500, Math.floor(settingNumber("pollIntervalMs", 1500, cwd))); }

// ============================================================================
// Widget render — pause banner + persistent dashboard
// ============================================================================

function renderPauseBannerLines(snapshot: FlightdeckSnapshot, theme: Theme, width: number): string[] {
	const paused = snapshot.master?.paused_for_user;
	if (!paused) return [];
	const issueId = paused.issue_id ?? "(unknown)";
	const session = findTrackedEntry(snapshot.master, paused.issue_id);
	const reason = paused.reason ?? "paused for user";
	const promptText = (paused.prompt_text ?? "").replace(/\s+/g, " ").trim();
	const inner = frameContentWidth(width) - 2;
	const titleLine = `${theme.fg("warning", "▲ FLIGHTDECK PAUSED")} ${theme.fg("muted", "for")} ${theme.fg("accent", session ? sessionLabel(session) : issueId)} ${theme.fg("dim", "—")} ${theme.fg("warning", reason)}`;
	const paneInfo = session?.pane_target ? `${theme.fg("muted", "pane")} ${theme.fg("text", session.pane_target)} ${theme.fg("dim", "·")} ${harnessChip(theme, session.harness ?? undefined)}` : "";
	const pr = issueDomain(session)?.pr_number;
	const prInfo = pr ? ` ${theme.fg("dim", "·")} ${theme.fg("muted", "PR")} ${theme.fg("accent", `#${pr}`)}` : "";
	const meta = paneInfo ? `${paneInfo}${prInfo}` : "";
	const promptWrap = promptText ? wrapLine(theme.fg("dim", promptText), inner).slice(0, 4) : [];
	const hint = theme.fg("dim", "Respond in chat to resume the master agent. ") + theme.fg("warning", `${settingString("popupShortcut", "f6")} `) + theme.fg("dim", "for full context.");
	const lines: string[] = [];
	lines.push(titleLine);
	if (meta) lines.push(meta);
	if (promptWrap.length > 0) {
		lines.push("");
		for (const row of promptWrap) lines.push(row);
	}
	lines.push("");
	lines.push(hint);
	return framePanel(lines, width, theme, "warning", " PAUSE — awaiting user ");
}

export function renderStaleHintLine(snapshot: FlightdeckSnapshot, theme: Theme, width: number): string[] {
	const latest = mostRecentPollMs(snapshot);
	const ageSec = latest === undefined ? undefined : Math.max(0, Math.floor((Date.now() - latest) / 1000));
	const ageText = ageSec === undefined ? "unknown age" : `${formatAge(ageSec)} ago`;
	const daemon = daemonHealthChip(theme, {
		alive: snapshot.daemon.pidAlive,
		everStarted: daemonEverStarted(snapshot),
		heartbeatAgeSec: snapshot.daemon.heartbeatAgeSec,
	});
	const line = `${daemon} ${theme.fg("dim", "·")} ${theme.fg("dim", `Flightdeck · session state from ${ageText} — daemon stopped. Resume with /skill:flightdeck session watch, or run terminate to archive.`)}`;
	return [truncateToWidth(line, Math.max(1, width), "…")];
}

// Awaiting-watch: tracked sessions exist but the daemon has never started
// for this tmux session. This is the normal state between `session start`
// and `session watch`. Friendly, non-alarming copy.
export function renderAwaitingWatchHintLine(snapshot: FlightdeckSnapshot, theme: Theme, width: number): string[] {
	const daemon = daemonHealthChip(theme, {
		alive: snapshot.daemon.pidAlive,
		everStarted: daemonEverStarted(snapshot),
		heartbeatAgeSec: snapshot.daemon.heartbeatAgeSec,
	});
	const sessions = readAwaitingWatchTrackedEntries(snapshot);
	const count = sessions.length;
	const noun = count === 1 ? "session" : "sessions";
	const line = `${daemon} ${theme.fg("dim", "·")} ${theme.fg("dim", `${count} tracked ${noun} — run /skill:flightdeck session watch to start supervising.`)}`;
	return [truncateToWidth(line, Math.max(1, width), "…")];
}

export function renderDashboardLines(snapshot: FlightdeckSnapshot, theme: Theme, width: number, state: DashboardState, cwd: string, paneMap: Map<string, string>): string[] {
	if (state === "hidden") return [];
	const sessions = readTrackedEntries(snapshot.master);
	const max = Math.max(1, Math.floor(settingNumber("dashboardMaxItems", 8, cwd)));
	const treeStyle = (settingString("treeStyle", "unicode", cwd) === "ascii" ? "ascii" : "unicode") as TreeStyle;
	const terminated = !!snapshot.master?.terminated;
	const headerRight = headerChipForSnapshot(snapshot, theme);
	const queueLen = snapshot.master?.merge_queue?.length ?? 0;
	const queueBadge = queueLen > 0 ? ` ${theme.fg("muted", "·")} ${theme.fg("accent", `merge-queue ${queueLen}`)}` : "";
	// Keyhints — same pattern as pi-agents-tmux dashboard header:
	// `<title> <stats> · alt+f toggle · f6 popup · <daemon-health>`. Both
	// shortcuts read from extension settings so user overrides are reflected.
	const toggleShortcut = settingString("dashboardShortcut", "alt+m", cwd);
	const popupShortcut = settingString("popupShortcut", "f6", cwd);
	const toggleHint = toggleShortcut === "none" ? "" : theme.fg("dim", ` · ${formatShortcutHint(toggleShortcut)} ${terminated ? "dismiss" : "toggle"}`);
	const popupHint = popupShortcut === "none" ? "" : theme.fg("dim", ` · ${formatShortcutHint(popupShortcut)} popup`);
	const hints = `${toggleHint}${popupHint}`;
	const summary = formatStateBreakdown(theme, sessions);
	const headerLeft = `${theme.fg("customMessageLabel", theme.bold("Flightdeck"))} ${formatSessionTotals(theme, sessions)}${summary ? ` ${theme.fg("muted", "·")} ${summary}` : ""}${queueBadge}${hints}`;
	const header = `${headerLeft}  ${theme.fg("dim", "·")}  ${headerRight}`;
	const bridge = getAgentsBridge();
	if (state === "compact") {
		const lines = [header];
		if (sessions.length === 0) {
			lines.push(`${panelBranch(theme, "└", treeStyle)}${theme.fg("muted", "No tracked sessions yet")}`);
			return framePanel(lines, width, theme);
		}
		const visible = sessions.slice(0, max);
		let anyGone = false;
		for (const [index, session] of visible.entries()) {
			const isLast = index === visible.length - 1 && sessions.length === visible.length;
			const stats = usageForSession(session, paneMap, bridge);
			const paneGone = isPaneGone(session, snapshot);
			if (paneGone) anyGone = true;
			lines.push(`${panelBranch(theme, isLast ? "└" : "├", treeStyle)}${renderSessionLine(session, theme, stats, paneGone)}`);
		}
		const hidden = Math.max(0, sessions.length - visible.length);
		if (hidden > 0) lines.push(`${panelBranch(theme, "└", treeStyle)}${theme.fg("muted", `… ${hidden} more`)}`);
		if (anyGone) {
			const pre = theme.fg("dim", "pane gone — open ");
			const shortcut = ansiYellow(formatShortcutHint(popupShortcut));
			const mid = theme.fg("dim", ", select the row, press ");
			const keyHint = `${ansiYellow("p")}${theme.fg("dim", "/")}${ansiYellow("del")}`;
			const post = theme.fg("dim", " to prune");
			lines.push(`${panelBranch(theme, "└", treeStyle)}${pre}${shortcut}${mid}${keyHint}${post}`);
		}
		return framePanel(lines, width, theme);
	}
	// expanded
	const lines = [header];
	if (sessions.length === 0) {
		lines.push(`${panelBranch(theme, "└", treeStyle)}${theme.fg("muted", "No tracked sessions yet")}`);
		return framePanel(lines, width, theme);
	}
	let anyGoneExpanded = false;
	for (const [index, session] of sessions.entries()) {
		const isLast = index === sessions.length - 1;
		const stats = usageForSession(session, paneMap, bridge);
		const paneGone = isPaneGone(session, snapshot);
		if (paneGone) anyGoneExpanded = true;
		lines.push(`${panelBranch(theme, isLast ? "└" : "├", treeStyle)}${renderSessionLine(session, theme, stats, paneGone)}`);
		const detailRows = renderSessionDetailLines(session, theme, stats);
		for (const [detailIndex, row] of detailRows.entries()) {
			lines.push(`${dashboardChildBranch(theme, treeStyle, isLast, detailIndex === detailRows.length - 1)}${row}`);
		}
	}
	if (anyGoneExpanded) {
		const pre = theme.fg("dim", "pane gone — open ");
		const shortcut = ansiYellow(formatShortcutHint(popupShortcut));
		const mid = theme.fg("dim", ", select the row, press ");
		const keyHint = `${ansiYellow("p")}${theme.fg("dim", "/")}${ansiYellow("del")}`;
		const post = theme.fg("dim", " to prune");
		lines.push(`${panelBranch(theme, "└", treeStyle)}${pre}${shortcut}${mid}${keyHint}${post}`);
	}
	return framePanel(lines, width, theme);
}

// Resolve the pane-registry script bundled with the flightdeck skill
// install. The dashboard ships separately, so it has to find the skill
// mirror under the project root.
function resolvePaneRegistryScript(cwd: string): string | undefined {
	const root = resolveProjectRoot(cwd);
	const candidate = join(root, ".agents/skills/flightdeck/scripts/pane-registry");
	return existsSync(candidate) ? candidate : undefined;
}

// Run `pane-registry remove <id>` from the popup `p` keybind. Returns
// `{ ok, stderr }` so the caller can notify on failure.
function pruneTrackedEntry(cwd: string, entryId: string): { ok: boolean; stderr: string } {
	const script = resolvePaneRegistryScript(cwd);
	if (!script) return { ok: false, stderr: "pane-registry script not found under .agents/skills/flightdeck/scripts/" };
	const r = spawnSync(script, ["remove", entryId], { encoding: "utf8", timeout: 5000 });
	if (r.status !== 0) return { ok: false, stderr: (r.stderr ?? "").trim() || `pane-registry remove exited ${r.status}` };
	return { ok: true, stderr: "" };
}

function dashboardChildBranch(theme: Theme, style: TreeStyle, parentLast: boolean, childLast: boolean): string {
	if (style === "ascii") {
		const parentStem = parentLast ? "    " : "|   ";
		return theme.fg("muted", `${parentStem}${childLast ? "`-- " : "|-- "}`);
	}
	const parentStem = parentLast ? "   " : "│  ";
	return theme.fg("muted", `${parentStem}${childLast ? "└─ " : "├─ "}`);
}

// ============================================================================
// Popup — six tabs
// ============================================================================

const TAB_OVERVIEW = "overview";
const TAB_LIVE = "live";
const TAB_CONVERSATIONS = "conversations";
const TAB_CONFLICTS = "conflicts";
const TAB_DECISIONS = "decisions";
const TAB_DAEMON = "daemon";

type Tab = typeof TAB_OVERVIEW | typeof TAB_LIVE | typeof TAB_CONVERSATIONS | typeof TAB_CONFLICTS | typeof TAB_DECISIONS | typeof TAB_DAEMON;

const TABS: Array<{ id: Tab; label: string }> = [
	{ id: TAB_OVERVIEW, label: "Overview" },
	{ id: TAB_LIVE, label: "Live feed" },
	{ id: TAB_CONVERSATIONS, label: "Conversations" },
	{ id: TAB_CONFLICTS, label: "Conflicts & merges" },
	{ id: TAB_DECISIONS, label: "Decisions" },
	{ id: TAB_DAEMON, label: "Daemon" },
];

function popupTabLabel(tab: { id: Tab; label: string }, snapshot?: FlightdeckSnapshot): string {
	if (tab.id === TAB_CONFLICTS && snapshot && !hasIssueSessions(readTrackedEntries(snapshot.master))) return "Conflicts & merges (issue mode)";
	return tab.label;
}

type DecisionEntry = ReturnType<typeof flatDecisionsLog>[number];

interface ConversationFeedItem {
	pane: string;
	session?: TrackedSession;
	turn: ConversationTurn;
	sessionLabel: string;
	sessionMeta: string[];
}

interface PopupUiState {
	tab: Tab;
	scroll: number;
	selected: number;
	search: string;
	showHelp: boolean;
	conversationDetail?: ConversationFeedItem;
	conversationDetailScroll: number;
	decisionDetail?: DecisionEntry;
	decisionDetailScroll: number;
	liveDetail?: LiveEvent;
	liveDetailScroll: number;
	liveShowNoisy: boolean;
}

export function makeInitialPopupState(): PopupUiState {
	return { conversationDetailScroll: 0, decisionDetailScroll: 0, liveDetailScroll: 0, liveShowNoisy: false, scroll: 0, search: "", selected: 0, showHelp: false, tab: TAB_OVERVIEW };
}
export type { PopupUiState };

function renderTabBar(active: Tab, width: number, theme: Theme, snapshot?: FlightdeckSnapshot): string {
	const cells = TABS.map((tab) => {
		const text = ` ${popupTabLabel(tab, snapshot)} `;
		if (tab.id === active) return theme.fg("accent", theme.inverse(theme.bold(text)));
		return theme.bg("selectedBg", theme.fg("accent", text));
	});
	return pad(cells.join(" "), width);
}

function isPlainSearchInput(data: string): boolean {
	return data.length === 1 && data >= " " && data !== "\x7f";
}

function activePopupCwd(ctx: ExtensionContext | ExtensionCommandContext): string {
	return (ctx as { cwd?: string }).cwd ?? process.cwd();
}

// ----- Tab renderers --------------------------------------------------------

export function renderOverviewTab(snapshot: FlightdeckSnapshot, ui: PopupUiState, width: number, theme: Theme, viewportRows: number, paneMap: Map<string, string>): string[] {
	const sessions = readTrackedEntries(snapshot.master);
	const filtered = ui.search.trim()
		? sessions.filter((session) => {
			const hay = sessionSearchText(session);
			return hay.includes(ui.search.trim().toLowerCase());
		})
		: sessions;
	clampSelection(ui, filtered.length, viewportRows);
	const lines: string[] = [];
	lines.push(searchRow(theme, ui.search, width));
	lines.push(...renderTerminatedOverviewBanner(snapshot, theme, width));
	lines.push("");
	if (filtered.length === 0) {
		if (sessions.length === 0) {
			lines.push(`${theme.fg("dim", "No sessions tracked yet. Run ")}${ansiGreen("'/skill:flightdeck session start'")}${theme.fg("dim", " to spawn.")}`);
		} else {
			lines.push(theme.fg("dim", "No matches for current search."));
		}
		return lines;
	}
	const bridge = getAgentsBridge();
	const statsBySession = new Map<string, AgentsBridgeItem | undefined>();
	for (const session of filtered) statsBySession.set(session.id, usageForSession(session, paneMap, bridge));
	const hasStats = Array.from(statsBySession.values()).some((stat) => Boolean(stat?.usage));
	const hasPr = filtered.some((session) => Boolean(issueDomain(session)?.pr_number));
	const hdr = formatOverviewHeader(theme, width, hasStats, hasPr);
	lines.push(hdr);
	lines.push(divider(width, theme));
	const rows = Math.max(1, viewportRows - lines.length - 2);
	const tail = Math.max(0, filtered.length - (ui.scroll + rows));
	if (ui.scroll > 0) lines.push(theme.fg("dim", `↑ ${ui.scroll} earlier`));
	let anyGone = false;
	for (const [vi, session] of filtered.slice(ui.scroll, ui.scroll + rows).entries()) {
		const idx = ui.scroll + vi;
		const selected = idx === ui.selected;
		const statsText = formatUsageCompact(statsBySession.get(session.id)?.usage);
		const paneGone = isPaneGone(session, snapshot);
		if (paneGone) anyGone = true;
		const row = formatOverviewRow(session, theme, width, statsText, hasStats, hasPr, selected, paneGone);
		lines.push(selected ? selectedRow(theme, row, width) : row);
	}
	if (tail > 0) lines.push(theme.fg("dim", `↓ ${tail} more`));
	const session = filtered[ui.selected];
	if (session) {
		lines.push("");
		lines.push(divider(width, theme));
		lines.push(...renderSessionDetailBlock(session, theme, width, statsBySession.get(session.id)));
	}
	return lines;
}

interface LiveEvent {
	ts: string;          // HH:MM:SS short form, for display
	isoTs: string;       // full ISO timestamp, for sorting
	kind: "daemon" | "decision" | "event-pending" | "event-wake" | "heartbeat-fold";
	line: string;
	sessionLabel: string;
	count?: number;
}

function buildLiveFeedEvents(snapshot: FlightdeckSnapshot, cwd: string): LiveEvent[] {
	const max = Math.max(20, Math.floor(settingNumber("liveFeedLines", 200, cwd)));
	const sessionByPane = sessionByConversationPane(snapshot);
	const raw: LiveEvent[] = [];
	for (const line of (snapshot.daemon.logTail ?? []).slice(-max)) {
		const isoTs = line.match(/^[^ ]+/)?.[0] ?? "";
		raw.push({ kind: "daemon", line, sessionLabel: daemonLineSessionLabel(line, sessionByPane), ts: isoTs.slice(11, 19), isoTs });
	}
	const decisions = flatDecisionsLog(snapshot.master, max);
	for (const d of decisions) {
		raw.push({ kind: "decision", line: `${d.ts} [decision] ${d.session} ${d.prompt_tag} → ${d.answer}`, sessionLabel: d.session, ts: d.ts.slice(11, 19), isoTs: d.ts });
	}
	for (const ev of snapshot.pendingEvents.slice(-max)) {
		const isoTs = ev.ts ?? "";
		raw.push({ kind: "event-pending", line: `${isoTs} [pending] session=${sessionLabelForPane(ev.pane_id, sessionByPane)} tag=${ev.tag ?? "?"} reason=${ev.reason ?? "?"} age=${ev.stable_age_sec ?? 0}s`, sessionLabel: sessionLabelForPane(ev.pane_id, sessionByPane), ts: isoTs.slice(11, 19), isoTs });
	}
	for (const ev of snapshot.wakeEvents.slice(-max)) {
		const tag = ev.classifier_tag ?? "?";
		const text = (ev.last_assistant_text ?? "").slice(0, 80).replace(/\s+/g, " ");
		const extra = ev.event_type === "question" && typeof ev.question === "object"
			? ` request_id=${ev.request_id ?? "?"}`
			: ev.event_type === "subagent-completion" ? " subagent-completion" : "";
		const isoTs = ev.ts ?? "";
		const sessionLabel = sessionLabelForPane(ev.pane_id, sessionByPane);
		raw.push({ kind: "event-wake", line: `${isoTs} [adapter:${ev.harness ?? "?"}] session=${sessionLabel} tag=${tag}${extra}${text ? ` :: ${text}` : ""}`, sessionLabel, ts: isoTs.slice(11, 19), isoTs });
	}
	// Chronological order — the prior `localeCompare(line)` sort mixed daemon
	// timestamps with adapter timestamps and obscured causality.
	raw.sort((a, b) => a.isoTs.localeCompare(b.isoTs));
	return foldHeartbeats(raw);
}

function filterLiveFeedEvents(events: LiveEvent[], ui: PopupUiState): LiveEvent[] {
	const query = ui.search.trim().toLowerCase();
	const base = ui.liveShowNoisy ? events : events.filter((event) => !isNoisyLiveEvent(event));
	return query ? base.filter((event) => liveEventSearchText(event).includes(query)) : base;
}

function selectedLiveEvent(snapshot: FlightdeckSnapshot, ui: PopupUiState, cwd: string): LiveEvent | undefined {
	const filtered = filterLiveFeedEvents(buildLiveFeedEvents(snapshot, cwd), ui);
	if (filtered.length === 0) return undefined;
	ui.selected = Math.max(0, Math.min(ui.selected, filtered.length - 1));
	return filtered[ui.selected];
}

function liveEventSearchText(ev: LiveEvent): string {
	return `${ev.ts} ${ev.sessionLabel} ${ev.kind} ${liveEventKindText(ev)} ${ev.line}`.toLowerCase();
}

function sessionLabelForPane(paneId: string | undefined, sessionByPane: Map<string, TrackedSession>): string {
	if (paneId) {
		const session = sessionByPane.get(paneId);
		if (session) return sessionLabel(session);
	}
	return "unmapped session";
}

function parseDaemonLinePaneId(line: string): string | undefined {
	return line.match(/\bpane=(%\d+)/)?.[1]
		?? line.match(/\badapter:(%\d+):/)?.[1]
		?? line.match(/\binner_ids=(%\d+)/)?.[1]
		?? line.match(/\[(?:classify|wake)\]\s+(%\d+)\b/)?.[1];
}

function daemonLineSessionLabel(line: string, sessionByPane: Map<string, TrackedSession>): string {
	const paneId = parseDaemonLinePaneId(line);
	if (paneId) {
		const session = sessionByPane.get(paneId);
		if (session) return sessionLabel(session);
	}
	const name = line.match(/\bname=([^\s]+)/)?.[1];
	return name || "daemon";
}

function isImportantDaemonInfo(line: string): boolean {
	return /\[(?:start|spawn|pi-subscriber-spawn|oc-subscriber-spawn|cc-subscriber-spawn|cx-subscriber-spawn|submit|merge|pr|ci|question|done|finish|completed|failed|error|warn)\]/i.test(line);
}

function isNoisyLiveEvent(ev: LiveEvent): boolean {
	if (ev.kind === "heartbeat-fold") return true;
	if (ev.kind !== "daemon") return false;
	const kind = classifyDaemonLogLine(ev.line);
	if (kind === "heartbeat") return true;
	return kind === "info" && !isImportantDaemonInfo(ev.line);
}

function liveEventKindText(ev: LiveEvent): string {
	switch (ev.kind) {
		case "daemon": return classifyDaemonLogLine(ev.line);
		case "decision": return "decision";
		case "event-pending": return "pending";
		case "event-wake": return "wake";
		case "heartbeat-fold": return "heartbeat";
	}
}

function liveEventKindChip(ev: LiveEvent, theme: Theme, selected = false): string {
	const text = liveEventKindText(ev);
	switch (ev.kind) {
		case "decision": return theme.fg("accent", text);
		case "event-wake": return theme.fg("success", text);
		case "event-pending": return theme.fg("warning", text);
		case "heartbeat-fold": return selectedSoft(theme, selected, text);
		case "daemon": {
			const kind = classifyDaemonLogLine(ev.line);
			if (kind === "warn") return theme.fg("warning", kind);
			if (kind === "error") return theme.fg("error", kind);
			if (kind === "wake") return theme.fg("success", kind);
			if (kind === "classify") return theme.fg("accent", kind);
			return selectedSoft(theme, selected, kind);
		}
	}
}

function liveEventSummary(ev: LiveEvent): string {
	if (ev.kind === "heartbeat-fold") return ev.line;
	return ev.line
		.replace(/^\S+\s+\[decision\]\s+/, "")
		.replace(/^\S+\s+\[adapter:([^\]]+)\]\s+/, "adapter:$1 ")
		.replace(/^\S+\s+/, "");
}

function renderLiveEventRow(ev: LiveEvent, theme: Theme, width: number, selected = false): string {
	const time = pad(selectedSoft(theme, selected, ev.ts || "--:--:--"), 10);
	const session = pad(theme.fg(ev.sessionLabel === "daemon" ? (selected ? "text" : "muted") : "customMessageLabel", ev.sessionLabel), 18);
	const kind = pad(liveEventKindChip(ev, theme, selected), 12);
	const summary = ev.kind === "heartbeat-fold" ? selectedSoft(theme, selected, liveEventSummary(ev)) : theme.fg("text", liveEventSummary(ev));
	return truncateToWidth(`${time} ${session} ${kind} ${summary}`, width, "");
}

function renderLiveEventInlineDetail(ev: LiveEvent, theme: Theme, width: number, maxRows: number): string[] {
	const budget = Math.max(2, maxRows);
	const header = `${label(theme, "selected:")} ${theme.fg("customMessageLabel", theme.bold(ev.sessionLabel))} ${theme.fg("dim", "·")} ${liveEventKindChip(ev, theme)} ${theme.fg("dim", "·")} ${theme.fg("text", ev.ts || ev.isoTs || "--:--:--")}`;
	const wrapped = wrapLine(ev.line, width).map((row) => theme.fg("text", row));
	const bodyBudget = Math.max(1, budget - 1);
	const out = [truncateToWidth(header, width, "")];
	if (wrapped.length <= bodyBudget) {
		out.push(...wrapped);
		return out;
	}
	out.push(...wrapped.slice(0, Math.max(1, bodyBudget - 1)));
	out.push(theme.fg("dim", `↓ ${wrapped.length - out.length + 1} more wrapped line(s) · press enter for full event`));
	return out;
}

function renderLiveEventDetailView(ev: LiveEvent, ui: PopupUiState, width: number, theme: Theme, innerRows: number): string[] {
	const header = [
		`${theme.fg("customMessageLabel", theme.bold(ev.sessionLabel))} ${theme.fg("dim", "·")} ${liveEventKindChip(ev, theme)}`,
		`${label(theme, "time:")} ${theme.fg("text", ev.isoTs || ev.ts || "—")} ${theme.fg("dim", "·")} ${label(theme, "raw chars:")} ${theme.fg("text", String(ev.line.length))}`,
		divider(width, theme),
		label(theme, "raw event"),
	];
	const footerRows = 2;
	const eventRows = wrapLine(ev.line, width).map((row) => theme.fg("text", row));
	const windowRows = Math.max(1, innerRows - header.length - footerRows);
	const maxScroll = Math.max(0, eventRows.length - windowRows);
	ui.liveDetailScroll = Math.max(0, Math.min(ui.liveDetailScroll, maxScroll));
	const start = ui.liveDetailScroll;
	const end = Math.min(eventRows.length, start + windowRows);
	const lines = [...header, ...eventRows.slice(start, end)];
	while (lines.length < innerRows - footerRows) lines.push("");
	const lineInfo = eventRows.length > windowRows ? `${start + 1}-${end}/${eventRows.length}` : `${eventRows.length}/${eventRows.length}`;
	const footer = `${ansiYellow("↑/↓")} ${theme.fg("dim", "scroll · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("home/end")} ${theme.fg("dim", "ends · ")}${ansiYellow("esc/backspace")} ${theme.fg("dim", "back · ")}${theme.fg("dim", `lines ${lineInfo}`)}`;
	lines.push(divider(width, theme));
	lines.push(truncateToWidth(footer, width, ""));
	return lines.slice(0, innerRows);
}

function renderLiveFeedTab(snapshot: FlightdeckSnapshot, ui: PopupUiState, width: number, theme: Theme, viewportRows: number, cwd: string): string[] {
	const events = buildLiveFeedEvents(snapshot, cwd);
	const filtered = filterLiveFeedEvents(events, ui);
	const noisyHidden = ui.liveShowNoisy ? 0 : events.filter((event) => isNoisyLiveEvent(event)).length;
	const lines: string[] = [];
	lines.push(searchRow(theme, ui.search, width));
	lines.push(`${label(theme, "filter:")} ${ui.liveShowNoisy ? theme.fg("text", "all events") : theme.fg("accent", "important")} ${noisyHidden > 0 ? theme.fg("dim", `· ${noisyHidden} noisy hidden · ctrl+n show all`) : theme.fg("dim", "· ctrl+n toggle noise")}`);
	if (filtered.length === 0) {
		lines.push("");
		lines.push(theme.fg("dim", events.length === 0 ? "No live events. Daemon may be quiet or not running." : "No live events match current search."));
		return lines;
	}
	const detailRows = Math.min(7, Math.max(4, Math.floor(viewportRows * 0.32)));
	const rows = Math.max(3, viewportRows - lines.length - detailRows - 3);
	clampSelection(ui, filtered.length, rows);
	const start = Math.max(0, Math.min(ui.scroll, Math.max(0, filtered.length - rows)));
	const end = Math.min(filtered.length, start + rows);
	if (start > 0) lines.push(theme.fg("dim", `↑ ${start} earlier`));
	for (const [vi, ev] of filtered.slice(start, end).entries()) {
		const idx = start + vi;
		const selected = idx === ui.selected;
		const rowText = renderLiveEventRow(ev, theme, width, selected);
		lines.push(selected ? selectedRow(theme, rowText, width) : rowText);
	}
	const tail = Math.max(0, filtered.length - end);
	if (tail > 0) lines.push(theme.fg("dim", `↓ ${tail} more`));
	const selected = filtered[ui.selected];
	if (selected) {
		lines.push("");
		lines.push(divider(width, theme));
		lines.push(...renderLiveEventInlineDetail(selected, theme, width, detailRows));
	}
	return lines;
}

function colorizeLiveEvent(ev: LiveEvent, theme: Theme, selected = false): string {
	switch (ev.kind) {
		case "daemon": return colorizeDaemonLogLine(ev.line, theme, selected);
		case "decision": return theme.fg("accent", ev.line);
		case "event-wake": return theme.fg("text", ev.line);
		case "event-pending": return theme.fg("warning", ev.line);
		case "heartbeat-fold": return selectedSoft(theme, selected, ev.line);
	}
}

// Consecutive `[heartbeat]` daemon lines fold into one summary row so the
// feed surfaces real activity. Non-heartbeat lines split the run.
function foldHeartbeats(events: LiveEvent[]): LiveEvent[] {
	const out: LiveEvent[] = [];
	let runStart: LiveEvent | undefined;
	let runEnd: LiveEvent | undefined;
	let runCount = 0;
	const flush = () => {
		if (!runStart || runCount === 0) return;
		if (runCount === 1) {
			out.push(runStart);
		} else {
			const endTs = runEnd?.ts ?? runStart.ts;
			out.push({
				kind: "heartbeat-fold",
				ts: endTs,
				isoTs: runEnd?.isoTs ?? runStart.isoTs,
				line: `${runStart.ts}→${endTs}  ×${runCount} heartbeats (daemon alive)`,
				sessionLabel: runStart.sessionLabel,
				count: runCount,
			});
		}
		runStart = undefined;
		runEnd = undefined;
		runCount = 0;
	};
	for (const ev of events) {
		const isHeartbeat = ev.kind === "daemon" && /\[heartbeat\]/.test(ev.line);
		if (isHeartbeat) {
			if (!runStart) runStart = ev;
			runEnd = ev;
			runCount += 1;
			continue;
		}
		flush();
		out.push(ev);
	}
	flush();
	return out;
}

function daemonLogEvents(lines: string[]): LiveEvent[] {
	return lines.map((line) => {
		const isoTs = line.match(/^[^ ]+/)?.[0] ?? "";
		return { kind: "daemon", line, sessionLabel: "daemon", ts: isoTs.slice(11, 19), isoTs };
	});
}

function foldedDaemonLogEvents(lines: string[]): LiveEvent[] {
	return foldHeartbeats(daemonLogEvents(lines));
}

function formatConversationTime(ts: string): string {
	const match = ts.match(/\d\d:\d\d:\d\d/)?.[0];
	const fallback = ts.slice(11, 19);
	return match ?? (fallback || "--:--:--");
}

function sessionByConversationPane(snapshot: FlightdeckSnapshot): Map<string, TrackedSession> {
	const sessionByPane = new Map<string, TrackedSession>();
	for (const session of readTrackedEntries(snapshot.master)) {
		if (session.pane_id) sessionByPane.set(session.pane_id, session);
		if (session.pane_target) sessionByPane.set(session.pane_target, session);
	}
	return sessionByPane;
}

function conversationSessionLabel(pane: string, session: TrackedSession | undefined): string {
	if (session) return sessionLabel(session);
	const suffix = pane.replace(/^%/, "#").trim();
	return suffix ? `unmapped ${suffix}` : "unmapped session";
}

function conversationSessionMeta(session: TrackedSession | undefined, turn: ConversationTurn): string[] {
	const meta: string[] = [];
	if (session?.kind) meta.push(session.kind);
	if (session?.state) meta.push(session.state);
	if (turn.harness || session?.harness) meta.push(turn.harness ?? session?.harness ?? "");
	if (turn.tag) meta.push(turn.tag);
	const target = sessionPaneTargetLabel(session);
	if (target) meta.push(target);
	return meta.filter(Boolean);
}

function buildConversationFeed(snapshot: FlightdeckSnapshot, conversations: Map<string, ConversationTurn[]>): ConversationFeedItem[] {
	const sessionByPane = sessionByConversationPane(snapshot);
	const items: ConversationFeedItem[] = [];
	for (const [pane, turns] of conversations) {
		const session = sessionByPane.get(pane);
		for (const turn of turns) {
			items.push({
				pane,
				session,
				sessionLabel: conversationSessionLabel(pane, session),
				sessionMeta: conversationSessionMeta(session, turn),
				turn,
			});
		}
	}
	items.sort((a, b) => b.turn.ts.localeCompare(a.turn.ts) || a.sessionLabel.localeCompare(b.sessionLabel));
	return items;
}

function filterConversationFeed(items: ConversationFeedItem[], ui: PopupUiState): ConversationFeedItem[] {
	const query = ui.search.trim().toLowerCase();
	if (!query) return items;
	return items.filter((item) => `${item.pane} ${item.sessionLabel} ${item.sessionMeta.join(" ")} ${item.turn.harness ?? ""} ${item.turn.tag ?? ""} ${item.turn.excerpt}`.toLowerCase().includes(query));
}

function selectedConversationItem(snapshot: FlightdeckSnapshot, conversations: Map<string, ConversationTurn[]>, ui: PopupUiState): ConversationFeedItem | undefined {
	const filtered = filterConversationFeed(buildConversationFeed(snapshot, conversations), ui);
	if (filtered.length === 0) return undefined;
	ui.selected = Math.max(0, Math.min(ui.selected, filtered.length - 1));
	return filtered[ui.selected];
}

function renderConversationRow(item: ConversationFeedItem, theme: Theme, width: number, selected = false): string {
	const time = pad(selectedSoft(theme, selected, formatConversationTime(item.turn.ts)), 10);
	const session = pad(theme.fg("customMessageLabel", item.sessionLabel), 18);
	const harness = pad(harnessChip(theme, item.turn.harness ?? item.session?.harness ?? undefined), 8);
	const tag = pad(conversationTagChip(theme, item.turn.tag, selected), 24);
	const preview = theme.fg("text", item.turn.excerpt.replace(/\s+/g, " "));
	return truncateToWidth(`${time} ${session} ${harness} ${tag} ${preview}`, width, "");
}

function conversationTagChip(theme: Theme, tag: string | undefined, selected = false): string {
	if (selected && (!tag || tag === "idle" || tag === "rendering")) return theme.fg("text", tag ?? "—");
	return tagBadge(theme, tag);
}

function renderConversationInlineDetail(item: ConversationFeedItem, theme: Theme, width: number, maxRows: number): string[] {
	const target = sessionPaneTargetLabel(item.session);
	const meta = [
		kindBadge(theme, item.session),
		stateBadge(theme, item.session?.state),
		harnessChip(theme, item.turn.harness ?? item.session?.harness ?? undefined),
		tagBadge(theme, item.turn.tag),
		selectedSoft(theme, false, formatConversationTime(item.turn.ts)),
		target ? selectedSoft(theme, false, target) : "",
	].filter(Boolean);
	const header = `${label(theme, "selected:")} ${theme.fg("customMessageLabel", theme.bold(item.sessionLabel))} ${theme.fg("dim", "·")} ${meta.join(theme.fg("dim", " · "))}`;
	const budget = Math.max(2, maxRows);
	const wrapped = wrapLine(item.turn.excerpt, width).map((row) => theme.fg("text", row));
	const bodyBudget = Math.max(1, budget - 1);
	const out = [truncateToWidth(header, width, "")];
	if (wrapped.length <= bodyBudget) {
		out.push(...wrapped);
		return out;
	}
	out.push(...wrapped.slice(0, Math.max(1, bodyBudget - 1)));
	out.push(theme.fg("dim", `↓ ${wrapped.length - out.length + 1} more wrapped line(s) · press enter for full turn`));
	return out;
}

function renderConversationDetailView(item: ConversationFeedItem, ui: PopupUiState, width: number, theme: Theme, innerRows: number): string[] {
	const target = sessionPaneTargetLabel(item.session);
	const header = [
		`${theme.fg("customMessageLabel", theme.bold(item.sessionLabel))} ${theme.fg("dim", "·")} ${kindBadge(theme, item.session)} ${theme.fg("dim", "·")} ${stateBadge(theme, item.session?.state)} ${theme.fg("dim", "·")} ${harnessChip(theme, item.turn.harness ?? item.session?.harness ?? undefined)} ${theme.fg("dim", "·")} ${tagBadge(theme, item.turn.tag)}`,
		`${label(theme, "time:")} ${theme.fg("text", item.turn.ts)}${target ? ` ${theme.fg("dim", "·")} ${label(theme, "tmux:")} ${theme.fg("text", target)}` : ""} ${theme.fg("dim", "·")} ${label(theme, "chars:")} ${theme.fg("text", String(item.turn.excerpt.length))}`,
		divider(width, theme),
		label(theme, "assistant turn"),
	];
	const footerRows = 2;
	const rows = wrapLine(item.turn.excerpt, width).map((row) => theme.fg("text", row));
	const windowRows = Math.max(1, innerRows - header.length - footerRows);
	const maxScroll = Math.max(0, rows.length - windowRows);
	ui.conversationDetailScroll = Math.max(0, Math.min(ui.conversationDetailScroll, maxScroll));
	const start = ui.conversationDetailScroll;
	const end = Math.min(rows.length, start + windowRows);
	const lines = [...header, ...rows.slice(start, end)];
	while (lines.length < innerRows - footerRows) lines.push("");
	const lineInfo = rows.length > windowRows ? `${start + 1}-${end}/${rows.length}` : `${rows.length}/${rows.length}`;
	const footer = `${ansiYellow("↑/↓")} ${theme.fg("dim", "scroll · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("home/end")} ${theme.fg("dim", "ends · ")}${ansiYellow("esc/backspace")} ${theme.fg("dim", "back · ")}${theme.fg("dim", `lines ${lineInfo}`)}`;
	lines.push(divider(width, theme));
	lines.push(truncateToWidth(footer, width, ""));
	return lines.slice(0, innerRows);
}

function renderConversationsTab(snapshot: FlightdeckSnapshot, conversations: Map<string, ConversationTurn[]>, ui: PopupUiState, width: number, theme: Theme, viewportRows: number, _cwd: string): string[] {
	const lines: string[] = [];
	lines.push(searchRow(theme, ui.search, width));
	lines.push("");
	if (conversations.size === 0) {
		lines.push(theme.fg("dim", "No assistant turns captured yet."));
		lines.push("");
		lines.push(theme.fg("dim", "Conversations are populated from adapter wake events as inner panes finish turns."));
		lines.push(theme.fg("dim", "Events get drained on each master turn boundary, so this is a rolling buffer."));
		return lines;
	}
	const items = buildConversationFeed(snapshot, conversations);
	const filtered = filterConversationFeed(items, ui);
	if (filtered.length === 0) {
		lines.push(theme.fg("dim", "No conversations match current search."));
		return lines;
	}
	const detailRows = Math.min(7, Math.max(4, Math.floor(viewportRows * 0.32)));
	const rows = Math.max(3, viewportRows - lines.length - detailRows - 3);
	clampSelection(ui, filtered.length, rows);
	const start = Math.max(0, Math.min(ui.scroll, Math.max(0, filtered.length - rows)));
	const end = Math.min(filtered.length, start + rows);
	if (start > 0) lines.push(theme.fg("dim", `↑ ${start} earlier`));
	for (const [vi, item] of filtered.slice(start, end).entries()) {
		const idx = start + vi;
		const selected = idx === ui.selected;
		const row = renderConversationRow(item, theme, width, selected);
		lines.push(selected ? selectedRow(theme, row, width) : row);
	}
	const tail = Math.max(0, filtered.length - end);
	if (tail > 0) lines.push(theme.fg("dim", `↓ ${tail} more`));
	const selected = filtered[ui.selected];
	if (selected) {
		lines.push("");
		lines.push(divider(width, theme));
		lines.push(...renderConversationInlineDetail(selected, theme, width, detailRows));
	}
	return lines;
}

export function renderConflictsTab(snapshot: FlightdeckSnapshot, _ui: PopupUiState, width: number, theme: Theme): string[] {
	const lines: string[] = [];
	const queue = snapshot.master?.merge_queue ?? [];
	const edges = snapshot.master?.conflict_graph?.edges ?? [];
	const computed = snapshot.master?.conflict_graph?.computed_at;
	const sessions = readTrackedEntries(snapshot.master);
	if (!hasIssueSessions(sessions)) {
		lines.push(theme.fg("warning", "Conflicts & merges (issue mode)"));
		lines.push(theme.fg("dim", "No issue-mode sessions are tracked. Ad-hoc and workflow sessions skip PR merge queues and file-overlap conflict graphs."));
		return lines.flatMap((line) => wrapLine(line, width));
	}
	lines.push(`${theme.fg("customMessageLabel", theme.bold("Merge queue"))} ${theme.fg("dim", `(${queue.length})`)}`);
	if (queue.length === 0) lines.push(theme.fg("dim", "  (empty)"));
	else for (const [i, id] of queue.entries()) {
		const session = findTrackedEntry(snapshot.master, id);
		const state = stateBadge(theme, session?.state);
		const pr = issueDomain(session)?.pr_number ? ` ${theme.fg("dim", "·")} ${theme.fg("accent", `PR#${issueDomain(session)?.pr_number}`)}` : "";
		lines.push(`  ${theme.fg("muted", `${i + 1}.`)} ${theme.bold(theme.fg("text", id))} ${theme.fg("dim", "·")} ${state}${pr}`);
	}
	lines.push(...renderTerminatedConflictsSection(snapshot, theme));
	lines.push(`${theme.fg("customMessageLabel", theme.bold("Conflict graph"))} ${theme.fg("dim", `(${edges.length} edge${edges.length === 1 ? "" : "s"}${computed ? `, ${formatAge(ageSecondsSince(computed))} ago` : ""})`)}`);
	if (edges.length === 0) lines.push(theme.fg("dim", "  (no detected file overlap)"));
	else for (const [a, b] of edges) {
		const aIssue = findTrackedEntry(snapshot.master, a);
		const bIssue = findTrackedEntry(snapshot.master, b);
		const ap = issueDomain(aIssue)?.pr_number ? `#${issueDomain(aIssue)?.pr_number}` : "";
		const bp = issueDomain(bIssue)?.pr_number ? `#${issueDomain(bIssue)?.pr_number}` : "";
		lines.push(`  ${theme.fg("text", a)}${ap ? theme.fg("dim", ` ${ap}`) : ""} ${theme.fg("warning", "↔")} ${theme.fg("text", b)}${bp ? theme.fg("dim", ` ${bp}`) : ""}`);
	}
	return lines.flatMap((line) => wrapLine(line, width));
}

function filteredDecisions(snapshot: FlightdeckSnapshot, ui: PopupUiState, cwd: string): DecisionEntry[] {
	const max = Math.max(50, Math.floor(settingNumber("liveFeedLines", 200, cwd)));
	const decisions = flatDecisionsLog(snapshot.master, max);
	if (!ui.search.trim()) return decisions;
	const query = ui.search.trim().toLowerCase();
	return decisions.filter((d) => `${d.session} ${d.prompt_tag} ${d.answer}`.toLowerCase().includes(query));
}

function selectedDecision(snapshot: FlightdeckSnapshot, ui: PopupUiState, cwd: string): DecisionEntry | undefined {
	const decisions = filteredDecisions(snapshot, ui, cwd);
	if (decisions.length === 0) return undefined;
	ui.selected = Math.max(0, Math.min(ui.selected, decisions.length - 1));
	return decisions[ui.selected];
}

export function renderDecisionsTab(snapshot: FlightdeckSnapshot, ui: PopupUiState, width: number, theme: Theme, viewportRows: number, cwd: string): string[] {
	const all = flatDecisionsLog(snapshot.master, Math.max(50, Math.floor(settingNumber("liveFeedLines", 200, cwd))));
	const filtered = filteredDecisions(snapshot, ui, cwd);
	const lines: string[] = [];
	lines.push(searchRow(theme, ui.search, width));
	lines.push("");
	if (filtered.length === 0) {
		lines.push(theme.fg("dim", all.length === 0 ? "No decisions logged yet." : "No matches for current search."));
		return lines;
	}
	lines.push(`${pad(label(theme, "TIME"), 10)} ${pad(label(theme, "SESSION"), 16)} ${pad(label(theme, "PROMPT TAG"), 26)} ${label(theme, "ANSWER")}`);
	lines.push(divider(width, theme));
	const rows = Math.max(1, viewportRows - lines.length - 2);
	clampSelection(ui, filtered.length, rows);
	const start = Math.max(0, Math.min(ui.scroll, Math.max(0, filtered.length - rows)));
	const end = Math.min(filtered.length, start + rows);
	if (start > 0) lines.push(theme.fg("dim", `↑ ${start} earlier`));
	for (const [vi, d] of filtered.slice(start, end).entries()) {
		const idx = start + vi;
		const selected = idx === ui.selected;
		const time = pad(selectedSoft(theme, selected, d.ts.slice(11, 19)), 10);
		const session = pad(theme.fg("text", d.session), 16);
		const tag = pad(tagBadge(theme, d.prompt_tag), 26);
		const answer = theme.fg("text", d.answer);
		const row = truncateToWidth(`${time} ${session} ${tag} ${answer}`, width, "");
		lines.push(selected ? selectedRow(theme, row, width) : row);
	}
	const tail = Math.max(0, filtered.length - end);
	if (tail > 0) lines.push(theme.fg("dim", `↓ ${tail} more`));
	return lines;
}

function wrapDecisionAnswer(answer: string, width: number, theme: Theme): string[] {
	const rows = wrapLine(answer || "(empty answer)", width);
	return rows.map((row) => theme.fg(row ? "text" : "dim", row));
}

function renderDecisionDetailView(decision: DecisionEntry, ui: PopupUiState, width: number, theme: Theme, innerRows: number): string[] {
	const header = [
		`${theme.fg("customMessageLabel", theme.bold(decision.session))} ${theme.fg("dim", "·")} ${tagBadge(theme, decision.prompt_tag)}`,
		`${label(theme, "time:")} ${theme.fg("text", decision.ts)} ${theme.fg("dim", "·")} ${label(theme, "answer chars:")} ${theme.fg("text", String(decision.answer.length))}`,
		divider(width, theme),
		label(theme, "answer"),
	];
	const footerRows = 2;
	const answerRows = wrapDecisionAnswer(decision.answer, width, theme);
	const answerWindowRows = Math.max(1, innerRows - header.length - footerRows);
	const maxScroll = Math.max(0, answerRows.length - answerWindowRows);
	ui.decisionDetailScroll = Math.max(0, Math.min(ui.decisionDetailScroll, maxScroll));
	const start = ui.decisionDetailScroll;
	const end = Math.min(answerRows.length, start + answerWindowRows);
	const lines = [...header, ...answerRows.slice(start, end)];
	while (lines.length < innerRows - footerRows) lines.push("");
	const lineInfo = answerRows.length > answerWindowRows
		? `${start + 1}-${end}/${answerRows.length}`
		: `${answerRows.length}/${answerRows.length}`;
	const footer = `${ansiYellow("↑/↓")} ${theme.fg("dim", "scroll · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("home/end")} ${theme.fg("dim", "ends · ")}${ansiYellow("esc/backspace")} ${theme.fg("dim", "back · ")}${theme.fg("dim", `lines ${lineInfo}`)}`;
	lines.push(divider(width, theme));
	lines.push(truncateToWidth(footer, width, ""));
	return lines.slice(0, innerRows);
}

type HarnessKey = "opencode" | "claude" | "pi" | "codex";
const HARNESS_KEY_BY_NAME: Record<string, HarnessKey> = { opencode: "opencode", claude: "claude", pi: "pi", codex: "codex" };

function isActiveSession(session: TrackedSession): boolean {
	return session.state !== "merged" && session.state !== "aborted" && session.state !== "dead" && session.state !== "complete" && session.state !== "cancelled";
}

// A session is "adapter-eligible" only when its registry record carries
// the adapter metadata fields the daemon's spawn_<h>_subscriber path
// reads. Without this gate, expectedSubscribers counted every active
// pi/claude/codex session as needing a subscriber even when the spawn
// failed gracefully and the pane is intentionally on tmux fallback
// (cross-harness review finding #5).
function sessionIsAdapterEligible(session: TrackedSession, harness: HarnessKey): boolean {
	const rec = session as Record<string, unknown>;
	const hasField = (k: string): boolean => {
		const v = rec[k] ?? session.adapter?.[k];
		return typeof v === "string" ? v.length > 0 : v !== null && v !== undefined && v !== "";
	};
	switch (harness) {
		case "opencode": return hasField("oc_url") && hasField("oc_session_id");
		case "claude":   return hasField("cc_url") && hasField("cc_transcript");
		case "pi":       return hasField("pi_bridge_socket") || hasField("pi_bridge_pid");
		case "codex":    return hasField("cx_ws") && hasField("cx_thread_id");
	}
}

function expectedSubscribersByHarness(snapshot: FlightdeckSnapshot): Record<HarnessKey, number> {
	const out: Record<HarnessKey, number> = { opencode: 0, claude: 0, pi: 0, codex: 0 };
	for (const session of readTrackedEntries(snapshot.master)) {
		if (!isActiveSession(session)) continue;
		const key = HARNESS_KEY_BY_NAME[session.harness ?? ""];
		if (key && sessionIsAdapterEligible(session, key)) out[key] += 1;
	}
	return out;
}

function formatSubscriberCounts(theme: Theme, counts: Record<HarnessKey, number>, expected: Record<HarnessKey, number>): string {
	const pairs: Array<{ label: string; key: HarnessKey }> = [
		{ label: "oc", key: "opencode" },
		{ label: "cc", key: "claude" },
		{ label: "pi", key: "pi" },
		{ label: "cx", key: "codex" },
	];
	const parts = pairs.map(({ label, key }) => {
		const actual = counts[key];
		const want = expected[key];
		const tag = want > 0 ? `${label}=${actual}/${want}` : `${label}=${actual}`;
		if (want > 0 && actual < want) return theme.fg("warning", tag);
		if (want > 0 && actual === want) return theme.fg("success", tag);
		return theme.fg("text", tag);
	});
	return parts.join(theme.fg("dim", " "));
}

function shortSubscriberHarnesses(expected: Record<HarnessKey, number>, counts: Record<HarnessKey, number>): Set<HarnessKey> {
	const out = new Set<HarnessKey>();
	for (const key of Object.keys(expected) as HarnessKey[]) {
		if (expected[key] > counts[key]) out.add(key);
	}
	return out;
}

function unsubscribedPanes(snapshot: FlightdeckSnapshot, expected: Record<HarnessKey, number>, counts: Record<HarnessKey, number>): TrackedSession[] {
	// Only surface adapter-eligible sessions whose harness is short on
	// subscribers. Panes intentionally on tmux fallback (no adapter
	// metadata recorded) are not surfaced as "unsubscribed" since the
	// daemon never tried to subscribe them in the first place
	// (cross-harness review finding #5).
	const missingHarnesses = shortSubscriberHarnesses(expected, counts);
	if (missingHarnesses.size === 0) return [];
	const out: TrackedSession[] = [];
	for (const session of readTrackedEntries(snapshot.master)) {
		if (!isActiveSession(session)) continue;
		const key = HARNESS_KEY_BY_NAME[session.harness ?? ""];
		if (key && missingHarnesses.has(key) && sessionIsAdapterEligible(session, key)) out.push(session);
	}
	return out;
}

function sessionForPane(snapshot: FlightdeckSnapshot, paneId: string): TrackedSession | undefined {
	return readTrackedEntries(snapshot.master).find((session) => session.pane_id === paneId || session.pane_target === paneId);
}

function renderDaemonTab(snapshot: FlightdeckSnapshot, ui: PopupUiState, width: number, theme: Theme, viewportRows: number): string[] {
	const lines: string[] = [];
	const d = snapshot.daemon;
	const query = ui.search.trim().toLowerCase();
	if (query) {
		lines.push(searchRow(theme, ui.search, width));
		lines.push("");
	}
	lines.push(`${theme.fg("customMessageLabel", theme.bold("Daemon"))} ${dotIndicator(theme, d.pidAlive)} ${theme.fg("dim", `pid=${d.pid ?? "—"}`)}`);
	lines.push(`${label(theme, "state dir:")} ${theme.fg("text", compactPath(d.stateDir))}`);
	lines.push(`${label(theme, "session:")}   ${theme.fg("text", snapshot.tmux.sessionName)} ${theme.fg("dim", `(${snapshot.tmux.sessionId})`)}`);
	lines.push(`${label(theme, "key:")}       ${theme.fg("text", d.sessionKey ?? "")}`);
	const heartbeatColor = d.heartbeatAgeSec === undefined ? "dim" : d.heartbeatAgeSec < 30 ? "success" : d.heartbeatAgeSec < 120 ? "warning" : "error";
	lines.push(`${label(theme, "heartbeat:")} ${theme.fg(heartbeatColor, formatAge(d.heartbeatAgeSec))}`);
	lines.push(`${label(theme, "busy:")}      ${d.busy ? theme.fg("warning", `master pid=${d.busy.pid ?? "?"} pane=${d.busy.master_pane_id ?? "?"} since ${d.busy.started_at?.slice(11, 19) ?? "?"}`) : theme.fg("success", "free")}`);
	const wp = d.wakePending;
	lines.push(`${label(theme, "wake-pending:")} ${wp ? theme.fg("warning", `${wp.in_flight?.length ?? 0} in-flight since ${wp.delivered_at?.slice(11, 19) ?? "?"}`) : theme.fg("success", "none")}`);
	const counts = d.subscriberCounts;
	const expected = expectedSubscribersByHarness(snapshot);
	lines.push(`${label(theme, "subscribers:")} ${formatSubscriberCounts(theme, counts, expected)}`);
	const shortHarnesses = shortSubscriberHarnesses(expected, counts);
	const liveShortSubscribers = (d.subscribers ?? []).filter((sub) => shortHarnesses.has(sub.harness));
	if (liveShortSubscribers.length > 0) {
		lines.push(`${label(theme, "live subs:")} ${theme.fg("dim", "pids for short harness buckets")}`);
		for (const sub of liveShortSubscribers.slice(0, 8)) {
			const session = sessionForPane(snapshot, sub.paneId);
			const sessionPrefix = session ? `${sessionLabel(session)} ` : "";
			lines.push(`   ${theme.fg("dim", "· ")}${theme.fg("text", `${sessionPrefix}${sub.paneId}`)} ${theme.fg("dim", "·")} ${harnessChip(theme, sub.harness)} ${theme.fg("dim", "·")} ${theme.fg("dim", `pid=${sub.pid}`)}`);
		}
		if (liveShortSubscribers.length > 8) lines.push(`   ${theme.fg("dim", `… ${liveShortSubscribers.length - 8} more`)}`);
	}
	const unsubscribed = unsubscribedPanes(snapshot, expected, counts);
	if (unsubscribed.length > 0) {
		lines.push(`${label(theme, "unsubscribed:")} ${theme.fg("warning", `${unsubscribed.length} tracked pane${unsubscribed.length === 1 ? "" : "s"} without an adapter subscriber`)}`);
		for (const session of unsubscribed.slice(0, 6)) {
			const hint = session.pane_target ? `pane ${session.pane_target}` : "(no pane recorded)";
			lines.push(`   ${theme.fg("dim", "· ")}${theme.fg("text", sessionLabel(session))} ${theme.fg("dim", "·")} ${harnessChip(theme, session.harness ?? undefined)} ${theme.fg("dim", "·")} ${theme.fg("dim", hint)}`);
		}
		if (unsubscribed.length > 6) lines.push(`   ${theme.fg("dim", `… ${unsubscribed.length - 6} more`)}`);
	}
	if (snapshot.masterStatePath) lines.push(`${label(theme, "master state:")} ${theme.fg("text", compactPath(snapshot.masterStatePath))}`);
	if (snapshot.masterError) lines.push(theme.fg("error", `master read error: ${snapshot.masterError}`));
	lines.push("");
	const rawLog = d.logTail ?? [];
	const folded = foldedDaemonLogEvents(rawLog);
	const filtered = query ? folded.filter((ev) => ev.line.toLowerCase().includes(query)) : folded;
	const foldedSuffix = folded.length < rawLog.length ? ` → ${folded.length} row${folded.length === 1 ? "" : "s"}, heartbeats folded` : "";
	lines.push(`${theme.fg("customMessageLabel", theme.bold("Daemon log"))} ${theme.fg("dim", `(tail ${rawLog.length} line${rawLog.length === 1 ? "" : "s"}${foldedSuffix})`)}`);
	const logRows = Math.max(1, viewportRows - lines.length - 2);
	if (filtered.length === 0) {
		lines.push(theme.fg("dim", rawLog.length === 0 ? "No daemon log lines." : "No daemon log lines match current search."));
		return lines;
	}
	clampSelection(ui, filtered.length, logRows);
	const start = Math.max(0, Math.min(ui.scroll, Math.max(0, filtered.length - logRows)));
	const end = Math.min(filtered.length, start + logRows);
	if (start > 0) lines.push(theme.fg("dim", `↑ ${start} earlier`));
	for (const [vi, ev] of filtered.slice(start, end).entries()) {
		const idx = start + vi;
		const selected = idx === ui.selected;
		const row = truncateToWidth(colorizeLiveEvent(ev, theme, selected), width, "");
		lines.push(selected ? selectedRow(theme, row, width) : row);
	}
	const tail = Math.max(0, filtered.length - end);
	if (tail > 0) lines.push(theme.fg("dim", `↓ ${tail} more`));
	return lines;
}

function clampSelection(ui: PopupUiState, total: number, viewportRows: number): void {
	const rows = Math.max(1, viewportRows);
	ui.selected = Math.max(0, Math.min(ui.selected, Math.max(0, total - 1)));
	if (ui.selected < ui.scroll) ui.scroll = ui.selected;
	else if (ui.selected >= ui.scroll + rows) ui.scroll = ui.selected - rows + 1;
	ui.scroll = Math.max(0, Math.min(ui.scroll, Math.max(0, total - rows)));
}

// ============================================================================
// Extension entry point
// ============================================================================

export default function flightdeck(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;
	if (!settingBoolean("enabled", true)) return;

	const cache: DashboardCache = {
		conversations: new Map(),
		state: defaultDashboardState(),
		paneTargetToId: new Map(),
	};
	let activeCtx: ExtensionContext | undefined;
	let poller: ReturnType<typeof setInterval> | undefined;
	let popupTui: { requestRender: () => void } | undefined;

	const refreshSnapshot = (cwd: string): FlightdeckSnapshot | undefined => {
		const snapshot = buildSnapshot(cwd, settingsLike(cwd), {
			logTailLines: Math.max(50, Math.floor(settingNumber("liveFeedLines", 200, cwd))),
			wakeEventsLines: Math.max(50, Math.floor(settingNumber("liveFeedLines", 200, cwd))),
		});
		if (snapshot) {
			const turnsPerPane = Math.max(1, Math.floor(settingNumber("conversationsHistory", 5, cwd)));
			const excerptChars = Math.max(120, Math.floor(settingNumber("conversationExcerptChars", 800, cwd)));
			cache.conversations = foldWakeEventsIntoConversations(cache.conversations, snapshot.wakeEvents, turnsPerPane, excerptChars);
			// Skip the tmux list-panes call entirely when there are no sessions
			// to join against. Key the cache by the joined pane_target set so
			// repeated polls with the same session set reuse the cached map
			// instead of re-shelling tmux every 1.5s (perf review finding #2).
			const sessions = readTrackedEntries(snapshot.master);
			if (sessions.length === 0 || !getAgentsBridge()) {
				cache.paneTargetToId = new Map();
			} else {
				const sessionKey = sessions.map((session) => session.pane_target ?? "").sort().join("|");
				cache.paneTargetToId = buildPaneTargetToIdMap(sessionKey);
			}
		}
		cache.lastSnapshot = snapshot;
		return snapshot;
	};

	const handlePauseTransition = (ctx: ExtensionContext, snapshot: FlightdeckSnapshot | undefined) => {
		const paused = snapshot?.master?.paused_for_user;
		const issueId = paused?.issue_id;
		if (!paused) {
			cache.pauseSeenIssue = undefined;
			cache.pauseSeenAt = undefined;
			return;
		}
		if (cache.pauseSeenIssue === issueId) return;
		cache.pauseSeenIssue = issueId;
		cache.pauseSeenAt = Date.now();
		const paneAllowed = dashboardVisibleForSnapshot(snapshot, dashboardVisibility(ctx.cwd));
		if (!paneAllowed) return;
		if (settingBoolean("pauseBeep", true, ctx.cwd)) process.stdout.write(ANSI_BELL);
		if (settingBoolean("autoOpenOnPause", false, ctx.cwd)) {
			openPopup(pi, ctx).catch(() => undefined);
		}
	};

	const syncWidget = (ctx: ExtensionContext) => {
		activeCtx = ctx;
		if (!ctx.hasUI) {
			setMiniDashboardWidget(ctx, WIDGET_KEY, MINI_DASHBOARD_RANK.FLIGHTDECK, undefined);
			cache.lastSyncKey = "__off__";
			return;
		}
		const snapshot = cache.lastSnapshot;
		const visibility = dashboardVisibility(ctx.cwd);
		const dashboardPaneAllowed = dashboardVisibleForSnapshot(snapshot, visibility);
		const showBanner = dashboardPaneAllowed && settingBoolean("pauseBanner", true, ctx.cwd) && Boolean(snapshot?.master?.paused_for_user);
		const dashboardEnabled = dashboardPaneAllowed && settingBoolean("dashboard", true, ctx.cwd) && cache.state !== "hidden";
		const staleAfterMin = Math.max(0, Math.floor(settingNumber("dashboardStaleAfterMin", 5, ctx.cwd)));
		const status = flightdeckSessionStatus(snapshot, { staleAfterMin });
		const awaitingWatchSessionCount = readAwaitingWatchTrackedEntries(snapshot).length;
		if (status === "inactive" && !showBanner) {
			if (cache.lastSyncKey !== "__off__") {
				setMiniDashboardWidget(ctx, WIDGET_KEY, MINI_DASHBOARD_RANK.FLIGHTDECK, undefined);
				cache.lastSyncKey = "__off__";
			}
			return;
		}
		// Build a structural key over the inputs that actually shape the rendered
		// output. If the file-backed snapshot, the dashboard mode, and the pause
		// state are all unchanged since the previous tick, calling setWidget would
		// only force a redundant TUI redraw — which in turn re-diffs the entire
		// screen and can trip pi-tui's above-viewport flash whenever the chat is
		// taller than the terminal. Skip the call entirely when nothing changed.
		const syncKey = JSON.stringify({
			state: cache.state,
			showBanner,
			dashboardEnabled,
			dashboardVisibility: visibility,
			currentPaneId: snapshot?.tmux.paneId ?? null,
			status,
			awaitingWatchSessionCount,
			master: snapshot?.master ?? null,
			daemonAlive: snapshot?.daemon?.pidAlive ?? null,
			daemonHeartbeat: snapshot?.daemon?.heartbeatAgeSec ?? null,
			polledAt: mostRecentPollMs(snapshot) ?? null,
		});
		if (cache.lastSyncKey === syncKey) return;
		cache.lastSyncKey = syncKey;
		setMiniDashboardWidget(ctx, WIDGET_KEY, MINI_DASHBOARD_RANK.FLIGHTDECK, (tui, theme) => ({
			invalidate() { /* no-op; we drive renders via setInterval+setWidget */ },
			render(width: number): string[] {
				const lines: string[] = [];
				if (showBanner && snapshot) lines.push(...renderPauseBannerLines(snapshot, theme, width));
				if (dashboardEnabled && snapshot) {
					if (status === "live" || status === "terminated") {
						if (lines.length > 0) lines.push("");
						lines.push(...renderDashboardLines(snapshot, theme, width, cache.state, ctx.cwd, cache.paneTargetToId));
					} else if (status === "awaiting-watch") {
						if (lines.length > 0) lines.push("");
						lines.push(...renderAwaitingWatchHintLine(snapshot, theme, width));
					} else if (status === "stale") {
						if (lines.length > 0) lines.push("");
						lines.push(...renderStaleHintLine(snapshot, theme, width));
					} else if (status === "archive-error") {
						if (lines.length > 0) lines.push("");
						lines.push(...renderArchiveErrorBanner(snapshot, theme, width));
					}
				}
				return clampAboveEditorWidget(lines, tui.terminal.rows, theme);
			},
		}), { placement: "aboveEditor" });
	};

	const shouldSkipOwnerWidgetSnapshot = (ctx: ExtensionContext): boolean => {
		const visibility = dashboardVisibility(ctx.cwd); if (popupTui || visibility !== "owner") return false;
		const probe = readOwnerVisibilityProbe(ctx.cwd, settingsLike(ctx.cwd));
		if (!probe) return false; const inChildPane = isInFlightdeckChildPane(); if (inChildPane) return true; if (!probe.ownerPaneId) return false;
		return !dashboardVisibleInPane({ currentPaneId: probe.tmux.paneId, inChildPane, ownerPaneId: probe.ownerPaneId, visibility });
	};

	const tick = (ctx: ExtensionContext) => {
		if (shouldSkipOwnerWidgetSnapshot(ctx)) {
			cache.lastSnapshot = undefined; cache.paneTargetToId = new Map(); syncWidget(ctx);
			return;
		}
		const snapshot = refreshSnapshot(ctx.cwd);
		handlePauseTransition(ctx, snapshot);
		syncWidget(ctx);
		if (popupTui) popupTui.requestRender();
	};

	const startPoller = (ctx: ExtensionContext) => {
		if (poller) clearInterval(poller);
		const interval = pollIntervalMs(ctx.cwd);
		poller = setInterval(() => {
			const live = activeCtx ?? ctx;
			tick(live);
		}, interval);
		// Immediate first tick so the dashboard appears on session start without
		// waiting a full interval.
		tick(ctx);
	};

	const stopPoller = () => {
		if (poller) clearInterval(poller);
		poller = undefined;
	};

	const cycleDashboard = (ctx: ExtensionContext) => {
		cache.state = cache.state === "hidden" ? "compact" : cache.state === "compact" ? "expanded" : "hidden";
		syncWidget(ctx);
		ctx.ui.notify(`Flightdeck dashboard ${cache.state}`, "info");
	};

	async function openPopup(_pi: ExtensionAPI, ctx: ExtensionContext | ExtensionCommandContext): Promise<void> {
		if (!ctx.hasUI) {
			ctx.ui.notify("Flightdeck popup requires a TUI; running headless.", "warning");
			return;
		}
		const releaseModal = acquireVstackModalLock();
		const ui = makeInitialPopupState();
		try {
			await ctx.ui.custom((tui, theme, _kb, done) => {
				popupTui = tui;
				return {
					handleInput(data: string) {
						if (ui.conversationDetail) {
							if (matchesKey(data, "ctrl+c")) {
								done(undefined);
								return;
							}
							if (matchesKey(data, "escape") || matchesKey(data, "backspace")) {
								ui.conversationDetail = undefined;
								ui.conversationDetailScroll = 0;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "up")) {
								ui.conversationDetailScroll = Math.max(0, ui.conversationDetailScroll - 1);
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "down")) {
								ui.conversationDetailScroll += 1;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "pageUp") || matchesKey(data, "-")) {
								ui.conversationDetailScroll = Math.max(0, ui.conversationDetailScroll - 10);
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "pageDown") || matchesKey(data, "=")) {
								ui.conversationDetailScroll += 10;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "home")) {
								ui.conversationDetailScroll = 0;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "end")) {
								ui.conversationDetailScroll = Number.MAX_SAFE_INTEGER;
								tui.requestRender();
							}
							return;
						}
						if (ui.liveDetail) {
							if (matchesKey(data, "ctrl+c")) {
								done(undefined);
								return;
							}
							if (matchesKey(data, "escape") || matchesKey(data, "backspace")) {
								ui.liveDetail = undefined;
								ui.liveDetailScroll = 0;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "up")) {
								ui.liveDetailScroll = Math.max(0, ui.liveDetailScroll - 1);
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "down")) {
								ui.liveDetailScroll += 1;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "pageUp") || matchesKey(data, "-")) {
								ui.liveDetailScroll = Math.max(0, ui.liveDetailScroll - 10);
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "pageDown") || matchesKey(data, "=")) {
								ui.liveDetailScroll += 10;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "home")) {
								ui.liveDetailScroll = 0;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "end")) {
								ui.liveDetailScroll = Number.MAX_SAFE_INTEGER;
								tui.requestRender();
							}
							return;
						}
						if (ui.decisionDetail) {
							if (matchesKey(data, "ctrl+c")) {
								done(undefined);
								return;
							}
							if (matchesKey(data, "escape") || matchesKey(data, "backspace")) {
								ui.decisionDetail = undefined;
								ui.decisionDetailScroll = 0;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "up")) {
								ui.decisionDetailScroll = Math.max(0, ui.decisionDetailScroll - 1);
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "down")) {
								ui.decisionDetailScroll += 1;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "pageUp") || matchesKey(data, "-")) {
								ui.decisionDetailScroll = Math.max(0, ui.decisionDetailScroll - 10);
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "pageDown") || matchesKey(data, "=")) {
								ui.decisionDetailScroll += 10;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "home")) {
								ui.decisionDetailScroll = 0;
								tui.requestRender();
								return;
							}
							if (matchesKey(data, "end")) {
								ui.decisionDetailScroll = Number.MAX_SAFE_INTEGER;
								tui.requestRender();
							}
							return;
						}
						if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) {
							done(undefined);
							return;
						}
						if (matchesKey(data, "tab") || matchesKey(data, "right") || matchesKey(data, "alt+right") || matchesKey(data, "ctrl+l")) {
							const idx = TABS.findIndex((t) => t.id === ui.tab);
							ui.tab = TABS[(idx + 1) % TABS.length].id;
							ui.scroll = 0;
							ui.selected = 0;
							ui.search = "";
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "shift+tab") || matchesKey(data, "left") || matchesKey(data, "alt+left") || matchesKey(data, "ctrl+h")) {
							const idx = TABS.findIndex((t) => t.id === ui.tab);
							ui.tab = TABS[(idx - 1 + TABS.length) % TABS.length].id;
							ui.scroll = 0;
							ui.selected = 0;
							ui.search = "";
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "up")) {
							ui.selected = Math.max(0, ui.selected - 1);
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "down")) {
							ui.selected += 1;
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "pageUp") || matchesKey(data, "-")) {
							ui.selected = Math.max(0, ui.selected - 10);
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "pageDown") || matchesKey(data, "=")) {
							ui.selected += 10;
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "home")) {
							ui.selected = 0;
							ui.scroll = 0;
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "end")) {
							ui.selected = Number.MAX_SAFE_INTEGER;
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "ctrl+n") && ui.tab === TAB_LIVE) {
							ui.liveShowNoisy = !ui.liveShowNoisy;
							ui.selected = 0;
							ui.scroll = 0;
							tui.requestRender();
							return;
						}
						if ((matchesKey(data, "enter") || matchesKey(data, "return")) && ui.tab === TAB_CONVERSATIONS) {
							const snapshot = cache.lastSnapshot ?? refreshSnapshot(activePopupCwd(ctx));
							const item = snapshot ? selectedConversationItem(snapshot, cache.conversations, ui) : undefined;
							if (item) {
								ui.conversationDetail = item;
								ui.conversationDetailScroll = 0;
								tui.requestRender();
							}
							return;
						}
						if ((matchesKey(data, "enter") || matchesKey(data, "return")) && ui.tab === TAB_LIVE) {
							const snapshot = cache.lastSnapshot ?? refreshSnapshot(activePopupCwd(ctx));
							const event = snapshot ? selectedLiveEvent(snapshot, ui, activePopupCwd(ctx)) : undefined;
							if (event) {
								ui.liveDetail = event;
								ui.liveDetailScroll = 0;
								tui.requestRender();
							}
							return;
						}
						if ((matchesKey(data, "enter") || matchesKey(data, "return")) && ui.tab === TAB_DECISIONS) {
							const snapshot = cache.lastSnapshot ?? refreshSnapshot(activePopupCwd(ctx));
							const decision = snapshot ? selectedDecision(snapshot, ui, activePopupCwd(ctx)) : undefined;
							if (decision) {
								ui.decisionDetail = decision;
								ui.decisionDetailScroll = 0;
								tui.requestRender();
							}
							return;
						}
						if (matchesKey(data, "backspace")) {
							ui.search = ui.search.slice(0, -1);
							ui.selected = 0;
							ui.scroll = 0;
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "ctrl+u")) {
							ui.search = "";
							ui.selected = 0;
							ui.scroll = 0;
							tui.requestRender();
							return;
						}
						if (matchesKey(data, "?")) {
							ui.showHelp = !ui.showHelp;
							tui.requestRender();
							return;
						}
						if ((matchesKey(data, "p") || matchesKey(data, "delete")) && ui.tab === TAB_OVERVIEW) {
							const snapshot = cache.lastSnapshot ?? refreshSnapshot(activePopupCwd(ctx));
							const sessions = snapshot ? readTrackedEntries(snapshot.master) : [];
							const filtered = ui.search.trim()
								? sessions.filter((s) => sessionSearchText(s).includes(ui.search.trim().toLowerCase()))
								: sessions;
							const target = filtered[ui.selected];
							if (!target) return;
							if (!isPaneGone(target, snapshot)) {
								ctx.ui.notify(`Prune refused: pane for ${target.id} is still alive in tmux. Use 'flightdeck session stop' instead.`, "warning");
								return;
							}
							const result = pruneTrackedEntry(activePopupCwd(ctx), target.id);
							if (!result.ok) {
								ctx.ui.notify(`Prune failed: ${result.stderr}`, "error");
								return;
							}
							ctx.ui.notify(`Pruned ${target.id}`, "info");
							refreshSnapshot(activePopupCwd(ctx));
							tui.requestRender();
							return;
						}
						if (isPlainSearchInput(data)) {
							ui.search += data;
							ui.selected = 0;
							ui.scroll = 0;
							tui.requestRender();
							return;
						}
					},
					invalidate() { /* no-op */ },
					render(width: number) {
						const safeWidth = Math.max(1, width);
						const innerWidth = frameContentWidth(safeWidth);
						const innerRows = Math.max(10, Math.floor(tui.terminal.rows * 0.85) - 6);
						const snapshot = cache.lastSnapshot ?? refreshSnapshot(activePopupCwd(ctx));
						const lines: string[] = [];
						if (!snapshot) {
							lines.push(theme.fg("warning", "Not running inside a tmux session — flightdeck has nothing to show."));
							lines.push(theme.fg("dim", "Run pi from inside the tmux session that hosts flightdeck."));
							return framePopup(lines, safeWidth, theme, "Flightdeck", innerRows);
						}
						if (ui.conversationDetail) {
							return framePopup(renderConversationDetailView(ui.conversationDetail, ui, innerWidth, theme, innerRows), safeWidth, theme, " Flightdeck · Conversation ", innerRows);
						}
						if (ui.liveDetail) {
							return framePopup(renderLiveEventDetailView(ui.liveDetail, ui, innerWidth, theme, innerRows), safeWidth, theme, " Flightdeck · Live event ", innerRows);
						}
						if (ui.decisionDetail) {
							return framePopup(renderDecisionDetailView(ui.decisionDetail, ui, innerWidth, theme, innerRows), safeWidth, theme, " Flightdeck · Decision ", innerRows);
						}
						lines.push(renderTabBar(ui.tab, innerWidth, theme, snapshot));
						lines.push("");
						const observerHeader = renderObserverHeader(snapshot, theme, innerWidth);
						if (observerHeader) {
							lines.push(observerHeader);
							lines.push(divider(innerWidth, theme));
						}
						const headerSummary = renderPopupHeader(snapshot, theme, innerWidth);
						lines.push(headerSummary);
						lines.push(divider(innerWidth, theme));
						const tabRows = Math.max(4, innerRows - lines.length - 3);
						let body: string[] = [];
						switch (ui.tab) {
							case TAB_OVERVIEW: body = renderOverviewTab(snapshot, ui, innerWidth, theme, tabRows, cache.paneTargetToId); break;
							case TAB_LIVE: body = renderLiveFeedTab(snapshot, ui, innerWidth, theme, tabRows, activePopupCwd(ctx)); break;
							case TAB_CONVERSATIONS: body = renderConversationsTab(snapshot, cache.conversations, ui, innerWidth, theme, tabRows, activePopupCwd(ctx)); break;
							case TAB_CONFLICTS: body = renderConflictsTab(snapshot, ui, innerWidth, theme); break;
							case TAB_DECISIONS: body = renderDecisionsTab(snapshot, ui, innerWidth, theme, tabRows, activePopupCwd(ctx)); break;
							case TAB_DAEMON: body = renderDaemonTab(snapshot, ui, innerWidth, theme, tabRows); break;
						}
						lines.push(...body);
						const footer = renderPopupFooter(theme, innerWidth, ui);
						const padded = lines.slice(0, innerRows - 2);
						padded.push(divider(innerWidth, theme));
						padded.push(footer);
						return framePopup(padded, safeWidth, theme, " Flightdeck ", innerRows);
					},
				};
			}, { overlay: true, overlayOptions: { anchor: "center", maxHeight: POPUP_MAX_HEIGHT, width: POPUP_WIDTH_PERCENT } });
		} finally {
			popupTui = undefined;
			releaseModal();
		}
	}

	function renderPopupHeader(snapshot: FlightdeckSnapshot, theme: Theme, width: number): string {
		const sessions = readTrackedEntries(snapshot.master);
		const summary = formatStateBreakdown(theme, sessions, { includeNames: true, separator: theme.fg("dim", "  ·  ") });
		const queue = snapshot.master?.merge_queue?.length ?? 0;
		const queuePart = queue > 0 ? ` ${theme.fg("dim", "·")} ${theme.fg("accent", `merge-queue ${queue}`)}` : "";
		const headerRight = headerChipForSnapshot(snapshot, theme);
		// tmux session_id ($N) is dropped here — it never changes for the life
		// of the session and visually collides with USD cost strings; the
		// Daemon tab still shows it for diagnostics.
		const sessionLine = `${theme.fg("muted", "session")} ${theme.fg("text", snapshot.tmux.sessionName)}`;
		const left = `${sessionLine}  ${theme.fg("dim", "·")}  ${formatSessionTotals(theme, sessions)}${summary ? `  ${theme.fg("dim", "·")}  ${summary}` : ""}${queuePart}`;
		const padded = pad(left, Math.max(0, width - visibleWidth(headerRight) - 2));
		return truncateToWidth(`${padded}  ${headerRight}`, width, "");
	}

	function renderPopupFooter(theme: Theme, _width: number, ui: PopupUiState): string {
		const tabHint = `${ansiYellow("tab")} ${theme.fg("dim", "next tab · ")}${ansiYellow("shift+tab")} ${theme.fg("dim", "prev")}`;
		const viewHint = ui.tab === TAB_DECISIONS || ui.tab === TAB_LIVE || ui.tab === TAB_CONVERSATIONS ? `${theme.fg("dim", " · ")}${ansiYellow("enter")} ${theme.fg("dim", "details")}` : "";
		const navVerb = ui.tab === TAB_DAEMON ? "scroll" : "select";
		const noiseHint = ui.tab === TAB_LIVE ? `${theme.fg("dim", " · ")}${ansiYellow("ctrl+n")} ${theme.fg("dim", ui.liveShowNoisy ? "important" : "all")}` : "";
		const pruneHint = ui.tab === TAB_OVERVIEW ? `${theme.fg("dim", " · ")}${ansiYellow("p")}${theme.fg("dim", "/")}${ansiYellow("del")} ${theme.fg("dim", "prune dead")}` : "";
		const navHint = `${ansiYellow("↑/↓")} ${theme.fg("dim", `${navVerb} · `)}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("home/end")} ${theme.fg("dim", "ends")}${viewHint}${noiseHint}${pruneHint}`;
		const searchHint = ui.search ? `${ansiYellow("ctrl+u")} ${theme.fg("dim", "clear search")}` : `${theme.fg("dim", "type to filter")}`;
		const closeHint = `${ansiYellow("esc")} ${theme.fg("dim", "close")}`;
		return `${tabHint}  ${theme.fg("dim", "·")}  ${navHint}  ${theme.fg("dim", "·")}  ${searchHint}  ${theme.fg("dim", "·")}  ${closeHint}`;
	}

	pi.on("session_start", (_event, ctx) => {
		activeCtx = ctx;
		startPoller(ctx);
	});
	pi.on("session_tree", (_event, ctx) => {
		activeCtx = ctx;
		// Force a refresh on tree changes (e.g., resume).
		tick(ctx);
	});
	pi.on("session_shutdown", (_event, ctx) => {
		stopPoller();
		setMiniDashboardWidget(ctx, WIDGET_KEY, MINI_DASHBOARD_RANK.FLIGHTDECK, undefined);
	});

	// React to settings changes — clear cache so next tick reflects new values.
	pi.events.on(SETTINGS_EVENT, (_payload: unknown) => {
		const ctx = activeCtx;
		if (!ctx) return;
		if (cache.state === "hidden" && settingBoolean("dashboard", true, ctx.cwd)) {
			cache.state = defaultDashboardState(ctx.cwd);
		}
		tick(ctx);
	});

	pi.registerCommand("flightdeck", {
		description: "Open the flightdeck session-control popup. With 'watch [args...]', dispatch the legacy flightdeck watch bridge workaround.",
		handler: async (args, ctx) => {
			const trimmed = (args ?? "").trim();
			if (!trimmed) {
				await openPopup(pi, ctx);
				return;
			}
			const firstSpace = trimmed.search(/\s/);
			const verb = firstSpace === -1 ? trimmed : trimmed.slice(0, firstSpace);
			const rest = firstSpace === -1 ? "" : trimmed.slice(firstSpace + 1).trim();
			if (verb === "watch") {
				// Legacy workaround kept for callers that still send the bare
				// /flightdeck watch form. The daemon now sends
				// /skill:flightdeck directly through pi-session-bridge, which
				// expands skills client-side (vstack#13).
				const skillCmd = rest ? `/skill:flightdeck watch ${rest}\n` : "/skill:flightdeck watch\n";
				ctx.ui.pasteToEditor(skillCmd);
				return;
			}
			// Unknown subcommand — fall back to opening the popup so
			// operators get a visible response rather than silent
			// failure. ctx.ui.notify isn't always intercepted; popup is
			// the most discoverable path.
			await openPopup(pi, ctx);
		},
	});
	pi.registerCommand("flightdeck:toggle", {
		description: "Cycle the persistent flightdeck dashboard widget hidden → compact → expanded.",
		handler: async (_args, ctx) => cycleDashboard(ctx as ExtensionContext),
	});

	const popupShortcut = settingString("popupShortcut", "f6");
	if (popupShortcut !== "none") {
		pi.registerShortcut(popupShortcut as Parameters<typeof pi.registerShortcut>[0], {
			description: "Open the flightdeck session-control popup",
			handler: async (ctx) => openPopup(pi, ctx as ExtensionContext),
		});
	}
	const dashboardShortcut = settingString("dashboardShortcut", "alt+m");
	if (dashboardShortcut !== "none") {
		pi.registerShortcut(dashboardShortcut as Parameters<typeof pi.registerShortcut>[0], {
			description: "Cycle the flightdeck dashboard widget",
			handler: async (ctx) => cycleDashboard(ctx as ExtensionContext),
		});
	}
}
