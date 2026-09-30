import { mock } from "bun:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fixturePid, interceptNativeEffects } from "./spawn-native.js";

// Drives the registered extension through its write-heavy and probe paths:
//   chunks:              one task streams output with notifyOnOutput on;
//   restore:             a session branch replays many snapshot entries of the same tasks;
//   identity-cleared:    a task is cleared before its spawn-time identity read resolves;
//   restore-concurrency: restore probes `running` running tasks whose /proc reads the fixture holds.
interface Input { mode: "chunks" | "restore" | "identity-cleared" | "restore-concurrency"; chunks?: number; entries?: number; running?: number }
const input: Input = JSON.parse(await Bun.stdin.text());
const native = await interceptNativeEffects({ deferProcReads: input.mode === "identity-cleared" || input.mode === "restore-concurrency" });
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: readonly string[]) => ({ enum: values }) }));
mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, Optional: (value: unknown) => value, Number: () => ({}), String: () => ({}), Boolean: () => ({}) } }));
const unused = () => { throw new Error("write_path_fixture.sdk_operation=unexpected_render"); };
mock.module("@earendil-works/pi-tui", () => ({ matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused }));
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: () => ({ shell: "fixture-shell", args: ["-c"] }) }));

interface ToolResult { details: { task?: Record<string, unknown> } }
interface Tool { name: string; execute(id: string, params: Record<string, unknown>): Promise<ToolResult> }
const tools = new Map<string, Tool>();
const events = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
const entries: unknown[] = [];
const sessionId = "write-path-private-session";
const unit = "kendex-pi-bg-bg-2-1700000000000.service";
const snapshot = (id: string, fields: Record<string, unknown>) => ({
	command: `fixture ${id}`, cwd: process.cwd(), exitCode: null, exitNotified: true, expiresAt: null, id,
	lastOutputAt: null, logFile: join(process.cwd(), `${id}.log`), notifyOnExit: false, notifyOnOutput: false,
	outputBytes: 0, pid: 0, sessionId, startedAt: 1_700_000_000_000, status: "completed", title: id, updatedAt: 1_700_000_000_000, ...fields,
});
const identity = { pid: fixturePid, startToken: "12345", comm: "fixture-child" };
const concurrencyBranch = [{
	type: "custom", customType: "kendex-background-tasks:state",
	data: { version: 1, updatedAt: 1_700_000_000_000, tasks: Array.from({ length: input.running ?? 0 }, (_, index) =>
		snapshot(`bg-${index + 1}`, { status: "running", pid: fixturePid, procIdent: identity })) },
}];
const historyBranch = Array.from({ length: input.entries ?? 0 }, (_, entry) => ({
	type: "custom", customType: "kendex-background-tasks:state",
	data: { version: 1, updatedAt: 1_700_000_000_000 + entry, tasks: [
		snapshot("bg-1", { status: "running", pid: fixturePid, procIdent: identity, updatedAt: 1_700_000_000_000 + entry }),
		snapshot("bg-2", { status: "running", pid: fixturePid + 1, resourceControl: { mode: "systemd-run", requestedMode: "auto", unitName: unit }, updatedAt: 1_700_000_000_000 + entry }),
		snapshot("bg-3", { exitCode: 0 }),
	] },
}));
const branch = input.mode === "restore-concurrency" ? concurrencyBranch : historyBranch;
const ctx = {
	cwd: process.cwd(), hasUI: false, isProjectTrusted: () => true,
	sessionManager: { getSessionId: () => sessionId, getSessionFile: () => join(process.cwd(), "session.jsonl"), getBranch: () => branch },
	ui: { notify() {}, setWidget() {} },
} as unknown as ExtensionContext;
const pi = {
	registerTool(tool: Tool) { tools.set(tool.name, tool); },
	registerCommand() {}, registerShortcut() {}, registerMessageRenderer() {},
	on(event: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) { events.set(event, handler); },
	appendEntry: (...args: unknown[]) => entries.push(args),
	sendMessage() {},
} as unknown as ExtensionAPI;
async function dispatch(event: string) {
	const handler = events.get(event);
	if (!handler) throw new Error(`write_path_fixture.event_missing=${event}`);
	await handler({}, ctx);
}
async function execute(params: Record<string, unknown>) {
	const tool = tools.get("bg_task");
	if (!tool) throw new Error("write_path_fixture.tool_missing=bg_task");
	return await tool.execute("private-tool-call", params);
}
// PassThrough data events and resolved probes land on later event-loop turns.
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));
const timerSets = () => {
	const counts: Record<string, number> = {};
	for (const event of native.timerEvents) if (event.action === "set") counts[`${event.kind}:${event.ms}`] = (counts[`${event.kind}:${event.ms}`] ?? 0) + 1;
	return counts;
};
const logBytes = (file: string) => existsSync(file) ? readFileSync(file, "utf8").length : 0;
const persistedProcIdent = (id: string) => {
	const payload = (entries.at(-1) as [string, { tasks: { id: string; procIdent?: unknown }[] }] | undefined)?.[1];
	return payload?.tasks.find((task) => task.id === id)?.procIdent ?? null;
};
let result: unknown;
try {
	const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
	const { LOG_DRAIN_DEADLINE_MS, taskLogs } = await import("../../extensions/log-writer.js");
	backgroundTasks(pi);
	if (input.mode === "chunks") {
		await dispatch("session_start");
		const spawned = await execute({ action: "spawn", command: "fixture stream", notifyOnOutput: true, notifyOnExit: false });
		const logFile = spawned.details.task!.logFile as string;
		await settle();
		const child = native.children[0]!;
		const entriesBefore = entries.length;
		const chunk = "fixture output line\n";
		for (let index = 0; index < (input.chunks ?? 0); index++) {
			child.stdout.write(chunk);
			await settle();
		}
		const duringChunks = { entries: entries.length - entriesBefore, logBytes: logBytes(logFile), timerSets: timerSets() };
		const fireIfArmed = (ms: number) => {
			if (native.activeTimers().some((timer) => timer.kind === "timeout" && timer.ms === ms)) native.fireTimeout(ms);
		};
		fireIfArmed(1_000);
		const afterPersistWindow = entries.length - entriesBefore;
		fireIfArmed(250);
		await taskLogs.drain(LOG_DRAIN_DEADLINE_MS);
		result = { duringChunks, afterPersistWindow, procIdent: persistedProcIdent("bg-1"), logBytesAfterFlush: logBytes(logFile), chunkBytes: chunk.length };
		child.emit("close", 0);
	} else if (input.mode === "identity-cleared") {
		const { latestSnapshot } = await import("../../extensions/snapshot.js");
		await dispatch("session_start");
		await execute({ action: "spawn", command: "fixture quick", notifyOnExit: false });
		await settle();
		native.children[0]!.emit("close", 0);
		await execute({ action: "clear" });
		const heldReads = native.heldProcReads();
		native.releaseProcReads();
		await settle();
		const live = latestSnapshot({ id: "bg-1" } as Parameters<typeof latestSnapshot>[0]);
		result = { heldReads, liveProcIdent: live?.procIdent ?? null, persistArmed: native.activeTimers().some((timer) => timer.ms === 1_000) };
	} else if (input.mode === "restore-concurrency") {
		let started = false;
		const start = dispatch("session_start").then(() => { started = true; });
		let maxInFlight = 0;
		let probes = 0;
		while (!started) {
			await settle();
			const held = native.heldProcReads();
			maxInFlight = Math.max(maxInFlight, held);
			probes += held;
			native.releaseProcReads();
		}
		await start;
		result = { maxInFlight, probes };
	} else {
		await dispatch("session_start");
		const states = [];
		for (const id of ["bg-1", "bg-2", "bg-3"]) {
			const task = (await execute({ action: "log", id })).details.task!;
			states.push({ id: task.id, status: task.status });
		}
		// Concurrent probes finish in any order; the multiset is the contract.
		result = { probes: native.probeCalls.map(({ file, args }) => [file, ...args].join(" ")).sort(), states };
	}
	await dispatch("session_shutdown");
	process.stdout.write(JSON.stringify({ ...result as object, unexpected: native.unexpected }));
} finally {
	native.restore();
}
