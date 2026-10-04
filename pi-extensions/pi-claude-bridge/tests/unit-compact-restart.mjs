/**
 * Pi 0.84.4+ compacts between tool execution and the next assistant response,
 * so `session_compact` can fire while the bridge's SDK query is still waiting
 * for a Pi tool result. That query's Claude session holds the history Pi just
 * replaced, and every remaining request of the tool loop re-sends it — the
 * climbing input usage across the compactions of one reported session.
 *
 * The next provider callback must restart the query from Pi's compacted
 * context instead of delivering into it, importing the tool results Pi already
 * holds exactly once and re-running no tool. The request the query was
 * answering stays live input: a summary can replace it in Pi's context, and a
 * request imported as history reads to Claude as one already handled.
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
import { clearPackageConfigCache } from "../src/package-config.ts";
import { ctx, resetStack } from "../src/query-state.ts";
import { answerSdkQuery } from "./lib/fake-sdk-query.mjs";
import { assertSourceControl } from "./lib/source-control.mjs";
import { waitFor } from "./lib/wait-for.mjs";
import { piContext } from "./lib/transcript.mjs";

const model = { id: "claude-haiku-4-5", api: "claude-bridge", provider: "pi-claude", cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const tool = { name: "echo", description: "Return a supplied value", parameters: { type: "object", properties: { id: { type: "string" } }, required: ["id"] } };
const SESSION_ID = "11111111-1111-4111-8111-111111111111";
const FAILED_SESSION_ID = "22222222-2222-4222-8222-222222222222";
const TOOL_OUTPUT = "tool output t0";
const SUMMARY = "[summary] the earlier turns, condensed";
const OLD_TRANSCRIPT = "what the killed child had already written";

const user = (content, timestamp = Date.now()) => ({ role: "user", content, timestamp });
const assistantText = (text) => ({ role: "assistant", content: [{ type: "text", text }], timestamp: Date.now() });
const assistantToolCall = (id) => ({ role: "assistant", content: [{ type: "toolCall", id, name: "echo", arguments: { id } }], timestamp: Date.now() });
const toolResult = (id, text) => ({ role: "toolResult", toolCallId: id, content: [{ type: "text", text }], timestamp: Date.now() });
const collect = async (stream) => { const events = []; for await (const event of stream) events.push(event); return events; };
/** The live prompt a replacement sends when it carries `request`. */
const carried = (...request) => [...request, HISTORY_REPLACED_PROMPT].join("\n\n");
/** A prompt sent as blocks (it carries images), read the way the SDK reads it. */
async function promptBlocks(prompt) {
	assert.equal(typeof prompt, "object", "a prompt carrying images is sent as blocks");
	const blocks = [];
	for await (const message of prompt) blocks.push(...message.message.content);
	return blocks;
}

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

/** A replacement whose child reports `sessionId`, then fails with no output. */
function failingQuery(sessionId) {
	return {
		async *[Symbol.asyncIterator]() {
			yield { type: "system", subtype: "init", session_id: sessionId };
			yield { type: "result", subtype: "error_during_execution", errors: ["fixture-failure=replacement"] };
		},
		close() {},
		async interrupt() {},
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

/** Pi's context when it calls the provider back with the tool result. After a
 *  compaction the summary stands in place of the earlier turns. */
const toolResultDelivery = () => piContext({
	messages: [user(SUMMARY), assistantToolCall("t0"), toolResult("t0", TOOL_OUTPUT)],
	tools: [tool],
});

/** `request` is the content of the user message that opens the query. */
async function withBridge(run, openingQuery = toolCallQuery, { request = "run the tool" } = {}) {
	const root = mkdtempSync(join(tmpdir(), "bridge-compact-restart-"));
	const env = { CLAUDE_CONFIG_DIR: root, PI_CODING_AGENT_DIR: root, CLAUDE_CODE_OAUTH_TOKEN: "offline-test", CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "0", CLAUDE_BRIDGE_DIAG_PATH: join(root, "diag.log") };
	const previous = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
	Object.assign(process.env, env);
	clearPackageConfigCache();
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
		return (queued.shift() ?? (() => answerSdkQuery("restarted", options.resume ?? SESSION_ID)))();
	});
	try {
		const preCompaction = piContext({ messages: [user("earlier prompt"), assistantText("earlier reply"), user(request)], tools: [tool] });
		const opened = await collect(streamClaudeAgentSdk(model, preCompaction, { cwd: root, signal: abort.signal }));
		assert.equal(opened.filter((event) => event.type === "done").length, 1, "the tool-call turn reached pi");
		assert.notEqual(ctx().activeQuery, null, "the query stays active, waiting for the tool result");
		await run({ root, calls, queued, firstQuery, abort, opened, diagPath: env.CLAUDE_BRIDGE_DIAG_PATH, oldSession: { path: oldSession.jsonlPath, bytes: oldSessionBytes } });
	} finally {
		firstQuery.release();
		cancelScheduledToolUseEnd(ctx());
		__testSetSdkQueryFactory();
		__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
		resetStack();
		for (const [key, value] of Object.entries(previous)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
		clearPackageConfigCache();
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
	it("restarts the query from pi's compacted context, carrying each tool result once and the request the summary replaced", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, firstQuery, oldSession }) => {
			onPiHistoryReplaced("session_compact");
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.needsRebuild, true, "the record must rebuild");
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.forceRotate, true, "away from the session the killed child still writes");

			const events = await collect(streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root }));

			assert.equal(firstQuery.closed, true, "the pre-compaction query is stopped, not continued");
			assert.equal(calls.length, 2, "the tool result opened a replacement query");
			assert.equal(calls[1].prompt, carried("run the tool"), "the replacement is still answering the request, which the summary dropped from pi's context");
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

	it("sends the request the summary replaced, then the user batch the restart callback carries, as the live prompt", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls }) => {
			onPiHistoryReplaced("session_compact");

			// Pi delivers the tool result with two follow-ups queued behind it.
			await collect(streamClaudeAgentSdk(model, piContext({
				messages: [user(SUMMARY), assistantToolCall("t0"), toolResult("t0", TOOL_OUTPUT), user("first follow-up"), user("second follow-up")],
				tools: [tool],
			}), { cwd: root }));

			assert.equal(calls.length, 2, "the callback opened the replacement");
			assert.equal(calls[1].prompt, carried("run the tool", "first follow-up", "second follow-up"), "the request, then the whole batch, is the live prompt");
			const imported = importedMessages(root, calls[1].options.resume);
			assert.deepEqual(imported.filter((message) => typeof message.content === "string").map((message) => message.content), [SUMMARY], "no follow-up is imported as history");
			assert.deepEqual(blocksOfType(imported, "tool_result").map((block) => block.content), [TOOL_OUTPUT], "and the tool result once");
		});
	});

	it("keeps the images of the request it carries", { timeout: 10_000 }, async () => {
		const image = { type: "image", data: "aGk=", mimeType: "image/png" };
		await withBridge(async ({ root, calls }) => {
			onPiHistoryReplaced("session_compact");

			await collect(streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root }));

			assert.equal(calls.length, 2);
			const blocks = await promptBlocks(calls[1].prompt);
			assert.deepEqual(blocks.filter((block) => block.type === "image").map((block) => block.source), [{ type: "base64", media_type: "image/png", data: "aGk=" }], "the image reaches the replacement");
			assert.deepEqual(blocks.filter((block) => block.type === "text" && block.text.trim()).map((block) => block.text), ["look at this", HISTORY_REPLACED_PROMPT], "beside the request's text and the notice");
		}, toolCallQuery, { request: [{ type: "text", text: "look at this" }, image] });
	});

	// The replacement stores its record as it completes, or as it fails
	// terminally; either record is what the next turn reads.
	for (const { outcome, replacement, ending } of [
		{ outcome: "completes", replacement: undefined, ending: "done" },
		{ outcome: "fails", replacement: () => failingQuery(FAILED_SESSION_ID), ending: "error" },
	]) {
		it(`stores pi's own message count as the cursor when the replacement ${outcome}, so the next turn resumes it`, { timeout: 10_000 }, async () => {
			await withBridge(async ({ root, calls, queued }) => {
				if (replacement) queued.push(replacement);
				onPiHistoryReplaced("session_compact");
				const delivery = toolResultDelivery();

				const events = await collect(streamClaudeAgentSdk(model, delivery, { cwd: root }));
				assert.deepEqual(events.filter((event) => event.type === "done" || event.type === "error").map((event) => event.type), [ending], "the replacement ended as the row says");
				assert.equal(await waitFor(() => ctx().activeQuery === null), true, "the replacement settled");
				const record = __testGetBridgeIntegrityState().sharedSession;
				assert.equal(record?.cursor, delivery.messages.length, "the appended request and notice are not pi's messages");

				const next = piContext({ messages: [...delivery.messages.slice(1), assistantText("restarted"), user("the next prompt")], tools: [tool] });
				await collect(streamClaudeAgentSdk(model, next, { cwd: root }));
				assert.equal(calls.length, 3);
				assert.equal(calls[2].options.resume, record.sessionId, "the next turn resumes the replacement's session");
				assert.equal(calls[2].prompt, "the next prompt", "with only the new message");
			});
		});
	}

	it("carries the request once through a second restart", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, queued }) => {
			const replacement = {};
			queued.push(() => toolCallQuery(replacement, "t1"));
			onPiHistoryReplaced("session_compact");
			streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root });
			assert.equal(await waitFor(() => calls.length === 2), true, "the first replacement started");
			assert.equal(calls[1].prompt, carried("run the tool"));

			// Pi compacts again while the replacement waits for its own tool result.
			onPiHistoryReplaced("session_compact");
			await collect(streamClaudeAgentSdk(model, piContext({
				messages: [user(SUMMARY), assistantToolCall("t1"), toolResult("t1", TOOL_OUTPUT)],
				tools: [tool],
			}), { cwd: root }));

			assert.equal(replacement.closed, true, "the first replacement is stopped");
			assert.equal(calls.length, 3);
			assert.equal(calls[2].prompt, carried("run the tool"), "the second carries the same request under one notice");
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

			const next = piContext({ messages: [user(SUMMARY), assistantText("kept reply"), user("the next prompt")], tools: [tool] });
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
			streamClaudeAgentSdk(model, piContext({ messages: steered, tools: [tool] }), { cwd: root });
			streamClaudeAgentSdk(model, piContext({ messages: [...steered, user("steer two")], tools: [tool] }), { cwd: root });
			firstQuery.release();
			assert.equal(await waitFor(() => calls.length === 2), true, "the steer replays as a continuation query");
			assert.equal(calls[1].prompt, "steer one");

			// Pi compacts while THAT query waits for its own tool result.
			onPiHistoryReplaced("session_compact");
			const events = await collect(streamClaudeAgentSdk(model, piContext({
				messages: [user(SUMMARY), assistantToolCall("t1"), toolResult("t1", TOOL_OUTPUT)],
				tools: [tool],
			}), { cwd: root }));

			assert.equal(continuation.closed, true, "the continuation query is stopped for the restart");
			assert.equal(calls.length, 3, "the second steer does not open another query on the replaced history");
			assert.equal(calls[2].prompt, carried("steer one", "steer two"), "the replacement carries the steer being answered and the one still queued");
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

	// Pi deep-copies its context for every provider call, so the steer its run
	// still holds is a copy of the captured one; a message the user sends again
	// with the same text has its own timestamp.
	const STEER_AT = 1_700_000_000_000;
	for (const { held, trailing, prompt, sent } of [
		{
			held: "a copy of the queued steer",
			trailing: (steer) => structuredClone(steer),
			prompt: carried("steer one", "continue"),
			sent: "the steer being answered, then the queued one Pi's run holds, sent once",
		},
		{
			held: "a new message with the queued steer's text",
			trailing: () => user("continue", STEER_AT + 1),
			prompt: carried("steer one", "continue", "continue"),
			sent: "the steer being answered, the queued one, then the new one with its text",
		},
	]) {
		it(`records no failure for a continuation whose child throws as the restart kills it, when Pi's run holds ${held}`, { timeout: 10_000 }, async () => {
			await withBridge(async ({ root, calls, queued, firstQuery, diagPath }) => {
				const continuation = {};
				queued.push(() => throwingQuery(continuation));

				const steered = [user(SUMMARY), assistantToolCall("t0"), toolResult("t0", TOOL_OUTPUT), user("steer one")];
				const steerTwo = user("continue", STEER_AT);
				streamClaudeAgentSdk(model, piContext({ messages: steered, tools: [tool] }), { cwd: root });
				streamClaudeAgentSdk(model, piContext({ messages: [...steered, steerTwo], tools: [tool] }), { cwd: root });
				firstQuery.release();
				assert.equal(await waitFor(() => calls.length === 2), true, "the steer replays as a continuation query");

				// The compaction summarized "steer one" away; pi's context ends in a
				// user run the bridge's queued steer may or may not be part of.
				onPiHistoryReplaced("session_compact");
				await collect(streamClaudeAgentSdk(model, piContext({
					messages: [user(SUMMARY), assistantToolCall("t1"), toolResult("t1", TOOL_OUTPUT), trailing(steerTwo)],
					tools: [tool],
				}), { cwd: root }));

				assert.equal(calls.length, 3, "the replacement still runs after the child throws");
				assert.equal(calls[2].prompt, prompt, sent);
				assert.notEqual(calls[2].options.resume, SESSION_ID, "on a session rotated away from the killed child");
				assert.equal(
					readFileSync(diagPath, "utf8").includes("deferred_user_messages_dropped"),
					false,
					"the kill is this restart's own doing, so it drops no input and diagnoses none",
				);
				assert.deepEqual(
					importedMessages(root, calls[2].options.resume).filter((message) => typeof message.content === "string").map((message) => message.content),
					[SUMMARY],
					"and is not imported as history Claude would read as handled",
				);
			});
		});
	}

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
			await collect(streamClaudeAgentSdk(model, piContext({ messages: [user(SUMMARY), assistantText("kept reply"), user("a turn with no connector")], tools: [tool] }), { cwd: root }));
			onPiHistoryReplaced("session_compact");

			// The refused path leaves the callback stream open on the stale query, so
			// wait for the replacement rather than for this stream to end.
			streamClaudeAgentSdk(model, toolResultDelivery(), { cwd: root });

			assert.equal(await waitFor(() => calls.length === 3), true, "this turn ran no connector, so the handover happens");
			assert.equal(calls[2].prompt, carried("a turn with no connector"), "on the replacement query");
			assert.equal(second.closed, true, "and the stale query is stopped");
		}, (record) => childSideQuery(record, "mcp__claude_ai_slack__post_message"));
	});

	it("ends the turn rather than restarting when the request is already aborted", { timeout: 10_000 }, async () => {
		await withBridge(async ({ root, calls, abort, opened }) => {
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

			// The tool-call turn pi already holds must not be rewritten by an abort
			// that lands afterwards: its tools ran.
			const delivered = opened.find((event) => event.type === "done").message;
			const aborted = collected.at(-1).error;
			assert.equal(delivered.stopReason, "toolUse", "the delivered turn keeps its own outcome");
			assert.notEqual(aborted, delivered, "and the abort reports its own message");
			assert.deepEqual(aborted.content, [], "carrying no tool call of that turn");
		});
	});
});

// Each row removes one rule from a copy of the source; the regression it names
// must turn red.
describe("source controls: the history restart's live prompt and cursor", () => {
	const rows = [
		{
			why: "the replacement drops the request it was answering",
			source: "src/index.ts",
			before: "const request = [...pending.filter((message) => !heldByPi(message)), ...trailingRun];",
			after: "const request = [...trailingRun];",
			pattern: "carrying each tool result once and the request the summary replaced",
			failure: /the replacement is still answering the request/,
		},
		{
			why: "a restart callback ending in user input drops the request it was answering",
			source: "src/index.ts",
			before: "const request = [...pending.filter((message) => !heldByPi(message)), ...trailingRun];",
			after: "const request = trailingRun.length > 0 ? trailingRun : pending;",
			pattern: "sends the request the summary replaced, then the user batch",
			failure: /the request, then the whole batch, is the live prompt/,
		},
		{
			why: "a captured steer pi's trailing run holds is sent twice",
			source: "src/index.ts",
			before: "const heldByPi = (message: Context[\"messages\"][number]) => trailingRun.some((held) => isSameUserMessage(held, message));",
			after: "const heldByPi = (_message: Context[\"messages\"][number]) => false;",
			pattern: "when Pi's run holds a copy of the queued steer",
			failure: /the steer being answered, then the queued one Pi's run holds, sent once/,
		},
		{
			why: "a new message with a captured steer's text is taken for that steer",
			source: "src/index.ts",
			before: "a.timestamp === b.timestamp && ",
			after: "",
			pattern: "when Pi's run holds a new message with the queued steer's text",
			failure: /the steer being answered, the queued one, then the new one with its text/,
		},
		{
			why: "the replacement carries the request's text without its images",
			source: "src/index.ts",
			before: "messages: [...piMessages.slice(0, runStart), ...request, {",
			after: "messages: [...piMessages.slice(0, runStart), ...request.map((message) => ({ ...message, content: messageContentToText(message.content) })), {",
			pattern: "keeps the images of the request it carries",
			failure: /a prompt carrying images is sent as blocks/,
		},
		{
			why: "the replacement drops the steers still queued",
			source: "src/index.ts",
			before: "const pending = [...unansweredRequest, ...abortCtx.deferredUserMessages.flatMap((steer) => steer.messages)];",
			after: "const pending = [...unansweredRequest];",
			pattern: "carries the replacement through a deferred continuation",
			failure: /the replacement carries the steer being answered and the one still queued/,
		},
		{
			why: "a continuation does not become the request being answered",
			source: "src/index.ts",
			before: "unansweredRequest = steer.messages;",
			after: "void steer.messages;",
			pattern: "carries the replacement through a deferred continuation",
			failure: /the replacement carries the steer being answered and the one still queued/,
		},
		{
			why: "a rebuild imports all but the last user message of a pending batch",
			source: "src/session-persistence.ts",
			before: "const priorMessages = messages.slice(0, trailingUserRunStart(messages));",
			after: "const priorMessages = messages.slice(0, -1);",
			pattern: "sends the request the summary replaced, then the user batch",
			failure: /the request, then the whole batch, is the live prompt/,
		},
		{
			why: "the appended request and notice advance the cursor",
			source: "src/index.ts",
			before: "const piMessageCount = historyRestart?.piMessageCount ?? context.messages.length;",
			after: "const piMessageCount = context.messages.length;",
			pattern: "stores pi's own message count as the cursor when the replacement completes",
			failure: /the appended request and notice are not pi's messages/,
		},
		{
			why: "a terminal failure of the replacement stores a cursor past pi's messages",
			source: "src/index.ts",
			before: "const cursor = Math.max(piMessageCount, abortCtx.latestCursor, activeSession?.cursor ?? 0);\n\t\t\t\t\tdebug(`provider: terminal failure",
			after: "const cursor = Math.max(context.messages.length, abortCtx.latestCursor, activeSession?.cursor ?? 0);\n\t\t\t\t\tdebug(`provider: terminal failure",
			pattern: "stores pi's own message count as the cursor when the replacement fails",
			failure: /the appended request and notice are not pi's messages/,
		},
		{
			why: "a second restart carries the first replacement's whole prompt",
			source: "src/index.ts",
			before: "let unansweredRequest = historyRestart?.request ?? promptMessages;",
			after: "let unansweredRequest = promptMessages;",
			pattern: "carries the request once through a second restart",
			failure: /the second carries the same request under one notice/,
		},
	];
	for (const { why, ...row } of rows) {
		it(why, { timeout: 60_000 }, () => assertSourceControl({ ...row, suite: "unit-compact-restart.mjs" }));
	}
});
