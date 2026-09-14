import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { afterEach, beforeEach, it } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createSession, openSession } from "cc-session-io";

import claudeBridge, {
	__testGetBridgeIntegrityState,
	__testSetBridgeIntegrityState,
	__testSetSdkQueryFactory,
	conversationFingerprint,
	streamClaudeAgentSdk,
} from "../src/index.ts";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";
import { ctx, resetStack } from "../src/query-state.ts";
import { runInRequestLane } from "../src/request-lane.ts";
import { waitFor } from "./lib/wait-for.mjs";

const model = {
	id: "claude-haiku-4-5",
	name: "Claude Haiku",
	api: "claude-bridge",
	provider: "pi-claude",
	baseUrl: "claude-bridge",
	reasoning: true,
	input: ["text"],
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	contextWindow: 200000,
	maxTokens: 8192,
};
const tool = {
	name: "echo",
	description: "Return a supplied value",
	parameters: { type: "object", properties: { value: { type: "string" } }, required: ["value"] },
};
const piSessionId = "pi-main";
const claudeSessionId = "11111111-1111-4111-8111-111111111111";
const rootTmp = fileURLToPath(new URL("../../../tmp/", import.meta.url));

const user = (text) => ({ role: "user", content: text, timestamp: Date.now() });
const assistantText = (text) => ({
	role: "assistant",
	content: [{ type: "text", text }],
	api: model.api,
	provider: model.provider,
	model: model.id,
	usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
	stopReason: "stop",
	timestamp: Date.now(),
});
const assistantToolCalls = (calls) => ({
	role: "assistant",
	content: calls.map(({ id, value }) => ({ type: "toolCall", id, name: "echo", arguments: { value } })),
	api: model.api,
	provider: model.provider,
	model: model.id,
	usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
	stopReason: "toolUse",
	timestamp: Date.now(),
});
const assistantToolCall = () => assistantToolCalls([{ id: "call-1", value: "run once" }]);
const toolResult = (id = "call-1", text = "executed output") => ({
	role: "toolResult",
	toolCallId: id,
	toolName: "echo",
	content: [{ type: "text", text }],
	isError: false,
	timestamp: Date.now(),
});

function streamedText(text) {
	return [
		{ type: "stream_event", event: { type: "message_start", message: { id: `message-${text}`, model: model.id, usage: { input_tokens: 1 } } } },
		{ type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } },
		{ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } } },
		{ type: "stream_event", event: { type: "content_block_stop", index: 0 } },
		{ type: "stream_event", event: { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 1 } } },
		{ type: "stream_event", event: { type: "message_stop" } },
	];
}

async function collect(stream) {
	const events = [];
	for await (const event of stream) events.push(event);
	return events;
}

function fakePi(handlers) {
	return {
		on(event, handler) { handlers.set(event, handler); },
		registerCommand() {},
		registerProvider() {},
		events: { emit() {} },
		appendEntry() {},
	};
}

function sessionContext(sessionId) {
	const sessionManager = {
		getSessionId: () => sessionId,
		getEntries: () => [],
		getCwd: () => process.cwd(),
		buildSessionContext: () => ({ messages: [] }),
	};
	return { sessionManager, ui: { notify() {} }, cwd: process.cwd() };
}

let tempRoot;
let previousEnv;
let handlers;
let client;
let server;

beforeEach(() => {
	mkdirSync(rootTmp, { recursive: true });
	tempRoot = mkdtempSync(join(rootTmp, "bridge-mid-loop-compaction-"));
	previousEnv = Object.fromEntries([
		"CLAUDE_BRIDGE_ISOLATED",
		"CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT",
		"CLAUDE_CODE_OAUTH_TOKEN",
		"CLAUDE_CONFIG_DIR",
		"PI_CODING_AGENT_DIR",
	].map((key) => [key, process.env[key]]));
	Object.assign(process.env, {
		CLAUDE_BRIDGE_ISOLATED: "1",
		CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "0",
		CLAUDE_CODE_OAUTH_TOKEN: "offline-test",
		CLAUDE_CONFIG_DIR: tempRoot,
		PI_CODING_AGENT_DIR: tempRoot,
	});
	writeFileSync(join(tempRoot, "claude-bridge.json"), JSON.stringify({ provider: { enableConnectors: false } }));
	resetStack();
	__testSetBridgeIntegrityState({ sharedSession: null, ui: { notify() {} } });
	handlers = new Map();
	claudeBridge(fakePi(handlers));
});

afterEach(async () => {
	cancelScheduledToolUseEnd(runInRequestLane(piSessionId, () => ctx()));
	await client?.close();
	await server?.close();
	__testSetSdkQueryFactory();
	resetStack();
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
	for (const [key, value] of Object.entries(previousEnv)) {
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
	rmSync(tempRoot, { recursive: true, force: true });
	client = undefined;
	server = undefined;
});

it("rebuilds from compacted history before the post-tool assistant response", { timeout: 5000 }, async () => {
	const originalContext = {
		messages: [user("original opener"), assistantText("old answer"), user("run the tool")],
		tools: [tool],
	};
	const oldSession = createSession({ sessionId: claudeSessionId, projectPath: tempRoot, claudeDir: tempRoot });
	oldSession.importMessages([{ role: "user", content: "old writable transcript" }]);
	oldSession.save();
	const oldSessionBytes = readFileSync(oldSession.jsonlPath, "utf8");
	runInRequestLane(piSessionId, () => {
		__testSetBridgeIntegrityState({
			sharedSession: {
				sessionId: claudeSessionId,
				cursor: 2,
				cwd: tempRoot,
				conversationFingerprint: conversationFingerprint(originalContext.messages),
			},
		});
	});

	const oldToolResultObserved = Promise.withResolvers();
	const lifecycle = [];
	const calls = [];
	__testSetSdkQueryFactory(({ prompt, options }) => {
		calls.push({ prompt, options });
		if (calls.length === 1) {
			server = options.mcpServers["custom-tools"].instance;
			let closed = false;
			return {
				async *[Symbol.asyncIterator]() {
					try {
						yield { type: "system", subtype: "init", session_id: claudeSessionId };
						yield { type: "assistant", message: { content: [{ type: "tool_use", id: "call-1", name: "mcp__custom-tools__echo", input: { value: "run once" } }] } };
						await oldToolResultObserved.promise;
						if (closed) return;
						for (const message of streamedText("stale pre-compaction answer")) yield message;
						yield { type: "result", subtype: "success", result: "stale pre-compaction answer" };
					} finally {
						lifecycle.push("old-query-settled");
					}
				},
				close() { closed = true; oldToolResultObserved.resolve(); },
				async interrupt() { closed = true; oldToolResultObserved.resolve(); },
				async accountInfo() { return { email: "offline@example.test", subscriptionType: "max" }; },
			};
		}

		lifecycle.push("replacement-query-started");
		const rebuilt = openSession({ sessionId: options.resume, projectPath: tempRoot, claudeDir: tempRoot });
		const blocks = rebuilt.messages.flatMap((record) => Array.isArray(record.message.content) ? record.message.content : []);
		assert.deepEqual(
			blocks.filter((block) => block.type === "tool_use").map((block) => ({ id: block.id, name: block.name, input: block.input })),
			[{ id: "call-1", name: "mcp__custom-tools__echo", input: { value: "run once" } }],
			"the executed call is imported once rather than replayed",
		);
		assert.deepEqual(
			blocks.filter((block) => block.type === "tool_result").map((block) => ({ id: block.tool_use_id, content: block.content, isError: block.is_error })),
			[{ id: "call-1", content: "executed output", isError: undefined }],
			"the real result is imported once without a synthetic lost-output replacement",
		);
		return {
			async *[Symbol.asyncIterator]() {
				yield { type: "system", subtype: "init", session_id: options.resume };
				for (const message of streamedText("answer from compacted history")) yield message;
				yield { type: "result", subtype: "success", result: "answer from compacted history" };
			},
			close() {},
			async interrupt() {},
			async accountInfo() { return { email: "offline@example.test", subscriptionType: "max" }; },
		};
	});

	const firstEvents = await collect(streamClaudeAgentSdk(model, originalContext, { cwd: tempRoot, sessionId: piSessionId }));
	assert.equal(firstEvents.at(-1)?.reason, "toolUse");

	const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
	client = new Client({ name: "mid-loop-compaction-test", version: "1.0.0" });
	await server.connect(serverTransport);
	await client.connect(clientTransport);
	const deliveredToOldHandler = client.callTool({ name: "echo", arguments: { value: "run once" } });
	assert.equal(await waitFor(() => runInRequestLane(piSessionId, () => ctx().pendingToolCalls.has("call-1"))), true, "SDK handler is waiting");

	const summaryQuery = { id: "summary-one-shot" };
	runInRequestLane("summary-request", () => {
		ctx().activeQuery = summaryQuery;
		__testSetBridgeIntegrityState({ sharedSession: { sessionId: "summary-session", cursor: 0, cwd: tempRoot } });
	});
	await runInRequestLane("summary-request", () => handlers.get("session_compact")(
		{ reason: "threshold", willRetry: false },
		sessionContext(piSessionId),
	));
	assert.equal(runInRequestLane("summary-request", () => ctx().activeQuery), summaryQuery, "the summary one-shot lane is untouched");
	assert.equal(runInRequestLane("summary-request", () => __testGetBridgeIntegrityState().sharedSession.needsRebuild), undefined);
	assert.equal(runInRequestLane("summary-request", () => __testGetBridgeIntegrityState().sharedSession.forceRotate), undefined);
	assert.equal(runInRequestLane(piSessionId, () => __testGetBridgeIntegrityState().sharedSession.needsRebuild), true, "only the Pi session lane is marked");
	assert.equal(runInRequestLane(piSessionId, () => __testGetBridgeIntegrityState().sharedSession.forceRotate), true, "only the active Pi session lane requires rotation");

	const compactedContext = {
		messages: [user("compacted summary"), assistantToolCall(), toolResult()],
		tools: [tool],
	};
	const eventsPromise = collect(streamClaudeAgentSdk(model, compactedContext, { cwd: tempRoot, sessionId: piSessionId }));
	const handlerResult = await deliveredToOldHandler;
	oldToolResultObserved.resolve();
	const events = await eventsPromise;

	assert.deepEqual(handlerResult, {
		content: [{ type: "text", text: "executed output" }],
		isError: false,
		toolCallId: "call-1",
	});
	assert.deepEqual(
		events.filter((event) => event.type === "text_delta").map((event) => event.delta),
		["answer from compacted history"],
		JSON.stringify(events),
	);
	assert.equal(calls.length, 2, "one old query and one replacement query; no tool replay query");
	assert.equal(calls[1].prompt, "[continue]");
	assert.notEqual(calls[1].options.resume, claudeSessionId, "the replacement must not share a writable UUID with the old child");
	assert.equal(readFileSync(oldSession.jsonlPath, "utf8"), oldSessionBytes, "handover leaves the old session file intact");
	assert.deepEqual(lifecycle, ["old-query-settled", "replacement-query-started"], "replacement waits for old-query teardown");
	assert.deepEqual(
		runInRequestLane(piSessionId, () => {
			const state = __testGetBridgeIntegrityState().sharedSession;
			return { needsRebuild: state.needsRebuild, forceRotate: state.forceRotate };
		}),
		{ needsRebuild: undefined, forceRotate: undefined },
		"a successful replacement clears the transient rebuild state",
	);
	assert.equal(runInRequestLane(piSessionId, () => ctx().activeQuery), null);
});

it("imports multiple waiting and staggered queued results exactly once", { timeout: 5000 }, async () => {
	const executed = [
		{ id: "call-1", value: "first", output: "first output" },
		{ id: "call-2", value: "second", output: "second output" },
		{ id: "call-3", value: "third", output: "third output" },
	];
	const closeObserved = Promise.withResolvers();
	const allowTeardown = Promise.withResolvers();
	const calls = [];
	let importedBlocks = [];
	__testSetSdkQueryFactory(({ prompt, options }) => {
		calls.push({ prompt, options });
		if (calls.length === 1) {
			server = options.mcpServers["custom-tools"].instance;
			let closed = false;
			return {
				async *[Symbol.asyncIterator]() {
					yield { type: "system", subtype: "init", session_id: claudeSessionId };
					yield {
						type: "assistant",
						message: {
							content: executed.map(({ id, value }) => ({ type: "tool_use", id, name: "mcp__custom-tools__echo", input: { value } })),
						},
					};
					await allowTeardown.promise;
					if (!closed) yield { type: "result", subtype: "success", result: "stale answer" };
				},
				close() { closed = true; closeObserved.resolve(); },
				async interrupt() { closed = true; closeObserved.resolve(); },
				async accountInfo() { return { email: "offline@example.test", subscriptionType: "max" }; },
			};
		}

		const rebuilt = openSession({ sessionId: options.resume, projectPath: tempRoot, claudeDir: tempRoot });
		importedBlocks = rebuilt.messages.flatMap((record) => Array.isArray(record.message.content) ? record.message.content : []);
		return {
			async *[Symbol.asyncIterator]() {
				yield { type: "system", subtype: "init", session_id: options.resume };
				for (const message of streamedText("multi-tool continuation")) yield message;
				yield { type: "result", subtype: "success", result: "multi-tool continuation" };
			},
			close() {},
			async interrupt() {},
			async accountInfo() { return { email: "offline@example.test", subscriptionType: "max" }; },
		};
	});

	const initial = await collect(streamClaudeAgentSdk(
		model,
		{ messages: [user("run three tools")], tools: [tool] },
		{ cwd: tempRoot, sessionId: piSessionId },
	));
	assert.equal(initial.at(-1)?.reason, "toolUse");
	const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
	client = new Client({ name: "multi-tool-handover-test", version: "1.0.0" });
	await server.connect(serverTransport);
	await client.connect(clientTransport);

	const waiting = executed.slice(0, 2).map(({ value }) => client.callTool({ name: "echo", arguments: { value } }));
	assert.equal(await waitFor(() => runInRequestLane(piSessionId, () => ctx().pendingToolCalls.size === 2)), true, "multiple SDK handlers are waiting");
	await handlers.get("session_compact")(
		{ reason: "threshold", willRetry: false },
		sessionContext(piSessionId),
	);
	const compactedContext = {
		messages: [
			user("compacted multi-tool summary"),
			assistantToolCalls(executed),
			...executed.map(({ id, output }) => toolResult(id, output)),
		],
		tools: [tool],
	};
	const eventsPromise = collect(streamClaudeAgentSdk(model, compactedContext, { cwd: tempRoot, sessionId: piSessionId }));
	await closeObserved.promise;
	const waitingResults = await Promise.all(waiting);
	assert.equal(await waitFor(() => runInRequestLane(piSessionId, () => ctx().pendingResults.has("call-3"))), true, "the late handler's result is queued");
	const lateResult = await client.callTool({ name: "echo", arguments: { value: "third" } });
	allowTeardown.resolve();
	const events = await eventsPromise;

	assert.deepEqual(
		[...waitingResults, lateResult].map((result) => ({ id: result.toolCallId, output: result.content[0].text })),
		executed.map(({ id, output }) => ({ id, output })),
		"each handler consumes its executed result once",
	);
	assert.deepEqual(
		importedBlocks.filter((block) => block.type === "tool_use").map((block) => block.id),
		executed.map(({ id }) => id),
		"replacement history contains each executed call once",
	);
	assert.deepEqual(
		importedBlocks.filter((block) => block.type === "tool_result").map((block) => ({ id: block.tool_use_id, output: block.content })),
		executed.map(({ id, output }) => ({ id, output })),
		"replacement history contains each executed result once",
	);
	assert.deepEqual(events.filter((event) => event.type === "text_delta").map((event) => event.delta), ["multi-tool continuation"]);
	assert.equal(calls.length, 2, "one old query and one replacement query; no tool rerun");
});

it("hands over a deferred-message continuation query without waiting on the wrong teardown", { timeout: 5000 }, async () => {
	const gates = [Promise.withResolvers(), Promise.withResolvers()];
	const calls = [];
	let serverInstance;
	__testSetSdkQueryFactory(({ prompt, options }) => {
		calls.push(String(prompt));
		serverInstance ??= options.mcpServers["custom-tools"].instance;
		if (calls.length <= 2) {
			const index = calls.length - 1;
			const id = `call-${index + 1}`;
			let closed = false;
			return {
				async *[Symbol.asyncIterator]() {
					yield { type: "system", subtype: "init", session_id: claudeSessionId };
					yield { type: "assistant", message: { content: [{ type: "tool_use", id, name: "mcp__custom-tools__echo", input: { value: id } }] } };
					await gates[index].promise;
					if (closed) return;
				},
				close() { closed = true; gates[index].resolve(); },
				async interrupt() { closed = true; gates[index].resolve(); },
				async accountInfo() { return { email: "offline@example.test", subscriptionType: "max" }; },
			};
		}
		return {
			async *[Symbol.asyncIterator]() {
				yield { type: "system", subtype: "init", session_id: claudeSessionId };
				for (const message of streamedText("continued after nested handover")) yield message;
				yield { type: "result", subtype: "success", result: "continued after nested handover" };
			},
			close() {},
			async interrupt() {},
			async accountInfo() { return { email: "offline@example.test", subscriptionType: "max" }; },
		};
	});

	const initial = await collect(streamClaudeAgentSdk(
		model,
		{ messages: [user("run first tool")], tools: [tool] },
		{ cwd: tempRoot, sessionId: piSessionId },
	));
	assert.equal(initial.at(-1)?.reason, "toolUse");
	const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
	client = new Client({ name: "nested-handover-test", version: "1.0.0" });
	server = serverInstance;
	await server.connect(serverTransport);
	await client.connect(clientTransport);

	const firstHandler = client.callTool({ name: "echo", arguments: { value: "call-1" } });
	assert.equal(await waitFor(() => runInRequestLane(piSessionId, () => ctx().pendingToolCalls.has("call-1"))), true);
	const firstContinuation = collect(streamClaudeAgentSdk(model, {
		messages: [
			user("run first tool"),
			assistantToolCall(),
			{ ...toolResult(), content: [{ type: "text", text: "first output" }] },
			user("steer into a second tool"),
		],
		tools: [tool],
	}, { cwd: tempRoot, sessionId: piSessionId }));
	await firstHandler;
	gates[0].resolve();
	const secondToolTurn = await firstContinuation;
	assert.equal(secondToolTurn.at(-1)?.reason, "toolUse");
	assert.deepEqual(calls, ["run first tool", "steer into a second tool"]);

	const secondHandler = client.callTool({ name: "echo", arguments: { value: "call-2" } });
	assert.equal(await waitFor(() => runInRequestLane(piSessionId, () => ctx().pendingToolCalls.has("call-2"))), true);
	await handlers.get("session_compact")(
		{ reason: "threshold", willRetry: false },
		sessionContext(piSessionId),
	);
	const secondAssistant = {
		...assistantToolCall(),
		content: [{ type: "toolCall", id: "call-2", name: "echo", arguments: { value: "call-2" } }],
	};
	const secondResult = {
		...toolResult(),
		toolCallId: "call-2",
		content: [{ type: "text", text: "second output" }],
	};
	const handoverEvents = collect(streamClaudeAgentSdk(model, {
		messages: [user("compacted nested summary"), secondAssistant, secondResult],
		tools: [tool],
	}, { cwd: tempRoot, sessionId: piSessionId }));
	await secondHandler;
	gates[1].resolve();
	const events = await handoverEvents;

	assert.deepEqual(events.filter((event) => event.type === "text_delta").map((event) => event.delta), ["continued after nested handover"]);
	assert.deepEqual(calls, ["run first tool", "steer into a second tool", "[continue]"]);
	assert.equal(runInRequestLane(piSessionId, () => ctx().activeQuery), null);
});

it("aborts a handover without reusing its writable UUID on the next prompt", { timeout: 5000 }, async () => {
	const originalContext = {
		messages: [user("original opener"), assistantText("old answer"), user("run the tool")],
		tools: [tool],
	};
	const oldSession = createSession({ sessionId: claudeSessionId, projectPath: tempRoot, claudeDir: tempRoot });
	oldSession.importMessages([{ role: "user", content: "old writable transcript" }]);
	oldSession.save();
	const oldSessionBytes = readFileSync(oldSession.jsonlPath, "utf8");
	runInRequestLane(piSessionId, () => {
		__testSetBridgeIntegrityState({
			sharedSession: {
				sessionId: claudeSessionId,
				cursor: 2,
				cwd: tempRoot,
				conversationFingerprint: conversationFingerprint(originalContext.messages),
			},
		});
	});

	const teardownGate = Promise.withResolvers();
	const closeObserved = Promise.withResolvers();
	const calls = [];
	__testSetSdkQueryFactory(({ prompt, options }) => {
		calls.push({ prompt, options });
		if (calls.length === 1) {
			server = options.mcpServers["custom-tools"].instance;
			return {
				async *[Symbol.asyncIterator]() {
					yield { type: "system", subtype: "init", session_id: claudeSessionId };
					yield { type: "assistant", message: { content: [{ type: "tool_use", id: "call-1", name: "mcp__custom-tools__echo", input: { value: "run once" } }] } };
					await teardownGate.promise;
				},
				close() { closeObserved.resolve(); },
				async interrupt() { closeObserved.resolve(); },
				async accountInfo() { return { email: "offline@example.test", subscriptionType: "max" }; },
			};
		}
		return {
			async *[Symbol.asyncIterator]() {
				yield { type: "system", subtype: "init", session_id: options.resume };
				for (const message of streamedText("next prompt answer")) yield message;
				yield { type: "result", subtype: "success", result: "next prompt answer" };
			},
			close() {},
			async interrupt() {},
			async accountInfo() { return { email: "offline@example.test", subscriptionType: "max" }; },
		};
	});

	const controller = new AbortController();
	const initial = await collect(streamClaudeAgentSdk(
		model,
		originalContext,
		{ cwd: tempRoot, sessionId: piSessionId, signal: controller.signal },
	));
	assert.equal(initial.at(-1)?.reason, "toolUse");
	const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
	client = new Client({ name: "aborted-handover-test", version: "1.0.0" });
	await server.connect(serverTransport);
	await client.connect(clientTransport);
	const handler = client.callTool({ name: "echo", arguments: { value: "run once" } });
	assert.equal(await waitFor(() => runInRequestLane(piSessionId, () => ctx().pendingToolCalls.has("call-1"))), true);
	await handlers.get("session_compact")(
		{ reason: "threshold", willRetry: false },
		sessionContext(piSessionId),
	);
	const compactedContext = {
		messages: [user("compacted summary"), assistantToolCall(), toolResult()],
		tools: [tool],
	};
	const eventsPromise = collect(streamClaudeAgentSdk(
		model,
		compactedContext,
		{ cwd: tempRoot, sessionId: piSessionId, signal: controller.signal },
	));
	await closeObserved.promise;
	controller.abort();
	assert.equal((await handler).content[0].text, "executed output");
	teardownGate.resolve();
	const events = await eventsPromise;

	assert.equal(calls.length, 1, "cancellation must not start a replacement query");
	assert.deepEqual(events.filter((event) => event.type === "error").map((event) => ({ reason: event.reason, stopReason: event.error.stopReason })), [
		{ reason: "aborted", stopReason: "aborted" },
	]);
	assert.deepEqual(
		runInRequestLane(piSessionId, () => {
			const queryCtx = ctx();
			const state = __testGetBridgeIntegrityState().sharedSession;
			return {
				activeQuery: queryCtx.activeQuery,
				reportedMismatch: queryCtx.reportedToolResultMismatch,
				needsRebuild: state.needsRebuild,
				forceRotate: state.forceRotate,
			};
		}),
		{ activeQuery: null, reportedMismatch: false, needsRebuild: true, forceRotate: true },
		"fully delivered results still leave a persisted rotation requirement after cancellation",
	);
	assert.equal(readFileSync(oldSession.jsonlPath, "utf8"), oldSessionBytes, "cancellation leaves the old writable file intact");

	const abortedAssistant = events.find((event) => event.type === "error").error;
	const nextEvents = await collect(streamClaudeAgentSdk(model, {
		messages: [...compactedContext.messages, abortedAssistant, user("next prompt")],
		tools: [tool],
	}, { cwd: tempRoot, sessionId: piSessionId }));

	assert.deepEqual(nextEvents.filter((event) => event.type === "text_delta").map((event) => event.delta), ["next prompt answer"]);
	assert.equal(calls.length, 2, "the next prompt starts one fresh query");
	assert.notEqual(calls[1].options.resume, claudeSessionId, "next-prompt sync rotates away from the abandoned query's UUID");
	assert.equal(readFileSync(oldSession.jsonlPath, "utf8"), oldSessionBytes, "next-prompt sync does not rewrite the abandoned query's JSONL");
	assert.equal(runInRequestLane(piSessionId, () => ctx().activeQuery), null);
});

it("does not require rotation after compaction with no active query", async () => {
	const session = createSession({ sessionId: claudeSessionId, projectPath: tempRoot, claudeDir: tempRoot });
	session.importMessages([{ role: "user", content: "completed transcript" }]);
	session.save();
	runInRequestLane(piSessionId, () => {
		__testSetBridgeIntegrityState({ sharedSession: { sessionId: claudeSessionId, cursor: 1, cwd: tempRoot } });
	});

	await handlers.get("session_compact")(
		{ reason: "threshold", willRetry: false },
		sessionContext(piSessionId),
	);

	assert.deepEqual(
		runInRequestLane(piSessionId, () => {
			const state = __testGetBridgeIntegrityState().sharedSession;
			return { needsRebuild: state.needsRebuild, forceRotate: state.forceRotate };
		}),
		{ needsRebuild: true, forceRotate: undefined },
		"without an active child, compaction does not require UUID rotation",
	);
});

it("keeps the ordinary tool-result continuation on the active SDK query", { timeout: 5000 }, async () => {
	const resultObserved = Promise.withResolvers();
	let serverInstance;
	let calls = 0;
	__testSetSdkQueryFactory(({ options }) => {
		calls += 1;
		serverInstance = options.mcpServers["custom-tools"].instance;
		return {
			async *[Symbol.asyncIterator]() {
				yield { type: "system", subtype: "init", session_id: "ordinary-session" };
				yield { type: "assistant", message: { content: [{ type: "tool_use", id: "call-1", name: "mcp__custom-tools__echo", input: { value: "run once" } }] } };
				await resultObserved.promise;
				for (const message of streamedText("ordinary continuation")) yield message;
				yield { type: "result", subtype: "success", result: "ordinary continuation" };
			},
			close() { resultObserved.resolve(); },
			async interrupt() { resultObserved.resolve(); },
			async accountInfo() { return { email: "offline@example.test", subscriptionType: "max" }; },
		};
	});

	const initial = await collect(streamClaudeAgentSdk(model, { messages: [user("run the tool")], tools: [tool] }, { cwd: tempRoot, sessionId: piSessionId }));
	assert.equal(initial.at(-1)?.reason, "toolUse");
	const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
	client = new Client({ name: "ordinary-continuation-test", version: "1.0.0" });
	server = serverInstance;
	await server.connect(serverTransport);
	await client.connect(clientTransport);
	const handler = client.callTool({ name: "echo", arguments: { value: "run once" } });
	assert.equal(await waitFor(() => runInRequestLane(piSessionId, () => ctx().pendingToolCalls.has("call-1"))), true);

	const eventsPromise = collect(streamClaudeAgentSdk(
		model,
		{ messages: [user("run the tool"), assistantToolCall(), toolResult()], tools: [tool] },
		{ cwd: tempRoot, sessionId: piSessionId },
	));
	await handler;
	resultObserved.resolve();
	const events = await eventsPromise;

	assert.deepEqual(events.filter((event) => event.type === "text_delta").map((event) => event.delta), ["ordinary continuation"]);
	assert.equal(calls, 1, "ordinary delivery keeps the active query");
});
