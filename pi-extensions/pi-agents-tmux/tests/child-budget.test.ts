import assert from "node:assert/strict";
import test, { after, afterEach } from "node:test";
import { withChildBudget, childSignal } from "../extensions/subagent/child-budget.js";
import { runChainDispatch, runParallelDispatch, runSingleDispatch } from "../extensions/subagent/dispatch.js";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";
import { installMockSpawn, makeDetails, mockPiEvents, tempRuntime, testAgent, writeSettings } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);
afterEach(() => setSingleAgentSpawnForTests());

async function budgetBound(run: typeof withChildBudget): Promise<void> {
	const cwd = tempRuntime();
	writeSettings(cwd, { maxConcurrency: 2 });
	const pi = mockPiEvents([]);
	let started = 0;
	let finish!: () => void;
	const gate = new Promise<void>((resolve) => { finish = resolve; });
	const calls = Array.from({ length: 5 }, () => run(pi, cwd, undefined, async () => { started++; await gate; }));
	try {
		await new Promise(setImmediate);
		assert.equal(started, 2);
	} finally {
		finish();
		await Promise.all(calls);
	}
}

test("one abort-aware budget admits work across calls", async () => {
	await budgetBound(withChildBudget);
	const mutant = await importRuntimeCopy("child-budget.ts", "if (this.active >= limit) return;", "if (this.active >= limit) void 0;") as typeof import("../extensions/subagent/child-budget.js");
	await assert.rejects(budgetBound(mutant.withChildBudget), /5 !== 2/);
});

async function pendingBound(run: typeof withChildBudget): Promise<void> {
	const cwd = tempRuntime();
	writeSettings(cwd, { maxConcurrency: 1 });
	const pi = mockPiEvents([]);
	let finish!: () => void;
	const gate = new Promise<void>((resolve) => { finish = resolve; });
	const active = run(pi, cwd, undefined, () => gate);
	let refused = 0;
	const queued = Array.from({ length: 257 }, () => run(pi, cwd, undefined, () => gate).catch((error) => {
		assert.match(String(error), /pending limit=256/);
		refused++;
	}));
	try {
		await new Promise(setImmediate);
		assert.equal(refused, 1, "pending work must be bounded");
	} finally {
		finish();
		await Promise.all([active, ...queued]);
	}
}

async function cancelledAdmission(run: typeof withChildBudget): Promise<void> {
	const cwd = tempRuntime();
	const controller = new AbortController();
	let launched = 0;
	const call = run(mockPiEvents([]), cwd, controller.signal, async () => { launched++; });
	const settled = Promise.allSettled([call]);
	// Admission is synchronous, but action begins on the next microtask. Pi can
	// cancel the tool in that gap, before the runner's separate pre-spawn check.
	controller.abort(new Error("cancelled-after-admission"));
	await settled;
	assert.equal(launched, 0, "cancelled admission must not execute");
}

async function shutdownBudget(runtime: { withChildBudget: typeof withChildBudget; childSignal: typeof childSignal }): Promise<void> {
	const cwd = tempRuntime();
	writeSettings(cwd, { maxConcurrency: 1 });
	let shutdown!: () => Promise<void>;
	const pi = mockPiEvents([]);
	pi.on = (_event: string, handler: () => Promise<void>) => { shutdown = handler; return () => {}; };
	let signal: AbortSignal | undefined;
	let finish!: () => void;
	const gate = new Promise<void>((resolve) => { finish = resolve; });
	const active = runtime.withChildBudget(pi, cwd, undefined, async () => { signal = runtime.childSignal(); await gate; });
	let launched = 0;
	const queued = runtime.withChildBudget(pi, cwd, undefined, async () => { launched++; });
	const settled = Promise.allSettled([active, queued]);
	try {
		await new Promise(setImmediate);
		await shutdown();
		assert.equal(signal?.aborted, true, "shutdown must cancel active work");
	} finally {
		finish();
		await settled;
	}
	assert.equal(launched, 0, "shutdown must cancel queued work");
}

test("pending work, post-admission cancellation and shutdown guards have controls", async () => {
	await pendingBound(withChildBudget);
	const unbounded = await importRuntimeCopy("child-budget.ts", "if (this.queued.length >= 256)", "if (this.queued.length >= 257)") as typeof import("../extensions/subagent/child-budget.js");
	await assert.rejects(pendingBound(unbounded.withChildBudget), /pending work must be bounded/);
	await cancelledAdmission(withChildBudget);
	const late = await importRuntimeCopy("child-budget.ts", "try {\n\t\t\tsignal.throwIfAborted();", "try {\n\t\t\tvoid signal.aborted;") as typeof import("../extensions/subagent/child-budget.js");
	await assert.rejects(cancelledAdmission(late.withChildBudget), /cancelled admission must not execute/);
	await shutdownBudget({ withChildBudget, childSignal });
	const live = await importRuntimeCopy("child-budget.ts", 'owner.shutdown.abort(new Error("Child dispatch session shut down"));', 'void new Error("Child dispatch session shut down");') as typeof import("../extensions/subagent/child-budget.js");
	await assert.rejects(shutdownBudget(live), /shutdown must cancel active work/);
});

test("five parallel dispatches share one cap; single and chain modes use it too", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { maxConcurrency: 2 });
	const events: Array<{ name: string; payload: unknown }> = [];
	const pi = mockPiEvents(events);
	const controller = new AbortController();
	let opened = 0;
	let firstTwo!: () => void;
	const ready = new Promise<void>((resolve) => { firstTwo = resolve; });
	const closes: Array<() => void> = [];
	const spawns = installMockSpawn(Array.from({ length: 12 }, () => ({ defer(finish) {
		closes.push(finish);
		if (++opened === 2) firstTwo();
	} })));
	const flow = { agents: [testAgent()], cwd, runtimeRoot: cwd, parentSessionId: "parent", pi,
		makeDetails: () => makeDetails, removeDashboardAgent() {}, updateDashboard() {}, signal: controller.signal };
	const task = { agent: testAgent().name, task: "inspect" };
	const calls = [
		...Array.from({ length: 5 }, () => runParallelDispatch({ ...flow, tasks: [task, task] })),
		runSingleDispatch({ ...flow, ...task }), runChainDispatch({ ...flow, chain: [task] }),
	];
	// Observe rejections immediately, as Pi does when a tool fails.
	const settled = Promise.allSettled(calls);
	await ready;
	await new Promise(setImmediate);
	assert.equal(spawns.length, 2);
	controller.abort(new Error("cancel queued dispatches"));
	for (const close of closes) close();
	await settled;
	assert.equal(spawns.length, 2, "cancelled queues must not launch a replacement child");
});
