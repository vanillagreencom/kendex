/** Exercise production MCP handlers and provider result delivery with an offline SDK transport. */
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { it } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { __testSetBridgeIntegrityState, __testSetSdkQueryFactory, streamClaudeAgentSdk } from "../src/index.ts";
import { ctx, resetStack } from "../src/query-state.ts";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";

const model = { id: "claude-haiku-4-5", api: "claude-bridge", provider: "pi-claude", cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const tool = { name: "echo", description: "Return a supplied value", parameters: { type: "object", properties: { id: { type: "string" } }, required: ["id"] } };
const collect = async (stream) => { const events = []; for await (const event of stream) events.push(event); return events; };

async function withBridge(ids, run) {
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
	__testSetSdkQueryFactory(({ options }) => {
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
		const initial = await collect(streamClaudeAgentSdk(model, { messages: [{ role: "user", content: "run" }], tools: [tool] }, { cwd: root, signal: abort.signal }));
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
			deliver(results) {
				streamClaudeAgentSdk(model, { messages: [
					{ role: "assistant", content: ids.map((id) => ({ type: "toolCall", id, name: "echo", arguments: { id } })) },
					...results.map(({ id, text = id, isError = false }) => ({ role: "toolResult", toolCallId: id, content: [{ type: "text", text }], isError })),
				] }, { cwd: root });
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

const orderings = [
	{ name: "results before handlers", ids: ["t0", "t1", "t2"], steps: [["deliver", "t2", "t0", "t1"], ["handler", "t0", "t1", "t2"]] },
	{ name: "handlers before results", ids: ["t0", "t1", "t2"], steps: [["handler", "t0", "t1", "t2"], ["deliver", "t2", "t0", "t1"]] },
	{ name: "interleaved", ids: ["t0", "t1"], steps: [["handler", "t0"], ["deliver", "t0"], ["deliver", "t1"], ["handler", "t1"]] },
	{ name: "ID matching across mixed arrival order", ids: ["t0", "t1", "t2", "t3", "t4", "t5", "t6"], steps: [["handler", "t0", "t1", "t2"], ["deliver", "t4", "t3", "t2", "t1", "t0"], ["handler", "t3", "t4", "t5", "t6"], ["deliver", "t6", "t5"]] },
];
for (const row of orderings) it(row.name, { timeout: 5000 }, async () => {
	await withBridge(row.ids, async (bridge) => {
		const handlers = new Map();
		const delivered = new Set();
		for (const [action, ...ids] of row.steps) {
			if (action === "deliver") { bridge.deliver(ids.map((id) => ({ id, text: `result-${id}`, isError: id === "t0" }))); for (const id of ids) delivered.add(id); }
			else for (const id of ids) handlers.set(id, (await bridge.handler(id)).result);
			bridge.counts([...handlers.keys()].filter((id) => !delivered.has(id)).length, [...delivered].filter((id) => !handlers.has(id)).length);
		}
		for (const id of row.ids) assert.deepEqual(await handlers.get(id), { content: [{ type: "text", text: `result-${id}` }], isError: id === "t0", toolCallId: id });
		bridge.counts(0, 0);
	});
});

it("abort resolves waiting handlers and clears queued results before a fresh query", { timeout: 5000 }, async () => {
	await withBridge(["t0", "t1", "t2", "t3", "queued"], async (bridge) => {
		const handlers = [];
		for (const id of ["t0", "t1", "t2", "t3"]) handlers.push((await bridge.handler(id)).result);
		bridge.deliver([{ id: "t0", text: "resolved" }, { id: "queued", text: "stale" }]);
		bridge.counts(3, 1);
		bridge.abort();
		const results = await Promise.all(handlers);
		assert.equal(results[0].content[0].text, "resolved");
		for (const result of results.slice(1)) assert.deepEqual([result.isError, result.content[0].text.split("\n")[0]], [true, "tool-call-drain=abort"]);
		bridge.counts(0, 0);
	});
	await withBridge(["queued"], async (bridge) => {
		const fresh = (await bridge.handler("queued")).result;
		bridge.counts(1, 0);
		bridge.deliver([{ id: "queued", text: "fresh" }]);
		assert.equal((await fresh).content[0].text, "fresh");
		bridge.counts(0, 0);
	});
});
