/**
 * Agent discovery and configuration for the project-local Pi subagent extension.
 *
 * Supported locations:
 * - ~/.pi/agent/agents/*.md       user-level agents
 * - .pi/agents/*.md               project-level Pi agents
 * - .claude/agents/*.md           project-level compatibility import
 *
 * When duplicate names exist, precedence is: user < .claude < .pi.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { getAgentDir, parseFrontmatter } from "@earendil-works/pi-coding-agent";
import { effortFromModelId, normalizeReasoningEffort } from "./settings.js";

export type AgentScope = "user" | "project" | "both";

export interface AgentConfig {
	name: string;
	description: string;
	color?: string;
	denyTools?: string[];
	/**
	 * Allowlist for the restricted delegation tool. When non-empty the agent
	 * can call `delegate_subagent` targeting any of the listed agents; when
	 * empty/undefined the tool refuses and is denied at install time.
	 */
	allowedSubagents?: string[];
	model?: string;
	effort?: string;
	pane: boolean;
	systemPrompt: string;
	source: "user" | "project";
	filePath: string;
}

export interface AgentDiscoveryResult {
	agents: AgentConfig[];
	projectAgentsDir: string | null;
}

function normalizeModel(model: unknown): string | undefined {
	if (typeof model !== "string" || model.trim().length === 0) return undefined;
	const trimmed = model.trim();
	if (trimmed === "sonnet") return "claude-sonnet-4-5";
	if (trimmed.startsWith("opus")) return "claude-opus-4-5";
	if (trimmed === "haiku") return "claude-haiku-4-5";
	return trimmed;
}

function parseToolList(value: unknown): string[] | undefined {
	if (typeof value === "string" && value.trim().length > 0) {
		return value
			.split(",")
			.map((tool) => tool.trim())
			.filter(Boolean);
	}
	if (Array.isArray(value)) {
		const tools = value
			.map((tool) => (typeof tool === "string" ? tool.trim() : ""))
			.filter(Boolean);
		return tools.length > 0 ? tools : undefined;
	}
	return undefined;
}

/**
 * Parse the `allowed-subagents` frontmatter (and its aliases) into a
 * normalized array. Unlike `parseToolList`, an explicit empty list is
 * preserved as `[]` so callers can distinguish "user disabled delegation"
 * from "user did not set this field". Returns undefined only when no key
 * was present at all.
 */
function parseAllowedSubagents(frontmatter: Record<string, unknown>): string[] | undefined {
	const keys = ["allowed-subagents", "allowedSubagents", "subagent-agents", "subagent_agents"];
	for (const key of keys) {
		if (!(key in frontmatter)) continue;
		const value = frontmatter[key];
		if (typeof value === "string") {
			const names = value
				.split(",")
				.map((name) => name.trim())
				.filter(Boolean);
			return names;
		}
		if (Array.isArray(value)) {
			const names = value
				.map((name) => (typeof name === "string" ? name.trim() : ""))
				.filter(Boolean);
			return names;
		}
		return [];
	}
	return undefined;
}

function asString(value: unknown): string | undefined {
	return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function asBoolean(value: unknown): boolean {
	if (typeof value === "boolean") return value;
	if (typeof value !== "string") return false;
	const normalized = value.trim().toLowerCase();
	return normalized === "true" || normalized === "yes" || normalized === "1" || normalized === "pane";
}

function loadAgentsFromDir(dir: string, source: "user" | "project"): AgentConfig[] {
	const agents: AgentConfig[] = [];

	if (!fs.existsSync(dir)) {
		return agents;
	}

	let entries: fs.Dirent[];
	try {
		entries = fs.readdirSync(dir, { withFileTypes: true });
	} catch {
		return agents;
	}

	for (const entry of entries) {
		if (!entry.name.endsWith(".md")) continue;
		if (!entry.isFile() && !entry.isSymbolicLink()) continue;

		const filePath = path.join(dir, entry.name);
		let content: string;
		try {
			content = fs.readFileSync(filePath, "utf-8");
		} catch {
			continue;
		}

		const { frontmatter, body } = parseFrontmatter<Record<string, unknown>>(content);
		const name = asString(frontmatter.name);
		const description = asString(frontmatter.description);

		if (!name || !description) {
			continue;
		}

		const model = normalizeModel(frontmatter.model);
		const effort = normalizeReasoningEffort(frontmatter["model-reasoning-effort"] ?? frontmatter.modelReasoningEffort ?? frontmatter.effort) ?? effortFromModelId(model);

		agents.push({
			name,
			description,
			color: asString(frontmatter.color),
			denyTools: parseToolList(frontmatter["deny-tools"] ?? frontmatter.denyTools ?? frontmatter.disallowedTools),
			allowedSubagents: parseAllowedSubagents(frontmatter),
			model,
			// Reasoning effort lives under different keys depending on harness
			// (Claude `effort`, OpenCode/Codex `model-reasoning-effort`). Both
			// resolve to the same display token (low|medium|high|xhigh|max).
			effort,
			pane: asBoolean(frontmatter.pane ?? frontmatter.persistentPane),
			systemPrompt: body,
			source,
			filePath,
		});
	}

	return agents;
}

function isDirectory(p: string): boolean {
	try {
		return fs.statSync(p).isDirectory();
	} catch {
		return false;
	}
}

function findNearestProjectAgentDirs(cwd: string): string[] {
	let currentDir = cwd;
	while (true) {
		const claudeDir = path.join(currentDir, ".claude", "agents");
		const piDir = path.join(currentDir, ".pi", "agents");
		const dirs = [claudeDir, piDir].filter(isDirectory);
		if (dirs.length > 0) return dirs;

		const parentDir = path.dirname(currentDir);
		if (parentDir === currentDir) return [];
		currentDir = parentDir;
	}
}

export function discoverAgents(cwd: string, scope: AgentScope): AgentDiscoveryResult {
	const userDir = path.join(getAgentDir(), "agents");
	const projectAgentDirs = findNearestProjectAgentDirs(cwd);

	const userAgents = scope === "project" ? [] : loadAgentsFromDir(userDir, "user");
	const projectAgents =
		scope === "user" ? [] : projectAgentDirs.flatMap((dir) => loadAgentsFromDir(dir, "project"));

	const agentMap = new Map<string, AgentConfig>();

	if (scope === "both") {
		for (const agent of userAgents) agentMap.set(agent.name, agent);
		for (const agent of projectAgents) agentMap.set(agent.name, agent);
	} else if (scope === "user") {
		for (const agent of userAgents) agentMap.set(agent.name, agent);
	} else {
		for (const agent of projectAgents) agentMap.set(agent.name, agent);
	}

	return {
		agents: Array.from(agentMap.values()).sort((a, b) => a.name.localeCompare(b.name)),
		projectAgentsDir: projectAgentDirs.length > 0 ? projectAgentDirs.join(", ") : null,
	};
}

export function formatAgentList(agents: AgentConfig[], maxItems = Number.POSITIVE_INFINITY): { text: string; remaining: number } {
	if (agents.length === 0) return { text: "none", remaining: 0 };
	const listed = agents.slice(0, maxItems);
	const remaining = agents.length - listed.length;
	return {
		text: listed.map((a) => `${a.name} (${a.source}): ${a.description}`).join("; "),
		remaining,
	};
}
