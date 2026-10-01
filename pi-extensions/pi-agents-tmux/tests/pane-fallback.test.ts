// Where a `pane: true` agent runs when the dispatcher probes tmux: headless
// through the one-shot runner when no server answers, in a pane when one
// does, and refused under `paneOnly`. Also how `stop_subagent` retires an
// agent whose latest task ran headless.

import assert from "node:assert/strict";
import { join } from "node:path";
import test, { after, afterEach } from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import { runChainDispatch, runParallelDispatch, runSingleDispatch } from "../extensions/subagent/dispatch.js";
import { retireSubagent, setPaneExecCaptureForTests } from "../extensions/subagent/pane.js";
import { registerPaneSupportTools } from "../extensions/subagent/pane-support-tools.js";
import { setBgTimeoutKillGraceMsForTests, setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { upsertTaskRecord, writePaneRegistry } from "../extensions/subagent/tasks.js";
import { PANE_LAUNCHER_VERSION, type SingleResult } from "../extensions/subagent/types.js";
import { bridgeEvent, bridgeStdout, cleanupTempRuntimes, installLifecycleMockSpawn, installMockSpawn, makeDetails, mockPiEvents, tempRuntime, testAgent, writeSettings } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

const suiteTmux = process.env.TMUX;
afterEach(() => {
	if (suiteTmux === undefined) delete process.env.TMUX;
	else process.env.TMUX = suiteTmux;
	setPaneExecCaptureForTests();
	setSingleAgentSpawnForTests();
	setBgTimeoutKillGraceMsForTests();
});

const NOTICE = "pane-fallback reason=no-tmux";

function paneAgent(): AgentConfig {
	return { name: "generalist", description: "maintenance", pane: true, source: "project", systemPrompt: "", filePath: "generalist.md" };
}

const agents = [paneAgent(), testAgent()];

function flow(runtimeRoot: string, mode: "single" | "parallel" | "chain", paneOnly = false) {
	return {
		agents,
		cwd: runtimeRoot,
		makeDetails: (_mode: typeof mode) => makeDetails,
		paneOnly,
		parentSessionId: "parent-session",
		pi: mockPiEvents([]),
		removeDashboardAgent: () => undefined,
		runtimeRoot,
		updateDashboard: () => undefined,
	};
}

function dispatchSingle(runtimeRoot: string, paneOnly = false) {
	return runSingleDispatch({ ...flow(runtimeRoot, "single", paneOnly), agent: "generalist", task: "tidy the docs" });
}

// Records every tmux call; `split-window` is the pane launch and fails with a
// planted message, so a pane dispatch stops there without starting a Pi.
function recordTmux(serverAnswers: boolean): string[][] {
	const calls: string[][] = [];
	setPaneExecCaptureForTests(async (_command, args) => {
		calls.push(args);
		if (!serverAnswers) return { code: 1, stdout: "", stderr: "no server running on /tmp/tmux-test/default" };
		if (args[0] === "split-window") return { code: 1, stdout: "", stderr: "planted split-window refusal" };
		const target = args.indexOf("-t");
		return { code: 0, stdout: `${target >= 0 ? args[target + 1] : "%0"}\n`, stderr: "" };
	});
	return calls;
}

const finished = () => ({ stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "docs tidied" }] } })]) });

function taskIdLines(text: string): string[] {
	return text.split("\n").filter((line) => line.startsWith("Task ID: "));
}

function resultFor(results: SingleResult[], agent: string): SingleResult {
	const found = results.find((result) => result.agent === agent);
	assert.ok(found, `no result for ${agent}`);
	return found;
}

for (const row of [
	{ label: "$TMUX is unset", cause: /\$TMUX is unset/, probed: false, setup: () => delete process.env.TMUX },
	{ label: "the named tmux server does not answer", cause: /tmux is unavailable: no server running/, probed: true, setup: () => (process.env.TMUX = "/tmp/tmux-test/default,1,0") },
]) {
	test(`a pane agent runs headless and returns its result when ${row.label}`, async () => {
		row.setup();
		const tmuxCalls = recordTmux(false);
		const spawns = installMockSpawn([finished()]);

		const result = await dispatchSingle(tempRuntime());

		const [notice, cause] = result.content[0].text.split("\n");
		assert.equal(notice, NOTICE);
		assert.match(cause, row.cause);
		assert.match(cause, /Pane agents ran headless as background one-shot processes: generalist\.$/);
		assert.equal(tmuxCalls.some((args) => args[0] === "display-message"), row.probed);
		const outcome = result.details.results[0];
		assert.deepEqual(taskIdLines(result.content[0].text), [`Task ID: ${outcome.taskId}`]);
		assert.match(result.content[0].text, /docs tidied$/);
		assert.equal(outcome.kind, "oneshot");
		assert.equal(result.isError, undefined);
		assert.equal(spawns.length, 1);
	});
}

for (const [mode, dispatch] of [
	["parallel", (runtimeRoot: string) => runParallelDispatch({ ...flow(runtimeRoot, "parallel"), tasks: [{ agent: "generalist", task: "tidy the docs" }, { agent: "reviewer-test", task: "review code" }] })],
	["chain", (runtimeRoot: string) => runChainDispatch({ ...flow(runtimeRoot, "chain"), chain: [{ agent: "generalist", task: "tidy the docs" }, { agent: "reviewer-test", task: "review {previous}" }] })],
] as const) {
	test(`a ${mode} dispatch notes the fallback once and names only the pane agent's task`, async () => {
		delete process.env.TMUX;
		const spawns = installMockSpawn([finished(), finished()]);

		const result = await dispatch(tempRuntime());

		const text = result.content[0].text;
		assert.equal(text.split(NOTICE).length, 2);
		assert.match(text.split("\n")[1], /one-shot processes: generalist\.$/);
		assert.deepEqual(taskIdLines(text), [`Task ID: ${resultFor(result.details.results, "generalist").taskId}`]);
		assert.equal(spawns.length, 2);
	});
}

test("headless pane and background agents both keep the process deadline", async () => {
	delete process.env.TMUX;
	const runtimeRoot = tempRuntime();
	writeSettings(runtimeRoot, { bgTaskTimeoutMs: 5 });
	setBgTimeoutKillGraceMsForTests(1);
	// Both children answer after 60 ms, well past the 5 ms deadline.
	installLifecycleMockSpawn({ closeAfterMs: 60, stdout: finished().stdout });

	const result = await runParallelDispatch({ ...flow(runtimeRoot, "parallel"), tasks: [{ agent: "generalist", task: "tidy the docs" }, { agent: "reviewer-test", task: "review code" }] });

	const headless = resultFor(result.details.results, "generalist");
	assert.equal(headless.stopReason, "unresponsive_timeout");
	assert.equal(headless.exitCode, 1);
	assert.equal(resultFor(result.details.results, "reviewer-test").stopReason, "unresponsive_timeout");
});

test("a pane agent keeps its pane where the tmux server answers", async () => {
	const tmuxCalls = recordTmux(true);
	const spawns = installMockSpawn([finished()]);

	await assert.rejects(dispatchSingle(tempRuntime()), /planted split-window refusal/);

	assert.ok(tmuxCalls.some((args) => args[0] === "split-window"));
	assert.equal(spawns.length, 0);
});

test("paneOnly refuses a pane agent where no tmux server is reachable", async () => {
	delete process.env.TMUX;
	const spawns = installMockSpawn([finished()]);

	await assert.rejects(dispatchSingle(tempRuntime(), true), /Persistent pane agents require tmux \(\$TMUX is unset\)\./);

	assert.equal(spawns.length, 0);
});

function paneEntry(runtimeRoot: string) {
	return {
		agent: "generalist",
		paneId: "%42",
		windowName: "agent:generalist",
		cwd: runtimeRoot,
		sessionFile: join(runtimeRoot, "sessions", "generalist.jsonl"),
		promptFile: join(runtimeRoot, "prompts", "generalist.md"),
		launcherFile: join(runtimeRoot, "launchers", "generalist.sh"),
		launcherVersion: PANE_LAUNCHER_VERSION,
		startedAt: new Date().toISOString(),
	};
}

async function seedLatestTask(runtimeRoot: string, kind: "oneshot" | "pane") {
	const now = new Date().toISOString();
	await upsertTaskRecord(runtimeRoot, { taskId: "generalist-1", agent: "generalist", task: "tidy the docs", status: "completed", kind, createdAt: now, updatedAt: now });
}

// One row per rule: a registry entry is stopped as a pane whatever ran last,
// and only a one-shot latest task makes a missing entry a headless retirement.
for (const row of [
	{ label: "no pane entry and a one-shot latest task is headless", pane: false, kind: "oneshot", expect: "headless" },
	{ label: "a pane entry is stopped as a pane after a one-shot task", pane: true, kind: "oneshot", expect: "pane" },
	{ label: "no pane entry and a pane latest task is refused", pane: false, kind: "pane", expect: /No pane registry entry for agent: generalist/ },
] as const) {
	test(`retireSubagent: ${row.label}`, async () => {
		const runtimeRoot = tempRuntime();
		setPaneExecCaptureForTests(async () => ({ code: 1, stdout: "", stderr: "no server running" }));
		if (row.pane) await writePaneRegistry(runtimeRoot, { generalist: paneEntry(runtimeRoot) });
		await seedLatestTask(runtimeRoot, row.kind);

		if (row.expect instanceof RegExp) {
			await assert.rejects(retireSubagent(runtimeRoot, "generalist"), row.expect);
			return;
		}
		assert.equal((await retireSubagent(runtimeRoot, "generalist")).kind, row.expect);
	});
}

test("stop_subagent reports no_pane for an agent whose latest task ran headless", async () => {
	const runtimeRoot = tempRuntime();
	await seedLatestTask(runtimeRoot, "oneshot");
	const tools: Array<{ name: string; execute: (...args: any[]) => Promise<any> }> = [];
	registerPaneSupportTools({
		ensurePaneBridgeMetadata: async () => undefined,
		persistRuntimeSnapshot: async () => undefined,
		pi: { registerTool: (tool: any) => tools.push(tool) } as any,
		removeDashboardAgent: () => undefined,
		retireSubagent,
		runtimeSessionId: () => "parent-session",
		sessionRuntimeDir: () => runtimeRoot,
	});
	const stop = tools.find((tool) => tool.name === "stop_subagent");
	assert.ok(stop);

	const result = await stop.execute("call-1", { agent: "generalist" }, undefined, undefined, {});

	assert.equal(result.content[0].text.split("\n")[0], "no_pane=generalist");
	assert.equal(result.isError, undefined);
});

async function stalledResolvers(runtime: typeof import("../extensions/subagent/dispatch.js")): Promise<void> {
	const { childSignal } = await import("../extensions/subagent/child-budget.js");
	process.env.TMUX = "/tmp/tmux-test/default,1,0";
	const root = tempRuntime();
	writeSettings(root, { maxConcurrency: 2 });
	const pi = mockPiEvents([]);
	const controller = new AbortController();
	const signals: Array<AbortSignal | undefined> = [];
	const releases: Array<() => void> = [];
	let cleaning = false;
	setPaneExecCaptureForTests(async () => {
		const signal = childSignal();
		signals.push(signal);
		return new Promise((resolve) => {
			const finish = () => resolve({ code: 1, stdout: "", stderr: "probe interrupted", error: new Error("probe interrupted") });
			releases.push(finish);
			if (cleaning || signal?.aborted) finish();
			else signal?.addEventListener("abort", finish, { once: true });
		});
	});
	const context = { ...flow(root, "single"), pi, signal: controller.signal };
	const task = { agent: "generalist", task: "inspect" };
	let settledCount = 0;
	const calls = [
		...Array.from({ length: 2 }, () => runtime.runSingleDispatch({ ...context, ...task })),
		...Array.from({ length: 2 }, () => runtime.runParallelDispatch({ ...context, tasks: [task] })),
		...Array.from({ length: 2 }, () => runtime.runChainDispatch({ ...context, chain: [task] })),
	].map((call) => call.then(() => { settledCount++; }, () => { settledCount++; }));
	try {
		await new Promise(setImmediate);
		assert.equal(signals.length, 2, "resolver probes must share admission");
		assert.ok(signals.every(Boolean), "resolver probes must inherit cancellation");
		controller.abort(new Error("cancel probes"));
		await new Promise(setImmediate);
		assert.equal(settledCount, 6, "stalled resolver cancellation must settle all modes");
	} finally {
		// Mutants can admit queued probes after the first release. Their fixture
		// commands must settle too, before this case releases its runtime root.
		cleaning = true;
		controller.abort();
		for (const release of releases) release();
		await Promise.all(calls);
	}
}

test("single, parallel and chain resolver probes share admission and cancellation", async () => {
	const { importRuntimeCopy } = await import("./browser-fixture.js");
	const runtime = await import("../extensions/subagent/dispatch.js");
	await stalledResolvers(runtime);
	const unbounded = await importRuntimeCopy("dispatch.ts", "await withChildBudget(flow.pi, flow.cwd, flow.signal, probeTmux)", "await probeTmux()") as typeof runtime;
	await assert.rejects(stalledResolvers(unbounded), /resolver probes must share admission/);
	const uncancelled = await importRuntimeCopy("dispatch.ts", "await withChildBudget(flow.pi, flow.cwd, flow.signal, probeTmux)", "await withChildBudget(flow.pi, flow.cwd, undefined, probeTmux)") as typeof runtime;
	await assert.rejects(stalledResolvers(uncancelled), /stalled resolver cancellation/);
});
