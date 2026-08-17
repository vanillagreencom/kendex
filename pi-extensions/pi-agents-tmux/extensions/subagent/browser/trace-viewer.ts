import { spawn } from "node:child_process";
import { type ExtensionContext, type Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth } from "@earendil-works/pi-tui";
import { ansiYellow, compactPath, divider, simpleFrame } from "../format.js";
import { shellQuote } from "../names.js";
import {
	TRACE_VIEWER_MAX_HEIGHT,
	TRACE_VIEWER_WIDTH,
	type TraceViewerItem,
	type TraceViewerState,
} from "../types.js";
import { renderTraceContentLine, renderTraceTabBar } from "./monitor-task-detail.js";

function traceViewerLines(state: TraceViewerState, width: number, rows: number, theme: Theme): string[] {
	const innerWidth = Math.max(1, width - 4);
	const frameRows = Math.max(8, rows);
	const item = state.items[state.selected] ?? state.items[0];
	const help = `${ansiYellow("tab/←→")} ${theme.fg("dim", "sections · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page")}${item?.path ? `${theme.fg("dim", " · ")}${ansiYellow("e")} ${theme.fg("dim", "editor")}` : ""}`;
	const tabs = renderTraceTabBar(state.items, state.selected, innerWidth, theme);
	const meta = [
		item?.ref ? theme.fg("accent", item.ref) : "",
		item?.agent ? theme.fg("muted", item.agent) : "",
		item?.status ? theme.fg(item.status === "completed" ? "success" : item.status === "failed" ? "error" : "warning", item.status) : "",
		item?.createdAt ? theme.fg("dim", item.createdAt) : "",
	].filter(Boolean).join(theme.fg("dim", " · "));
	const file = item?.path ? theme.fg("dim", `file ${compactPath(item.path, { maxChars: Math.max(24, innerWidth - 8) })}`) : "";
	const rawContent = (item?.text || "(empty)").split(/\r?\n/);
	const content = rawContent.flatMap((line) => renderTraceContentLine(line, item?.type, innerWidth, theme)).map((line) => truncateToWidth(line, innerWidth, ""));
	const fixedRowsInsideFrame = 8;
	const bodyRows = Math.max(1, frameRows - 2 - fixedRowsInsideFrame);
	const maxScroll = Math.max(0, content.length - bodyRows);
	state.scroll = Math.max(0, Math.min(state.scroll, maxScroll));
	const visible = content.slice(state.scroll, state.scroll + bodyRows);
	const footer = item?.path
		? theme.fg("dim", `${state.scroll + 1}-${Math.min(content.length, state.scroll + bodyRows)}/${content.length} · file`)
		: theme.fg("dim", `${state.scroll + 1}-${Math.min(content.length, state.scroll + bodyRows)}/${content.length}`);
	const fileBlock = file ? [file, divider(innerWidth, theme)] : [];
	const innerLines = [
		tabs,
		"",
		meta,
		...fileBlock,
		...(file ? [] : [divider(innerWidth, theme)]),
		...visible,
		divider(innerWidth, theme),
		footer,
		help,
	];
	while (innerLines.length < frameRows - 2) innerLines.splice(Math.max(0, innerLines.length - 2), 0, "");
	return simpleFrame(innerLines.slice(0, frameRows - 2), width, theme, state.title);
}

/**
 * Open the item's backing file in $VISUAL/$EDITOR. The popup owns the
 * terminal, so the editor gets its own tmux window; outside tmux (or with no
 * editor configured) the path is surfaced instead of fighting over the tty.
 */
export function openTraceItemInEditor(ctx: ExtensionContext, path: string | undefined): void {
	if (!path) return;
	const editor = process.env.VISUAL?.trim() || process.env.EDITOR?.trim();
	if (!editor) {
		ctx.ui.notify(`Set $VISUAL or $EDITOR to open ${path}`, "warning");
		return;
	}
	if (!process.env.TMUX) {
		ctx.ui.notify(`Not inside tmux — open manually: ${editor} ${path}`, "warning");
		return;
	}
	const child = spawn("tmux", ["new-window", "-n", "transcript", `${editor} ${shellQuote(path)}`], { detached: true, stdio: "ignore" });
	child.on("error", (error) => ctx.ui.notify(`Could not open editor window: ${error instanceof Error ? error.message : String(error)}`, "error"));
	child.unref();
}

export async function openTraceViewer(ctx: ExtensionContext, title: string, items: TraceViewerItem[]): Promise<void> {
	if (!ctx.hasUI) {
		ctx.ui.notify(title, "info");
		return;
	}
	const state: TraceViewerState = { items: items.length ? items : [{ label: "Empty", text: "No traces found." }], selected: 0, scroll: 0, title };
	await ctx.ui.custom<void>((tui, theme, _kb, done) => ({
		invalidate() {},
		handleInput(data: string) {
			const tracePageRows = Math.max(1, Math.min(30, Math.max(12, Math.floor(tui.terminal.rows * 0.72))) - 10);
			if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c")) return done();
			if (matchesKey(data, "up")) { state.scroll = Math.max(0, state.scroll - 1); tui.requestRender(); return; }
			if (matchesKey(data, "down")) { state.scroll += 1; tui.requestRender(); return; }
			if (matchesKey(data, "-") || matchesKey(data, "pageup" as any) || matchesKey(data, "page_up" as any)) { state.scroll = Math.max(0, state.scroll - tracePageRows); tui.requestRender(); return; }
			if (matchesKey(data, "=") || matchesKey(data, "pagedown" as any) || matchesKey(data, "page_down" as any)) { state.scroll += tracePageRows; tui.requestRender(); return; }
			if (matchesKey(data, "e")) { openTraceItemInEditor(ctx, (state.items[state.selected] ?? state.items[0])?.path); return; }
			if (matchesKey(data, "left")) { state.selected = (state.selected + state.items.length - 1) % state.items.length; state.scroll = 0; tui.requestRender(); return; }
			if (matchesKey(data, "right") || matchesKey(data, "tab")) { state.selected = (state.selected + 1) % state.items.length; state.scroll = 0; tui.requestRender(); return; }
		},
		render(width: number): string[] {
			const rows = Math.min(30, Math.max(12, Math.floor(tui.terminal.rows * 0.72)));
			const lines = traceViewerLines(state, width, rows, theme);
			return lines.slice(0, rows);
		},
	}), { overlay: true, overlayOptions: { anchor: "center", width: TRACE_VIEWER_WIDTH, maxHeight: TRACE_VIEWER_MAX_HEIGHT } });
}
