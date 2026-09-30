import { mock } from "bun:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fixturePid, interceptNativeEffects } from "./spawn-native.js";

// Drives the registered extension through its write-heavy and probe paths:
//   chunks:              one task streams output with notifyOnOutput on;
//   restore:             a session branch replays many snapshot entries of the same tasks;
//   identity-cleared:    a task is cleared before its spawn-time identity read resolves;
//   restore-concurrency: restore probes `running` running tasks whose /proc reads the fixture holds;
//   exit-flush:          a task's last chunk is still pending in the log writer when its child closes;
//   log-hold:            a task outruns log appends the fixture holds;
//   exit-held:           a task's child closes while the fixture holds its last log append, then
//                        `during` names what lands before the release: a stop and the timeout, shutdown or a clear;
//                        this mode alone has a UI, whose widget the fixture draws on each redraw request;
//   log-stall:           a task outruns a log append that never settles and is stopped while held;
//   bound-held:          a task's child closes while the fixture holds its last log append, then
//                        as many tasks as the finished-task bound keeps finish before the release.
interface Input {
	mode: "chunks" | "restore" | "identity-cleared" | "restore-concurrency" | "exit-flush" | "log-hold" | "exit-held" | "log-stall" | "bound-held";
	chunks?: number; entries?: number; running?: number; during?: "stop-and-timeout" | "shutdown" | "clear";
}
const input: Input = JSON.parse(await Bun.stdin.text());
const native = await interceptNativeEffects({
	deferProcReads: input.mode === "identity-cleared" || input.mode === "restore-concurrency",
	deferAppends: input.mode === "log-hold" || input.mode === "exit-held" || input.mode === "log-stall" || input.mode === "bound-held",
});
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: readonly string[]) => ({ enum: values }) }));
mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, Optional: (value: unknown) => value, Number: () => ({}), String: () => ({}), Boolean: () => ({}) } }));
const unused = () => { throw new Error("write_path_fixture.sdk_operation=unexpected_render"); };
const hasUI = input.mode === "exit-held";
// The runner's user settings hide the widget; this project's settings show it.
if (hasUI) writeFileSync(join(process.cwd(), ".pi", "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-background-tasks": { showWidget: true } } } } }));
mock.module("@earendil-works/pi-tui", () => hasUI
	? { matchesKey: unused, truncateToWidth: (text: string, width: number) => text.slice(0, width), visibleWidth: (text: string) => text.length, wrapTextWithAnsi: (text: string) => [text] }
	: { matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused });
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: () => ({ shell: "fixture-shell", args: ["-c"] }) }));

interface ToolResult { content: { text: string }[]; details: { task?: Record<string, unknown> } }
interface Tool { name: string; execute(id: string, params: Record<string, unknown>): Promise<ToolResult> }
const tools = new Map<string, Tool>();
const events = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
const entries: unknown[] = [];
// The task's log file contents at each wake, read when the wake is sent.
let wakeLogFile: string | null = null;
const logsAtWake: string[] = [];
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
// The widget stack as the TUI last drew it: a new widget and each redraw request draw it again.
type Drawn = { render(width: number): string[] };
let widget: Drawn | null = null;
let frame: string[] = [];
const draw = () => { frame = widget?.render(120) ?? []; };
const tui = { terminal: { rows: 40 }, requestRender: draw };
const theme = { fg: (_color: string, text: string) => text, bold: (text: string) => text };
const widgetCounts = () => {
	const counts = frame.join("\n").match(/(\d+) running · (\d+) finished/);
	return counts ? { running: Number(counts[1]), finished: Number(counts[2]) } : null;
};
const ctx = {
	cwd: process.cwd(), hasUI, isProjectTrusted: () => true,
	sessionManager: { getSessionId: () => sessionId, getSessionFile: () => join(process.cwd(), "session.jsonl"), getBranch: () => branch },
	ui: {
		notify() {},
		setWidget(_key: string, factory?: (tui: unknown, theme: unknown) => Drawn) {
			widget = factory ? factory(tui, theme) : null;
			draw();
		},
	},
} as unknown as ExtensionContext;
const pi = {
	registerTool(tool: Tool) { tools.set(tool.name, tool); },
	registerCommand() {}, registerShortcut() {}, registerMessageRenderer() {},
	on(event: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) { events.set(event, handler); },
	appendEntry: (...args: unknown[]) => entries.push(args),
	sendMessage() { if (wakeLogFile) logsAtWake.push(existsSync(wakeLogFile) ? readFileSync(wakeLogFile, "utf8") : ""); },
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
// Log appends reach the real file system, whose writes finish in real time.
const settleUntil = async (done: () => boolean) => {
	for (let waited = 0; waited < 5_000 && !done(); waited += 1) await Bun.sleep(1);
};
const timerSets = () => {
	const counts: Record<string, number> = {};
	for (const event of native.timerEvents) if (event.action === "set") counts[`${event.kind}:${event.ms}`] = (counts[`${event.kind}:${event.ms}`] ?? 0) + 1;
	return counts;
};
const logBytes = (file: string) => existsSync(file) ? readFileSync(file, "utf8").length : 0;
const persistedTask = (id: string) => {
	const payload = (entries.at(-1) as [string, { tasks: Record<string, unknown>[] }] | undefined)?.[1];
	return payload?.tasks.find((task) => task.id === id) ?? null;
};
const persistedProcIdent = (id: string) => persistedTask(id)?.procIdent ?? null;
const persistedOutcome = (id: string) => {
	const task = persistedTask(id);
	return { status: task?.status, reason: task?.terminationReason, exitCode: task?.exitCode };
};
let result: unknown;
try {
	const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
	const { taskLogs } = await import("../../extensions/log-writer.js");
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
		await taskLogs.drain();
		result = { duringChunks, afterPersistWindow, procIdent: persistedProcIdent("bg-1"), logBytesAfterFlush: logBytes(logFile), chunkBytes: chunk.length };
		child.emit("close", 0);
	} else if (input.mode === "exit-flush") {
		await dispatch("session_start");
		const spawned = await execute({ action: "spawn", command: "fixture exit", notifyOnExit: true });
		wakeLogFile = spawned.details.task!.logFile as string;
		await settle();
		const child = native.children[0]!;
		child.stdout.write("final line\n");
		await settle();
		child.emit("close", 0);
		await settleUntil(() => logsAtWake.length > 0);
		result = { logsAtWake };
	} else if (input.mode === "log-hold") {
		const { LOG_MAX_PENDING_BYTES, LOG_WRITE_NOW_BYTES } = await import("../../extensions/log-writer.js");
		await dispatch("session_start");
		const spawned = await execute({ action: "spawn", command: "fixture flood", notifyOnExit: false });
		const logFile = spawned.details.task!.logFile as string;
		await settle();
		const child = native.children[0]!;
		const chunk = `${"z".repeat(LOG_WRITE_NOW_BYTES - 1)}\n`;
		// One chunk starts a write the fixture holds; the pending text behind it
		// reaches the cap, and one chunk more waits in the paused stream.
		const chunks = 2 + LOG_MAX_PENDING_BYTES / LOG_WRITE_NOW_BYTES;
		for (let index = 0; index < chunks; index++) {
			child.stdout.write(chunk);
			await settle();
		}
		const whileHeld = { heldAppends: native.heldAppends(), stdoutPaused: child.stdout.isPaused(), stderrPaused: child.stderr.isPaused() };
		native.releaseAppends();
		await settleUntil(() => !child.stdout.isPaused());
		const afterRelease = { stdoutPaused: child.stdout.isPaused(), stderrPaused: child.stderr.isPaused() };
		// The chunk the paused stream held reaches the writer once it resumes.
		await settleUntil(() => {
			native.releaseAppends();
			return logBytes(logFile) === chunks * chunk.length;
		});
		result = { whileHeld, afterRelease, logBytes: logBytes(logFile), expectedBytes: chunks * chunk.length };
		child.emit("close", 0);
	} else if (input.mode === "exit-held") {
		await dispatch("session_start");
		const spawned = await execute({ action: "spawn", command: "fixture exit", notifyOnExit: true, timeoutSeconds: 60 });
		const logFile = spawned.details.task!.logFile as string;
		wakeLogFile = logFile;
		await settle();
		const child = native.children[0]!;
		child.stdout.write("final line\n");
		await settle();
		const widgetBeforeClose = widgetCounts();
		child.emit("close", 0);
		await settle();
		const heldAppends = native.heldAppends();
		const widgetAtClose = widgetCounts();
		let stopMessage: string | null = null;
		let timeoutArmed: boolean | null = null;
		let signals: unknown[];
		if (input.during === "shutdown") {
			const shutdown = dispatch("session_shutdown");
			await settle();
			signals = [...native.signals];
			native.releaseAppends();
			await shutdown;
		} else if (input.during === "clear") {
			await execute({ action: "clear" });
			signals = [...native.signals];
			native.releaseAppends();
			// clear deletes the task's log once the held write has landed.
			await settleUntil(() => !existsSync(logFile));
			// A wake the write's settle could release runs on the turns after the bytes land.
			await settle();
			await settle();
		} else {
			stopMessage = (await execute({ action: "stop", id: "bg-1" })).content[0]!.text;
			timeoutArmed = native.activeTimers().some((timer) => timer.kind === "timeout" && timer.ms === 60_000);
			if (timeoutArmed) native.fireTimeout(60_000);
			signals = [...native.signals];
			native.releaseAppends();
			await settleUntil(() => logsAtWake.length > 0);
		}
		result = {
			heldAppends, widgetBeforeClose, widgetAtClose, stopMessage, timeoutArmed, signals, childSignals: native.childSignals,
			outcome: persistedOutcome("bg-1"), logsAtWake, log: existsSync(logFile) ? readFileSync(logFile, "utf8") : null,
		};
	} else if (input.mode === "log-stall") {
		const { LOG_MAX_PENDING_BYTES, LOG_WRITE_NOW_BYTES, LOG_WRITE_STALL_MS, stalledLogMarker } = await import("../../extensions/log-writer.js");
		await dispatch("session_start");
		const spawned = await execute({ action: "spawn", command: "fixture flood", notifyOnExit: true });
		const logFile = spawned.details.task!.logFile as string;
		wakeLogFile = logFile;
		await settle();
		const child = native.children[0]!;
		const chunk = `${"z".repeat(LOG_WRITE_NOW_BYTES - 1)}\n`;
		// One chunk starts the write the fixture holds; the pending text behind
		// it reaches the cap, and one chunk more waits in the paused stream.
		const chunks = 2 + LOG_MAX_PENDING_BYTES / LOG_WRITE_NOW_BYTES;
		for (let index = 0; index < chunks; index++) {
			child.stdout.write(chunk);
			await settle();
		}
		const whileHeld = { heldAppends: native.heldAppends(), stdoutPaused: child.stdout.isPaused() };
		const stopMessage = (await execute({ action: "stop", id: "bg-1" })).content[0]!.text.split(" ")[0];
		native.fireTimeout(LOG_WRITE_STALL_MS);
		await settleUntil(() => !child.stdout.isPaused());
		const afterStall = { heldAppends: native.heldAppends(), stdoutPaused: child.stdout.isPaused() };
		child.emit("close", null);
		await settleUntil(() => logsAtWake.length > 0);
		const atWake = { outcome: persistedOutcome("bg-1"), logsAtWake: logsAtWake.map((log) => log.length) };
		// The chunk that arrived during the stall is past the cap: once the
		// write settles, a marker counts it after the text kept before it.
		const expectedLog = chunk.repeat(chunks - 1) + stalledLogMarker(chunk.length);
		await settleUntil(() => {
			native.releaseAppends();
			return logBytes(logFile) >= expectedLog.length;
		});
		result = { whileHeld, stopMessage, afterStall, atWake, logIsKeptTextThenMarker: readFileSync(logFile, "utf8") === expectedLog };
	} else if (input.mode === "bound-held") {
		const { MAX_FINISHED_TASKS } = await import("../../extensions/constants.js");
		await dispatch("session_start");
		const spawned = await execute({ action: "spawn", command: "fixture held", notifyOnExit: true });
		wakeLogFile = spawned.details.task!.logFile as string;
		await settle();
		native.children[0]!.stdout.write("held line\n");
		await settle();
		native.children[0]!.emit("close", 0);
		await settle();
		// Each quiet task finishes with no output, so its exit settles at once and
		// runs the bound, while bg-1 is the oldest finished task.
		for (let index = 1; index <= MAX_FINISHED_TASKS; index++) {
			await execute({ action: "spawn", command: `fixture quiet ${index}`, notifyOnExit: false });
			await settle();
			native.children[index]!.emit("close", 0);
			await settle();
		}
		const heldAppends = native.heldAppends();
		native.releaseAppends();
		await settleUntil(() => logsAtWake.length > 0);
		result = { heldAppends, logsAtWake };
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
