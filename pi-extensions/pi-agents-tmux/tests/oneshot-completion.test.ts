// How a one-shot run classifies its end: the context-length retry,
// compact-then-empty, needs_completion delivery and the reused-session budget.

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS, isContextLengthExceededEnvelope, isContextLengthExceededText, resolveBgSession, setSessionCompactorForTests } from "../extensions/subagent/sessions.js";
import { runSingleAgent, setGitExecFileForTests, setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import type { SubagentDetails } from "../extensions/subagent/types.js";
import test, { after } from "node:test";
import { cleanupTempRuntimes, tempRuntime, tempGitRepo, writeSettings, testAgent, installMockSpawn, bridgeStdout, bridgeEvent, shapedStreamEvent, transcriptEventName, mockPiEvents, makeDetails } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

test("context_length_exceeded detection triggers one retry with fresh session", async () => {
	assert.equal(isContextLengthExceededText('Codex error: {"type":"error","error":{"type":"invalid_request_error","code":"context_length_exceeded"}}'), true);
	assert.equal(isContextLengthExceededText("Input length (265330) exceeds model's maximum context length (262144)."), true);
	assert.equal(isContextLengthExceededText("Your input exceeds the context window of this model"), true);
	assert.equal(isContextLengthExceededEnvelope({ type: "turn_end", message: { errorMessage: "context_length_exceeded" } }), true);
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

test("default reused-session context limit tracks current Codex backend cap", () => {
	assert.equal(DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS, 272_000);
});

test("context_length_exceeded text in normal tool output does not trigger retry", async () => {
	const stdout = bridgeStdout([
		{
			type: "tool_execution_end",
			toolCallId: "call-grep",
			toolName: "grep",
			result: {
				content: [
					{ type: "text", text: "tests/session-lanes.test.ts: context_length_exceeded detection triggers one retry" },
				],
			},
		},
		{
			type: "message_end",
			message: {
				role: "assistant",
				content: [{ type: "text", text: "Reviewed context_length_exceeded docs/tests; no runtime overflow." }],
				usage: { input: 1, output: 1, totalTokens: 2 },
			},
		},
	]);
	const calls = installMockSpawn([{ code: 0, stdout }]);
	try {
		const result = await runSingleAgent(
			process.cwd(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.equal(result.attempt, 1);
		assert.equal(result.attempts, undefined);
		assert.equal(result.errorEnvelope, undefined);
		assert.equal(result.errorMessage, undefined);
		assert.equal(result.stderr, "");
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("aborted oneshot emits failed event with summary", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([{ code: 0, stdout: bridgeStdout([
		shapedStreamEvent("top-level", "message_update", { message: { role: "assistant", content: [{ type: "text", text: "aborted partial" }] } }),
	]) }]);
	const controller = new AbortController();
	controller.abort();
	try {
		await assert.rejects(
			runSingleAgent(
				process.cwd(),
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				"review code",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(emitted),
				controller.signal,
				undefined,
				makeDetails,
			),
			/Agent was aborted/,
		);
		assert.equal(calls.length, 1);
		const failed = emitted.find((event) => event.name === "subagents:failed");
		assert.ok(failed);
		assert.equal(failed.payload.summary, "Agent was aborted before completion.");
		assert.equal(failed.payload.error, "Agent was aborted");
		const content = readFileSync(failed.payload.transcriptPath, "utf8");
		assert.match(content, /message_update/);
		assert.match(content, /aborted partial/);
		assert.match(content, /"buffered":true/);
		const updateRecords = content.trim().split(/\r?\n/).map((line) => JSON.parse(line)).filter((record) => record.event && transcriptEventName(record.event) === "message_update");
		assert.equal(updateRecords.length, 1);
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
	writeFileSync(session.path, "x".repeat(900_000), "utf8");
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
		assert.equal(result.sessionMode, "resumed");
		assert.equal(result.sessionKey, "reuse");
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
