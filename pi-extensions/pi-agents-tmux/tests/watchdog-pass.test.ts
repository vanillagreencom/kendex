import assert from "node:assert/strict";
import test, { after } from "node:test";
import { createIdleStallWatchdog } from "../extensions/subagent/idle-stall-watchdog.js";
import { cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

async function sharedPass(create: typeof createIdleStallWatchdog): Promise<void> {
	let release!: () => void;
	const gate = new Promise<void>((resolve) => { release = resolve; });
	let lists = 0;
	const watchdog = create({ intervalMs: 1000, thresholdMs: 0, isEnabled: () => true, now: () => 0,
		isAwaitingRateLimitRetry: () => false,
		listActiveTasks: async () => { lists++; await gate; return []; }, outboxExists: async () => false,
		outboxPathFor: () => "unused", isPaneIdle: async () => false, lastActivityAt: () => 0,
		writeSyntheticOutbox: async () => {}, markFired: async () => {}, logWarn() {} });
	const first = watchdog.checkAll();
	const second = watchdog.checkAll();
	try { assert.equal(lists, 1); }
	finally { release(); await Promise.all([first, second]); }
	await watchdog.checkAll();
	assert.equal(lists, 2);
}

test("watchdog passes cannot overlap when a probe stalls", async () => {
	await sharedPass(createIdleStallWatchdog);
	const mutant = await importRuntimeCopy("idle-stall-watchdog.ts", "if (passInFlight) return passInFlight;", "if (passInFlight) void 0;") as typeof import("../extensions/subagent/idle-stall-watchdog.js");
	await assert.rejects(sharedPass(mutant.createIdleStallWatchdog), /2 !== 1/);
});

async function shutdownPass(create: typeof createIdleStallWatchdog): Promise<void> {
	let release!: () => void;
	let signal: AbortSignal | undefined;
	const gate = new Promise<void>((resolve) => { release = resolve; });
	const record = { taskId: "task", agent: "engineer", task: "inspect", status: "running" as const, createdAt: "2026-10-01T00:00:00Z" };
	const watchdog = create({ intervalMs: 1000, thresholdMs: 0, isEnabled: () => true, now: () => 0,
		isAwaitingRateLimitRetry: () => false,
		listActiveTasks: async () => [record], outboxExists: async () => false, outboxPathFor: () => "unused",
		isPaneIdle: async (_record, cancellation) => { signal = cancellation; await gate; return false; }, lastActivityAt: () => 0,
		writeSyntheticOutbox: async () => {}, markFired: async () => {}, logWarn() {} });
	const pass = watchdog.checkAll();
	let stopped = false;
	let closing: Promise<void> | undefined;
	try {
		await new Promise(setImmediate);
		closing = watchdog.stop().then(() => { stopped = true; });
		await new Promise(setImmediate);
		assert.equal(signal?.aborted, true, "watchdog shutdown must cancel its current probe");
		assert.equal(stopped, false, "watchdog shutdown must drain its current pass");
	} finally { release(); await Promise.all([pass, closing]); }
}

test("watchdog shutdown cancels and drains its active pass", async () => {
	await shutdownPass(createIdleStallWatchdog);
	for (const [before, after, reason] of [
		['cancellation.abort(new Error("Idle watchdog shut down"));', 'void cancellation;', /must cancel its current probe/],
		['await passInFlight;', 'void passInFlight;', /must drain its current pass/],
	] as const) {
		const mutant = await importRuntimeCopy("idle-stall-watchdog.ts", before, after) as typeof import("../extensions/subagent/idle-stall-watchdog.js");
		await assert.rejects(shutdownPass(mutant.createIdleStallWatchdog), reason);
	}
});
