import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import test from "node:test";
import { CodexBridge } from "../src/bridge.ts";

class FakeClient extends EventEmitter {
	requests = [];
	responses = [];
	closed = false;

	async request(method, params = {}) {
		this.requests.push([method, params]);
		if (method === "thread/start") return { thread: { id: "thread-1" } };
		if (method === "thread/resume") return { thread: { id: params.threadId } };
		if (method === "turn/start") {
			setTimeout(() => this.emit("request", {
				method: "item/tool/call",
				id: "rpc-1",
				params: {
					threadId: "thread-1",
					turnId: "turn-1",
					callId: "call-1",
					namespace: null,
					tool: "read",
					arguments: { path: "README.md" },
				},
			}), 0);
			return { turn: { id: "turn-1" } };
		}
		if (method === "turn/interrupt") return {};
		throw new Error(`unexpected request ${method}`);
	}

	respond(id, result) {
		this.responses.push([id, result]);
		queueMicrotask(() => {
			this.emit("notification", {
				method: "item/agentMessage/delta",
				params: { threadId: "thread-1", turnId: "turn-1", itemId: "message-1", delta: "done" },
			});
			this.emit("notification", {
				method: "turn/completed",
				params: { threadId: "thread-1", turn: { id: "turn-1", status: "completed" } },
			});
		});
	}

	respondError(id, code, message) {
		assert.fail(`unexpected response error ${id} ${code} ${message}`);
	}

	close() {
		this.closed = true;
	}
}

class RefusalClient extends FakeClient {
	method;
	errors = [];

	constructor(method) {
		super();
		this.method = method;
	}

	async request(method, params = {}) {
		if (method !== "turn/start") return super.request(method, params);
		this.requests.push([method, params]);
		setTimeout(() => this.emit("request", {
			method: this.method,
			id: "rpc-refused",
			params: {},
		}), 0);
		return { turn: { id: "turn-1" } };
	}

	respondError(id, code, message) {
		this.errors.push([id, code, message]);
	}
}

const model = {
	id: "gpt-test",
	name: "GPT Test",
	api: "codex-app-server",
	provider: "pi-codex",
	baseUrl: "codex-app-server",
	reasoning: true,
	input: ["text"],
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	contextWindow: 128000,
	maxTokens: 32000,
};

const system = {
	role: "system",
	content: "Use the declared tools.",
	toolsAdded: [{ name: "read", description: "Read a file", parameters: { type: "object", properties: { path: { type: "string" } } } }],
	timestamp: 1,
};

async function collect(stream) {
	const events = [];
	for await (const event of stream) events.push(event);
	return events;
}

test("a dynamic tool call returns through Pi and resumes the same Codex turn", async () => {
	const client = new FakeClient();
	const bridge = new CodexBridge({
		codexHome: "/seeded/codex",
		cwd: "/workspace",
		startClient: async () => client,
	});
	const first = await collect(bridge.streamSimple(model, {
		messages: [system, { role: "user", content: "Read the file", timestamp: 2 }],
	}));
	const toolDone = first.at(-1);
	assert.equal(toolDone.type, "done");
	assert.equal(toolDone.reason, "toolUse");
	assert.equal(toolDone.message.responseId, "thread-1");
	assert.deepEqual(toolDone.message.content.at(-1), {
		type: "toolCall",
		id: "call-1",
		name: "read",
		arguments: { path: "README.md" },
	});

	const second = await collect(bridge.streamSimple(model, {
		messages: [
			system,
			{ role: "user", content: "Read the file", timestamp: 2 },
			toolDone.message,
			{
				role: "toolResult",
				toolCallId: "call-1",
				toolName: "read",
				content: [{ type: "text", text: "file contents" }],
				isError: false,
				timestamp: 3,
			},
		],
	}));
	const final = second.at(-1);
	assert.equal(final.type, "done");
	assert.equal(final.reason, "stop");
	assert.equal(final.message.content.at(-1).text, "done");
	assert.deepEqual(client.responses, [[
		"rpc-1",
		{ contentItems: [{ type: "inputText", text: "file contents" }], success: true },
	]]);
	assert.equal(client.requests.filter(([method]) => method === "thread/start").length, 1);
	assert.equal(client.requests.filter(([method]) => method === "turn/start").length, 1);
	await bridge.close();
	assert.equal(client.closed, true);
});

for (const [method, expected] of [
	["account/chatgptAuthTokens/refresh", "codex-credential-refresh-refused"],
	["item/commandExecution/requestApproval", "codex-native-tool-refused"],
]) {
	test(`the bridge refuses the app-server request ${method}`, async () => {
		const client = new RefusalClient(method);
		const bridge = new CodexBridge({
			codexHome: "/seeded/codex",
			cwd: "/workspace",
			startClient: async () => client,
		});
		const events = await collect(bridge.streamSimple(model, {
			messages: [system, { role: "user", content: "Do not bypass Pi", timestamp: 2 }],
		}));
		assert.equal(events.at(-1).type, "error");
		assert.equal(events.at(-1).error.errorMessage, `${expected} method=${method}`);
		assert.deepEqual(client.errors, [["rpc-refused", -32601, expected]]);
		assert.equal(client.closed, true);
	});
}
