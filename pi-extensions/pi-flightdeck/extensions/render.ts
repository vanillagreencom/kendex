/**
 * Shared render helpers — color tokens, frames, tree connectors, state /
 * harness / classifier badges. Matches the pi-task-panel and
 * pi-extension-manager visual patterns.
 */

import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";

type ThemeColor = Parameters<Theme["fg"]>[0];

import type { TrackedState } from "./state.js";
import { frameGlyphs, glyphs } from "./glyphs.js";

export const ANSI_YELLOW_FG = "\x1b[33m";
export const ANSI_RED_FG = "\x1b[31m";
export const ANSI_CYAN_FG = "\x1b[36m";
export const ANSI_MAGENTA_FG = "\x1b[35m";
export const ANSI_FG_RESET = "\x1b[39m";
export const ANSI_BELL = "\x07";

export const FRAME_PADDING_X = 2;
export const PANEL_CARD_PADDING_X = 1;
export const PANEL_BAR_COLOR = "borderAccent" as const;
export const PANEL_TITLE_COLOR = "customMessageLabel" as const;
export const PANEL_RULE_COLOR = "muted" as const;

export function ansiYellow(text: string): string { return `${ANSI_YELLOW_FG}${text}${ANSI_FG_RESET}`; }
export function ansiRed(text: string): string { return `${ANSI_RED_FG}${text}${ANSI_FG_RESET}`; }
export function ansiCyan(text: string): string { return `${ANSI_CYAN_FG}${text}${ANSI_FG_RESET}`; }
export function ansiMagenta(text: string): string { return `${ANSI_MAGENTA_FG}${text}${ANSI_FG_RESET}`; }

export function pad(text: string, width: number): string {
	const truncated = truncateToWidth(text, width, "");
	return `${truncated}${" ".repeat(Math.max(0, width - visibleWidth(truncated)))}`;
}

export function wrapLine(line: string, width: number): string[] {
	const safeWidth = Math.max(1, width);
	const normalized = String(line ?? "").replace(/\t/g, "  ");
	const wrapped = normalized.split(/\r?\n/).flatMap((part) => {
		const rows = wrapTextWithAnsi(part, safeWidth);
		return rows.length > 0 ? rows : [""];
	});
	return wrapped.map((part) => truncateToWidth(part, safeWidth, ""));
}

export function divider(width: number, theme: Theme): string {
	return theme.fg("dim", glyphs().line.repeat(Math.max(1, width)));
}

export function frameContentWidth(width: number): number {
	return Math.max(1, width - 2 - FRAME_PADDING_X * 2);
}

export function panelFrameContentWidth(width: number): number {
	return Math.max(1, width - 2 - PANEL_CARD_PADDING_X * 2);
}

/**
 * Inline panel frame — compact (no padding rows), single-cell side padding.
 * Used for the persistent dashboard widget and the pause banner.
 */
export function framePanel(lines: string[], width: number, theme: Theme, color: ThemeColor = PANEL_BAR_COLOR, title = ""): string[] {
	const safeWidth = Math.max(1, width);
	if (safeWidth < 8) return lines.map((line) => truncateToWidth(line, safeWidth, ""));
	const inner = Math.max(1, safeWidth - 2);
	const contentWidth = panelFrameContentWidth(safeWidth);
	const border = (text: string): string => theme.fg(color, text);
	const frame = frameGlyphs();
	const top = (): string => {
		if (!title) return `${border(frame.tl)}${border(frame.h.repeat(inner))}${border(frame.tr)}`;
		const titlePlain = ` ${truncateToWidth(title, Math.max(1, inner - 2), glyphs().ellipsis)} `;
		const fill = Math.max(1, inner - visibleWidth(titlePlain));
		return `${border(frame.tl)}${theme.fg(color, titlePlain)}${border(frame.h.repeat(fill))}${border(frame.tr)}`;
	};
	return [
		top(),
		...lines.map((line) => `${border(frame.v)}${" ".repeat(PANEL_CARD_PADDING_X)}${pad(line, contentWidth)}${" ".repeat(PANEL_CARD_PADDING_X)}${border(frame.v)}`),
		`${border(frame.bl)}${border(frame.h.repeat(inner))}${border(frame.br)}`,
	].map((line) => truncateToWidth(line, safeWidth, ""));
}

export type TreeStyle = "unicode" | "ascii";

export function panelBranch(theme: Theme, branch: "├" | "└" | "│", style: TreeStyle): string {
	if (style === "ascii") {
		if (branch === "│") return theme.fg(PANEL_RULE_COLOR, "|  ");
		return theme.fg(PANEL_RULE_COLOR, branch === "└" ? "`-- " : "|-- ");
	}
	if (branch === "│") return theme.fg(PANEL_RULE_COLOR, "│  ");
	return theme.fg(PANEL_RULE_COLOR, `${branch}─ `);
}

// Nerd Font cog (matches pi-agents-tmux dashboard "working" glyph) so the
// two stacked dashboards read with the same visual weight for the
// "agent is currently working" row.
export const COG_GLYPH = "\uf013";

// Keep shortcut hints lowercase (`ctrl+o`, `alt+f`, `f6`) to match other Pi tool output.
export function formatShortcutHint(shortcut: string): string {
	return shortcut.toLowerCase();
}

export function stateColor(state: TrackedState | string | undefined | null): "success" | "warning" | "error" | "accent" | "muted" | "dim" {
	switch (state) {
		case "complete": return "success";
		case "merged": return "success";
		case "ready": return "success";
		case "merge-ready": return "accent";
		case "submitting": return "accent";
		case "prompting": return "warning";
		case "waiting": return "warning";
		case "cancelled": return "error";
		case "aborted": return "error";
		case "dead": return "error";
		default: return "dim";
	}
}

export function stateGlyph(state: TrackedState | string | undefined | null): string {
	switch (state) {
		case "complete": return glyphs().ok;
		case "merged": return glyphs().ok;
		case "ready": return glyphs().bullet.trim();
		case "merge-ready": return glyphs().warn;
		case "submitting": return glyphs().diamond;
		case "prompting": return "?";
		case "waiting": return COG_GLYPH;
		case "cancelled": return glyphs().fail;
		case "aborted": return glyphs().fail;
		case "dead": return glyphs().fail;
		default: return glyphs().dot.trim();
	}
}

export function stateBadge(theme: Theme, state: TrackedState | string | undefined | null): string {
	const text = state ?? "?";
	return theme.fg(stateColor(state), `${stateGlyph(state)} ${text}`);
}

const HARNESS_COLORS: Record<string, "accent" | "warning" | "success" | "muted"> = {
	claude: "accent",
	codex: "success",
	opencode: "warning",
	pi: "accent",
};

export function harnessChip(theme: Theme, harness: string | undefined): string {
	if (!harness) return theme.fg("dim", "—");
	const color = HARNESS_COLORS[harness] ?? "muted";
	return theme.fg(color, harness);
}

const TAG_COLORS: Record<string, "success" | "warning" | "error" | "accent" | "muted"> = {
	"audit-relation-prompt": "accent",
	"awaiting-direction": "warning",
	"bash-permission-prompt": "warning",
	"bot-review-wait-stuck": "warning",
	"cleanup-prompt": "accent",
	"cycle-fix-suggestions": "warning",
	"descope-related": "warning",
	"external-fix-suggestions": "warning",
	"force-merge-confirm": "warning",
	"force-push-prompt": "warning",
	"generic-multi-choice": "warning",
	"merge-now": "success",
	"merge-ready-but-unknown": "accent",
	"modal-prompt": "warning",
	"multi-select-tabbed": "warning",
	"oc-question": "accent",
	"pi-question": "accent",
	"pi-subagent-completion": "warning",
	"rebase-multi-choice": "warning",
	rendering: "muted",
	"terminal-state-reached": "success",
};

export function tagBadge(theme: Theme, tag: string | undefined): string {
	if (!tag) return theme.fg("dim", "—");
	const color = TAG_COLORS[tag] ?? "muted";
	return theme.fg(color, tag);
}

export function bool(theme: Theme, value: boolean | undefined, ok = "yes", bad = "no"): string {
	return value ? theme.fg("success", ok) : theme.fg("error", bad);
}

export function dotIndicator(theme: Theme, alive: boolean): string {
	return alive ? theme.fg("success", glyphs().bullet.trim()) : theme.fg("error", glyphs().bullet.trim());
}

// Combined daemon health chip. Five visual states, matching the
// real daemon lifecycle so the dashboard never lies:
//   standby — !alive AND no pid file AND no heartbeat file: daemon
//             has never started for this session. Common between
//             `session start` and `session watch`. Dim, not alarming.
//   no-pulse — alive but no heartbeat seen yet (just spawned).
//   stale (warn) — alive, heartbeat 30..120s old.
//   stale (err)  — alive, heartbeat >=120s old.
//   dead — !alive but pid or heartbeat file exists (daemon ran and
//          died). This is the genuinely alarming case.
//   ok — alive, heartbeat <30s.
export interface DaemonChipInput {
	alive: boolean;
	heartbeatAgeSec: number | undefined;
	everStarted: boolean;
}

export function daemonHealthChip(theme: Theme, input: DaemonChipInput): string {
	const { alive, heartbeatAgeSec, everStarted } = input;
	const bullet = glyphs().bullet.trim();
	if (!alive && !everStarted) return `${theme.fg("dim", bullet)} ${theme.fg("dim", "daemon standby")}`;
	if (!alive) return `${theme.fg("error", bullet)} ${theme.fg("error", "daemon dead")}`;
	if (heartbeatAgeSec === undefined) return `${theme.fg("warning", bullet)} ${theme.fg("warning", "daemon no-pulse")}`;
	if (heartbeatAgeSec >= 120) return `${theme.fg("error", bullet)} ${theme.fg("error", `daemon stale ${formatAgeShort(heartbeatAgeSec)}`)}`;
	if (heartbeatAgeSec >= 30) return `${theme.fg("warning", bullet)} ${theme.fg("warning", `daemon stale ${formatAgeShort(heartbeatAgeSec)}`)}`;
	return `${theme.fg("success", bullet)} ${theme.fg("dim", "daemon")}`;
}

// Header chip rendered in place of `daemonHealthChip` when the master
// state has `terminated: true`. The daemon is intentionally stopped after
// `terminate.md § 5`; the alarming red "daemon dead" badge was the
// previous (wrong) signal in the post-completion view (issue #17).
export function sessionCompleteChip(theme: Theme): string {
	return `${theme.fg("success", glyphs().ok)} ${theme.fg("success", "session complete")}`;
}

function formatAgeShort(sec: number): string {
	if (sec < 60) return `${sec}s`;
	if (sec < 3600) return `${Math.floor(sec / 60)}m`;
	if (sec < 86_400) return `${Math.floor(sec / 3600)}h`;
	return `${Math.floor(sec / 86_400)}d`;
}

export function muted(theme: Theme, text: string): string { return theme.fg("dim", text); }
export function label(theme: Theme, text: string): string { return theme.fg("muted", text); }
export function accent(theme: Theme, text: string): string { return theme.fg("accent", text); }
