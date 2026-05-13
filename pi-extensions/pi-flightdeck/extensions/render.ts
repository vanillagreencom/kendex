/**
 * Shared render helpers — color tokens, frames, tree connectors, state /
 * harness / classifier badges. Matches the pi-task-panel and
 * pi-extension-manager visual patterns.
 */

import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";

type ThemeColor = Parameters<Theme["fg"]>[0];

import type { TrackedState } from "./state.js";

export const ANSI_GREEN_FG = "\x1b[32m";
export const ANSI_YELLOW_FG = "\x1b[33m";
export const ANSI_RED_FG = "\x1b[31m";
export const ANSI_CYAN_FG = "\x1b[36m";
export const ANSI_MAGENTA_FG = "\x1b[35m";
export const ANSI_FG_RESET = "\x1b[39m";
export const ANSI_BELL = "\x07";

export const POPUP_PADDING_X = 2;
export const POPUP_PADDING_Y = 1;
export const PANEL_CARD_PADDING_X = 1;
export const PANEL_BAR_COLOR = "borderAccent" as const;
export const PANEL_TITLE_COLOR = "customMessageLabel" as const;
export const PANEL_RULE_COLOR = "muted" as const;

export function ansiGreen(text: string): string { return `${ANSI_GREEN_FG}${text}${ANSI_FG_RESET}`; }
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
	return theme.fg("dim", "─".repeat(Math.max(1, width)));
}

export function frameContentWidth(width: number): number {
	return Math.max(1, width - 2 - POPUP_PADDING_X * 2);
}

export function panelFrameContentWidth(width: number): number {
	return Math.max(1, width - 2 - PANEL_CARD_PADDING_X * 2);
}

/**
 * Popup frame — heavy border, green title in top border, padded body.
 * Matches pi-extension-manager / pi-task-panel popup style.
 */
export function framePopup(lines: string[], width: number, theme: Theme, title = "", fixedInnerRows?: number): string[] {
	const inner = Math.max(1, width - 2);
	const contentWidth = frameContentWidth(width);
	const border = (s: string) => theme.fg("borderAccent", s);
	let body = lines;
	if (fixedInnerRows !== undefined && body.length > fixedInnerRows) {
		const hidden = body.length - fixedInnerRows + 1;
		body = [...body.slice(0, Math.max(0, fixedInnerRows - 1)), theme.fg("dim", `↓ ${hidden} more line(s)`)].slice(0, fixedInnerRows);
	}
	const blank = `${border("┃")}${" ".repeat(inner)}${border("┃")}`;
	const top = (): string => {
		if (!title) return `${border("┏")}${border("━".repeat(inner))}${border("┓")}`;
		const titlePlain = ` ${truncateToWidth(title, Math.max(1, inner - 2), "…")} `;
		const fill = Math.max(1, inner - visibleWidth(titlePlain));
		return `${border("┏")}${ansiGreen(titlePlain)}${border("━".repeat(fill))}${border("┓")}`;
	};
	const out = [top()];
	for (let i = 0; i < POPUP_PADDING_Y; i += 1) out.push(blank);
	for (const line of body) out.push(`${border("┃")}${" ".repeat(POPUP_PADDING_X)}${pad(line, contentWidth)}${" ".repeat(POPUP_PADDING_X)}${border("┃")}`);
	for (let i = 0; i < POPUP_PADDING_Y; i += 1) out.push(blank);
	out.push(`${border("┗")}${border("━".repeat(inner))}${border("┛")}`);
	return out.map((line) => truncateToWidth(line, width, ""));
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
	const top = (): string => {
		if (!title) return `${border("┏")}${border("━".repeat(inner))}${border("┓")}`;
		const titlePlain = ` ${truncateToWidth(title, Math.max(1, inner - 2), "…")} `;
		const fill = Math.max(1, inner - visibleWidth(titlePlain));
		return `${border("┏")}${theme.fg(color, titlePlain)}${border("━".repeat(fill))}${border("┓")}`;
	};
	return [
		top(),
		...lines.map((line) => `${border("┃")}${" ".repeat(PANEL_CARD_PADDING_X)}${pad(line, contentWidth)}${" ".repeat(PANEL_CARD_PADDING_X)}${border("┃")}`),
		`${border("┗")}${border("━".repeat(inner))}${border("┛")}`,
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

// Title-case each `+`-separated chunk so `alt+f` renders as `Alt+F`,
// matching pi-agents-tmux's mini dashboard hint formatting.
export function formatShortcutHint(shortcut: string): string {
	return shortcut
		.split("+")
		.map((part) => (part.length === 1 ? part.toUpperCase() : part.charAt(0).toUpperCase() + part.slice(1).toLowerCase()))
		.join("+");
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
		case "complete": return "✓";
		case "merged": return "✓";
		case "ready": return "●";
		case "merge-ready": return "▲";
		case "submitting": return "◆";
		case "prompting": return "?";
		case "waiting": return COG_GLYPH;
		case "cancelled": return "✗";
		case "aborted": return "✗";
		case "dead": return "×";
		default: return "·";
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
	return alive ? theme.fg("success", "●") : theme.fg("error", "●");
}

// Combined daemon health: dot + "daemon" label, optionally followed by a
// staleness suffix when the heartbeat is older than ~30s. Replaces the
// two-token `● daemon  ·  hb Xs` rendering so the header has one canonical
// daemon-health object instead of two stating the same fact.
export function daemonHealthChip(theme: Theme, alive: boolean, heartbeatAgeSec: number | undefined): string {
	if (!alive) return `${theme.fg("error", "●")} ${theme.fg("error", "daemon dead")}`;
	if (heartbeatAgeSec === undefined) return `${theme.fg("warning", "●")} ${theme.fg("warning", "daemon no-pulse")}`;
	if (heartbeatAgeSec >= 120) return `${theme.fg("error", "●")} ${theme.fg("error", `daemon stale ${formatAgeShort(heartbeatAgeSec)}`)}`;
	if (heartbeatAgeSec >= 30) return `${theme.fg("warning", "●")} ${theme.fg("warning", `daemon stale ${formatAgeShort(heartbeatAgeSec)}`)}`;
	return `${theme.fg("success", "●")} ${theme.fg("dim", "daemon")}`;
}

// Header chip rendered in place of `daemonHealthChip` when the master
// state has `terminated: true`. The daemon is intentionally stopped after
// `terminate.md § 5`; the alarming red "daemon dead" badge was the
// previous (wrong) signal in the post-completion view (issue #17).
export function sessionCompleteChip(theme: Theme): string {
	return `${theme.fg("success", "✔")} ${theme.fg("success", "session complete")}`;
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

/**
 * Standard popup search row + filter row — same pattern as
 * pi-extension-manager.
 */
export function searchRow(theme: Theme, search: string, width: number): string {
	return theme.bg("toolPendingBg", pad(` > ${search}${theme.inverse(" ")}`, width));
}

export function selectedRow(theme: Theme, line: string, width: number): string {
	return theme.bg("selectedBg", pad(line, width));
}
