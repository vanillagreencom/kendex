import { getLanguageFromPath, highlightCode } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

import {
	ANSI_BG_RESET,
	ansiHasBackground,
	ansiPartsFromStyled,
	hasAnsi,
	padVisible,
	sgrClearsBackground,
	stripAnsi,
	terminalWidth,
	truncateAnsi,
	updateActiveAnsiStyle,
	visibleLength,
	visibleWidth,
	type AnsiParts,
} from "./ansi.js";
import {
	bashDiffRenderingEnabled,
	diffBackgroundEnabled,
	settingBoolean,
	settingNumber,
} from "./settings.js";
import { dot, glyphs } from "./glyphs.js";
import { borderMuted, stackPrefix, toolLabel, treeConnector } from "./theme.js";
import {
	makeEmpty,
	makeTruncatedLines,
	isGitDiffCommand,
	pendingStatusPrefix,
	type TruncatedLines,
} from "./text.js";

const DIFF_SPLIT_MIN_WIDTH = 132;
const DIFF_SPLIT_MIN_CODE_WIDTH = 24;
const DIFF_SPLIT_MAX_WRAP_LINES = 8;
const DIFF_SPLIT_MAX_WRAP_RATIO = 0.55;
const DIFF_LCS_CELL_LIMIT = 250_000;
const DIFF_CONTEXT_LINES = 3;
export const MAX_DIFF_INPUT_BYTES = 700 * 1024;
const DIFF_HIGHLIGHT_MAX_CHARS = 180_000;
export const DIFF_ADD_BG_TOKEN = "toolSuccessBg";
export const DIFF_DEL_BG_TOKEN = "toolErrorBg";
export const DIFF_WORD_BG_TOKEN = "selectedBg";
export const DIFF_ADD_BG_FALLBACK = "\x1b[48;2;24;58;38m";
export const DIFF_DEL_BG_FALLBACK = "\x1b[48;2;66;31;43m";
const WORD_DIFF_CELL_LIMIT = 32_000;
const WORD_DIFF_MIN_SIMILARITY = 0.2;

export type DiffKind = "ctx" | "add" | "del" | "sep";
export interface StructuredDiffLine {
	content: string;
	hunk?: number;
	newNum: number | null;
	oldNum: number | null;
	type: DiffKind;
}
export interface StructuredDiff {
	additions: number;
	chars: number;
	hunks?: number;
	lines: StructuredDiffLine[];
	path?: string;
	removals: number;
}

const themeDiffBgParts = new WeakMap<object, Map<string, AnsiParts>>();

function diffDisplayContent(content: string): string {
	return content.replace(/\t/g, "  ");
}

function languageForPath(path?: string): string | undefined {
	if (!path) return undefined;
	try {
		return getLanguageFromPath(path) as string | undefined;
	} catch {
		return undefined;
	}
}

function highlightDiffContent(content: string, path: string | undefined, theme: any, cwd?: string): string {
	const display = diffDisplayContent(content);
	if (!display || !settingBoolean("shikiDiffs", true, cwd)) return display;
	if (display.length > 5000) return display;
	const language = languageForPath(path);
	if (!language) return display;
	try {
		const highlighted = highlightCode(display, language);
		const lines = Array.isArray(highlighted) ? highlighted : String(highlighted).replace(/\r\n/g, "\n").split("\n");
		return lines[0] ?? display;
	} catch {
		return display;
	}
}

interface WordToken {
	end: number;
	start: number;
	text: string;
}

interface WordDiffRanges {
	newRanges: Array<[number, number]>;
	oldRanges: Array<[number, number]>;
	similarity: number;
}

function wordTokens(text: string): WordToken[] {
	const tokens: WordToken[] = [];
	const re = /\s+|[A-Za-z0-9_]+|[^\sA-Za-z0-9_]+/g;
	let match: RegExpExecArray | null;
	while ((match = re.exec(text))) tokens.push({ end: re.lastIndex, start: match.index, text: match[0] });
	return tokens;
}

function changedRanges(tokens: WordToken[], common: boolean[]): Array<[number, number]> {
	const ranges: Array<[number, number]> = [];
	let start: number | null = null;
	let end = 0;
	for (let i = 0; i < tokens.length; i++) {
		const token = tokens[i]!;
		if (!common[i] && token.text.trim().length > 0) {
			if (start === null) start = token.start;
			end = token.end;
		} else if (start !== null) {
			ranges.push([start, end]);
			start = null;
		}
	}
	if (start !== null) ranges.push([start, end]);
	return ranges;
}

function wordDiffRanges(oldText: string, newText: string): WordDiffRanges {
	const oldTokens = wordTokens(oldText);
	const newTokens = wordTokens(newText);
	if (oldTokens.length === 0 && newTokens.length === 0) return { newRanges: [], oldRanges: [], similarity: 1 };
	if (oldTokens.length * newTokens.length > WORD_DIFF_CELL_LIMIT) return { newRanges: [], oldRanges: [], similarity: 0 };
	const width = newTokens.length + 1;
	const table = new Uint16Array((oldTokens.length + 1) * (newTokens.length + 1));
	for (let i = oldTokens.length - 1; i >= 0; i--) {
		for (let j = newTokens.length - 1; j >= 0; j--) {
			table[i * width + j] = oldTokens[i]!.text === newTokens[j]!.text
				? table[(i + 1) * width + j + 1] + 1
				: Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
		}
	}
	const oldCommon = new Array(oldTokens.length).fill(false);
	const newCommon = new Array(newTokens.length).fill(false);
	let i = 0;
	let j = 0;
	let commonChars = 0;
	while (i < oldTokens.length && j < newTokens.length) {
		if (oldTokens[i]!.text === newTokens[j]!.text) {
			oldCommon[i] = true;
			newCommon[j] = true;
			commonChars += oldTokens[i]!.text.length;
			i++;
			j++;
		} else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) {
			i++;
		} else {
			j++;
		}
	}
	const maxChars = Math.max(oldText.length, newText.length, 1);
	return {
		newRanges: changedRanges(newTokens, newCommon),
		oldRanges: changedRanges(oldTokens, oldCommon),
		similarity: commonChars / maxChars,
	};
}

function styleRanges(text: string, ranges: Array<[number, number]>, baseStyle: (value: string) => string, highlightStyle: (value: string) => string): string {
	if (ranges.length === 0 || hasAnsi(text)) return baseStyle(text);
	const sorted = [...ranges].sort((a, b) => a[0] - b[0]);
	let out = "";
	let offset = 0;
	for (const [start, end] of sorted) {
		if (end <= offset || start >= text.length) continue;
		const safeStart = Math.max(offset, start);
		const safeEnd = Math.min(text.length, end);
		if (safeStart > offset) out += baseStyle(text.slice(offset, safeStart));
		out += highlightStyle(text.slice(safeStart, safeEnd));
		offset = safeEnd;
	}
	if (offset < text.length) out += baseStyle(text.slice(offset));
	return out;
}

function maybeBg(theme: any, token: string, text: string, enabled: boolean): string {
	return enabled ? theme.bg(token, text) : text;
}

function fallbackDiffBgOpen(token: string): string {
	if (token === DIFF_ADD_BG_TOKEN) return DIFF_ADD_BG_FALLBACK;
	if (token === DIFF_DEL_BG_TOKEN) return DIFF_DEL_BG_FALLBACK;
	return "";
}

function cacheThemeBgParts(theme: any, token: string): AnsiParts | undefined {
	const marker = "\uE000";
	if (!theme || (typeof theme !== "object" && typeof theme !== "function") || !theme.bg) return undefined;
	try {
		const parts = ansiPartsFromStyled(theme.bg(token, marker));
		if (!ansiHasBackground(parts.open)) return undefined;
		let cached = themeDiffBgParts.get(theme);
		if (!cached) {
			cached = new Map();
			themeDiffBgParts.set(theme, cached);
		}
		cached.set(token, parts);
		return parts;
	} catch {
		// Keep rendering readable if the active theme cannot provide this token.
	}
	return undefined;
}

function cachedThemeBgParts(theme: any, token: string): AnsiParts | undefined {
	if (!theme || (typeof theme !== "object" && typeof theme !== "function")) return undefined;
	return themeDiffBgParts.get(theme)?.get(token);
}

export function captureDiffBackgroundTheme(theme: any): void {
	cacheThemeBgParts(theme, DIFF_ADD_BG_TOKEN);
	cacheThemeBgParts(theme, DIFF_DEL_BG_TOKEN);
}

function bgParts(theme: any, token: string): AnsiParts {
	const live = cacheThemeBgParts(theme, token);
	if (live) return live;
	const cached = cachedThemeBgParts(theme, token);
	if (cached) return cached;
	const fallbackOpen = fallbackDiffBgOpen(token);
	if (fallbackOpen) return { open: fallbackOpen, close: ANSI_BG_RESET };
	return { open: "", close: "" };
}

function applyFullLineBg(theme: any, token: string, text: string, enabled: boolean): string {
	if (!enabled) return text;
	const { open, close } = bgParts(theme, token);
	if (!open) return text;
	const reapplied = text.replace(/\x1b\[[0-9;]*m/g, (code) => (sgrClearsBackground(code) ? `${code}${open}` : code));
	return `${open}${reapplied}${close}`;
}

function diffLineBgToken(line: StructuredDiffLine | null): string | undefined {
	if (line?.type === "add") return DIFF_ADD_BG_TOKEN;
	if (line?.type === "del") return DIFF_DEL_BG_TOKEN;
	return undefined;
}

function styleAnsiVisibleRanges(
	text: string,
	ranges: Array<[number, number]>,
	theme: any,
	fgToken: string,
	baseBgToken: string,
	highlightBgToken: string,
	useBackground = false,
): string {
	if (!hasAnsi(text)) {
		const base = (value: string) => maybeBg(theme, baseBgToken, theme.fg(fgToken, value), useBackground);
		const highlight = (value: string) => maybeBg(theme, highlightBgToken, theme.fg(fgToken, value), useBackground);
		return styleRanges(text, ranges, base, highlight);
	}

	const sorted = [...ranges].sort((a, b) => a[0] - b[0]);
	let rangeIndex = 0;
	let visibleIndex = 0;
	let activeStyle = "";
	let out = "";
	const ansiRe = /\x1b\[[0-9;]*m/g;

	function inHighlightRange(index: number): boolean {
		while (rangeIndex < sorted.length && index >= sorted[rangeIndex]![1]) rangeIndex++;
		const range = sorted[rangeIndex];
		return Boolean(range && index >= range[0] && index < range[1]);
	}

	function emitChunk(chunk: string, highlighted: boolean): void {
		if (!chunk) return;
		const bgToken = highlighted ? highlightBgToken : baseBgToken;
		const content = activeStyle ? chunk : theme.fg(fgToken, chunk);
		out += maybeBg(theme, bgToken, content, useBackground);
		if (activeStyle) out += activeStyle;
	}

	function emitPlain(plain: string): void {
		let chunk = "";
		let highlighted: boolean | undefined;
		for (let index = 0; index < plain.length; index++) {
			const nextHighlighted = inHighlightRange(visibleIndex);
			if (highlighted !== undefined && nextHighlighted !== highlighted) {
				emitChunk(chunk, highlighted);
				chunk = "";
			}
			highlighted = nextHighlighted;
			chunk += plain[index]!;
			visibleIndex++;
		}
		if (highlighted !== undefined) emitChunk(chunk, highlighted);
	}

	let offset = 0;
	let match: RegExpExecArray | null;
	while ((match = ansiRe.exec(text))) {
		emitPlain(text.slice(offset, match.index));
		out += match[0];
		activeStyle = updateActiveAnsiStyle(match[0]);
		offset = match.index + match[0].length;
	}
	emitPlain(text.slice(offset));
	return out;
}

function splitContentLines(text: string): string[] {
	if (!text) return [];
	const lines = text.replace(/\r\n/g, "\n").split("\n");
	if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
	return lines;
}

function diffOps(oldLines: string[], newLines: string[]): Array<{ text: string; type: "ctx" | "add" | "del" }> {
	let start = 0;
	while (start < oldLines.length && start < newLines.length && oldLines[start] === newLines[start]) start++;
	let oldEnd = oldLines.length - 1;
	let newEnd = newLines.length - 1;
	while (oldEnd >= start && newEnd >= start && oldLines[oldEnd] === newLines[newEnd]) {
		oldEnd--;
		newEnd--;
	}
	const ops: Array<{ text: string; type: "ctx" | "add" | "del" }> = [];
	for (let i = 0; i < start; i++) ops.push({ text: oldLines[i] ?? "", type: "ctx" });
	const oldMid = oldLines.slice(start, oldEnd + 1);
	const newMid = newLines.slice(start, newEnd + 1);
	if (oldMid.length * newMid.length > DIFF_LCS_CELL_LIMIT) {
		for (const text of oldMid) ops.push({ text, type: "del" });
		for (const text of newMid) ops.push({ text, type: "add" });
	} else {
		const m = oldMid.length;
		const n = newMid.length;
		const width = n + 1;
		const table = new Uint32Array((m + 1) * (n + 1));
		for (let i = m - 1; i >= 0; i--) {
			for (let j = n - 1; j >= 0; j--) {
				table[i * width + j] = oldMid[i] === newMid[j]
					? table[(i + 1) * width + j + 1] + 1
					: Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
			}
		}
		let i = 0;
		let j = 0;
		while (i < m && j < n) {
			if (oldMid[i] === newMid[j]) {
				ops.push({ text: oldMid[i] ?? "", type: "ctx" });
				i++;
				j++;
			} else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) {
				ops.push({ text: oldMid[i] ?? "", type: "del" });
				i++;
			} else {
				ops.push({ text: newMid[j] ?? "", type: "add" });
				j++;
			}
		}
		while (i < m) ops.push({ text: oldMid[i++] ?? "", type: "del" });
		while (j < n) ops.push({ text: newMid[j++] ?? "", type: "add" });
	}
	for (let i = oldEnd + 1; i < oldLines.length; i++) ops.push({ text: oldLines[i] ?? "", type: "ctx" });
	return ops;
}

export function hiddenDiffLine(count: number): StructuredDiffLine {
	return {
		content: count > 0 ? `… ${count} unchanged line${count === 1 ? "" : "s"} …` : "…",
		newNum: null,
		oldNum: null,
		type: "sep",
	};
}

export function assignHunkNumbers(lines: StructuredDiffLine[]): { hunks: number; lines: StructuredDiffLine[] } {
	let hunk = 0;
	let inHunk = false;
	const numbered = lines.map((line) => {
		if (line.type === "sep") {
			inHunk = false;
			return { ...line, hunk: undefined };
		}
		if (line.type === "add" || line.type === "del") {
			if (!inHunk) {
				hunk++;
				inHunk = true;
			}
			return { ...line, hunk };
		}
		return inHunk ? { ...line, hunk } : line;
	});
	return { hunks: hunk, lines: numbered };
}

export function countStructuredHunks(lines: StructuredDiffLine[]): number {
	const assigned = assignHunkNumbers(lines);
	return assigned.hunks;
}

function hiddenHunksAfter(allRows: StructuredDiffLine[], shownRows: StructuredDiffLine[]): number {
	const shown = new Set(shownRows.map((line) => line.hunk).filter((hunk): hunk is number => typeof hunk === "number"));
	const hidden = new Set(allRows.slice(shownRows.length).map((line) => line.hunk).filter((hunk): hunk is number => typeof hunk === "number"));
	let count = 0;
	for (const hunk of hidden) if (!shown.has(hunk)) count++;
	return count;
}

function compactStructuredDiffLines(lines: StructuredDiffLine[], contextLines = DIFF_CONTEXT_LINES): StructuredDiffLine[] {
	const changed = lines
		.map((line, index) => (line.type === "add" || line.type === "del" ? index : -1))
		.filter((index) => index >= 0);
	if (changed.length === 0) return lines;

	const ranges: Array<{ end: number; start: number }> = [];
	for (const index of changed) {
		const start = Math.max(0, index - contextLines);
		const end = Math.min(lines.length - 1, index + contextLines);
		const previous = ranges[ranges.length - 1];
		if (!previous || start > previous.end + 1) ranges.push({ start, end });
		else previous.end = Math.max(previous.end, end);
	}

	const compacted: StructuredDiffLine[] = [];
	let previousEnd = -1;
	for (const range of ranges) {
		const hidden = range.start - previousEnd - 1;
		if (hidden > 0) compacted.push(hiddenDiffLine(hidden));
		compacted.push(...lines.slice(range.start, range.end + 1));
		previousEnd = range.end;
	}
	const trailingHidden = lines.length - previousEnd - 1;
	if (trailingHidden > 0) compacted.push(hiddenDiffLine(trailingHidden));
	return compacted;
}

export function buildStructuredDiff(oldText: string, newText: string): StructuredDiff {
	const ops = diffOps(splitContentLines(oldText), splitContentLines(newText));
	let oldNum = 1;
	let newNum = 1;
	let additions = 0;
	let removals = 0;
	const lines: StructuredDiffLine[] = [];
	for (const op of ops) {
		if (op.type === "ctx") {
			lines.push({ content: op.text, newNum, oldNum, type: "ctx" });
			oldNum++;
			newNum++;
		} else if (op.type === "del") {
			lines.push({ content: op.text, newNum: null, oldNum, type: "del" });
			oldNum++;
			removals++;
		} else {
			lines.push({ content: op.text, newNum, oldNum: null, type: "add" });
			newNum++;
			additions++;
		}
	}
	const numbered = assignHunkNumbers(compactStructuredDiffLines(lines));
	return { additions, chars: oldText.length + newText.length, hunks: numbered.hunks, lines: numbered.lines, removals };
}

function diffStatBar(additions: number, removals: number, theme: any, cwd?: string): string {
	const total = additions + removals;
	if (total <= 0) return "";
	const slots = Math.max(6, Math.min(18, Math.ceil(total / 3)));
	let addSlots = Math.round((additions / total) * slots);
	if (additions > 0 && addSlots === 0) addSlots = 1;
	if (removals > 0 && addSlots === slots) addSlots = slots - 1;
	const delSlots = slots - addSlots;
	const bar = glyphs(cwd).line;
	return `${theme.fg("dim", "[")}${theme.fg("toolDiffAdded", bar.repeat(addSlots))}${theme.fg("toolDiffRemoved", bar.repeat(delSlots))}${theme.fg("dim", "]")}`;
}

export function diffSummary(diff: StructuredDiff, theme: any, cwd?: string): string {
	const parts: string[] = [];
	if (diff.additions > 0) parts.push(theme.fg("success", `+${diff.additions}`));
	if (diff.removals > 0) parts.push(theme.fg("error", `-${diff.removals}`));
	if (parts.length === 0) return theme.fg("muted", "no changes");
	const bar = diffStatBar(diff.additions, diff.removals, theme, cwd);
	const hunks = diff.hunks ?? countStructuredHunks(diff.lines);
	let summary = `${parts.join(" ")}${bar ? ` ${bar}` : ""}`;
	if (settingBoolean("showDiffHunkMeta", true, cwd) && hunks > 0) summary += theme.fg("dim", `${dot(cwd)}${hunks} hunk${hunks === 1 ? "" : "s"}`);
	return summary;
}

function colorDiffText(line: StructuredDiffLine, text: string, theme: any, ranges: Array<[number, number]> = [], cwd?: string): string {
	if (line.type === "sep") return theme.fg("dim", text);
	if (line.type === "ctx") return hasAnsi(text) ? text : theme.fg("toolDiffContext", text);

	const fgToken = line.type === "add" ? "toolDiffAdded" : "toolDiffRemoved";
	const bgToken = line.type === "add" ? DIFF_ADD_BG_TOKEN : DIFF_DEL_BG_TOKEN;
	return styleAnsiVisibleRanges(text, ranges, theme, fgToken, bgToken, DIFF_WORD_BG_TOKEN, diffBackgroundEnabled(cwd));
}

function formatNum(value: number | null, width: number): string {
	return value === null ? " ".repeat(width) : `${" ".repeat(Math.max(0, width - String(value).length))}${value}`;
}

function lineWordRanges(line: StructuredDiffLine, mate: StructuredDiffLine | null, cwd?: string): Array<[number, number]> {
	if (!mate || !settingBoolean("wordDiffHighlights", true, cwd)) return [];
	if (!((line.type === "del" && mate.type === "add") || (line.type === "add" && mate.type === "del"))) return [];
	const oldText = diffDisplayContent(line.type === "del" ? line.content : mate.content);
	const newText = diffDisplayContent(line.type === "add" ? line.content : mate.content);
	const ranges = wordDiffRanges(oldText, newText);
	if (ranges.similarity < WORD_DIFF_MIN_SIMILARITY) return [];
	return line.type === "del" ? ranges.oldRanges : ranges.newRanges;
}

function highlightedLineBody(line: StructuredDiffLine, theme: any, path: string | undefined, cwd?: string): string {
	if (line.type === "sep") return (line.content || " ").replaceAll("…", glyphs(cwd).ellipsis).replaceAll(" · ", glyphs(cwd).dot);
	return highlightDiffContent(line.content, path, theme, cwd) || " ";
}

function diffFrame(cwd?: string): { bl: string; br: string; h: string; joint: string; tl: string; tm: string; tr: string; v: string } {
	if (glyphs(cwd).line === "-") return { bl: "+", br: "+", h: "-", joint: "+", tl: "+", tm: "+", tr: "+", v: "|" };
	return { bl: "└", br: "┘", h: "─", joint: "┴", tl: "┌", tm: "┬", tr: "┐", v: "│" };
}

function renderUnifiedLine(
	line: StructuredDiffLine,
	width: number,
	numWidth: number,
	theme: any,
	path: string | undefined,
	cwd: string | undefined,
	ranges: Array<[number, number]> = [],
): string {
	const sign = line.type === "add" ? "+" : line.type === "del" ? "-" : " ";
	const signToken = line.type === "add" ? "toolDiffAdded" : line.type === "del" ? "toolDiffRemoved" : "toolDiffContext";
	const gutter = `${theme.fg("muted", `${formatNum(line.oldNum, numWidth)} ${formatNum(line.newNum, numWidth)}`)} ${theme.fg(signToken, sign)} `;
	const contentWidth = Math.max(10, width - visibleLength(gutter));
	const rendered = `${gutter}${truncateAnsi(colorDiffText(line, highlightedLineBody(line, theme, path, cwd), theme, ranges, cwd), contentWidth)}`;
	return padVisible(rendered, width);
}

function renderUnifiedDiff(diff: StructuredDiff, rows: StructuredDiffLine[], width: number, theme: any, path?: string, cwd?: string): string[] {
	const tableWidth = Math.max(40, width);
	const maxNum = Math.max(1, ...diff.lines.map((line) => Math.max(line.oldNum ?? 0, line.newNum ?? 0)));
	const numWidth = Math.max(2, String(maxNum).length);
	const frame = diffFrame(cwd);
	const leftBorder = borderMuted(theme, frame.v);
	const rightBorder = borderMuted(theme, frame.v);
	const cellWidth = Math.max(1, tableWidth - visibleLength(leftBorder) - visibleLength(rightBorder));
	const contentWidth = Math.max(1, cellWidth - 2);
	const ruleSegment = borderMuted(theme, frame.h.repeat(Math.max(1, cellWidth)));
	const out: string[] = [`${borderMuted(theme, frame.tl)}${ruleSegment}${borderMuted(theme, frame.tr)}`];
	const pushLine = (line: StructuredDiffLine, renderedLine: string) => {
		const cell = ` ${padVisible(renderedLine, contentWidth)} `;
		const bgToken = diffLineBgToken(line);
		out.push(`${leftBorder}${bgToken ? applyFullLineBg(theme, bgToken, cell, diffBackgroundEnabled(cwd)) : cell}${rightBorder}`);
	};
	let index = 0;
	while (index < rows.length) {
		const line = rows[index]!;
		if (line.type === "ctx" || line.type === "sep") {
			pushLine(line, renderUnifiedLine(line, contentWidth, numWidth, theme, path ?? diff.path, cwd));
			index++;
			continue;
		}
		const dels: StructuredDiffLine[] = [];
		const adds: StructuredDiffLine[] = [];
		while (index < rows.length && rows[index]!.type === "del") dels.push(rows[index++]!);
		while (index < rows.length && rows[index]!.type === "add") adds.push(rows[index++]!);
		const count = Math.max(dels.length, adds.length);
		for (let i = 0; i < count; i++) {
			const del = dels[i];
			const add = adds[i];
			if (del) pushLine(del, renderUnifiedLine(del, contentWidth, numWidth, theme, path ?? diff.path, cwd, lineWordRanges(del, add ?? null, cwd)));
			if (add) pushLine(add, renderUnifiedLine(add, contentWidth, numWidth, theme, path ?? diff.path, cwd, lineWordRanges(add, del ?? null, cwd)));
		}
	}
	out.push(`${borderMuted(theme, frame.bl)}${ruleSegment}${borderMuted(theme, frame.br)}`);
	return out;
}

function pairDiffRows(rows: StructuredDiffLine[]): Array<{ left: StructuredDiffLine | null; right: StructuredDiffLine | null }> {
	const paired: Array<{ left: StructuredDiffLine | null; right: StructuredDiffLine | null }> = [];
	let index = 0;
	while (index < rows.length) {
		const line = rows[index]!;
		if (line.type === "ctx" || line.type === "sep") {
			paired.push({ left: line, right: line });
			index++;
			continue;
		}
		const dels: StructuredDiffLine[] = [];
		const adds: StructuredDiffLine[] = [];
		while (index < rows.length && rows[index]!.type === "del") dels.push(rows[index++]!);
		while (index < rows.length && rows[index]!.type === "add") adds.push(rows[index++]!);
		const count = Math.max(dels.length, adds.length);
		for (let i = 0; i < count; i++) paired.push({ left: dels[i] ?? null, right: adds[i] ?? null });
	}
	return paired;
}

function renderDiffHalf(
	line: StructuredDiffLine | null,
	side: "old" | "new",
	width: number,
	numWidth: number,
	theme: any,
	path: string | undefined,
	cwd: string | undefined,
	ranges: Array<[number, number]> = [],
): string {
	if (!line) return " ".repeat(width);
	const num = side === "old" ? line.oldNum : line.newNum;
	const sign = line.type === "add" ? "+" : line.type === "del" ? "-" : " ";
	const body = highlightedLineBody(line, theme, path, cwd);
	const prefix = `${formatNum(num, numWidth)} ${sign} `;
	const raw = `${prefix}${body}`;
	const shiftedRanges = ranges.map(([start, end]): [number, number] => [start + prefix.length, end + prefix.length]);
	return padVisible(truncateAnsi(colorDiffText(line, raw, theme, shiftedRanges, cwd), width), width);
}

function shouldUseSplitDiff(diff: StructuredDiff, rows: StructuredDiffLine[], width: number): boolean {
	if (width < DIFF_SPLIT_MIN_WIDTH) return false;
	const maxNum = Math.max(1, ...diff.lines.map((line) => Math.max(line.oldNum ?? 0, line.newNum ?? 0)));
	const numWidth = Math.max(2, String(maxNum).length);
	const innerWidth = Math.max(2, width - 3); // left border + center divider + right border
	const half = Math.max(24, Math.floor(innerWidth / 2));
	const codeWidth = half - 2 - numWidth - 3; // inner cell padding + number/sign prefix
	if (codeWidth < DIFF_SPLIT_MIN_CODE_WIDTH) return false;
	let contentLines = 0;
	let wrapCandidates = 0;
	for (const line of rows) {
		if (line.type === "sep") continue;
		contentLines++;
		if (visibleLength(diffDisplayContent(line.content)) > codeWidth) wrapCandidates++;
	}
	if (contentLines === 0) return true;
	if (wrapCandidates >= DIFF_SPLIT_MAX_WRAP_LINES) return false;
	return wrapCandidates / contentLines < DIFF_SPLIT_MAX_WRAP_RATIO;
}

function renderDiffCell(
	line: StructuredDiffLine | null,
	side: "old" | "new",
	cellWidth: number,
	numWidth: number,
	theme: any,
	path: string | undefined,
	cwd: string | undefined,
	ranges: Array<[number, number]> = [],
): string {
	const contentWidth = Math.max(1, cellWidth - 2);
	const cell = ` ${renderDiffHalf(line, side, contentWidth, numWidth, theme, path, cwd, ranges)} `;
	const bgToken = diffLineBgToken(line);
	return bgToken ? applyFullLineBg(theme, bgToken, padVisible(cell, cellWidth), diffBackgroundEnabled(cwd)) : cell;
}

function renderSplitDiff(diff: StructuredDiff, rows: StructuredDiffLine[], width: number, theme: any, path?: string, cwd?: string): string[] {
	const tableWidth = Math.max(DIFF_SPLIT_MIN_WIDTH, width);
	const maxNum = Math.max(1, ...diff.lines.map((line) => Math.max(line.oldNum ?? 0, line.newNum ?? 0)));
	const numWidth = Math.max(2, String(maxNum).length);
	const frame = diffFrame(cwd);
	const leftBorder = borderMuted(theme, frame.v);
	const divider = borderMuted(theme, frame.v);
	const rightBorder = borderMuted(theme, frame.v);
	const innerWidth = Math.max(2, tableWidth - visibleLength(leftBorder) - visibleLength(divider) - visibleLength(rightBorder));
	const leftCellWidth = Math.max(1, Math.floor(innerWidth / 2));
	const rightCellWidth = Math.max(1, innerWidth - leftCellWidth);
	const ruleSegment = (width: number) => borderMuted(theme, frame.h.repeat(Math.max(1, width)));
	const topRule = `${borderMuted(theme, frame.tl)}${ruleSegment(leftCellWidth)}${borderMuted(theme, frame.tm)}${ruleSegment(rightCellWidth)}${borderMuted(theme, frame.tr)}`;
	const bottomRule = `${borderMuted(theme, frame.bl)}${ruleSegment(leftCellWidth)}${borderMuted(theme, frame.joint)}${ruleSegment(rightCellWidth)}${borderMuted(theme, frame.br)}`;
	const out = [topRule];
	for (const pair of pairDiffRows(rows)) {
		const leftRanges = pair.left && pair.right ? lineWordRanges(pair.left, pair.right, cwd) : [];
		const rightRanges = pair.left && pair.right ? lineWordRanges(pair.right, pair.left, cwd) : [];
		out.push(`${leftBorder}${renderDiffCell(pair.left, "old", leftCellWidth, numWidth, theme, path ?? diff.path, cwd, leftRanges)}${divider}${renderDiffCell(pair.right, "new", rightCellWidth, numWidth, theme, path ?? diff.path, cwd, rightRanges)}${rightBorder}`);
	}
	out.push(bottomRule);
	return out;
}

function configuredDiffRowLimit(expanded: boolean, cwd?: string): number | null {
	const fallbackLimit = expanded ? 4000 : 24;
	const configuredLimit = Math.floor(settingNumber(expanded ? "diffExpandedLines" : "diffPreviewLines", fallbackLimit, cwd));
	return expanded && configuredLimit <= 0 ? null : Math.max(4, configuredLimit);
}


function collapsedDiffHint(remainingLines: number, hiddenHunks: number, expanded: boolean, shown: number, total: number, width = terminalWidth(), cwd?: string): string {
	const g = glyphs(cwd);
	const candidates = expanded
		? [
			`${g.ellipsis} ${remainingLines} more diff lines${hiddenHunks > 0 ? `${g.dot}${hiddenHunks} more hunks` : ""}${g.dot}UI cap ${shown}/${total}`,
			`${g.ellipsis} ${remainingLines} more lines${hiddenHunks > 0 ? `${g.dot}${hiddenHunks} hunks` : ""}`,
			`${g.ellipsis} +${remainingLines}${hiddenHunks > 0 ? `${g.dot}+${hiddenHunks}h` : ""}`,
			g.ellipsis,
		]
		: [
			`${g.ellipsis} ${remainingLines} more diff lines${hiddenHunks > 0 ? `${g.dot}${hiddenHunks} more hunks` : ""}${g.dot}ctrl+o to expand`,
			`${g.ellipsis} ${remainingLines} more lines${hiddenHunks > 0 ? `${g.dot}${hiddenHunks} hunks` : ""}`,
			`${g.ellipsis} +${remainingLines}${hiddenHunks > 0 ? `${g.dot}+${hiddenHunks}h` : ""}`,
			g.ellipsis,
		];
	for (const candidate of candidates) if (visibleWidth(candidate) <= width) return candidate;
	return g.ellipsis;
}

export function renderStructuredDiff(diff: StructuredDiff, theme: any, expanded: boolean, cwd?: string, rowLimit?: number | null, path?: string, widthOffset = 0): string {
	if (diff.additions === 0 && diff.removals === 0) return theme.fg("muted", "no changes");
	const width = Math.max(40, terminalWidth(cwd) - Math.max(0, widthOffset));
	const configuredLimit = rowLimit === undefined ? configuredDiffRowLimit(expanded, cwd) : rowLimit;
	const maxRows = configuredLimit === null ? diff.lines.length : Math.max(1, configuredLimit);
	const rows = diff.lines.slice(0, maxRows);
	const useSplit = settingBoolean("splitDiffs", true, cwd) && shouldUseSplitDiff(diff, rows, width);
	const rendered = useSplit ? renderSplitDiff(diff, rows, width, theme, path ?? diff.path, cwd) : renderUnifiedDiff(diff, rows, width, theme, path ?? diff.path, cwd);
	const remaining = diff.lines.length - rows.length;
	if (remaining > 0) rendered.push(theme.fg("dim", collapsedDiffHint(remaining, hiddenHunksAfter(diff.lines, rows), expanded, rows.length, diff.lines.length, width, cwd)));
	return rendered.join("\n");
}

interface UnifiedDiffFile {
	diff: StructuredDiff;
	path: string;
}

interface UnifiedDiffBuilder {
	additions: number;
	chars: number;
	hunkCount: number;
	lines: StructuredDiffLine[];
	newHunkEnd: number | null;
	newPath?: string;
	oldHunkEnd: number | null;
	oldPath?: string;
	path: string;
	removals: number;
	sawHunk: boolean;
}

function splitGitHeaderPaths(rest: string): string[] {
	const paths: string[] = [];
	const tokenRe = /"((?:\\.|[^"])*)"|(\S+)/g;
	let match: RegExpExecArray | null;
	while ((match = tokenRe.exec(rest))) {
		const raw = match[1] ?? match[2] ?? "";
		if (!raw) continue;
		if (match[1] !== undefined) {
			try {
				paths.push(JSON.parse(`"${raw}"`));
			} catch {
				paths.push(raw.replace(/\\"/g, "\"").replace(/\\\\/g, "\\"));
			}
		} else {
			paths.push(raw);
		}
	}
	return paths;
}

function cleanDiffPath(raw: string): string {
	let path = raw.trim();
	if (!path || path === "/dev/null") return path;
	if ((path.startsWith("a/") || path.startsWith("b/")) && path.length > 2) path = path.slice(2);
	return path;
}

function diffPathFromHeader(line: string): string {
	const value = line.replace(/^(?:---|\+\+\+)\s+/, "").trim().split(/\t/)[0] ?? "";
	return cleanDiffPath(value);
}

function displayUnifiedDiffPath(path: string, oldPath?: string, newPath?: string): string {
	const preferred = newPath && newPath !== "/dev/null" ? newPath : oldPath && oldPath !== "/dev/null" ? oldPath : path;
	return preferred || "diff";
}

function parseHunkHeader(line: string): { newCount: number; newStart: number; oldCount: number; oldStart: number } | null {
	const match = line.match(/^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@/);
	if (!match) return null;
	return {
		oldStart: Number.parseInt(match[1]!, 10),
		oldCount: match[2] === undefined ? 1 : Number.parseInt(match[2], 10),
		newStart: Number.parseInt(match[3]!, 10),
		newCount: match[4] === undefined ? 1 : Number.parseInt(match[4], 10),
	};
}

export function parseUnifiedDiffOutput(output: string): UnifiedDiffFile[] | null {
	const lines = stripAnsi(output).replace(/\r\n/g, "\n").split("\n");
	const files: UnifiedDiffFile[] = [];
	let current = null as UnifiedDiffBuilder | null;

	function start(path = "diff") {
		finish();
		current = { additions: 0, chars: 0, hunkCount: 0, lines: [], newHunkEnd: null, oldHunkEnd: null, path, removals: 0, sawHunk: false };
	}

	function finish() {
		if (!current) return;
		if (current.sawHunk && (current.additions > 0 || current.removals > 0)) {
			files.push({
				diff: { additions: current.additions, chars: current.chars || output.length, hunks: current.hunkCount || countStructuredHunks(current.lines), lines: current.lines, path: displayUnifiedDiffPath(current.path, current.oldPath, current.newPath), removals: current.removals },
				path: displayUnifiedDiffPath(current.path, current.oldPath, current.newPath),
			});
		}
		current = null;
	}

	let index = 0;
	while (index < lines.length) {
		const line = lines[index] ?? "";
		if (line.startsWith("diff --git ")) {
			const paths = splitGitHeaderPaths(line.slice("diff --git ".length)).map(cleanDiffPath);
			start(paths[1] || paths[0] || "diff");
			index++;
			continue;
		}
		if (!current && line.startsWith("--- ") && (lines[index + 1] ?? "").startsWith("+++ ")) start(diffPathFromHeader(lines[index + 1] ?? line));
		if (current && line.startsWith("--- ")) {
			current.oldPath = diffPathFromHeader(line);
			index++;
			continue;
		}
		if (current && line.startsWith("+++ ")) {
			current.newPath = diffPathFromHeader(line);
			current.path = displayUnifiedDiffPath(current.path, current.oldPath, current.newPath);
			index++;
			continue;
		}
		const hunk = current ? parseHunkHeader(line) : null;
		if (!current || !hunk) {
			index++;
			continue;
		}

		if (current.sawHunk && current.oldHunkEnd !== null && current.newHunkEnd !== null) {
			const hidden = Math.max(hunk.oldStart - current.oldHunkEnd - 1, hunk.newStart - current.newHunkEnd - 1);
			if (hidden > 0) current.lines.push(hiddenDiffLine(hidden));
		}
		current.sawHunk = true;
		current.hunkCount++;
		const hunkNumber = current.hunkCount;
		let oldLine = hunk.oldStart;
		let newLine = hunk.newStart;
		let oldConsumed = 0;
		let newConsumed = 0;
		index++;
		while (index < lines.length && (oldConsumed < hunk.oldCount || newConsumed < hunk.newCount)) {
			const raw = lines[index] ?? "";
			if (raw.startsWith("\\ No newline at end of file")) {
				index++;
				continue;
			}
			const marker = raw[0];
			const content = raw.slice(1);
			if (marker === " ") {
				current.lines.push({ content, hunk: hunkNumber, newNum: newLine, oldNum: oldLine, type: "ctx" });
				oldLine++;
				newLine++;
				oldConsumed++;
				newConsumed++;
			} else if (marker === "-") {
				current.lines.push({ content, hunk: hunkNumber, newNum: null, oldNum: oldLine, type: "del" });
				oldLine++;
				oldConsumed++;
				current.removals++;
			} else if (marker === "+") {
				current.lines.push({ content, hunk: hunkNumber, newNum: newLine, oldNum: null, type: "add" });
				newLine++;
				newConsumed++;
				current.additions++;
			} else {
				break;
			}
			current.chars += content.length;
			index++;
		}
		current.oldHunkEnd = oldLine - 1;
		current.newHunkEnd = newLine - 1;
	}
	finish();
	return files.length > 0 ? files : null;
}

export function shouldRenderBashDiffsForCommand(args: any, cwd?: string): boolean {
	return isGitDiffCommand(args?.command) ? settingBoolean("renderGitDiffCommandDiffs", false, cwd) : bashDiffRenderingEnabled(cwd);
}

function outputContainsUnifiedDiff(output: string): boolean {
	return Boolean(parseUnifiedDiffOutput(output)?.length);
}

export function suppressReadOnlyBashDiffOutput(args: any, output: string, cwd?: string): boolean {
	return !shouldRenderBashDiffsForCommand(args, cwd) && outputContainsUnifiedDiff(output);
}

export function renderBashDiffOutput(output: string, theme: any, expanded: boolean, cwd?: string, enabled = bashDiffRenderingEnabled(cwd)): string | null {
	if (!enabled) return null;
	const files = parseUnifiedDiffOutput(output);
	if (!files?.length) return null;
	const totalAdditions = files.reduce((sum, file) => sum + file.diff.additions, 0);
	const totalRemovals = files.reduce((sum, file) => sum + file.diff.removals, 0);
	const totalLines = files.reduce((sum, file) => sum + file.diff.lines.length, 0);
	const totalHunks = files.reduce((sum, file) => sum + (file.diff.hunks ?? countStructuredHunks(file.diff.lines)), 0);
	let remainingRows = configuredDiffRowLimit(expanded, cwd);
	const singleFile = files.length === 1;
	const rendered: string[] = [
		singleFile
			? `${toolLabel(theme, "Diff ")}${theme.fg("accent", files[0]!.path)} ${diffSummary(files[0]!.diff, theme, cwd)}`
			: `${toolLabel(theme, "Diff ")}${theme.fg("muted", `${files.length} files`)} ${diffSummary({ additions: totalAdditions, chars: output.length, hunks: totalHunks, lines: [], removals: totalRemovals }, theme, cwd)}`,
	];
	let renderedFiles = 0;
	for (const file of files) {
		if (remainingRows !== null && remainingRows <= 0) break;
		// For multi-file diffs, keep per-file summaries under the aggregate header
		// with a blank separator before each file so file boundaries are obvious.
		// For one-file diffs, the top line already has path/stat/hunk metadata, so
		// avoid repeating the same summary directly above the table.
		if (!singleFile) rendered.push("", `${theme.fg("accent", file.path)} ${diffSummary(file.diff, theme, cwd)}`);
		const fileLimit = remainingRows === null ? null : remainingRows;
		const diffText = renderStructuredDiff(file.diff, theme, expanded, cwd, fileLimit, file.path);
		// Keep the actual split/unified table flush with the Bash diff block. Prefixing
		// every table row with a tree stem made git diff tables look oddly indented
		// and could overflow by the stem width on wide terminals.
		rendered.push(...diffText.split(/\r?\n/));
		renderedFiles++;
		if (remainingRows !== null) remainingRows -= Math.min(file.diff.lines.length, fileLimit ?? file.diff.lines.length);
	}
	const hiddenFiles = files.length - renderedFiles;
	if (hiddenFiles > 0) rendered.push(theme.fg("muted", `… ${hiddenFiles} more file diff${hiddenFiles === 1 ? "" : "s"}${expanded ? ` · UI cap ${Math.max(0, renderedFiles)}/${files.length}` : " · ctrl+o to expand"}`));
	else if (remainingRows !== null && totalLines > configuredDiffRowLimit(expanded, cwd)!) {
		rendered.push(theme.fg("muted", expanded ? "diff UI cap reached" : "ctrl+o to expand"));
	}
	return rendered.join("\n");
}

export function readTextForDiff(pathValue: unknown, cwd: string): string | undefined {
	if (typeof pathValue !== "string" || !pathValue.trim()) return undefined;
	const target = resolve(cwd, pathValue);
	try {
		if (!existsSync(target)) return undefined;
		const text = readFileSync(target, "utf8");
		return Buffer.byteLength(text, "utf8") <= MAX_DIFF_INPUT_BYTES ? text : undefined;
	} catch {
		return undefined;
	}
}

export function attachDiffDetails(result: any, before: string | undefined, after: string | undefined, path?: string): any {
	if (before === undefined && after === undefined) return result;
	const oldText = before ?? "";
	const newText = after ?? "";
	if (oldText === newText) return result;
	const diff = { ...buildStructuredDiff(oldText, newText), path };
	const extra = { vstackDiff: diff, vstackDiffWasNewFile: before === undefined };
	result.details = result?.details && typeof result.details === "object" ? { ...result.details, ...extra } : extra;
	return result;
}

export function editOperationsFromArgs(args: any): Array<{ oldText: string; newText: string }> {
	if (Array.isArray(args?.edits)) {
		return args.edits
			.map((edit: any) => ({
				oldText: typeof edit?.oldText === "string" ? edit.oldText : typeof edit?.old_text === "string" ? edit.old_text : "",
				newText: typeof edit?.newText === "string" ? edit.newText : typeof edit?.new_text === "string" ? edit.new_text : "",
			}))
			.filter((edit: { oldText: string; newText: string }) => edit.oldText.length > 0 && edit.oldText !== edit.newText);
	}
	const oldText = typeof args?.oldText === "string" ? args.oldText : typeof args?.old_text === "string" ? args.old_text : "";
	const newText = typeof args?.newText === "string" ? args.newText : typeof args?.new_text === "string" ? args.new_text : "";
	return oldText.length > 0 && oldText !== newText ? [{ oldText, newText }] : [];
}

export function summarizeDiffs(diffs: StructuredDiff[]): StructuredDiff {
	return {
		additions: diffs.reduce((sum, diff) => sum + diff.additions, 0),
		chars: diffs.reduce((sum, diff) => sum + diff.chars, 0),
		hunks: diffs.reduce((sum, diff) => sum + (diff.hunks ?? countStructuredHunks(diff.lines)), 0),
		lines: diffs.flatMap((diff, index) => index === 0 ? diff.lines : [hiddenDiffLine(0), ...diff.lines]),
		removals: diffs.reduce((sum, diff) => sum + diff.removals, 0),
	};
}

export function renderMutationCallPreview(kind: "Edit" | "Write" | "Create", targetPath: string, diffs: StructuredDiff[], theme: any, context: any, cwd: string): TruncatedLines | ReturnType<typeof makeEmpty> {
	if (context?.executionStarted && !context?.isPartial) return makeEmpty();
	if (!settingBoolean("mutationCallPreview", true, cwd) || diffs.length === 0) return makeEmpty();
	const total = summarizeDiffs(diffs);
	const prefix = context?.executionStarted && context?.isPartial ? pendingStatusPrefix(theme, context, cwd) : stackPrefix(theme);
	let text = `${prefix}${toolLabel(theme, `${kind} `)}${theme.fg("accent", targetPath)}${theme.fg("dim", " · preview · ")}${diffSummary(total, theme, cwd)}`;
	const maxShown = context?.expanded ? diffs.length : Math.min(1, diffs.length);
	const perDiffLimit = Math.max(4, Math.floor(settingNumber("mutationCallPreviewLines", 16, cwd) / Math.max(1, maxShown)));
	for (let index = 0; index < maxShown; index++) {
		const diff = diffs[index]!;
		if (diffs.length > 1) text += `\n${treeConnector(theme, "├", cwd)}${theme.fg("muted", `edit ${index + 1}/${diffs.length}`)} ${diffSummary(diff, theme, cwd)}`;
		const stem = treeConnector(theme, "│", cwd);
		const rendered = renderStructuredDiff(diff, theme, Boolean(context?.expanded), cwd, perDiffLimit, targetPath, visibleWidth(stem));
		text += `\n${rendered.split(/\r?\n/).map((line) => `${stem}${line}`).join("\n")}`;
	}
	const hidden = diffs.length - maxShown;
	if (hidden > 0) text += `\n${treeConnector(theme, "└", cwd)}${theme.fg("muted", `… ${hidden} more edit block${hidden === 1 ? "" : "s"} · ctrl+o to expand`)}`;
	return makeTruncatedLines(text);
}

export function existingSmallTextOrUndefined(targetPath: string, cwd: string): string | undefined {
	return readTextForDiff(targetPath, cwd);
}

