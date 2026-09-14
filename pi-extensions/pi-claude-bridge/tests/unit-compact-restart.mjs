/**
 * Pi 0.84.4+ compacts between tool execution and the next assistant response,
 * so `session_compact` can fire while the bridge's SDK query is still waiting
 * for a Pi tool result. That query's Claude session holds the history Pi just
 * replaced, and every remaining request of the tool loop re-sends it — the
 * climbing input usage across the compactions of one reported session.
 *
 * The next provider callback must restart the query from Pi's compacted
 * context instead of delivering into it, importing the tool results Pi already
 * holds exactly once and re-running no tool.
 */
// Must load before any bridge module: the diag assertion below needs the debug
// flag set when src/debug.ts is evaluated.
import "./lib/debug-env.mjs";

import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { createSession } from "cc-session-io";

import {
	HISTORY_REPLACED_PROMPT,
	__testGetBridgeIntegrityState,
	__testSetBridgeIntegrityState,
	__testSetSdkQueryFactory,
	onPiHistoryReplaced,
	streamClaudeAgentSdk,
} from "../src/index.ts";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";
import { ctx, resetStack } from "../src/query-state.ts";
import { waitFor } from "./lib/wait-for.mjs";

const model = { id: "claude-haiku-4-5", api: "claude-bridge", provider: "pi-claude", cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const tool = { name: "echo", description: "Return a supplied value", parameters: { type: "object", properties: { id: { type: "string" } }, required: ["id"] } };
const SESSION_ID = "11111111-1111-4111-8111-111111111111";
const TOOL_OUTPUT = "tool output t0";
const SUMMARY = "[summary] the earlier turns, condensed";
const OLD_TRANSCRIPT = "what the killed child had already written";

const user = (content) => ({ role: "user", content, timestamp: Date.now() });
const assistantText = (text) => ({ role: "assistant", content: [{ type: "text", text }], timestamp: Date.now() });
const assistantToolCall = (id) => ({ role: "assistant", content: [{ type: "toolCall", id, name: "echo", arguments: { id } }], timestamp: Date.now() });
const toolResult = (id, text) => ({ role: "toolResult", toolCallId: id, content: [{ type: "text", text }], timestamp: Date.now() });
const collect = async (stream) => { const events = []; for await (const event of stream) events.push(event); return events; };

/** The pre-compaction turn: the child asks for one tool call, then waits for a
 *  result the compaction boundary intercepts. `close`/`interrupt` release it the
 *  way a killed Claude Code child ends its stream; `release` lets the turn end
 *  on its own instead. */
function toolCallQuery(record, id = "t0") {
	const gate = Promise.withResolvers();
	record.closed = false;
	record.release = () => gate.resolve();
	return {
		async *[Symbol.asyncIterator]() {
			yield { type: "system", subtype: "init", session_id: SESSION_ID };
			yield { type: "assistant", message: { content: [{ type: "tool_use", id, name: "mcp__custom-tools__echo", input: { id } }] } };
			await gate.promise;
			if (!record.closed) yield { type: "result", subtype: "success", result: "answered without the tool" };
		},
		close() { record.closed = true; gate.resolve(); },
		async interrupt() { record.closed = true; gate.resolve(); },
	};
}

/** A turn whose child runs a call pi never sees before calling a pi tool. That
 *  exchange never reaches pi's messages.
 *
 *  Both calls arrive in the completed assistant message. Opening a streamed
 *  block and never closing it would leave the turn to the grace-timer backstop,
 *  which is deliberately unref'd: whether it fires before the loop drains is a
 *  race the test must not take. */
function childSideQuery(record, toolName) {
	const gate = Promise.withResolvers();
	record.closed = false;
	record.release = () => gate.resolve();
	return {
		async *[Symbol.asyncIterator]() {
			yield { type: "system", subtype: "init", session_id: SESSION_ID };
			yield { type: "assistant", message: { content: [
				{ type: "tool_use", id: "c1", name: toolName, input: {} },
				{ type: "tool_use", id: "t0", name: "mcp__custom-tools__echo", input: { id: "t0" } },
			] } };
			await gate.promise;
			if (!record.closed) yield { type: "result", subtype: "success", result: "done" };
		},
		close() { record.closed = true; gate.resolve(); },
		async interrupt() { record.closed = true; gate.resolve(); },
	};
}

/** A query whose `close()` throws, the way a dying child's transport can. */
function closeThrowingQuery(record) {
	const gate = Promise.withResolvers();
	record.closed = false;
	record.release = () => gate.resolve();
	return {
		async *[Symbol.asyncIterator]() {
			yield { type: "system", subtype: "init", session_id: SESSION_ID };
			yield { type: "assistant", message: { content: [{ type: "tool_use", id: "t0", name: "mcp__custom-tools__echo", input: { id: "t0" } }] } };
			await gate.promise;
		},
		close() { record.closed = true; gate.resolve(); throw new Error("fixture-close-throws=sdk"); },
		async interrupt() { record.closed = true; gate.resolve(); },
	};
}

/** A continuation whose child throws out of its iterator when it is killed. */
function throwingQuery(record) {
	const gate = Promise.withResolvers();
	record.closed = false;
	return {
		async *[Symbol.asyncIterator]() {
			yield { type: "system", subtype: "init", session_id: SESSION_ID };
			yield { type: "assistant", message: { content: [{ type: "tool_use", id: "t1", name: "mcp__custom-tools__echo", input: { id: "t1" } }] } };
			await gate.promise;
			throw new Error("fixture-child-killed=continuation");
		},
		close() { record.closed = true; gate.resolve(); },
		async interrupt() { record.closed = true; gate.resolve(); },
	};
}

/** The replacement turn: a plain answer over the rebuilt session. */
function answerQuery(text, sessionId = SESSION_ID) {
	return {
		async *[Symbol.asyncIterator]() {
			yield { type: "system", subtype: "init", session_id: sessionId };
			yield { type: "stream_event", event: { type: "message_start", message: { model: model.id, usage: { input_tokens: 1 } } } };
			yield { type: "stream_event", event: { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } } };
			yield { type: "stream_event", event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } } };
			yield { type: "result", subtype: "success", result: text };
		},
		close() {},
		async interrupt() {},
	};
}

/** Pi's context when it calls the provider back with the tool result. After a
 *  compaction the summary stands in place of the earlier turns. */
const toolResultDelivery = () => ({
	messages: [user(SUMMARY), assistantToolCall("t0"), toolResult("t0", TOOL_OUTPUT)],
	tools: [tool],
});

async function withBridge(run, openingQuery = toolCallQuery) {
	const root = mkdtempSync(join(tmpdir(), "bridge-compact-restart-"));
	const env = { CLAUDE_CONFIG_DIR: root, PI_CODING_AGENT_DIR: root, CLAUDE_CODE_OAUTH_TOKEN: "offline-test", CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "0", CLAUDE_BRIDGE_DIAG_PATH: join(root, "diag.log") };
	const previous = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
	Object.assign(process.env, env);
	resetStack();
	// A conversation already under way: the record a compaction must rebuild,
	// and the transcript its Claude Code child is writing.
	const oldSession = createSession({ sessionId: SESSION_ID, projectPath: root, claudeDir: root });
	oldSession.importMessages([{ role: "user", content: OLD_TRANSCRIPT }]);
	oldSession.save();
	const oldSessionBytes = readFileSync(oldSession.jsonlPath, "utf8");
	__testSetBridgeIntegrityState({
		sharedSession: { sessionId: SESSION_ID, cursor: 2, cwd: root },
		ui: { notify() {} },
	});
	const calls = [];
	const firstQuery = {};
	const abort = new AbortController();
	// Makers for the queries after the first, in order; the default answers.
	const queued = [];
	__testSetSdkQueryFactory(({ prompt, options }) => {
		calls.push({ prompt, options });
		if (calls.length === 1) return openingQuery(firstQuery);
		return (queued.shift() ?? (() => answerQuery("restarted", options.resume ?? SESSION_ID)))();
	});
	try {
		const preCompaction = { messages: [user("earlier prompt"), assistantText("earlier reply"), user("run the tool")], tools: [tool] };
		const opened = await collect(streamClaudeAgentSdk(model, preCompaction, { cwd: root, signal: abort.signal }));
		assert.equal(opened.filter((event) => event.type === "done").length, 1, "the tool-call turn reached pi");
		assert.notEqual(ctx().activeQuery, null, "the query stays active, waiting for the tool result");
		await run({ root, calls, queued, firstQuery, abort, diagPath: env.CLAUDE_BRIDGE_DIAG_PATH, oldSession: { path: oldSession.jsonlPath, bytes: oldSessionBytes } });
	} finally {
		firstQuery.release();
		cancelScheduledToolUseEnd(ctx());
		__testSetSdkQueryFactory();
		__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
		resetStack();
		for (const [key, value] of Object.entries(previous)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
		rmSync(root, { recursive: true, force: true });
	}
}

/** The messages the rebuild imported into the session Claude is resumed on. */
function importedMessages(root, sessionId) {
	const files = readdirSync(root, { recursive: true, encoding: "utf8" }).filter((entry) => entry.endsWith(`${sessionId}.jsonl`));
	assert.equal(files.length, 1, `exactly one session file for ${sessionId}: ${files.join(", ")}`);
	return readFileSync(join(root, files[0]), "utf8").trim().split("\n").map((line) => JSON.parse(line).message);
}

const blocksOfType = (messages, type) => messages.flatMap((message) => (Array.isArray(message.content) ? message.content.filter((block) => block.type === type) : []));

describe("compaction while a bridge query waits for a tool result", () => {
	it("restarts the query from pi's compacted context, carrying each tool result once", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, firstQuery, oldSession }) => {
			onPiHistoryReplaced("session_compact");
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.needsRebuild, true, "the record must rebuild");
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.forceRotate, true, "away from the session the killed child still writes");

			const events = await collect(streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root }));

			assert.equal(firstQuery.closed, true, "the pre-compaction query is stopped, not continued");
			assert.equal(calls.length, 2, "the tool result opened a replacement query");
			assert.equal(calls[1].prompt, HISTORY_REPLACED_PROMPT, "the replacement query continues from the imported history");
			assert.notEqual(calls[1].options.resume, SESSION_ID, "the replacement does not reuse the killed child's session id");
			assert.equal(readFileSync(oldSession.path, "utf8"), oldSession.bytes, "and leaves that child's transcript intact");

			// Pi's whole context is imported, so the executed tool call and its
			// result stay paired in Claude's history and appear exactly once.
			const imported = importedMessages(root, calls[1].options.resume);
			assert.deepEqual(blocksOfType(imported, "tool_result"), [{ type: "tool_result", tool_use_id: "t0", content: TOOL_OUTPUT }], "the tool result is imported exactly once");
			assert.deepEqual(blocksOfType(imported, "tool_use").map((block) => block.id), ["t0"], "its tool call is imported beside it");
			assert.deepEqual(imported.filter((message) => typeof message.content === "string").map((message) => message.content), [SUMMARY], "the summary replaces the pre-compaction history");

			// No tool is dispatched again: the results came from pi's history, so
			// the replacement turn answers rather than re-running anything.
			assert.deepEqual(events.filter((event) => event.type === "text_delta").map((event) => event.delta), ["restarted"]);
			const done = events.filter((event) => event.type === "done");
			assert.equal(done.length, 1, "the callback's stream ends with the replacement turn");
			assert.deepEqual(done[0].message.content.filter((block) => block.type === "toolCall"), [], "no tool call is re-issued");
			assert.equal(ctx().pendingToolCalls.size, 0, "no handler is left waiting");

			// The rotation has to outlive startup: the child reports the session it
			// was handed, and that id is what the settled record keeps.
			assert.equal(await waitFor(() => ctx().activeQuery === null), true, "the replacement settled");
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.sessionId, calls[1].options.resume, "the record keeps the rotated session, not the killed child's");
		});
	});

	it("delivers into the running query when pi has not replaced the history", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, firstQuery }) => {
			streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root });

			assert.equal(calls.length, 1, "an ordinary tool result opens no second query");
			assert.equal(firstQuery.closed, false, "the running query keeps the turn");
			assert.notEqual(ctx().activeQuery, null, "and stays active");
			assert.equal(ctx().pendingResults.get("t0")?.content[0].text, TOOL_OUTPUT, "the result is delivered to it");
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.needsRebuild, undefined, "the record is left alone");
		});
	});

	it("rebuilds in place on the next prompt when the compaction killed no child", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, firstQuery }) => {
			onPiHistoryReplaced("session_compact");
			firstQuery.release(); // the turn answers instead of calling the tool again
			assert.equal(await waitFor(() => ctx().activeQuery === null), true, "the query settled with no restart");
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.needsRebuild, true, "pi's replacement outlives it");
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.forceRotate, undefined, "and the settled query leaves no rotation behind");

			onPiHistoryReplaced("session_compact"); // a later compaction, nothing running
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.forceRotate, undefined, "which kills no child and rotates nothing");

			const next = { messages: [user(SUMMARY), user("the next prompt")], tools: [tool] };
			const events = await collect(streamClaudeAgentSdk(model, next, { cwd: root }));

			assert.equal(calls.length, 2, "the prompt opens the next query");
			assert.equal(calls[1].prompt, "the next prompt", "prompted with the user's own message, not a continuation");
			assert.equal(calls[1].options.resume, SESSION_ID, "rebuilt in place, keeping the session id");
			assert.equal(events.filter((event) => event.type === "done").length, 1, "the turn completes");
		});
	});

	it("carries the replacement through a deferred continuation the compaction interrupts", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, queued, firstQuery, oldSession }) => {
			const continuation = {};
			queued.push(() => toolCallQuery(continuation, "t1"));

			// A steer arrives while the first query runs, so it replays as a
			// continuation query once that query ends.
			const steered = [user(SUMMARY), assistantToolCall("t0"), toolResult("t0", TOOL_OUTPUT), user("steer one")];
			streamClaudeAgentSdk(model, { messages: steered, tools: [tool] }, { cwd: root });
			streamClaudeAgentSdk(model, { messages: [...steered, user("steer two")], tools: [tool] }, { cwd: root });
			firstQuery.release();
			assert.equal(await waitFor(() => calls.length === 2), true, "the steer replays as a continuation query");
			assert.equal(calls[1].prompt, "steer one");

			// Pi compacts while THAT query waits for its own tool result.
			onPiHistoryReplaced("session_compact");
			const events = await collect(streamClaudeAgentSdk(model, {
				messages: [user(SUMMARY), assistantToolCall("t1"), toolResult("t1", TOOL_OUTPUT)],
				tools: [tool],
			}, { cwd: root }));

			assert.equal(continuation.closed, true, "the continuation query is stopped for the restart");
			assert.equal(calls.length, 3, "the second steer does not open another query on the replaced history");
			assert.equal(calls[2].prompt, HISTORY_REPLACED_PROMPT, "the third query is the replacement");
			assert.equal(typeof calls[2].options.resume, "string", "which resumes pi's history rather than starting empty");
			assert.notEqual(calls[2].options.resume, SESSION_ID, "on a session rotated away from the killed child");
			assert.equal(readFileSync(oldSession.path, "utf8"), oldSession.bytes, "whose transcript is left intact");
			assert.deepEqual(
				blocksOfType(importedMessages(root, calls[2].options.resume), "tool_result").map((block) => block.content),
				[TOOL_OUTPUT],
				"and carries the executed tool result exactly once",
			);
			assert.equal(events.filter((event) => event.type === "text_delta").map((event) => event.delta).join(""), "restarted");
		});
	});

	// Both kinds of child-side call are invisible to pi and unrecoverable from its
	// context, so both must refuse the handover.
	for (const { kind, toolName } of [
		{ kind: "a claude.ai connector", toolName: "mcp__claude_ai_slack__post_message" },
		{ kind: "a foreign MCP tool", toolName: "mcp__linear__create_issue" },
	]) {
		it(`declines the handover when the child ran ${kind} itself`, { timeout: 10_000 }, async () => {
			await withBridge(async ({ root, calls, firstQuery }) => {
				onPiHistoryReplaced("session_compact");

				streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root });

				assert.equal(calls.length, 1, "that call cannot be rebuilt from pi's context, so no replacement is opened");
				assert.equal(firstQuery.closed, false, "the query keeps its own history, that exchange included");
				assert.equal(ctx().pendingResults.get("t0")?.content[0].text, TOOL_OUTPUT, "and the tool result is delivered to it as usual");

				// The record this query writes as it ends is what the next turn reads,
				// so the rebuild only counts if it survives settlement.
				firstQuery.release();
				assert.equal(await waitFor(() => ctx().activeQuery === null), true, "the declined turn settled");
				assert.equal(__testGetBridgeIntegrityState().sharedSession?.needsRebuild, true, "the next turn still rebuilds");
			}, (record) => childSideQuery(record, toolName));
		});
	}

	it("records no failure for a continuation whose child throws as the restart kills it", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, queued, firstQuery, diagPath }) => {
			const continuation = {};
			queued.push(() => throwingQuery(continuation));

			const steered = [user(SUMMARY), assistantToolCall("t0"), toolResult("t0", TOOL_OUTPUT), user("steer one")];
			streamClaudeAgentSdk(model, { messages: steered, tools: [tool] }, { cwd: root });
			streamClaudeAgentSdk(model, { messages: [...steered, user("steer two")], tools: [tool] }, { cwd: root });
			firstQuery.release();
			assert.equal(await waitFor(() => calls.length === 2), true, "the steer replays as a continuation query");

			onPiHistoryReplaced("session_compact");
			await collect(streamClaudeAgentSdk(model, {
				messages: [user(SUMMARY), assistantToolCall("t1"), toolResult("t1", TOOL_OUTPUT), user("steer two")],
				tools: [tool],
			}, { cwd: root }));

			assert.equal(calls.length, 3, "the replacement still runs after the child throws");
			assert.equal(calls[2].prompt, HISTORY_REPLACED_PROMPT);
			assert.notEqual(calls[2].options.resume, SESSION_ID, "on a session rotated away from the killed child");
			assert.equal(
				readFileSync(diagPath, "utf8").includes("deferred_user_messages_dropped"),
				false,
				"the kill is this restart's own doing, so it drops no input and diagnoses none",
			);
			assert.deepEqual(
				importedMessages(root, calls[2].options.resume).filter((message) => typeof message.content === "string").map((message) => message.content),
				[SUMMARY, "steer two"],
				"the steer reaches Claude through the rebuild instead",
			);
		});
	});

	it("completes the handover when closing the stale query throws", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls }) => {
			onPiHistoryReplaced("session_compact");

			const events = await collect(streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root }));

			assert.equal(calls.length, 2, "the replacement still opens");
			assert.deepEqual(events.filter((event) => event.type === "text_delta").map((event) => event.delta), ["restarted"]);
			assert.equal(events.filter((event) => event.type === "done").length, 1, "and the callback's stream ends rather than leaving pi waiting");
		}, closeThrowingQuery);
	});

	it("hands over a later connector-free turn in the same lane", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, queued, firstQuery }) => {
			// Turn one runs a connector and finishes; its audit belongs to that query.
			firstQuery.release();
			assert.equal(await waitFor(() => ctx().activeQuery === null), true, "the connector turn settled");

			const second = {};
			queued.push(() => toolCallQuery(second));
			await collect(streamClaudeAgentSdk(model, { messages: [user(SUMMARY), user("a turn with no connector")], tools: [tool] }, { cwd: root }));
			onPiHistoryReplaced("session_compact");

			// The refused path leaves the callback stream open on the stale query, so
			// wait for the replacement rather than for this stream to end.
			streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root });

			assert.equal(await waitFor(() => calls.length === 3), true, "this turn ran no connector, so the handover happens");
			assert.equal(calls[2].prompt, HISTORY_REPLACED_PROMPT, "on the replacement query");
			assert.equal(second.closed, true, "and the stale query is stopped");
		}, (record) => childSideQuery(record, "mcp__claude_ai_slack__post_message"));
	});

	it("ends the turn rather than restarting when the request is already aborted", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, abort }) => {
			onPiHistoryReplaced("session_compact");

			const events = collect(streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root, signal: abort.signal }));
			abort.abort(); // the user stops the turn before the stale query has torn down
			const collected = await events;

			assert.equal(calls.length, 1, "no replacement is spawned for a request that is already gone");
			assert.deepEqual(
				collected.slice(-1).map((event) => ({ type: event.type, reason: event.reason })),
				[{ type: "error", reason: "aborted" }],
				"the callback's stream ends on the abort",
			);
		});
	});
});
