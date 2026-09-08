import { afterEach, beforeEach } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadedSkillHashesBySession } from "../../extensions/session-bridge.ts";

export let dir = "";

let oldAgentDir: string | undefined;
let oldBridgeDir: string | undefined;
let oldCwd = "";
export function p(name: string): string { return join(dir, name); }

export function useSlashFixture(): void {
beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "pi-session-bridge-slash-"));
	
	oldBridgeDir = process.env.PI_BRIDGE_DIR;
	oldAgentDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
	oldCwd = process.cwd();
});

afterEach(() => {
	
	if (oldBridgeDir === undefined) delete process.env.PI_BRIDGE_DIR;
	else process.env.PI_BRIDGE_DIR = oldBridgeDir;
	if (oldAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = oldAgentDir;
	process.chdir(oldCwd);
	loadedSkillHashesBySession.clear();
	if (dir) rmSync(dir, { recursive: true, force: true });
});

}
