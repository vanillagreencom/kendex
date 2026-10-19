import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { CodexBridge } from "../src/bridge.ts";
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
	// The user aborted while the tool ran and wrote again: no tool result.
	const next = await finish(bridge.streamSimple(model, { messages: [system(), user("Read the file"), first.message, user("Never mind", 4)] }));
	assert.equal(next.reason, "stop");
	assert.deepEqual(client.responses, [["rpc-1", { contentItems: [{ type: "inputText", text: LOST_TOOL_RESULT_TEXT }], success: false }]]);
	const [[, steer]] = methods(client, "turn/steer");
	assert.deepEqual(steer.input, [{ type: "text", text: "Never mind", text_elements: [] }]);
	assert.equal(steer.expectedTurnId, TURN);
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
	{ name: "an approval request", send: (client) => client.serverRequest("rpc-approve", "item/commandExecution/requestApproval", { threadId: THREAD, turnId: TURN }), key: "codex-native-approval-declined method=item/commandExecution/requestApproval", killed: false },
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

test("an abort before or during startup ends the stream as aborted", { timeout: 5000 }, async () => {
	const counter = { connects: 0 };
	const never = new CodexBridge({ codexHome, connect: () => { counter.connects++; return new Promise(() => undefined); } });
	const early = new AbortController();
	early.abort();
	const before = await finish(never.streamSimple(model, { messages: [system(), user("Hello")] }, { signal: early.signal }));
	assert.equal(before.reason, "aborted");
	assert.equal(counter.connects, 0);
	const late = new AbortController();
	const stream = never.streamSimple(model, { messages: [system(), user("Hello")] }, { signal: late.signal });
	setTimeout(() => late.abort(), 10);
	const during = await finish(stream);
	assert.equal(during.reason, "aborted");
	assert.equal(during.error.errorMessage, "codex-request-aborted");
	await never.close();
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
