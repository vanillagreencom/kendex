// AGENTS.md discovery and sanitization for forwarding to Claude Code.
//
// Pi uses AGENTS.md for long-lived instructions; Claude Code reads the same
// content under "# CLAUDE.md". We walk up from cwd looking for AGENTS.md,
// fall back to <piUserDir>/AGENTS.md (~/.pi/agent/AGENTS.md unless
// PI_CODING_AGENT_DIR points elsewhere), and rewrite pi-specific references
// (~/.pi, .pi/, .pi, pi) to their Claude Code equivalents so any paths or
// references in the file still resolve inside the CC subprocess.
//
// In isolated mode (CLAUDE_BRIDGE_ISOLATED=1), all AGENTS.md discovery is
// disabled. Embedding hosts provide their instruction surface explicitly.

import { existsSync, readFileSync } from "fs";
import { dirname, join, resolve } from "path";
import { isolatedFromEnv, piUserDir } from "./config.js";

function globalAgentsPath(): string {
	return join(piUserDir(), "AGENTS.md");
}

export function resolveAgentsMdPath(): string | undefined {
	if (isolatedFromEnv()) return undefined;
	const fromCwd = findAgentsMdInParents(process.cwd());
	if (fromCwd) return fromCwd;
	const globalPath = globalAgentsPath();
	if (existsSync(globalPath)) return globalPath;
	return undefined;
}

export function findAgentsMdInParents(startDir: string): string | undefined {
	let current = resolve(startDir);
	while (true) {
		const candidate = join(current, "AGENTS.md");
		if (existsSync(candidate)) return candidate;
		const parent = dirname(current);
		if (parent === current) break;
		current = parent;
	}
	return undefined;
}

export function extractAgentsAppend(): string | undefined {
	const agentsPath = resolveAgentsMdPath();
	if (!agentsPath) return undefined;
	try {
		const content = readFileSync(agentsPath, "utf-8").trim();
		if (!content) return undefined;
		const sanitized = sanitizeAgentsContent(content);
		return sanitized.length > 0 ? `# CLAUDE.md\n\n${sanitized}` : undefined;
	} catch {
		return undefined;
	}
}

export function sanitizeAgentsContent(content: string): string {
	let sanitized = content;
	sanitized = sanitized.replace(/~\/\.pi\b/gi, "~/.claude");
	sanitized = sanitized.replace(/(^|[\s'"`])\.pi\//g, "$1.claude/");
	sanitized = sanitized.replace(/\b\.pi\b/gi, ".claude");
	sanitized = sanitized.replace(/\bpi\b/gi, "environment");
	return sanitized;
}
