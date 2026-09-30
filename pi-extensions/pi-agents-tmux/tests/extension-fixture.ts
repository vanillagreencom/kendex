// The extension entry point loaded fresh against a fake Pi, in a private Pi
// user directory, for suites that drive its session_start handler.
import { expect } from "bun:test";
import assert from "node:assert/strict";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";
import {
	setTmuxPaneTitleSpawnForTests,
} from "../extensions/subagent/pane.js";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import { sessionRuntimeDir } from "../extensions/subagent/settings.js";
import { taskRegistryReader } from "../extensions/subagent/task-records.js";
import { writeTaskRegistry } from "../extensions/subagent/tasks.js";
import { taskRegistryReads, writeSettings } from "./browser-fixture.js";

type ExtensionFactory = (pi: ExtensionAPI) => void;
type SessionHandler = (event: unknown, ctx: ExtensionContext) => void | Promise<void>;

export interface Harness {
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

export function createHarness(env: { childAgent?: string; childPane?: string; tmuxPane?: string }): Harness {
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
	clearPackageConfigCache();
	const titleSpawnCalls: Array<{ command: string; args: string[] }> = [];
	setTmuxPaneTitleSpawnForTests(((command: string, args?: readonly string[]) => {
		titleSpawnCalls.push({ command, args: [...(args ?? [])] });
		const proc = new EventEmitter() as any;
		proc.unref = () => undefined;
		return proc;
	}) as any);
	return { cwd, piUserDir, titles: [], titleSpawnCalls, previousEnv };
}

export function teardown(harness: Harness): void {
	setTmuxPaneTitleSpawnForTests();
	if (harness.previousEnv.childAgent === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
	else process.env.PI_SUBAGENT_CHILD_AGENT = harness.previousEnv.childAgent;
	if (harness.previousEnv.childPane === undefined) delete process.env.PI_SUBAGENT_CHILD_PANE;
	else process.env.PI_SUBAGENT_CHILD_PANE = harness.previousEnv.childPane;
	if (harness.previousEnv.tmuxPane === undefined) delete process.env.TMUX_PANE;
	else process.env.TMUX_PANE = harness.previousEnv.tmuxPane;
	if (harness.previousEnv.piDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = harness.previousEnv.piDir;
	clearPackageConfigCache();
	rmSync(harness.cwd, { force: true, recursive: true });
}

export async function installExtension(harness: Harness, options: {
	extension?: ExtensionFactory;
	handlers?: Map<string, SessionHandler[]>;
	appendEntry?: (customType: string, data: unknown) => void;
} = {}): Promise<(event: unknown, ctx: ExtensionContext) => Promise<void>> {
	const handlers = options.handlers ?? new Map<string, SessionHandler[]>();
	const bus = new EventEmitter();
	const pi = {
		appendEntry: options.appendEntry ?? (() => undefined),
		events: { emit: bus.emit.bind(bus), on: (channel: string, handler: (data: unknown) => void) => { bus.on(channel, handler); return () => bus.off(channel, handler); } },
		getActiveTools: () => [],
		getThinkingLevel: () => undefined,
		on: (event: string, handler: SessionHandler) => {
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
	const extension = options.extension ?? (await import(url.href)).default;
	extension(pi);
	const registered = handlers.get("session_start") ?? [];
	expect(registered.length).toBeGreaterThan(0);
	return async (event, ctx) => {
		for (const handler of registered) await handler(event, ctx);
	};
}

export function fakeCtx(harness: Harness): any {
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

/** Run `fn` with setInterval stubbed out; each interval it starts is pushed
 *  onto `started`, so a case can run a tick itself. */
export async function withoutRealIntervals(fn: () => Promise<void>, started: Array<{ callback: () => void; ms: number }> = []): Promise<void> {
	const realSetInterval = globalThis.setInterval;
	(globalThis as any).setInterval = ((callback: () => void, ms: number) => {
		started.push({ callback, ms });
		return { unref: () => undefined };
	}) as any;
	try {
		await fn();
	} finally {
		globalThis.setInterval = realSetInterval;
	}
}

/** Startup warms the shared snapshot; its real parent poll reuses it and shutdown releases it. */
export async function assertSharedRegistryLifecycle(extension: ExtensionFactory): Promise<void> {
	const harness = createHarness({});
	const handlers = new Map<string, SessionHandler[]>();
	const entries: Array<{ customType: string; data: unknown }> = [];
	const stackSymbol = Symbol.for("kendex.pi.mini-dashboard-stack");
	const globals = globalThis as unknown as Record<PropertyKey, unknown>;
	const previousStack = globals[stackSymbol];
	delete globals[stackSymbol];
	const ctx = { ...fakeCtx(harness), hasUI: true } as ExtensionContext;
	const shutdown = async () => {
		for (const handler of handlers.get("session_shutdown") ?? []) await handler({ reason: "quit" }, ctx);
	};
	try {
		writeSettings(harness.cwd, { dashboard: true });
		const root = sessionRuntimeDir("test-session-id");
		mkdirSync(join(root, "outbox"), { recursive: true });
		// A completed bg child from writeTaskRegistry needs neither tmux nor transcript backfill.
		const records = { child: { taskId: "child", agent: "engineer", task: "work", kind: "oneshot" as const, status: "completed" as const, createdAt: "2026-09-30T00:00:00Z", summary: "done" } };
		await writeTaskRegistry(root, records);
		// Startup must warm the reader independently of the fixture writer's cache publication.
		taskRegistryReader.clear();
		const unchanged = readFileSync(taskRegistryPath(root), "utf8");
		await withoutRealIntervals(async () => {
			const start = await installExtension(harness, {
				extension, handlers,
				appendEntry: (customType, data) => { entries.push({ customType, data }); },
			});
			assert.ok((handlers.get("session_shutdown")?.length ?? 0) > 0);
			assert.equal(await taskRegistryReads(root, () => start({}, ctx)), 1);
			assert.equal(await taskRegistryReads(root, async () => {
				assert.deepEqual(taskRegistryReader.read(root), records);
			}), 0, "startup must warm the shared reader, not a private reader");
			// session_start starts a real asynchronous parent poll. Shutdown drains it before clearing
			// the reader, so the count covers its completion, dashboard sync and snapshot persistence.
			assert.equal(await taskRegistryReads(root, shutdown), 0, "the warmed parent poll must read no registry content");
			assert.deepEqual(entries.filter(({ customType }) => customType === "kendex-subagents:runtime-state").map(({ data }) => (data as { tasks: unknown }).tasks), [records], "the parent poll must persist its registry snapshot");
			assert.equal(readFileSync(taskRegistryPath(root), "utf8"), unchanged);
			assert.equal(await taskRegistryReads(root, async () => {
				assert.deepEqual(taskRegistryReader.read(root), records);
			}), 1, "shutdown must release the unchanged shared snapshot");
		});
	} finally {
		await shutdown();
		taskRegistryReader.clear();
		if (previousStack === undefined) delete globals[stackSymbol];
		else globals[stackSymbol] = previousStack;
		teardown(harness);
	}
}
