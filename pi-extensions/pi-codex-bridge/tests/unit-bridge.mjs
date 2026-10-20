import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { CodexBridge } from "../src/bridge.ts";
import { CodexRequestError } from "../src/json-rpc.ts";
import { buildDynamicTools } from "../src/dynamic-tools.ts";
import { LOST_TOOL_RESULT_TEXT } from "../src/tool-pairing.ts";
import { FakeClient, TURN, THREAD, finish, model, readTool, system, toolResult, user } from "./lib/fake-client.mjs";

const scratch = join(process.cwd(), "tmp");
mkdirSync(scratch, { recursive: true });
const codexHome = mkdtempSync(join(scratch, "bridge-home-"));
writeFileSync(join(codexHome, "auth.json"), "{}");

function bridgeFor(client, counter = { connects: 0 }) {
	return new CodexBridge({ codexHome, cwd: "/workspace", connect: async () => { counter.connects++; return client; } });
}

function methods(client, name) {
	return client.requests.filter(([method]) => method === name);
}

test("a tool call returns through Pi and continues the same Codex turn", async () => {
	const client = new FakeClient({
		"turn/start": () => { client.toolCall("rpc-1", "call-1"); return { turn: { id: TURN } }; },
	});
	client.on("responded", () => { client.text("done"); client.complete(); });
	const bridge = bridgeFor(client);
	const first = await finish(bridge.streamSimple(model, { messages: [system(), user("Read the file")] }));
	assert.equal(first.reason, "toolUse");
	assert.deepEqual(first.message.content.at(-1), { type: "toolCall", id: "call-1", name: "read", arguments: { path: "call-1" } });
	const second = await finish(bridge.streamSimple(model, { messages: [system(), user("Read the file"), first.message, toolResult("call-1", "file contents")] }));
	assert.equal(second.reason, "stop");
	assert.equal(second.message.content.at(-1).text, "done");
	assert.deepEqual(client.responses, [["rpc-1", { contentItems: [{ type: "inputText", text: "file contents" }], success: true }]]);
	assert.equal(methods(client, "thread/start").length, 1);
	assert.equal(methods(client, "turn/start").length, 1);
	await bridge.close();
});

// The second call arrives while no stream reads the thread: the first stream
// has ended with toolUse and Pi is running the tool.
test("a tool call that arrives between streams is answered by the next one", { timeout: 5000 }, async () => {
	const client = new FakeClient({
		"turn/start": () => { client.toolCall("rpc-1", "call-1"); return { turn: { id: TURN } }; },
	});
	client.on("responded", (id) => {
		if (id === "rpc-2") { client.text("both"); client.complete(); }
	});
	const bridge = bridgeFor(client);
	const transcript = [system(), user("Read two files")];
	const first = await finish(bridge.streamSimple(model, { messages: transcript }));
	assert.equal(first.reason, "toolUse");
	client.toolCall("rpc-2", "call-2");
	await new Promise((resolve) => setTimeout(resolve, 20));
	transcript.push(first.message, toolResult("call-1"));
	const second = await finish(bridge.streamSimple(model, { messages: transcript }));
	assert.equal(second.reason, "toolUse");
	assert.equal(second.message.content.at(-1).id, "call-2");
	transcript.push(second.message, toolResult("call-2"));
	const third = await finish(bridge.streamSimple(model, { messages: transcript }));
	assert.equal(third.reason, "stop");
	assert.deepEqual(client.responses.map(([id]) => id), ["rpc-1", "rpc-2"]);
	await bridge.close();
});

test("a call Pi's transcript has no result for is answered as lost", async () => {
	const client = new FakeClient({
		"turn/start": () => { client.toolCall("rpc-1", "call-1"); return { turn: { id: TURN } }; },
		"turn/steer": () => { client.text("ok"); client.complete(); return { turnId: TURN }; },
	});
	const bridge = bridgeFor(client);
	const first = await finish(bridge.streamSimple(model, { messages: [system(), user("Read the file")] }));
	assert.equal(first.reason, "toolUse");
	// The user wrote again and the transcript holds no result for the call.
	const next = await finish(bridge.streamSimple(model, { messages: [system(), user("Read the file"), first.message, user("Never mind", 4)] }));
	assert.equal(next.reason, "stop");
	assert.deepEqual(client.responses, [["rpc-1", { contentItems: [{ type: "inputText", text: LOST_TOOL_RESULT_TEXT }], success: false }]]);
	const [[, steer]] = methods(client, "turn/steer");
	assert.deepEqual(steer.input, [{ type: "text", text: "Never mind", text_elements: [] }]);
	assert.equal(steer.expectedTurnId, TURN);
	await bridge.close();
});

// Esc during a tool: Pi records an aborted result for the call, then calls
// the stream again with the aborted signal. The bridge's child outlives that
// stream, and the next prompt abandons the open call on the same child.
test("an abort during a tool keeps the child, and the next prompt answers the open call as lost on it", { timeout: 5000 }, async () => {
	const clients = [];
	let threads = 0;
	const connect = async () => {
		const client = new FakeClient({
			"thread/start": () => ({ thread: { id: `thread-${++threads}` } }),
			"turn/start": (params) => {
				if (params.threadId === "thread-1") client.toolCall("rpc-1", "call-1");
				else { client.text("next", TURN, params.threadId); client.complete(TURN, "completed", params.threadId); }
				return { turn: { id: TURN } };
			},
		});
		clients.push(client);
		return client;
	};
	const bridge = new CodexBridge({ codexHome, cwd: "/workspace", connect });
	const transcript = [system(), user("Read the file")];
	const first = await finish(bridge.streamSimple(model, { messages: transcript }));
	assert.equal(first.reason, "toolUse");
	transcript.push(first.message, { ...toolResult("call-1", "Operation aborted"), isError: true });
	const abort = new AbortController();
	abort.abort();
	const stopped = await finish(bridge.streamSimple(model, { messages: transcript }, { signal: abort.signal }));
	assert.equal(stopped.reason, "aborted");
	assert.equal(clients.length, 1);
	assert.equal(clients[0].killed, undefined);
	transcript.push(stopped.error, user("Next", 4));
	const next = await finish(bridge.streamSimple(model, { messages: transcript }));
	assert.equal(next.reason, "stop", next.error?.errorMessage);
	assert.equal(clients.length, 1);
	assert.deepEqual(clients[0].responses, [["rpc-1", { contentItems: [{ type: "inputText", text: LOST_TOOL_RESULT_TEXT }], success: false }]]);
	assert.deepEqual(methods(clients[0], "turn/interrupt").map(([, params]) => params), [{ threadId: "thread-1", turnId: TURN }]);
	await bridge.close();
});

// One row per way the boundary can stop matching Codex's thread. Each must
// start a new thread whose first turn replays the transcript.
const readSignature = buildDynamicTools([readTool]).signature;
for (const row of [
	{ name: "warm: Codex's latest turn is not Pi's boundary", warm: true, boundaryTurn: "turn-older", tools: [readTool] },
	{ name: "warm: Pi's tool set changed since the thread started", warm: true, boundaryTurn: TURN, tools: [{ name: "write", description: "Write", parameters: { type: "object" } }] },
	{ name: "cold: the resumed thread's latest turn is not Pi's boundary", warm: false, boundaryTurn: TURN, resumedTurn: "turn-later", tools: [readTool] },
]) {
	test(`boundary mismatch starts a new thread: ${row.name}`, async () => {
		let threads = 0;
		const client = new FakeClient({
			"thread/start": () => ({ thread: { id: `thread-${++threads}` } }),
			"thread/resume": (params) => ({ thread: { id: params.threadId }, initialTurnsPage: { data: [{ id: row.resumedTurn }] } }),
			"turn/start": (params) => { client.text("answer", TURN, params.threadId); client.complete(TURN, "completed", params.threadId); return { turn: { id: TURN } }; },
		});
		const bridge = bridgeFor(client);
		let boundary = { role: "assistant", content: [{ type: "text", text: "earlier" }], api: "codex-app-server", provider: "pi-codex", model: model.id, stopReason: "stop", timestamp: 3 };
		if (row.warm) {
			const first = await finish(bridge.streamSimple(model, { messages: [system(), user("First")] }));
			assert.equal(first.reason, "stop");
			boundary = first.message;
		}
		boundary = { ...boundary, responseId: `codex-thread:thread-1:${row.boundaryTurn}:${readSignature}` };
		const final = await finish(bridge.streamSimple(model, { messages: [system(row.tools), user("First"), boundary, user("Second", 4)] }));
		assert.equal(final.reason, "stop", final.message?.errorMessage);
		assert.equal(methods(client, "thread/resume").length, row.warm ? 0 : 1);
		assert.equal(methods(client, "thread/start").length, row.warm ? 2 : 1);
		const [, params] = methods(client, "turn/start").at(-1);
		assert.equal(params.threadId, row.warm ? "thread-2" : "thread-1");
		assert.match(params.input[0].text, /^Conversation so far, replayed from Pi:/);
		assert.deepEqual(params.input.at(-1), { type: "text", text: "Second", text_elements: [] });
		await bridge.close();
	});
}

test("a matching boundary continues the thread without a new one", async () => {
	const client = new FakeClient({
		"turn/start": (params) => { client.text("answer"); client.complete(); return { turn: { id: TURN } }; },
	});
	const bridge = bridgeFor(client);
	const first = await finish(bridge.streamSimple(model, { messages: [system(), user("First")] }));
	const final = await finish(bridge.streamSimple(model, { messages: [system(), user("First"), first.message, user("Second", 4)] }));
	assert.equal(final.reason, "stop", final.message?.errorMessage);
	assert.equal(methods(client, "thread/start").length, 1);
	assert.deepEqual(methods(client, "turn/start").at(-1)[1].input, [{ type: "text", text: "Second", text_elements: [] }]);
	await bridge.close();
});

test("the bridge refuses Codex's request for ChatGPT tokens", async () => {
	const client = new FakeClient({
		"turn/start": () => { client.serverRequest("rpc-refresh", "account/chatgptAuthTokens/refresh", { reason: "unauthorized" }); return { turn: { id: TURN } }; },
	});
	const bridge = bridgeFor(client);
	const end = await finish(bridge.streamSimple(model, { messages: [system(), user("Hello")] }));
	assert.equal(end.type, "error");
	assert.equal(end.error.errorMessage, "codex-credential-refresh-refused method=account/chatgptAuthTokens/refresh");
	assert.deepEqual(client.errors, [["rpc-refresh", -32601, "codex-credential-refresh-refused"]]);
	assert.deepEqual(client.responses, []);
	assert.ok(methods(client, "turn/interrupt").length > 0);
	await bridge.close();
});

// The guards that hold for a whole turn, one row each: the key the stream
// fails with and whether the child is stopped.
for (const row of [
	{ name: "a configured MCP server starting", send: (client) => client.notification("mcpServer/startupStatus/updated", { threadId: THREAD, name: "marker", status: "starting", error: null, failureReason: null }), key: "codex-mcp-started name=marker", killed: true },
	{ name: "a native item starting", send: (client) => client.notification("item/started", { threadId: THREAD, turnId: TURN, item: { type: "commandExecution" }, startedAtMs: 1 }), key: "codex-native-item type=commandExecution", killed: false },
	{ name: "a turn on a thread Pi did not start", send: (client) => client.notification("turn/started", { threadId: "thread-sub", turn: { id: "turn-sub" } }), key: "codex-foreign-thread thread=thread-sub", killed: true },
]) {
	test(`the turn is refused on ${row.name}`, async () => {
		const client = new FakeClient({ "turn/start": () => { row.send(client); return { turn: { id: TURN } }; } });
		const bridge = bridgeFor(client);
		const end = await finish(bridge.streamSimple(model, { messages: [system(), user("Hello")] }));
		assert.equal(end.type, "error");
		assert.equal(end.error.errorMessage, row.key);
		assert.equal(client.killed?.message, row.killed ? row.key : undefined);
		if (!row.killed) assert.ok(methods(client, "turn/interrupt").length > 0);
		await bridge.close();
	});
}

test("an enabled feature no review covers refuses the thread before a turn", async () => {
	const client = new FakeClient({ "experimentalFeature/list": () => ({ data: [{ name: "js_repl", enabled: true }, { name: "fast_mode", enabled: true }], nextCursor: null }) });
	const bridge = bridgeFor(client);
	const end = await finish(bridge.streamSimple(model, { messages: [system(), user("Hello")] }));
	assert.equal(end.error.errorMessage, "codex-feature-unreviewed name=js_repl");
	assert.equal(methods(client, "turn/start").length, 0);
	await bridge.close();
});

test("an abort before or during startup ends the stream as aborted and leaves the open with the bridge", { timeout: 5000 }, async () => {
	// A connection that ends only when its open is aborted, as startAppServer's does.
	const opens = [];
	const stalled = new CodexBridge({ codexHome, connect: (_launch, signal) => { opens.push(signal); return new Promise((_, reject) => signal.addEventListener("abort", () => reject(signal.reason))); } });
	const early = new AbortController();
	early.abort();
	const before = await finish(stalled.streamSimple(model, { messages: [system(), user("Hello")] }, { signal: early.signal }));
	assert.equal(before.reason, "aborted");
	assert.equal(opens.length, 0);
	const late = new AbortController();
	const stream = stalled.streamSimple(model, { messages: [system(), user("Hello")] }, { signal: late.signal });
	setTimeout(() => late.abort(), 10);
	const during = await finish(stream);
	assert.equal(during.reason, "aborted");
	assert.equal(during.error.errorMessage, "codex-request-aborted");
	assert.equal(opens.length, 1);
	assert.equal(opens[0].aborted, false, "the stream's abort stopped the bridge's open");
	await stalled.close();
	assert.equal(opens[0].reason?.message, "codex-bridge-closed");
});

test("failed thread setup reuses the bridge's one child, and close stops it", async () => {
	const counter = { connects: 0 };
	const client = new FakeClient({ "thread/start": () => { throw new Error("codex-request-failed method=thread/start code=-32600"); } });
	const bridge = bridgeFor(client, counter);
	for (let attempt = 0; attempt < 2; attempt++) {
		const end = await finish(bridge.streamSimple(model, { messages: [system(), user("Hello")] }));
		assert.equal(end.error.errorMessage, "codex-request-failed method=thread/start code=-32600");
	}
	assert.equal(counter.connects, 1);
	assert.equal(client.killed, undefined);
	await bridge.close();
	assert.equal(client.killed?.message, "codex-bridge-closed");
});

test("a missing login throws before any process starts", () => {
	const counter = { connects: 0 };
	const home = mkdtempSync(join(scratch, "bridge-nologin-"));
	const bridge = new CodexBridge({ codexHome: home, connect: async () => { counter.connects++; return new FakeClient(); } });
	assert.throws(() => bridge.streamSimple(model, { messages: [system(), user("Hello")] }), (error) => error.message.split("\n")[0] === `codex-login-missing home=${home}`);
	assert.equal(counter.connects, 0);
});

test("model discovery that stalls gives no models and a keyed notice instead of holding startup", { timeout: 5000 }, async () => {
	const stalled = new FakeClient({ "model/list": () => new Promise(() => undefined) });
	const bridge = bridgeFor(stalled);
	const discovered = await bridge.discoverModels(50);
	assert.deepEqual(discovered, { models: [], notice: "codex-discovery-timeout after_ms=50" });
	assert.equal(stalled.killed?.message, "codex-discovery-timeout after_ms=50");
});

// Each server request the bridge does not serve: the exact answer Codex gets,
// the key the stream fails with, and the turn interrupted.
for (const row of [
	{ method: "item/commandExecution/requestApproval", answer: { decision: "decline" }, key: "codex-native-approval-declined method=item/commandExecution/requestApproval" },
	{ method: "item/fileChange/requestApproval", answer: { decision: "decline" }, key: "codex-native-approval-declined method=item/fileChange/requestApproval" },
	{ method: "execCommandApproval", answer: { decision: "abort" }, key: "codex-native-approval-declined method=execCommandApproval" },
	{ method: "applyPatchApproval", answer: { decision: "abort" }, key: "codex-native-approval-declined method=applyPatchApproval" },
	{ method: "item/tool/requestUserInput", error: [-32601, "codex-server-request-refused"], key: "codex-server-request-refused method=item/tool/requestUserInput" },
]) {
	test(`the bridge answers ${row.method} by refusing it`, async () => {
		const client = new FakeClient({ "turn/start": () => { client.serverRequest("rpc-x", row.method, { threadId: THREAD, turnId: TURN }); return { turn: { id: TURN } }; } });
		const bridge = bridgeFor(client);
		const end = await finish(bridge.streamSimple(model, { messages: [system(), user("Hello")] }));
		assert.equal(end.error.errorMessage, row.key);
		assert.deepEqual(client.responses, row.answer ? [["rpc-x", row.answer]] : []);
		assert.deepEqual(client.errors, row.error ? [["rpc-x", ...row.error]] : []);
		assert.ok(methods(client, "turn/interrupt").length > 0);
		await bridge.close();
	});
}

test("Codex receives the reviewed sandbox, approval policy and empty environments", async () => {
	const client = new FakeClient({ "turn/start": () => { client.complete(); return { turn: { id: TURN } }; } });
	const bridge = bridgeFor(client);
	await finish(bridge.streamSimple(model, { messages: [system(), user("Hello")] }));
	const [[, start]] = methods(client, "thread/start");
	const [[, turn]] = methods(client, "turn/start");
	assert.deepEqual([start.sandbox, start.approvalPolicy, start.environments, turn.approvalPolicy, turn.environments], ["read-only", "untrusted", [], "untrusted", []]);
	await bridge.close();
});

// A name read that fails, or that Codex answers in a shape the decoder
// refuses, starts and resumes no thread. Only Codex's own error reply carries
// the configuration hint; every other failure keeps its own key.
const CONFIG_HINT = "Codex could not load its configuration";
for (const row of [
	{ name: "failed, at a new thread", configRead: () => { throw new CodexRequestError("config/read", -32603, null); }, cold: false, key: "codex-mcp-names-unread", hint: true },
	{ name: "malformed, at a new thread", configRead: () => ({ config: { mcp_servers: "fixture" } }), cold: false, key: "codex-protocol-invalid method=config/read field=config.mcp_servers", hint: false },
	{ name: "failed, at a cold resume", configRead: () => { throw new CodexRequestError("config/read", -32603, null); }, cold: true, key: "codex-mcp-names-unread", hint: true },
	{ name: "cut off by the child's exit, at a new thread", configRead: (_params, client) => { const exit = new Error("codex-app-server-exit code=1 signal=null"); client.kill(exit); throw exit; }, cold: false, key: "codex-app-server-exit code=1 signal=null", hint: false },
]) {
	test(`a name read that is ${row.name} refuses the turn`, async () => {
		const client = new FakeClient({ "config/read": row.configRead });
		const bridge = bridgeFor(client);
		const boundary = { role: "assistant", content: [{ type: "text", text: "earlier" }], api: "codex-app-server", provider: "pi-codex", model: model.id, stopReason: "stop", responseId: `codex-thread:${THREAD}:${TURN}:${readSignature}`, timestamp: 3 };
		const messages = row.cold ? [system(), user("First"), boundary, user("Second", 4)] : [system(), user("Hello")];
		const end = await finish(bridge.streamSimple(model, { messages }));
		assert.equal(end.error.errorMessage.split("\n")[0], row.key);
		assert.equal(end.error.errorMessage.includes(CONFIG_HINT), row.hint);
		assert.equal(methods(client, "thread/start").length, 0);
		assert.equal(methods(client, "thread/resume").length, 0);
		await bridge.close();
	});
}

test("a cold resume of a thread Codex does not hold starts a new thread with the replay", async () => {
	const client = new FakeClient({
		"thread/resume": () => { throw new CodexRequestError("thread/resume", -32600, "thread-not-found"); },
		"thread/start": () => ({ thread: { id: "thread-new" } }),
		"turn/start": (params) => { client.text("fresh", TURN, params.threadId); client.complete(TURN, "completed", params.threadId); return { turn: { id: TURN } }; },
	});
	const bridge = bridgeFor(client);
	const boundary = { role: "assistant", content: [{ type: "text", text: "earlier" }], api: "codex-app-server", provider: "pi-codex", model: model.id, stopReason: "stop", responseId: `codex-thread:thread-gone:${TURN}:${readSignature}`, timestamp: 3 };
	const end = await finish(bridge.streamSimple(model, { messages: [system(), user("First"), boundary, user("Second", 4)] }));
	assert.equal(end.reason, "stop", end.error?.errorMessage);
	assert.equal(methods(client, "turn/start").at(-1)[1].threadId, "thread-new");
	assert.match(methods(client, "turn/start").at(-1)[1].input[0].text, /^Conversation so far/);
	await bridge.close();
});

test("a tool-set change during a tool batch answers the open call as lost and interrupts that turn", async () => {
	let threads = 0;
	const client = new FakeClient({
		"thread/start": () => ({ thread: { id: `thread-${++threads}` } }),
		"turn/start": (params) => {
			if (params.threadId === "thread-1") client.toolCall("rpc-1", "call-1");
			else { client.text("new thread", TURN, params.threadId); client.complete(TURN, "completed", params.threadId); }
			return { turn: { id: TURN } };
		},
	});
	const bridge = bridgeFor(client);
	const first = await finish(bridge.streamSimple(model, { messages: [system(), user("Read")] }));
	assert.equal(first.reason, "toolUse");
	const write = { name: "write", description: "Write", parameters: { type: "object" } };
	const next = await finish(bridge.streamSimple(model, { messages: [system([readTool, write]), user("Read"), first.message, toolResult("call-1")] }));
	assert.equal(next.reason, "stop", next.error?.errorMessage);
	assert.deepEqual(client.responses, [["rpc-1", { contentItems: [{ type: "inputText", text: LOST_TOOL_RESULT_TEXT }], success: false }]]);
	assert.deepEqual(methods(client, "turn/interrupt").map(([, params]) => params), [{ threadId: "thread-1", turnId: TURN }]);
	await bridge.close();
});

// Another model's turn, or a pi-codex message that failed, after the boundary
// means Codex lacks part of the transcript: warm and cold paths both replay.
const otherTurn = { role: "assistant", content: [{ type: "text", text: "OTHER-MODEL" }], api: "anthropic-messages", provider: "anthropic", model: "claude", stopReason: "stop", timestamp: 5 };
for (const row of [
	{ name: "another provider's turn, warm", warm: true, between: otherTurn },
	{ name: "a pi-codex turn that errored, warm", warm: true, between: { ...otherTurn, provider: "pi-codex", api: "codex-app-server", stopReason: "error" } },
	{ name: "another provider's turn, cold", warm: false, between: otherTurn },
]) {
	test(`a turn Codex never saw after the boundary starts a new thread: ${row.name}`, async () => {
		let threads = 0;
		const client = new FakeClient({
			"thread/start": () => ({ thread: { id: `thread-${++threads}` } }),
			"thread/resume": (params) => ({ thread: { id: params.threadId }, initialTurnsPage: { data: [{ id: TURN }] } }),
			"turn/start": (params) => { client.text("answer", TURN, params.threadId); client.complete(TURN, "completed", params.threadId); return { turn: { id: TURN } }; },
		});
		const bridge = bridgeFor(client);
		let boundary = { role: "assistant", content: [{ type: "text", text: "earlier" }], api: "codex-app-server", provider: "pi-codex", model: model.id, stopReason: "stop", responseId: `codex-thread:thread-1:${TURN}:${readSignature}`, timestamp: 3 };
		if (row.warm) boundary = (await finish(bridge.streamSimple(model, { messages: [system(), user("Q1")] }))).message;
		const end = await finish(bridge.streamSimple(model, { messages: [system(), user("Q1"), boundary, user("Q2", 4), row.between, user("Q3", 6)] }));
		assert.equal(end.reason, "stop", end.error?.errorMessage);
		assert.equal(methods(client, "thread/resume").length, 0);
		const [, params] = methods(client, "turn/start").at(-1);
		assert.equal(params.threadId, row.warm ? "thread-2" : "thread-1");
		assert.equal(methods(client, "thread/start").length, row.warm ? 2 : 1);
		if (row.between.stopReason === "stop") assert.match(params.input[0].text, /OTHER-MODEL/);
		await bridge.close();
	});
}

test("each message reports the usage of its latest model request, cache tokens apart", async () => {
	const usage = (input, cached, output, total) => ({ threadId: THREAD, turnId: TURN, tokenUsage: { last: { inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: 0, outputTokens: output, reasoningOutputTokens: 0, totalTokens: total }, total: {}, modelContextWindow: null } });
	const client = new FakeClient({ "turn/start": () => { client.toolCall("rpc-1", "call-1"); return { turn: { id: TURN } }; } });
	client.on("responded", () => {
		// The tool-call request's usage arrives after its call, then the next request's.
		client.notification("thread/tokenUsage/updated", usage(100, 40, 10, 110));
		client.notification("thread/tokenUsage/updated", usage(130, 100, 5, 135));
		client.text("done");
		client.complete();
	});
	const bridge = bridgeFor(client);
	const first = await finish(bridge.streamSimple(model, { messages: [system(), user("Read")] }));
	const second = await finish(bridge.streamSimple(model, { messages: [system(), user("Read"), first.message, toolResult("call-1")] }));
	assert.deepEqual(second.message.usage, { input: 30, output: 5, cacheRead: 100, cacheWrite: 0, totalTokens: 135, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });
	await bridge.close();
});

for (const row of [
	{ name: "Codex rejects it for another cause", error: () => new CodexRequestError("turn/interrupt", -32603, null), killed: "codex-interrupt-failed thread=thread-1 turn=turn-1" },
	{ name: "the turn had already ended", error: () => new CodexRequestError("turn/interrupt", -32600, "no-active-turn"), killed: undefined },
]) {
	test(`a rejected interrupt: ${row.name}`, async () => {
		const client = new FakeClient({
			"turn/start": () => { client.notification("item/started", { threadId: THREAD, turnId: TURN, item: { type: "commandExecution" }, startedAtMs: 1 }); return { turn: { id: TURN } }; },
			"turn/interrupt": () => { throw row.error(); },
		});
		const bridge = bridgeFor(client);
		const end = await finish(bridge.streamSimple(model, { messages: [system(), user("Hello")] }));
		assert.equal(end.error.errorMessage, "codex-native-item type=commandExecution");
		await new Promise(setImmediate);
		assert.equal(client.killed?.message, row.killed);
		await bridge.close();
	});
}

test("a second stream on a thread another stream drives is refused and leaves that stream running", { timeout: 5000 }, async () => {
	let turns = 0;
	const client = new FakeClient({ "turn/start": () => { if (++turns === 1) client.complete("turn-1"); return { turn: { id: `turn-${turns}` } }; } });
	const bridge = bridgeFor(client);
	const first = await finish(bridge.streamSimple(model, { messages: [system(), user("Q1")] }));
	const transcript = [system(), user("Q1"), first.message, user("Q2", 4)];
	// Both streams start in one tick: the first claims the thread before any await.
	const one = bridge.streamSimple(model, { messages: transcript });
	const two = await finish(bridge.streamSimple(model, { messages: transcript }));
	assert.equal(two.error.errorMessage, `codex-thread-busy thread=${THREAD}`);
	while (methods(client, "turn/start").length < 2) await new Promise(setImmediate);
	assert.equal(methods(client, "turn/interrupt").length, 0);
	client.text("second", "turn-2");
	client.complete("turn-2");
	const end = await finish(one);
	assert.equal(end.reason, "stop", end.error?.errorMessage);
	assert.equal(end.message.content.at(-1).text, "second");
	assert.equal(methods(client, "turn/start").length, 2);
	await bridge.close();
});

test("an abort before Codex answers turn/start ends the stream, and the turn Codex then starts is stopped", { timeout: 5000 }, async () => {
	let reply;
	const client = new FakeClient({ "turn/start": () => new Promise((resolve) => (reply = resolve)) });
	const bridge = bridgeFor(client);
	const abort = new AbortController();
	const stream = bridge.streamSimple(model, { messages: [system(), user("Hello")] }, { signal: abort.signal });
	while (methods(client, "turn/start").length < 1) await new Promise(setImmediate);
	abort.abort();
	const end = await finish(stream);
	assert.equal(end.reason, "aborted");
	assert.equal(end.error.errorMessage, "codex-request-aborted");
	reply({ turn: { id: TURN } });
	await new Promise(setImmediate);
	assert.deepEqual(methods(client, "turn/interrupt").map(([, params]) => params), [{ threadId: THREAD, turnId: TURN }]);
	await bridge.close();
});

test("close ends a stream that waits on a running turn", { timeout: 2000 }, async () => {
	const client = new FakeClient({ "turn/start": () => ({ turn: { id: TURN } }) });
	const bridge = bridgeFor(client);
	const stream = bridge.streamSimple(model, { messages: [system(), user("Hello")] });
	while (methods(client, "turn/start").length < 1) await new Promise(setImmediate);
	await bridge.close();
	const end = await finish(stream);
	assert.equal(end.type, "error");
	assert.equal(end.error.errorMessage, "codex-bridge-closed");
	assert.equal(client.killed?.message, "codex-bridge-closed");
});

test("an abort during a running turn ends the stream at once, and a queued call does not end it as toolUse", { timeout: 5000 }, async () => {
	const client = new FakeClient({ "turn/start": () => ({ turn: { id: TURN } }) });
	const bridge = bridgeFor(client);
	const abort = new AbortController();
	const stream = bridge.streamSimple(model, { messages: [system(), user("Hello")] }, { signal: abort.signal });
	while (methods(client, "turn/start").length < 1) await new Promise(setImmediate);
	await new Promise(setImmediate);
	// The call reaches the queue first, then the abort: Codex never completes
	// the interrupted turn here, so only the bridge can end the stream.
	client.emit("request", { kind: "request", id: "rpc-late", method: "item/tool/call", params: { threadId: THREAD, turnId: TURN, callId: "call-late", namespace: null, tool: "read", arguments: {} } });
	abort.abort();
	const end = await finish(stream);
	assert.equal(end.reason, "aborted");
	assert.equal(end.error.errorMessage, "codex-request-aborted");
	assert.ok(methods(client, "turn/interrupt").length > 0);
	await bridge.close();
});

test("an abort ends a running turn's stream even when Codex never completes the turn", { timeout: 5000 }, async () => {
	const client = new FakeClient({ "turn/start": () => ({ turn: { id: TURN } }) });
	const bridge = bridgeFor(client);
	const abort = new AbortController();
	const stream = bridge.streamSimple(model, { messages: [system(), user("Hello")] }, { signal: abort.signal });
	while (methods(client, "turn/start").length < 1) await new Promise(setImmediate);
	await new Promise(setImmediate);
	abort.abort();
	const end = await finish(stream);
	assert.equal(end.reason, "aborted");
	assert.deepEqual(methods(client, "turn/interrupt").map(([, params]) => params), [{ threadId: THREAD, turnId: TURN }]);
	await bridge.close();
});
