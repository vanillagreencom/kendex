import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import {
	assignEphemeralSessionKeys,
	formatInventoryValidationError,
	mapInBatchesWithConcurrencyLimit,
	validateAgentInventory,
} from "../extensions/subagent/dispatch.js";
import {
	isContextLengthExceededText,
	ONESHOT_SESSION_PREFIX,
	resolveBgSession,
	setSessionCompactorForTests,
} from "../extensions/subagent/sessions.js";
import {
	runSingleAgent,
	setGitExecFileForTests,
	setSingleAgentSpawnForTests,
} from "../extensions/subagent/runner.js";
import { waitForIdleTransition } from "../extensions/subagent/wait.js";
import type { SubagentDetails } from "../extensions/subagent/types.js";

function tempRuntime(): string {
	return mkdtempSync(join(tmpdir(), "pi-agents-lanes-"));
}

function tempGitRepo(): string {
	const cwd = tempRuntime();
	execFileSync("git", ["init"], { cwd, stdio: "ignore" });
	writeFileSync(join(cwd, "tracked.txt"), "initial\n", "utf8");
	execFileSync("git", ["add", "tracked.txt"], { cwd, stdio: "ignore" });
	execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "-m", "initial commit"], { cwd, stdio: "ignore" });
	writeFileSync(join(cwd, "dirty.txt"), "dirty\n", "utf8");
	return cwd;
}

function writeSettings(cwd: string, config: Record<string, unknown>) {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({
		vstack: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": config } } },
	}), "utf8");
}

function testAgent(): AgentConfig {
	return {
		name: "reviewer-test",
		description: "test reviewer",
		pane: false,
		systemPrompt: "",
		source: "project",
		filePath: "reviewer-test.md",
	};
}

function installMockSpawn(scenarios: Array<{ code?: number; stderr?: string; stdout?: string }>) {
	const calls: Array<{ args: string[] }> = [];
	setSingleAgentSpawnForTests(((command: string, args: string[]) => {
		void command;
		calls.push({ args });
		const proc = new EventEmitter() as any;
		proc.stdout = new EventEmitter();
		proc.stderr = new EventEmitter();
		proc.killed = false;
		proc.kill = () => {
			proc.killed = true;
			return true;
		};
		const scenario = scenarios.shift();
		queueMicrotask(() => {
			if (scenario?.stdout) proc.stdout.emit("data", Buffer.from(scenario.stdout));
			if (scenario?.stderr) proc.stderr.emit("data", Buffer.from(scenario.stderr));
			proc.emit("close", scenario?.code ?? 0);
		});
		return proc;
	}) as any);
	return calls;
}

function bridgeStdout(events: unknown[]): string {
	return `${events.map((event) => JSON.stringify(event)).join("\n")}\n`;
}

function bridgeEvent(event: string, data: Record<string, unknown> = {}): Record<string, unknown> {
	return { type: "event", event, data };
}

function mockPiEvents(events: Array<{ name: string; payload: any }>) {
	return {
		getActiveTools: () => [],
		events: {
			emit: (name: string, payload: unknown) => events.push({ name, payload }),
		},
	} as any;
}

function makeDetails(results: any[]): SubagentDetails {
	return { mode: "single", agentScope: "project", projectAgentsDir: null, results };
}

function withPollutedEnv(fn: () => void) {
	const previousParent = process.env.PI_SUBAGENT_PARENT_SESSION_ID;
	const previousChild = process.env.PI_SUBAGENT_CHILD_AGENT;
	const previousDir = process.env.PI_CODING_AGENT_DIR;
	try {
		process.env.PI_SUBAGENT_PARENT_SESSION_ID = "polluted-parent";
		process.env.PI_SUBAGENT_CHILD_AGENT = "polluted-child";
		process.env.PI_CODING_AGENT_DIR = join(tempRuntime(), "agent-dir");
		fn();
	} finally {
		if (previousParent === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION_ID;
		else process.env.PI_SUBAGENT_PARENT_SESSION_ID = previousParent;
		if (previousChild === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
		else process.env.PI_SUBAGENT_CHILD_AGENT = previousChild;
		if (previousDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousDir;
	}
}

test("oneshot default mints unique lane per call in clean and polluted env", () => {
	const cleanRuntime = tempRuntime();
	const first = resolveBgSession(cleanRuntime, "reviewer-test");
	const second = resolveBgSession(cleanRuntime, "reviewer-test");
	assert.equal(first.explicit, false);
	assert.equal(second.explicit, false);
	assert.match(first.key, new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
	assert.match(second.key, new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
	assert.notEqual(first.key, second.key);
	assert.notEqual(first.path, second.path);
	const forwardedOneShot = resolveBgSession(cleanRuntime, "reviewer-test", first.key);
	assert.equal(forwardedOneShot.explicit, false);
	assert.equal(forwardedOneShot.ephemeral, true);
	assert.equal(forwardedOneShot.key, first.key);

	withPollutedEnv(() => {
		const pollutedRuntime = tempRuntime();
		const pollutedFirst = resolveBgSession(pollutedRuntime, "reviewer-test");
		const pollutedSecond = resolveBgSession(pollutedRuntime, "reviewer-test");
		assert.notEqual(pollutedFirst.key, pollutedSecond.key);
		assert.match(pollutedFirst.key, new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
	});
});

test("parallel tasks for same agent get distinct ephemeral lanes", () => {
	const tasks = assignEphemeralSessionKeys([
		{ agent: "reviewer-test", task: "one" },
		{ agent: "reviewer-test", task: "two" },
		{ agent: "reviewer-test", task: "three" },
	]);
	assert.equal(new Set(tasks.map((item) => item.sessionKey)).size, 3);
	for (const task of tasks) assert.match(task.sessionKey ?? "", new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
});

test("explicit sessionKey reuses same lane", () => {
	const runtimeRoot = tempRuntime();
	const first = resolveBgSession(runtimeRoot, "reviewer-test", "issue-27");
	const second = resolveBgSession(runtimeRoot, "reviewer-test", "issue-27");
	assert.equal(first.explicit, true);
	assert.equal(first.ephemeral, false);
	assert.equal(first.key, "issue-27");
	assert.equal(second.key, "issue-27");
	assert.equal(first.path, second.path);
});

test("context_length_exceeded detection triggers one retry with fresh session", async () => {
	assert.equal(isContextLengthExceededText('Codex error: {"type":"error","error":{"type":"invalid_request_error","code":"context_length_exceeded"}}'), true);
	const calls = installMockSpawn([
		{ code: 1, stdout: `${JSON.stringify({ error: { type: "invalid_request_error", code: "context_length_exceeded" } })}\n` },
		{ code: 0, stdout: `${JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "ok after retry" }], usage: { input: 1, output: 1, totalTokens: 2 } } })}\n` },
	]);
	try {
		const agent = testAgent();
		const result = await runSingleAgent(
			process.cwd(),
			tempRuntime(),
			[agent],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			(results): SubagentDetails => ({ mode: "single", agentScope: "project", projectAgentsDir: null, results }),
		);
		assert.equal(calls.length, 2);
		assert.equal(result.exitCode, 0);
		assert.equal(result.attempt, 2);
		assert.equal(result.attempts?.length, 2);
		assert.notEqual(result.attempts?.[0]?.sessionKey, result.attempts?.[1]?.sessionKey);
		assert.match(result.attempts?.[0]?.errorEnvelope ?? "", /context_length_exceeded/);
		assert.match(result.stderr, /retrying once with fresh session/);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("session_compact followed by empty agent_end emits synthetic needs_completion", async () => {
	const cwd = tempGitRepo();
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [] })]) },
	]);
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.equal(result.status, "needs_completion");
		assert.equal(result.needsCompletionReason, "compact-then-empty");
		assert.equal(result.cwdSnapshot?.cwd, cwd);
		assert.match(result.cwdSnapshot?.head ?? "", /^[0-9a-f]{40}$/);
		assert.equal(result.cwdSnapshot?.dirty, true);
		assert.match(result.cwdSnapshot?.status ?? "", /\?\? dirty\.txt/);
		assert.equal(result.cwdSnapshot?.lastCommit.subject, "initial commit");
		assert.equal(existsSync(join(cwd, ".git", "index.lock")), false);

		const needsCompletion = emitted.find((event) => event.name === "subagents:needs_completion");
		assert.ok(needsCompletion);
		assert.equal(needsCompletion.payload.reason, "compact-then-empty");
		assert.equal(needsCompletion.payload.status, "needs_completion");
		assert.equal(needsCompletion.payload.cwdSnapshot?.cwd, cwd);
		assert.equal(emitted.some((event) => event.name === "subagents:completed" || event.name === "subagents:failed"), false);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("pre-compact assistant text does not mask compact-then-empty", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{
			code: 0,
			stdout: bridgeStdout([
				bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "pre-compact progress" }] } }),
				bridgeEvent("session_compact"),
				bridgeEvent("agent_end", { content: [] }),
			]),
		},
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.status, "needs_completion");
		assert.equal(result.needsCompletionReason, "compact-then-empty");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("compact-then-empty detection applies after context retry", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 1, stdout: `${JSON.stringify({ error: { type: "invalid_request_error", code: "context_length_exceeded" } })}\n` },
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [] })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 2);
		assert.equal(result.attempt, 2);
		assert.equal(result.attempts?.length, 2);
		assert.equal(result.status, "needs_completion");
		assert.equal(result.needsCompletionReason, "compact-then-empty");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), true);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), false);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("compact-then-empty treats null and omitted agent_end content as empty", async () => {
	for (const data of [{ content: null }, {}]) {
		const emitted: Array<{ name: string; payload: any }> = [];
		const calls = installMockSpawn([
			{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", data)]) },
		]);
		try {
			const result = await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				"review code",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(emitted),
				undefined,
				undefined,
				makeDetails,
			);
			assert.equal(calls.length, 1);
			assert.equal(result.status, "needs_completion");
			assert.equal(result.needsCompletionReason, "compact-then-empty");
			assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), true);
		} finally {
			setSingleAgentSpawnForTests();
		}
	}
});

test("session_compact followed by text agent_end completes normally", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [{ type: "text", text: "ok" }] })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.notEqual(result.status, "needs_completion");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("empty agent_end without session_compact preserves existing completion behavior", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("agent_end", { content: [] })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.notEqual(result.status, "needs_completion");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("bridge disconnect after session_compact does not classify compact-then-empty", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact")]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.notEqual(result.status, "needs_completion");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("malformed agent_end content is logged and skipped", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: "bad-shape" })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.notEqual(result.status, "needs_completion");
		assert.match(result.diagnostics?.join("\n") ?? "", /malformed agent_end content/);
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("missing git binary omits cwdSnapshot but still emits compact-then-empty", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [] })]) },
	]);
	setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
		void command;
		void args;
		const cb = typeof options === "function" ? options : callback;
		queueMicrotask(() => cb(Object.assign(new Error("spawn git ENOENT"), { code: "ENOENT" }), "", "spawn git ENOENT"));
		return new EventEmitter() as any;
	}) as any);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.status, "needs_completion");
		assert.equal(result.needsCompletionReason, "compact-then-empty");
		assert.equal(result.cwdSnapshot, undefined);
		assert.match(result.diagnostics?.join("\n") ?? "", /cwdSnapshot git failed/);
		const needsCompletion = emitted.find((event) => event.name === "subagents:needs_completion");
		assert.ok(needsCompletion);
		assert.equal(needsCompletion.payload.reason, "compact-then-empty");
		assert.equal(needsCompletion.payload.cwdSnapshot, undefined);
		assert.match(needsCompletion.payload.diagnostics?.join("\n") ?? "", /cwdSnapshot git failed/);
	} finally {
		setGitExecFileForTests();
		setSingleAgentSpawnForTests();
	}
});

test("needs_completion emit failure is attached to result diagnostics", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [] })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempGitRepo(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			{
				getActiveTools: () => [],
				events: {
					emit: (name: string, payload: unknown) => {
						if (name === "subagents:needs_completion") throw new Error("bus disposed");
						emitted.push({ name, payload });
					},
				},
			} as any,
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.status, "needs_completion");
		assert.match(result.diagnostics?.join("\n") ?? "", /Failed to emit subagents:needs_completion/);
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("reused session budget guard refuses over-threshold explicit session by default without spawning", async () => {
	const runtimeRoot = tempRuntime();
	const cwd = tempRuntime();
	const session = resolveBgSession(runtimeRoot, "reviewer-test", "reuse");
	mkdirSync(dirname(session.path), { recursive: true });
	writeFileSync(session.path, "x".repeat(700_000), "utf8");
	const calls = installMockSpawn([{ code: 0 }]);
	try {
		const result = await runSingleAgent(
			cwd,
			runtimeRoot,
			[testAgent()],
			"reviewer-test",
			"reuse old context",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			makeDetails,
			"reuse",
		);
		assert.equal(calls.length, 0);
		assert.equal(result.exitCode, 1);
		assert.equal(result.stopReason, "session_budget_exceeded");
		assert.match(result.errorMessage ?? "", /Refusing reused session/);
		assert.match(result.errorMessage ?? "", /exceeds 80% guard threshold/);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("reused session budget guard allows below-threshold explicit session", async () => {
	const runtimeRoot = tempRuntime();
	const cwd = tempRuntime();
	const session = resolveBgSession(runtimeRoot, "reviewer-test", "reuse-small");
	mkdirSync(dirname(session.path), { recursive: true });
	writeFileSync(session.path, "small", "utf8");
	const calls = installMockSpawn([
		{ code: 0, stdout: `${JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "ok" }], usage: { input: 1, output: 1, totalTokens: 2 } } })}\n` },
	]);
	try {
		const result = await runSingleAgent(
			cwd,
			runtimeRoot,
			[testAgent()],
			"reviewer-test",
			"reuse small context",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			makeDetails,
			"reuse-small",
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("reused session compact-then-resume policy compacts then launches", async () => {
	const runtimeRoot = tempRuntime();
	const cwd = tempRuntime();
	writeSettings(cwd, {
		reusedSessionBudgetPolicy: "compact-then-resume",
		reusedSessionBudgetThreshold: 0.5,
		reusedSessionContextLimitTokens: 100,
	});
	const session = resolveBgSession(runtimeRoot, "reviewer-test", "reuse-compact");
	mkdirSync(dirname(session.path), { recursive: true });
	writeFileSync(session.path, "x".repeat(1_000), "utf8");
	let compactCalls = 0;
	setSessionCompactorForTests(async (request) => {
		compactCalls += 1;
		writeFileSync(request.sessionPath, "", "utf8");
		return { archivePath: `${request.sessionPath}.archive` };
	});
	const calls = installMockSpawn([
		{ code: 0, stdout: `${JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "ok" }], usage: { input: 1, output: 1, totalTokens: 2 } } })}\n` },
	]);
	try {
		const result = await runSingleAgent(
			cwd,
			runtimeRoot,
			[testAgent()],
			"reviewer-test",
			"compact old context",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			makeDetails,
			"reuse-compact",
		);
		assert.equal(compactCalls, 1);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.match(result.stderr, /Compacted reused session/);
	} finally {
		setSessionCompactorForTests();
		setSingleAgentSpawnForTests();
	}
});

test("inventory guard rejects unknown agent with structured available lists", () => {
	const projectAgent: AgentConfig = { name: "planner", description: "plan", pane: true, systemPrompt: "", source: "project", filePath: "planner.md" };
	const userAgent: AgentConfig = { name: "personal", description: "user", pane: false, systemPrompt: "", source: "user", filePath: "personal.md" };
	const validation = validateAgentInventory(["missing"], { allowed: [projectAgent], project: [projectAgent], user: [userAgent] }, "project");
	assert.ok(validation);
	assert.deepEqual(validation?.missing, ["missing"]);
	assert.deepEqual(validation?.available.project, ["planner"]);
	assert.deepEqual(validation?.available.user, ["personal"]);
	assert.match(formatInventoryValidationError(validation!), /Unknown subagent\(s\).*missing/);
	assert.match(formatInventoryValidationError(validation!), /Project agents: planner/);
	assert.match(formatInventoryValidationError(validation!), /User agents: personal/);
});

test("parallel cap of 10 tasks dispatches with auto-batching", async () => {
	const items = Array.from({ length: 10 }, (_, index) => index);
	let active = 0;
	let maxActive = 0;
	const results = await mapInBatchesWithConcurrencyLimit(items, 8, 8, async (item) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		await new Promise((resolve) => setTimeout(resolve, 5));
		active -= 1;
		return item * 2;
	});
	assert.deepEqual(results, items.map((item) => item * 2));
	assert.equal(maxActive, 8);
});

test("wait_for_subagent_idle helper resolves on idle transition", async () => {
	const states = [{ isIdle: false }, { isIdle: false }, { isIdle: true }];
	const result = await waitForIdleTransition(async () => states.shift(), 1_000, 1);
	assert.equal(result.transitioned, true);
	assert.equal(result.timedOut, false);
	assert.equal(result.status, "idle-after-busy");
	assert.equal(result.samples, 3);
	assert.equal(result.lastState?.isIdle, true);
});

test("wait_for_subagent_idle distinguishes never-busy from idle-after-busy", async () => {
	const result = await waitForIdleTransition(async () => ({ isIdle: true }), 5, 1);
	assert.equal(result.transitioned, false);
	assert.equal(result.status, "never-busy");
	assert.equal(result.timedOut, true);
});
