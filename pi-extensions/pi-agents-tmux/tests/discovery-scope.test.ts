import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { discoverAgents } from "../extensions/subagent/agents.js";

function writeAgent(dir: string, name: string, description: string): void {
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, `${name}.md`), `---\nname: ${name}\ndescription: ${description}\n---\n\n${name} body\n`, "utf8");
}

function withTempDiscoveryEnv<T>(fn: (env: { home: string; piDir: string; cwd: string }) => T): T {
	const root = mkdtempSync(join(tmpdir(), "pi-agents-discovery-"));
	const home = join(root, "home");
	const piDir = join(root, "pi-user");
	const cwd = join(home, "workspace", "repo", "src");
	mkdirSync(cwd, { recursive: true });

	const previousHome = process.env.HOME;
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	process.env.HOME = home;
	process.env.PI_CODING_AGENT_DIR = piDir;
	try {
		return fn({ home, piDir, cwd });
	} finally {
		if (previousHome === undefined) delete process.env.HOME;
		else process.env.HOME = previousHome;
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
		rmSync(root, { force: true, recursive: true });
	}
}

describe("agent discovery scope", () => {
	test("does not classify HOME .claude agents as project agents", () => {
		withTempDiscoveryEnv(({ home, cwd }) => {
			writeAgent(join(home, ".claude", "agents"), "claude-user", "Claude user agent");

			const { agents, projectAgentsDir } = discoverAgents(cwd, "project");

			expect(agents.map((agent) => agent.name)).not.toContain("claude-user");
			expect(projectAgentsDir).toBeNull();
		});
	});

	test("loads HOME .claude agents as user agents and keeps Pi user precedence", () => {
		withTempDiscoveryEnv(({ home, piDir, cwd }) => {
			writeAgent(join(home, ".claude", "agents"), "claude-only", "Claude user agent");
			writeAgent(join(home, ".claude", "agents"), "shared", "Claude shared user agent");
			writeAgent(join(piDir, "agents"), "shared", "Pi shared user agent");

			const { agents } = discoverAgents(cwd, "user");
			const byName = new Map(agents.map((agent) => [agent.name, agent]));

			expect(byName.get("claude-only")?.source).toBe("user");
			expect(byName.get("shared")?.source).toBe("user");
			expect(byName.get("shared")?.description).toBe("Pi shared user agent");
		});
	});

	test("preserves project-local .claude agents as project agents", () => {
		withTempDiscoveryEnv(({ home, cwd }) => {
			const repo = join(home, "workspace", "repo");
			writeAgent(join(repo, ".claude", "agents"), "project-claude", "Project Claude agent");

			const { agents, projectAgentsDir } = discoverAgents(cwd, "project");
			const agent = agents.find((candidate) => candidate.name === "project-claude");

			expect(agent?.source).toBe("project");
			expect(projectAgentsDir).toBe(join(repo, ".claude", "agents"));
		});
	});
});
