import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { resolveSubagentStatuslineInfo } from "../extensions/subagent/format.js";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";

const rootTmp = join(import.meta.dir, "..", "..", "..", "tmp", "pi-agents-statusline-tests");
const originalEnv = {
	HOME: process.env.HOME,
	PI_CODING_AGENT_DIR: process.env.PI_CODING_AGENT_DIR,
	PI_SUBAGENT_CHILD_COLOR: process.env.PI_SUBAGENT_CHILD_COLOR,
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
	if (originalEnv.PI_SUBAGENT_CHILD_COLOR === undefined) delete process.env.PI_SUBAGENT_CHILD_COLOR;
	else process.env.PI_SUBAGENT_CHILD_COLOR = originalEnv.PI_SUBAGENT_CHILD_COLOR;
	clearPackageConfigCache();
}

function writeAgent(dir: string, name: string, description: string, frontmatterLines: string[] = []): string {
	mkdirSync(dir, { recursive: true });
	const filePath = join(dir, name + ".md");
	const lines = ["---", "name: " + name, "description: " + description, ...frontmatterLines, "---", ""];
	writeFileSync(filePath, lines.join("\n") + "\n", "utf8");
	return filePath;
}

beforeEach(() => {
	resetTmp();
	const home = join(rootTmp, "home");
	mkdirSync(home, { recursive: true });
	process.env.HOME = home;
	process.env.PI_CODING_AGENT_DIR = join(home, ".pi", "agent");
	clearPackageConfigCache();
	delete process.env.PI_SUBAGENT_CHILD_COLOR;
});

afterEach(() => {
	restoreEnv();
	rmSync(rootTmp, { force: true, recursive: true });
});

test("statusline uses exported child color before discovered agent color", () => {
	const home = process.env.HOME!;
	const cwd = join(home, "work", "env-color-app", "src");
	const projectRoot = join(home, "work", "env-color-app");
	mkdirSync(cwd, { recursive: true });
	writeAgent(join(projectRoot, ".pi", "agents"), "child", "child agent", ["color: red"]);
	process.env.PI_SUBAGENT_CHILD_COLOR = "teal";

	expect(resolveSubagentStatuslineInfo("child", cwd)).toEqual({ name: "child", color: "cyan" });
});

test("statusline memoizes fallback discovery briefly", () => {
	const home = process.env.HOME!;
	const cwd = join(home, "work", "cache-app", "src");
	const projectRoot = join(home, "work", "cache-app");
	const projectAgentsDir = join(projectRoot, ".pi", "agents");
	mkdirSync(cwd, { recursive: true });
	writeAgent(projectAgentsDir, "target", "target agent");

	expect(resolveSubagentStatuslineInfo("target", cwd)).toEqual({ name: "target", color: "magenta" });
	writeAgent(projectAgentsDir, "aaa", "new leading agent");
	expect(resolveSubagentStatuslineInfo("target", cwd)).toEqual({ name: "target", color: "magenta" });
	expect(resolveSubagentStatuslineInfo("target", projectRoot)).toEqual({ name: "target", color: "green" });
});
