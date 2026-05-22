import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";

interface RegisteredTool {
	name: string;
	execute: (
		toolCallId: string,
		params: Record<string, any>,
		signal: AbortSignal | undefined,
		onUpdate: undefined,
		ctx: any,
	) => Promise<any>;
}

interface Harness {
	cwd: string;
	piUserDir: string;
	tools: Map<string, RegisteredTool>;
	previousEnv: {
		child?: string;
		dir?: string;
		bridgeParent?: string;
		bridgeRole?: string;
		parentSession?: string;
	};
}

function createTempProject(): { cwd: string; piUserDir: string } {
	const cwd = mkdtempSync(join(tmpdir(), "delegate-subagent-runtime-"));
	mkdirSync(join(cwd, ".pi", "agents"), { recursive: true });
	const piUserDir = join(cwd, ".pi-agent-home");
	mkdirSync(piUserDir, { recursive: true });
	return { cwd, piUserDir };
}

function writeAgent(cwd: string, name: string, frontmatter: string[]): void {
	const lines = ["---", `name: ${name}`, `description: ${name} test agent`, ...frontmatter, "---", ""];
	writeFileSync(join(cwd, ".pi", "agents", `${name}.md`), `${lines.join("\n")}\n`, "utf8");
}

function makeFakeCtx(cwd: string): any {
	return {
		cwd,
		hasUI: false,
		isIdle: () => true,
		model: undefined,
		sessionManager: {
			getSessionFile: () => undefined,
			getSessionId: () => "test-session-id",
			getBranch: () => [],
		},
		ui: {
			confirm: async () => true,
			setStatus: () => undefined,
			setTitle: () => undefined,
			setWidget: () => undefined,
		},
	};
}

function setup(callerEnv: string | undefined): Harness {
	const { cwd, piUserDir } = createTempProject();
	const previousEnv = {
		child: process.env.PI_SUBAGENT_CHILD_AGENT,
		dir: process.env.PI_CODING_AGENT_DIR,
		bridgeParent: process.env.PI_BRIDGE_PARENT_SESSION_ID,
		bridgeRole: process.env.PI_BRIDGE_CHILD_ROLE,
		parentSession: process.env.PI_SUBAGENT_PARENT_SESSION_ID,
	};
	if (callerEnv === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
	else process.env.PI_SUBAGENT_CHILD_AGENT = callerEnv;
	process.env.PI_CODING_AGENT_DIR = piUserDir;
	delete process.env.PI_BRIDGE_PARENT_SESSION_ID;
	delete process.env.PI_BRIDGE_CHILD_ROLE;
	delete process.env.PI_SUBAGENT_PARENT_SESSION_ID;
	return { cwd, piUserDir, tools: new Map(), previousEnv };
}

function teardown(harness: Harness): void {
	const { previousEnv, cwd } = harness;
	setSingleAgentSpawnForTests();
	if (previousEnv.child === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
	else process.env.PI_SUBAGENT_CHILD_AGENT = previousEnv.child;
	if (previousEnv.dir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = previousEnv.dir;
	if (previousEnv.bridgeParent === undefined) delete process.env.PI_BRIDGE_PARENT_SESSION_ID;
	else process.env.PI_BRIDGE_PARENT_SESSION_ID = previousEnv.bridgeParent;
	if (previousEnv.bridgeRole === undefined) delete process.env.PI_BRIDGE_CHILD_ROLE;
	else process.env.PI_BRIDGE_CHILD_ROLE = previousEnv.bridgeRole;
	if (previousEnv.parentSession === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION_ID;
	else process.env.PI_SUBAGENT_PARENT_SESSION_ID = previousEnv.parentSession;
	rmSync(cwd, { force: true, recursive: true });
}

async function installExtension(harness: Harness): Promise<void> {
	// Re-import so module-level `childAgentName` snapshot reflects the
	// per-test PI_SUBAGENT_CHILD_AGENT env we set in setup(). bun's import
	// cache is keyed by URL; a query parameter forces a fresh evaluation.
	const url = new URL("../extensions/subagent/index.ts", import.meta.url);
	url.searchParams.set("t", String(Date.now()) + Math.random().toString(36).slice(2));
	const mod = await import(url.href);
	const subagentExtension = mod.default;
	const bus = new EventEmitter();
	const pi = {
		appendEntry: () => undefined,
		events: { emit: bus.emit.bind(bus), on: bus.on.bind(bus) },
		getActiveTools: () => ["delegate_subagent"],
		getThinkingLevel: () => undefined,
		on: () => undefined,
		registerCommand: () => undefined,
		registerMessageRenderer: () => undefined,
		registerShortcut: () => undefined,
		registerTool: (def: any) => {
			if (def.name && typeof def.execute === "function") {
				harness.tools.set(def.name, { name: def.name, execute: def.execute });
			}
		},
		sendMessage: () => undefined,
		sendUserMessage: async () => undefined,
	} as any;
	subagentExtension(pi);
}

function installSpawnSuccess(): Array<{ args: string[]; env: NodeJS.ProcessEnv | undefined }> {
	const calls: Array<{ args: string[]; env: NodeJS.ProcessEnv | undefined }> = [];
	setSingleAgentSpawnForTests(((command: string, args: string[], options?: { env?: NodeJS.ProcessEnv }) => {
		void command;
		calls.push({ args, env: options?.env });
		const proc = new EventEmitter() as any;
		proc.stdout = new EventEmitter();
		proc.stderr = new EventEmitter();
		proc.killed = false;
		proc.kill = () => {
			proc.killed = true;
			return true;
		};
		queueMicrotask(() => {
			const events = [
				JSON.stringify({ type: "event", event: "agent_start", data: {} }),
				JSON.stringify({
					type: "event",
					event: "message_end",
					data: {
						message: {
							role: "assistant",
							content: [{ type: "text", text: "scout report" }],
							usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2 },
						},
					},
				}),
			];
			proc.stdout.emit("data", Buffer.from(`${events.join("\n")}\n`));
			proc.emit("close", 0, null);
		});
		return proc;
	}) as any);
	return calls;
}

describe("delegate_subagent runtime behavior (issue #228)", () => {
	let harness: Harness | undefined;

	afterEach(() => {
		if (harness) {
			teardown(harness);
			harness = undefined;
		}
	});

	test("registers when imported and is callable via the captured execute fn", async () => {
		harness = setup("rust");
		writeAgent(harness.cwd, "rust", ["allowed-subagents: scout"]);
		writeAgent(harness.cwd, "scout", []);
		await installExtension(harness);
		expect(harness.tools.has("delegate_subagent")).toBe(true);
	});

	test("allowed target spawns the child via single-mode dispatch", async () => {
		harness = setup("rust");
		writeAgent(harness.cwd, "rust", ["allowed-subagents: scout"]);
		writeAgent(harness.cwd, "scout", []);
		await installExtension(harness);
		const calls = installSpawnSuccess();
		const tool = harness.tools.get("delegate_subagent")!;
		const result = await tool.execute(
			"call-1",
			{ agent: "scout", task: "Map the unknown area." },
			undefined,
			undefined,
			makeFakeCtx(harness.cwd),
		);
		expect(result.isError).toBeFalsy();
		expect(calls).toHaveLength(1);
		// Child identity env (issue #228) is set, bridge env is stripped.
		expect(calls[0]?.env?.PI_SUBAGENT_CHILD_AGENT).toBe("scout");
		expect(calls[0]?.env?.PI_BRIDGE_PARENT_SESSION_ID).toBeUndefined();
	});

	test("refuses when caller identity is missing (no PI_SUBAGENT_CHILD_AGENT)", async () => {
		harness = setup(undefined);
		writeAgent(harness.cwd, "rust", ["allowed-subagents: scout"]);
		writeAgent(harness.cwd, "scout", []);
		await installExtension(harness);
		const tool = harness.tools.get("delegate_subagent")!;
		const result = await tool.execute(
			"call-1",
			{ agent: "scout", task: "Map." },
			undefined,
			undefined,
			makeFakeCtx(harness.cwd),
		);
		expect(result.isError).toBe(true);
		expect(result.content[0]?.text).toContain("PI_SUBAGENT_CHILD_AGENT");
	});

	test("refuses when caller has no allowed-subagents configured", async () => {
		harness = setup("scout");
		writeAgent(harness.cwd, "scout", []);
		writeAgent(harness.cwd, "researcher", []);
		await installExtension(harness);
		const tool = harness.tools.get("delegate_subagent")!;
		const result = await tool.execute(
			"call-1",
			{ agent: "researcher", task: "Recurse." },
			undefined,
			undefined,
			makeFakeCtx(harness.cwd),
		);
		expect(result.isError).toBe(true);
		expect(result.content[0]?.text).toMatch(/no allowed-subagents/);
	});

	test("refuses target not in caller's allowlist", async () => {
		harness = setup("rust");
		writeAgent(harness.cwd, "rust", ["allowed-subagents: scout"]);
		writeAgent(harness.cwd, "scout", []);
		writeAgent(harness.cwd, "researcher", []);
		await installExtension(harness);
		const tool = harness.tools.get("delegate_subagent")!;
		const result = await tool.execute(
			"call-1",
			{ agent: "researcher", task: "Do research." },
			undefined,
			undefined,
			makeFakeCtx(harness.cwd),
		);
		expect(result.isError).toBe(true);
		expect(result.content[0]?.text).toMatch(/not in rust's allowed-subagents/);
	});

	test("refuses target that is not in discovered project inventory", async () => {
		harness = setup("rust");
		writeAgent(harness.cwd, "rust", ["allowed-subagents: ghost"]);
		// Note: no ghost agent on disk.
		await installExtension(harness);
		const tool = harness.tools.get("delegate_subagent")!;
		const result = await tool.execute(
			"call-1",
			{ agent: "ghost", task: "Ghostly task." },
			undefined,
			undefined,
			makeFakeCtx(harness.cwd),
		);
		expect(result.isError).toBe(true);
		expect(result.content[0]?.text).toMatch(/not discovered in project agents/);
	});

	test("refuses pane target even when allowlisted", async () => {
		harness = setup("rust");
		writeAgent(harness.cwd, "rust", ["allowed-subagents: planner"]);
		writeAgent(harness.cwd, "planner", ["pane: true"]);
		await installExtension(harness);
		const tool = harness.tools.get("delegate_subagent")!;
		const result = await tool.execute(
			"call-1",
			{ agent: "planner", task: "Plan a thing." },
			undefined,
			undefined,
			makeFakeCtx(harness.cwd),
		);
		expect(result.isError).toBe(true);
		expect(result.content[0]?.text).toMatch(/persistent pane agent/);
	});

	test("refuses when caller agent itself is not in project inventory", async () => {
		// Pane launches set PI_SUBAGENT_CHILD_AGENT to an agent name, but a
		// stale env (or local repo override missing the agent file) must not
		// auto-authorize.
		harness = setup("ghost-caller");
		writeAgent(harness.cwd, "scout", []);
		await installExtension(harness);
		const tool = harness.tools.get("delegate_subagent")!;
		const result = await tool.execute(
			"call-1",
			{ agent: "scout", task: "Recon." },
			undefined,
			undefined,
			makeFakeCtx(harness.cwd),
		);
		expect(result.isError).toBe(true);
		expect(result.content[0]?.text).toMatch(/not in the discovered project inventory/);
	});

	test("refuses empty task / empty agent params", async () => {
		harness = setup("rust");
		writeAgent(harness.cwd, "rust", ["allowed-subagents: scout"]);
		writeAgent(harness.cwd, "scout", []);
		await installExtension(harness);
		const tool = harness.tools.get("delegate_subagent")!;
		const noTask = await tool.execute(
			"call-1",
			{ agent: "scout", task: "  " },
			undefined,
			undefined,
			makeFakeCtx(harness.cwd),
		);
		expect(noTask.isError).toBe(true);
		expect(noTask.content[0]?.text).toMatch(/'task' parameter is required/);

		const noAgent = await tool.execute(
			"call-2",
			{ agent: "  ", task: "Real task." },
			undefined,
			undefined,
			makeFakeCtx(harness.cwd),
		);
		expect(noAgent.isError).toBe(true);
		expect(noAgent.content[0]?.text).toMatch(/'agent' parameter is required/);
	});
});
