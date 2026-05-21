import { existsSync, readFileSync } from "node:fs";
import { isAbsolute } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext, Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { TranscriptRiskResult } from "./budget-guard.js";
import { DEFAULT_TRANSCRIPT_RISK_WARN_CHARS } from "./constants.js";
import { settingNumber } from "./settings.js";
import { transcriptRiskState } from "./transcript-risk.js";

type TranscriptRiskState = TranscriptRiskResult;

type QolContextColor = "accent" | "success" | "warning" | "error" | "muted" | "dim" | "borderMuted" | "text";

interface QolContextDetailItem {
	label: string;
	tokens: number;
	description?: string;
	group?: string;
}

interface QolContextCategory {
	key: string;
	label: string;
	rawTokens: number;
	tokens: number;
	color: QolContextColor;
	icon: string;
}

export interface QolContextUsageMessageDetails {
	usage: {
		contextWindow?: number;
		percent?: number;
		tokens: number;
	};
	model: {
		contextWindow?: number;
		id: string;
		label: string;
		provider: string;
		thinking?: string;
	};
	categories: QolContextCategory[];
	freeTokens?: number;
	contextFiles: QolContextDetailItem[];
	skills: QolContextDetailItem[];
	customAgents: QolContextDetailItem[];
	builtinTools: QolContextDetailItem[];
	extensionTools: QolContextDetailItem[];
	mcpTools: QolContextDetailItem[];
	messageStats: {
		assistant: number;
		bash: number;
		branchEntries: number;
		compact: number;
		contextMessages: number;
		custom: number;
		toolResult: number;
		user: number;
	};
	compactSummaries: QolContextDetailItem[];
	transcriptRisk?: TranscriptRiskState;
	note?: string;
}

function qcuSafeString(value: unknown): string {
	if (typeof value === "string") return value;
	if (value == null) return "";
	const seen = new WeakSet<object>();
	try {
		return JSON.stringify(value, (_key, current) => {
			if (typeof current === "function") return undefined;
			if (typeof current === "object" && current !== null) {
				if (seen.has(current)) return "[Circular]";
				seen.add(current);
			}
			return current;
		}) ?? "";
	} catch {
		return String(value);
	}
}

function qcuEstimateTokens(value: unknown): number {
	const text = qcuSafeString(value);
	if (!text) return 0;
	return Math.max(1, Math.ceil(text.length / 4));
}

function qcuFormatTokens(value: number | undefined): string {
	const n = Math.max(0, Math.round(Number(value) || 0));
	const trim = (input: number) => input.toFixed(input >= 10 ? 0 : 1).replace(/\.0$/, "");
	if (n >= 1_000_000) return `${trim(n / 1_000_000)}M`;
	if (n >= 1_000) return `${trim(n / 1_000)}K`;
	return n.toLocaleString();
}

function qcuPercent(tokens: number, contextWindow?: number): string {
	if (!contextWindow || contextWindow <= 0) return "--";
	return `${((tokens / contextWindow) * 100).toFixed(1)}%`;
}

function qcuPadAnsi(text: string, width: number): string {
	const clipped = truncateToWidth(text, Math.max(0, width), "");
	return `${clipped}${" ".repeat(Math.max(0, width - visibleWidth(clipped)))}`;
}

function qcuOneLine(text: string, maxWidth: number): string {
	return truncateToWidth(text.replace(/[\r\n\t]+/g, " ").replace(/\s+/g, " ").trim(), maxWidth, "…");
}

function qcuDetailLabel(item: unknown, fallback: string): string {
	if (typeof item === "string") return qcuOneLine(item, 90) || fallback;
	if (!item || typeof item !== "object") return fallback;
	const obj = item as Record<string, unknown>;
	const raw = obj.name ?? obj.title ?? obj.label ?? obj.id ?? obj.path ?? obj.file ?? obj.filePath ?? obj.sourcePath ?? obj.description ?? fallback;
	const label = typeof raw === "string" ? raw : fallback;
	return qcuOneLine(label, 90) || fallback;
}

function qcuDetailText(item: unknown): string {
	if (typeof item === "string") return item;
	if (!item || typeof item !== "object") return qcuSafeString(item);
	const obj = item as Record<string, unknown>;
	const direct = obj.content ?? obj.text ?? obj.markdown ?? obj.body ?? obj.instructions ?? obj.description ?? obj.prompt;
	if (typeof direct === "string") return direct;
	const pathValue = obj.path ?? obj.file ?? obj.filePath ?? obj.sourcePath;
	if (typeof pathValue === "string" && isAbsolute(pathValue) && existsSync(pathValue)) {
		try {
			return readFileSync(pathValue, "utf8");
		} catch {
			// Fall through to a safe structural estimate.
		}
	}
	return qcuSafeString(item);
}

function qcuDetailsFromItems(items: unknown[], fallbackGroup?: string): QolContextDetailItem[] {
	return items
		.map((item, index) => {
			const obj = item && typeof item === "object" ? item as Record<string, unknown> : undefined;
			const sourceInfo = obj?.sourceInfo && typeof obj.sourceInfo === "object" ? obj.sourceInfo as Record<string, unknown> : undefined;
			const group = typeof obj?.scope === "string" ? obj.scope : typeof sourceInfo?.scope === "string" ? sourceInfo.scope : typeof sourceInfo?.source === "string" ? sourceInfo.source : fallbackGroup;
			const description = typeof obj?.description === "string" ? obj.description : undefined;
			return {
				description: description ? qcuOneLine(description, 120) : undefined,
				group,
				label: qcuDetailLabel(item, `item-${index + 1}`),
				tokens: qcuEstimateTokens(qcuDetailText(item)),
			};
		})
		.filter((item) => item.tokens > 0 || item.label.length > 0);
}

function qcuPromptOptionArray(options: unknown, keys: string[]): unknown[] {
	if (!options || typeof options !== "object") return [];
	const obj = options as Record<string, unknown>;
	for (const key of keys) {
		const value = obj[key];
		if (Array.isArray(value)) return value;
	}
	return [];
}

function qcuUniqDetails(items: QolContextDetailItem[]): QolContextDetailItem[] {
	const byLabel = new Map<string, QolContextDetailItem>();
	for (const item of items) {
		const key = `${item.group ?? ""}:${item.label}`;
		const existing = byLabel.get(key);
		if (!existing || item.tokens > existing.tokens) byLabel.set(key, item);
	}
	return Array.from(byLabel.values()).sort((a, b) => b.tokens - a.tokens || a.label.localeCompare(b.label));
}

function qcuTokenSum(items: QolContextDetailItem[]): number {
	return items.reduce((sum, item) => sum + Math.max(0, item.tokens), 0);
}

function qcuMessageTokens(message: any): number {
	if (!message || typeof message !== "object") return 0;
	if (message.role === "bashExecution" && message.excludeFromContext === true) return 0;
	if (message.role === "compactionSummary") return qcuEstimateTokens(message.summary ?? "");
	if (message.role === "branchSummary") return qcuEstimateTokens(message.summary ?? "");
	if (message.role === "custom") return qcuEstimateTokens(message.content ?? "");
	const content = message.content;
	if (typeof content === "string") return qcuEstimateTokens(content);
	if (!Array.isArray(content)) return qcuEstimateTokens(content);
	return content.reduce((sum: number, part: any) => {
		if (part?.type === "text") return sum + qcuEstimateTokens(part.text ?? "");
		if (part?.type === "thinking") return sum + qcuEstimateTokens(part.thinking ?? "");
		if (part?.type === "toolCall") return sum + qcuEstimateTokens(part);
		if (part?.type === "image") return sum + 85;
		return sum + qcuEstimateTokens(part);
	}, 0);
}

function qcuBuildMessageStats(ctx: ExtensionCommandContext): { rawMessageTokens: number; rawCompactTokens: number; stats: QolContextUsageMessageDetails["messageStats"]; compactSummaries: QolContextDetailItem[] } {
	const sm = ctx.sessionManager as any;
	const branch = Array.isArray(sm.getBranch?.()) ? sm.getBranch() : [];
	const built = typeof sm.buildSessionContext === "function" ? sm.buildSessionContext() : undefined;
	const messages = Array.isArray(built?.messages) ? built.messages : branch.filter((entry: any) => entry?.type === "message").map((entry: any) => entry.message);
	const stats = { assistant: 0, bash: 0, branchEntries: branch.length, compact: 0, contextMessages: messages.length, custom: 0, toolResult: 0, user: 0 };
	let rawMessageTokens = 0;
	let rawCompactTokens = 0;
	for (const message of messages) {
		const tokens = qcuMessageTokens(message);
		switch (message?.role) {
			case "user": stats.user += 1; rawMessageTokens += tokens; break;
			case "assistant": stats.assistant += 1; rawMessageTokens += tokens; break;
			case "toolResult": stats.toolResult += 1; rawMessageTokens += tokens; break;
			case "bashExecution": stats.bash += 1; rawMessageTokens += tokens; break;
			case "custom": stats.custom += 1; rawMessageTokens += tokens; break;
			case "compactionSummary":
			case "branchSummary":
				stats.compact += 1;
				rawCompactTokens += tokens;
				break;
			default:
				rawMessageTokens += tokens;
		}
	}
	const compactSummaries = branch
		.filter((entry: any) => entry?.type === "compaction" || entry?.type === "branch_summary")
		.map((entry: any) => ({
			group: entry.type === "compaction" ? "compaction" : "branch",
			label: entry.type === "compaction" ? `Compaction${entry.tokensBefore ? ` (${qcuFormatTokens(Number(entry.tokensBefore))} before)` : ""}` : "Branch summary",
			tokens: qcuEstimateTokens(entry.summary ?? ""),
		}))
		.reverse();
	return { compactSummaries, rawCompactTokens, rawMessageTokens, stats };
}

function qcuToolDetails(pi: ExtensionAPI): {
	builtinTools: QolContextDetailItem[];
	extensionTools: QolContextDetailItem[];
	mcpTools: QolContextDetailItem[];
	rawBuiltinToolTokens: number;
	rawExtensionToolTokens: number;
	rawMcpToolTokens: number;
} {
	const api = pi as any;
	const activeNames = new Set<string>(Array.isArray(api.getActiveTools?.()) ? api.getActiveTools() : []);
	const allTools = Array.isArray(api.getAllTools?.()) ? api.getAllTools() : [];
	const activeTools = allTools.filter((tool: any) => typeof tool?.name === "string" && (activeNames.size === 0 || activeNames.has(tool.name)));
	const details = activeTools.map((tool: any) => {
		const sourceInfo = tool.sourceInfo && typeof tool.sourceInfo === "object" ? tool.sourceInfo : undefined;
		const source = typeof sourceInfo?.source === "string" ? sourceInfo.source : undefined;
		return {
			description: typeof tool.description === "string" ? qcuOneLine(tool.description, 120) : undefined,
			group: source,
			label: tool.name,
			tokens: qcuEstimateTokens({ description: tool.description, name: tool.name, parameters: tool.parameters, promptGuidelines: tool.promptGuidelines, promptSnippet: tool.promptSnippet }),
		};
	});
	const isMcpTool = (tool: QolContextDetailItem) => /^mcp_{1,2}/i.test(tool.label) || /mcp/i.test(tool.group ?? "");
	const mcpTools = details.filter(isMcpTool);
	const builtinTools = details.filter((tool) => !isMcpTool(tool) && (tool.group === "builtin" || tool.group === "sdk"));
	const extensionTools = details.filter((tool) => !isMcpTool(tool) && tool.group !== "builtin" && tool.group !== "sdk");
	return {
		builtinTools: qcuUniqDetails(builtinTools),
		extensionTools: qcuUniqDetails(extensionTools),
		mcpTools: qcuUniqDetails(mcpTools),
		rawBuiltinToolTokens: qcuTokenSum(builtinTools),
		rawExtensionToolTokens: qcuTokenSum(extensionTools),
		rawMcpToolTokens: qcuTokenSum(mcpTools),
	};
}

function qcuSkillDetails(pi: ExtensionAPI, promptOptions: unknown): QolContextDetailItem[] {
	const fromOptions = qcuDetailsFromItems(qcuPromptOptionArray(promptOptions, ["skills", "loadedSkills", "availableSkills"]), "loaded");
	const commands = Array.isArray((pi as any).getCommands?.()) ? (pi as any).getCommands() : [];
	const fromCommands = commands
		.filter((command: any) => command?.source === "skill")
		.map((command: any) => {
			const sourceInfo = command.sourceInfo && typeof command.sourceInfo === "object" ? command.sourceInfo : undefined;
			return {
				description: typeof command.description === "string" ? qcuOneLine(command.description, 120) : undefined,
				group: typeof sourceInfo?.scope === "string" ? sourceInfo.scope : typeof sourceInfo?.source === "string" ? sourceInfo.source : "skill",
				label: String(command.name ?? "skill").replace(/^skill:/, ""),
				tokens: qcuEstimateTokens(`${command.name ?? ""}\n${command.description ?? ""}`),
			};
		});
	return qcuUniqDetails([...fromOptions, ...fromCommands]);
}

function qcuScaleCategories(rawCategories: Array<Omit<QolContextCategory, "tokens">>, totalTokens: number, contextWindow?: number): QolContextCategory[] {
	const rawTotal = rawCategories.reduce((sum, category) => sum + Math.max(0, category.rawTokens), 0);
	if (rawTotal <= 0) {
		return [{ color: "accent", icon: "◉", key: "messages", label: "Messages", rawTokens: totalTokens, tokens: totalTokens }];
	}
	const ratio = totalTokens / rawTotal;
	const categories = rawCategories
		.map((category) => ({ ...category, tokens: Math.max(0, Math.round(category.rawTokens * ratio)) }))
		.filter((category) => category.tokens > 0 || category.rawTokens > 0);
	const scaledTotal = categories.reduce((sum, category) => sum + category.tokens, 0);
	const delta = totalTokens - scaledTotal;
	const messages = categories.find((category) => category.key === "messages") ?? categories[categories.length - 1];
	if (messages && delta !== 0) messages.tokens = Math.max(0, messages.tokens + delta);
	const used = categories.reduce((sum, category) => sum + category.tokens, 0);
	if (contextWindow && used < totalTokens) {
		const other = totalTokens - used;
		if (other > 0) categories.push({ color: "dim", icon: "◉", key: "other", label: "Other", rawTokens: other, tokens: other });
	}
	return categories;
}

function qcuExtractProjectAgents(systemPrompt: string): { agents: QolContextDetailItem[]; tokens: number } {
	const marker = systemPrompt.includes("## Project Agents") ? "## Project Agents" : "## Project Subagents";
	const start = systemPrompt.indexOf(marker);
	if (start < 0) return { agents: [], tokens: 0 };
	const rest = systemPrompt.slice(start);
	const next = rest.slice(marker.length).search(/\n##\s+/);
	const section = next >= 0 ? rest.slice(0, marker.length + next) : rest;
	const agents = section
		.split(/\r?\n/)
		.filter((line) => line.startsWith("- "))
		.map((line) => {
			const match = line.match(/^-\s*([^:]+):\s*(.*?)(?:\s*\(([^)]*)\))?$/);
			return {
				description: match?.[2] ? qcuOneLine(match[2], 120) : undefined,
				group: match?.[3]?.includes("project") ? "project" : match?.[3]?.includes("user") ? "user" : "agent",
				label: qcuOneLine(match?.[1] ?? line.replace(/^[-\s]+/, ""), 90),
				tokens: qcuEstimateTokens(line),
			};
		});
	return { agents: qcuUniqDetails(agents), tokens: qcuEstimateTokens(section) };
}

function qcuMessagesForRisk(ctx: ExtensionCommandContext): any[] {
	const sm = ctx.sessionManager as any;
	const built = typeof sm.buildSessionContext === "function" ? sm.buildSessionContext() : undefined;
	if (Array.isArray(built?.messages)) return built.messages;
	const branch = Array.isArray(sm.getBranch?.()) ? sm.getBranch() : [];
	return branch.filter((entry: any) => entry?.type === "message").map((entry: any) => entry.message);
}

export function buildQolContextUsageDetails(pi: ExtensionAPI, ctx: ExtensionCommandContext, promptOptions: unknown): QolContextUsageMessageDetails | undefined {
	const usage = ctx.getContextUsage?.() as { contextWindow?: unknown; percent?: unknown; tokens?: unknown } | undefined;
	const tokens = Number(usage?.tokens);
	if (!Number.isFinite(tokens) || tokens <= 0) return undefined;
	const model = (ctx as any).model ?? {};
	const contextWindow = Number(usage?.contextWindow ?? model.contextWindow);
	const safeContextWindow = Number.isFinite(contextWindow) && contextWindow > 0 ? contextWindow : undefined;
	const percent = Number(usage?.percent);
	const systemPrompt = ctx.getSystemPrompt?.() ?? "";
	const contextFiles = qcuUniqDetails(qcuDetailsFromItems(qcuPromptOptionArray(promptOptions, ["contextFiles", "agentsFiles", "memoryFiles"]), "context"));
	const skills = qcuSkillDetails(pi, promptOptions);
	const extractedAgents = qcuExtractProjectAgents(systemPrompt);
	const customAgents = qcuUniqDetails([...qcuDetailsFromItems(qcuPromptOptionArray(promptOptions, ["customAgents", "agents", "agentSnippets"]), "agent"), ...extractedAgents.agents]);
	const { builtinTools, extensionTools, mcpTools, rawBuiltinToolTokens, rawExtensionToolTokens, rawMcpToolTokens } = qcuToolDetails(pi);
	const { compactSummaries, rawCompactTokens, rawMessageTokens, stats } = qcuBuildMessageStats(ctx);
	const rawCompactSummaryTokens = rawCompactTokens > 0 ? rawCompactTokens : qcuTokenSum(compactSummaries);
	const rawContextFiles = qcuTokenSum(contextFiles);
	const rawSkills = qcuTokenSum(skills);
	const rawCustomAgents = Math.max(qcuTokenSum(customAgents), extractedAgents.tokens);
	const rawSystemPromptTotal = qcuEstimateTokens(systemPrompt);
	const rawSystemPrompt = Math.max(0, rawSystemPromptTotal - rawContextFiles - rawSkills - rawCustomAgents);
	const categories = qcuScaleCategories([
		{ color: "muted", icon: "◉", key: "system", label: "System prompt", rawTokens: rawSystemPrompt },
		{ color: "warning", icon: "◉", key: "builtinTools", label: "Built-in tools", rawTokens: rawBuiltinToolTokens },
		{ color: "error", icon: "◉", key: "extensionTools", label: "Extension tools", rawTokens: rawExtensionToolTokens },
		{ color: "warning", icon: "◉", key: "mcpTools", label: "MCP tools", rawTokens: rawMcpToolTokens },
		{ color: "success", icon: "◉", key: "agents", label: "Custom agents", rawTokens: rawCustomAgents },
		{ color: "error", icon: "◉", key: "contextFiles", label: "Context / memory files", rawTokens: rawContextFiles },
		{ color: "success", icon: "◉", key: "skills", label: "Skills", rawTokens: rawSkills },
		{ color: "accent", icon: "◉", key: "messages", label: "Messages", rawTokens: rawMessageTokens },
		{ color: "muted", icon: "◉", key: "compact", label: "Compact buffer", rawTokens: rawCompactSummaryTokens },
	], tokens, safeContextWindow);
	const modelProvider = typeof model.provider === "string" ? model.provider : "unknown";
	const modelId = typeof model.id === "string" ? model.id : typeof model.model === "string" ? model.model : "unknown";
	const modelName = typeof model.name === "string" ? model.name : modelId;
	const thinking = typeof (pi as any).getThinkingLevel === "function" ? (pi as any).getThinkingLevel() : undefined;
	const transcriptThreshold = Math.floor(settingNumber("compaction.transcriptRiskWarnChars", DEFAULT_TRANSCRIPT_RISK_WARN_CHARS, ctx.cwd));
	const transcriptRisk = transcriptRiskState(qcuMessagesForRisk(ctx), transcriptThreshold);
	return {
		builtinTools,
		categories,
		compactSummaries,
		contextFiles,
		customAgents,
		extensionTools,
		freeTokens: safeContextWindow ? Math.max(0, safeContextWindow - tokens) : undefined,
		mcpTools,
		messageStats: stats,
		transcriptRisk: transcriptRisk.chars > 0 || transcriptRisk.error ? transcriptRisk : undefined,
		model: {
			contextWindow: safeContextWindow,
			id: modelId,
			label: modelName,
			provider: modelProvider,
			thinking: typeof thinking === "string" && thinking !== "off" ? thinking : undefined,
		},
		note: promptOptions ? undefined : "Context-file and skill breakdowns become more precise after the next agent turn.",
		skills,
		usage: {
			contextWindow: safeContextWindow,
			percent: Number.isFinite(percent) ? percent : safeContextWindow ? (tokens / safeContextWindow) * 100 : undefined,
			tokens,
		},
	};
}

function qcuLimitDetails(items: QolContextDetailItem[], limit: number): QolContextDetailItem[] {
	return items.slice(0, Math.max(0, limit));
}

function qcuBranch(theme: Theme, branch: "├" | "└" | "│"): string {
	if (branch === "│") return theme.fg("muted", "│  ");
	return theme.fg("muted", `${branch}─ `);
}

function qcuStem(theme: Theme, isLast: boolean): string {
	return isLast ? theme.fg("borderMuted", "   ") : qcuBranch(theme, "│");
}

function qcuRenderDetailSection(lines: string[], title: string, items: QolContextDetailItem[], theme: Theme, options: { empty?: string; limit?: number; showDescriptions?: boolean } = {}): void {
	if (items.length === 0) {
		if (options.empty) {
			lines.push("");
			lines.push(`${theme.fg("customMessageLabel", theme.bold(title))}`);
			lines.push(`${qcuBranch(theme, "└")}${theme.fg("dim", options.empty)}`);
		}
		return;
	}
	const visible = qcuLimitDetails(items, options.limit ?? 10);
	lines.push("");
	lines.push(`${theme.fg("customMessageLabel", theme.bold(title))}`);
	visible.forEach((item, index) => {
		const isLast = index === visible.length - 1 && visible.length === items.length;
		const branch = isLast ? "└" : "├";
		const group = item.group ? theme.fg("dim", ` ${item.group}`) : "";
		lines.push(`${qcuBranch(theme, branch)}${theme.fg("text", qcuOneLine(item.label, 72))}: ${theme.fg("accent", qcuFormatTokens(item.tokens))} tokens${group}`);
		if (options.showDescriptions && item.description) lines.push(`${qcuStem(theme, isLast)}${theme.fg("dim", qcuOneLine(item.description, 100))}`);
	});
	if (items.length > visible.length) lines.push(`${qcuBranch(theme, "└")}${theme.fg("dim", `… ${items.length - visible.length} more`)}`);
}

export function renderQolContextUsageMessage(message: any, _options: any, theme: Theme): { render(width: number): string[]; invalidate(): void } {
	const details = message?.details as QolContextUsageMessageDetails | undefined;
	return {
		invalidate() {},
		render(width: number): string[] {
			if (!details) return [theme.fg("warning", "Context usage details unavailable.")];
			const safeWidth = Math.max(48, width);
			const lines: string[] = [];
			lines.push(`${theme.fg("accent", "› /context")}`);
			lines.push(`└ ${theme.fg("customMessageLabel", theme.bold("Context Usage"))}`);
			const gridCols = safeWidth >= 112 ? 28 : safeWidth >= 88 ? 22 : 16;
			const gridRows = safeWidth >= 88 ? 7 : 6;
			const totalBlocks = gridCols * gridRows;
			const contextWindow = details.usage.contextWindow;
			const gridDenominator = contextWindow ?? details.usage.tokens;
			const blockCategories: QolContextCategory[] = [];
			for (const category of details.categories) {
				if (!gridDenominator || category.tokens <= 0) continue;
				let count = Math.round((category.tokens / gridDenominator) * totalBlocks);
				if (count === 0 && category.tokens > 0) count = 1;
				for (let index = 0; index < count && blockCategories.length < totalBlocks; index += 1) blockCategories.push(category);
			}
			const gridLines: string[] = [];
			for (let row = 0; row < gridRows; row += 1) {
				let line = "";
				for (let col = 0; col < gridCols; col += 1) {
					const category = blockCategories[row * gridCols + col];
					line += category ? theme.fg(category.color as any, category.icon) : theme.fg("borderMuted", "□");
					if (col !== gridCols - 1) line += " ";
				}
				gridLines.push(line);
			}
			const modelBits = [`${details.model.provider}/${details.model.id}`];
			if (details.model.thinking) modelBits.push(`thinking ${details.model.thinking}`);
			const summaryLines = [
				`${theme.fg("text", theme.bold(details.model.label))}${contextWindow ? theme.fg("muted", ` (${qcuFormatTokens(contextWindow)} context)`) : ""}`,
				theme.fg("muted", modelBits.join(" · ")),
				`${theme.fg("accent", qcuFormatTokens(details.usage.tokens))}${contextWindow ? `/${qcuFormatTokens(contextWindow)}` : ""} tokens${details.usage.percent != null ? ` (${details.usage.percent.toFixed(1)}%)` : ""}`,
				"",
				theme.fg("muted", theme.italic("Estimated usage by category")),
				...details.categories.map((category) => `${theme.fg(category.color as any, category.icon)} ${theme.fg("text", `${category.label}:`)} ${qcuFormatTokens(category.tokens)} tokens ${theme.fg("muted", `(${qcuPercent(category.tokens, contextWindow)})`)}`),
			];
			if (details.freeTokens != null) summaryLines.push(`${theme.fg("borderMuted", "□")} ${theme.fg("text", "Free space:")} ${qcuFormatTokens(details.freeTokens)} ${theme.fg("muted", `(${qcuPercent(details.freeTokens, contextWindow)})`)}`);
			lines.push("");
			if (safeWidth >= 82) {
				const leftWidth = visibleWidth(gridLines[0] ?? "");
				const maxRows = Math.max(gridLines.length, summaryLines.length);
				for (let index = 0; index < maxRows; index += 1) {
					lines.push(`  ${qcuPadAnsi(gridLines[index] ?? "", leftWidth)}    ${summaryLines[index] ?? ""}`.trimEnd());
				}
			} else {
				lines.push(...gridLines.map((line) => `  ${line}`));
				lines.push("");
				lines.push(...summaryLines.map((line) => `  ${line}`));
			}
			if (details.note) lines.push("", theme.fg("dim", details.note));
			const messageStats = details.messageStats;
			lines.push("");
			lines.push(`${theme.fg("customMessageLabel", theme.bold("Conversation"))}`);
			lines.push(`${qcuBranch(theme, "├")}context messages: ${theme.fg("accent", String(messageStats.contextMessages))} ${theme.fg("dim", `(${messageStats.branchEntries} branch entries)`)}`);
			lines.push(`${qcuBranch(theme, "├")}user: ${messageStats.user} · assistant: ${messageStats.assistant} · tool results: ${messageStats.toolResult}`);
			lines.push(`${qcuBranch(theme, "└")}bash: ${messageStats.bash} · custom: ${messageStats.custom} · compact summaries: ${messageStats.compact}`);
			qcuRenderDetailSection(lines, "MCP tools", details.mcpTools, theme, { empty: undefined, limit: 12, showDescriptions: false });
			qcuRenderDetailSection(lines, "Built-in tools", details.builtinTools, theme, { limit: details.mcpTools.length > 0 ? 8 : 12, showDescriptions: false });
			qcuRenderDetailSection(lines, "Extension tools", details.extensionTools, theme, { limit: 12, showDescriptions: false });
			qcuRenderDetailSection(lines, "Custom agents · /agents", details.customAgents, theme, { limit: 12, showDescriptions: false });
			qcuRenderDetailSection(lines, "Context / memory files", details.contextFiles, theme, { limit: 12, showDescriptions: false });
			qcuRenderDetailSection(lines, "Skills · /skills", details.skills, theme, { empty: "No skill commands discovered.", limit: 14, showDescriptions: false });
			qcuRenderDetailSection(lines, "Compact buffer", details.compactSummaries, theme, { limit: 6, showDescriptions: false });
			if (details.transcriptRisk?.error) {
				const r = details.transcriptRisk;
				const safe = r.error.replace(/[\x00-\x1f]+/g, " ").slice(0, 200);
				lines.push("");
				lines.push(`${theme.fg("warning", theme.bold("Transcript risk"))}`);
				lines.push(`${qcuBranch(theme, "└")}${theme.fg("warning", `risk calculation failed: ${safe}`)}`);
			} else if (details.transcriptRisk?.exceeded) {
				const r = details.transcriptRisk;
				lines.push("");
				lines.push(`${theme.fg("warning", theme.bold("Transcript risk"))}`);
				lines.push(`${qcuBranch(theme, "├")}${theme.fg("warning", `serialized payload ${qcuFormatTokens(Math.ceil(r.chars / 4))} tokens (${r.chars.toLocaleString()} chars) >= ${r.threshold.toLocaleString()} char warn budget`)}`);
				lines.push(`${qcuBranch(theme, "└")}${theme.fg("muted", "compact soon or raise compaction.transcriptRiskWarnChars to silence")}`);
			} else if (details.transcriptRisk && details.transcriptRisk.chars > 0) {
				const r = details.transcriptRisk;
				lines.push("");
				lines.push(`${theme.fg("muted", `Transcript payload: ${qcuFormatTokens(Math.ceil(r.chars / 4))} tokens (${r.chars.toLocaleString()} chars / ${r.threshold.toLocaleString()} warn budget).`)}`);
			}
			return lines.map((line) => truncateToWidth(line, safeWidth, ""));
		},
	};
}
