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
	dashboardStatusIcon,
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
	inactivePill,
	sessionModeChipLabel,
	sessionModeDetailLabel,
	shortTaskSuffix,
	simpleFrame,
	textFromMessageContent,
	truncateSessionKeyForChip,
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
	MONITOR_BROWSER_TAB,
	MONITOR_SUBTAB_LABELS,
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
	type MonitorDetailEntry,
	type MonitorFilter,
	type PaneTaskRecord,
	type PaneTaskRegistry,
	type PaneTaskStatus,
	type SubagentDashboardItem,
	type TraceViewerItem,
	type TraceViewerState,
	type UsageStats,
	type VstackModalLock,
} from "./types.js";

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

function tabNext(current: AgentBrowserTabId, _hasActive: boolean, delta: number): AgentBrowserTabId {
	const tabs: AgentBrowserTabId[] = ["agents", "monitor"];
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

export function renderAgentBrowserTabs(active: AgentBrowserTabId, hasActive: boolean, width: number, theme: Theme): string {
	void hasActive;
	const tabs = [AGENTS_BROWSER_TAB, MONITOR_BROWSER_TAB];
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

interface AgentBrowserRow {
	agent: AgentConfig;
	label: string;
}

export function buildAgentRows(agents: AgentConfig[], query: string, statuses: Map<string, AgentPaneStatus>): AgentBrowserRow[] {
	const tokens = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
	const rows: AgentBrowserRow[] = [];
	const catalogAgents = sortAgentsForUnifiedView(agents, statuses);
	for (const agent of catalogAgents) {
		const agentSearch = agentSearchText(agent, statuses.get(agent.name));
		const includeAgent = tokens.length === 0 || tokens.every((token) => agentSearch.includes(token));
		if (!includeAgent) continue;
		rows.push({ agent, label: agent.name });
	}
	return rows;
}

function unifiedAgentRank(agent: AgentConfig, status: AgentPaneStatus | undefined): number {
	const state = agentStatus(agent, status);
	if (state === "live") return 0;
	if (state === "dead") return 1;
	if (state === "pane") return 2;
	return 3;
}

function sortAgentsForUnifiedView(agents: AgentConfig[], statuses: Map<string, AgentPaneStatus>): AgentConfig[] {
	return [...agents].sort((a, b) => {
		const rank = unifiedAgentRank(a, statuses.get(a.name)) - unifiedAgentRank(b, statuses.get(b.name));
		if (rank !== 0) return rank;
		return a.name.localeCompare(b.name);
	});
}

function agentLegend(theme: Theme): string {
	return `${theme.fg("muted", "Legend")}: ${theme.fg("success", ICONS.circleFilled)} live pane · ${theme.fg("dim", ICONS.circleOpen)} idle/static · ${theme.fg("muted", "P/U")} project/user`;
}

function agentKindChip(agent: AgentConfig, theme: Theme): string {
	return theme.fg("muted", agent.pane ? "pane" : "bg");
}

function agentScopeChip(agent: AgentConfig, theme: Theme): string {
	return theme.fg("muted", agent.source === "project" ? "P" : "U");
}

function agentLiveBadge(agent: AgentConfig, status: AgentPaneStatus | undefined, theme: Theme): string {
	if (agent.pane && status?.live) return `${theme.fg("success", ICONS.circleFilled)} ${theme.fg("success", "live")}`;
	return theme.fg("dim", ICONS.circleOpen);
}

function displayAgentModel(agent: AgentConfig): string {
	return agent.model ?? "default";
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
		const status = statuses.get(agent.name);
		const marker = " ";
		const name = ansiMagenta(selected ? theme.bold(rowInfo.label) : rowInfo.label);
		const model = `${theme.fg("dim", " · ")}${theme.fg("muted", displayAgentModel(agent))}`;
		const meta = `${theme.fg("dim", " · ")}${agentKindChip(agent, theme)}${model}${theme.fg("dim", " · ")}${agentScopeChip(agent, theme)}`;
		const row = truncateToWidth(`${marker}${agentLiveBadge(agent, status, theme)} ${name}${meta}`, width, "…");
		lines.push(selected ? theme.bg("selectedBg", agentPad(row, width)) : row);
	}
	const hidden = Math.max(0, rows.length - (ui.scroll + listRows));
	if (hidden > 0) lines.push(theme.fg("dim", `↓ ${hidden} more`));
	return lines;
}

function renderAgentPromptViewport(agent: AgentConfig, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	const prompt = agent.systemPrompt.trim() || theme.fg("dim", "(empty prompt)");
	const renderedPrompt = new Markdown(prompt, 0, 0, getMarkdownTheme()).render(width);
	const promptLines = renderedPrompt.length > 0 ? renderedPrompt : wrapTextWithAnsi(prompt, width);
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

function clockTime(raw: string | undefined): string | undefined {
	if (!raw) return undefined;
	const date = new Date(raw);
	if (!Number.isFinite(date.getTime())) return undefined;
	return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function paneStaticStatus(agent: AgentConfig, status: AgentPaneStatus | undefined): string | undefined {
	if (!agent.pane) return undefined;
	if (status?.live) {
		const started = clockTime(status.entry?.startedAt);
		return `running${started ? ` (started ${started})` : ""}`;
	}
	if (status?.entry) return "stopped";
	return "not started";
}

export function renderAgentInspector(agent: AgentConfig | undefined, statuses: Map<string, AgentPaneStatus>, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
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
		`${agentPaneTitle(theme, "Inspector", ui.pane === "inspector")} ${agentEntityTitle(theme, agent.name)} ${theme.fg("dim", `[${agent.pane ? "pane" : "bg"}]`)} ${theme.fg("dim", `[${agent.source === "project" ? "P" : "U"}]`)}`,
	);
	lines.push("");
	lines.push(...wrapTextWithAnsi(agent.description || "No description.", safeWidth).slice(0, 3));
	lines.push("");
	pushWrapped(
		lines,
		`${theme.fg("muted", "Kind")}: ${agent.pane ? "persistent pane" : "bg"}    ${theme.fg("muted", "Scope")}: ${agent.source}`,
	);
	pushWrapped(lines, `${theme.fg("muted", "Model")}: ${displayAgentModel(agent)}    ${theme.fg("muted", "Effort")}: ${agent.effort ?? "default"}`);
	pushWrapped(lines, `${theme.fg("muted", "Deny tools")}: ${agent.denyTools && agent.denyTools.length > 0 ? agent.denyTools.join(", ") : "none"}`);
	pushWrapped(lines, `${theme.fg("muted", "Color")}: ${agent.color ?? "default"}`);
	pushWrapped(lines, `${theme.fg("muted", "Source path")}: ${compactPath(agent.filePath, { baseDir: process.cwd(), maxChars: Number.POSITIVE_INFINITY }) || compactAgentPath(agent.filePath)}`);
	const paneLine = paneStaticStatus(agent, status);
	if (paneLine) pushWrapped(lines, `${theme.fg("muted", "Pane")}: ${paneLine}`);
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

function transcriptRowTime(raw: string | undefined): string {
	if (!raw) return "--:--:--";
	const date = new Date(raw);
	if (!Number.isFinite(date.getTime())) return raw.slice(0, 8).padEnd(8, "-");
	return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}:${String(date.getSeconds()).padStart(2, "0")}`;
}

function transcriptEventTimestamp(outer: any, inner: any): string | undefined {
	return typeof outer?.ts === "string"
		? outer.ts
		: typeof inner?.timestamp === "string"
			? inner.timestamp
			: typeof outer?.timestamp === "string"
				? outer.timestamp
				: undefined;
}

function firstTranscriptLine(value: unknown): string {
	const text = typeof value === "string" ? value : value === undefined ? "" : JSON.stringify(value);
	return text.replace(/\r\n/g, "\n").split("\n")[0]?.replace(/\s+/g, " ").trim() ?? "";
}

function transcriptCompactRow(timestamp: string | undefined, arrow: "→" | "←", type: "prompt" | "assistant" | "tool" | "error" | "exit" | "turn", text: string): string {
	return `${transcriptRowTime(timestamp)} ${arrow} ${type} ${firstTranscriptLine(text)}`.trimEnd();
}

function toolCallPreview(tool: any): string {
	const name = tool?.name ?? tool?.toolName ?? "tool";
	const args = tool?.arguments ?? tool?.args;
	if (!args || (typeof args === "object" && Object.keys(args).length === 0)) return String(name);
	return `${name} ${firstTranscriptLine(args)}`;
}

export function transcriptCompactRows(record: PaneTaskRecord, maxRows = 200): string[] {
	const rows: string[] = [];
	let sawPrompt = false;
	let sawMalformedLine = false;
	try {
		const raw = record.transcriptPath ? fs.readFileSync(record.transcriptPath, "utf-8") : "";
		for (const line of raw.split(/\r?\n/)) {
			if (!line.trim()) continue;
			let event: any;
			try { event = JSON.parse(line); } catch { sawMalformedLine = true; continue; }
			const inner = event?.event && typeof event.event === "object" ? event.event : event;
			const innerType = typeof inner?.type === "string" ? inner.type : undefined;
			const timestamp = transcriptEventTimestamp(event, inner);
			const msg = inner?.message;
			if (msg && typeof msg === "object") {
				const role = String(msg.role ?? "");
				const content = Array.isArray(msg.content) ? msg.content : [];
				const tool = content.find((item: any) => item?.type === "toolCall" || item?.type === "tool_call");
				if (tool) {
					rows.push(transcriptCompactRow(timestamp, "←", "tool", toolCallPreview(tool)));
					continue;
				}
				const text = textFromMessageContent(msg.content);
				if (role === "user") {
					sawPrompt = true;
					rows.push(transcriptCompactRow(timestamp, "→", "prompt", text));
				} else if (role === "assistant") {
					rows.push(transcriptCompactRow(timestamp, "←", "assistant", text || innerType || "assistant"));
				} else if (text.trim()) {
					rows.push(transcriptCompactRow(timestamp, "←", "turn", `${role || innerType || "message"} ${text}`));
				}
				continue;
			}
			if (innerType && typeof inner?.toolName === "string") {
				const phase = innerType === "tool_execution_start" ? "start" : innerType === "tool_execution_end" ? "end" : innerType === "tool_result_end" ? "result" : innerType;
				const result = inner.result ?? inner.output ?? inner.content;
				rows.push(transcriptCompactRow(timestamp, "←", "tool", `${inner.toolName} ${phase}${result ? ` ${firstTranscriptLine(result)}` : ""}`));
				continue;
			}
			if (innerType === "turn_start" || innerType === "turn_end") {
				rows.push(transcriptCompactRow(timestamp, "←", "turn", innerType.replace("_", " ")));
				continue;
			}
			if (innerType === "exit") {
				rows.push(transcriptCompactRow(timestamp, "←", "exit", typeof inner?.code === "number" ? `code ${inner.code}` : "exit"));
				continue;
			}
			if (innerType && (innerType.includes("error") || inner?.error)) rows.push(transcriptCompactRow(timestamp, "←", "error", inner.error ?? innerType));
		}
	} catch {
		rows.push(transcriptCompactRow(undefined, "←", "error", "(transcript unavailable)"));
	}
	if (sawMalformedLine) rows.push(transcriptCompactRow(undefined, "←", "error", "(malformed transcript JSONL)"));
	if (!sawPrompt && record.task?.trim()) rows.unshift(transcriptCompactRow(record.createdAt, "→", "prompt", record.task));
	return rows.slice(-maxRows);
}

// Multiple bg launches of the same agent name produce distinct dashboard rows
// (keyed by taskId). Disambiguate the rendered label with a 1-based occurrence
// suffix in start-time order: "reviewer-arch", "reviewer-arch 2", ... Pane
// agents collapse to a single row per name so they never collide here.
export function dashboardDisplayLabels(items: SubagentDashboardItem[], persistentTaskNumbers?: Map<string, number>): Map<string, string> {
	// Numbering source order:
	//   1. persistent taskNumberById (from tasks.json) when supplied. This is
	//      the canonical per-agent #N the Monitor tab and Detail header use,
	//      so a task reads identically across task-centric surfaces (mini
	//      widget, active-list, Detail header, Chat attribution).
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

function monitorStatusIcon(status: PaneTaskStatus, theme: Theme): string {
	if (status === "completed") return theme.fg("success", ICONS.check);
	if (status === "failed") return theme.fg("error", ICONS.times);
	if (status === "blocked") return theme.fg("warning", ICONS.times);
	if (status === "running") return dashboardStatusIcon("running", theme);
	if (status === "queued") return theme.fg("warning", ICONS.clock);
	return theme.fg("muted", "·");
}

function monitorStatusText(status: PaneTaskStatus, theme: Theme): string {
	return theme.fg(paneCompletionTone(status), status);
}

export type MonitorSessionType = "pane" | "bg-lane" | "bg-one-shot";

export interface MonitorSessionGroup {
	agent: string;
	createdAt: string;
	id: string;
	isActive: boolean;
	isCompleted: boolean;
	kind: "pane" | "oneshot";
	latestAt: string;
	paneId?: string;
	records: PaneTaskRecord[];
	sessionKey?: string;
	sessionMode?: PaneTaskRecord["sessionMode"];
	taskCount: number;
	transcriptPath?: string;
	type: MonitorSessionType;
	usage?: UsageStats;
}

export type MonitorTreeRow =
	| { key: string; kind: "section"; label: string }
	| { group: MonitorSessionGroup; key: string; kind: "session" }
	| { group: MonitorSessionGroup; key: string; kind: "task"; record: PaneTaskRecord };

const MONITOR_FILTERS: MonitorFilter[] = ["active", "completed", "all"];

function sortedMonitorRecords(registry: PaneTaskRegistry): PaneTaskRecord[] {
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

export function monitorRecordLabel(record: PaneTaskRecord, taskNumbers: Map<string, number>): string {
	const number = taskNumbers.get(record.taskId);
	const numberText = number ? ` #${number}` : "";
	return `${record.agent}${numberText} · ${recordClockTime(record)} · ${shortTaskSuffix(record.taskId)}`;
}

export function monitorTaskRowLabel(record: PaneTaskRecord, taskNumbers: Map<string, number>): string {
	const number = taskNumbers.get(record.taskId);
	const numberText = number ? `#${number}` : "Task";
	return `${numberText} · ${recordClockTime(record)} · ${shortTaskSuffix(record.taskId)}`;
}

function recordTimestampLocal(record: PaneTaskRecord): number {
	const value = Date.parse(record.completedAt ?? record.createdAt ?? "");
	return Number.isFinite(value) ? value : 0;
}

function recordLatestTimestamp(record: PaneTaskRecord): number {
	const value = Date.parse(record.completedAt ?? record.updatedAt ?? record.createdAt ?? "");
	return Number.isFinite(value) ? value : 0;
}

function recordMonitorKind(record: PaneTaskRecord): "pane" | "oneshot" {
	if (record.kind === "pane" || record.kind === "oneshot") return record.kind;
	if (record.paneId || record.inboxFile || record.processingFile || record.doneFile || record.outboxFile || record.completionSourcePath || record.completionArchivePath) return "pane";
	return "oneshot";
}

function monitorStatusIsActive(status: PaneTaskStatus | string | undefined): boolean {
	return !monitorStatusIsTerminal(status);
}

function monitorStatusIsTerminal(status: PaneTaskStatus | string | undefined): boolean {
	return status === "completed" || status === "failed" || status === "blocked" || status === "needs_completion" || status === "cancelled";
}

function monitorSessionKey(record: PaneTaskRecord): { id: string; type: MonitorSessionType } {
	const kind = recordMonitorKind(record);
	if (kind === "pane") {
		if (record.paneId?.trim()) return { id: `pane:${record.paneId.trim()}`, type: "pane" };
		if (record.transcriptPath?.trim()) return { id: `pane-transcript:${record.transcriptPath.trim()}`, type: "pane" };
		return { id: `pane-task:${record.taskId}`, type: "pane" };
	}
	if (record.sessionKey?.trim()) return { id: `bg-lane:${record.agent}:${record.sessionKey.trim()}`, type: "bg-lane" };
	return { id: `bg-one-shot:${record.taskId}`, type: "bg-one-shot" };
}

function usageSum(records: PaneTaskRecord[]): UsageStats | undefined {
	const total: UsageStats = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 };
	let seen = false;
	for (const usage of records.map((record) => record.usage).filter(Boolean) as UsageStats[]) {
		seen = true;
		total.input += usage.input || 0;
		total.output += usage.output || 0;
		total.cacheRead += usage.cacheRead || 0;
		total.cacheWrite += usage.cacheWrite || 0;
		total.cost += usage.cost || 0;
		total.contextTokens += usage.contextTokens || 0;
		total.turns += usage.turns || 0;
	}
	return seen ? total : undefined;
}

export function buildMonitorSessionGroups(records: PaneTaskRecord[]): MonitorSessionGroup[] {
	const bySession = new Map<string, { records: PaneTaskRecord[]; type: MonitorSessionType }>();
	for (const record of records.filter((item) => item.taskId && item.agent)) {
		const session = monitorSessionKey(record);
		const bucket = bySession.get(session.id) ?? { records: [], type: session.type };
		bucket.records.push(record);
		bySession.set(session.id, bucket);
	}
	const groups: MonitorSessionGroup[] = [];
	for (const [id, bucket] of bySession) {
		const groupRecords = [...bucket.records].sort((a, b) => {
			const delta = recordLatestTimestamp(b) - recordLatestTimestamp(a);
			return delta !== 0 ? delta : b.taskId.localeCompare(a.taskId);
		});
		const latest = groupRecords[0];
		if (!latest) continue;
		const created = groupRecords.reduce((min, record) => Math.min(min, Date.parse(record.createdAt) || min), Number.POSITIVE_INFINITY);
		const latestAtTs = groupRecords.reduce((max, record) => Math.max(max, recordLatestTimestamp(record)), 0);
		const kind = bucket.type === "pane" ? "pane" : "oneshot";
		groups.push({
			agent: latest.agent,
			createdAt: Number.isFinite(created) ? new Date(created).toISOString() : latest.createdAt,
			id,
			isActive: groupRecords.some((record) => monitorStatusIsActive(record.status)),
			isCompleted: groupRecords.every((record) => monitorStatusIsTerminal(record.status)),
			kind,
			latestAt: latestAtTs ? new Date(latestAtTs).toISOString() : latest.completedAt ?? latest.updatedAt ?? latest.createdAt,
			paneId: groupRecords.find((record) => record.paneId)?.paneId,
			records: groupRecords,
			sessionKey: groupRecords.find((record) => record.sessionKey)?.sessionKey,
			sessionMode: latest.sessionMode,
			taskCount: groupRecords.length,
			transcriptPath: groupRecords.find((record) => record.transcriptPath)?.transcriptPath,
			type: bucket.type,
			usage: usageSum(groupRecords),
		});
	}
	return groups.sort((a, b) => {
		const delta = Date.parse(b.latestAt) - Date.parse(a.latestAt);
		return delta !== 0 ? delta : a.id.localeCompare(b.id);
	});
}

export function filteredMonitorSessionGroups(groups: MonitorSessionGroup[], filter: MonitorFilter): MonitorSessionGroup[] {
	if (filter === "active") return groups.filter((group) => group.isActive);
	if (filter === "completed") return groups.filter((group) => group.isCompleted);
	return groups;
}

export function monitorTreeRows(groups: MonitorSessionGroup[], filter: MonitorFilter, collapsedSessionIds: Set<string> = new Set()): MonitorTreeRow[] {
	const filtered = filteredMonitorSessionGroups(groups, filter);
	const rows: MonitorTreeRow[] = [];
	const pushGroup = (group: MonitorSessionGroup) => {
		rows.push({ group, key: group.id, kind: "session" });
		if (!collapsedSessionIds.has(group.id)) {
			for (const record of group.records) rows.push({ group, key: `${group.id}:${record.taskId}`, kind: "task", record });
		}
	};
	const pushSection = (label: string, sectionGroups: MonitorSessionGroup[]) => {
		if (filter === "all" && sectionGroups.length === 0) return;
		rows.push({ key: `section:${label.toLowerCase()}`, kind: "section", label: `${label} (${sectionGroups.length})` });
		for (const group of sectionGroups) pushGroup(group);
	};
	if (filter === "active") pushSection("Active", filtered);
	else if (filter === "completed") pushSection("Completed", filtered);
	else {
		pushSection("Active", groups.filter((group) => group.isActive));
		pushSection("Completed", groups.filter((group) => group.isCompleted));
	}
	return rows;
}

function selectableMonitorRows(rows: MonitorTreeRow[]): MonitorTreeRow[] {
	return rows.filter((row) => row.kind !== "section");
}

function selectedMonitorRow(rows: MonitorTreeRow[], ui: AgentBrowserUiState): MonitorTreeRow | undefined {
	return selectableMonitorRows(rows)[ui.monitorSelected];
}

function selectedMonitorRowIndex(rows: MonitorTreeRow[], ui: AgentBrowserUiState): number {
	const selected = selectedMonitorRow(rows, ui);
	return selected ? rows.findIndex((row) => row.key === selected.key) : -1;
}

export function clampMonitorUiToRows(ui: AgentBrowserUiState, rows: MonitorTreeRow[], listRows: number): void {
	const selectable = selectableMonitorRows(rows);
	ui.monitorSelected = Math.max(0, Math.min(ui.monitorSelected, Math.max(0, selectable.length - 1)));
	const selectedIndex = selectedMonitorRowIndex(rows, ui);
	if (selectedIndex >= 0 && selectedIndex < ui.monitorScroll) ui.monitorScroll = selectedIndex;
	if (selectedIndex >= 0 && selectedIndex >= ui.monitorScroll + listRows) ui.monitorScroll = selectedIndex - listRows + 1;
	ui.monitorScroll = Math.max(0, Math.min(ui.monitorScroll, Math.max(0, rows.length - listRows)));
}

function monitorFilter(ui: AgentBrowserUiState): MonitorFilter {
	return ui.monitorFilter ?? "all";
}

function cycleMonitorFilter(filter: MonitorFilter): MonitorFilter {
	return MONITOR_FILTERS[(MONITOR_FILTERS.indexOf(filter) + 1) % MONITOR_FILTERS.length] ?? "all";
}

function renderMonitorFilterBar(filter: MonitorFilter, width: number, theme: Theme): string {
	const parts = MONITOR_FILTERS.map((value) => {
		const label = ` ${value} `;
		return value === filter ? agentActivePill(theme, label) : agentInactivePill(theme, label);
	});
	return truncateToWidth(`${parts.join(" ")} ${theme.fg("dim", "f cycle")}`, width, "");
}

function monitorSessionKindLabel(group: MonitorSessionGroup): string {
	if (group.type === "pane") return "pane";
	if (group.type === "bg-lane") return `bg lane:${truncateSessionKeyForChip(group.sessionKey) ?? "?"}`;
	return "bg";
}

function monitorSessionModeLabel(group: MonitorSessionGroup): string | undefined {
	if (group.type === "bg-lane") return group.sessionMode === "fresh" ? "fresh" : "resumed";
	return sessionModeChipLabel({ kind: group.kind, sessionMode: group.sessionMode, sessionKey: group.sessionKey });
}

function monitorSessionRowLabel(group: MonitorSessionGroup, theme: Theme): string {
	const mode = monitorSessionModeLabel(group);
	const modeSuffix = mode ? `${theme.fg("dim", " · ")}${theme.fg("muted", mode)}` : "";
	const tasksText = group.taskCount === 1 ? "1 task" : `${group.taskCount} tasks`;
	const meta = theme.fg("dim", ` (${tasksText} · last ${formatRelativeTime(group.latestAt)})`);
	return `${theme.fg("muted", monitorSessionKindLabel(group))}${theme.fg("dim", " · ")}${ansiMagenta(group.agent)}${modeSuffix}${meta}`;
}

export function renderMonitorTree(rows: MonitorTreeRow[], records: PaneTaskRecord[], collapsedSessionIds: Set<string>, ui: AgentBrowserUiState, width: number, theme: Theme, listRows: number): string[] {
	const filter = monitorFilter(ui);
	const groups = rows.filter((row) => row.kind === "session").length;
	const lines = [`${agentPaneTitle(theme, "Monitor", ui.pane === "list")} ${theme.fg("dim", `(${groups})`)}`, renderMonitorFilterBar(filter, width, theme), ""];
	if (rows.length === 0 || selectableMonitorRows(rows).length === 0) {
		lines.push(theme.fg("dim", "No tasks yet. Dispatch via `subagent` or `/agents`."));
		return lines;
	}
	if (ui.monitorScroll > 0) lines.push(theme.fg("dim", `↑ ${ui.monitorScroll} earlier`));
	const taskNumbers = taskNumberById(records);
	const selectedKey = selectedMonitorRow(rows, ui)?.key;
	for (const row of rows.slice(ui.monitorScroll, ui.monitorScroll + listRows)) {
		let rendered = "";
		if (row.kind === "section") rendered = `${theme.fg("muted", "▼")} ${theme.fg("accent", row.label)}`;
		else if (row.kind === "session") {
			const expander = collapsedSessionIds.has(row.group.id) ? "▶" : "▼";
			rendered = `  ${theme.fg("muted", expander)} ${monitorSessionRowLabel(row.group, theme)}`;
		} else {
			const label = monitorTaskRowLabel(row.record, taskNumbers);
			rendered = `    ${monitorStatusIcon(row.record.status, theme)} ${theme.fg("text", `Task ${label}`)}${theme.fg("dim", " · ")}${monitorStatusText(row.record.status, theme)}`;
		}
		const line = truncateToWidth(rendered, width, "…");
		lines.push(row.key === selectedKey ? theme.bg("selectedBg", agentPad(line, width)) : line);
	}
	const hidden = Math.max(0, rows.length - (ui.monitorScroll + listRows));
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
	const labelMatch = line.match(/^(Ref|Agent|Task #|Status|Task ID|Created|Done|Model|Session|Session type|Start|Latest|Duration|Tasks|Usage|Pane ID|SessionKey|Transcript|Completion|Archive|Source)\s{2,}(.+)$/);
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

function renderMonitorDetail(
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
	const entry = cache.get(record.taskId);
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

export function appendBgChatMessages(messages: ChatMessage[], items: SubagentDashboardItem[], taskRegistry: PaneTaskRegistry = {}): void {
	// Bg/oneshot agents skip the file bus (no inbox/outbox/.md/.json), so the
	// file-based scan never sees them. Synthesize delegation+completion records
	// from the dashboard item itself; the data we need is already on it.
	// Use the persistent task registry's #N so chat row attribution matches
	// the Monitor tab and Detail header (not the in-memory counter).
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

function formatDateTime(raw: string | undefined): string {
	if (!raw) return "—";
	const date = new Date(raw);
	if (!Number.isFinite(date.getTime())) return raw;
	return date.toISOString().replace("T", " ").replace(/\.\d{3}Z$/, "Z");
}

function formatDurationBetween(start: string | undefined, end: string | undefined): string {
	const startMs = Date.parse(start ?? "");
	const endMs = Date.parse(end ?? "");
	if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs < startMs) return "—";
	const totalSeconds = Math.floor((endMs - startMs) / 1000);
	const hours = Math.floor(totalSeconds / 3600);
	const minutes = Math.floor((totalSeconds % 3600) / 60);
	const seconds = totalSeconds % 60;
	if (hours > 0) return `${hours}h ${minutes}m`;
	if (minutes > 0) return `${minutes}m ${seconds}s`;
	return `${seconds}s`;
}

function monitorSessionTypeLabel(group: MonitorSessionGroup): string {
	if (group.type === "pane") return "pane";
	if (group.type === "bg-lane") return "bg-lane";
	return "bg-one-shot";
}

function monitorStatusBreakdown(group: MonitorSessionGroup): string {
	const counts = new Map<string, number>();
	for (const record of group.records) counts.set(record.status, (counts.get(record.status) ?? 0) + 1);
	return [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0])).map(([status, count]) => `${status}:${count}`).join(" · ");
}

function renderScrollableTraceText(rawLines: string[], type: TraceViewerItem["type"] | undefined, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	const wrapped: string[] = [];
	for (const raw of rawLines) {
		const chunk = renderTraceContentLine(raw, type, width, theme);
		wrapped.push(...(chunk.length > 0 ? chunk : [""]));
	}
	const visibleRows = Math.max(1, rows - 1);
	const maxScroll = Math.max(0, wrapped.length - visibleRows);
	ui.inspectorScroll = Math.max(0, Math.min(ui.inspectorScroll, maxScroll));
	const slice = wrapped.slice(ui.inspectorScroll, ui.inspectorScroll + visibleRows);
	const before = ui.inspectorScroll > 0 ? `↑ ${ui.inspectorScroll}` : "";
	const afterCount = Math.max(0, wrapped.length - ui.inspectorScroll - visibleRows);
	const after = afterCount > 0 ? `↓ ${afterCount}` : "";
	const scrollHint = [before, after].filter(Boolean).join(" · ");
	return scrollHint ? [...slice, ansiYellow(scrollHint)] : [...slice, ""];
}

export function renderMonitorSessionDetail(group: MonitorSessionGroup | undefined, taskNumbers: Map<string, number>, ui: AgentBrowserUiState, width: number, rows: number, theme: Theme): string[] {
	if (!group) return [`${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${theme.fg("dim", "Select a session or task.")}`];
	const safeWidth = Math.max(8, width);
	const mode = monitorSessionModeLabel(group);
	const header = `${agentPaneTitle(theme, "Detail", ui.pane === "inspector")} ${theme.fg("muted", monitorSessionKindLabel(group))}${theme.fg("dim", " · ")}${ansiMagenta(theme.bold(group.agent))}${mode ? `${theme.fg("dim", " · ")}${theme.fg("muted", mode)}` : ""}`;
	const taskCountText = group.taskCount === 1 ? "1 task" : `${group.taskCount} tasks`;
	const metadata = [
		"Session",
		"-------",
		`Session type  ${monitorSessionTypeLabel(group)}`,
		`Start     ${formatDateTime(group.createdAt)}`,
		`Latest    ${formatDateTime(group.latestAt)}`,
		`Duration  ${formatDurationBetween(group.createdAt, group.latestAt)}`,
		`Tasks     ${taskCountText} · ${monitorStatusBreakdown(group)}`,
		group.usage ? `Usage     ${formatUsageStats(group.usage)}` : "Usage     —",
		group.type === "pane" && group.paneId ? `Pane ID   ${group.paneId}` : "",
		group.type === "pane" && group.transcriptPath ? `Transcript  ${group.transcriptPath}` : "",
		group.type === "bg-lane" && group.sessionKey ? `SessionKey  ${group.sessionKey}` : "",
		group.type === "bg-one-shot" && group.transcriptPath ? `Transcript  ${group.transcriptPath}` : "",
		"",
		"Task list",
		"---------",
		...group.records.map((record) => `${monitorStatusIcon(record.status, theme)} Task ${monitorTaskRowLabel(record, taskNumbers)} · ${record.status}`),
		"",
		"Select a task row in the Monitor tree to open task detail.",
	].filter(Boolean);
	const headerLines = [header, ""];
	const bodyRows = Math.max(1, rows - headerLines.length);
	return [...headerLines, ...renderScrollableTraceText(metadata, "summary", ui, safeWidth, bodyRows, theme)].slice(0, rows);
}

function renderMonitorTabBody(
	records: PaneTaskRecord[],
	rows: MonitorTreeRow[],
	collapsedSessionIds: Set<string>,
	cache: Map<string, MonitorDetailEntry>,
	discovery: ReturnType<typeof discoverAgents>,
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
	const left = renderMonitorTree(rows, records, collapsedSessionIds, ui, leftWidth, theme, layout.listRows);
	const selection = selectedMonitorRow(rows, ui);
	const taskNumbers = taskNumberById(records);
	const right = selection?.kind === "task"
		? renderMonitorDetail(selection.record, cache, ui, taskNumbers.get(selection.record.taskId), discovery, rightWidth, bodyRows, theme)
		: renderMonitorSessionDetail(selection?.kind === "session" ? selection.group : undefined, taskNumbers, ui, rightWidth, bodyRows, theme);
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
	ui: AgentBrowserUiState,
	width: number,
	rows: number,
	theme: Theme,
): string[] {
	ui.agentSubtab = 0;
	return renderAgentInspector(row?.agent, statuses, ui, width, rows, theme);
}

function renderAgentsBody(
	discovery: ReturnType<typeof discoverAgents>,
	rowsForList: AgentBrowserRow[],
	statuses: Map<string, AgentPaneStatus>,
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
	const right = renderUnifiedAgentDetail(selectedRow, statuses, ui, rightWidth, bodyRows, theme);
	const rows = bodyRows;
	const searchLine = theme.bg("toolPendingBg", agentPad(` > ${ui.search}${theme.inverse(" ")}`, width));
	const filterLine = `${theme.fg("muted", "all scopes")}: ${rowsForList.length} rows · ${discovery.agents.length} agents · ${paneCount} pane · ${liveCount} live`;
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
	const filtered = () => buildAgentRows(discovery.agents, ui.search, statuses);
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
	const monitorRecords = sortedMonitorRecords(taskRegistry);
	const monitorGroups = buildMonitorSessionGroups(monitorRecords);
	const monitorCollapsedSessions = new Set<string>();
	const currentMonitorRows = () => monitorTreeRows(monitorGroups, monitorFilter(ui), monitorCollapsedSessions);
	const monitorCache = new Map<string, MonitorDetailEntry>();
	const monitorTaskNumbers = taskNumberById(monitorRecords);
	const loadMonitorRecord = (record: PaneTaskRecord | undefined) => {
		if (!record) return;
		const entry = monitorCache.get(record.taskId);
		if (entry?.items || entry?.loading) return;
		monitorCache.set(record.taskId, { loading: true });
		void traceViewerItems(record, monitorTaskNumbers.get(record.taskId), discovery).then((items) => {
			monitorCache.set(record.taskId, { items });
			requestRender();
		}).catch((error) => {
			monitorCache.set(record.taskId, { error: error instanceof Error ? error.message : String(error) });
			requestRender();
		});
	};
	const loadMonitorSelection = () => {
		const row = selectedMonitorRow(currentMonitorRows(), ui);
		if (row?.kind === "task") loadMonitorRecord(row.record);
	};
	const clampMonitor = () => {
		const layout = getLayout();
		const rows = currentMonitorRows();
		clampMonitorUiToRows(ui, rows, layout.listRows);
	};

	const hasActiveTab = () => getActiveItems().length > 0;
	const switchTab = (delta: number) => {
		const next = tabNext(ui.tab, hasActiveTab(), delta);
		if (next === "monitor") {
			ui.tab = "monitor";
			ui.monitorSelected = 0;
			ui.monitorScroll = 0;
			ui.monitorSubtab = 0;
			ui.inspectorScroll = 0;
			ui.pane = "list";
			clampMonitor();
			loadMonitorSelection();
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
				ui.agentSubtab = 0;
				ui.pane = "list";
				requestRender();
				return;
			}
			if (ui.tab === "monitor" && ui.pane === "inspector") {
				if (ui.monitorSubtab === 0) {
					ui.pane = "list";
				} else {
					ui.monitorSubtab -= 1;
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
				ui.agentSubtab = 0;
				return;
			}
			if (ui.tab === "monitor" && ui.pane === "inspector") {
				const total = MONITOR_SUBTAB_LABELS.length;
				if (ui.monitorSubtab < total - 1) {
					ui.monitorSubtab += 1;
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
			} else if (ui.tab === "monitor") {
				if (ui.pane === "inspector") {
					ui.inspectorScroll = Math.max(0, ui.inspectorScroll + delta);
				} else {
					ui.monitorSelected = Math.max(0, ui.monitorSelected + delta);
					ui.monitorSubtab = 0;
					ui.inspectorScroll = 0;
					clampMonitor();
					loadMonitorSelection();
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
		if (ui.tab === "monitor") {
			const layout = getLayout();
			if (matchesKey(data, "f")) {
				ui.monitorFilter = cycleMonitorFilter(monitorFilter(ui));
				ui.monitorSelected = 0;
				ui.monitorScroll = 0;
				ui.monitorSubtab = 0;
				ui.inspectorScroll = 0;
				clampMonitor();
				loadMonitorSelection();
				requestRender();
				return;
			}
			if (matchesKey(data, "up")) {
				if (ui.pane === "inspector") ui.inspectorScroll = Math.max(0, ui.inspectorScroll - 1);
				else { ui.monitorSelected = Math.max(0, ui.monitorSelected - 1); ui.monitorSubtab = 0; ui.inspectorScroll = 0; clampMonitor(); loadMonitorSelection(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "down")) {
				if (ui.pane === "inspector") ui.inspectorScroll += 1;
				else { ui.monitorSelected += 1; ui.monitorSubtab = 0; ui.inspectorScroll = 0; clampMonitor(); loadMonitorSelection(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "pageup" as any)) {
				if (ui.pane === "inspector") ui.inspectorScroll = Math.max(0, ui.inspectorScroll - Math.max(1, layout.bodyRows));
				else { ui.monitorSelected = Math.max(0, ui.monitorSelected - layout.listRows); ui.monitorSubtab = 0; ui.inspectorScroll = 0; clampMonitor(); loadMonitorSelection(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "pagedown" as any)) {
				if (ui.pane === "inspector") ui.inspectorScroll += Math.max(1, layout.bodyRows);
				else { ui.monitorSelected += layout.listRows; ui.monitorSubtab = 0; ui.inspectorScroll = 0; clampMonitor(); loadMonitorSelection(); }
				requestRender();
				return;
			}
			if (matchesKey(data, "home")) { if (ui.pane === "inspector") ui.inspectorScroll = 0; else { ui.monitorSelected = 0; ui.monitorScroll = 0; ui.monitorSubtab = 0; clampMonitor(); loadMonitorSelection(); } requestRender(); return; }
			if (matchesKey(data, "end")) { if (ui.pane === "inspector") ui.inspectorScroll = Number.MAX_SAFE_INTEGER; else { ui.monitorSelected = Math.max(0, selectableMonitorRows(currentMonitorRows()).length - 1); ui.monitorSubtab = 0; clampMonitor(); loadMonitorSelection(); } requestRender(); return; }
			if (matchesKey(data, "enter") || matchesKey(data, "return")) {
				if (ui.pane === "list") {
					const selected = selectedMonitorRow(currentMonitorRows(), ui);
					if (selected?.kind === "session") {
						if (monitorCollapsedSessions.has(selected.group.id)) monitorCollapsedSessions.delete(selected.group.id);
						else monitorCollapsedSessions.add(selected.group.id);
						clampMonitor();
						requestRender();
						return;
					}
					ui.pane = "inspector";
					loadMonitorSelection();
					requestRender();
					return;
				}
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
		if (ui.tab === "monitor") {
			clampMonitor();
			loadMonitorSelection();
			const rows = currentMonitorRows();
			const footer = `${ansiYellow("tab")} ${theme.fg("dim", "switch tabs · ")}${ansiYellow("↑/↓ -/=")} ${theme.fg("dim", "navigate · ")}${ansiYellow("←/→")} ${theme.fg("dim", "tree/detail panes · ")}${ansiYellow("enter")} ${theme.fg("dim", "expand/open · ")}${ansiYellow("f")} ${theme.fg("dim", "filter · ")}${ansiYellow("esc")} ${theme.fg("dim", "close")}`;
			const lines = [tabLine, "", ...renderMonitorTabBody(monitorRecords, rows, monitorCollapsedSessions, monitorCache, discovery, ui, bodyWidth, theme, layout), agentDivider(bodyWidth, theme), ...wrapTextWithAnsi(footer, bodyWidth)];
			return agentFrame(lines, safeWidth, theme, layout.innerRows, "Monitor");
		}
		clamp();
		const footer = `${ansiYellow("tab")} ${theme.fg("dim", "view · ")}${ansiYellow("-/=")} ${theme.fg("dim", "page · ")}${ansiYellow("←/→")} ${theme.fg("dim", "pane · ")}${ansiYellow("alt+m")} ${theme.fg("dim", "edit frontmatter · ")}${ansiYellow("alt+p")} ${theme.fg("dim", "start pane · ")}${ansiYellow("alt+o")} ${theme.fg("dim", "attach · ")}${ansiYellow("alt+x")} ${theme.fg("dim", "stop")}`;
		const lines = [
			tabLine,
			"",
			...renderAgentsBody(discovery, filtered(), statuses, ui, bodyWidth, theme, layout),
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
		monitorSelected: 0,
		monitorScroll: 0,
		monitorSubtab: 0,
		monitorFilter: "all",
	};
	while (true) {
		const discovery = discoverAgents(ctx.cwd, "both");
		const statuses = await loadAgentPaneStatuses(runtimeRoot);
		if (initialAgentName) {
			const selected = sortAgentsForUnifiedView(discovery.agents, statuses).findIndex((agent) => agent.name === initialAgentName);
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
	const compactTranscript = transcriptCompactRows(record);
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
		compactTranscript.length ? compactTranscript.join("\n") : "Transcript unavailable.",
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
