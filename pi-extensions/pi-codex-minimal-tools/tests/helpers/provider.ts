import { normalizeContext, type AssistantMessage, type AssistantMessageEventStream, type Context } from "@earendil-works/pi-ai";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { setImmediate } from "node:timers/promises";
import type { TestContext } from "node:test";
import { registerOpenAICodexCustomProvider } from "../../src/provider-shim.js";
import { environment, noProxyEnvironment, world } from "./world.js";

let providerCwd: string | undefined;

/** Restore transport globals and isolate settings for each provider case. */
export function providerWorld(t: Pick<TestContext, "after">) {
	const fixture = world(t);
	providerCwd = fixture.cwd;
	t.after(() => { providerCwd = undefined; });
	environment(t, { ...noProxyEnvironment, PI_CODING_AGENT_DIR: fixture.agent });
	const fetch = globalThis.fetch;
	t.after(() => { globalThis.fetch = fetch; });
	return fixture;
}

/**
 * Resolve when the provider makes its first fetch. The SSE body compresses on the
 * libuv thread pool before that fetch, a wait no mocked clock schedules, so a case
 * advances its clock only once this resolves.
 */
export function firstFetch(): Promise<void> {
	const fetch = globalThis.fetch;
	return new Promise((resolve) => {
		globalThis.fetch = (...args: Parameters<typeof fetch>) => {
			globalThis.fetch = fetch;
			resolve();
			return fetch(...args);
		};
	});
}

/** Advance the test clock only after pending request promises have settled. */
export async function finishRetries<T>(t: TestContext, pending: Promise<T>): Promise<T> {
	let settled = false;
	const fetched = firstFetch();
	const observed = pending.finally(() => { settled = true; });
	await Promise.race([fetched, observed.then(() => undefined, () => undefined)]);
	for (let step = 0; step < 12 && !settled; step++) {
		await setImmediate();
		if (!settled) t.mock.timers.tick(10_000);
	}
	assert.equal(settled, true, "provider did not settle under the controlled retry clock");
	return observed;
}

function codexJwt(): string {
	const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" } })).toString("base64");
	return `header.${payload}.signature`;
}

type Provider = { streamSimple(model: unknown, context: unknown, options: unknown): AssistantMessageEventStream };

function createCodexProvider(): Provider {
	let provider: Provider | undefined;
	const pi = {
		registerProvider(name: string, value: Provider) {
			assert.equal(name, "openai-codex");
			provider = value;
		},
		on() {},
		registerMessageRenderer() {},
	};
	registerOpenAICodexCustomProvider(pi as never, { getCurrentCwd: () => { assert.ok(providerCwd); return providerCwd; } });
	assert.ok(provider);
	return provider;
}

export async function runCodexProvider(
	streamOptions: Record<string, unknown> = {},
	modelOverrides: Record<string, unknown> = {},
	contextOverrides: Record<string, unknown> = {},
): Promise<AssistantMessage> {
	// Pi hands a provider the normalized transcript, never the raw Context.
	const provider = createCodexProvider();
	const stream = provider.streamSimple(
		{
			provider: "openai-codex",
			api: "openai-codex-responses",
			id: "gpt-6-astra",
			baseUrl: "https://example.test/backend-api",
			headers: {},
			input: ["text"],
			reasoning: false,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			...modelOverrides,
		},
		normalizeContext({
			systemPrompt: "",
			messages: [{ role: "user", content: "hello", timestamp: 0 }],
			tools: [],
			...contextOverrides,
		} as Context),
		{ apiKey: codexJwt(), transport: "sse", ...streamOptions },
	);
	return stream.result();
}

export function errorResponse(status: number, body: unknown, statusText = "Error"): Response {
	return new Response(typeof body === "string" ? body : JSON.stringify(body), { status, statusText });
}

export const completedEvent = {
	type: "response.completed",
	response: {
		id: "resp_ok",
		status: "completed",
		usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } },
	},
};

export function sseResponse(body: string): Response {
	return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

export function successSseResponse(): Response {
	return sseResponse(`data: ${JSON.stringify(completedEvent)}\n\n`);
}


/** Bound a real network assertion; always clear the test's deadline timer. */
export async function withinDeadline<T>(pending: Promise<T>): Promise<T> {
	let timer: ReturnType<typeof setTimeout> | undefined;
	try {
		return await Promise.race([pending, new Promise<never>((_resolve, reject) => {
			timer = setTimeout(() => reject(new Error("transport did not settle within the test deadline")), 2_000);
		})]);
	} finally {
		clearTimeout(timer);
	}
}

/** Send HTTP or WebSocket headers on a loopback socket, then remain silent. */
export async function stalledHttpServer(t: Pick<TestContext, "after">, transport: "sse" | "websocket" | "connect" = "sse") {
	let close: () => void = () => {};
	const closed = new Promise<void>(resolve => { close = resolve; });
	let upgrade: () => void = () => {};
	const upgraded = new Promise<void>(resolve => { upgrade = resolve; });
	let clientEnd: () => void = () => {};
	const clientEnded = new Promise<void>(resolve => { clientEnd = resolve; });
	const sockets = new Set<import("node:net").Socket>();
	const server = createServer((_request, response) => {
		response.writeHead(200, { "content-type": "text/event-stream" });
		response.flushHeaders();
	});
	server.on("connection", socket => {
		sockets.add(socket);
		socket.on("close", () => { sockets.delete(socket); close(); });
	});
	server.on("upgrade", (request, socket) => {
		upgrade();
		if (transport === "connect") {
			// An HTTP upgrade leaves the peer half-open. Draining exposes
			// client EOF before we finish the peer side, without fixture teardown.
			socket.on("end", () => { clientEnd(); socket.end(); });
			socket.resume();
			return;
		}
		const key = request.headers["sec-websocket-key"];
		assert.equal(typeof key, "string");
		const accept = createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
		socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
		// A close frame ends the faux server's socket; no response frames are sent.
		socket.on("data", data => { if ((data[0]! & 0x0f) === 8) socket.end(); });
	});
	server.listen(0, "127.0.0.1");
	await once(server, "listening");
	t.after(async () => {
		for (const socket of sockets) socket.destroy();
		await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
	});
	const address = server.address();
	assert.ok(address && typeof address !== "string");
	return { url: `http://127.0.0.1:${address.port}/backend-api`, closed, upgraded, clientEnded };
}

type Listener = (event: unknown) => void;

/** Replace the global WebSocket with a Codex socket that records each sent request and answers it with one completed text response. */
export function codexWebSocket(t: Pick<TestContext, "after">): { requests: Array<Record<string, any>> } {
	const requests: Array<Record<string, any>> = [];
	class ScriptedCodexSocket {
		readyState = 1;
		private readonly listeners = new Map<string, Set<Listener>>();
		constructor() {
			globalThis.setImmediate(() => this.emit("open", {}));
		}
		addEventListener(type: string, listener: Listener) {
			const set = this.listeners.get(type) ?? new Set<Listener>();
			set.add(listener);
			this.listeners.set(type, set);
		}
		removeEventListener(type: string, listener: Listener) {
			this.listeners.get(type)?.delete(listener);
		}
		send(data: string) {
			requests.push(JSON.parse(data));
			const id = `resp_${requests.length}`;
			const messageId = `msg_${requests.length}`;
			const events = [
				{ type: "response.created", response: { id } },
				{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: messageId } },
				{ type: "response.output_text.delta", output_index: 0, content_index: 0, delta: "ok" },
				{ type: "response.output_item.done", output_index: 0, item: { type: "message", id: messageId, content: [{ type: "output_text", text: "ok" }] } },
				{ ...completedEvent, response: { ...completedEvent.response, id } },
			];
			globalThis.setImmediate(() => { for (const event of events) this.emit("message", { data: JSON.stringify(event) }); });
		}
		close() {
			this.readyState = 3;
		}
		private emit(type: string, event: unknown) {
			for (const listener of [...(this.listeners.get(type) ?? [])]) listener(event);
		}
	}
	const global = globalThis as { WebSocket?: unknown };
	const previous = global.WebSocket;
	global.WebSocket = ScriptedCodexSocket;
	t.after(() => { global.WebSocket = previous; });
	return { requests };
}
