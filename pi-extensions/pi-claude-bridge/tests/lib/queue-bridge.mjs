/**
 * Drive production MCP handlers and provider result delivery over an offline
 * SDK transport. The bridge modules read CLAUDE_BRIDGE_DEBUG when they load, so
 * an importer that needs a known debug state sets or deletes it before a
 * dynamic import of this module.
 */
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { __testSetBridgeIntegrityState, __testSetSdkQueryFactory, streamClaudeAgentSdk } from "../../src/index.ts";
import { ctx, resetStack } from "../../src/query-state.ts";
import { cancelScheduledToolUseEnd } from "../../src/assistant-stream.ts";
import { piContext } from "./transcript.mjs";

const model = { id: "claude-haiku-4-5", api: "claude-bridge", provider: "pi-claude", cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const tool = { name: "echo", description: "Return a supplied value", parameters: { type: "object", properties: { id: { type: "string" } }, required: ["id"] } };
const collect = async (stream) => { const events = []; for await (const event of stream) events.push(event); return events; };

/** `prompt` is the user message that opens the query. */
export async function withBridge(ids, run, { prompt = "run" } = {}) {
	const root = mkdtempSync(join(tmpdir(), "bridge-queue-"));
	const env = { CLAUDE_CONFIG_DIR: root, PI_CODING_AGENT_DIR: root, CLAUDE_CODE_OAUTH_TOKEN: "offline-test", CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "0" };
	const previous = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
	Object.assign(process.env, env);
	resetStack();
	__testSetBridgeIntegrityState({ sharedSession: null, ui: { notify() {} } });
	const gate = Promise.withResolvers();
	const finished = Promise.withResolvers();
	let server;
	let client;
	const pending = [];
	const abort = new AbortController();
	let queries = 0;
	__testSetSdkQueryFactory(({ options }) => {
		// Every query after the first replays a deferred user message and
		// answers at once.
		if (++queries > 1) return {
			async *[Symbol.asyncIterator]() {
				yield { type: "system", subtype: "init", session_id: "offline-queue" };
				yield { type: "result", subtype: "success", result: "continued" };
			},
			close() {},
			async interrupt() {},
		};
		server = options.mcpServers["custom-tools"].instance;
		return {
			async *[Symbol.asyncIterator]() {
				try {
					yield { type: "system", subtype: "init", session_id: "offline-queue" };
					yield { type: "assistant", message: { content: ids.map((id) => ({ type: "tool_use", id, name: "mcp__custom-tools__echo", input: { id } })) } };
					await gate.promise;
					yield { type: "result", subtype: "success", result: "done" };
				} finally { finished.resolve(); }
			},
			close() { gate.resolve(); },
			async interrupt() { gate.resolve(); },
		};
	});
	try {
		const initial = await collect(streamClaudeAgentSdk(model, piContext({ messages: [{ role: "user", content: prompt }], tools: [tool] }), { cwd: root, signal: abort.signal }));
		assert.deepEqual(initial.find((event) => event.type === "done").message.content.map((block) => block.id), ids);
		const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
		client = new Client({ name: "queue-test", version: "1.0.0" });
		await server.connect(serverTransport);
		await client.connect(clientTransport);
		await client.listTools();
		const bridge = {
			query: ctx(),
			async handler(id) {
				const result = client.callTool({ name: "echo", arguments: { id } });
				pending.push(result);
				// Transport dispatch and schema validation are microtasks. Observe the
				// production handler registration rather than advancing a wall clock.
				for (let turn = 0; turn < 100 && !ctx().claimedToolCallIds.has(id); turn++) await Promise.resolve();
				assert.equal(ctx().claimedToolCallIds.has(id), true, `handler registered: ${id}`);
				return { result };
			},
			/** `steer` is a user message Pi appended after the results. */
			deliver(results, { steer } = {}) {
				streamClaudeAgentSdk(model, piContext({ tools: [tool], messages: [
					{ role: "assistant", content: ids.map((id) => ({ type: "toolCall", id, name: "echo", arguments: { id } })) },
					...results.map(({ id, text = id, isError = false }) => ({ role: "toolResult", toolCallId: id, content: [{ type: "text", text }], isError })),
					...(steer === undefined ? [] : [{ role: "user", content: steer }]),
				] }), { cwd: root });
			},
			/** End the query unaborted, so its deferred user messages replay, and
			 *  wait until every query has settled. */
			async finish() {
				gate.resolve();
				await finished.promise;
				for (let turn = 0; turn < 1000 && ctx().activeQuery !== null; turn++) await new Promise((resolve) => setImmediate(resolve));
				assert.equal(ctx().activeQuery, null, "every query settled");
			},
			counts(waiting, queued) {
				assert.deepEqual([ctx().pendingToolCalls.size, ctx().pendingResults.size], [waiting, queued]);
				for (const id of ctx().pendingToolCalls.keys()) assert.equal(ctx().pendingResults.has(id), false, id);
			},
			abort() { abort.abort(); },
		};
		await run(bridge);
	} finally {
		abort.abort();
		gate.resolve();
		await finished.promise;
		cancelScheduledToolUseEnd(ctx());
		await client?.close();
		await server?.close();
		await Promise.allSettled(pending);
		__testSetSdkQueryFactory();
		__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
		resetStack();
		for (const [key, value] of Object.entries(previous)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
		rmSync(root, { recursive: true, force: true });
	}
}
