// Where a `pane: true` agent runs when the dispatcher probes tmux: headless
// through the one-shot runner when no server answers, in a pane when one
// does, and refused under `paneOnly`. Also how `stop_subagent` retires an
// agent whose latest task ran headless.

import assert from "node:assert/strict";
import test, { after, afterEach } from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import { runSingleDispatch } from "../extensions/subagent/dispatch.js";
import { retireSubagent, setPaneExecCaptureForTests } from "../extensions/subagent/pane.js";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { upsertTaskRecord } from "../extensions/subagent/tasks.js";
import { bridgeEvent, bridgeStdout, cleanupTempRuntimes, installMockSpawn, makeDetails, mockPiEvents, tempRuntime } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

const suiteTmux = process.env.TMUX;
afterEach(() => {
	process.env.TMUX = suiteTmux;
	setPaneExecCaptureForTests();
	setSingleAgentSpawnForTests();
});

function paneAgent(): AgentConfig {
	return { name: "generalist", description: "maintenance", pane: true, source: "project", systemPrompt: "", filePath: "generalist.md" };
}

function dispatch(runtimeRoot: string, paneOnly = false) {
	return runSingleDispatch({
		agent: "generalist",
		agents: [paneAgent()],
		cwd: runtimeRoot,
		makeDetails: () => makeDetails,
		paneOnly,
		parentSessionId: "parent-session",
		pi: mockPiEvents([]),
		removeDashboardAgent: () => undefined,
		runtimeRoot,
		task: "tidy the docs",
		updateDashboard: () => undefined,
	});
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

const finished = { stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "docs tidied" }] } })]) };

for (const [label, setup] of [
	["$TMUX is unset", () => delete process.env.TMUX],
	["the named tmux server does not answer", () => recordTmux(false)],
] as const) {
	test(`a pane agent runs headless and returns its result when ${label}`, async () => {
		setup();
		const spawns = installMockSpawn([finished]);

		const result = await dispatch(tempRuntime());

		const [notice, cause, taskLine] = result.content[0].text.split("\n");
		assert.equal(notice, "pane-fallback reason=no-tmux");
		assert.match(cause, /Pane agents ran headless as background one-shot processes: generalist\.$/);
		const outcome = result.details.results[0];
		assert.equal(taskLine, `Task ID: ${outcome.taskId}`);
		assert.equal(result.content[0].text.split("pane-fallback reason=no-tmux").length, 2);
		assert.match(result.content[0].text, /docs tidied$/);
		assert.equal(outcome.kind, "oneshot");
		assert.equal(result.isError, undefined);
		assert.equal(spawns.length, 1);
	});
}

test("a pane agent keeps its pane where the tmux server answers", async () => {
	const tmuxCalls = recordTmux(true);
	const spawns = installMockSpawn([finished]);

	await assert.rejects(dispatch(tempRuntime()), /planted split-window refusal/);

	assert.ok(tmuxCalls.some((args) => args[0] === "split-window"));
	assert.equal(spawns.length, 0);
});

test("paneOnly refuses a pane agent where no tmux server is reachable", async () => {
	delete process.env.TMUX;
	const spawns = installMockSpawn([finished]);

	await assert.rejects(dispatch(tempRuntime(), true), /Persistent pane agents require tmux \(\$TMUX is unset\)\./);

	assert.equal(spawns.length, 0);
});

test("stop_subagent retires an agent whose latest task ran headless without a pane", async () => {
	const runtimeRoot = tempRuntime();
	const now = new Date().toISOString();
	await upsertTaskRecord(runtimeRoot, { taskId: "generalist-1", agent: "generalist", task: "tidy the docs", status: "completed", kind: "oneshot", createdAt: now, updatedAt: now });

	const retired = await retireSubagent(runtimeRoot, "generalist");

	assert.equal(retired.kind, "headless");
	assert.equal(retired.kind === "headless" && retired.record.taskId, "generalist-1");
	await assert.rejects(retireSubagent(runtimeRoot, "planner"), /No pane registry entry for agent: planner/);
});
