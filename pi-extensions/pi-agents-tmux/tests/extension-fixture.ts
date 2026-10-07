// The extension entry point loaded fresh against a fake Pi, in a private Pi
// user directory, for suites that drive its session_start handler.
import { expect, spyOn } from "bun:test";
import assert from "node:assert/strict";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";
import {
	setTmuxPaneTitleSpawnForTests,
} from "../extensions/subagent/pane.js";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import { runtimeDirForContext, sessionRuntimeDir } from "../extensions/subagent/settings.js";
import { taskRegistryReader } from "../extensions/subagent/task-records.js";
import * as tasks from "../extensions/subagent/tasks.js";
import { writeTaskRegistry, writePaneRegistry } from "../extensions/subagent/tasks.js";
import * as sessions from "../extensions/subagent/sessions.js";
import { singleResultStatus } from "../extensions/subagent/outcomes.js";
import { resolveBgSession } from "../extensions/subagent/sessions.js";

import { taskRegistryReads, writeSettings } from "./browser-fixture.js";
import { bridgeEvent, bridgeStdout, installMockSpawn } from "./single-agent-fixture.js";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import * as idleWatchdog from "../extensions/subagent/idle-stall-watchdog.js";
import { toneTheme } from "./browser-fixture.js";

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
		queueMicrotask(() => proc.emit("close", 0));
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
	registerTool?: (tool: any) => void;
	sendUserMessage?: (prompt: string, options: { deliverAs: string }) => Promise<void>;
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
			return () => handlers.set(event, (handlers.get(event) ?? []).filter((registered) => registered !== handler));
		},
		registerCommand: () => undefined,
		registerMessageRenderer: () => undefined,
		registerShortcut: () => undefined,
		registerTool: options.registerTool ?? (() => undefined),
		sendMessage: () => undefined,
		sendUserMessage: options.sendUserMessage ?? (async () => undefined),
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
		isProjectTrusted: () => true,
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

/** Run registered tools against an isolated parent with drained shutdown; headless unless `hasUI`. */
export async function withExtensionTools(run: (tools: Map<string, any>, ctx: any, harness: Harness) => Promise<void>, extension?: ExtensionFactory, hasUI = false) {
	const harness = createHarness({});
	const ctx = { ...fakeCtx(harness), hasUI };
	const handlers = new Map<string, SessionHandler[]>();
	const tools = new Map<string, any>();
	const pending = new Set<Promise<unknown>>();
	const updateTaskRegistry = tasks.updateTaskRegistry;
	const writes = spyOn(tasks, "updateTaskRegistry").mockImplementation((...args) => {
		const write = updateTaskRegistry(...args);
		pending.add(write);
		void write.then(() => pending.delete(write), () => pending.delete(write));
		return write;
	});
	try {
		await withoutRealIntervals(async () => {
			const start = await installExtension(harness, { extension, handlers, registerTool: (tool) => tools.set(tool.name, tool) });
			await start({}, ctx);
			await run(tools, ctx, harness);
		});
	} finally {
		try {
			for (const handler of handlers.get("session_shutdown") ?? []) await handler({ reason: "quit" }, ctx);
			while (pending.size > 0) await Promise.allSettled([...pending]);
		} finally {
			writes.mockRestore();
			teardown(harness);
		}
	}
}

/** A cancellation event persists stopped and is read back through the real tool. */
export async function assertStoppedEvent(extension?: ExtensionFactory) {
	const factory = extension ?? (await import("../extensions/subagent/index.js")).default;
	let emit: ExtensionAPI["events"]["emit"];
	await withExtensionTools(async (tools, ctx) => {
		const root = sessionRuntimeDir(ctx.sessionManager.getSessionId());
		emit("subagents:failed", { agent: "scout", taskId: "canceled-task", mode: "oneshot", runtimeRoot: root, status: "aborted", error: "Agent was aborted", task: "map" });
		// Registry persistence runs after the bus callback; the real status tool waits for it.
		const result = await tools.get("get_subagent_result").execute("test", { taskId: "canceled-task", wait: true, timeoutMs: 1000 }, undefined, undefined, ctx);
		assert.equal(result.details.status, "stopped");
	}, (pi) => { emit = pi.events.emit.bind(pi.events); factory(pi); });
}

/**
 * The extension's stall selector reads its own registry and keeps the active task alone,
 * and the started watchdog marks a stale idle pane task needs_completion at its deadline.
 * Driven through the injected clock and the captured interval tick; the bridge idle probe is stubbed idle.
 */
export async function assertStallSelector(extension?: ExtensionFactory, hasUI = true) {
	let deps: idleWatchdog.IdleStallWatchdogDeps | undefined;
	let watchdog: idleWatchdog.IdleStallWatchdog | undefined;
	let tick: (() => void) | undefined;
	const lastActivity = Date.parse("2026-10-01T00:00:00Z");
	let clock = lastActivity;
	// The factory hands its selector to the watchdog it constructs.
	const create = idleWatchdog.createIdleStallWatchdog;
	const construction = spyOn(idleWatchdog, "createIdleStallWatchdog").mockImplementation((real) => {
		deps = real;
		watchdog = create({ ...real, now: () => clock, isPaneIdle: async () => true, setInterval: (handler) => { tick = handler; return handler; }, clearInterval: () => { tick = undefined; } });
		return watchdog;
	});
	try {
		await withExtensionTools(async (_tools, ctx) => {
			assert.ok(deps && watchdog, "extension must construct the stall watchdog");
			const root = runtimeDirForContext(ctx);
			const row = (taskId: string, status: "running" | "stopped") => ({ agent: "scout", taskId, task: "map files", status, paneId: "%7", createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z" });
			await tasks.writeTaskRegistry(root, { running: row("running", "running"), stopped: row("stopped", "stopped") });
			// The running row proves the selector read this registry, so a read that
			// found nothing cannot stand in for one that filtered the stopped task.
			assert.deepEqual((await deps.listActiveTasks()).map((record) => record.taskId), ["running"]);
			assert.ok(tick, "session_start must start the stall watchdog");
			const pass = async () => {
				tick!();
				return watchdog!.checkAll();
			};
			clock = lastActivity + deps.thresholdMs - 1;
			assert.deepEqual(await pass(), [{ taskId: "running", fired: false, skipped: "not-stale" }]);
			assert.equal((await tasks.readTaskRegistry(root)).running?.status, "running");
			clock = lastActivity + deps.thresholdMs;
			assert.deepEqual(await pass(), [{ taskId: "running", fired: true }]);
			const stalled = (await tasks.readTaskRegistry(root)).running;
			assert.equal(stalled?.status, "needs_completion");
			// The completion poller parses this outbox; its reason is the machine-read stall key.
			assert.equal(JSON.parse(readFileSync(stalled!.outboxFile!, "utf8")).reason, idleWatchdog.STALL_WATCHDOG_REASON);
		}, extension, hasUI);
	} finally {
		construction.mockRestore();
	}
}

/** Both completion renderers consume the status that complete_subagent writes. */
export async function assertCompletionPresentation(extension?: ExtensionFactory) {
	const factory = extension ?? (await import("../extensions/subagent/index.js")).default;
	let selfRenderer: Parameters<ExtensionAPI["registerMessageRenderer"]>[1] | undefined;
	await withExtensionTools(async (tools) => {
		// blocked is one of CompleteSubagentParams' real output statuses.
		const details = { agent: "scout", taskId: "task", status: "blocked" };
		const toolLines = tools.get("complete_subagent").renderResult({ content: [], details }, {}, toneTheme, {}).render(180).join("\n");
		assert.ok(toolLines.includes("<warning>blocked</warning>"));
		assert.ok(selfRenderer);
		const message = { role: "custom" as const, customType: "subagent-self-completion", content: "", display: true, details, timestamp: 0 };
		assert.ok(selfRenderer(message, { expanded: false }, toneTheme as unknown as import("@earendil-works/pi-coding-agent").Theme)?.render(180).join("\n").includes("<warning>blocked</warning>"));
	}, (pi) => {
		const register = pi.registerMessageRenderer.bind(pi);
		pi.registerMessageRenderer = (type, renderer) => {
			if (type === "subagent-self-completion") selfRenderer = renderer as Parameters<ExtensionAPI["registerMessageRenderer"]>[1];
			register(type, renderer);
		};
		factory(pi);
	});
}

/** The registered tool must keep exact-session requests in every dispatch mode. */
export async function assertRegisteredExactSession(params: Record<string, unknown>, overflow: "guard" | "provider", extension?: ExtensionFactory) {
	await withExtensionTools(async (tools, ctx, harness) => {
		mkdirSync(join(harness.cwd, ".pi/agents"), { recursive: true });
		writeFileSync(join(harness.cwd, ".pi/agents/scout.md"), "---\nname: scout\ndescription: map\n---\nMap files.\n");
		writeSettings(harness.cwd, { reusedSessionContextLimitTokens: overflow === "guard" ? 100 : 1000, reusedSessionBudgetThreshold: 0.8 });
		const root = sessionRuntimeDir(ctx.sessionManager.getSessionId());
		const session = resolveBgSession(root, "scout", "reuse");
		mkdirSync(join(root, "sessions"), { recursive: true });
		writeFileSync(session.path, " ".repeat(432));
		const calls = installMockSpawn([{ stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [], stopReason: "error", errorMessage: "context_length_exceeded" } })]) }, { stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "unwanted fresh answer" }] } })]) }]);
		try {
			const result = await tools.get("subagent").execute("test", params, undefined, undefined, ctx);
			const child = result.details.results[0];
			assert.deepEqual([calls.length, singleResultStatus(child), child.sessionKey, child.refused ?? false, result.content[0].text.includes("Start a fresh agent")], [overflow === "guard" ? 0 : 1, overflow === "guard" ? "refused" : "failed", "reuse", overflow === "guard", true]);
			if (result.details.mode !== "parallel") assert.equal(result.isError, true);
			assert.ok(result.content[0].text.includes(overflow === "guard" ? "108/100 tokens (108%) exceeds 80%" : "context_length_exceeded"));
		} finally { setSingleAgentSpawnForTests(); }
	}, extension);
}

/** A parent reads the child guard's exact estimate before choosing reuse. */
export async function assertAgentContextBudget(extension?: ExtensionFactory, route: "background" | "pane" = "background") {
	await withExtensionTools(async (tools, ctx, harness) => {
		const childCwd = join(harness.cwd, "child-project");
		writeSettings(harness.cwd, { reusedSessionContextLimitTokens: 1000, reusedSessionBudgetThreshold: 0.9, subagentModelSource: "parent" });
		writeSettings(childCwd, { reusedSessionContextLimitTokens: 100, reusedSessionBudgetThreshold: 0.8 });
		mkdirSync(join(harness.cwd, ".pi/agents"), { recursive: true });
		writeFileSync(join(harness.cwd, ".pi/agents/scout.md"), "---\nname: scout\ndescription: map\nmodel: profile/model\n---\nMap files.\n");
		ctx.model = { provider: "parent", id: "model" };
		const root = sessionRuntimeDir(ctx.sessionManager.getSessionId());
		const session = resolveBgSession(root, "scout", "reuse");
		mkdirSync(join(root, "sessions"), { recursive: true });
		writeFileSync(session.path, `${JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "prior result" }] } })}\n`.padEnd(432, " "));
		if (route === "pane") {
			await writePaneRegistry(root, { scout: { agent: "scout", paneId: "%missing", windowName: "scout", cwd: childCwd, sessionFile: session.path, promptFile: "", launcherFile: "", model: "pane/model", startedAt: "2026-09-30T00:00:00Z" } });
			await writeTaskRegistry(root, { "pane-task": { taskId: "pane-task", agent: "scout", task: "map", kind: "pane", paneId: "%missing", status: "completed", transcriptPath: session.path, model: "stale/model", summary: "prior result", createdAt: "2026-09-30T00:00:00Z" } });
		}
		// The guard currently uses configured limits. Observe its model argument as well.
		const guard = spyOn(sessions, "guardReusedSessionBudget");
		try {
			const params = route === "background" ? { agent: "scout", sessionKey: "reuse", cwd: childCwd } : { taskId: "pane-task" };
			const result = await tools.get("get_subagent_result").execute("test", params, undefined, undefined, ctx);
			const budget = result.details.contextBudget;
			assert.deepEqual([result.isError ?? false, budget?.ok, budget?.estimate.tokens, budget?.estimate.contextLimitTokens, budget?.estimate.ratio, budget?.estimate.threshold, result.details.summary], [false, false, 108, 100, 1.08, 0.8, "prior result"]);
			assert.deepEqual(guard.mock.calls.at(-1)?.slice(2), [route === "pane" ? "pane/model" : "parent/model", childCwd]);
			const content = result.content[0].text;
			const reportedBudget = route === "background" ? JSON.parse(content).contextBudget : JSON.parse(content.split("\nContext budget: ")[1]);
			assert.deepEqual(reportedBudget, budget);
		} finally { guard.mockRestore(); }
	}, extension);
}

/** Run `fn` with setInterval stubbed out; each interval it starts is pushed
 *  onto `started`, so a case can run a tick itself. A clearInterval inside
 *  `fn` marks its interval `cleared`, as a real timer would stop firing. */
export async function withoutRealIntervals(fn: () => Promise<void>, started: Array<{ callback: () => void; ms: number; cleared?: boolean }> = []): Promise<void> {
	const realSetInterval = globalThis.setInterval;
	const realClearInterval = globalThis.clearInterval;
	const stubbed = new Map<object, { cleared?: boolean }>();
	(globalThis as any).setInterval = ((callback: () => void, ms: number) => {
		const tick = { callback, ms };
		started.push(tick);
		const handle = { unref: () => undefined };
		stubbed.set(handle, tick);
		return handle;
	}) as any;
	(globalThis as any).clearInterval = ((handle: any) => {
		const tick = stubbed.get(handle);
		if (tick) tick.cleared = true;
		else realClearInterval(handle);
	}) as any;
	try {
		await fn();
	} finally {
		globalThis.setInterval = realSetInterval;
		globalThis.clearInterval = realClearInterval;
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
