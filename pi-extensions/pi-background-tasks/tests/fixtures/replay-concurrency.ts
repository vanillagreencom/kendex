import { mock } from "bun:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { BackgroundTaskSnapshot } from "../../extensions/types.js";
import { interceptNativeEffects } from "./spawn-native.js";
import { waitForSpawnEffects } from "./spawn-child-runner.js";

const input: { action: "delivered" | "clear" | "shutdown" | "replacement" } = JSON.parse(await Bun.stdin.text());
const native = await interceptNativeEffects({ deferLogOpens: true });
const platform = Object.getOwnPropertyDescriptor(process, "platform")!;
Object.defineProperty(process, "platform", { ...platform, value: "linux" });
const unused = () => { throw new Error("replay-concurrency reached an unrelated operation"); };
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: string[]) => ({ enum: values }) }));
mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, Optional: (value: unknown) => value, Number: () => ({}), String: () => ({}), Boolean: () => ({}) } }));
mock.module("@earendil-works/pi-tui", () => ({ matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused }));
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: () => ({ shell: "fixture-shell", args: ["-c"] }) }));
const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
const { taskLogs } = await import("../../extensions/log-writer.js");
const { sidecarStatePath } = await import("../../extensions/persistence.js");
const { MAX_FINISHED_TASKS } = await import("../../extensions/constants.js");
const { PROBE_CONCURRENCY } = await import("../../extensions/probes.js");
const events = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
interface Tool { name: string; execute(id: string, params: Record<string, unknown>): Promise<unknown> }
let tool: Tool | undefined;
const tails: { eventType: string; outputTail: string; outputTailTruncated: boolean; task: BackgroundTaskSnapshot }[] = [];
const pi = {
	on: (name: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => events.set(name, handler),
	registerTool: (registered: Tool) => { if (registered.name === "bg_task") tool = registered; },
	registerCommand() {}, registerShortcut() {}, registerMessageRenderer() {}, appendEntry() {},
	sendMessage: (message: { details: (typeof tails)[number] }) => tails.push(message.details),
} as unknown as ExtensionAPI;
const ctx = {
	cwd: process.cwd(), hasUI: false, isProjectTrusted: () => true,
	sessionManager: { getSessionId: () => "replay-producer", getSessionFile: () => join(process.cwd(), "session.jsonl"), getBranch: () => [] },
	ui: { notify() {}, setWidget() {} },
} as unknown as ExtensionContext;
const savedTasks = () => (JSON.parse(readFileSync(sidecarStatePath(ctx), "utf8")) as { tasks: BackgroundTaskSnapshot[] }).tasks;
const count = 64;
const output = "😀".repeat(4000) + "TAIL";
let currentCtx = ctx;
try {
	backgroundTasks(pi);
	await events.get("session_start")!({}, ctx);
	assert.ok(tool, "registered bg_task producer");
	// Registered spawns and clean shutdown, not a hand-authored oversized manifest.
	for (let index = 0; index < count; index += 1) {
		await tool.execute(`spawn-${index}`, { action: "spawn", command: "fixture-running", notifyOnExit: true, timeoutSeconds: 0 });
		native.children[index].stdout.write(output);
	}
	await taskLogs.drain();
	assert.equal(savedTasks().length, count);
	assert.ok(savedTasks().every((task) => task.status === "running" && !task.exitNotified));
	await events.get("session_shutdown")!({}, ctx);
	const produced = savedTasks();
	assert.equal(produced.length, count);
	assert.ok(count > MAX_FINISHED_TASKS);
	assert.ok(produced.every((task) => task.status === "stopped" && !task.exitNotified && task.terminationReason === "session-shutdown"));
	assert.equal(tails.length, 0);
	await events.get("session_start")!({}, ctx);
	assert.equal(native.logOpens.requested.length, PROBE_CONCURRENCY, "replay acquisition must be bounded before any read settles");
	assert.equal(native.heldLogOpens(), PROBE_CONCURRENCY);
	assert.equal(tails.length, 0);
	assert.equal(savedTasks().length, count, "queued exits must remain protected from history eviction");
	const initial = native.logOpens.requested.length;
	if (input.action === "delivered") {
		for (let delivered = 0; delivered < count; delivered += 1) {
			assert.ok(native.heldLogOpens() > 0);
			native.releaseLogOpens(1);
			await waitForSpawnEffects(() => tails.length === delivered + 1, "exit read and delivery must settle");
			assert.ok(native.logOpens.maxActive <= PROBE_CONCURRENCY, "replay acquisition must stay bounded through delivery");
			const notified = new Set(tails.map((tail) => tail.task.id));
			const retained = new Set(savedTasks().map((task) => task.id));
			assert.ok(produced.every((task) => notified.has(task.id) || retained.has(task.id)), "queued exits must survive every history pass");
		}
		assert.equal(new Set(native.logOpens.requested).size, count, "each saved task reads once");
		assert.equal(new Set(tails.map((tail) => tail.task.id)).size, count, "each saved task delivers once");
		for (const tail of tails) {
			assert.equal(tail.eventType, "exit");
			assert.equal(tail.task.terminationReason, "session-shutdown");
			assert.equal(tail.outputTail, "[...truncated]\n" + "😀".repeat(998) + "TAIL");
			assert.equal(tail.outputTailTruncated, true);
		}
		assert.equal(savedTasks().length, MAX_FINISHED_TASKS);
		assert.ok(savedTasks().every((task) => task.exitNotified));
	} else {
		switch (input.action) {
			case "clear": await tool.execute("clear", { action: "clear" }); break;
			case "shutdown": await events.get("session_shutdown")!({}, ctx); break;
			case "replacement": {
				currentCtx = { ...ctx, sessionManager: { ...ctx.sessionManager, getSessionId: () => "replacement", getSessionFile: () => join(process.cwd(), "replacement.jsonl") } } as unknown as ExtensionContext;
				await events.get("session_start")!({}, currentCtx);
				await tool.execute("replacement-spawn", { action: "spawn", command: "replacement-running", notifyOnExit: true });
				break;
			}
			default: { const unreachable: never = input.action; throw new Error(`unknown replay action: ${unreachable}`); }
		}
		native.releaseLogOpens();
		await waitForSpawnEffects(() => native.logOpens.settled === initial, "suppressed active reads must settle");
		// Allow delivery and the queued mapper callbacks to run after file close.
		await Bun.sleep(1);
		assert.equal(native.logOpens.requested.length, initial, "suppressed queued tasks must not acquire a log");
		assert.equal(tails.length, 0, "suppressed active tasks must not deliver an exit");
	}
	assert.equal(native.logOpens.active, 0);
	process.stdout.write(JSON.stringify({ action: input.action, produced: produced.length, initial, peak: native.logOpens.maxActive, acquired: native.logOpens.requested.length, delivered: tails.length, retained: savedTasks().length }));
} finally {
	await events.get("session_shutdown")!({}, currentCtx);
	Object.defineProperty(process, "platform", platform);
	native.restore();
}
