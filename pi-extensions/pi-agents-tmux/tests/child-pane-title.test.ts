import { afterEach, describe, expect, test } from "bun:test";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	setTmuxPaneTitleSpawnForTests,
} from "../extensions/subagent/pane.js";

interface Harness {
	cwd: string;
	piUserDir: string;
	titles: string[];
	titleSpawnCalls: Array<{ command: string; args: string[] }>;
	previousEnv: {
		childAgent?: string;
		childPane?: string;
		tmuxPane?: string;
		piDir?: string;
	};
}

function createHarness(env: { childAgent?: string; childPane?: string; tmuxPane?: string }): Harness {
	const cwd = mkdtempSync(join(tmpdir(), "pi-agents-child-title-"));
	const piUserDir = join(cwd, ".pi-agent-home");
	mkdirSync(piUserDir, { recursive: true });
	const previousEnv = {
		childAgent: process.env.PI_SUBAGENT_CHILD_AGENT,
		childPane: process.env.PI_SUBAGENT_CHILD_PANE,
		tmuxPane: process.env.TMUX_PANE,
		piDir: process.env.PI_CODING_AGENT_DIR,
	};
	if (env.childAgent === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
	else process.env.PI_SUBAGENT_CHILD_AGENT = env.childAgent;
	if (env.childPane === undefined) delete process.env.PI_SUBAGENT_CHILD_PANE;
	else process.env.PI_SUBAGENT_CHILD_PANE = env.childPane;
	if (env.tmuxPane === undefined) delete process.env.TMUX_PANE;
	else process.env.TMUX_PANE = env.tmuxPane;
	process.env.PI_CODING_AGENT_DIR = piUserDir;
	const titleSpawnCalls: Array<{ command: string; args: string[] }> = [];
	setTmuxPaneTitleSpawnForTests(((command: string, args?: readonly string[]) => {
		titleSpawnCalls.push({ command, args: [...(args ?? [])] });
		const proc = new EventEmitter() as any;
		proc.unref = () => undefined;
		return proc;
	}) as any);
	return { cwd, piUserDir, titles: [], titleSpawnCalls, previousEnv };
}

function teardown(harness: Harness): void {
	setTmuxPaneTitleSpawnForTests();
	if (harness.previousEnv.childAgent === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
	else process.env.PI_SUBAGENT_CHILD_AGENT = harness.previousEnv.childAgent;
	if (harness.previousEnv.childPane === undefined) delete process.env.PI_SUBAGENT_CHILD_PANE;
	else process.env.PI_SUBAGENT_CHILD_PANE = harness.previousEnv.childPane;
	if (harness.previousEnv.tmuxPane === undefined) delete process.env.TMUX_PANE;
	else process.env.TMUX_PANE = harness.previousEnv.tmuxPane;
	if (harness.previousEnv.piDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = harness.previousEnv.piDir;
	rmSync(harness.cwd, { force: true, recursive: true });
}

async function installExtension(harness: Harness): Promise<(event: unknown, ctx: any) => Promise<void>> {
	const handlers = new Map<string, Array<(event: unknown, ctx: any) => Promise<void>>>();
	const bus = new EventEmitter();
	const pi = {
		appendEntry: () => undefined,
		events: { emit: bus.emit.bind(bus), on: bus.on.bind(bus) },
		getActiveTools: () => [],
		getThinkingLevel: () => undefined,
		on: (event: string, handler: (event: unknown, ctx: any) => Promise<void>) => {
			handlers.set(event, [...(handlers.get(event) ?? []), handler]);
		},
		registerCommand: () => undefined,
		registerMessageRenderer: () => undefined,
		registerShortcut: () => undefined,
		registerTool: () => undefined,
		sendMessage: () => undefined,
		sendUserMessage: async () => undefined,
	} as any;
	const url = new URL("../extensions/subagent/index.ts", import.meta.url);
	url.searchParams.set("t", `${Date.now()}-${Math.random().toString(36).slice(2)}`);
	const mod = await import(url.href);
	mod.default(pi);
	const handler = handlers.get("session_start")?.[0];
	expect(handler).toBeTruthy();
	return handler!;
}

function fakeCtx(harness: Harness): any {
	return {
		cwd: harness.cwd,
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
			setTitle: (title: string) => { harness.titles.push(title); },
			setWidget: () => undefined,
		},
	};
}

async function withoutRealIntervals(fn: () => Promise<void>): Promise<void> {
	const realSetInterval = globalThis.setInterval;
	(globalThis as any).setInterval = (() => ({ unref: () => undefined })) as any;
	try {
		await fn();
	} finally {
		globalThis.setInterval = realSetInterval;
	}
}

let currentHarness: Harness | undefined;

afterEach(() => {
	if (currentHarness) {
		teardown(currentHarness);
		currentHarness = undefined;
	}
});

describe("child pane title ownership", () => {
	test("bg one-shot child identity with inherited TMUX_PANE does not set the tmux pane title", async () => {
		currentHarness = createHarness({ childAgent: "reviewer-security", tmuxPane: "%parent" });
		const onSessionStart = await installExtension(currentHarness);
		await withoutRealIntervals(async () => {
			await onSessionStart({}, fakeCtx(currentHarness!));
		});
		expect(currentHarness.titleSpawnCalls).toHaveLength(0);
		expect(currentHarness.titles).toHaveLength(0);
	});

	test("visible pane child marker sets the tmux pane title", async () => {
		currentHarness = createHarness({ childAgent: "rust", childPane: "1", tmuxPane: "%42" });
		const onSessionStart = await installExtension(currentHarness);
		await withoutRealIntervals(async () => {
			await onSessionStart({}, fakeCtx(currentHarness!));
		});
		expect(currentHarness.titles).toContain("pi agent - rust");
		expect(currentHarness.titleSpawnCalls).toContainEqual({
			command: "tmux",
			args: ["select-pane", "-t", "%42", "-T", "agent:rust"],
		});
	});
});
