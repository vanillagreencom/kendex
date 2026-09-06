// What the one-shot runner hands its child: the identity environment (the
// agent, its colour, the pane and bridge markers stripped from an inherited
// pane environment) and the tool flags built from the parent's active tools.
// Each row reads back one line: every PI_SUBAGENT_* and PI_BRIDGE* key the
// child receives, each planted parent key that did not survive, and the
// argument list, with the session file under the runtime root aliased.

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import { runSingleAgent, setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import type { SingleResult, SubagentDetails } from "../extensions/subagent/types.js";

const IDENTITY_KEY = /^PI_(SUBAGENT|BRIDGE)/;

interface Launch {
	color?: string;
	denyTools?: string[];
	activeTools?: string[];
	parent?: Record<string, string>;
}

function agent(opts: Launch): AgentConfig {
	return { color: opts.color, denyTools: opts.denyTools, description: "scout test agent", filePath: "scout.md", name: "scout", pane: false, source: "project", systemPrompt: "" };
}

function makeDetails(results: SingleResult[]): SubagentDetails {
	return { agentScope: "project", mode: "single", projectAgentsDir: null, results };
}

// Runs the agent under a parent environment holding only the planted keys of
// the identity family, and reads back the child's spawn.
async function launchLine(opts: Launch): Promise<string> {
	const runtime = mkdtempSync(join(tmpdir(), "pi-agents-runner-env-"));
	const saved = Object.entries(process.env).filter(([key]) => IDENTITY_KEY.test(key) || key in (opts.parent ?? {}));
	for (const [key] of saved) delete process.env[key];
	Object.assign(process.env, opts.parent ?? {});
	const spawns: Array<{ args: string[]; env: NodeJS.ProcessEnv }> = [];
	setSingleAgentSpawnForTests(((command: string, args: string[], options: { env: NodeJS.ProcessEnv }) => {
		void command;
		spawns.push({ args, env: options.env });
		const proc = Object.assign(new EventEmitter(), { kill: () => true, killed: false, stderr: new EventEmitter(), stdout: new EventEmitter() });
		queueMicrotask(() => proc.emit("close", 0, null));
		return proc;
	}) as unknown as Parameters<typeof setSingleAgentSpawnForTests>[0]);
	try {
		const pi = { events: { emit: () => undefined }, getActiveTools: () => opts.activeTools ?? [] } as unknown as Parameters<typeof runSingleAgent>[9];
		await runSingleAgent(runtime, runtime, [agent(opts)], "scout", "recon", undefined, undefined, undefined, undefined, pi, undefined, undefined, makeDetails);
	} finally {
		setSingleAgentSpawnForTests();
		for (const key of Object.keys(opts.parent ?? {})) delete process.env[key];
		for (const key of Object.keys(process.env)) if (IDENTITY_KEY.test(key)) delete process.env[key];
		Object.assign(process.env, Object.fromEntries(saved));
		rmSync(runtime, { force: true, recursive: true });
	}
	if (spawns.length !== 1) return `spawns=${spawns.length}`;
	const { args, env } = spawns[0];
	const keys = [...new Set([...Object.keys(env).filter((key) => IDENTITY_KEY.test(key)), ...Object.keys(opts.parent ?? {})])].sort();
	const envLine = keys.map((key) => `${key}=${env[key] ?? "-"}`).join(" ");
	const argsLine = args.map((arg, i) => (args[i - 1] === "--session" ? (arg.startsWith(runtime) ? "<runtime-session>" : arg) : arg)).join(" ");
	return `${envLine} | ${argsLine}`;
}

const STRIPPED = { PI_BRIDGE_CHILD_ROLE: "role", PI_BRIDGE_PARENT_SESSION_ID: "parent", PI_BRIDGE_SOCKET_PATH: "/tmp/sock", PI_SUBAGENT_CHILD_PANE: "1", PI_SUBAGENT_PARENT_SESSION_ID: "session" };
const BASE = "--mode json -p --name scout --session <runtime-session> --exclude-tools complete_subagent";

// label | launch | expect
const rows: Array<[string, Launch, string]> = [
	["a clean parent: the child carries the agent and the depth, no colour", {}, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_DEPTH=1 | ${BASE} Task: recon`],
	["the agent's colour is exported", { color: "cyan" }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_CHILD_COLOR=cyan PI_SUBAGENT_DEPTH=1 | ${BASE} Task: recon`],
	["a parent colour is cleared when the agent has none", { parent: { PI_SUBAGENT_CHILD_COLOR: "magenta" } }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_CHILD_COLOR=- PI_SUBAGENT_DEPTH=1 | ${BASE} Task: recon`],
	["a parent colour is replaced by the agent's", { color: "cyan", parent: { PI_SUBAGENT_CHILD_COLOR: "magenta" } }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_CHILD_COLOR=cyan PI_SUBAGENT_DEPTH=1 | ${BASE} Task: recon`],
	["a parent's child agent is replaced by this one", { parent: { PI_SUBAGENT_CHILD_AGENT: "other" } }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_DEPTH=1 | ${BASE} Task: recon`],
	["pane and bridge markers are stripped, a PI_BRIDGE sibling and an unrelated key kept", { parent: { ...STRIPPED, KENDEX_TEST_KEEP: "kept", PI_BRIDGEX: "kept" } }, `KENDEX_TEST_KEEP=kept PI_BRIDGEX=kept PI_BRIDGE_CHILD_ROLE=- PI_BRIDGE_PARENT_SESSION_ID=- PI_BRIDGE_SOCKET_PATH=- PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_CHILD_PANE=- PI_SUBAGENT_DEPTH=1 PI_SUBAGENT_PARENT_SESSION_ID=- | ${BASE} Task: recon`],
	["the parent's depth is one more in the child", { parent: { PI_SUBAGENT_DEPTH: "2" } }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_DEPTH=3 | ${BASE} Task: recon`],
	["the excluded tool is dropped from the inherited tools", { activeTools: ["read", "complete_subagent", "delegate_subagent"] }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_DEPTH=1 | ${BASE} --tools read,delegate_subagent Task: recon`],
	["the excluded tool is matched by its normalised name", { activeTools: ["read", " Complete-Subagent "] }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_DEPTH=1 | ${BASE} --tools read Task: recon`],
	["only the excluded tool inherited: no tools at all", { activeTools: ["complete_subagent"] }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_DEPTH=1 | ${BASE} --no-tools Task: recon`],
	["a denied tool is dropped, the rest deduplicated and trimmed", { activeTools: ["read", "bash", " read", "bash "], denyTools: ["Bash"] }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_DEPTH=1 | ${BASE} --tools read Task: recon`],
	["every inherited tool denied: no tools at all", { activeTools: ["bash"], denyTools: ["bash"] }, `PI_SUBAGENT_CHILD_AGENT=scout PI_SUBAGENT_DEPTH=1 | ${BASE} --no-tools Task: recon`],
];

test("runSingleAgent child identity", async () => {
	for (const [label, launch, expect] of rows) assert.equal(await launchLine(launch), expect, label);
});
