import { mock } from "bun:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { interceptNativeEffects, fixtureNow, fixturePid } from "./spawn-native.js";

interface Input { mode: "spawn" | "stop"; platform?: string; resource?: boolean; caller?: "tool" | "shutdown" | "slash"; command?: string; stopFails?: boolean; killFails?: boolean; signalGone?: boolean }
const input: Input = JSON.parse(await Bun.stdin.text());
const native = await interceptNativeEffects(input);
const originalPlatform = Object.getOwnPropertyDescriptor(process, "platform")!;
const unused = () => { throw new Error("spawn_fixture.sdk_operation=unexpected_render"); };
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: readonly string[]) => ({ enum: values }) }));
mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, Optional: (value: unknown) => value, Number: () => ({}), String: () => ({}), Boolean: () => ({}) } }));
mock.module("@earendil-works/pi-tui", () => ({ matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused }));
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: () => ({ shell: "fixture-shell", args: ["-c"] }) }));

interface ToolResult { content: { type: string; text: string }[]; details: { action: string; task?: Record<string, unknown>; tasks?: Record<string, unknown>[] } }
interface Tool { name: string; execute(id: string, params: Record<string, unknown>): Promise<ToolResult> }
const tools = new Map<string, Tool>();
const commands = new Map<string, { handler(args: string, ctx: ExtensionContext): unknown }>();
const events = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
const messages: unknown[] = [];
const notifications: unknown[] = [];
const entries: unknown[] = [];
const ctx = {
	cwd: process.cwd(), hasUI: false, isProjectTrusted: () => true,
	sessionManager: { getSessionId: () => "spawn-hardening-private-session", getSessionFile: () => join(process.cwd(), "session.jsonl"), getBranch: () => [] },
	ui: { notify: (...args: unknown[]) => notifications.push(args), setWidget() {} },
} as unknown as ExtensionContext;
const pi = {
	registerTool(tool: Tool) { tools.set(tool.name, tool); },
	registerCommand(name: string, command: { handler(args: string, ctx: ExtensionContext): unknown }) { commands.set(name, command); }, registerShortcut() {}, registerMessageRenderer() {},
	on(event: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) { events.set(event, handler); },
	appendEntry: (...args: unknown[]) => entries.push(args),
	sendMessage: (...args: unknown[]) => messages.push(args),
} as unknown as ExtensionAPI;
let started = false;
let shutDown = false;
async function dispatch(event: string) {
	const handler = events.get(event);
	if (!handler) throw new Error(`spawn_fixture.event_missing=${event}`);
	await handler({}, ctx);
}
async function execute(params: Record<string, unknown>) {
	const tool = tools.get("bg_task");
	if (!tool) throw new Error("spawn_fixture.tool_missing=bg_task");
	return await tool.execute("private-tool-call", params);
}
async function state() {
	const inspected = await execute({ action: "log", id: "bg-1" });
	const task = inspected.details.task;
	if (!task) throw new Error("spawn_fixture.task_missing=bg-1");
	return { id: task.id, pid: task.pid, status: task.status, reason: task.terminationReason ?? null, exitCode: task.exitCode, exitNotified: task.exitNotified };
}
try {
	const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
	backgroundTasks(pi);
	await dispatch("session_start");
	started = true;
	// Only the platform-sensitive spawn call runs under this row's platform.
	if (input.platform) Object.defineProperty(process, "platform", { ...originalPlatform, value: input.platform });
	const spawned = await execute({ action: "spawn", command: input.command ?? "fixture command", notifyOnExit: false });
	Object.defineProperty(process, "platform", originalPlatform);
	if (native.children.length !== 1 || native.spawns.length !== 1) throw new Error(`spawn_fixture.spawn_count=${native.spawns.length},children=${native.children.length}`);
	const child = native.children[0]!;
	const spawn = native.spawns[0]!;
	const before = await state();
	const stopStart = native.syncCalls.length;
	let outcome: unknown;
	let stopResult: ToolResult | undefined;
	let after: unknown;
	let escalated: unknown;
	if (input.mode === "stop") {
		if (input.caller === "shutdown") {
			await dispatch("session_shutdown");
			shutDown = true;
			outcome = { kind: "shutdown" };
		} else if (input.caller === "slash") {
			const command = commands.get("bg:stop");
			if (!command) throw new Error("spawn_fixture.command_missing=bg:stop");
			await command.handler("bg-1", ctx);
			outcome = { kind: "slash" };
		} else {
			try { const result = await execute({ action: "stop", id: "bg-1" }); stopResult = result; outcome = { kind: "tool", action: result.details.action, text: result.content[0]?.text }; }
			catch (error) { outcome = { kind: "error", message: error instanceof Error ? error.message : String(error) }; }
		}
		after = { state: await state(), timers: native.activeTimers(), signals: [...native.signals], childSignals: [...native.childSignals], unitCalls: native.syncCalls.slice(stopStart) };
		if (input.caller !== "shutdown" && !input.stopFails && !input.signalGone) {
			native.fireTimeout(5000);
			escalated = { state: await state(), signals: [...native.signals], unitCalls: native.syncCalls.slice(stopStart) };
			child.emit("close", null);
		}
	}
	if (input.mode === "spawn") child.emit("close", 0);
	const final = await state();
	const log = readFileSync(spawned.details.task!.logFile as string, "utf8");
	const stoppedTimers = native.activeTimers();
	const stopCalls = native.syncCalls.slice(stopStart);
	const signals = [...native.signals];
	const childSignals = [...native.childSignals];
	if (!shutDown) { await dispatch("session_shutdown"); shutDown = true; }
	process.stdout.write(JSON.stringify({
		spawn: { file: spawn.file, args: spawn.args, detached: spawn.options.detached, stdio: spawn.options.stdio, cwdIsPrivate: spawn.options.cwd === process.cwd(), piRootIsPrivate: (spawn.options.env as NodeJS.ProcessEnv).PI_CODING_AGENT_DIR === process.env.PI_CODING_AGENT_DIR, resultAction: spawned.details.action, resultId: spawned.details.task!.id, resultPid: spawned.details.task!.pid },
		before, outcome, stopResult, after, escalated, final, log, stoppedTimers, stopCalls, signals, childSignals,
		timerEvents: native.timerEvents, remainingTimers: native.activeTimers(), unexpected: native.unexpected, notifications, messages,
		fixtureNow, fixturePid,
	}));
} finally {
	Object.defineProperty(process, "platform", originalPlatform);
	try { if (started && !shutDown) await dispatch("session_shutdown"); }
	finally { native.restore(); }
}
