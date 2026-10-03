import { mock } from "bun:test";
import assert from "node:assert/strict";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { interceptNativeEffects, fixtureNow, fixturePid } from "./spawn-native.js";
import { waitForSpawnEffects } from "./spawn-child-runner.js";

import type { BackgroundTaskSnapshot } from "../../extensions/types.js";

interface ExitReadsInput { mode: "exit-reads"; action: "delivered" | "clear" | "shutdown" | "replacement"; producer: "replay" | "live" | "orphan" | "mixed" }
type Input = ExitReadsInput | { mode: "restored-exit" } | { mode: "spawn" | "stop" | "matcher" | "wake-defaults"; platform?: string; resource?: boolean; caller?: "tool" | "shutdown" | "slash"; command?: string; stopFails?: boolean; killFails?: boolean; signalGone?: boolean };
const input: Input = JSON.parse(await Bun.stdin.text());
// The fixture's settings leave outputSettleMs and outputWakeBudgetMaxWakes
// unset, so output wakes run on the shipped defaults.
const OUTPUT_SETTLE_DEFAULT_MS = 2_000;
const effects = { ...input, deferLogOpens: input.mode === "exit-reads", identityGone: false };
const native = await interceptNativeEffects(effects);
const originalPlatform = Object.getOwnPropertyDescriptor(process, "platform")!;
const unused = () => { throw new Error("spawn_fixture.sdk_operation=unexpected_render"); };
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: readonly string[]) => ({ enum: values }) }));
mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, Optional: (value: unknown) => value, Number: () => ({}), String: () => ({}), Boolean: () => ({}) } }));
mock.module("@earendil-works/pi-tui", () => ({ matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused }));
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: () => ({ shell: "fixture-shell", args: ["-c"] }) }));
const { latestSnapshot } = await import("../../extensions/snapshot.js");

interface ToolResult { content: { type: string; text: string }[]; details: { action: string; task?: BackgroundTaskSnapshot } }
interface Tool { name: string; execute(id: string, params: Record<string, unknown>): Promise<ToolResult> }
const tools = new Map<string, Tool>();
const commands = new Map<string, { handler(args: string, ctx: ExtensionContext): unknown }>();
const events = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
const messages: unknown[] = [];
const notifications: unknown[] = [];

const ctx = {
	cwd: process.cwd(), hasUI: false, isProjectTrusted: () => true,
	sessionManager: { getSessionId: () => "spawn-hardening-private-session", getSessionFile: () => join(process.cwd(), "session.jsonl"), getBranch: () => [] },
	ui: { notify: (...args: unknown[]) => notifications.push(args), setWidget() {} },
} as unknown as ExtensionContext;
let currentCtx = ctx;
const pi = {
	registerTool(tool: Tool) { tools.set(tool.name, tool); },
	registerCommand(name: string, command: { handler(args: string, ctx: ExtensionContext): unknown }) { commands.set(name, command); }, registerShortcut() {}, registerMessageRenderer() {},
	on(event: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) { events.set(event, handler); },
	appendEntry() {},
	sendMessage: (...args: unknown[]) => messages.push(args),
} as unknown as ExtensionAPI;
let started = false;
let shutDown = false;
let spawnedSnapshot: BackgroundTaskSnapshot | undefined;
async function dispatch(event: string) {
	const handler = events.get(event);
	if (!handler) throw new Error(`spawn_fixture.event_missing=${event}`);
	await handler({}, currentCtx);
}
async function execute(params: Record<string, unknown>) {
	const tool = tools.get("bg_task");
	if (!tool) throw new Error("spawn_fixture.tool_missing=bg_task");
	return await tool.execute("private-tool-call", params);
}
async function state() {
	// The product accessor retains current status even when list details are a
	// bounded manifest or shutdown has released the live task collection.
	const task = latestSnapshot(spawnedSnapshot);
	if (!task) throw new Error("spawn_fixture.task_missing=bg-1");
	return { id: task.id, pid: task.pid, status: task.status, reason: task.terminationReason ?? null, exitCode: task.exitCode, exitNotified: task.exitNotified };
}
// A task with pending log text finalizes after its log flush, which the real
// file system finishes in real time.
async function finalized() {
	for (let waited = 0; waited < 5_000 && (await state()).status === "running"; waited += 1) await Bun.sleep(1);
}
async function restoredExits() {
	Object.defineProperty(process, "platform", { ...originalPlatform, value: "linux" });
	const tails = messages as [{ details: { outputTail: string; outputTailTruncated: boolean; eventType: string; task: { terminationReason?: string } } }][];
	const long = "x".repeat(4000) + "TAIL";
	const rows = [
		{ action: "delivered", output: long, truncated: true },
		{ action: "short", output: "TAIL", truncated: false },
		{ action: "exact", output: "x".repeat(1996) + "TAIL", truncated: false },
		{ action: "unicode", output: "😀".repeat(1000) + "TAIL", truncated: true },
		{ action: "orphan", output: long, truncated: true },
		{ action: "clear", output: long, truncated: true },
		{ action: "shutdown", output: long, truncated: true },
	] as const;
	for (const { action, output, truncated } of rows) {
		effects.identityGone = false;
		const logFile = `${process.cwd()}/${action}.log`;
		await writeFile(logFile, output);
		const before = tails.length;
		const task = { id: "bg-1", command: "restored", cwd: process.cwd(), exitCode: 0, exitNotified: false,
			logFile, notifyOnExit: true, notifyOnOutput: false, outputBytes: Buffer.byteLength(output),
			pid: action === "orphan" ? fixturePid : 0, sessionId: action, startedAt: 1,
			status: action === "orphan" ? "running" : "completed", title: "restored", updatedAt: 1,
			procIdent: { pid: fixturePid, comm: "fixture-child", startToken: "12345" } };
		currentCtx = { ...ctx, sessionManager: { getSessionId: () => action, getSessionFile: () => null,
			getBranch: () => [{ type: "custom", customType: "kendex-background-tasks:state", data: { tasks: [task] } }] } } as unknown as ExtensionContext;
		await dispatch("session_start");
		if (action === "clear") await execute({ action: "clear" });
		if (action === "shutdown") await dispatch("session_shutdown");
		if (action === "orphan") {
			assert.equal(tails.length, before, "a live restored orphan must not emit an exit");
			effects.identityGone = true;
			await native.fireInterval(30_000);
		}
		const suppressed = action === "clear" || action === "shutdown";
		// Real asynchronous file reads must finish before delivery or suppression checks.
		for (let waited = 0; waited < 100 && (suppressed || tails.length === before); waited += 1) await Bun.sleep(1);
		assert.equal(tails.length, before + (suppressed ? 0 : 1), action);
		if (!suppressed) {
			const tail = tails[before][0].details;
			assert.equal(tail.eventType, "exit");
			assert.ok(tail.outputTail.endsWith("TAIL"));
			assert.equal(tail.outputTailTruncated, truncated, `exit omission metadata: ${action}`);
			assert.equal(tail.outputTail.startsWith("[...truncated]\n"), truncated, `exit omission marker: ${action}`);
			assert.ok(tail.outputTail.length <= 2015);
			if (action === "delivered" || action === "orphan") assert.equal(tail.outputTail, "[...truncated]\n" + "x".repeat(1996) + "TAIL");
			if (action === "unicode") assert.equal(tail.outputTail, "[...truncated]\n" + "😀".repeat(998) + "TAIL", "restored exit character limit");
			if (!truncated) assert.equal(tail.outputTail, output);
			if (action === "orphan") assert.equal(tail.task.terminationReason, "orphaned-pid-gone");
		}
		if (action !== "shutdown") await dispatch("session_shutdown");
	}
	assert.equal(native.spawns.length, 0, "restore never spawns a command");
	return { delivered: tails.length };
}
async function exitReads(row: ExitReadsInput) {
	Object.defineProperty(process, "platform", { ...originalPlatform, value: "linux" });
	const { taskLogs } = await import("../../extensions/log-writer.js");
	const { sidecarStatePath } = await import("../../extensions/persistence.js");
	const { MAX_FINISHED_TASKS } = await import("../../extensions/constants.js");
	const { PROBE_CONCURRENCY } = await import("../../extensions/probes.js");
	const { DEFAULT_ORPHAN_POLL_MS } = await import("../../extensions/orphan-watcher.js");
	const savedTasks = () => (JSON.parse(readFileSync(sidecarStatePath(ctx), "utf8")) as { tasks: BackgroundTaskSnapshot[] }).tasks;
	const tails = () => (messages as [{ details: { eventType: string; outputTail: string; outputTailTruncated: boolean; task: BackgroundTaskSnapshot } }][]).map(([message]) => message.details);
	const count = 64;
	// Registered spawns produce the snapshots and logs for every exit path.
	for (let index = 0; index < count; index += 1) {
		await execute({ action: "spawn", command: "fixture-running", notifyOnExit: true, timeoutSeconds: 0 });
		if (row.producer !== "live") native.children[index].stdout.write("😀".repeat(4000) + "TAIL");
	}
	await taskLogs.drain();
	assert.equal(savedTasks().length, count);
	assert.ok(savedTasks().every((task) => task.status === "running" && !task.exitNotified));
	if (row.producer === "replay" || row.producer === "mixed") await dispatch("session_shutdown");
	const produced = savedTasks();
	assert.equal(produced.length, count);
	assert.ok(count > MAX_FINISHED_TASKS);
	assert.ok(produced.every((task) => !task.exitNotified && task.status === (row.producer === "live" || row.producer === "orphan" ? "running" : "stopped")
		&& task.terminationReason === (row.producer === "live" || row.producer === "orphan" ? undefined : "session-shutdown")));
	assert.equal(tails().length, 0);
	if (row.producer === "live") for (const child of native.children) child.emit("close", 0);
	else {
		await dispatch("session_start");
		if (row.producer === "orphan") { effects.identityGone = true; await native.fireInterval(DEFAULT_ORPHAN_POLL_MS); }
	}
	assert.equal(native.logOpens.requested.length, PROBE_CONCURRENCY, "exit acquisition must be bounded before any read settles");
	assert.equal(native.heldLogOpens(), PROBE_CONCURRENCY);
	assert.equal(tails().length, 0);
	assert.equal(savedTasks().length, count, "queued exits must remain protected from history eviction");
	assert.ok(savedTasks().every((task) => !task.exitNotified), "acquisition is not acknowledgement");
	const initial = native.logOpens.requested.length;
	if (row.action === "delivered") {
		let log: Promise<unknown> | undefined;
		if (row.producer === "mixed") {
			await execute({ action: "spawn", command: "quiet-live", notifyOnExit: true });
			native.children.at(-1)!.emit("close", 0);
			log = execute({ action: "log", id: "bg-65" });
		}
		const total = count + (log ? 1 : 0);
		for (let delivered = 0; delivered < total; delivered += 1) {
			assert.ok(native.heldLogOpens() > 0);
			native.releaseLogOpens(1);
			await waitForSpawnEffects(() => tails().length === delivered + 1, "exit read and delivery must settle");
			assert.ok(native.logOpens.maxActive <= PROBE_CONCURRENCY, "aggregate acquisition must stay bounded through delivery");
			const notified = new Set(tails().map((tail) => tail.task.id));
			const retained = new Set(savedTasks().map((task) => task.id));
			assert.ok(produced.every((task) => notified.has(task.id) || retained.has(task.id)), "queued exits must survive every history pass");
		}
		if (log) { await waitForSpawnEffects(() => native.heldLogOpens() === 1, "mixed tool read must acquire"); native.releaseLogOpens(); await log; }
		assert.equal(new Set(native.logOpens.requested).size, total, "each saved task reads once");
		assert.equal(new Set(tails().map((tail) => tail.task.id)).size, total, "each saved task delivers once");
		for (const tail of tails()) {
			const quiet = row.producer === "live" || tail.task.id === "bg-65";
			assert.equal(tail.eventType, "exit");
			assert.equal(tail.task.terminationReason, quiet ? "self-exit" : row.producer === "orphan" ? "orphaned-pid-gone" : "session-shutdown");
			assert.equal(tail.outputTail, quiet ? "" : "[...truncated]\n" + "😀".repeat(998) + "TAIL");
			assert.equal(tail.outputTailTruncated, !quiet);
		}
		assert.equal(savedTasks().length, MAX_FINISHED_TASKS);
		assert.ok(savedTasks().every((task) => task.exitNotified));
	} else {
		switch (row.action) {
			case "clear": await execute({ action: "clear" }); break;
			case "shutdown": await dispatch("session_shutdown"); break;
			case "replacement":
				currentCtx = { ...ctx, sessionManager: { ...ctx.sessionManager, getSessionId: () => "replacement", getSessionFile: () => join(process.cwd(), "replacement.jsonl") } } as unknown as ExtensionContext;
				await dispatch("session_start");
				await execute({ action: "spawn", command: "replacement-running", notifyOnExit: true });
				break;
			default: { const unreachable: never = row.action; throw new Error(`unknown exit action: ${unreachable}`); }
		}
		native.releaseLogOpens();
		await waitForSpawnEffects(() => native.logOpens.settled === initial, "suppressed active reads must settle");
		// Delivery and queued reader callbacks follow real file close.
		await Bun.sleep(1);
		assert.equal(native.logOpens.requested.length, initial, "suppressed queued tasks must not acquire a log");
		assert.equal(tails().length, 0, "suppressed active tasks must not deliver an exit");
	}
	assert.equal(native.logOpens.active, 0);
	return { action: row.action, produced: produced.length, initial, peak: native.logOpens.maxActive, acquired: native.logOpens.requested.length, delivered: tails().length, retained: savedTasks().length };
}
try {
	const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
	backgroundTasks(pi);
	await dispatch("session_start");
	started = true;
	if (input.mode === "restored-exit") process.stdout.write(JSON.stringify(await restoredExits()));
	else if (input.mode === "exit-reads") process.stdout.write(JSON.stringify(await exitReads(input)));
	else {
	// Only the platform-sensitive spawn call runs under this row's platform.
	if (input.platform) Object.defineProperty(process, "platform", { ...originalPlatform, value: input.platform });
	const matcherMode = input.mode === "matcher";
	const wakeMode = input.mode === "wake-defaults";
	const spawned = await execute({ action: "spawn", command: input.command ?? "fixture command", notifyOnExit: matcherMode,
		notifyOnOutput: matcherMode || wakeMode, notifyPattern: matcherMode ? `/${"a".repeat(1000)}(a+)+$/` : undefined });
	spawnedSnapshot = spawned.details.task;
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
	let matcherEvidence: unknown;
	let wakeEvidence: unknown;
	if (matcherMode) {
		let callbackCompletions = 0;
		const react = async (text: string) => {
			child.stdout.write(text);
			try { await native.fireTimeout(OUTPUT_SETTLE_DEFAULT_MS); }
			catch (error) { throw new Error("spawn_fixture.output_callback=rejected", { cause: error }); }
			callbackCompletions += 1;
			await execute({ action: "list" });
		};
		await react("a".repeat(1_000_000 - 1) + "!");
		const drops = latestSnapshot(spawnedSnapshot)!.wakeEvents!;
		assert.equal(drops.length, 1);
		assert.equal(drops[0].droppedReason, "notify-pattern-timeout");
		assert.equal(drops[0].deliveredAt, null);
		for (let index = 0; index < 20; index += 1) await react("\nsubsequent output");
		const emitted = messages as [{ details: { eventType: string; reason?: string; matchedPattern?: string; error?: string }; content: string }, { triggerTurn: boolean; deliverAs: string }][];
		assert.equal(emitted.length, 1, "matcher must report one notice without output wakes");
		assert.equal(emitted[0][0].details.eventType, "output-matcher-timeout");
		assert.equal(emitted[0][0].details.reason, "notify-pattern-timeout");
		assert.ok(emitted[0][0].details.error);
		assert.ok(emitted[0][0].details.matchedPattern!.length <= 192);
		assert.ok(Buffer.byteLength(JSON.stringify(emitted[0])) < 4096, "matcher notice must remain bounded");
		assert.equal(emitted[0][1].triggerTurn, true);
		assert.equal(emitted[0][1].deliverAs, "steer");
		assert.equal(latestSnapshot(spawnedSnapshot)!.outputWakeBudget!.wakes, 0);
		assert.equal(latestSnapshot(spawnedSnapshot)!.pendingWakes!.length, 0);
		assert.equal(callbackCompletions, 21);
		child.emit("close", 0);
		const { taskLogs } = await import("../../extensions/log-writer.js");
		await taskLogs.drain();
		assert.equal(emitted.length, 2, "matcher timeout must retain exit delivery");
		assert.equal(emitted[1][0].details.eventType, "exit");
		assert.equal(emitted[1][1].deliverAs, "followUp");
		assert.equal((await state()).exitNotified, true);
		matcherEvidence = { callbackCompletions, notices: emitted.filter(([message]) => message.details.eventType === "output-matcher-timeout").length,
			outputWakes: emitted.filter(([message]) => message.details.eventType === "output").length, exitWakes: emitted.filter(([message]) => message.details.eventType === "exit").length };
	}
	if (wakeMode) {
		// Each burst settles before the next, so each can wake the agent once.
		for (let index = 0; index < 12; index += 1) {
			child.stdout.write(`burst ${index}\n`);
			await native.fireTimeout(OUTPUT_SETTLE_DEFAULT_MS);
		}
		const emitted = messages as [{ details: { eventType: string } }][];
		wakeEvidence = { outputWakes: emitted.filter(([message]) => message.details.eventType === "output").length,
			budgetNotices: emitted.filter(([message]) => message.details.eventType === "output-budget-exhausted").length };
	}
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
			await finalized();
		}
	}
	if (input.mode === "spawn") child.emit("close", 0);
	const final = await state();
	// Log lines are written asynchronously; the drain lands them before the read.
	const { taskLogs } = await import("../../extensions/log-writer.js");
	await taskLogs.drain();
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
		fixtureNow, fixturePid, matcherEvidence, wakeEvidence,
	}));
	}
} finally {
	Object.defineProperty(process, "platform", originalPlatform);
	try { if (started && !shutDown) await dispatch("session_shutdown"); }
	finally { native.restore(); }
}
