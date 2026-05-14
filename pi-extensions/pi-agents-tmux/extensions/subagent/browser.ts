import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
	getMarkdownTheme,
	type ExtensionContext,
	type Theme,
	withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import {
	Markdown,
	matchesKey,
	truncateToWidth,
	visibleWidth,
	wrapTextWithAnsi,
	type TUI,
} from "@earendil-works/pi-tui";
import {
	discoverAgents,
	type AgentConfig,
	type AgentScope,
} from "./agents.js";
import {
	dashboardKindLabel,
	dashboardStatusIcon,
	dashboardStatusText,
	isDashboardAttentionStatus,
	isDashboardWorkingStatus,
	sortDashboardItems,
} from "./dashboard.js";
import {
	activePill,
	ansiGreen,
	ansiMagenta,
	ansiYellow,
	COMPLETION_SUMMARY_UNAVAILABLE,
	compactPath,
	completionBodyWithoutPromptEcho,
	divider,
	formatUsageStats,
	formatUsageStatsForDashboard,
	inactivePill,
	oneLinePreview,
	sessionModeChipLabel,
	sessionModeChipSuffix,
	sessionModeDetailLabel,
	shortTaskSuffix,
	simpleFrame,
	textFromMessageContent,
} from "./format.js";
import {
	ensurePersistentPane,
	paneExists,
	stopPersistentPane,
	tmux,
} from "./pane.js";
import { readPaneRegistry, readTaskRegistry } from "./tasks.js";
import { paneCompletionTone, readTextFileIfExists } from "./renderers.js";
import { recordTraceRef } from "./renderers.js";
import { taskRegistryPath } from "./paths.js";
import {
	AGENTS_BROWSER_TAB,
	AGENTS_BROWSER_HEIGHT_RATIO,
	AGENTS_BROWSER_MAX_HEIGHT,
	AGENTS_BROWSER_WIDTH,
	AGENTS_LEFT_MAX_WIDTH,
	AGENTS_LEFT_MIN_WIDTH,
	AGENTS_POPUP_FRAME_ROWS,
	AGENTS_POPUP_PADDING_X,
	AGENTS_POPUP_PADDING_Y,
	AGENT_EDIT_CONFIRM_WIDTH,
	HISTORY_BROWSER_TAB,
	HISTORY_SUBTAB_LABELS,
	ICONS,
	TRACE_VIEWER_MAX_HEIGHT,
	TRACE_VIEWER_WIDTH,
	VSTACK_MODAL_LOCK_SYMBOL,
	type AgentBrowserAction,
	type AgentBrowserLayout,
	type AgentBrowserTabDef,
	type AgentBrowserTabId,
	type AgentBrowserUiState,
	type AgentFrontmatterEdit,
	type AgentPaneStatus,
	type ChatMessage,
	type CompletionMessageProvenance,
	type HistoryDetailEntry,
	type PaneTaskRecord,
	type PaneTaskRegistry,
	type PaneTaskStatus,
	type SubagentDashboardItem,
	type TraceViewerItem,
	type TraceViewerState,
	type VstackModalLock,
} from "./types.js";
import { safeFileName } from "./names.js";

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

function agentInlineLine(text: string): string {
	return text.replace(/[\r\n]+/g, " ").replace(/\t/g, " ");
}

function agentPad(text: string, width: number): string {
	const safeWidth = Math.max(0, width);
	const truncated = truncateToWidth(agentInlineLine(text), safeWidth, "");
	return `${truncated}${" ".repeat(Math.max(0, safeWidth - visibleWidth(truncated)))}`;
}

function isAgentBrowserTextInput(data: string): boolean {
	return data.length === 1 && data >= " " && data !== "\x7f";
}

function isAgentBrowserCancelInput(data: string): boolean {
	// After terminal/tmux resize events, stdin can occasionally deliver raw control
	// bytes in chunks that `matchesKey()` does not normalize. Always honor Ctrl+C
	// if the byte is present anywhere in the input chunk so the popup cannot trap
	// the session in raw-mode focus.
	return data.includes("\x03") || matchesKey(data, "escape") || matchesKey(data, "ctrl+c");
}

function compactAgentPath(filePath: string): string {
	const home = os.homedir();
	return filePath.startsWith(home) ? `~${filePath.slice(home.length)}` : filePath;
}

function stripYamlQuotes(value: string): string {
	const trimmed = value.trim();
	if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
		return trimmed.slice(1, -1).replace(/\\"/g, '"').replace(/\\'/g, "'");
	}
	return trimmed;
}

function splitMarkdownFrontmatter(raw: string): { frontmatter: string; body: string; hasFrontmatter: boolean } {
	if (!raw.startsWith("---\n") && raw.trim() !== "---") return { frontmatter: "", body: raw, hasFrontmatter: false };
	const close = raw.indexOf("\n---", 4);
	if (close < 0) return { frontmatter: "", body: raw, hasFrontmatter: false };
	const afterClose = raw.slice(close + 4).replace(/^\r?\n/, "");
	return { frontmatter: raw.slice(4, close), body: afterClose, hasFrontmatter: true };
}

function flatYamlField(frontmatter: string, key: string): string | undefined {
	const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	const match = frontmatter.match(new RegExp(`^\\s*${escaped}\\s*:\\s*(.*?)\\s*$`, "m"));
	return match?.[1] === undefined ? undefined : stripYamlQuotes(match[1]);
}

function parseToolsList(value: string | undefined): string[] {
	if (!value) return [];
	const trimmed = value.trim();
	const listText = trimmed.startsWith("[") && trimmed.endsWith("]") ? trimmed.slice(1, -1) : trimmed;
	return listText.split(",").map((tool) => stripYamlQuotes(tool).trim()).filter(Boolean);
}

function agentCurrentFrontmatterEdit(agent: AgentConfig): AgentFrontmatterEdit {
	let frontmatter = "";
	try {
		frontmatter = splitMarkdownFrontmatter(fs.readFileSync(agent.filePath, "utf-8")).frontmatter;
	} catch {
		frontmatter = "";
	}
	const current = {
		model: flatYamlField(frontmatter, "model") ?? agent.model ?? "",
		denyTools: parseToolsList(flatYamlField(frontmatter, "deny-tools") ?? agent.denyTools?.join(", ")),
		color: flatYamlField(frontmatter, "color") ?? agent.color ?? "",
	};
	if (!isVstackManagedAgentFile(agent)) return current;
	const tomlPath = vstackTomlPathForAgent(agent, process.cwd());
	if (!tomlPath) return current;
	const tomlCurrent = readAgentFrontmatterToml(tomlPath, agent.name, "[agent-frontmatter.pi]");
	return {
		model: tomlCurrent.model ?? current.model,
		denyTools: tomlCurrent.denyTools ?? current.denyTools,
		color: tomlCurrent.color ?? current.color,
	};
}

function editableAgentFrontmatterText(agent: AgentConfig): string {
	const current = agentCurrentFrontmatterEdit(agent);
	const lines = [
		"# Edit agent frontmatter overrides. Blank values remove the override.",
		"# For vstack-managed agents, this writes [agent-frontmatter.pi] in vstack.toml.",
		"# Pi-specific changes regenerate the Pi agent file only.",
		`model: ${current.model}`,
		`deny-tools: ${current.denyTools.join(", ")}`,
	];
	lines.push(`color: ${current.color}`, "");
	return lines.join("\n");
}

function parseEditableAgentFrontmatterText(raw: string): AgentFrontmatterEdit {
	const fields = new Map<string, string>();
	for (const line of raw.split(/\r?\n/)) {
		const trimmed = line.trim();
		if (!trimmed || trimmed.startsWith("#")) continue;
		const match = trimmed.match(/^([A-Za-z][\w-]*)\s*:\s*(.*)$/);
		if (!match) throw new Error(`Expected 'key: value' line, got: ${trimmed}`);
		const key = match[1].toLowerCase();
		if (key === "tools") throw new Error("tools allowlists are no longer supported; use deny-tools instead.");
		if (key === "model" || key === "deny-tools" || key === "color") fields.set(key, match[2] ?? "");
	}
	return {
		model: stripYamlQuotes(fields.get("model") ?? ""),
		denyTools: parseToolsList(fields.get("deny-tools")),
		color: stripYamlQuotes(fields.get("color") ?? ""),
	};
}

function isVstackManagedAgentFile(agent: AgentConfig): boolean {
	try {
		const raw = fs.readFileSync(agent.filePath, "utf-8");
		return raw.includes("Never edit this file directly") && raw.includes("vstack refresh");
	} catch {
		return false;
	}
}

function projectRootForAgentFile(agent: AgentConfig, cwd: string): string {
	const normalized = path.resolve(agent.filePath);
	for (const marker of [`${path.sep}.pi${path.sep}agents${path.sep}`, `${path.sep}.claude${path.sep}agents${path.sep}`]) {
		const idx = normalized.indexOf(marker);
		if (idx >= 0) return normalized.slice(0, idx);
	}
	let current = path.resolve(cwd);
	while (true) {
		if (fs.existsSync(path.join(current, "vstack.toml")) || fs.existsSync(path.join(current, ".vstack-lock.json")) || fs.existsSync(path.join(current, ".git"))) return current;
		const parent = path.dirname(current);
		if (parent === current) return path.resolve(cwd);
		current = parent;
	}
}

function vstackTomlPathForAgent(agent: AgentConfig, cwd: string): string | undefined {
	let current = projectRootForAgentFile(agent, cwd);
	while (true) {
		const candidate = path.join(current, "vstack.toml");
		if (fs.existsSync(candidate)) return candidate;
		if (fs.existsSync(path.join(current, ".vstack-lock.json")) || fs.existsSync(path.join(current, ".git"))) return candidate;
		const parent = path.dirname(current);
		if (parent === current) return undefined;
		current = parent;
	}
}

function tomlString(value: string): string {
	return `"${value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
}

function tomlArray(values: string[]): string {
	return `[${values.map(tomlString).join(", ")}]`;
}

function splitTopLevelCommas(input: string): string[] {
	const out: string[] = [];
	let current = "";
	let quote: string | undefined;
	let bracketDepth = 0;
	let escaped = false;
	for (const char of input) {
		if (escaped) { current += char; escaped = false; continue; }
		if (char === "\\") { current += char; escaped = true; continue; }
		if (quote) {
			current += char;
			if (char === quote) quote = undefined;
			continue;
		}
		if (char === '"' || char === "'") { quote = char; current += char; continue; }
		if (char === "[") bracketDepth += 1;
		if (char === "]") bracketDepth = Math.max(0, bracketDepth - 1);
		if (char === "," && bracketDepth === 0) { out.push(current.trim()); current = ""; continue; }
		current += char;
	}
	if (current.trim()) out.push(current.trim());
	return out;
}

function parseInlineTomlTable(value: string): Map<string, string> {
	const map = new Map<string, string>();
	const trimmed = value.trim().replace(/^\{/, "").replace(/\}$/, "");
	for (const part of splitTopLevelCommas(trimmed)) {
		const idx = part.indexOf("=");
		if (idx <= 0) continue;
		map.set(part.slice(0, idx).trim(), part.slice(idx + 1).trim());
	}
	return map;
}

function tomlSectionSpan(lines: string[], section: string): { start: number; end: number } | undefined {
	const start = lines.findIndex((line) => line.trim() === section);
	if (start < 0) return undefined;
	let end = lines.length;
	for (let i = start + 1; i < lines.length; i += 1) {
		if (/^\s*\[[^\]]+\]\s*$/.test(lines[i])) { end = i; break; }
		if (lines[i].trim().startsWith("# ──")) { end = i; break; }
	}
	return { start, end };
}

function agentTomlKeyRegex(agentName: string): RegExp {
	return new RegExp(`^\\s*(?:${agentName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}|${tomlString(agentName).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})\\s*=`);
}

function agentTomlLineIndex(lines: string[], sectionStart: number, sectionEnd: number, agentName: string): number {
	const keyRe = agentTomlKeyRegex(agentName);
	const existingIndex = lines.slice(sectionStart + 1, sectionEnd).findIndex((line) => keyRe.test(line));
	return existingIndex >= 0 ? sectionStart + 1 + existingIndex : -1;
}

function readAgentFrontmatterToml(tomlPath: string, agentName: string, section = "[agent-frontmatter]"): Partial<AgentFrontmatterEdit> {
	let content = "";
	try { content = fs.readFileSync(tomlPath, "utf-8"); } catch { return {}; }
	const lines = content.split(/\r?\n/);
	const span = tomlSectionSpan(lines, section);
	if (!span) return {};
	const absoluteIndex = agentTomlLineIndex(lines, span.start, span.end, agentName);
	if (absoluteIndex < 0) return {};
	const existingValue = lines[absoluteIndex].split(/=(.*)/s)[1] ?? "";
	const fields = parseInlineTomlTable(existingValue.trim());
	return {
		model: fields.has("model") ? stripYamlQuotes(fields.get("model") ?? "") : undefined,
		denyTools: fields.has("deny-tools") ? parseToolsList(fields.get("deny-tools")) : undefined,
		color: fields.has("color") ? stripYamlQuotes(fields.get("color") ?? "") : undefined,
	};
}

function tomlAgentKey(agentName: string): string {
	return /^[A-Za-z0-9_-]+$/.test(agentName) ? agentName : tomlString(agentName);
}

function renderTomlInlineTable(fields: Map<string, string>): string {
	const preferred = ["color", "model", "deny-tools", "pane", "mode", "sandbox-mode", "model-reasoning-effort", "effort", "background", "isolation", "memory"];
	const keys = [...preferred.filter((key) => fields.has(key)), ...[...fields.keys()].filter((key) => !preferred.includes(key)).sort()];
	return `{ ${keys.map((key) => `${key} = ${fields.get(key)}`).join(", ")} }`;
}

function removeAgentFrontmatterKeys(content: string, agentName: string, section: string, keys: string[]): string {
	const lines = content.split(/\r?\n/);
	const span = tomlSectionSpan(lines, section);
	if (!span) return content;
	const absoluteIndex = agentTomlLineIndex(lines, span.start, span.end, agentName);
	if (absoluteIndex < 0) return content;
	const existingValue = lines[absoluteIndex].split(/=(.*)/s)[1] ?? "";
	const fields = parseInlineTomlTable(existingValue.trim());
	for (const key of keys) fields.delete(key);
	if (fields.size === 0) lines.splice(absoluteIndex, 1);
	else lines[absoluteIndex] = `${tomlAgentKey(agentName)} = ${renderTomlInlineTable(fields)}`;
	return lines.join("\n");
}

function upsertAgentFrontmatterToml(content: string, agentName: string, edit: AgentFrontmatterEdit): string {
	const section = "[agent-frontmatter.pi]";
	const lines = content.split(/\r?\n/);
	let span = tomlSectionSpan(lines, section);
	if (!span) {
		const insertAt = lines.findIndex((line) => line.trim().startsWith("# ── Installed skills"));
		const block = ["", "# Pi-specific frontmatter values. The Pi /agents popup edits", "# vstack-managed entries in this file, then `vstack refresh` applies them.", section, ""];
		if (insertAt >= 0) lines.splice(insertAt, 0, ...block);
		else lines.push(...block);
		span = tomlSectionSpan(lines, section);
	}
	if (!span) return content;
	let sectionEnd = span.end;
	while (sectionEnd > span.start + 1 && lines[sectionEnd - 1]?.trim() === "") sectionEnd -= 1;
	const key = tomlAgentKey(agentName);
	const absoluteIndex = agentTomlLineIndex(lines, span.start, sectionEnd, agentName);
	const existingValue = absoluteIndex >= 0 ? (lines[absoluteIndex].split(/=(.*)/s)[1] ?? "") : "";
	const fields = parseInlineTomlTable(existingValue.trim());
	if (edit.color.trim()) fields.set("color", tomlString(edit.color.trim())); else fields.delete("color");
	if (edit.model.trim()) fields.set("model", tomlString(edit.model.trim())); else fields.delete("model");
	fields.delete("tools");
	if (edit.denyTools.length > 0) fields.set("deny-tools", tomlArray(edit.denyTools)); else fields.delete("deny-tools");
	if (fields.size === 0) {
		if (absoluteIndex >= 0) lines.splice(absoluteIndex, 1);
	} else {
		const nextLine = `${key} = ${renderTomlInlineTable(fields)}`;
		if (absoluteIndex >= 0) lines[absoluteIndex] = nextLine;
		else lines.splice(sectionEnd, 0, nextLine, "");
	}
	const next = lines.join("\n");
	return `${next.replace(/\n*$/, "")}\n`;
}

function refreshVstackManagedAgent(agent: AgentConfig, tomlPath: string): { ok: boolean; message?: string } {
	const projectRoot = path.dirname(tomlPath);
	const result = spawnSync("vstack", ["refresh", "--scope", "project"], {
		cwd: projectRoot,
		encoding: "utf-8",
		timeout: 120_000,
	});
	if (result.error) return { ok: false, message: result.error.message };
	if ((result.status ?? 0) !== 0) {
		const detail = (result.stderr || result.stdout || `exit ${result.status}`).trim();
		return { ok: false, message: detail.split(/\r?\n/).slice(-4).join(" ") };
	}
	if (!fs.existsSync(agent.filePath)) return { ok: false, message: `${compactAgentPath(agent.filePath)} was not regenerated.` };
	return { ok: true };
}

function yamlScalar(value: string): string {
	if (!value) return "";
	return /^[A-Za-z0-9_./:+-]+$/.test(value) ? value : `"${value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
}

function upsertYamlField(frontmatter: string, key: string, value: string | undefined): string {
	const lines = frontmatter.split(/\r?\n/);
	const keyRe = new RegExp(`^\\s*${key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*:`);
	const idx = lines.findIndex((line) => keyRe.test(line));
	if (!value) {
		if (idx >= 0) lines.splice(idx, 1);
		return lines.join("\n");
	}
	const line = `${key}: ${value}`;
	if (idx >= 0) lines[idx] = line;
	else lines.push(line);
	return lines.join("\n");
}

function updateAgentFileFrontmatter(raw: string, edit: AgentFrontmatterEdit): string {
	const split = splitMarkdownFrontmatter(raw);
	if (!split.hasFrontmatter) throw new Error("Agent file does not have YAML frontmatter.");
	let fm = split.frontmatter;
	fm = upsertYamlField(fm, "model", edit.model.trim() ? yamlScalar(edit.model.trim()) : undefined);
	fm = upsertYamlField(fm, "tools", undefined);
	fm = upsertYamlField(fm, "deny-tools", edit.denyTools.length > 0 ? edit.denyTools.join(", ") : undefined);
	fm = upsertYamlField(fm, "color", edit.color.trim() ? yamlScalar(edit.color.trim()) : undefined);
	return `---\n${fm.replace(/\n*$/, "")}\n---\n\n${split.body.replace(/^\n+/, "")}`;
}

function agentSearchText(agent: AgentConfig, status?: AgentPaneStatus): string {
	return [
		agent.name,
		agent.description,
		agent.source,
		agent.filePath,
		agent.model ?? "",
		agent.denyTools?.join(" ") ?? "",
		agent.pane ? "pane persistent tmux" : "bg background one-shot oneshot",
		status?.live ? "live running" : status?.entry ? "dead stopped" : "",
	].join(" ").toLowerCase();
}

function filterAgentsForBrowser(agents: AgentConfig[], query: string, statuses: Map<string, AgentPaneStatus>): AgentConfig[] {
	const tokens = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
	if (tokens.length === 0) return agents;
	return agents.filter((agent) => tokens.every((token) => agentSearchText(agent, statuses.get(agent.name)).includes(token)));
}

function tabNext(current: AgentBrowserTabId, _hasActive: boolean, delta: number): AgentBrowserTabId {
	const tabs: AgentBrowserTabId[] = ["agents", "history"];
	const index = Math.max(0, tabs.indexOf(current));
	return tabs[(index + delta + tabs.length) % tabs.length]!;
}

async function loadAgentPaneStatuses(runtimeRoot: string): Promise<Map<string, AgentPaneStatus>> {
	const registry = await readPaneRegistry(runtimeRoot);
	const entries = await Promise.all(
		Object.entries(registry).map(async ([agentName, entry]) => [agentName, { entry, live: await paneExists(entry.paneId) }] as const),
	);
	return new Map(entries);
}

function agentFrameContentWidth(width: number): number {
	return Math.max(1, width - 2 - AGENTS_POPUP_PADDING_X * 2);
}

function agentBrowserLayout(terminalRows: number): AgentBrowserLayout {
	const innerRows = Math.max(1, Math.floor(Math.max(1, terminalRows) * AGENTS_BROWSER_HEIGHT_RATIO) - AGENTS_POPUP_FRAME_ROWS);
	const bodyRows = Math.max(0, innerRows - 9);
	return {
		bodyRows,
		innerRows,
		listRows: Math.max(1, bodyRows - 3),
	};
}

function agentDivider(width: number, theme: Theme): string {
	return theme.fg("dim", "─".repeat(Math.max(1, width)));
}

function agentFrame(lines: string[], width: number, theme: Theme, fixedInnerRows = 30, title = ""): string[] {
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

function agentActivePill(theme: Theme, label: string): string {
	return theme.fg("accent", theme.inverse(theme.bold(label)));
}

function agentInactivePill(theme: Theme, label: string): string {
	return theme.bg("selectedBg", theme.fg("accent", label));
}

function agentPaneTitle(theme: Theme, label: string, active: boolean): string {
	const padded = ` ${label} `;
	return active ? agentActivePill(theme, padded) : agentInactivePill(theme, padded);
}

function agentEntityTitle(theme: Theme, label: string): string {
	return ansiMagenta(theme.bold(label));
}

function renderAgentBrowserTabs(active: AgentBrowserTabId, hasActive: boolean, width: number, theme: Theme): string {
	void hasActive;
	const tabs = [AGENTS_BROWSER_TAB, HISTORY_BROWSER_TAB];
	const partFor = (tab: AgentBrowserTabDef): string => {
		const label = ` ${truncateToWidth(tab.label, 18, "…")} `;
		if (tab.id === active) return agentActivePill(theme, label);
		return agentInactivePill(theme, label);
	};
	return truncateToWidth(tabs.map(partFor).join(" "), width, "");
}

function agentStatus(agent: AgentConfig, status: AgentPaneStatus | undefined): "live" | "dead" | "pane" | "bg" {
	if (!agent.pane) return "bg";
	if (status?.live) return "live";
	if (status?.entry) return "dead";
	return "pane";
}

function agentStatusColor(status: ReturnType<typeof agentStatus>): "success" | "warning" | "muted" | "dim" {
	if (status === "live") return "success";
	if (status === "dead") return "warning";
	if (status === "pane") return "muted";
	return "dim";
}

function agentStatusIcon(status: ReturnType<typeof agentStatus>, theme: Theme): string {
	if (status === "live") return theme.fg("success", ICONS.circleFilled);
	if (status === "dead") return theme.fg("warning", ICONS.times);
	if (status === "pane") return theme.fg("warning", ICONS.circleOpen);
	return theme.fg("dim", "·");
}

function agentStatusLabel(agent: AgentConfig, status: AgentPaneStatus | undefined, theme: Theme): string {
	const state = agentStatus(agent, status);
	if (state === "live") return theme.fg("success", "live");
	if (state === "dead") return theme.fg("warning", "dead");
	if (state === "pane") return theme.fg("muted", "startable");
	return theme.fg("dim", "bg");
}

interface AgentBrowserRow {
	agent: AgentConfig;
	item?: SubagentDashboardItem;
	label: string;
	record?: PaneTaskRecord;
	rowType: "agent" | "task";
	taskNumber?: number;
}

const RECENT_TASK_CHILD_LIMIT = 5;

function dashboardItemSearchText(item: SubagentDashboardItem, label: string): string {
	return [
		label,
		item.agent,
		item.kind,
		item.status,
		item.taskId,
		item.task ?? "",
		item.message ?? "",
		item.sessionMode ?? "",
		item.sessionKey ?? "",
		item.transcriptPath ?? "",
	].join(" ").toLowerCase();
}

function dashboardItemFromTaskRecord(record: PaneTaskRecord): SubagentDashboardItem {
	const terminal = record.status === "completed" || record.status === "failed" || record.status === "blocked" || record.status === "needs_completion";
	const hasSummary = Boolean(record.summary?.trim());
	const message = record.summary?.trim()
		? record.summary
		: terminal
			? COMPLETION_SUMMARY_UNAVAILABLE
			: record.task || record.diagnostics?.at(-1);
	const messageProvenance: CompletionMessageProvenance = hasSummary ? "persisted" : terminal ? "placeholder" : record.task ? "task-echo-fallback" : "diagnostic";
	return {
		agent: record.agent,
		artifacts: Boolean(record.transcriptPath || record.completionArchivePath || record.outboxFile || record.doneFile),
		completedAt: record.completedAt,
		kind: record.kind ?? (record.paneId || record.inboxFile || record.outboxFile || record.doneFile ? "pane" : "oneshot"),
		message,
		messageProvenance,
		model: record.model,
		paneId: record.paneId,
		sessionMode: record.sessionMode,
		sessionKey: record.sessionKey,
		startedAt: record.createdAt,
		status: record.status,
		task: record.task,
		taskId: record.taskId,
		transcriptPath: record.transcriptPath,
		updatedAt: record.updatedAt ?? record.completedAt ?? record.createdAt,
		usage: record.usage,
	};
}

function taskRecordsByAgent(taskRegistry: PaneTaskRegistry): Map<string, PaneTaskRecord[]> {
	const out = new Map<string, PaneTaskRecord[]>();
	for (const record of sortedHistoryRecords(taskRegistry)) {
		const list = out.get(record.agent) ?? [];
		list.push(record);
		out.set(record.agent, list);
	}
	return out;
}

export function buildAgentRows(agents: AgentConfig[], query: string, statuses: Map<string, AgentPaneStatus>, activeItems: SubagentDashboardItem[], taskRegistry: PaneTaskRegistry = {}): AgentBrowserRow[] {
	const tokens = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
	const activeByTask = new Map(activeItems.map((item) => [item.taskId, item]));
	const activeByAgent = activeItemsByAgent(activeItems);
	const recordsByAgent = taskRecordsByAgent(taskRegistry);
	const taskNumbers = taskNumberById(Object.values(taskRegistry));
	const rows: AgentBrowserRow[] = [];
	const catalogAgents = sortAgentsForUnifiedView(agents, statuses, activeItems);
	for (const agent of catalogAgents) {
		const records = recordsByAgent.get(agent.name) ?? [];
		const latestRecord = records[0];
		const activeItem = activeByAgent.get(agent.name);
		const agentItem = activeItem ?? (latestRecord ? dashboardItemFromTaskRecord(latestRecord) : undefined);
		const childRows = records.slice(0, RECENT_TASK_CHILD_LIMIT).map((record): AgentBrowserRow => ({
			agent,
			item: activeByTask.get(record.taskId) ?? dashboardItemFromTaskRecord(record),
			label: `#${taskNumbers.get(record.taskId) ?? "?"} · ${recordClockTime(record)} · ${shortTaskSuffix(record.taskId)}`,
			record,
			rowType: "task",
			taskNumber: taskNumbers.get(record.taskId),
		}));
		const agentSearch = `${agentSearchText(agent, statuses.get(agent.name))} ${agentItem ? dashboardItemSearchText(agentItem, agent.name) : ""}`.toLowerCase();
		const matchingChildren = childRows.filter((row) => {
			const text = `${row.label} ${row.record?.task ?? ""} ${row.record?.summary ?? ""} ${row.record?.taskId ?? ""} ${row.record?.transcriptPath ?? ""}`.toLowerCase();
			return tokens.length === 0 || tokens.every((token) => text.includes(token) || agentSearch.includes(token));
		});
		const includeAgent = tokens.length === 0 || tokens.every((token) => agentSearch.includes(token)) || matchingChildren.length > 0;
		if (!includeAgent) continue;
		rows.push({ agent, item: agentItem, label: agent.name, record: latestRecord, rowType: "agent", taskNumber: latestRecord ? taskNumbers.get(latestRecord.taskId) : undefined });
		rows.push(...matchingChildren);
	}
	return rows;
}

function activeItemsByAgent(items: SubagentDashboardItem[]): Map<string, SubagentDashboardItem> {
	const out = new Map<string, SubagentDashboardItem>();
	for (const item of sortDashboardItems(items)) {
		if (!out.has(item.agent)) out.set(item.agent, item);
	}
	return out;
}

function unifiedAgentRank(agent: AgentConfig, status: AgentPaneStatus | undefined, activeItem: SubagentDashboardItem | undefined): number {
	if (activeItem && isDashboardWorkingStatus(activeItem.status)) return 0;
	if (activeItem && isDashboardAttentionStatus(activeItem.status)) return 1;
	if (activeItem?.status === "completed") return 2;
	const state = agentStatus(agent, status);
	if (state === "live") return 3;
	if (state === "dead") return 4;
	if (state === "pane") return 5;
	return 6;
}

function sortAgentsForUnifiedView(agents: AgentConfig[], statuses: Map<string, AgentPaneStatus>, activeItems: SubagentDashboardItem[]): AgentConfig[] {
	const activeByAgent = activeItemsByAgent(activeItems);
	return [...agents].sort((a, b) => {
		const rank = unifiedAgentRank(a, statuses.get(a.name), activeByAgent.get(a.name)) - unifiedAgentRank(b, statuses.get(b.name), activeByAgent.get(b.name));
		if (rank !== 0) return rank;
		return a.name.localeCompare(b.name);
	});
}

function agentLegend(theme: Theme): string {
	return `${theme.fg("muted", "Legend")}: ${theme.fg("success", ICONS.circleFilled)} live · ${theme.fg("warning", ICONS.circleOpen)} startable · ${theme.fg("warning", ICONS.times)} stale`;
}

function renderAgentList(rows: AgentBrowserRow[], statuses: Map<string, AgentPaneStatus>, ui: AgentBrowserUiState, width: number, theme: Theme, listRows: number): string[] {
	const lines = [`${agentPaneTitle(theme, "Agents", ui.pane === "list")} ${theme.fg("dim", `(${rows.length})`)}`, ""];
	if (rows.length === 0) {
		lines.push(theme.fg("dim", "No matching agents."));
		return lines;
	}
	if (ui.scroll > 0) lines.push(theme.fg("dim", `↑ ${ui.scroll} earlier`));
	for (const [visibleIndex, rowInfo] of rows.slice(ui.scroll, ui.scroll + listRows).entries()) {
		const index = ui.scroll + visibleIndex;
		const selected = index === ui.selected;
		const agent = rowInfo.agent;
		const status = agentStatus(agent, statuses.get(agent.name));
		const marker = rowInfo.rowType === "task" ? theme.fg("dim", "  └ ") : " ";
		const name = rowInfo.rowType === "task"
			? theme.fg("muted", selected ? theme.bold(rowInfo.label) : rowInfo.label)
			: ansiMagenta(selected ? theme.bold(rowInfo.label) : rowInfo.label);
		const icon = rowInfo.item ? dashboardStatusIcon(rowInfo.item.status, theme) : agentStatusIcon(status, theme);
		const meta = rowInfo.rowType === "task"
			? rowInfo.item ? `${theme.fg("dim", ` · ${dashboardKindLabel(rowInfo.item.kind)}`)}${sessionModeChipSuffix(theme, rowInfo.item)}${rowInfo.item.kind === "pane" && rowInfo.item.transcriptPath ? theme.fg("dim", " · shared transcript") : ""}` : ""
			: rowInfo.item ? `${theme.fg("dim", " · ")}${dashboardStatusText(rowInfo.item, theme)}` : "";
		const row = truncateToWidth(`${marker}${icon} ${name}${meta}`, width, "…");
		lines.push(selected ? theme.bg("selectedBg", agentPad(row, width)) : row);
	}
	const hidden = Math.max(0, rows.length - (ui.scroll + listRows));
	if (hidden > 0) lines.push(theme.fg("dim", `↓ ${hidden} more`));
	return lines;
}

function renderAgentPromptViewport(agent: AgentConfig, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	const prompt = agent.systemPrompt.trim() || theme.fg("dim", "(empty prompt)");
	const promptLines = new Markdown(prompt, 0, 0, getMarkdownTheme()).render(width);
	const visibleRows = Math.max(1, rows - 1);
	const maxScroll = Math.max(0, promptLines.length - visibleRows);
	ui.inspectorScroll = Math.max(0, Math.min(ui.inspectorScroll, maxScroll));
	const visible = promptLines.slice(ui.inspectorScroll, ui.inspectorScroll + visibleRows);
	const before = ui.inspectorScroll > 0 ? `↑ ${ui.inspectorScroll}` : "";
	const afterCount = Math.max(0, promptLines.length - ui.inspectorScroll - visibleRows);
	const after = afterCount > 0 ? `↓ ${afterCount}` : "";
	const scroll = [before, after].filter(Boolean).join(" · ");
	return scroll ? [...visible, theme.fg("dim", scroll)] : visible;
}

function renderAgentInspector(agent: AgentConfig | undefined, statuses: Map<string, AgentPaneStatus>, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	if (!agent) return [`${agentPaneTitle(theme, "Inspector", ui.pane === "inspector")} ${theme.fg("dim", "Select an agent to inspect it.")}`];
	const status = statuses.get(agent.name);
	const safeWidth = Math.max(8, width);
	const pushWrapped = (target: string[], text: string) => {
		const wrapped = wrapTextWithAnsi(text, safeWidth);
		target.push(...(wrapped.length > 0 ? wrapped : [""]));
	};
	const lines: string[] = [];
	pushWrapped(
		lines,
		`${agentPaneTitle(theme, "Inspector", ui.pane === "inspector")} ${agentEntityTitle(theme, agent.name)} ${theme.fg(agentStatusColor(agentStatus(agent, status)), agentStatus(agent, status))}`,
	);
	lines.push("");
	lines.push(...wrapTextWithAnsi(agent.description || "No description.", safeWidth).slice(0, 3));
	lines.push("");
	pushWrapped(
		lines,
		`${theme.fg("muted", "Kind")}: ${agent.pane ? "persistent pane" : "bg"}    ${theme.fg("muted", "Scope")}: ${agent.source}`,
	);
	pushWrapped(lines, `${theme.fg("muted", "Model")}: ${agent.model ?? "default"}`);
	pushWrapped(lines, `${theme.fg("muted", "Deny tools")}: ${agent.denyTools && agent.denyTools.length > 0 ? agent.denyTools.join(", ") : "none"}`);
	pushWrapped(lines, `${theme.fg("muted", "Path")}: ${compactAgentPath(agent.filePath)}`);
	pushWrapped(lines, `${theme.fg("muted", "State")}: ${agentStatusLabel(agent, status, theme)}`);
	if (status?.entry) {
		pushWrapped(lines, `${theme.fg("muted", "Pane")}: ${status.entry.windowName}`);
		pushWrapped(lines, `${theme.fg("muted", "Last task")}: ${status.entry.lastTaskAt ?? "never"}`);
	}
	lines.push("", theme.fg("muted", theme.bold("System Prompt")));
	const promptRows = Math.max(1, rows - lines.length);
	lines.push(...renderAgentPromptViewport(agent, ui, safeWidth, promptRows, theme));
	return lines.slice(0, rows);
}

export function activeDashboardItems(items: SubagentDashboardItem[]): SubagentDashboardItem[] {
	return sortDashboardItems(items);
}

export function readTranscriptTail(transcriptPath: string | undefined, maxLines: number): string[] {
	if (!transcriptPath) return [];
	// Pi's --mode json stream emits ~50-100x more streaming-delta events
	// (message_update, tool_execution_update) than terminal ones, and the
	// deltas carry partial/empty argument objects. Rendering them produces a
	// flood of duplicate "assistant: [tool] bash {}" lines that don't reflect
	// real activity. Restrict to terminal lifecycle events that carry final
	// content. tool_execution_start is kept so we still see the tool call
	// before its result arrives.
	const INCLUDED_EVENT_TYPES = new Set([
		"start",
		"agent_start",
		"session",
		"turn_start",
		"turn_end",
		"message_end",
		"tool_execution_start",
		"tool_execution_end",
		"tool_result_end",
		"exit",
	]);
	try {
		const raw = fs.readFileSync(transcriptPath, "utf-8");
		const lines = raw.split(/\r?\n/);
		const rendered: string[] = [];
		let lastRendered: string | undefined;
		const push = (text: string | undefined) => {
			if (text === undefined) return;
			const parts = String(text).replace(/\r\n/g, "\n").split("\n");
			for (const part of parts) {
				if (part === lastRendered) continue;
				lastRendered = part;
				rendered.push(part);
			}
		};
		const pushSection = (label: string, ts?: string) => {
			push(`── ${label}${ts ? ` · ${ts}` : ""} ──`);
		};
		const eventTime = (outer: any, inner: any): string | undefined => {
			const rawTs = typeof outer?.ts === "string" ? outer.ts : typeof inner?.timestamp === "string" ? inner.timestamp : undefined;
			if (!rawTs) return undefined;
			const date = new Date(rawTs);
			if (!Number.isFinite(date.getTime())) return rawTs;
			return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}:${String(date.getSeconds()).padStart(2, "0")}`;
		};
		const pushJson = (value: unknown) => {
			try {
				const text = JSON.stringify(value ?? {}, null, 2);
				for (const line of text.split(/\r?\n/)) push(line);
			} catch {
				push(String(value));
			}
		};
		for (const line of lines) {
			if (!line.trim()) continue;
			let event: any;
			try { event = JSON.parse(line); } catch { push(line); continue; }
			const inner = event?.event && typeof event.event === "object" ? event.event : event;
			const innerType = typeof inner?.type === "string" ? inner.type : undefined;
			if (innerType && !INCLUDED_EVENT_TYPES.has(innerType)) continue;
			const ts = eventTime(event, inner);
			const msg = inner?.message;
			if (msg && typeof msg === "object") {
				const role = msg.role || innerType || "?";
				const content = Array.isArray(msg.content) ? msg.content : [];
				const tool = content.find((c: any) => c?.type === "toolCall");
				if (tool) {
					const args = tool.arguments ?? tool.args ?? {};
					pushSection(`${role} tool call ${tool.name ?? "?"}`, ts);
					if (Object.keys(args).length > 0) pushJson(args);
				} else {
					const text = textFromMessageContent(msg.content);
					if (text.trim()) {
						pushSection(String(role), ts);
						push(text);
					} else if (innerType) pushSection(`${role} (${innerType})`, ts);
				}
				continue;
			}
			// tool_execution_start/end carry identity in inner.toolName + inner.toolCallId
			// at the top level (not inside a .message or .call). Render the tool name
			// and a short id so dedup doesn't collapse two distinct tool runs into a
			// single bare event-type line.
			if (innerType && typeof inner?.toolName === "string") {
				const rawId = typeof inner.toolCallId === "string" ? inner.toolCallId : "";
				const id = rawId ? rawId.split("|").pop()?.slice(-8) : undefined;
				const suffix = id ? ` · ${id}` : "";
				const phase = innerType === "tool_execution_start" ? "tool start" : innerType === "tool_execution_end" ? "tool end" : innerType;
				pushSection(`${phase} ${inner.toolName}${suffix}`, ts);
				const result = inner.result ?? inner.output ?? inner.content;
				if (innerType === "tool_result_end" && result) push(typeof result === "string" ? result : JSON.stringify(result, null, 2));
				continue;
			}
			if (innerType) {
				if (innerType === "turn_start" || innerType === "turn_end") pushSection(innerType.replace("_", " "), ts);
				else if (innerType === "exit") pushSection(`exit${typeof inner?.code === "number" ? ` ${inner.code}` : ""}`, ts);
				else pushSection(innerType, ts);
				continue;
			}
			push(line);
		}
		return rendered.slice(-maxLines);
	} catch {
		return [];
	}
}

// Multiple bg launches of the same agent name produce distinct dashboard rows
// (keyed by taskId). Disambiguate the rendered label with a 1-based occurrence
// suffix in start-time order: "reviewer-arch", "reviewer-arch 2", ... Pane
// agents collapse to a single row per name so they never collide here.
export function dashboardDisplayLabels(items: SubagentDashboardItem[], persistentTaskNumbers?: Map<string, number>): Map<string, string> {
	// Numbering source order:
	//   1. persistent taskNumberById (from tasks.json) when supplied. This is
	//      the canonical per-agent #N the popup's nested task-children and
	//      Detail header already use, so a task reads identically across
	//      every surface (mini widget, popup left-list, task-children,
	//      Detail header, Chat attribution).
	//   2. In-memory occurrence counter as a fallback for items dispatched
	//      in this turn that haven't been persisted yet, AND so callers
	//      that can't cheaply load the registry still get stable labels.
	const occurrence = new Map<string, number>();
	const total = new Map<string, number>();
	for (const item of items) total.set(item.agent, (total.get(item.agent) ?? 0) + 1);
	const sorted = [...items].sort((a, b) => {
		const aKey = a.startedAt ?? a.taskId;
		const bKey = b.startedAt ?? b.taskId;
		if (aKey === bKey) return 0;
		return aKey < bKey ? -1 : 1;
	});
	const labels = new Map<string, string>();
	for (const item of sorted) {
		const next = (occurrence.get(item.agent) ?? 0) + 1;
		occurrence.set(item.agent, next);
		const persistentN = persistentTaskNumbers?.get(item.taskId);
		const n = persistentN ?? next;
		const showNumber = persistentN !== undefined || (total.get(item.agent) ?? 1) > 1;
		const label = showNumber ? `${item.agent} #${n}` : item.agent;
		labels.set(item.taskId, label);
	}
	return labels;
}

function renderActiveAgentList(items: SubagentDashboardItem[], ui: AgentBrowserUiState, width: number, theme: Theme, listRows: number, persistentTaskNumbers?: Map<string, number>): string[] {
	const lines = [`${agentPaneTitle(theme, "Active", ui.pane === "list")} ${theme.fg("dim", `(${items.length})`)}`, ""];
	if (ui.activeScroll > 0) lines.push(theme.fg("dim", `\u2191 ${ui.activeScroll} earlier`));
	const visible = items.slice(ui.activeScroll, ui.activeScroll + listRows);
	const labels = dashboardDisplayLabels(items, persistentTaskNumbers);
	for (const [index, item] of visible.entries()) {
		const absoluteIndex = ui.activeScroll + index;
		const selected = absoluteIndex === ui.activeSelected;
		const icon = dashboardStatusIcon(item.status, theme);
		const displayName = labels.get(item.taskId) ?? item.agent;
		const name = selected ? ansiMagenta(theme.bold(displayName)) : ansiMagenta(displayName);
		const sessionChip = sessionModeChipLabel(item);
		const meta = `${theme.fg("dim", ` · ${dashboardKindLabel(item.kind)}`)}${sessionChip ? theme.fg("dim", ` · ${sessionChip}`) : ""}`;
		const row = `${icon} ${name}${meta}`;
		const prefix = selected ? theme.fg("accent", "> ") : "  ";
		lines.push(truncateToWidth(`${prefix}${row}`, width, ""));
	}
	const after = items.length - (ui.activeScroll + visible.length);
	if (after > 0) lines.push(theme.fg("dim", `\u2193 ${after} more`));
	return lines;
}

function renderActiveAgentDetail(item: SubagentDashboardItem | undefined, displayLabel: string | undefined, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	if (!item) return [`${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${theme.fg("dim", "Select an agent to inspect.")}`];
	const safeWidth = Math.max(8, width);
	const wrap = (text: string): string[] => {
		const wrapped = wrapTextWithAnsi(text, safeWidth);
		return wrapped.length > 0 ? wrapped : [""];
	};
	const nameForTitle = displayLabel ?? item.agent;
	const titleLine = `${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${ansiMagenta(theme.bold(nameForTitle))} ${dashboardStatusText(item, theme)} ${theme.fg("dim", `· ${dashboardKindLabel(item.kind)}`)}${sessionModeChipSuffix(theme, item)}`;
	const body: string[] = [];
	body.push(...wrap(`${theme.fg("muted", "Task ID")}: ${theme.fg("dim", item.taskId)}`));
	// Show the full transcript file path at the top so users always have
	// a one-line pointer to inspect the raw session record themselves.
	// Pane agents share one transcript across multiple tasks; flag that
	// explicitly so the path isn't misread as task-scoped.
	if (item.transcriptPath) {
		const sharedTag = item.kind === "pane" ? theme.fg("dim", " (shared by pane tasks)") : "";
		const path = compactPath(item.transcriptPath, { maxChars: Number.POSITIVE_INFINITY });
		body.push(...wrapPlainNoEllipsis(`Transcript: ${path}`, safeWidth).map((line, idx) =>
			idx === 0 ? `${theme.fg("muted", "Transcript")}: ${theme.fg("dim", line.replace(/^Transcript:\s*/, ""))}${sharedTag}` : theme.fg("dim", line),
		));
	}
	body.push("");
	if (item.task) {
		body.push(...wrap(theme.fg("accent", theme.bold("Task:"))));
		for (const raw of item.task.split(/\r?\n/)) body.push(...renderTraceContentLine(raw, "task", safeWidth, theme));
	}
	if (item.usage) {
		const usageLine = formatUsageStatsForDashboard(item.usage).join(" \u00b7 ");
		if (usageLine) body.push(...wrap(`${theme.fg("muted", "Usage")}: ${theme.fg("dim", usageLine)}`));
	}
	if (item.message) {
		body.push("");
		body.push(...wrap(theme.fg("accent", theme.bold("Latest Message"))));
		const wrapped = item.message.split(/\r?\n/).flatMap((line) => renderTraceContentLine(line, "summary", safeWidth, theme));
		body.push(...wrapped.slice(0, 8));
	}
	const allLines: string[] = [titleLine, ""];
	const visibleBodyRows = Math.max(1, rows - 2);
	const maxOffset = Math.max(0, body.length - visibleBodyRows);
	const offset = Math.max(0, Math.min(ui.inspectorScroll, maxOffset));
	ui.inspectorScroll = offset;
	const slice = body.slice(offset, offset + visibleBodyRows);
	allLines.push(...slice);
	if (offset > 0 || maxOffset > 0) {
		const hint = `${offset > 0 ? `\u2191 ${offset} earlier` : ""}${offset > 0 && offset < maxOffset ? "  " : ""}${offset < maxOffset ? `\u2193 ${maxOffset - offset} more` : ""}`.trim();
		if (hint && allLines.length < rows) {
			const lastIndex = allLines.length - 1;
			allLines[lastIndex] = `${allLines[lastIndex]} ${ansiYellow(hint)}`;
		}
	}
	return allLines.slice(0, rows);
}

export function formatRelativeTime(iso: string | undefined): string {
	if (!iso) return "—";
	const ts = Date.parse(iso);
	if (!Number.isFinite(ts)) return "—";
	const delta = Date.now() - ts;
	if (delta < 0) return "just now";
	const sec = Math.floor(delta / 1000);
	if (sec < 60) return `${sec}s ago`;
	const min = Math.floor(sec / 60);
	if (min < 60) return `${min}m ago`;
	const hr = Math.floor(min / 60);
	if (hr < 24) return `${hr}h ago`;
	const day = Math.floor(hr / 24);
	if (day < 30) return `${day}d ago`;
	const mo = Math.floor(day / 30);
	if (mo < 12) return `${mo}mo ago`;
	return new Date(ts).toISOString().slice(0, 10);
}

function historyStatusIcon(status: PaneTaskStatus, theme: Theme): string {
	if (status === "completed") return theme.fg("success", ICONS.check);
	if (status === "failed") return theme.fg("error", ICONS.times);
	if (status === "blocked") return theme.fg("warning", ICONS.times);
	if (status === "running") return dashboardStatusIcon("running", theme);
	if (status === "queued") return theme.fg("warning", ICONS.clock);
	return theme.fg("muted", "·");
}

function historyStatusText(status: PaneTaskStatus, theme: Theme): string {
	return theme.fg(paneCompletionTone(status), status);
}

function sortedHistoryRecords(registry: PaneTaskRegistry): PaneTaskRecord[] {
	return Object.values(registry)
		.filter((record) => record.taskId && record.agent)
		.sort((a, b) => recordTimestampLocal(b) - recordTimestampLocal(a));
}

export function taskNumberById(records: PaneTaskRecord[]): Map<string, number> {
	const byAgent = new Map<string, PaneTaskRecord[]>();
	for (const record of records) {
		if (!record.taskId || !record.agent) continue;
		const list = byAgent.get(record.agent) ?? [];
		list.push(record);
		byAgent.set(record.agent, list);
	}
	const out = new Map<string, number>();
	for (const list of byAgent.values()) {
		list
			.sort((a, b) => {
				const delta = recordTimestampLocal(a) - recordTimestampLocal(b);
				return delta !== 0 ? delta : a.taskId.localeCompare(b.taskId);
			})
			.forEach((record, index) => out.set(record.taskId, index + 1));
	}
	return out;
}

function recordClockTime(record: PaneTaskRecord): string {
	const raw = record.completedAt ?? record.updatedAt ?? record.createdAt;
	if (!raw) return "--:--";
	const date = new Date(raw);
	if (!Number.isFinite(date.getTime())) return "--:--";
	return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

export function historyRecordLabel(record: PaneTaskRecord, taskNumbers: Map<string, number>): string {
	const number = taskNumbers.get(record.taskId);
	const numberText = number ? ` #${number}` : "";
	return `${record.agent}${numberText} · ${recordClockTime(record)} · ${shortTaskSuffix(record.taskId)}`;
}

function recordTimestampLocal(record: PaneTaskRecord): number {
	const value = Date.parse(record.completedAt ?? record.createdAt ?? "");
	return Number.isFinite(value) ? value : 0;
}

function renderHistoryList(records: PaneTaskRecord[], ui: AgentBrowserUiState, width: number, theme: Theme, listRows: number): string[] {
	const lines = [`${agentPaneTitle(theme, "Tasks", ui.pane === "list")} ${theme.fg("dim", `(${records.length})`)}`, ""];
	if (records.length === 0) {
		lines.push(theme.fg("dim", "No agent task history yet."));
		return lines;
	}
	if (ui.historyScroll > 0) lines.push(theme.fg("dim", `↑ ${ui.historyScroll} earlier`));
	const taskNumbers = taskNumberById(records);
	for (const [visibleIndex, record] of records.slice(ui.historyScroll, ui.historyScroll + listRows).entries()) {
		const index = ui.historyScroll + visibleIndex;
		const selected = index === ui.historySelected;
		const icon = historyStatusIcon(record.status, theme);
		const label = historyRecordLabel(record, taskNumbers);
		const name = ansiMagenta(selected ? theme.bold(label) : label);
		const row = truncateToWidth(`${icon} ${name}`, width, "…");
		lines.push(selected ? theme.bg("selectedBg", agentPad(row, width)) : row);
	}
	const hidden = Math.max(0, records.length - (ui.historyScroll + listRows));
	if (hidden > 0) lines.push(theme.fg("dim", `↓ ${hidden} more`));
	return lines;
}

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

function renderTraceContentLine(raw: string, type: TraceViewerItem["type"] | undefined, width: number, theme: Theme): string[] {
	const line = raw.replace(/\t/g, "  ");
	const trimmed = line.trim();
	if (!trimmed) return [""];
	if (/^── .+ ──$/.test(trimmed)) return wrapTextWithAnsi(theme.fg("muted", trimmed.replace(/(assistant|user|tool call|tool start|tool end|turn start|turn end|exit)/i, (match) => theme.fg("accent", theme.bold(match)))), width);
	if (/^-{3,}$/.test(trimmed)) return [];
	if (/^(Overview|Metadata|Summary|Files changed|Validation|Notes|Task|Artifacts)$/i.test(trimmed)) {
		return wrapTextWithAnsi(theme.fg("accent", theme.bold(trimmed)), width);
	}
	const labelMatch = line.match(/^(Ref|Agent|Task #|Status|Task ID|Created|Done|Model|Session|Usage|Transcript|Completion|Archive|Source)\s{2,}(.+)$/);
	if (labelMatch) return wrapTextWithAnsi(colorTraceValue(labelMatch[1], labelMatch[2], theme), width);
	if (type === "completion" || type === "transcript") {
		const jsonKey = line.match(/^(\s*)"([^"]+)"(\s*:\s*)(.*)$/);
		if (jsonKey) return wrapTextWithAnsi(`${jsonKey[1]}${theme.fg("accent", `"${jsonKey[2]}"`)}${theme.fg("dim", jsonKey[3])}${theme.fg("toolOutput", jsonKey[4])}`, width);
	}
	const bullet = line.match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
	if (bullet) return wrapTextWithAnsi(`${bullet[1]}${theme.fg("accent", bullet[2])} ${theme.fg("toolOutput", bullet[3])}`, width);
	const markdownHeading = line.match(/^(#{1,6})\s+(.*)$/);
	if (markdownHeading) return wrapTextWithAnsi(`${theme.fg("accent", markdownHeading[1])} ${theme.fg("accent", theme.bold(markdownHeading[2]))}`, width);
	const backtick = line.replace(/`([^`]+)`/g, (_m: string, code: string) => theme.fg("accent", code));
	return wrapTextWithAnsi(theme.fg(type === "summary" ? "text" : "toolOutput", backtick), width);
}

function renderHistoryDetail(
	record: PaneTaskRecord | undefined,
	cache: Map<string, HistoryDetailEntry>,
	ui: AgentBrowserUiState,
	width: number,
	rows: number,
	theme: Theme,
): string[] {
	if (!record) {
		return [`${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${theme.fg("dim", "Select a task to view its trace.")}`];
	}
	const safeWidth = Math.max(8, width);
	const entry = cache.get(record.taskId);
	const items = entry?.items;
	const placeholderText = entry?.error ? `Error: ${entry.error}` : entry?.loading || !items ? "Loading…" : "(empty)";
	const subtabs: TraceViewerItem[] = items ?? HISTORY_SUBTAB_LABELS.map((label) => ({ label, text: placeholderText, type: label.toLowerCase() as TraceViewerItem["type"] }));
	const subtabIndex = Math.max(0, Math.min(ui.historySubtab, subtabs.length - 1));
	ui.historySubtab = subtabIndex;
	const when = formatRelativeTime(record.completedAt ?? record.createdAt);
	const titleLine = `${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${ansiMagenta(theme.bold(record.agent))} ${historyStatusText(record.status, theme)} ${theme.fg("dim", `· ${when}`)}`;
	const subtabLine = renderTraceTabBar(subtabs, subtabIndex, safeWidth, theme);
	const item = subtabs[subtabIndex];
	const fileLines = item?.path
		? [
			...wrapPlainNoEllipsis(`file ${compactPath(item.path, { maxChars: Number.POSITIVE_INFINITY })}`, safeWidth).map((line) => theme.fg("dim", line)),
			agentDivider(safeWidth, theme),
		]
			: [];
	const rawLines = (item?.text || "(empty)").split(/\r?\n/);
	const wrapped: string[] = [];
	for (const raw of rawLines) {
		const chunk = renderTraceContentLine(raw, item?.type, safeWidth, theme);
		wrapped.push(...(chunk.length > 0 ? chunk : [""]));
	}
	const header: string[] = [titleLine, "", subtabLine, "", ...fileLines];
	const headerRows = header.length;
	const footerRows = 1;
	const visibleRows = Math.max(1, rows - headerRows - footerRows);
	const maxScroll = Math.max(0, wrapped.length - visibleRows);
	ui.inspectorScroll = Math.max(0, Math.min(ui.inspectorScroll, maxScroll));
	const slice = wrapped.slice(ui.inspectorScroll, ui.inspectorScroll + visibleRows);
	const before = ui.inspectorScroll > 0 ? `↑ ${ui.inspectorScroll}` : "";
	const afterCount = Math.max(0, wrapped.length - ui.inspectorScroll - visibleRows);
	const after = afterCount > 0 ? `↓ ${afterCount}` : "";
	const scrollHint = [before, after].filter(Boolean).join(" · ");
	const out: string[] = [...header];
	out.push(...slice);
	if (scrollHint) out.push(ansiYellow(scrollHint));
	else out.push("");
	return out.slice(0, rows);
}

function deriveTaskIdFromFile(file: string): string | undefined {
	const base = path.basename(file, path.extname(file));
	const stripped = base.replace(/^\d{10,}-/, "");
	return stripped || base || undefined;
}

function trimChatBody(text: string, max = 4_000): string {
	const compact = text.trim();
	if (compact.length <= max) return compact;
	return `${compact.slice(0, max)}\n\u2026(truncated)`;
}

function normalizeTaskRegistryShape(parsed: unknown): PaneTaskRegistry {
	if (Array.isArray(parsed)) return Object.fromEntries(parsed.filter((record) => record?.taskId).map((record) => [record.taskId, record])) as PaneTaskRegistry;
	return parsed && typeof parsed === "object" ? parsed as PaneTaskRegistry : {};
}

export function loadTaskRegistrySync(runtimeRoot: string): PaneTaskRegistry {
	try {
		return normalizeTaskRegistryShape(JSON.parse(fs.readFileSync(taskRegistryPath(runtimeRoot), "utf-8")));
	} catch {
		return {};
	}
}

function completionBodyFromRecord(record: PaneTaskRecord | undefined, fallback: string | undefined, task: string | undefined, fallbackProvenance: CompletionMessageProvenance = "fallback"): string {
	if (record?.summary?.trim()) return completionBodyWithoutPromptEcho(record.summary, record.task ?? task, "persisted");
	return completionBodyWithoutPromptEcho(fallback, record?.task ?? task, fallbackProvenance);
}

function extractDelegationBody(raw: string): string {
	const lines = raw.split(/\r?\n/);
	const out: string[] = [];
	let started = false;
	for (const line of lines) {
		if (!started) {
			if (/^Task for /.test(line) || /^Task ID:/.test(line)) continue;
			if (line.trim() === "") continue;
			started = true;
		}
		if (/^When done, /.test(line)) break;
		if (/^If complete_subagent is unavailable/.test(line)) break;
		if (/^Do not complete before the work is actually done/.test(line)) break;
		out.push(line);
	}
	while (out.length > 0 && out[out.length - 1].trim() === "") out.pop();
	return out.join("\n").trim();
}

function extractSteeringBody(raw: string): string {
	const lines = raw.split(/\r?\n/);
	const out: string[] = [];
	let started = false;
	for (const line of lines) {
		if (!started) {
			if (/^Steering update for /.test(line)) continue;
			if (line.trim() === "") continue;
			started = true;
		}
		out.push(line);
	}
	return out.join("\n").trim();
}

export function appendBgChatMessages(messages: ChatMessage[], items: SubagentDashboardItem[], taskRegistry: PaneTaskRegistry = {}): void {
	// Bg/oneshot agents skip the file bus (no inbox/outbox/.md/.json), so the
	// file-based scan never sees them. Synthesize delegation+completion records
	// from the dashboard item itself; the data we need is already on it.
	// Use the persistent task registry's #N so chat row attribution matches
	// the popup task-children and Detail header (not the in-memory counter).
	const persistentTaskNumbers = taskNumberById(Object.values(taskRegistry));
	const labels = dashboardDisplayLabels(items, persistentTaskNumbers);
	for (const item of items) {
		if (item.kind !== "oneshot") continue;
		const label = labels.get(item.taskId) ?? item.agent;
		const startTs = item.startedAt ? Date.parse(item.startedAt) : Number.NaN;
		if (Number.isFinite(startTs) && item.task) {
			messages.push({
				timestamp: startTs,
				agent: item.agent,
				taskId: item.taskId,
				kind: "delegation",
				from: "@orch",
				to: `@${label}`,
				body: item.task,
			});
		}
		const isTerminal = item.status === "completed" || item.status === "failed" || item.status === "blocked" || item.status === "needs_completion";
		if (!isTerminal) continue;
		const endTs = item.completedAt ? Date.parse(item.completedAt) : item.updatedAt ? Date.parse(item.updatedAt) : Number.NaN;
		if (!Number.isFinite(endTs)) continue;
		messages.push({
			timestamp: endTs,
			agent: item.agent,
			taskId: item.taskId,
			kind: "completion",
			from: `@${label}`,
			to: "@orch",
			body: completionBodyFromRecord(taskRegistry[item.taskId], item.message, item.task, item.messageProvenance ?? "task-echo-fallback"),
			status: item.status,
		});
	}
}

function loadChatMessages(runtimeRoot: string, agentNames: string[], taskRegistry: PaneTaskRegistry): ChatMessage[] {
	const messages: ChatMessage[] = [];
	const seen = new Set<string>();
	const pushMd = (filePath: string, agent: string): void => {
		const key = `md:${filePath}`;
		if (seen.has(key)) return;
		seen.add(key);
		let stat: fs.Stats;
		try { stat = fs.statSync(filePath); } catch { return; }
		let raw: string;
		try { raw = fs.readFileSync(filePath, "utf-8"); } catch { return; }
		const isSteer = /^Steering update for /m.test(raw) || /^STEER:/im.test(raw);
		const body = trimChatBody(isSteer ? extractSteeringBody(raw) : extractDelegationBody(raw));
		if (!body) return;
		messages.push({
			timestamp: stat.mtimeMs,
			agent,
			taskId: deriveTaskIdFromFile(filePath),
			kind: isSteer ? "steering" : "delegation",
			from: "@orch",
			to: `@${agent}`,
			body,
		});
	};
	const pushJson = (filePath: string, agent: string): void => {
		const key = `json:${filePath}`;
		if (seen.has(key)) return;
		seen.add(key);
		let stat: fs.Stats;
		try { stat = fs.statSync(filePath); } catch { return; }
		let parsed: Record<string, unknown> | undefined;
		try { parsed = JSON.parse(fs.readFileSync(filePath, "utf-8")) as Record<string, unknown>; } catch { return; }
		const taskId = deriveTaskIdFromFile(filePath);
		const record = taskId ? taskRegistry[taskId] : undefined;
		const summary = completionBodyFromRecord(record, typeof parsed?.summary === "string" ? parsed.summary : undefined, record?.task, "fallback");
		const status = typeof parsed?.status === "string" ? parsed.status : undefined;
		const notes = typeof parsed?.notes === "string" ? parsed.notes : undefined;
		const filesChanged = Array.isArray(parsed?.filesChanged)
			? (parsed.filesChanged as unknown[]).filter((entry): entry is string => typeof entry === "string")
			: undefined;
		messages.push({
			timestamp: stat.mtimeMs,
			agent,
			taskId,
			kind: "completion",
			from: `@${agent}`,
			to: "@orch",
			body: summary,
			status,
			filesChanged,
			notes,
		});
	};
	const mdDirs = ["inbox", "processing", "done"];
	const jsonDirs = ["outbox", "processed"];
	for (const agent of agentNames) {
		for (const rel of mdDirs) {
			const dir = path.join(runtimeRoot, rel, safeFileName(agent));
			let entries: string[];
			try { entries = fs.readdirSync(dir); } catch { continue; }
			for (const name of entries) if (name.endsWith(".md")) pushMd(path.join(dir, name), agent);
		}
		for (const rel of jsonDirs) {
			const dir = path.join(runtimeRoot, rel, safeFileName(agent));
			let entries: string[];
			try { entries = fs.readdirSync(dir); } catch { continue; }
			for (const name of entries) if (name.endsWith(".json")) pushJson(path.join(dir, name), agent);
		}
	}
	messages.sort((a, b) => a.timestamp - b.timestamp);
	return messages;
}

function chatTimestamp(ms: number): string {
	const d = new Date(ms);
	const hh = String(d.getHours()).padStart(2, "0");
	const mm = String(d.getMinutes()).padStart(2, "0");
	const ss = String(d.getSeconds()).padStart(2, "0");
	return `${hh}:${mm}:${ss}`;
}

function chatRoleColor(name: string, theme: Theme): string {
	if (name === "@orch") return theme.fg("accent", theme.bold(name));
	return ansiMagenta(theme.bold(name));
}

function chatKindBadge(kind: ChatMessage["kind"], theme: Theme): string {
	if (kind === "completion") return theme.fg("success", "completion");
	if (kind === "steering") return theme.fg("warning", "steer");
	return theme.fg("muted", "delegation");
}

function chatStatusIcon(status: string | undefined, theme: Theme): string | undefined {
	if (!status) return undefined;
	if (status === "completed") return theme.fg("success", ICONS.check);
	if (status === "failed") return theme.fg("error", ICONS.times);
	if (status === "blocked") return theme.fg("error", ICONS.times);
	return theme.fg("warning", ICONS.warning);
}

function wrapWithHangingIndent(text: string, indent: string, width: number): string[] {
	const innerWidth = Math.max(1, width - visibleWidth(indent));
	const out: string[] = [];
	for (const line of text.split(/\r?\n/)) {
		const wrapped = wrapTextWithAnsi(line, innerWidth);
		if (wrapped.length === 0) {
			out.push(indent);
			continue;
		}
		for (const sub of wrapped) out.push(`${indent}${sub}`);
	}
	return out;
}

function renderChatRoomDetail(runtimeRoot: string, items: SubagentDashboardItem[], ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	const safeWidth = Math.max(8, width);
	const agentNames = [...new Set(items.map((item) => item.agent))];
	const taskIds = new Set(items.map((item) => item.taskId).filter(Boolean));
	const scopeLabel = items.length === 1 ? `@${items[0]!.agent}` : `${agentNames.length} agent${agentNames.length === 1 ? "" : "s"}`;
	const titleLine = `${agentPaneTitle(theme, "Chat", ui.pane === "inspector")} ${theme.fg("dim", `(${scopeLabel})`)}`;
	const taskRegistry = loadTaskRegistrySync(runtimeRoot);
	const messages = loadChatMessages(runtimeRoot, agentNames, taskRegistry).filter((message) => taskIds.size === 0 || !message.taskId || taskIds.has(message.taskId));
	appendBgChatMessages(messages, items, taskRegistry);
	messages.sort((a, b) => a.timestamp - b.timestamp);
	const body: string[] = [];
	if (messages.length === 0) {
		body.push(...wrapTextWithAnsi(theme.fg("dim", "No messages yet. Delegations and completions will appear here as agents work."), safeWidth));
	} else {
		for (let i = 0; i < messages.length; i += 1) {
			const msg = messages[i];
			const time = theme.fg("dim", chatTimestamp(msg.timestamp));
			const arrow = theme.fg("dim", "\u2192");
			const fromLabel = chatRoleColor(msg.from, theme);
			const toLabel = chatRoleColor(msg.to, theme);
			const sep = theme.fg("dim", "\u00b7");
			const kindBadge = chatKindBadge(msg.kind, theme);
			const statusIcon = chatStatusIcon(msg.status, theme);
			const taskBadge = msg.taskId ? theme.fg("muted", `#${shortTaskSuffix(msg.taskId)}`) : undefined;
			const headerParts = [time, fromLabel, arrow, toLabel, sep, kindBadge];
			if (statusIcon) headerParts.push(sep, statusIcon);
			if (taskBadge) headerParts.push(sep, taskBadge);
			body.push(...wrapTextWithAnsi(headerParts.join(" "), safeWidth));
			const indent = theme.fg("dim", "\u2502 ");
			const bodyText = msg.body || theme.fg("dim", "(empty)");
			body.push(...wrapWithHangingIndent(theme.fg("toolOutput", bodyText), indent, safeWidth));
			if (msg.filesChanged && msg.filesChanged.length > 0) {
				body.push(...wrapWithHangingIndent(theme.fg("muted", `files: ${msg.filesChanged.join(", ")}`), indent, safeWidth));
			}
			if (msg.notes) {
				body.push(...wrapWithHangingIndent(theme.fg("muted", `notes: ${msg.notes}`), indent, safeWidth));
			}
			if (i < messages.length - 1) body.push("");
		}
	}
	const allLines: string[] = [titleLine, ""];
	const visibleBodyRows = Math.max(1, rows - 2);
	const maxOffset = Math.max(0, body.length - visibleBodyRows);
	const offset = Math.max(0, Math.min(ui.inspectorScroll, maxOffset));
	ui.inspectorScroll = offset;
	allLines.push(...body.slice(offset, offset + visibleBodyRows));
	if (offset > 0 || maxOffset > 0) {
		const hint = `${offset > 0 ? `\u2191 ${offset} earlier` : ""}${offset > 0 && offset < maxOffset ? "  " : ""}${offset < maxOffset ? `\u2193 ${maxOffset - offset} more` : ""}`.trim();
		if (hint && allLines.length < rows) {
			const lastIndex = allLines.length - 1;
			allLines[lastIndex] = `${allLines[lastIndex]} ${theme.fg("dim", hint)}`;
		}
	}
	return allLines.slice(0, rows);
}

function renderActiveTabBody(items: SubagentDashboardItem[], runtimeRoot: string, ui: AgentBrowserUiState, width: number, theme: Theme, layout: AgentBrowserLayout): string[] {
	const maxLeftWidth = Math.max(10, width - 13);
	const desiredLeftWidth = Math.min(AGENTS_LEFT_MAX_WIDTH, Math.floor(width * 0.32), maxLeftWidth);
	const leftWidth = Math.max(10, Math.min(maxLeftWidth, Math.max(Math.min(AGENTS_LEFT_MIN_WIDTH, maxLeftWidth), desiredLeftWidth)));
	const rightWidth = Math.max(1, width - leftWidth - 3);
	const bodyRows = layout.bodyRows;
	// Numbering for active-list, Detail header, and Chat must match the
	// popup task-children + Inspector header (`<agent> #N`) by reading
	// the persisted task registry, not the in-memory counter. Small
	// JSON; the per-render read is cheap and removes the worst
	// inconsistency (same task showing as #2 here and #6 there).
	const persistentTaskNumbers = taskNumberById(Object.values(loadTaskRegistrySync(runtimeRoot)));
	const left = renderActiveAgentList(items, ui, leftWidth, theme, layout.listRows, persistentTaskNumbers);
	const detailItem = items[ui.activeSelected];
	const labels = dashboardDisplayLabels(items, persistentTaskNumbers);
	const right = renderActiveAgentDetail(detailItem, detailItem ? labels.get(detailItem.taskId) : undefined, ui, rightWidth, bodyRows, theme);
	const lines: string[] = [];
	const headerLine = `${theme.fg("muted", "View")}: ${theme.fg("text", "active")}  ${theme.fg("muted", "Items")}: ${items.length}`;
	lines.push(...wrapTextWithAnsi(headerLine, width));
	lines.push(agentDivider(width, theme));
	for (let i = 0; i < bodyRows; i += 1) {
		lines.push(`${agentPad(left[i] ?? "", leftWidth)} ${theme.fg("dim", "\u2502")} ${truncateToWidth(right[i] ?? "", rightWidth, "")}`);
	}
	const legend = `${theme.fg("muted", "Active")}: ${theme.fg("warning", "running/waiting")} \u00b7 ${theme.fg("success", "completed")} \u00b7 ${theme.fg("error", "failed")}`;
	lines.push("");
	lines.push(...wrapTextWithAnsi(legend, width));
	return lines;
}

function renderHistoryTabBody(
	records: PaneTaskRecord[],
	cache: Map<string, HistoryDetailEntry>,
	ui: AgentBrowserUiState,
	width: number,
	theme: Theme,
	layout: AgentBrowserLayout,
): string[] {
	const maxLeftWidth = Math.max(10, width - 13);
	const desiredLeftWidth = Math.min(AGENTS_LEFT_MAX_WIDTH, Math.floor(width * 0.36), maxLeftWidth);
	const leftWidth = Math.max(10, Math.min(maxLeftWidth, Math.max(Math.min(AGENTS_LEFT_MIN_WIDTH, maxLeftWidth), desiredLeftWidth)));
	const rightWidth = Math.max(1, width - leftWidth - 3);
	const bodyRows = layout.bodyRows;
	const left = renderHistoryList(records, ui, leftWidth, theme, layout.listRows);
	const record = records[ui.historySelected];
	const right = renderHistoryDetail(record, cache, ui, rightWidth, bodyRows, theme);
	const lines: string[] = [agentDivider(width, theme)];
	for (let i = 0; i < bodyRows; i += 1) {
		lines.push(`${agentPad(left[i] ?? "", leftWidth)} ${theme.fg("dim", "│")} ${truncateToWidth(right[i] ?? "", rightWidth, "")}`);
	}
	const legend = `${theme.fg("muted", "Status")}: ${theme.fg("success", "completed")} · ${theme.fg("warning", "running/queued/blocked")} · ${theme.fg("error", "failed")}`;
	lines.push("");
	lines.push(...wrapTextWithAnsi(legend, width));
	return lines;
}

function renderUnifiedAgentDetail(
	row: AgentBrowserRow | undefined,
	statuses: Map<string, AgentPaneStatus>,
	activeItems: SubagentDashboardItem[],
	runtimeRoot: string,
	ui: AgentBrowserUiState,
	width: number,
	rows: number,
	theme: Theme,
): string[] {
	const agent = row?.agent;
	const activeItem = row?.item;
	const displayLabel = row?.rowType === "task" && agent ? `${agent.name} ${row.label}` : row?.label;
	if (!activeItem) {
		ui.agentSubtab = 0;
		return renderAgentInspector(agent, statuses, ui, width, rows, theme);
	}
	const tabs: TraceViewerItem[] = [
		{ label: "Live", text: "", type: "transcript" },
		{ label: "Chat", text: "", type: "summary" },
		{ label: "Inspector", text: "", type: "summary" },
	];
	ui.agentSubtab = Math.max(0, Math.min(ui.agentSubtab, tabs.length - 1));
	const agentChatItems = activeItems.filter((item) => item.agent === activeItem.agent);
	const chatItems = row?.rowType === "agent" ? (agentChatItems.length > 0 ? agentChatItems : [activeItem]) : [activeItem];
	const base = ui.agentSubtab === 0
		? renderActiveAgentDetail(activeItem, displayLabel, ui, width, rows, theme)
		: ui.agentSubtab === 1
			? renderChatRoomDetail(runtimeRoot, chatItems, ui, width, rows, theme)
			: renderAgentInspector(agent, statuses, ui, width, rows, theme);
	const tabLine = renderTraceTabBar(tabs, ui.agentSubtab, Math.max(8, width), theme);
	return [base[0] ?? "", "", tabLine, "", ...base.slice(2)].slice(0, rows);
}

function renderAgentsBody(
	discovery: ReturnType<typeof discoverAgents>,
	rowsForList: AgentBrowserRow[],
	statuses: Map<string, AgentPaneStatus>,
	activeItems: SubagentDashboardItem[],
	runtimeRoot: string,
	ui: AgentBrowserUiState,
	width: number,
	theme: Theme,
	layout: AgentBrowserLayout,
): string[] {
	const selectedRow = rowsForList[ui.selected];
	const maxLeftWidth = Math.max(10, width - 13);
	const desiredLeftWidth = Math.min(AGENTS_LEFT_MAX_WIDTH, Math.floor(width * 0.38), maxLeftWidth);
	const leftWidth = Math.max(10, Math.min(maxLeftWidth, Math.max(Math.min(AGENTS_LEFT_MIN_WIDTH, maxLeftWidth), desiredLeftWidth)));
	const rightWidth = Math.max(1, width - leftWidth - 3);
	const bodyRows = layout.bodyRows;
	const liveCount = [...statuses.values()].filter((status) => status.live).length;
	const paneCount = discovery.agents.filter((agent) => agent.pane).length;
	const left = renderAgentList(rowsForList, statuses, ui, leftWidth, theme, layout.listRows);
	const right = renderUnifiedAgentDetail(selectedRow, statuses, activeItems, runtimeRoot, ui, rightWidth, bodyRows, theme);
	const rows = bodyRows;
	const searchLine = theme.bg("toolPendingBg", agentPad(` > ${ui.search}${theme.inverse(" ")}`, width));
	const workingCount = activeItems.filter((item) => isDashboardWorkingStatus(item.status)).length;
	const filterLine = `${theme.fg("muted", "all scopes")}: ${rowsForList.length} rows · ${discovery.agents.length} agents · ${workingCount} working · ${paneCount} pane · ${liveCount} live`;
	const filterLines = wrapTextWithAnsi(filterLine, width);
	const lines = [searchLine, ...filterLines, agentDivider(width, theme)];
	for (let i = 0; i < rows; i += 1) {
		lines.push(`${agentPad(left[i] ?? "", leftWidth)} ${theme.fg("dim", "│")} ${truncateToWidth(right[i] ?? "", rightWidth, "")}`);
	}
	lines.push("");
	lines.push(...wrapTextWithAnsi(agentLegend(theme), width));
	return lines;
}

function createAgentsBrowserComponent(
	discovery: ReturnType<typeof discoverAgents>,
	statuses: Map<string, AgentPaneStatus>,
	taskRegistry: PaneTaskRegistry,
	ui: AgentBrowserUiState,
	theme: Theme,
	requestRender: () => void,
	getLayout: () => AgentBrowserLayout,
	done: (action: AgentBrowserAction) => void,
	getActiveItems: () => SubagentDashboardItem[],
	runtimeRoot: string,
) {
	let closed = false;
	let resizeTimer: ReturnType<typeof setTimeout> | undefined;
	const animationTimer = setInterval(() => {
		if (!closed && getActiveItems().some((item) => isDashboardWorkingStatus(item.status))) requestRender();
	}, 120);
	animationTimer.unref?.();
	const scheduleResizeRender = () => {
		if (closed) return;
		requestRender();
		if (resizeTimer) clearTimeout(resizeTimer);
		resizeTimer = setTimeout(() => {
			resizeTimer = undefined;
			if (!closed) requestRender();
		}, 80);
		resizeTimer.unref?.();
	};
	const cleanup = () => {
		closed = true;
		if (resizeTimer) clearTimeout(resizeTimer);
		resizeTimer = undefined;
		clearInterval(animationTimer);
		process.off("SIGWINCH", scheduleResizeRender);
	};
	const finish = (action: AgentBrowserAction) => {
		cleanup();
		done(action);
	};
	process.on("SIGWINCH", scheduleResizeRender);
	const filtered = () => buildAgentRows(discovery.agents, ui.search, statuses, getActiveItems(), taskRegistry);
	const selectedRow = () => filtered()[ui.selected];
	const selectedAgent = () => selectedRow()?.agent;
	const clamp = () => {
		const layout = getLayout();
		const list = filtered();
		ui.selected = Math.max(0, Math.min(ui.selected, Math.max(0, list.length - 1)));
		if (ui.selected < ui.scroll) ui.scroll = ui.selected;
		if (ui.selected >= ui.scroll + layout.listRows) ui.scroll = ui.selected - layout.listRows + 1;
		ui.scroll = Math.max(0, Math.min(ui.scroll, Math.max(0, list.length - layout.listRows)));
	};
	const historyRecords = sortedHistoryRecords(taskRegistry);
	const historyCache = new Map<string, HistoryDetailEntry>();
	const historyTaskNumbers = taskNumberById(historyRecords);
	const loadHistoryRecord = (record: PaneTaskRecord | undefined) => {
		if (!record) return;
		const entry = historyCache.get(record.taskId);
		if (entry?.items || entry?.loading) return;
		historyCache.set(record.taskId, { loading: true });
		void traceViewerItems(record, historyTaskNumbers.get(record.taskId), discovery).then((items) => {
			historyCache.set(record.taskId, { items });
			requestRender();
		}).catch((error) => {
			historyCache.set(record.taskId, { error: error instanceof Error ? error.message : String(error) });
			requestRender();
		});
	};
	const clampHistory = () => {
		const layout = getLayout();
		const total = historyRecords.length;
		ui.historySelected = Math.max(0, Math.min(ui.historySelected, Math.max(0, total - 1)));
		if (ui.historySelected < ui.historyScroll) ui.historyScroll = ui.historySelected;
		if (ui.historySelected >= ui.historyScroll + layout.listRows) ui.historyScroll = ui.historySelected - layout.listRows + 1;
		ui.historyScroll = Math.max(0, Math.min(ui.historyScroll, Math.max(0, total - layout.listRows)));
	};

	const hasActiveTab = () => getActiveItems().length > 0;
	const switchTab = (delta: number) => {
		const next = tabNext(ui.tab, hasActiveTab(), delta);
		if (next === "history") {
			ui.tab = "history";
			ui.historySelected = 0;
			ui.historyScroll = 0;
			ui.historySubtab = 0;
			ui.inspectorScroll = 0;
			ui.pane = "list";
			loadHistoryRecord(historyRecords[0]);
			requestRender();
			return;
		}
		ui.tab = "agents";
		ui.selected = 0;
		ui.scroll = 0;
		ui.agentSubtab = 0;
		ui.inspectorScroll = 0;
		ui.pane = "list";
		requestRender();
	};
	const insertSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "insert", agentName: agent.name });
	};
	const startSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "start", agentName: agent.name });
	};
	const attachSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "attach", agentName: agent.name });
	};
	const stopSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "stop", agentName: agent.name });
	};
	const editFrontmatterSelected = () => {
		const agent = selectedAgent();
		if (agent) finish({ type: "editFrontmatter", agentName: agent.name });
	};
	function handleInput(data: string): void {
		if (isAgentBrowserCancelInput(data)) {
			if (ui.tab !== "active" && ui.search) { ui.search = ""; ui.selected = 0; ui.scroll = 0; requestRender(); return; }
			finish({ type: "close" });
			return;
		}
		if (matchesKey(data, "tab")) return switchTab(1);
		if (matchesKey(data, "shift+tab")) return switchTab(-1);
		if (matchesKey(data, "left")) {
			if (ui.tab === "agents" && ui.pane === "inspector") {
				if (ui.agentSubtab > 0) {
					ui.agentSubtab -= 1;
					ui.inspectorScroll = 0;
				} else {
					ui.pane = "list";
				}
				requestRender();
				return;
			}
			if (ui.tab === "history" && ui.pane === "inspector") {
				if (ui.historySubtab === 0) {
					ui.pane = "list";
				} else {
					ui.historySubtab -= 1;
					ui.inspectorScroll = 0;
				}
				requestRender();
				return;
			}
			ui.pane = "list";
			requestRender();
			return;
		}
		if (matchesKey(data, "right")) {
			if (ui.tab === "agents") {
				if (ui.pane !== "inspector") {
					ui.pane = "inspector";
					requestRender();
					return;
				}
				if (selectedRow()?.item && ui.agentSubtab < 2) {
					ui.agentSubtab += 1;
					ui.inspectorScroll = 0;
					requestRender();
				}
				return;
			}
			if (ui.tab === "history" && ui.pane === "inspector") {
				const total = HISTORY_SUBTAB_LABELS.length;
				if (ui.historySubtab < total - 1) {
					ui.historySubtab += 1;
					ui.inspectorScroll = 0;
					requestRender();
				}
				return;
			}
			ui.pane = "inspector";
			requestRender();
			return;
		}
		if (matchesKey(data, "-") || matchesKey(data, "=")) {
			const layout = getLayout();
			const page = Math.max(1, layout.bodyRows);
			const delta = matchesKey(data, "-") ? -page : page;
			if (ui.tab === "active") {
				const items = getActiveItems();
				const totalRows = items.length;
				if (ui.pane === "inspector") {
					ui.inspectorScroll = Math.max(0, ui.inspectorScroll + delta);
				} else {
					ui.activeSelected = Math.max(0, Math.min(totalRows - 1, ui.activeSelected + delta));
					if (ui.activeSelected < ui.activeScroll) ui.activeScroll = ui.activeSelected;
					if (ui.activeSelected >= ui.activeScroll + layout.listRows) ui.activeScroll = ui.activeSelected - layout.listRows + 1;
					ui.activeScroll = Math.max(0, Math.min(ui.activeScroll, Math.max(0, totalRows - layout.listRows)));
					ui.inspectorScroll = 0;
				}
			} else if (ui.tab === "history") {
				if (ui.pane === "inspector") {
					ui.inspectorScroll = Math.max(0, ui.inspectorScroll + delta);
				} else {
					ui.historySelected = Math.max(0, ui.historySelected + delta);
					ui.historySubtab = 0;
					ui.inspectorScroll = 0;
					clampHistory();
					loadHistoryRecord(historyRecords[ui.historySelected]);
				}
			} else if (ui.pane === "inspector") {
				ui.inspectorScroll = Math.max(0, ui.inspectorScroll + delta);
			} else {
				ui.selected = Math.max(0, ui.selected + delta);
				ui.inspectorScroll = 0;
				clamp();
			}
			requestRender();
			return;
		}
		if (ui.tab === "active") {
			const items = getActiveItems();
			const layout = getLayout();
			const totalRows = items.length;
			const clampActive = () => {
				ui.activeSelected = Math.max(0, Math.min(ui.activeSelected, Math.max(0, totalRows - 1)));
				if (ui.activeSelected < ui.activeScroll) ui.activeScroll = ui.activeSelected;
				if (ui.activeSelected >= ui.activeScroll + layout.listRows) ui.activeScroll = ui.activeSelected - layout.listRows + 1;
				ui.activeScroll = Math.max(0, Math.min(ui.activeScroll, Math.max(0, totalRows - layout.listRows)));
			};
			if (matchesKey(data, "up")) {
				if (ui.pane === "inspector") ui.inspectorScroll = Math.max(0, ui.inspectorScroll - 1);
				else { ui.activeSelected -= 1; ui.inspectorScroll = 0; clampActive(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "down")) {
				if (ui.pane === "inspector") ui.inspectorScroll += 1;
				else { ui.activeSelected += 1; ui.inspectorScroll = 0; clampActive(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "pageup" as any)) {
				if (ui.pane === "inspector") ui.inspectorScroll = Math.max(0, ui.inspectorScroll - Math.max(1, layout.bodyRows));
				else { ui.activeSelected -= layout.listRows; ui.inspectorScroll = 0; clampActive(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "pagedown" as any)) {
				if (ui.pane === "inspector") ui.inspectorScroll += Math.max(1, layout.bodyRows);
				else { ui.activeSelected += layout.listRows; ui.inspectorScroll = 0; clampActive(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "home")) { if (ui.pane === "inspector") ui.inspectorScroll = 0; else { ui.activeSelected = 0; ui.activeScroll = 0; } requestRender(); return; }
			if (matchesKey(data, "end")) { if (ui.pane === "inspector") ui.inspectorScroll = Number.MAX_SAFE_INTEGER; else { ui.activeSelected = Math.max(0, totalRows - 1); clampActive(); } requestRender(); return; }
			return;
		}
		if (ui.tab === "history") {
			const layout = getLayout();
			if (matchesKey(data, "up")) {
				if (ui.pane === "inspector") ui.inspectorScroll = Math.max(0, ui.inspectorScroll - 1);
				else { ui.historySelected = Math.max(0, ui.historySelected - 1); ui.historySubtab = 0; ui.inspectorScroll = 0; clampHistory(); loadHistoryRecord(historyRecords[ui.historySelected]); }
				requestRender();
				return;
			}
			if (matchesKey(data, "down")) {
				if (ui.pane === "inspector") ui.inspectorScroll += 1;
				else { ui.historySelected += 1; ui.historySubtab = 0; ui.inspectorScroll = 0; clampHistory(); loadHistoryRecord(historyRecords[ui.historySelected]); }
				requestRender();
				return;
			}
			if (matchesKey(data, "pageup" as any)) {
				if (ui.pane === "inspector") ui.inspectorScroll = Math.max(0, ui.inspectorScroll - Math.max(1, layout.bodyRows));
				else { ui.historySelected = Math.max(0, ui.historySelected - layout.listRows); ui.historySubtab = 0; ui.inspectorScroll = 0; clampHistory(); loadHistoryRecord(historyRecords[ui.historySelected]); }
				requestRender();
				return;
			}
			if (matchesKey(data, "pagedown" as any)) {
				if (ui.pane === "inspector") ui.inspectorScroll += Math.max(1, layout.bodyRows);
				else { ui.historySelected += layout.listRows; ui.historySubtab = 0; ui.inspectorScroll = 0; clampHistory(); loadHistoryRecord(historyRecords[ui.historySelected]); }
				requestRender();
				return;
			}
			if (matchesKey(data, "home")) { if (ui.pane === "inspector") ui.inspectorScroll = 0; else { ui.historySelected = 0; ui.historyScroll = 0; ui.historySubtab = 0; loadHistoryRecord(historyRecords[0]); } requestRender(); return; }
			if (matchesKey(data, "end")) { if (ui.pane === "inspector") ui.inspectorScroll = Number.MAX_SAFE_INTEGER; else { ui.historySelected = Math.max(0, historyRecords.length - 1); ui.historySubtab = 0; clampHistory(); loadHistoryRecord(historyRecords[ui.historySelected]); } requestRender(); return; }
			if (matchesKey(data, "enter") || matchesKey(data, "return")) {
				if (ui.pane === "list") { ui.pane = "inspector"; loadHistoryRecord(historyRecords[ui.historySelected]); requestRender(); return; }
				return;
			}
			return;
		}
		if (matchesKey(data, "up")) {
			if (ui.pane === "inspector") ui.inspectorScroll -= 1;
			else { ui.selected -= 1; ui.inspectorScroll = 0; clamp(); }
			requestRender();
			return;
		}
		if (matchesKey(data, "down")) {
			if (ui.pane === "inspector") ui.inspectorScroll += 1;
			else { ui.selected += 1; ui.inspectorScroll = 0; clamp(); }
			requestRender();
			return;
		}
		if (matchesKey(data, "pageup" as any)) {
			const layout = getLayout();
			if (ui.pane === "inspector") ui.inspectorScroll -= Math.max(1, layout.bodyRows);
			else { ui.selected -= layout.listRows; ui.inspectorScroll = 0; clamp(); }
			requestRender();
			return;
		}
		if (matchesKey(data, "pagedown" as any)) {
			const layout = getLayout();
			if (ui.pane === "inspector") ui.inspectorScroll += Math.max(1, layout.bodyRows);
			else { ui.selected += layout.listRows; ui.inspectorScroll = 0; clamp(); }
			requestRender();
			return;
		}
		if (matchesKey(data, "home")) { if (ui.pane === "inspector") ui.inspectorScroll = 0; else { ui.selected = 0; ui.scroll = 0; } requestRender(); return; }
		if (matchesKey(data, "end")) { if (ui.pane === "inspector") ui.inspectorScroll = Number.MAX_SAFE_INTEGER; else { ui.selected = Math.max(0, filtered().length - 1); clamp(); } requestRender(); return; }
		if (matchesKey(data, "enter") || matchesKey(data, "return")) return insertSelected();
		if (matchesKey(data, "alt+m") || matchesKey(data, "ctrl+m")) return editFrontmatterSelected();
		if (matchesKey(data, "alt+p") || matchesKey(data, "ctrl+p")) return startSelected();
		if (matchesKey(data, "alt+o") || matchesKey(data, "ctrl+o")) return attachSelected();
		if (matchesKey(data, "alt+x") || matchesKey(data, "ctrl+x")) return stopSelected();
		if (matchesKey(data, "backspace")) { ui.search = ui.search.slice(0, -1); ui.selected = 0; ui.scroll = 0; ui.inspectorScroll = 0; clamp(); requestRender(); return; }
		if (matchesKey(data, "ctrl+u")) { ui.search = ""; ui.selected = 0; ui.scroll = 0; ui.inspectorScroll = 0; requestRender(); return; }
		if (isAgentBrowserTextInput(data)) { ui.search += data; ui.pane = "list"; ui.selected = 0; ui.scroll = 0; ui.inspectorScroll = 0; clamp(); requestRender(); }
	}

	function render(width: number): string[] {
		const layout = getLayout();
		const safeWidth = Math.max(1, width);
		const bodyWidth = agentFrameContentWidth(safeWidth);
		const activeItems = getActiveItems();
		const tabLine = renderAgentBrowserTabs(ui.tab, activeItems.length > 0, bodyWidth, theme);
		if (ui.tab === "history") {
			clampHistory();
			loadHistoryRecord(historyRecords[ui.historySelected]);
			const arrowsLabel = ui.pane === "inspector" ? "sections · " : "pane · ";
			const footer = `${ansiYellow("tab")} ${theme.fg("dim", "view · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("←/→")} ${theme.fg("dim", arrowsLabel.replace(/ +$/, ""))}`;
			const lines = [tabLine, "", ...renderHistoryTabBody(historyRecords, historyCache, ui, bodyWidth, theme, layout), agentDivider(bodyWidth, theme), ...wrapTextWithAnsi(footer, bodyWidth)];
			return agentFrame(lines, safeWidth, theme, layout.innerRows, "Agents");
		}
		clamp();
		const footer = `${ansiYellow("tab")} ${theme.fg("dim", "view · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("←/→")} ${theme.fg("dim", "pane · ")}${ansiYellow("alt+m")} ${theme.fg("dim", "edit frontmatter · ")}${ansiYellow("alt+p")} ${theme.fg("dim", "start pane · ")}${ansiYellow("alt+o")} ${theme.fg("dim", "attach · ")}${ansiYellow("alt+x")} ${theme.fg("dim", "stop")}`;
		const lines = [
			tabLine,
			"",
			...renderAgentsBody(discovery, filtered(), statuses, activeItems, runtimeRoot, ui, bodyWidth, theme, layout),
			agentDivider(bodyWidth, theme),
			...wrapTextWithAnsi(footer, bodyWidth),
		];
		return agentFrame(lines, safeWidth, theme, layout.innerRows, "Agents");
	}

	return { handleInput, invalidate() {}, render };
}

export async function openAgentsBrowser(
	ctx: ExtensionContext,
	initialScope: AgentScope,
	initialAgentName: string | undefined,
	runtimeRoot: string,
	parentSessionId: string,
	parentModel: string | undefined,
	parentThinkingLevel: string | undefined,
	activeTools: string[] | undefined,
	getActiveItems: () => SubagentDashboardItem[],
	onAgentStopped?: (agentName: string) => void,
): Promise<void> {
	const releaseModalLock = acquireVstackModalLock();
	try {
	const ui: AgentBrowserUiState = {
		inspectorScroll: 0,
		pane: initialAgentName ? "inspector" : "list",
		tab: "agents",
		scope: initialScope,
		search: "",
		selected: 0,
		scroll: 0,
		agentSubtab: 0,
		activeSelected: 0,
		activeScroll: 0,
		historySelected: 0,
		historyScroll: 0,
		historySubtab: 0,
	};
	while (true) {
		const discovery = discoverAgents(ctx.cwd, "both");
		const statuses = await loadAgentPaneStatuses(runtimeRoot);
		if (initialAgentName) {
			const selected = sortAgentsForUnifiedView(discovery.agents, statuses, getActiveItems()).findIndex((agent) => agent.name === initialAgentName);
			if (selected >= 0) ui.selected = selected;
			else {
				ctx.ui.notify(`Unknown agent "${initialAgentName}"`, "warning");
				ui.pane = "list";
			}
		}
		const taskRegistry = await readTaskRegistry(runtimeRoot).catch(() => ({} as PaneTaskRegistry));
		const action = await ctx.ui.custom<AgentBrowserAction>(
			(tui: TUI, theme: Theme, _keybindings, done) => createAgentsBrowserComponent(
				discovery,
				statuses,
				taskRegistry,
				ui,
				theme,
				() => tui.requestRender(),
				() => agentBrowserLayout(tui.terminal.rows),
				done,
				getActiveItems,
				runtimeRoot,
			),
			{ overlay: true, overlayOptions: { anchor: "center", maxHeight: AGENTS_BROWSER_MAX_HEIGHT, width: AGENTS_BROWSER_WIDTH } },
		);
		initialAgentName = undefined;
		if (!action || action.type === "close") return;
		if (action.type === "reload") continue;
		const agent = discovery.agents.find((candidate) => candidate.name === action.agentName);
		if (!agent) {
			ctx.ui.notify(`Unknown agent: ${action.agentName}`, "error");
			continue;
		}
		try {
			if (action.type === "editFrontmatter") {
				const message = await editAgentFrontmatterOverrides(ctx, agent);
				if (message) await showAgentEditConfirmation(ctx, message);
				continue;
			}
			if (action.type === "insert") {
				ctx.ui.pasteToEditor(`Use agent ${agent.name} to: `);
				return;
			}
			if (action.type === "start") {
				if (!agent.pane) throw new Error(`${agent.name} is not configured with pane: true.`);
				await ensurePersistentPane(runtimeRoot, parentSessionId, ctx.cwd, agent, parentModel, parentThinkingLevel, activeTools);
				ctx.ui.notify(`Started/reused ${agent.name}`, "info");
				continue;
			}
			if (action.type === "attach") {
				const registry = await readPaneRegistry(runtimeRoot);
				const entry = registry[agent.name];
				if (!entry || !(await paneExists(entry.paneId))) throw new Error(`No live pane for ${agent.name}.`);
				const result = await tmux(["select-pane", "-t", entry.paneId]);
				if (result.code !== 0) throw new Error(result.stderr || result.stdout || "tmux select-pane failed");
				ctx.ui.notify(`Attached to ${agent.name}`, "info");
				return;
			}
			if (action.type === "stop") {
				await stopPersistentPane(runtimeRoot, agent.name);
				onAgentStopped?.(agent.name);
				ctx.ui.notify(`Stopped ${agent.name}`, "info");
				continue;
			}
		} catch (error) {
			ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
		}
	}
	} finally {
		releaseModalLock();
	}
}

function traceViewerLines(state: TraceViewerState, width: number, rows: number, theme: Theme): string[] {
	const innerWidth = Math.max(1, width - 4);
	const frameRows = Math.max(8, rows);
	const item = state.items[state.selected] ?? state.items[0];
	const help = `${ansiYellow("tab/←→")} ${theme.fg("dim", "sections · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page")}`;
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

function renderTraceTabBar(items: TraceViewerItem[], selected: number, width: number, theme: Theme): string {
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

export async function editAgentFrontmatterOverrides(ctx: ExtensionContext, agent: AgentConfig): Promise<string | undefined> {
	const edited = await ctx.ui.editor(`Edit ${agent.name} frontmatter — model/deny-tools/color`, editableAgentFrontmatterText(agent));
	if (edited === undefined) return undefined;
	const parsed = parseEditableAgentFrontmatterText(edited);
	if (isVstackManagedAgentFile(agent)) {
		const tomlPath = vstackTomlPathForAgent(agent, ctx.cwd);
		if (!tomlPath) throw new Error(`Could not locate vstack.toml for vstack-managed agent ${agent.name}.`);
		await withFileMutationQueue(tomlPath, async () => {
			let current = "";
			try { current = await fs.promises.readFile(tomlPath, "utf-8"); } catch {}
			const next = upsertAgentFrontmatterToml(current, agent.name, parsed);
			await fs.promises.mkdir(path.dirname(tomlPath), { recursive: true });
			await fs.promises.writeFile(tomlPath, next, "utf-8");
		});
		const refresh = refreshVstackManagedAgent(agent, tomlPath);
		if (!refresh.ok) return `Updated ${agent.name} overrides in ${compactAgentPath(tomlPath)}. Refresh failed: ${refresh.message || "unknown error"}. Run vstack refresh --scope project to regenerate ${compactAgentPath(agent.filePath)}.`;
		return `Updated Pi overrides in ${compactAgentPath(tomlPath)} and regenerated project agents. Run /reload if Pi does not pick up the changed agent immediately.`;
	}
	await withFileMutationQueue(agent.filePath, async () => {
		const current = await fs.promises.readFile(agent.filePath, "utf-8");
		await fs.promises.writeFile(agent.filePath, updateAgentFileFrontmatter(current, parsed), "utf-8");
	});
	return `Updated ${agent.name} frontmatter in ${compactAgentPath(agent.filePath)}.`;
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

function highlightAgentEditConfirmationPaths(message: string): string {
	return message.replace(/(~\/[^\s,]+|\/[^\s,]*\/[^\s,]+)/g, (match) => {
		const trailing = match.match(/[.;:!?]+$/)?.[0] ?? "";
		const filePath = trailing ? match.slice(0, -trailing.length) : match;
		return `${ansiGreen(filePath)}${trailing}`;
	});
}

export async function showAgentEditConfirmation(ctx: ExtensionContext, message: string): Promise<void> {
	if (!ctx.hasUI) {
		ctx.ui.notify(message, "info");
		return;
	}
	const styledMessage = highlightAgentEditConfirmationPaths(message);
	await ctx.ui.custom<void>((tui: TUI, theme: Theme, _kb, done) => ({
		invalidate() {},
		handleInput(data: string) {
			if (matchesKey(data, "return") || matchesKey(data, "enter") || matchesKey(data, "escape") || matchesKey(data, "backspace") || matchesKey(data, "ctrl+c")) done();
		},
		render(width: number): string[] {
			const frameWidth = Math.max(8, Math.min(width, AGENT_EDIT_CONFIRM_WIDTH));
			const innerWidth = Math.max(1, frameWidth - 4);
			const lines = [
				theme.fg("success", "Agent metadata updated"),
				"",
				...wrapTextWithAnsi(styledMessage, innerWidth),
				"",
				`${ansiYellow("enter")} ${theme.fg("dim", "return to agents")}`,
			];
			return simpleFrame(lines, frameWidth, theme, "Agents").slice(0, Math.max(8, Math.floor(tui.terminal.rows * 0.45)));
		},
	}), { overlay: true, overlayOptions: { anchor: "center", width: AGENT_EDIT_CONFIRM_WIDTH, maxHeight: "40%" } });
}

export async function traceViewerItems(record: PaneTaskRecord, taskNumber?: number, discovery?: { agents: AgentConfig[] }): Promise<TraceViewerItem[]> {
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
