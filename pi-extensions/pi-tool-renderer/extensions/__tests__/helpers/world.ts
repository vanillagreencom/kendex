import { afterEach, beforeEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { recordProjectTrust } from "../../tool-renderer/settings.js";

/** Give each case owned project and user settings directories. */
export function useWorld() {
	let current: { cwd: string; root: string; agent: string } | undefined;
	let previousAgent: string | undefined;
	beforeEach(() => {
		const root = mkdtempSync(join(tmpdir(), "pi-tool-renderer-test-"));
		const cwd = join(root, "project");
		const agent = join(root, "agent");
		mkdirSync(join(cwd, ".pi"), { recursive: true });
		mkdirSync(agent);
		current = { root, cwd, agent };
		previousAgent = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = agent;
		recordProjectTrust({ cwd, isProjectTrusted: () => true });
	});
	afterEach(() => {
		if (previousAgent === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousAgent;
		if (current) rmSync(current.root, { recursive: true, force: true });
		current = undefined;
	});
	return () => {
		if (!current) throw new Error("No active renderer test world");
		return current;
	};
}
