// delegate_subagent, the restricted delegation tool, as one table over the
// caller's identity, the agents on disk and the call: each row is read back
// as the guard that refused it, or the child it spawned and the environment
// that child was handed.

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { removeSettled } from "./remove-settled.js";

type Execute = (toolCallId: string, params: Record<string, unknown>, signal: undefined, onUpdate: undefined, ctx: unknown) => Promise<{ content: Array<{ text?: string }>; isError?: boolean }>;
type Spawn = { env: NodeJS.ProcessEnv | undefined };
type Agents = Record<string, string[]>;

// Every pane-only marker the parent may carry is set to a sentinel so the
// success row can read that the child was handed none of them.
const PARENT_ENV = { PI_BRIDGE_CHILD_ROLE: "bridge-role", PI_BRIDGE_PARENT_SESSION_ID: "bridge-parent", PI_SUBAGENT_PARENT_SESSION_ID: "parent-session" };
const ENV_KEYS = ["PI_SUBAGENT_CHILD_AGENT", "PI_CODING_AGENT_DIR", ...Object.keys(PARENT_ENV)] as const;

const tempDirs: string[] = [];

// The task-registry writes behind a dispatch are fire-and-forget and can
// recreate a row's cwd after its removal; sweep once more when the file is
// done so nothing is left in tmpdir.
after(async () => {
	for (const dir of tempDirs) await removeSettled(dir);
});

function writeAgents(cwd: string, agents: Agents): void {
	for (const [name, frontmatter] of Object.entries(agents)) {
		const lines = ["---", `name: ${name}`, `description: ${name} test agent`, ...frontmatter, "---", ""];
		writeFileSync(join(cwd, ".pi", "agents", `${name}.md`), `${lines.join("\n")}\n`, "utf8");
	}
}

function fakeCtx(cwd: string): unknown {
	return {
		cwd,
		hasUI: false,
		isIdle: () => true,
		model: undefined,
		sessionManager: { getBranch: () => [], getSessionFile: () => undefined, getSessionId: () => "test-session-id" },
		ui: { confirm: async () => true, setStatus: () => undefined, setTitle: () => undefined, setWidget: () => undefined },
	};
}

// The extension reads PI_SUBAGENT_CHILD_AGENT once at module load, so each
// row imports it afresh under its own environment (bun keys its import cache
// by URL; the query parameter forces a new evaluation).
async function installTool(): Promise<Execute | undefined> {
	const url = new URL("../extensions/subagent/index.ts", import.meta.url);
	url.searchParams.set("t", `${Date.now()}${Math.random().toString(36).slice(2)}`);
	const extension = (await import(url.href)).default;
	const bus = new EventEmitter();
	let execute: Execute | undefined;
	extension({
		appendEntry: () => undefined,
		events: { emit: bus.emit.bind(bus), on: bus.on.bind(bus) },
		getActiveTools: () => ["delegate_subagent"],
		getThinkingLevel: () => undefined,
		on: () => undefined,
		registerCommand: () => undefined,
		registerMessageRenderer: () => undefined,
		registerShortcut: () => undefined,
		registerTool: (def: { name?: string; execute?: Execute }) => {
			if (def.name === "delegate_subagent" && typeof def.execute === "function") execute = def.execute;
		},
		sendMessage: () => undefined,
		sendUserMessage: async () => undefined,
	});
	return execute;
}

// A child that announces itself, reports once and exits clean.
function fakeSpawns(): Spawn[] {
	const spawns: Spawn[] = [];
	setSingleAgentSpawnForTests(((_command: string, _args: string[], options?: { env?: NodeJS.ProcessEnv }) => {
		spawns.push({ env: options?.env });
		const proc = Object.assign(new EventEmitter(), { killed: false, stderr: new EventEmitter(), stdout: new EventEmitter() });
		proc.kill = () => ((proc.killed = true), true);
		queueMicrotask(() => {
			const events = [
				JSON.stringify({ type: "event", event: "agent_start", data: {} }),
				JSON.stringify({ type: "event", event: "message_end", data: { message: { role: "assistant", content: [{ type: "text", text: "scout report" }], usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2 } } } }),
			];
			proc.stdout.emit("data", Buffer.from(`${events.join("\n")}\n`));
			proc.emit("close", 0, null);
		});
		return proc;
	}) as never);
	return spawns;
}

// The queued/running/completed registry updates behind a dispatch are
// fire-and-forget; wait for the terminal one so the row's cwd is settled.
async function settleRegistry(cwd: string): Promise<void> {
	const deadline = Date.now() + 2000;
	while (Date.now() < deadline) {
		const registry = readdirSync(cwd, { recursive: true }).map(String).find((entry) => entry.endsWith("tasks.json"));
		if (registry && readFileSync(join(cwd, registry), "utf8").includes('"completed"')) return;
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
	throw new Error("task registry never recorded a completed dispatch");
}

// A refusal by the guard that wrote it, any other text printed whole; a
// dispatch by the identity and markers the child was handed and the report
// it returned.
const REFUSALS: Array<[string, string]> = [
	["PI_SUBAGENT_CHILD_AGENT must be set", "no-caller"],
	["is not in the discovered project inventory", "caller-unknown"],
	["has no allowed-subagents configured", "no-allowlist"],
	["'agent' parameter is required", "no-agent"],
	["allowed-subagents list. Allowed:", "not-allowed"],
	["is not discovered in project agents", "target-unknown"],
	["is a persistent pane agent", "pane-target"],
	["'task' parameter is required", "no-task"],
];
function resultLine(result: Awaited<ReturnType<Execute>>, spawns: Spawn[]): string {
	const text = result.content[0]?.text ?? "";
	if (result.isError) {
		const guard = REFUSALS.find(([needle]) => text.includes(needle))?.[1] ?? JSON.stringify(text);
		return `refused:${guard} spawns=${spawns.length}`;
	}
	const env = spawns[0]?.env ?? {};
	const markers = Object.keys(PARENT_ENV).filter((key) => key in env);
	return `spawned:${env.PI_SUBAGENT_CHILD_AGENT} markers=[${markers.join(",")}] spawns=${spawns.length} text=${JSON.stringify(text)}`;
}

async function delegateLine(caller: string | undefined, agents: Agents, params: Record<string, unknown>): Promise<string> {
	const cwd = mkdtempSync(join(tmpdir(), "delegate-subagent-runtime-"));
	tempDirs.push(cwd);
	mkdirSync(join(cwd, ".pi", "agents"), { recursive: true });
	mkdirSync(join(cwd, ".pi-agent-home"), { recursive: true });
	writeAgents(cwd, agents);
	const saved = Object.fromEntries(ENV_KEYS.map((key) => [key, process.env[key]]));
	Object.assign(process.env, PARENT_ENV, { PI_CODING_AGENT_DIR: join(cwd, ".pi-agent-home") });
	if (caller === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
	else process.env.PI_SUBAGENT_CHILD_AGENT = caller;
	try {
		const execute = await installTool();
		if (!execute) return "unregistered";
		const spawns = fakeSpawns();
		const result = await execute("call-1", params, undefined, undefined, fakeCtx(cwd));
		if (!result.isError) await settleRegistry(cwd);
		return resultLine(result, spawns);
	} catch (error) {
		return `threw:${(error as Error).constructor.name}`;
	} finally {
		setSingleAgentSpawnForTests();
		for (const key of ENV_KEYS) {
			if (saved[key] === undefined) delete process.env[key];
			else process.env[key] = saved[key];
		}
		await removeSettled(cwd);
	}
}

const RUST_TO_SCOUT: Agents = { rust: ["allowed-subagents: scout"], scout: [] };

// label | PI_SUBAGENT_CHILD_AGENT | agents on disk | params | expect
const rows: Array<[string, string | undefined, Agents, Record<string, unknown>, string]> = [
	["a root session has no caller identity", undefined, RUST_TO_SCOUT, { agent: "scout", task: "Map." }, "refused:no-caller spawns=0"],
	["a blank caller identity is none", "  ", RUST_TO_SCOUT, { agent: "scout", task: "Map." }, "refused:no-caller spawns=0"],
	["a caller not on disk cannot authorize", "ghost-caller", { scout: [] }, { agent: "scout", task: "Recon." }, "refused:caller-unknown spawns=0"],
	["a caller without an allowlist", "scout", { researcher: [], scout: [] }, { agent: "researcher", task: "Recurse." }, "refused:no-allowlist spawns=0"],
	["a blank agent parameter", "rust", RUST_TO_SCOUT, { agent: "  ", task: "Real task." }, "refused:no-agent spawns=0"],
	["a target outside the allowlist", "rust", { ...RUST_TO_SCOUT, researcher: [] }, { agent: "researcher", task: "Do research." }, "refused:not-allowed spawns=0"],
	["a target that only extends an allowlisted name", "rust", { ...RUST_TO_SCOUT, "scout-2": [] }, { agent: "scout-2", task: "Do research." }, "refused:not-allowed spawns=0"],
	["an allowlisted target not on disk", "rust", { rust: ["allowed-subagents: ghost"] }, { agent: "ghost", task: "Ghostly task." }, "refused:target-unknown spawns=0"],
	["an allowlisted pane target", "rust", { planner: ["pane: true"], rust: ["allowed-subagents: planner"] }, { agent: "planner", task: "Plan a thing." }, "refused:pane-target spawns=0"],
	["a blank task", "rust", RUST_TO_SCOUT, { agent: "scout", task: "  " }, "refused:no-task spawns=0"],
	["an allowlisted bg target is spawned as the child with the pane markers stripped", "rust", RUST_TO_SCOUT, { agent: "scout", task: "Map the unknown area." }, 'spawned:scout markers=[] spawns=1 text="scout report"'],
];

test("delegate_subagent refuses by guard or spawns the child", async () => {
	for (const [label, caller, agents, params, expect] of rows) assert.equal(await delegateLine(caller, agents, params), expect, label);
});
