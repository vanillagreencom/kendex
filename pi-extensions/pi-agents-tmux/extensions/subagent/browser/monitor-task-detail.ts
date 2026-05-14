import { type Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth, wrapTextWithAnsi } from "@earendil-works/pi-tui";
import { discoverAgents, type AgentConfig } from "../agents.js";
import {
	activePill,
	ansiMagenta,
	ansiYellow,
	COMPLETION_SUMMARY_UNAVAILABLE,
	compactPath,
	completionBodyWithoutPromptEcho,
	formatUsageStats,
	highlightInlinePreview,
	inactivePill,
	sessionModeChipLabel,
	sessionModeDetailLabel,
} from "../format.js";
import { readTextFileIfExists, recordTraceRef } from "../renderers.js";
import {
	MONITOR_SUBTAB_LABELS,
	type AgentBrowserUiState,
	type MonitorDetailEntry,
	type PaneTaskRecord,
	type TraceViewerItem,
} from "../types.js";
import { agentDivider, agentPad, agentPaneTitle } from "./shared.js";
import {
	monitorStatusText,
	recordMonitorKind,
} from "./monitor-tree.js";
import {
	TRANSCRIPT_COMPACTION_BANNER,
	TRANSCRIPT_COMPACTION_BODY,
	transcriptCompactRows,
	transcriptExpandedRows,
} from "./transcript.js";

function wrapPlainNoEllipsis(text: string, width: number): string[] {
	const targetWidth = Math.max(1, width);
	const out: string[] = [];
	for (const raw of text.split(/\r?\n/)) {
		const soft = wrapTextWithAnsi(raw, targetWidth);
		const chunks = soft.length > 0 ? soft : [""];
		for (const chunk of chunks) {
			let rest = chunk;
			if (!rest) {
				out.push("");
				continue;
			}
			while (visibleWidth(rest) > targetWidth) {
				const part = truncateToWidth(rest, targetWidth, "");
				if (!part) break;
				out.push(part);
				rest = rest.slice(part.length);
			}
			if (rest) out.push(rest);
		}
	}
	return out;
}

function colorTraceValue(label: string, value: string, theme: Theme): string {
	let renderedValue = theme.fg("text", value);
	if (label.toLowerCase() === "status") {
		renderedValue = theme.fg(value === "completed" ? "success" : value === "failed" ? "error" : "warning", value);
	}
	return `${theme.fg("muted", `${label}: `.padEnd(12))}${renderedValue}`;
}

function traceLineLooksJsonLike(line: string, type: TraceViewerItem["type"] | undefined): boolean {
	const trimmed = line.trim();
	return type === "completion"
		|| type === "transcript"
		|| trimmed.startsWith("{")
		|| trimmed.startsWith("[")
		|| /^"[^"\\]+"\s*:/.test(trimmed)
		|| /^[}\]],?$/.test(trimmed);
}

function monitorStickyTranscriptRawLines(rawLines: string[], type: TraceViewerItem["type"] | undefined): { scrollRawLines: string[]; stickyRawLines: string[] } {
	if (type !== "summary") return { scrollRawLines: rawLines, stickyRawLines: [] };
	const stickyIndexes = new Set<number>();
	const stickyRawLines: string[] = [];
	for (let index = 0; index < rawLines.length; index += 1) {
		const line = rawLines[index] ?? "";
		if (!line.includes(TRANSCRIPT_COMPACTION_BANNER)) continue;
		stickyIndexes.add(index);
		stickyRawLines.push(line);
		const next = rawLines[index + 1] ?? "";
		if (next.trim() === TRANSCRIPT_COMPACTION_BODY) {
			stickyIndexes.add(index + 1);
			stickyRawLines.push(next);
		}
	}
	if (stickyRawLines.length === 0) return { scrollRawLines: rawLines, stickyRawLines };
	return { scrollRawLines: rawLines.filter((_line, index) => !stickyIndexes.has(index)), stickyRawLines };
}

export function renderTraceContentLines(rawLines: string[], type: TraceViewerItem["type"] | undefined, width: number, theme: Theme): string[] {
	const wrapped: string[] = [];
	for (const raw of rawLines) {
		const chunk = renderTraceContentLine(raw, type, width, theme);
		wrapped.push(...(chunk.length > 0 ? chunk : [""]));
	}
	return wrapped;
}

export function renderTraceContentLine(raw: string, type: TraceViewerItem["type"] | undefined, width: number, theme: Theme): string[] {
	const line = raw.replace(/\t/g, "  ");
	const trimmed = line.trim();
	if (!trimmed) return [""];
	if (trimmed.includes("⚠ COMPACTION")) return [theme.fg("error", agentPad(truncateToWidth(line, width, ""), width))];
	if (trimmed === TRANSCRIPT_COMPACTION_BODY) return wrapTextWithAnsi(theme.fg("error", line), width);
	if (/^── .+ ──$/.test(trimmed)) return wrapTextWithAnsi(theme.fg("muted", trimmed.replace(/(assistant|user|tool call|tool start|tool end|turn start|turn end|exit)/i, (match) => theme.fg("accent", theme.bold(match)))), width);
	if (/^-{3,}$/.test(trimmed)) return [];
	if (/^(Overview|Metadata|Summary|Files changed|Validation|Notes|Task|Artifacts)$/i.test(trimmed)) {
		return wrapTextWithAnsi(theme.fg("accent", theme.bold(trimmed)), width);
	}
	const labelMatch = line.match(/^(Ref|Agent|Task #|Status|Task ID|Created|Done|Model|Session|Session type|Start|Latest|Duration|Tasks|Usage|Pane ID|SessionKey|Transcript|Completion|Archive|Source)\s{2,}(.+)$/);
	if (labelMatch) return wrapTextWithAnsi(colorTraceValue(labelMatch[1], labelMatch[2], theme), width);
	if (traceLineLooksJsonLike(line, type)) return wrapTextWithAnsi(highlightInlinePreview(line, theme), width);
	const bullet = line.match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
	if (bullet) return wrapTextWithAnsi(`${bullet[1]}${theme.fg("accent", bullet[2])} ${theme.fg("toolOutput", bullet[3])}`, width);
	const markdownHeading = line.match(/^(#{1,6})\s+(.*)$/);
	if (markdownHeading) return wrapTextWithAnsi(`${theme.fg("accent", markdownHeading[1])} ${theme.fg("accent", theme.bold(markdownHeading[2]))}`, width);
	const backtick = line.replace(/`([^`]+)`/g, (_m: string, code: string) => theme.fg("accent", code));
	return wrapTextWithAnsi(theme.fg(type === "summary" ? "text" : "toolOutput", backtick), width);
}

function monitorTaskTitle(record: PaneTaskRecord, taskNumber: number | undefined, discovery: ReturnType<typeof discoverAgents>, theme: Theme, active: boolean): string {
	const agentConfig = discovery.agents.find((agent) => agent.name === record.agent);
	const taskNumberText = taskNumber ? ` #${taskNumber}` : "";
	const kind = recordMonitorKind(record) === "pane" ? "pane" : "bg";
	const session = sessionModeChipLabel({ kind: recordMonitorKind(record), sessionMode: record.sessionMode, sessionKey: record.sessionKey });
	const sessionPart = session ? `${theme.fg("dim", " · ")}${theme.fg("muted", session)}` : "";
	const model = record.model ?? agentConfig?.model;
	const effort = agentConfig?.effort?.trim();
	const modelPart = model ? `${theme.fg("dim", " · ")}${theme.fg("muted", `${model}${effort ? ` ${effort}` : ""}`)}` : "";
	return `${agentPaneTitle(theme, "Detail", active)} ${ansiMagenta(theme.bold(`${record.agent}${taskNumberText}`))}${theme.fg("dim", " · ")}${monitorStatusText(record.status, theme)}${theme.fg("dim", " · ")}${theme.fg("muted", kind)}${sessionPart}${modelPart}`;
}

export function monitorDetailCacheKey(taskId: string, transcriptExpanded: boolean): string {
	return `${taskId}:${transcriptExpanded ? "expanded" : "compact"}`;
}

export function monitorFooterHint(ui: AgentBrowserUiState, theme: Theme, taskDetailFocused = false): string {
	const xHint = taskDetailFocused
		? `${theme.fg("dim", " · ")}${ansiYellow("x")} ${theme.fg("dim", ui.monitorTranscriptExpanded ? "compact" : "expand")}`
		: "";
	return `${ansiYellow("tab")} ${theme.fg("dim", "switch · ")}${ansiYellow("↑/↓ -/=")} ${theme.fg("dim", "page · ")}${ansiYellow("←/→")} ${theme.fg("dim", "tree↔detail · ")}${ansiYellow("enter")} ${theme.fg("dim", "open · ")}${ansiYellow("f")} ${theme.fg("dim", "filter")}${xHint}${theme.fg("dim", " · ")}${ansiYellow("esc")} ${theme.fg("dim", "close")}`;
}

export function renderMonitorDetail(
	record: PaneTaskRecord | undefined,
	cache: Map<string, MonitorDetailEntry>,
	ui: AgentBrowserUiState,
	taskNumber: number | undefined,
	discovery: ReturnType<typeof discoverAgents>,
	width: number,
	rows: number,
	theme: Theme,
): string[] {
	if (!record) {
		return [`${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${theme.fg("dim", "Select a task to view its trace.")}`];
	}
	const safeWidth = Math.max(8, width);
	const entry = cache.get(monitorDetailCacheKey(record.taskId, ui.monitorTranscriptExpanded)) ?? cache.get(record.taskId);
	const items = entry?.items;
	const placeholderText = entry?.error ? `Error: ${entry.error}` : entry?.loading || !items ? "Loading…" : "(empty)";
	const subtabs: TraceViewerItem[] = items ?? MONITOR_SUBTAB_LABELS.map((label) => ({ label, text: placeholderText, type: label.toLowerCase() as TraceViewerItem["type"] }));
	const subtabIndex = Math.max(0, Math.min(ui.monitorSubtab, subtabs.length - 1));
	ui.monitorSubtab = subtabIndex;
	const titleLine = monitorTaskTitle(record, taskNumber, discovery, theme, ui.pane === "inspector");
	const subtabLine = renderTraceTabBar(subtabs, subtabIndex, safeWidth, theme);
	const item = subtabs[subtabIndex];
	const fileLines = item?.path
		? [
			...wrapPlainNoEllipsis(`file ${compactPath(item.path, { maxChars: Number.POSITIVE_INFINITY })}`, safeWidth).map((line) => theme.fg("dim", line)),
			agentDivider(safeWidth, theme),
		]
			: [];
	const rawLines = (item?.text || "(empty)").split(/\r?\n/);
	const { scrollRawLines, stickyRawLines } = monitorStickyTranscriptRawLines(rawLines, item?.type);
	const stickyWrapped = renderTraceContentLines(stickyRawLines, item?.type, safeWidth, theme);
	const wrapped = renderTraceContentLines(scrollRawLines, item?.type, safeWidth, theme);
	const header: string[] = [titleLine, "", subtabLine, "", ...fileLines];
	const headerRows = header.length;
	const footerRows = 1;
	const visibleRows = Math.max(1, rows - headerRows - stickyWrapped.length - footerRows);
	const maxScroll = Math.max(0, wrapped.length - visibleRows);
	ui.inspectorScroll = Math.max(0, Math.min(ui.inspectorScroll, maxScroll));
	const slice = wrapped.slice(ui.inspectorScroll, ui.inspectorScroll + visibleRows);
	const before = ui.inspectorScroll > 0 ? `↑ ${ui.inspectorScroll}` : "";
	const afterCount = Math.max(0, wrapped.length - ui.inspectorScroll - visibleRows);
	const after = afterCount > 0 ? `↓ ${afterCount}` : "";
	const scrollHint = [before, after].filter(Boolean).join(" · ");
	const out: string[] = [...header];
	out.push(...stickyWrapped);
	out.push(...slice);
	if (scrollHint) out.push(ansiYellow(scrollHint));
	else out.push("");
	return out.slice(0, rows);
}

export function renderTraceTabBar(items: TraceViewerItem[], selected: number, width: number, theme: Theme): string {
	const partFor = (item: TraceViewerItem, index: number): string => {
		const label = ` ${truncateToWidth(item.label, 18, "…")} `;
		return index === selected ? activePill(theme, label) : inactivePill(theme, label);
	};
	const renderWindow = (start: number, end: number): string => {
		const parts = items.slice(start, end).map((item, offset) => partFor(item, start + offset));
		if (start > 0) parts.unshift(theme.fg("dim", "‹"));
		if (end < items.length) parts.push(theme.fg("dim", "›"));
		return parts.join(" ");
	};
	let start = Math.max(0, selected);
	let end = Math.min(items.length, selected + 1);
	let current = renderWindow(start, end);
	let preferRight = true;
	while (start > 0 || end < items.length) {
		const addRight = end < items.length && (preferRight || start === 0);
		const addLeft = !addRight && start > 0;
		const nextStart = addLeft ? start - 1 : start;
		const nextEnd = addRight ? end + 1 : end;
		const candidate = renderWindow(nextStart, nextEnd);
		if (visibleWidth(candidate) > width) {
			if (addRight && start > 0) {
				preferRight = false;
				continue;
			}
			break;
		}
		start = nextStart;
		end = nextEnd;
		current = candidate;
		preferRight = !preferRight;
	}
	return truncateToWidth(current, width, "");
}

export async function traceViewerItems(record: PaneTaskRecord, taskNumber?: number, discovery?: { agents: AgentConfig[] }, options: { transcriptExpanded?: boolean } = {}): Promise<TraceViewerItem[]> {
	const ref = recordTraceRef(record);
	const usage = record.usage ? formatUsageStats(record.usage, record.model) : "";
	const completionPath = record.completionArchivePath ?? record.completionSourcePath;
	const summaryText = record.summary?.trim()
		? completionBodyWithoutPromptEcho(record.summary, record.task)
		: record.status === "completed" || record.status === "failed" || record.status === "blocked"
			? COMPLETION_SUMMARY_UNAVAILABLE
			: "No summary yet.";
	// Reasoning-effort lookup: the record itself does not persist `effort`,
	// but the agent's frontmatter does. Pull from discovery when available
	// (popup path) so the Model line reads `gpt-5.5 xhigh` instead of just
	// `gpt-5.5`. Effort lives under `model-reasoning-effort` (OpenCode /
	// Codex / Pi) or `effort` (Claude); both resolve to the same display
	// token.
	const agentConfig = discovery?.agents.find((a) => a.name === record.agent);
	const effort = agentConfig?.effort?.trim() || undefined;
	const modelLine = record.model
		? `Model    ${record.model}${effort ? ` ${effort}` : ""}`
		: "";
	const sessionDetail = sessionModeDetailLabel(record);
	const sessionLine = sessionDetail ? `Session  ${sessionDetail}` : "";
	const transcriptRows = options.transcriptExpanded ? transcriptExpandedRows(record) : transcriptCompactRows(record);
	// `" "` (single space) is a sentinel for an intentional blank line; it
	// survives the `.filter(Boolean)` pass below that drops conditionally
	// empty entries (e.g. record.completedAt missing -> no `Done` line).
	const BLANK = " ";
	const metadata = [
		"Overview",
		"",
		`Ref      ${ref}`,
		`Agent    ${record.agent}`,
		taskNumber ? `Task #   ${taskNumber}` : "",
		`Status   ${record.status}`,
		`Task ID  ${record.taskId}`,
		modelLine,
		sessionLine,
		usage ? `Usage    ${usage}` : "",
		record.transcriptPath ? `Transcript  ${record.transcriptPath}` : "",
		completionPath ? `Completion  ${completionPath}` : "",
		record.completionArchivePath ? `Archive  ${record.completionArchivePath}` : "",
		record.completionSourcePath ? `Source   ${record.completionSourcePath}` : "",
		`Created  ${record.createdAt}`,
		record.completedAt ? `Done     ${record.completedAt}` : "",
		BLANK,
		"Transcript",
		"----------",
		transcriptRows.length ? transcriptRows.join("\n") : "Transcript unavailable.",
		BLANK,
		"Summary",
		"-------",
		summaryText,
		BLANK,
		"Files changed",
		"-------------",
		record.filesChanged?.length ? record.filesChanged.map((file) => `- ${file}`).join("\n") : "None reported",
		BLANK,
		"Validation",
		"----------",
		record.validation?.length ? record.validation.map((item) => `- ${item}`).join("\n") : "None reported",
		record.notes ? `\nNotes\n-----\n${record.notes}` : "",
	].filter(Boolean).join("\n");
	const completion = await readTextFileIfExists(record.completionArchivePath ?? record.completionSourcePath, 24_000);
	const common = { agent: record.agent, createdAt: record.completedAt ?? record.createdAt, ref, status: record.status, summary: summaryText };
	const taskText = [
		`Task ID  ${record.taskId}`,
		`Created  ${record.createdAt}`,
		taskNumber ? `Task #   ${taskNumber}` : "",
		"",
		"Task",
		"----",
		record.task || "Task unavailable.",
	].filter(Boolean).join("\n");
	return [
		{ ...common, label: "Summary", text: metadata, type: "summary" },
		{ ...common, label: "Completion", path: record.completionArchivePath ?? record.completionSourcePath, text: completion || "Completion JSON unavailable.", type: "completion" },
		{ ...common, label: "Task", path: record.inboxFile, text: taskText, type: "task" },
	];
}
