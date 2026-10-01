import assert from "node:assert/strict";
import test, { after } from "node:test";
import { runParallelDispatch } from "../extensions/subagent/dispatch.js";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { clearPackageConfigCache } from "../extensions/subagent/package-config.js";
import { cleanupTempRuntimes, importMainRuntime, importRuntimeCopy } from "./browser-fixture.js";
import { makeDetails, mockPiEvents, observeChildSpawns, tempRuntime, testAgent, writeSettings } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

async function dispatchMeasurement(dispatch: typeof runParallelDispatch, setSpawn: typeof setSingleAgentSpawnForTests) {
	const cwd = tempRuntime();
	writeSettings(cwd, { maxConcurrency: 2, bgTaskTimeoutMs: 10_000 });
	const pi = mockPiEvents([]);
	const observed = observeChildSpawns(cwd);
	setSpawn(observed.spawner);
	try {
		const flow = { agents: [testAgent()], cwd, runtimeRoot: cwd, parentSessionId: "benchmark", pi,
			makeDetails: () => makeDetails, removeDashboardAgent() {}, updateDashboard() {} };
		const task = { agent: testAgent().name, task: "inspect" };
		const started = performance.now();
		const results = await Promise.all(Array.from({ length: 5 }, () => dispatch({ ...flow, tasks: [task, task] })));
		const elapsedMs = performance.now() - started;
		assert.deepEqual(results.map((result) => result.details.results.map((child) => child.exitCode)), Array.from({ length: 5 }, () => [0, 0]));
		assert.equal(observed.counts().launches, 10);
		assert.equal(observed.counts().active, 0);
		return { elapsedMs: Math.round(elapsedMs), ...observed.counts() };
	} finally {
		observed.stop();
		setSpawn();
	}
}

test("component benchmark: five parallel dispatches share a child cap", async () => {
	const main = await importMainRuntime();
	const previous = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = tempRuntime();
	clearPackageConfigCache();
	main.config.clearPackageConfigCache();
	try {
		const before = await dispatchMeasurement(main.dispatch.runParallelDispatch, main.runner.setSingleAgentSpawnForTests);
		const after = await dispatchMeasurement(runParallelDispatch, setSingleAgentSpawnForTests);
		console.log(`dispatch-benchmark ${JSON.stringify({ main: main.ref, before, after, calls: 5, tasksPerCall: 2, cap: 2 })}`);
		assert.ok(before.peak > 2, "main must expose independent per-call caps");
		assert.equal(after.peak, 2, "shared cap must bound peak children");
		const mutant = await importRuntimeCopy("dispatch.ts",
			"const result = await withChildBudget(flow.pi, flow.cwd, flow.signal, async () => runsInPane(taskAgent, lane)",
			"const result = await (async () => runsInPane(taskAgent, lane)",
			[{ before: "\t\t\t\t\t\tt.sessionKey,\n\t\t\t\t\t\tt.sameSession ?? flow.sameSession,\n\t\t\t\t\t));", after: "\t\t\t\t\t\tt.sessionKey,\n\t\t\t\t\t\tt.sameSession ?? flow.sameSession,\n\t\t\t\t\t))();" }],
		) as typeof import("../extensions/subagent/dispatch.js");
		const control = await dispatchMeasurement(mutant.runParallelDispatch, setSingleAgentSpawnForTests);
		assert.throws(() => assert.equal(control.peak, 2, "shared cap must bound peak children"), /shared cap must bound/);
		console.log(`dispatch-benchmark control=${JSON.stringify(control)}`);
	} finally {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
		clearPackageConfigCache();
		main.config.clearPackageConfigCache();
	}
});
