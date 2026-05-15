import * as os from "node:os";
import { type Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { ansiGreen, ansiMagenta } from "../format.js";
import { paneExists } from "../pane.js";
import { readPaneRegistry } from "../tasks.js";
import {
	AGENTS_BROWSER_HEIGHT_RATIO,
	AGENTS_BROWSER_TAB,
	AGENTS_POPUP_FRAME_ROWS,
	AGENTS_POPUP_PADDING_X,
	AGENTS_POPUP_PADDING_Y,
	MONITOR_BROWSER_TAB,
	VSTACK_MODAL_LOCK_SYMBOL,
	type AgentBrowserLayout,
	type AgentBrowserTabDef,
	type AgentBrowserTabId,
	type AgentPaneStatus,
	type VstackModalLock,
} from "../types.js";

export function acquireVstackModalLock(): () => void {
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

export function agentInlineLine(text: string): string {
	return text.replace(/[\r\n]+/g, " ").replace(/\t/g, " ");
}

export function agentPad(text: string, width: number): string {
	const safeWidth = Math.max(0, width);
	const truncated = truncateToWidth(agentInlineLine(text), safeWidth, "");
	return `${truncated}${" ".repeat(Math.max(0, safeWidth - visibleWidth(truncated)))}`;
}

// After terminal/tmux resize events, stdin can occasionally deliver raw control
// bytes in chunks that `matchesKey()` does not normalize. Always honor ctrl+c
// if the byte is present anywhere in the input chunk so the popup cannot trap
// the session in raw-mode focus.
export function isAgentBrowserCancelInput(data: string): boolean {
	return data.includes("\x03") || matchesKey(data, "escape") || matchesKey(data, "ctrl+c");
}

export function compactAgentPath(filePath: string): string {
	const home = os.homedir();
	return filePath.startsWith(home) ? `~${filePath.slice(home.length)}` : filePath;
}

export function tabNext(current: AgentBrowserTabId, delta: number): AgentBrowserTabId {
	const tabs: AgentBrowserTabId[] = ["agents", "monitor"];
	const index = Math.max(0, tabs.indexOf(current));
	return tabs[(index + delta + tabs.length) % tabs.length]!;
}

export async function loadAgentPaneStatuses(runtimeRoot: string): Promise<Map<string, AgentPaneStatus>> {
	const registry = await readPaneRegistry(runtimeRoot);
	const entries = await Promise.all(
		Object.entries(registry).map(async ([agentName, entry]) => [agentName, { entry, live: await paneExists(entry.paneId) }] as const),
	);
	return new Map(entries);
}

export function agentFrameContentWidth(width: number): number {
	return Math.max(1, width - 2 - AGENTS_POPUP_PADDING_X * 2);
}

export function agentBrowserLayout(terminalRows: number): AgentBrowserLayout {
	const innerRows = Math.max(1, Math.floor(Math.max(1, terminalRows) * AGENTS_BROWSER_HEIGHT_RATIO) - AGENTS_POPUP_FRAME_ROWS);
	const bodyRows = Math.max(0, innerRows - 9);
	return {
		bodyRows,
		innerRows,
		listRows: Math.max(1, bodyRows - 3),
	};
}

export function agentDivider(width: number, theme: Theme): string {
	return theme.fg("dim", "─".repeat(Math.max(1, width)));
}

export function agentFrame(lines: string[], width: number, theme: Theme, fixedInnerRows = 30, title = ""): string[] {
	const safeWidth = Math.max(1, width);
	const inner = Math.max(1, safeWidth - 2);
	const contentWidth = agentFrameContentWidth(safeWidth);
	const border = (s: string) => theme.fg("borderAccent", s);
	let body = lines;
	if (body.length > fixedInnerRows) {
		const hidden = body.length - fixedInnerRows + 1;
		body = [...body.slice(0, Math.max(0, fixedInnerRows - 1)), theme.fg("dim", `↓ ${hidden} more line(s)`)].slice(0, fixedInnerRows);
	} else if (body.length < fixedInnerRows) {
		body = [...body, ...Array.from({ length: fixedInnerRows - body.length }, () => "")];
	}
	const blank = `${border("┃")}${" ".repeat(inner)}${border("┃")}`;
	const top = () => {
		if (!title) return `${border("┏")}${border("━".repeat(inner))}${border("┓")}`;
		const titlePlain = ` ${truncateToWidth(title, Math.max(1, inner - 2), "…")} `;
		const fill = Math.max(1, inner - visibleWidth(titlePlain));
		return `${border("┏")}${ansiGreen(titlePlain)}${border("━".repeat(fill))}${border("┓")}`;
	};
	const out = [top()];
	for (let i = 0; i < AGENTS_POPUP_PADDING_Y; i += 1) out.push(blank);
	for (const line of body) out.push(`${border("┃")}${" ".repeat(AGENTS_POPUP_PADDING_X)}${agentPad(line, contentWidth)}${" ".repeat(AGENTS_POPUP_PADDING_X)}${border("┃")}`);
	for (let i = 0; i < AGENTS_POPUP_PADDING_Y; i += 1) out.push(blank);
	out.push(`${border("┗")}${border("━".repeat(inner))}${border("┛")}`);
	return out.map((line) => truncateToWidth(agentInlineLine(line), safeWidth, ""));
}

export function agentActivePill(theme: Theme, label: string): string {
	return theme.fg("accent", theme.inverse(theme.bold(label)));
}

export function agentInactivePill(theme: Theme, label: string): string {
	return theme.bg("selectedBg", theme.fg("accent", label));
}

export function agentPaneTitle(theme: Theme, label: string, active: boolean): string {
	const padded = ` ${label} `;
	return active ? agentActivePill(theme, padded) : agentInactivePill(theme, padded);
}

export function agentEntityTitle(theme: Theme, label: string): string {
	return ansiMagenta(theme.bold(label));
}

export function renderAgentBrowserTabs(active: AgentBrowserTabId, width: number, theme: Theme): string {
	const tabs = [AGENTS_BROWSER_TAB, MONITOR_BROWSER_TAB];
	const partFor = (tab: AgentBrowserTabDef): string => {
		const label = ` ${truncateToWidth(tab.label, 18, "…")} `;
		if (tab.id === active) return agentActivePill(theme, label);
		return agentInactivePill(theme, label);
	};
	return truncateToWidth(tabs.map(partFor).join(" "), width, "");
}
