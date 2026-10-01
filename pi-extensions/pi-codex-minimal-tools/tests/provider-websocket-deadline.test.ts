import assert from "node:assert/strict";
import test from "node:test";
import { setImmediate } from "node:timers/promises";
import { providerWorld, runCodexProvider, stalledHttpServer, withinDeadline } from "./helpers/provider.js";

// These cases use real handshake I/O to distinguish connect from receive stalls.
for (const row of [
	{ name: "silent receive", mode: "websocket", options: { httpIdleTimeoutMs: 50, websocketConnectTimeoutMs: 1_000 }, key: "http_idle_timeout_ms=50" },
	{ name: "Pi idle setting", mode: "websocket", options: { timeoutMs: 50, websocketConnectTimeoutMs: 1_000 }, key: "http_idle_timeout_ms=50" },
	{ name: "stalled open", mode: "connect", options: { httpIdleTimeoutMs: 1_000, websocketConnectTimeoutMs: 50 }, key: "websocket_connect_timeout_ms=50" },
] as const) {
	test(`WebSocket deadline: ${row.name}`, async (t) => {
		providerWorld(t);
		const server = await stalledHttpServer(t, row.mode);
		const controller = new AbortController();
		t.after(() => controller.abort());
		const result = await withinDeadline(runCodexProvider({ transport: "websocket", ...row.options, signal: controller.signal }, { baseUrl: server.url }));
		assert.equal(result.stopReason, "error");
		assert.equal(result.errorMessage?.split("\n")[0], row.key);
		if (row.mode === "connect") await withinDeadline(server.clientEnded);
		await withinDeadline(server.closed);
	});
}

test("parent cancellation terminates a stalled WebSocket upgrade", async (t) => {
	providerWorld(t);
	const server = await stalledHttpServer(t, "connect");
	const controller = new AbortController();
	t.after(() => controller.abort());
	const pending = runCodexProvider({ transport: "websocket", websocketConnectTimeoutMs: 0, signal: controller.signal }, { baseUrl: server.url });
	// Wait for the peer to receive the handshake, not a test-clock delay.
	await withinDeadline(server.upgraded);
	controller.abort();
	assert.equal((await withinDeadline(pending)).stopReason, "aborted");
	await withinDeadline(server.clientEnded);
	await withinDeadline(server.closed);
});

test("WebSocket receive deadline resets after events and zero disables the deadline", async (t) => {
	providerWorld(t);
	t.mock.timers.enable({ apis: ["setTimeout"] });
	const previous = globalThis.WebSocket;
	t.after(() => { globalThis.WebSocket = previous; });
	let socket: EventTarget | undefined;
	class SilentSocket extends EventTarget {
		readyState = 0;
		constructor() {
			super(); socket = this;
			globalThis.setImmediate(() => { this.readyState = 1; this.dispatchEvent(new Event("open")); });
		}
		send() {}
		close() { this.readyState = 3; }
	}
	globalThis.WebSocket = SilentSocket as never;
	const pending = runCodexProvider({ transport: "websocket", httpIdleTimeoutMs: 50 });
	await setImmediate();
	await setImmediate();
	t.mock.timers.tick(49);
	socket!.dispatchEvent(Object.assign(new Event("message"), { data: JSON.stringify({ type: "response.created", response: { id: "resp_1" } }) }));
	await setImmediate();
	let settled = false;
	void pending.then(() => { settled = true; });
	t.mock.timers.tick(49);
	await setImmediate();
	assert.equal(settled, false);
	t.mock.timers.tick(1);
	const result = await pending;
	assert.equal(result.errorMessage?.split("\n")[0], "http_idle_timeout_ms=50");
	const controller = new AbortController();
	const disabled = runCodexProvider({ transport: "websocket", httpIdleTimeoutMs: 0, websocketConnectTimeoutMs: 0, signal: controller.signal });
	await setImmediate();
	await setImmediate();
	t.mock.timers.tick(300_000);
	await setImmediate();
	controller.abort();
	assert.equal((await disabled).stopReason, "aborted");
});
