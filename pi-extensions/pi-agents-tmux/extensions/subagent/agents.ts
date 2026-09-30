/**
 * Agent discovery and configuration for the project-local Pi subagent extension.
 *
 * Supported locations:
 * - ~/.claude/agents/*.md         user-level Claude compatibility agents
 * - ~/.pi/agent/agents/*.md       user-level Pi agents
 * - .pi/agents/*.md               project-level Pi agents
 * - .claude/agents/*.md           project-level compatibility import
 *
 * When duplicate names exist, precedence is:
 * user .claude < user .pi < project .claude < project .pi.
 */

import * as fs from "node:fs";
import { homedir } from "node:os";
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
	// "anthropic/<alias>" (not a bare id) so Pi's own model resolver keeps
	// picking the current non-dated alias in that provider across model
	// generations. A hardcoded dated id would become stale.
	if (trimmed === "sonnet") return "anthropic/sonnet";
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

interface CachedAgentFile {
	version: string;
	agents: AgentConfig[];
}

function fileVersion(filePath: string): string {
	const stat = fs.statSync(filePath);
	return JSON.stringify([fs.realpathSync(filePath), stat.dev, stat.ino, stat.size, stat.mtimeMs, stat.ctimeMs]);
}

function loadAgentsFromDir(dir: string, source: "user" | "project", blockedSourceDirs: string[], files: Map<string, CachedAgentFile>, watched: Map<string, "user" | "project" | "directory">): AgentConfig[] {
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
		watched.set(filePath, source);
		agents.push(...loadAgentFile(filePath, source, blockedSourceDirs, files));
	}

	return agents;
}

function loadAgentFile(filePath: string, source: "user" | "project", blockedSourceDirs: string[], files: Map<string, CachedAgentFile>): AgentConfig[] {
	if (source === "project" && isSameOrDescendantOfAny(filePath, blockedSourceDirs)) {
		files.delete(filePath);
		return [];
	}
	let content: string;
	let version: string;
	try {
		version = fileVersion(filePath);
		const cached = files.get(filePath);
		if (cached?.version === version) {
			return cached.agents;
		}
		content = fs.readFileSync(filePath, "utf-8");
	} catch {
		files.delete(filePath);
		return [];
	}

	const { frontmatter, body } = parseFrontmatter<Record<string, unknown>>(content);
	const name = asString(frontmatter.name);
	const description = asString(frontmatter.description);

	if (!name || !description) {
		files.set(filePath, { version, agents: [] });
		return [];
	}

	const model = normalizeModel(frontmatter.model);
	// The explicit key is kept as written: the launchers prefer the suffix of
	// the model they actually run (`selectedEffortForAgent`), which may be the
	// parent's rather than this one.
	const effort = normalizeReasoningEffort(frontmatter["model-reasoning-effort"] ?? frontmatter.modelReasoningEffort ?? frontmatter.effort) ?? effortFromModelId(model);

	const agent: AgentConfig = {
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
	};
	files.set(filePath, { version, agents: [agent] });
	return [agent];
}

function isDirectory(p: string): boolean {
	try {
		return fs.statSync(p).isDirectory();
	} catch {
		return false;
	}
}

function userHomeDir(): string {
	const home = process.env.HOME?.trim();
	return home ? home : homedir();
}

interface DiscoveryLocation {
	cwd: string;
	home: string;
	userClaudeDir: string;
	userPiDir: string;
}

// The render lookup resolves paths only; discovery owns the filesystem walk.
function discoveryLocation(cwd: string): DiscoveryLocation {
	const home = path.resolve(userHomeDir());
	return {
		cwd: path.resolve(cwd),
		home,
		userClaudeDir: path.join(home, ".claude", "agents"),
		userPiDir: path.resolve(getAgentDir(), "agents"),
	};
}

function realpathOrResolve(p: string): string {
	try {
		return fs.realpathSync(p);
	} catch {
		return path.resolve(p);
	}
}

function isSameOrDescendant(candidate: string, root: string): boolean {
	const relative = path.relative(root, candidate);
	return relative === "" || (relative.length > 0 && !relative.startsWith("..") && !path.isAbsolute(relative));
}

function isSameOrDescendantOfAny(candidate: string, roots: string[]): boolean {
	const realCandidate = realpathOrResolve(candidate);
	return roots.some((root) => isSameOrDescendant(realCandidate, root));
}

function findNearestProjectAgentDirs(location: DiscoveryLocation, blockedSourceDirs: string[], watched: Map<string, "user" | "project" | "directory">): string[] {
	const home = realpathOrResolve(location.home);
	let currentDir = location.cwd;
	while (true) {
		const isHome = realpathOrResolve(currentDir) === home;
		if (isHome) return [];

		const claudeDir = path.join(currentDir, ".claude", "agents");
		const piDir = path.join(currentDir, ".pi", "agents");
		// Absent nearer candidates must replace the inherited inventory when created.
		watched.set(claudeDir, "directory");
		watched.set(piDir, "directory");
		const dirs = [claudeDir, piDir]
			.filter(isDirectory)
			.filter((dir) => !isSameOrDescendantOfAny(dir, blockedSourceDirs));
		if (dirs.length > 0) return dirs;

		const parentDir = path.dirname(currentDir);
		if (parentDir === currentDir) return [];
		currentDir = parentDir;
	}
}

function readDiscovery(location: DiscoveryLocation, files: Map<string, CachedAgentFile>, watched: Map<string, "user" | "project" | "directory">): AgentDiscoveryResult {
	const userAgentDirs = [location.userClaudeDir, location.userPiDir];
	for (const dir of userAgentDirs) watched.set(dir, "directory");
	const userAgentRealDirs = userAgentDirs.map(realpathOrResolve);
	const projectAgentDirs = findNearestProjectAgentDirs(location, userAgentRealDirs, watched);
	return {
		agents: [
			...userAgentDirs.flatMap((dir) => loadAgentsFromDir(dir, "user", [], files, watched)),
			...projectAgentDirs.flatMap((dir) => loadAgentsFromDir(dir, "project", userAgentRealDirs, files, watched)),
		],
		projectAgentsDir: projectAgentDirs.length > 0 ? projectAgentDirs.join(", ") : null,
	};
}

function scopedDiscovery(discovery: AgentDiscoveryResult, scope: AgentScope): AgentDiscoveryResult {
	const agentMap = new Map<string, AgentConfig>();
	for (const agent of discovery.agents) {
		if (scope === "both" || scope === agent.source) agentMap.set(agent.name, agent);
	}
	return {
		agents: Array.from(agentMap.values()).sort((a, b) => a.name.localeCompare(b.name)),
		projectAgentsDir: discovery.projectAgentsDir,
	};
}

type DiscoveryState =
	| { kind: "ready"; discovery: AgentDiscoveryResult; scopes: Record<AgentScope, AgentDiscoveryResult> }
	| { kind: "failed"; error: unknown };

// Process-shared, bounded by directory combinations rather than session events.
// watchFile polls symlink targets and absent paths too; native directory watches
// alone miss target edits and newly created agent directories.
class AgentDiscoveryMemo {
	private files = new Map<string, CachedAgentFile>();
	private watched = new Map<string, "user" | "project" | "directory">();
	private subscriptions = new Map<string, (current: fs.Stats, previous: fs.Stats) => void>();
	private state: DiscoveryState = { kind: "failed", error: new Error("Agent discovery has not loaded") };

	private location: DiscoveryLocation;

	constructor(location: DiscoveryLocation) {
		this.location = location;
	}

	refresh(): void {
		const watched = new Map<string, "user" | "project" | "directory">();
		try {
			const discovery = readDiscovery(this.location, this.files, watched);
			for (const file of this.files.keys()) if (!watched.has(file)) this.files.delete(file);
			this.watched = watched;
			this.update(discovery);
			for (const [file, listener] of this.subscriptions) {
				if (!watched.has(file)) {
					fs.unwatchFile(file, listener);
					this.subscriptions.delete(file);
				}
			}
			for (const [file, source] of watched) {
				if (this.subscriptions.has(file)) continue;
				const listener = () => source === "directory" ? this.refresh() : this.refreshFile(file, source);
				fs.watchFile(file, { persistent: false, interval: 250 }, listener);
				this.subscriptions.set(file, listener);
			}
		} catch (error) {
			this.state = { kind: "failed", error };
		}
	}

	private refreshFile(file: string, source: "user" | "project"): void {
		if (this.state.kind === "failed") {
			this.refresh();
			return;
		}
		try {
			const blockedDirs = source === "project" ? [this.location.userClaudeDir, this.location.userPiDir].map(realpathOrResolve) : [];
			loadAgentFile(file, source, blockedDirs, this.files);
			// Keep listing order: duplicate names retain the same precedence after edits.
			this.update({
				agents: Array.from(this.watched.keys()).flatMap((file) => this.files.get(file)?.agents ?? []),
				projectAgentsDir: this.state.discovery.projectAgentsDir,
			});
		} catch (error) {
			this.state = { kind: "failed", error };
		}
	}

	private update(discovery: AgentDiscoveryResult): void {
		const old = this.state;
		if (old.kind !== "ready" || old.discovery.projectAgentsDir !== discovery.projectAgentsDir ||
			old.discovery.agents.length !== discovery.agents.length ||
			old.discovery.agents.some((agent, index) => agent !== discovery.agents[index])) {
			this.state = { kind: "ready", discovery, scopes: {
				user: scopedDiscovery(discovery, "user"),
				project: scopedDiscovery(discovery, "project"),
				both: scopedDiscovery(discovery, "both"),
			} };
		}
	}

	read(scope: AgentScope): AgentDiscoveryResult {
		switch (this.state.kind) {
			case "ready": return this.state.scopes[scope];
			case "failed": throw this.state.error;
			default: { const unreachable: never = this.state; throw unreachable; }
		}
	}

	dispose(): void {
		for (const [file, listener] of this.subscriptions) fs.unwatchFile(file, listener);
		this.subscriptions.clear();
		this.watched.clear();
		this.files.clear();
	}
}

const discoveryMemos = new Map<string, AgentDiscoveryMemo>();
const MAX_DISCOVERY_MEMOS = 8;

/** Load or revalidate discovery outside rendering. Unchanged files are not read or parsed again. */
export function discoverAgents(cwd: string, scope: AgentScope): AgentDiscoveryResult {
	const location = discoveryLocation(cwd);
	const key = JSON.stringify(location);
	let memo = discoveryMemos.get(key);
	if (!memo) {
		memo = new AgentDiscoveryMemo(location);
		if (discoveryMemos.size >= MAX_DISCOVERY_MEMOS) {
			const oldest = discoveryMemos.entries().next().value;
			if (!oldest) throw new Error("Agent discovery cache is full without an oldest entry");
			oldest[1].dispose();
			discoveryMemos.delete(oldest[0]);
		}
	}
	discoveryMemos.delete(key);
	discoveryMemos.set(key, memo);
	memo.refresh();
	return memo.read(scope);
}

/** Read only memory. Session startup and tool execution populate all scopes; cold calls use the generic preview. */
export function cachedAgentDiscovery(cwd: string, scope: AgentScope): AgentDiscoveryResult | undefined {
	const key = JSON.stringify(discoveryLocation(cwd));
	const memo = discoveryMemos.get(key);
	if (!memo) return undefined;
	discoveryMemos.delete(key);
	discoveryMemos.set(key, memo);
	return memo.read(scope);
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
