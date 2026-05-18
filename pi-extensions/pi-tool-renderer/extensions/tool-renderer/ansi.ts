import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";

import { rightMarginGuardEnabled } from "./settings.js";

export const ANSI_GREEN = "\x1b[32m";
export const ANSI_RED = "\x1b[31m";
export const ANSI_FG_RESET = "\x1b[39m";
export const ANSI_BG_RESET = "\x1b[49m";

export const ANSI_RE = /\x1b(?:\[[0-9;]*m|\]133;[ABC]\x07)/g;
export const ANSI_PRESENT_RE = /\x1b\[[0-9;]*m/;

export interface AnsiParts {
	close: string;
	open: string;
}

export function ansiRed(text: string): string {
	return `${ANSI_RED}${text}${ANSI_FG_RESET}`;
}

export function ansiGreen(text: string): string {
	return `${ANSI_GREEN}${text}${ANSI_FG_RESET}`;
}

export function stripAnsi(text: string): string {
	return text.replace(ANSI_RE, "");
}

export function hasAnsi(text: string): boolean {
	return ANSI_PRESENT_RE.test(text);
}

export function visibleLength(text: string): number {
	return visibleWidth(text);
}

export function padVisible(text: string, width: number): string {
	const missing = width - visibleLength(text);
	return missing > 0 ? `${text}${" ".repeat(missing)}` : text;
}

export function truncateAnsi(text: string, width: number): string {
	return truncateToWidth(text, Math.max(1, width), "");
}

export function stableRenderWidth(width: number, cwd?: string): number {
	const safe = Math.max(1, Math.floor(width || 1));
	return rightMarginGuardEnabled(cwd) && safe > 1 ? safe - 1 : safe;
}

export function terminalWidth(cwd?: string): number {
	const raw = Number(process.stdout.columns || (process.stderr as any).columns || process.env.COLUMNS || 120);
	const guarded = stableRenderWidth(raw, cwd);
	return Math.max(40, guarded);
}

export function isBlankRenderLine(line: string | undefined): boolean {
	return stripAnsi(line ?? "").trim().length === 0;
}

export function trimTrailingBlankLines(lines: string[]): string[] {
	let end = lines.length - 1;
	while (end >= 0 && isBlankRenderLine(lines[end])) end--;
	return end < 0 ? [] : lines.slice(0, end + 1);
}

export function trimOuterBlankLines(lines: string[]): string[] {
	let start = 0;
	while (start < lines.length && isBlankRenderLine(lines[start])) start++;
	let end = lines.length - 1;
	while (end >= start && isBlankRenderLine(lines[end])) end--;
	return start > end ? [] : lines.slice(start, end + 1);
}

const TRAILING_ANSI_RE = /(?:\x1b(?:\[[0-9;:]*m|\]133;[ABC]\x07))+$/;

export function trimTrailingWhitespaceBeforeAnsi(text: string): string {
	const match = text.match(TRAILING_ANSI_RE);
	if (!match) return text.trimEnd();
	return `${text.slice(0, -match[0].length).trimEnd()}${match[0]}`;
}

export function isHorizontalRuleLine(line: string | undefined): boolean {
	const stripped = stripAnsi(line ?? "").trim();
	return stripped.length > 0 && /^[─━-]+$/.test(stripped);
}

export function trimOuterBlankLinesAroundRules(lines: string[]): string[] {
	const trimmed = trimOuterBlankLines(lines);
	if (trimmed.length < 3) return lines;
	return isHorizontalRuleLine(trimmed[0]) && isHorizontalRuleLine(trimmed[trimmed.length - 1]) ? trimmed : lines;
}

export function isThinkingOnlyAssistantMessage(message: any): boolean {
	const content = Array.isArray(message?.content) ? message.content : [];
	let hasThinking = false;
	for (const item of content) {
		if (item?.type === "text" && typeof item.text === "string" && item.text.trim()) return false;
		if (item?.type === "thinking" && typeof item.thinking === "string" && item.thinking.trim()) hasThinking = true;
	}
	return hasThinking;
}

export function trimThinkingOnlyAssistantLines(lines: string[]): string[] {
	const trimmed = trimOuterBlankLines(lines).map((line) => line.trimEnd());
	if (trimmed.length === 0) return lines;
	const zoneStart = "\x1b]133;A\x07";
	if (lines[0]?.includes(zoneStart) && !trimmed[0]?.includes(zoneStart)) trimmed[0] = `${zoneStart}${trimmed[0] ?? ""}`;
	return trimmed;
}

export function ansiPartsFromStyled(styled: string): AnsiParts {
	const marker = "\uE000";
	const markerIndex = styled.indexOf(marker);
	if (markerIndex < 0) return { open: "", close: "" };
	return { open: styled.slice(0, markerIndex), close: styled.slice(markerIndex + marker.length) };
}

export function fgParts(theme: any, token: string): { open: string; close: string } {
	const marker = "\uE000";
	try {
		const styled = theme.fg(token, marker);
		const index = styled.indexOf(marker);
		if (index < 0) return { open: "", close: "" };
		return { open: styled.slice(0, index), close: styled.slice(index + marker.length) };
	} catch {
		return { open: "", close: "" };
	}
}

export function applyBaseTextFg(line: string, theme: any): string {
	let normalized = line;
	for (const token of ["userMessageText", "text"]) {
		const { open } = fgParts(theme, token);
		if (open) normalized = normalized.split(open).join(ANSI_FG_RESET);
	}
	return `${ANSI_FG_RESET}${normalized.replace(/\x1b\[(?:0|39)m/g, (reset) => `${reset}${ANSI_FG_RESET}`)}${ANSI_FG_RESET}`;
}

export function ansiHasBackground(open: string): boolean {
	for (const match of open.matchAll(/\x1b\[([0-9;:]*)m/g)) {
		const params = match[1] || "0";
		if (/(^|[;:])48([;:]|$)/.test(params)) return true;
		if (/(^|[;:])(?:4[0-7]|10[0-7])([;:]|$)/.test(params)) return true;
	}
	return false;
}

export function sgrClearsBackground(code: string): boolean {
	const match = code.match(/^\x1b\[([0-9;]*)m$/);
	if (!match) return false;
	const params = match[1] ? match[1].split(";").map((value) => Number.parseInt(value || "0", 10)) : [0];
	return params.some((value) => value === 0 || value === 49);
}

export function stripSgrBackgroundParams(code: string): string {
	const match = code.match(/^\x1b\[([0-9;:]*)m$/);
	if (!match) return code;
	const raw = match[1] ?? "";
	if (!raw || raw.includes(":")) return code;
	const params = raw.split(";");
	const kept: string[] = [];
	for (let index = 0; index < params.length; index++) {
		const value = Number.parseInt(params[index] || "0", 10);
		if (value === 48) {
			const mode = Number.parseInt(params[index + 1] || "", 10);
			if (mode === 5) {
				index += 2;
				continue;
			}
			if (mode === 2) {
				index += 4;
				continue;
			}
		}
		if (value === 49 || (value >= 40 && value <= 47) || (value >= 100 && value <= 107)) continue;
		kept.push(params[index] || "0");
	}
	return kept.length > 0 ? `\x1b[${kept.join(";")}m` : "";
}

export function stripLeadingBackgroundLayer(line: string): string {
	let offset = 0;
	let out = "";
	const leadingAnsiRe = /\x1b(?:\[([0-9;:]*)m|\]133;[ABC]\x07)/y;
	while (offset < line.length) {
		leadingAnsiRe.lastIndex = offset;
		const match = leadingAnsiRe.exec(line);
		if (!match) break;
		const code = match[0];
		out += code.startsWith("\x1b[") ? stripSgrBackgroundParams(code) : code;
		offset = leadingAnsiRe.lastIndex;
	}
	return `${out}${line.slice(offset)}`;
}

export function updateActiveAnsiStyle(code: string): string {
	const match = code.match(/^\x1b\[([0-9;]*)m$/);
	if (!match) return "";
	const params = match[1] ? match[1].split(";").map((value) => Number.parseInt(value || "0", 10)) : [0];
	if (params.some((value) => value === 0 || value === 39)) return "";
	return code;
}

export { visibleWidth, wrapTextWithAnsi };
