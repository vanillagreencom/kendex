/**
 * pi-flightdeck — read-only mission control for the flightdeck skill.
 *
 * Reads on-disk artifacts produced by skills/flightdeck/scripts/* — never
 * mutates them. Renders persistent status widgets, pause banner, and /flightdeck app focus.
 *
 * Pi extension only — the underlying flightdeck skill works without this
 * extension via the same on-disk files.
 */

import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { truncateToWidth } from "@earendil-works/pi-tui";

import {
	type FlightdeckSessionStatus,
	type FlightdeckSnapshot,
	type TrackedSession,
	buildSnapshot,
	findTrackedEntry,
	flightdeckSessionStatus,
	daemonEverStarted,
	formatAge,
	isPaneGone,
	mostRecentPollMs,
	readAwaitingWatchTrackedEntries,
	readOwnerVisibilityProbe,
	readTrackedEntries,
	resolveProjectRoot,
	type SettingsLike,
} from "./state.js";
import { dashboardVisibleForSnapshot, dashboardVisibleInPane, isInFlightdeckChildPane, normalizeDashboardVisibility, type DashboardVisibility } from "./dashboard-visibility.js";
import {
	buildPaneTargetToIdMap,
	formatUsageCompact,
	getAgentsBridge,
	type AgentsBridgeItem,
} from "./agents-bridge.js";
import {
	ANSI_BELL,
	daemonHealthChip,
	formatShortcutHint,
	frameContentWidth,
	framePanel,
	harnessChip,
	panelBranch,
	type TreeStyle,
	wrapLine,
} from "./render.js";
import { headerChipForSnapshot, renderArchiveErrorBanner } from "./render-terminated.js";
import { formatSessionTotals, formatStateBreakdown, issueDomain, renderSessionDetailLines, renderSessionLine, sessionLabel } from "./session-ui.js";
import { MINI_DASHBOARD_RANK, setMiniDashboardWidget } from "./stacked-widget.js";
import {
	createFlightdeckDashboardVisibility,
	cycleFlightdeckDashboardVisibility,
	flightdeckWidgetSuppressedByUser,
	normalizeDashboardState,
	resetFlightdeckDashboardVisibility,
	shouldRenderFlightdeckInlineWidget,
	type DashboardState,
	type FlightdeckDashboardVisibilityState,
} from "./visibility.js";
export type { DashboardState } from "./visibility.js";
const INSTALL_SYMBOL = Symbol.for("vstack.pi-flightdeck.installed");
const CONFIG_ID = "@vanillagreen/pi-flightdeck";
const SETTINGS_EVENT = "vstack:extension-settings-changed";
const WIDGET_KEY = "vstack-flightdeck-widget";
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

interface DashboardCache {
	visibility: FlightdeckDashboardVisibilityState;
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
	return [...lines.slice(0, maxLines - 1), theme.fg("muted", `… ${hidden} more (open /flightdeck for the full app)`)];
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

function defaultDashboardState(cwd?: string): DashboardState { return normalizeDashboardState(settingString("dashboardDefaultState", "compact", cwd), "compact"); }

function dashboardVisibility(cwd?: string): DashboardVisibility { return normalizeDashboardVisibility(settingString("dashboardVisibility", "owner", cwd)); }

function pollIntervalMs(cwd?: string): number { return Math.max(500, Math.floor(settingNumber("pollIntervalMs", 1500, cwd))); }

export function dashboardAllowedForStatus(dashboardPaneAllowed: boolean, status: FlightdeckSessionStatus): boolean {
	return dashboardPaneAllowed || status === "state-error" || status === "archive-error";
}

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
	const hint = theme.fg("dim", "Respond in chat to resume the master agent. Run ") + theme.fg("warning", "/flightdeck") + theme.fg("dim", " for full context.");
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

export function renderStateErrorBanner(snapshot: FlightdeckSnapshot, theme: Theme, width: number): string[] {
	const path = snapshot.masterStatePath ? ` ${snapshot.masterStatePath}` : "";
	const error = snapshot.masterError ?? "unknown state read error";
	const inner = frameContentWidth(width) - 2;
	const lines = [
		`${theme.fg("error", "▲ FLIGHTDECK STATE ERROR")}${theme.fg("dim", path)}`,
		...wrapLine(theme.fg("dim", error), inner).slice(0, 4),
		"",
		theme.fg("dim", "Fix or archive the state file; the mini-dashboard is hidden until state can be read."),
	];
	return framePanel(lines, width, theme, "error", " STATE — read/parse error ");
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
	// `<title> <stats> · alt+m toggle · /flightdeck app · <daemon-health>`.
	const toggleShortcut = settingString("dashboardShortcut", "alt+m", cwd);
	const toggleHint = toggleShortcut === "none" ? "" : theme.fg("dim", ` · ${formatShortcutHint(toggleShortcut)} ${terminated ? "dismiss" : "toggle"}`);
	const appHint = theme.fg("dim", " · /flightdeck app");
	const hints = `${toggleHint}${appHint}`;
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
			lines.push(`${panelBranch(theme, "└", treeStyle)}${theme.fg("dim", "pane gone — run /flightdeck for full app context")}`);
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
		lines.push(`${panelBranch(theme, "└", treeStyle)}${theme.fg("dim", "pane gone — run /flightdeck for full app context")}`);
	}
	return framePanel(lines, width, theme);
}

function dashboardChildBranch(theme: Theme, style: TreeStyle, parentLast: boolean, childLast: boolean): string {
	if (style === "ascii") {
		const parentStem = parentLast ? "    " : "|   ";
		return theme.fg("muted", `${parentStem}${childLast ? "`-- " : "|-- "}`);
	}
	const parentStem = parentLast ? "   " : "│  ";
	return theme.fg("muted", `${parentStem}${childLast ? "└─ " : "├─ "}`);
}

interface FocusOrLaunchReport {
	status?: string;
	reason?: string;
	pane?: string | null;
	window?: string | null;
	stderr?: string | null;
}

function resolveFlightdeckDashboardBin(cwd: string): string {
	const root = resolveProjectRoot(cwd);
	const candidates = [
		join(root, ".agents/skills/flightdeck/scripts/flightdeck-dashboard"),
		join(root, "skills/flightdeck/scripts/flightdeck-dashboard"),
	];
	return candidates.find((candidate) => existsSync(candidate)) ?? "flightdeck-dashboard";
}

function splitCommandArgs(input: string): string[] {
	return input.trim().length > 0 ? input.trim().split(/\s+/) : [];
}

function focusReportMessage(report: FocusOrLaunchReport): { message: string; level: "info" | "warning" | "error" } {
	const status = report.status ?? "error";
	const reason = report.reason ? `: ${report.reason}` : "";
	const target = [report.window ? `window ${report.window}` : "", report.pane ? `pane ${report.pane}` : ""].filter(Boolean).join(" · ");
	const suffix = target ? ` (${target})` : "";
	if (status === "focused" || status === "launched") return { level: "info", message: `Flightdeck app ${status}${suffix}` };
	if (status === "blocked") return { level: "warning", message: `Flightdeck app blocked${reason}` };
	return { level: "error", message: `Flightdeck app error${reason}` };
}

function focusOrLaunchFlightdeckApp(ctx: ExtensionCommandContext | ExtensionContext, args?: string): void {
	const cwd = (ctx as { cwd?: string }).cwd ?? process.cwd();
	const bin = resolveFlightdeckDashboardBin(cwd);
	const extra = splitCommandArgs(args ?? "").filter((arg) => arg !== "--json");
	const result = spawnSync(bin, ["focus-or-launch", "--json", ...extra], {
		cwd,
		encoding: "utf8",
		env: process.env,
		timeout: 15_000,
	});
	const stdout = (result.stdout ?? "").trim();
	let report: FocusOrLaunchReport | undefined;
	if (stdout) {
		try {
			report = JSON.parse(stdout) as FocusOrLaunchReport;
		} catch (error) {
			const snippet = stdout.length > 240 ? `${stdout.slice(0, 240)}…` : stdout;
			report = {
				status: "error",
				reason: `flightdeck-dashboard returned malformed JSON: ${error instanceof Error ? error.message : String(error)}; stdout=${JSON.stringify(snippet)}`,
				stderr: (result.stderr ?? "").trim() || null,
			};
		}
	}
	if (!report) {
		const stderr = (result.stderr ?? "").trim();
		const error = result.error?.message ?? (stderr || `flightdeck-dashboard returned no JSON (exit ${result.status ?? "unknown"})`);
		report = { status: "error", reason: error, stderr };
	}
	if (result.status !== 0 && report.status !== "blocked" && report.status !== "error") {
		report = { ...report, status: "error", reason: report.reason ?? `flightdeck-dashboard exited ${result.status}` };
	}
	const notification = focusReportMessage(report);
	ctx.ui.notify(notification.message, notification.level);
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
		visibility: createFlightdeckDashboardVisibility(defaultDashboardState()),
		paneTargetToId: new Map(),
	};
	let activeCtx: ExtensionContext | undefined;
	let poller: ReturnType<typeof setInterval> | undefined;

	const refreshSnapshot = (cwd: string): FlightdeckSnapshot | undefined => {
		const snapshot = buildSnapshot(cwd, settingsLike(cwd), {
			logTailLines: 50,
			wakeEventsLines: 50,
		});
		if (snapshot) {
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
		const staleAfterMin = Math.max(0, Math.floor(settingNumber("dashboardStaleAfterMin", 5, ctx.cwd)));
		const status = flightdeckSessionStatus(snapshot, { staleAfterMin });
		const suppressedByUser = flightdeckWidgetSuppressedByUser(cache.visibility);
		const showBanner = !suppressedByUser && dashboardPaneAllowed && settingBoolean("pauseBanner", true, ctx.cwd) && Boolean(snapshot?.master?.paused_for_user);
		const dashboardEnabled = !suppressedByUser && dashboardAllowedForStatus(dashboardPaneAllowed, status) && settingBoolean("dashboard", true, ctx.cwd) && cache.visibility.state !== "hidden";
		const awaitingWatchSessionCount = readAwaitingWatchTrackedEntries(snapshot).length;
		if (!shouldRenderFlightdeckInlineWidget(cache.visibility, { dashboardEnabled, showBanner, status })) {
			if (cache.lastSyncKey !== "__off__") {
				setMiniDashboardWidget(ctx, WIDGET_KEY, MINI_DASHBOARD_RANK.FLIGHTDECK, undefined);
				cache.lastSyncKey = "__off__";
			}
			return;
		}
		const syncKey = JSON.stringify({
			state: cache.visibility.state,
			hiddenByUser: cache.visibility.hiddenByUser,
			showBanner,
			dashboardEnabled,
			dashboardVisibility: visibility,
			currentPaneId: snapshot?.tmux.paneId ?? null,
			status,
			awaitingWatchSessionCount,
			master: snapshot?.master ?? null,
			masterError: snapshot?.masterError ?? null,
			masterStatePath: snapshot?.masterStatePath ?? null,
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
					if (status === "live") {
						if (lines.length > 0) lines.push("");
						lines.push(...renderDashboardLines(snapshot, theme, width, cache.visibility.state, ctx.cwd, cache.paneTargetToId));
					} else if (status === "awaiting-watch") {
						if (lines.length > 0) lines.push("");
						lines.push(...renderAwaitingWatchHintLine(snapshot, theme, width));
					} else if (status === "stale") {
						if (lines.length > 0) lines.push("");
						lines.push(...renderStaleHintLine(snapshot, theme, width));
					} else if (status === "state-error") {
						if (lines.length > 0) lines.push("");
						lines.push(...renderStateErrorBanner(snapshot, theme, width));
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
		const visibility = dashboardVisibility(ctx.cwd);
		if (visibility !== "owner") return false;
		const probe = readOwnerVisibilityProbe(ctx.cwd, settingsLike(ctx.cwd));
		if (!probe) return false;
		const inChildPane = isInFlightdeckChildPane();
		if (inChildPane) return true;
		if (!probe.ownerPaneId) return false;
		return !dashboardVisibleInPane({ currentPaneId: probe.tmux.paneId, inChildPane, ownerPaneId: probe.ownerPaneId, visibility });
	};

	const tick = (ctx: ExtensionContext) => {
		if (shouldSkipOwnerWidgetSnapshot(ctx)) {
			cache.lastSnapshot = undefined;
			cache.paneTargetToId = new Map();
			syncWidget(ctx);
			return;
		}
		const snapshot = refreshSnapshot(ctx.cwd);
		handlePauseTransition(ctx, snapshot);
		syncWidget(ctx);
	};

	const startPoller = (ctx: ExtensionContext) => {
		if (poller) clearInterval(poller);
		const interval = pollIntervalMs(ctx.cwd);
		poller = setInterval(() => {
			const live = activeCtx ?? ctx;
			tick(live);
		}, interval);
		tick(ctx);
	};

	const stopPoller = () => {
		if (poller) clearInterval(poller);
		poller = undefined;
	};

	const cycleDashboard = (ctx: ExtensionContext) => {
		cycleFlightdeckDashboardVisibility(cache.visibility);
		syncWidget(ctx);
		ctx.ui.notify(`Flightdeck dashboard ${cache.visibility.state}`, "info");
	};

	pi.on("session_start", (_event, ctx) => {
		activeCtx = ctx;
		resetFlightdeckDashboardVisibility(cache.visibility, defaultDashboardState(ctx.cwd));
		startPoller(ctx);
	});
	pi.on("session_tree", (_event, ctx) => {
		activeCtx = ctx;
		tick(ctx);
	});
	pi.on("session_shutdown", (_event, ctx) => {
		stopPoller();
		setMiniDashboardWidget(ctx, WIDGET_KEY, MINI_DASHBOARD_RANK.FLIGHTDECK, undefined);
	});

	pi.events.on(SETTINGS_EVENT, (_payload: unknown) => {
		const ctx = activeCtx;
		if (!ctx) return;
		tick(ctx);
	});

	pi.registerCommand("flightdeck", {
		description: "Focus the Flightdeck Rust app, or launch it if missing.",
		handler: async (args, ctx) => focusOrLaunchFlightdeckApp(ctx, args),
	});
	pi.registerCommand("flightdeck:toggle", {
		description: "Cycle the persistent flightdeck dashboard widget; user-hidden state stays hidden until toggled back in.",
		handler: async (_args, ctx) => cycleDashboard(ctx as ExtensionContext),
	});

	const dashboardShortcut = settingString("dashboardShortcut", "alt+m");
	if (dashboardShortcut !== "none") {
		pi.registerShortcut(dashboardShortcut as Parameters<typeof pi.registerShortcut>[0], {
			description: "Cycle the flightdeck dashboard widget",
			handler: async (ctx) => cycleDashboard(ctx as ExtensionContext),
		});
	}
}
