// A scripted stand-in for one app-server connection: the bridge's own router,
// planner and streams run against it unchanged.
import { EventEmitter } from "node:events";

export const THREAD = "thread-1";
export const TURN = "turn-1";

export class FakeClient extends EventEmitter {
	requests = [];
	responses = [];
	errors = [];
	killed;
	#nextTurn = 1;
	#handlers;

	/** `handlers[method](params, client)` answers one request; the defaults
	 * answer a clean start with no MCP servers and no unreviewed feature. */
	constructor(handlers = {}) {
		super();
		this.#handlers = {
			"config/read": () => ({ config: {} }),
			"thread/start": () => ({ thread: { id: THREAD } }),
			"thread/resume": (params) => ({ thread: { id: params.threadId }, initialTurnsPage: { data: [] } }),
			"experimentalFeature/list": () => ({ data: [], nextCursor: null }),
			"turn/start": () => ({ turn: { id: `turn-${this.#nextTurn++}` } }),
			"turn/steer": (params) => ({ turnId: params.expectedTurnId }),
			"turn/interrupt": () => ({}),
			...handlers,
		};
	}

	async request(method, params = {}) {
		this.requests.push([method, params]);
		const handler = this.#handlers[method];
		if (!handler) throw new Error(`unexpected request ${method}`);
		return handler(params, this);
	}

	async requestDecoded(method, params, decode) {
		return decode(await this.request(method, params));
	}

	notify() {}

	respond(id, result) {
		this.responses.push([id, result]);
		this.emit("responded", id, result);
	}

	respondError(id, code, message) {
		this.errors.push([id, code, message]);
	}

	kill(reason) {
		if (this.killed !== undefined) return Promise.resolve();
		this.killed = reason;
		this.emit("closed", reason);
		return Promise.resolve();
	}

	/** Send a server request or notification on the next tick. */
	serverRequest(id, method, params) {
		setImmediate(() => this.emit("request", { kind: "request", id, method, params }));
	}

	notification(method, params) {
		setImmediate(() => this.emit("notification", { kind: "notification", method, params }));
	}

	toolCall(id, callId, turnId = TURN, tool = "read", threadId = THREAD) {
		this.serverRequest(id, "item/tool/call", { threadId, turnId, callId, namespace: null, tool, arguments: { path: callId } });
	}

	text(delta, turnId = TURN, threadId = THREAD) {
		this.notification("item/agentMessage/delta", { threadId, turnId, itemId: `msg-${turnId}`, delta });
	}

	complete(turnId = TURN, status = "completed", threadId = THREAD) {
		this.notification("turn/completed", { threadId, turn: { id: turnId, status, error: null } });
	}
}

export const model = {
	id: "gpt-test",
	name: "GPT Test",
	api: "codex-app-server",
	provider: "pi-codex",
	baseUrl: "codex-app-server",
	reasoning: true,
	thinkingLevelMap: { off: "none", minimal: null, low: "low", medium: "medium", high: "high", xhigh: null, max: null },
	input: ["text", "image"],
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	contextWindow: 128000,
	maxTokens: 32000,
};

export const readTool = { name: "read", description: "Read a file", parameters: { type: "object", properties: { path: { type: "string" } } } };

export function system(tools = [readTool]) {
	return { role: "system", content: "Use the declared tools.", toolsAdded: tools, timestamp: 1 };
}

export function user(content, timestamp = 2) {
	return { role: "user", content, timestamp };
}

export function toolResult(callId, text = `result-${callId}`, toolName = "read") {
	return { role: "toolResult", toolCallId: callId, toolName, content: [{ type: "text", text }], isError: false, timestamp: 3 };
}

export async function collect(stream) {
	const events = [];
	for await (const event of stream) events.push(event);
	return events;
}

/** The terminal event of a stream. */
export async function finish(stream) {
	return (await collect(stream)).at(-1);
}
