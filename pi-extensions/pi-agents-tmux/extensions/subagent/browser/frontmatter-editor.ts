import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import {
	type ExtensionContext,
	type Theme,
	withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import { matchesKey, wrapTextWithAnsi, type TUI } from "@earendil-works/pi-tui";
import type { AgentConfig } from "../agents.js";
import { ansiGreen, ansiYellow, simpleFrame } from "../format.js";
import { AGENT_EDIT_CONFIRM_WIDTH, type AgentFrontmatterEdit } from "../types.js";
import { compactAgentPath } from "./shared.js";

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
