import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";

import {
	__testGetBridgeIntegrityState,
	__testSetBridgeIntegrityState,
	__testSetSdkQueryFactory,
	streamClaudeAgentSdk,
} from "../src/index.ts";
import { setExtensionApi } from "../src/bridge-state.ts";
import { ctx, resetStack } from "../src/query-state.ts";
import { runInRequestLane } from "../src/request-lane.ts";

const model = {
	id: "claude-haiku-4-5",
	name: "Claude Haiku",
	api: "claude-bridge",
	provider: "pi-claude",
	baseUrl: "claude-bridge",
	reasoning: true,
	input: ["text", "image"],
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	contextWindow: 200000,
	maxTokens: 8192,
};

function deferred() {
	let resolve;
	const promise = new Promise((done) => { resolve = done; });
	return { promise, resolve };
}

function streamedText(text) {
	return [
		{ type: "stream_event", event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } } },
		{ type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } },
		{ type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } } },
	];
}

async function collect(stream) {
	const events = [];
	for await (const event of stream) events.push(event);
	return events;
}

beforeEach(() => {
	process.env.CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT = "0";
	process.env.CLAUDE_CODE_OAUTH_TOKEN = "test-token";
	resetStack();
	__testSetBridgeIntegrityState({ sharedSession: null, ui: { notify: () => {} } });
	setExtensionApi({ events: { emit: () => {} }, appendEntry: () => {} });
});

afterEach(() => {
	delete process.env.CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT;
	delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
	__testSetSdkQueryFactory();
	setExtensionApi(undefined);
	resetStack();
	__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
});

describe("provider request session lanes", () => {
	it("keeps an active parent and parallel in-process subagents independent", async () => {
		const gates = new Map();
		const started = [];
		__testSetSdkQueryFactory(({ prompt }) => {
			const label = String(prompt);
			const gate = deferred();
			gates.set(label, gate);
			started.push(label);
			let closed = false;
			return {
				async *[Symbol.asyncIterator]() {
					yield { type: "system", subtype: "init", session_id: `sdk-${label}` };
					await gate.promise;
					if (closed) return;
					for (const message of streamedText(`answer-${label}`)) yield message;
					yield { type: "result", subtype: "success", result: `answer-${label}` };
				},
				close() { closed = true; gate.resolve(); },
				async interrupt() { closed = true; gate.resolve(); },
			};
		});

		const requests = ["parent", "child-a", "child-b", "child-c"].map((label) => ({
			label,
			stream: streamClaudeAgentSdk(
				model,
				{ messages: [{ role: "user", content: label, timestamp: Date.now() }] },
				{ sessionId: label },
			),
		}));
		const results = requests.map(({ stream }) => collect(stream));

		await new Promise((resolve) => setTimeout(resolve, 20));
		assert.deepEqual(started.sort(), requests.map(({ label }) => label).sort());
		for (const gate of gates.values()) gate.resolve();

		const events = await Promise.all(results);
		for (let index = 0; index < requests.length; index += 1) {
			const label = requests[index].label;
			assert.deepEqual(
				events[index].filter((event) => event.type === "text_delta").map((event) => event.delta),
				[`answer-${label}`],
			);
			assert.equal(
				runInRequestLane(label, () => __testGetBridgeIntegrityState().sharedSession?.sessionId),
				`sdk-${label}`,
			);
			assert.equal(runInRequestLane(label, () => ctx().activeQuery), null);
		}
	});

	it("aborts one session without stopping a concurrent sibling", async () => {
		const gates = new Map();
		__testSetSdkQueryFactory(({ prompt }) => {
			const label = String(prompt);
			const gate = deferred();
			gates.set(label, gate);
			let closed = false;
			return {
				async *[Symbol.asyncIterator]() {
					yield { type: "system", subtype: "init", session_id: `sdk-${label}` };
					await gate.promise;
					if (closed) return;
					for (const message of streamedText(`answer-${label}`)) yield message;
					yield { type: "result", subtype: "success", result: `answer-${label}` };
				},
				close() { closed = true; gate.resolve(); },
				async interrupt() { closed = true; gate.resolve(); },
			};
		});

		const childAbort = new AbortController();
		const parentEvents = collect(streamClaudeAgentSdk(
			model,
			{ messages: [{ role: "user", content: "parent", timestamp: Date.now() }] },
			{ sessionId: "parent" },
		));
		const childEvents = collect(streamClaudeAgentSdk(
			model,
			{ messages: [{ role: "user", content: "child", timestamp: Date.now() }] },
			{ sessionId: "child", signal: childAbort.signal },
		));

		await new Promise((resolve) => setTimeout(resolve, 20));
		childAbort.abort();
		gates.get("parent").resolve();

		const [parent, child] = await Promise.all([parentEvents, childEvents]);
		assert.deepEqual(
			parent.filter((event) => event.type === "text_delta").map((event) => event.delta),
			["answer-parent"],
		);
		assert.ok(child.some((event) => event.type === "error" && event.reason === "aborted"));
		assert.equal(runInRequestLane("parent", () => ctx().activeQuery), null);
		assert.equal(runInRequestLane("child", () => ctx().activeQuery), null);
	});

	it("does not let one lane overwrite another lane's mutable state", () => {
		runInRequestLane("parent", () => {
			ctx().activeQuery = { id: "parent-query" };
			__testSetBridgeIntegrityState({ sharedSession: { sessionId: "parent-session", cursor: 5, cwd: "/parent" } });
		});
		runInRequestLane("child", () => {
			ctx().activeQuery = { id: "child-query" };
			__testSetBridgeIntegrityState({ sharedSession: { sessionId: "child-session", cursor: 1, cwd: "/child" } });
		});

		assert.equal(runInRequestLane("parent", () => ctx().activeQuery.id), "parent-query");
		assert.equal(runInRequestLane("parent", () => __testGetBridgeIntegrityState().sharedSession.sessionId), "parent-session");
		assert.equal(runInRequestLane("child", () => ctx().activeQuery.id), "child-query");
		assert.equal(runInRequestLane("child", () => __testGetBridgeIntegrityState().sharedSession.sessionId), "child-session");
	});
});
