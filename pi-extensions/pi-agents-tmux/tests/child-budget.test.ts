import assert from "node:assert/strict";
import test, { after, afterEach } from "node:test";
import { withChildBudget } from "../extensions/subagent/child-budget.js";
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
