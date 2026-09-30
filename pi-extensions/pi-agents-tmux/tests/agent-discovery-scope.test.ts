import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { discoverAgents } from "../extensions/subagent/agents.js";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";

const rootTmp = join(import.meta.dir, "..", "..", "..", "tmp", "pi-agents-discovery-scope-tests");
const originalEnv = {
	HOME: process.env.HOME,
	PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR,
};

function resetTmp(): void {
	rmSync(rootTmp, { force: true, recursive: true });
	mkdirSync(rootTmp, { recursive: true });
}

function restoreEnv(): void {
	if (originalEnv.HOME === undefined) delete process.env.HOME;
	else process.env.HOME = originalEnv.HOME;
	if (originalEnv.PI_CODING_AGENT_DIR === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = originalEnv.PI_CODING_AGENT_DIR;
	clearPackageConfigCache();
}

function writeAgent(dir: string, name: string, description: string): string {
	mkdirSync(dir, { recursive: true });
	const filePath = join(dir, name + ".md");
	writeFileSync(filePath, "---\nname: " + name + "\ndescription: " + description + "\n---\n\n", "utf8");
	return filePath;
}

beforeEach(() => {
	resetTmp();
	const home = join(rootTmp, "home");
	mkdirSync(home, { recursive: true });
	process.env.HOME = home;
	process.env.PI_CODING_AGENT_DIR = join(home, ".pi", "agent");
	clearPackageConfigCache();
});

afterEach(() => {
	restoreEnv();
	rmSync(rootTmp, { force: true, recursive: true });
});

test("classifies HOME Claude agents as user agents, not project agents", () => {
	const home = process.env.HOME!;
	const cwd = join(home, "scratch", "repo");
	mkdirSync(cwd, { recursive: true });
	writeAgent(join(home, ".claude", "agents"), "shared", "home Claude compatibility");
	writeAgent(join(home, ".claude", "agents"), "claude-only", "home Claude only");
	const piShared = writeAgent(join(home, ".pi", "agent", "agents"), "shared", "Pi user override");
	writeAgent(join(home, ".pi", "agents"), "legacy-home-pi", "home .pi agents are not project");

	const project = discoverAgents(cwd, "project");
	expect(project.agents).toEqual([]);
	expect(project.projectAgentsDir).toBeNull();

	const user = discoverAgents(cwd, "user").agents;
	expect(user.map((agent) => agent.name)).toEqual(["claude-only", "shared"]);
	expect(user.find((agent) => agent.name === "shared")).toMatchObject({
		description: "Pi user override",
		filePath: piShared,
		source: "user",
	});

	expect(discoverAgents(cwd, "both").agents.map((agent) => agent.name)).toEqual(["claude-only", "shared"]);
});

test("discovers real project agents below HOME", () => {
	const home = process.env.HOME!;
	const cwd = join(home, "work", "app", "src");
	const projectRoot = join(home, "work", "app");
	mkdirSync(cwd, { recursive: true });
	writeAgent(join(home, ".claude", "agents"), "shared", "home Claude compatibility");
	writeAgent(join(home, ".pi", "agent", "agents"), "shared", "Pi user override");
	writeAgent(join(projectRoot, ".claude", "agents"), "project-claude-only", "project Claude only");
	writeAgent(join(projectRoot, ".claude", "agents"), "shared", "project Claude compatibility");
	const projectPiShared = writeAgent(join(projectRoot, ".pi", "agents"), "shared", "project Pi override");

	const project = discoverAgents(cwd, "project");
	expect(project.projectAgentsDir).toBe(join(projectRoot, ".claude", "agents") + ", " + join(projectRoot, ".pi", "agents"));
	expect(project.agents.map((agent) => agent.name)).toEqual(["project-claude-only", "shared"]);
	expect(project.agents.find((agent) => agent.name === "shared")).toMatchObject({
		description: "project Pi override",
		filePath: projectPiShared,
		source: "project",
	});

	const bothShared = discoverAgents(cwd, "both").agents.find((agent) => agent.name === "shared");
	expect(bothShared).toMatchObject({ description: "project Pi override", source: "project" });
});

test("skips project agent directories symlinked to user sources", () => {
	const home = process.env.HOME!;
	const cwd = join(home, "work", "dir-symlink-app", "src");
	const projectRoot = join(home, "work", "dir-symlink-app");
	mkdirSync(cwd, { recursive: true });
	const homeClaudeDir = join(home, ".claude", "agents");
	const piUserDir = join(home, ".pi", "agent", "agents");
	writeAgent(homeClaudeDir, "home-claude", "home Claude");
	writeAgent(piUserDir, "pi-user", "Pi user");
	mkdirSync(join(projectRoot, ".claude"), { recursive: true });
	mkdirSync(join(projectRoot, ".pi"), { recursive: true });
	symlinkSync(homeClaudeDir, join(projectRoot, ".claude", "agents"), "dir");
	symlinkSync(piUserDir, join(projectRoot, ".pi", "agents"), "dir");

	const project = discoverAgents(cwd, "project");
	expect(project.agents).toEqual([]);
	expect(project.projectAgentsDir).toBeNull();
	expect(discoverAgents(cwd, "user").agents.map((agent) => agent.name)).toEqual(["home-claude", "pi-user"]);
});

test("skips project agent files symlinked to user sources", () => {
	const home = process.env.HOME!;
	const cwd = join(home, "work", "file-symlink-app", "src");
	const projectRoot = join(home, "work", "file-symlink-app");
	mkdirSync(cwd, { recursive: true });
	const homeClaudeFile = writeAgent(join(home, ".claude", "agents"), "linked-claude", "home Claude");
	const piUserFile = writeAgent(join(home, ".pi", "agent", "agents"), "linked-pi", "Pi user");
	const projectClaudeDir = join(projectRoot, ".claude", "agents");
	const projectPiDir = join(projectRoot, ".pi", "agents");
	mkdirSync(projectClaudeDir, { recursive: true });
	mkdirSync(projectPiDir, { recursive: true });
	symlinkSync(homeClaudeFile, join(projectClaudeDir, "linked-claude.md"), "file");
	symlinkSync(piUserFile, join(projectPiDir, "linked-pi.md"), "file");
	writeAgent(projectClaudeDir, "real-claude", "real project Claude");
	writeAgent(projectPiDir, "real-pi", "real project Pi");

	const project = discoverAgents(cwd, "project");
	expect(project.agents.map((agent) => agent.name)).toEqual(["real-claude", "real-pi"]);
	expect(project.agents.every((agent) => agent.source === "project")).toBe(true);
	expect(project.projectAgentsDir).toBe(projectClaudeDir + ", " + projectPiDir);
});
