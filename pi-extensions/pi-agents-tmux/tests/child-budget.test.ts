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
		let closed = false;
		const closing = shutdown().then(() => { closed = true; });
		await new Promise(setImmediate);
		assert.equal(signal?.aborted, true, "shutdown must cancel active work");
		assert.equal(closed, false, "shutdown must drain active work");
		finish();
		await closing;
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
	const live = await importRuntimeCopy("child-budget.ts", 'this.shutdown.abort(new Error("Child dispatch session shut down"));', 'void new Error("Child dispatch session shut down");') as typeof import("../extensions/subagent/child-budget.js");
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

async function queuedCancellation(run: typeof withChildBudget): Promise<void> {
	const cwd = tempRuntime();
	writeSettings(cwd, { maxConcurrency: 1 });
	let release!: () => void;
	const held = run(mockPi, cwd, undefined, () => new Promise<void>((resolve) => { release = resolve; }));
	const controller = new AbortController();
	let settled = false;
	const queued = run(mockPi, cwd, controller.signal, async () => {}).then(() => { settled = true; }, () => { settled = true; });
	try {
		await new Promise(setImmediate);
		controller.abort(new Error("cancel queued"));
		await new Promise(setImmediate);
		assert.equal(settled, true, "queued cancellation must settle while another slot is held");
	} finally { release(); await Promise.all([held, queued]); }
}
const mockPi = mockPiEvents([]);

test("queued cancellation settles independently of active work", async () => {
	await queuedCancellation(withChildBudget);
	const copy = await importRuntimeCopy("child-budget.ts", 'signal.addEventListener("abort", waiter.abort, { once: true });', 'if (false) signal.addEventListener("abort", waiter.abort, { once: true });') as typeof import("../extensions/subagent/child-budget.js");
	await assert.rejects(queuedCancellation(copy.withChildBudget), /queued cancellation must settle/);
});

async function modeAdmission(dispatch: typeof import("../extensions/subagent/dispatch.js"), mode: "single" | "chain"): Promise<void> {
	const cwd = tempRuntime();
	writeSettings(cwd, { maxConcurrency: 1 });
	const pi = mockPiEvents([]);
	let release!: () => void;
	const held = withChildBudget(pi, cwd, undefined, () => new Promise<void>((resolve) => { release = resolve; }));
	let spawned!: () => void;
	const started = new Promise<void>((resolve) => { spawned = resolve; });
	const spawns = installMockSpawn([{ defer(finish) { spawned(); queueMicrotask(finish); } }]);
	const flow = { agents: [testAgent()], cwd, runtimeRoot: cwd, parentSessionId: "parent", pi,
		makeDetails: () => makeDetails, removeDashboardAgent() {}, updateDashboard() {} };
	const task = { agent: testAgent().name, task: "inspect" };
	const call = mode === "single" ? dispatch.runSingleDispatch({ ...flow, ...task }) : dispatch.runChainDispatch({ ...flow, chain: [task] });
	try {
		// The real runner awaits session and transcript filesystem writes before
		// spawn. Observe that boundary while the unrelated slot remains held.
		await Promise.race([started, new Promise((resolve) => setTimeout(resolve, 200))]);
		assert.equal(spawns.length, 0, `${mode} must wait for shared admission`);
	}
	finally { release(); await Promise.all([held, call]); }
	assert.equal(spawns.length, 1, `${mode} must execute after admission`);
}

test("single and chain admission have independent controls", async () => {
	const runtime = await import("../extensions/subagent/dispatch.js");
	for (const [mode, start, end] of [
		["single", "const result = await withChildBudget(flow.pi, flow.cwd, flow.signal, async () => runsInPane(agent, lane)", "\t\t\t\tflow.sessionKey,\n\t\t\t\tflow.sameSession,\n\t\t\t));"],
		["chain", "const result = await withChildBudget(flow.pi, flow.cwd, flow.signal, async () => runsInPane(stepAgent, lane)", "\t\t\t\t\tstep.sessionKey,\n\t\t\t\t\tstep.sameSession ?? flow.sameSession,\n\t\t\t\t));"],
	] as const) {
		await modeAdmission(runtime, mode);
		const mutant = await importRuntimeCopy("dispatch.ts", start, start.replace("withChildBudget(flow.pi, flow.cwd, flow.signal, async () =>", "(async () =>"), [{ before: end, after: end.replace("));", "))();") }]) as typeof runtime;
		await assert.rejects(modeAdmission(mutant, mode), /must wait for shared admission/);
	}
});

async function shutdownRunner(runner: typeof import("../extensions/subagent/runner.js"), dispatch = false): Promise<void> {
	const { spawn } = await import("node:child_process");
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 10_000 });
	let shutdown!: () => Promise<void>;
	const pi = mockPiEvents([]);
	pi.on = (_event: string, handler: () => Promise<void>) => { shutdown = handler; return () => {}; };
	let ready!: () => void;
	const started = new Promise<void>((resolve) => { ready = resolve; });
	let child: ReturnType<typeof spawn> | undefined;
	runner.setSingleAgentSpawnForTests(((_cmd, _args, options) => {
		child = spawn(process.execPath, ["-e", 'process.on("SIGTERM", () => {}); console.log("ready"); setTimeout(() => console.log("natural-exit"), 2000)'], { ...options, env: { PATH: "/usr/bin:/bin", HOME: cwd, TMPDIR: cwd } });
		child.stdout!.once("data", ready);
		return child;
	}) as typeof spawn);
	runner.setBgTimeoutKillGraceMsForTests(20);
	let output = "";
	const agent = testAgent();
	const call = dispatch ? runSingleDispatch({ agents: [agent], cwd, runtimeRoot: cwd, parentSessionId: "parent", pi,
		makeDetails: () => makeDetails, removeDashboardAgent() {}, updateDashboard() {}, agent: agent.name, task: "inspect" })
		: withChildBudget(pi, cwd, undefined, () => runner.runSingleAgent(cwd, cwd, [agent], agent.name, "inspect", undefined, undefined, undefined, undefined, pi, undefined, undefined, makeDetails));
	const settled = Promise.allSettled([call]);
	try {
		await started;
		child!.stdout!.on("data", (data) => { output += String(data); });
		await shutdown();
		const [outcome] = await settled;
		if (outcome.status === "rejected") assert.match(String(outcome.reason), /Agent was aborted/);
		assert.ok(!output.includes("natural-exit"), "shutdown must reach runner without an explicit child signal");
		assert.throws(() => process.kill(child!.pid!, 0), { code: "ESRCH" });
	} finally {
		child?.kill("SIGKILL");
		await settled;
		runner.setSingleAgentSpawnForTests();
		runner.setBgTimeoutKillGraceMsForTests();
	}
}

test("shutdown propagates through dispatch into the runner", async () => {
	const runtime = await import("../extensions/subagent/runner.js");
	await shutdownRunner(runtime, true);
	const mutant = await importRuntimeCopy("runner.ts", "signal = childSignal() ?? signal;", "void childSignal;") as typeof runtime;
	await assert.rejects(shutdownRunner(mutant), /shutdown must reach runner/);
	const undrained = await importRuntimeCopy("child-budget.ts", "await Promise.allSettled(this.pending);", "void this.pending;") as typeof import("../extensions/subagent/child-budget.js");
	await assert.rejects(shutdownBudget(undrained), /shutdown must drain active work/);
});
