import type { Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { ansiGreen } from "./format.js";
import { frameGlyphs, glyphs } from "./glyphs.js";
import { POPUP_PADDING_X, POPUP_PADDING_Y, type ManagerTab, type TopTab } from "./types.js";

export function frameContentWidth(width: number): number {
	return Math.max(1, width - 2 - POPUP_PADDING_X * 2);
}

export function divider(width: number, theme: Theme): string {
	return theme.fg("dim", glyphs().line.repeat(Math.max(1, width)));
}

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

export function wrapDescription(text: string, width: number, theme: Theme, indent = ""): string[] {
	const indentWidth = visibleWidth(indent);
	const contentWidth = Math.max(1, width - indentWidth);
	return wrapLine(text, contentWidth).map((line) => `${indent}${theme.fg("muted", line)}`);
}

export function countBy<T>(items: T[], key: (item: T) => string): Record<string, number> {
	const out: Record<string, number> = {};
	for (const item of items) out[key(item)] = (out[key(item)] ?? 0) + 1;
	return out;
}

export function frame(lines: string[], width: number, theme: Theme, fixedInnerRows?: number, title = ""): string[] {
	const inner = Math.max(1, width - 2);
	const contentWidth = frameContentWidth(width);
	const border = (s: string) => theme.fg("borderAccent", s);
	let body = lines;
	if (fixedInnerRows !== undefined && body.length > fixedInnerRows) {
		const hidden = body.length - fixedInnerRows + 1;
		body = [...body.slice(0, Math.max(0, fixedInnerRows - 1)), theme.fg("dim", `↓ ${hidden} more line(s)`)].slice(0, fixedInnerRows);
	}
	const frameGlyph = frameGlyphs();
	const blank = `${border(frameGlyph.v)}${" ".repeat(inner)}${border(frameGlyph.v)}`;
	const top = () => {
		if (!title) return `${border(frameGlyph.tl)}${border(frameGlyph.h.repeat(inner))}${border(frameGlyph.tr)}`;
		const titlePlain = ` ${truncateToWidth(title, Math.max(1, inner - 2), glyphs().ellipsis)} `;
		const fill = Math.max(1, inner - visibleWidth(titlePlain));
		return `${border(frameGlyph.tl)}${ansiGreen(titlePlain)}${border(frameGlyph.h.repeat(fill))}${border(frameGlyph.tr)}`;
	};
	const out = [top()];
	for (let i = 0; i < POPUP_PADDING_Y; i += 1) out.push(blank);
	for (const line of body) out.push(`${border(frameGlyph.v)}${" ".repeat(POPUP_PADDING_X)}${pad(line, contentWidth)}${" ".repeat(POPUP_PADDING_X)}${border(frameGlyph.v)}`);
	for (let i = 0; i < POPUP_PADDING_Y; i += 1) out.push(blank);
	out.push(`${border(frameGlyph.bl)}${border(frameGlyph.h.repeat(inner))}${border(frameGlyph.br)}`);
	return out.map((line) => truncateToWidth(line, width, ""));
}

export function managerActivePill(theme: Theme, label: string): string {
	return theme.fg("accent", theme.inverse(theme.bold(label)));
}

export function managerInactivePill(theme: Theme, label: string): string {
	return theme.bg("selectedBg", theme.fg("accent", label));
}

export function managerPaneTitle(theme: Theme, label: string, active: boolean): string {
	const padded = ` ${label} `;
	return active ? managerActivePill(theme, padded) : managerInactivePill(theme, padded);
}

export function managerEntityTitle(theme: Theme, label: string): string {
	return theme.fg("accent", theme.bold(label));
}

export function managerSectionTitle(theme: Theme, label: string): string {
	return theme.fg("muted", theme.bold(label));
}

export function managerSelectedLine(theme: Theme, line: string, width: number): string {
	return theme.bg("selectedBg", pad(line, width));
}

export function managerMutedForSelection(theme: Theme, text: string, selected: boolean): string {
	return theme.fg(selected ? "text" : "dim", text);
}

export function renderTabBar(tabs: ManagerTab[], active: TopTab, width: number, theme: Theme): string {
	const safeWidth = Math.max(1, width);
	if (tabs.length === 0) return " ".repeat(safeWidth);
	const activeIndex = Math.max(0, tabs.findIndex((tab) => tab.id === active));
	const widths = tabs.map((tab) => visibleWidth(tab.label) + 2);
	const sliceWidth = (s: number, e: number): number => {
		let total = 0;
		for (let i = s; i < e; i += 1) total += widths[i]!;
		total += Math.max(0, e - s - 1); // single-space gaps between tabs
		total += s > 0 ? 2 : 0; // "‹ "
		total += e < tabs.length ? 2 : 0; // " ›"
		return total;
	};

	let start = activeIndex;
	let end = activeIndex + 1;
	let preferRight = true;
	while (start > 0 || end < tabs.length) {
		let progressed = false;
		const tryRight = (): boolean => {
			if (end < tabs.length && sliceWidth(start, end + 1) <= safeWidth) {
				end += 1;
				return true;
			}
			return false;
		};
		const tryLeft = (): boolean => {
			if (start > 0 && sliceWidth(start - 1, end) <= safeWidth) {
				start -= 1;
				return true;
			}
			return false;
		};
		if (preferRight) {
			if (tryRight()) progressed = true;
			if (tryLeft()) progressed = true;
		} else {
			if (tryLeft()) progressed = true;
			if (tryRight()) progressed = true;
		}
		if (!progressed) break;
		preferRight = !preferRight;
	}

	const cells = tabs.slice(start, end).map((tab) => {
		const label = ` ${tab.label} `;
		return tab.id === active ? managerActivePill(theme, label) : managerInactivePill(theme, label);
	});
	if (start > 0) cells.unshift(theme.fg("dim", "‹"));
	if (end < tabs.length) cells.push(theme.fg("dim", "›"));
	return pad(cells.join(" "), safeWidth);
}
