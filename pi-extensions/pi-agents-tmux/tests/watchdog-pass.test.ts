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
