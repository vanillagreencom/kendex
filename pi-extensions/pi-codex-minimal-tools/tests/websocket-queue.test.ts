import assert from "node:assert/strict";
import test from "node:test";
import { WEBSOCKET_QUEUE_MAX_CHARS } from "../src/provider-shim.js";
import { completedEvent, providerWorld, runCodexProvider } from "./helpers/provider.js";

/** A WebSocket that opens at once and answers the request with `events`. */
function fakeWebSocket(events: string[]) {
	return class FakeWebSocket extends EventTarget {
		readyState = 0;
		constructor(_url: string, _options: unknown) {
			super();
			setTimeout(() => {
				this.readyState = 1;
				this.dispatchEvent(new Event("open"));
			}, 0);
		}
		send(): void {
			setTimeout(() => {
				for (const data of events) this.dispatchEvent(Object.assign(new Event("message"), { data }));
			}, 0);
		}
		close(): void {
			this.readyState = 3;
		}
	};
}

for (const row of [
	{ name: "an event within the queue bound is delivered", deltaChars: 1_000, overflow: false },
	{ name: "an event past the queue bound stops the response", deltaChars: WEBSOCKET_QUEUE_MAX_CHARS, overflow: true },
]) {
	test(`websocket queue: ${row.name}`, async (t) => {
		providerWorld(t);
		const previous = (globalThis as { WebSocket?: unknown }).WebSocket;
		t.after(() => { (globalThis as { WebSocket?: unknown }).WebSocket = previous; });
		const delta = JSON.stringify({ type: "response.output_text.delta", item_id: "msg_1", output_index: 0, content_index: 0, delta: "x".repeat(row.deltaChars) });
		(globalThis as { WebSocket?: unknown }).WebSocket = fakeWebSocket([delta, JSON.stringify(completedEvent)]);
		const message = await runCodexProvider({ transport: "websocket" });
		assert.deepEqual({
			stopReason: message.stopReason,
			overflowKey: (message.errorMessage ?? "").split("\n")[0]!.startsWith("codex-websocket-queue-overflow="),
		}, {
			stopReason: row.overflow ? "error" : "stop",
			overflowKey: row.overflow,
		});
	});
}
