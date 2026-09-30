import assert from "node:assert/strict";
import test from "node:test";
import { WEBSOCKET_QUEUE_MAX_CHARS } from "../src/provider-shim.js";
import { completedEvent, providerWorld, runCodexProvider } from "./helpers/provider.js";

type Frame = "text" | "bytes" | "blob";

/** `event` as the payload of a WebSocket frame of kind `frame`. */
function framePayload(event: string, frame: Frame): unknown {
	switch (frame) {
		case "text": return event;
		case "bytes": return new TextEncoder().encode(event);
		case "blob": return new Blob([event]);
		default: { const unreachable: never = frame; throw new Error(`unknown frame kind: ${unreachable}`); }
	}
}

/** A WebSocket that opens at once and answers the request with `events`:
 *  in one burst, or with `spaced` each in its own timer turn so the reader
 *  can take one before the next arrives. */
function fakeWebSocket(events: unknown[], spaced: boolean) {
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
			const dispatch = (data: unknown) => this.dispatchEvent(Object.assign(new Event("message"), { data }));
			if (spaced) {
				for (const data of events) setTimeout(() => dispatch(data), 0);
			} else {
				setTimeout(() => { for (const data of events) dispatch(data); }, 0);
			}
		}
		close(): void {
			this.readyState = 3;
		}
	};
}

// A burst is dispatched in one timer turn, so no event is decoded or read
// before the last one arrives: the bound counts what has arrived and is not
// yet read. Spaced events are read as they arrive, so events that pass the
// bound only in sum are delivered.
for (const row of [
	{ name: "an event within the queue bound is delivered", deltaChars: 1_000, count: 1, frame: "text", spaced: false, overflow: false },
	{ name: "an event past the queue bound stops the response", deltaChars: WEBSOCKET_QUEUE_MAX_CHARS, count: 1, frame: "text", spaced: false, overflow: true },
	{ name: "a burst that passes the bound before any event is decoded stops the response", deltaChars: Math.ceil(WEBSOCKET_QUEUE_MAX_CHARS / 3), count: 4, frame: "text", spaced: false, overflow: true },
	{ name: "a burst of byte frames past the bound stops the response", deltaChars: Math.ceil(WEBSOCKET_QUEUE_MAX_CHARS / 3), count: 4, frame: "bytes", spaced: false, overflow: true },
	{ name: "a burst of blob frames past the bound stops the response", deltaChars: Math.ceil(WEBSOCKET_QUEUE_MAX_CHARS / 3), count: 4, frame: "blob", spaced: false, overflow: true },
	{ name: "spaced events that pass the bound only in sum are delivered", deltaChars: Math.ceil(WEBSOCKET_QUEUE_MAX_CHARS / 3), count: 4, frame: "text", spaced: true, overflow: false },
] satisfies Array<{ name: string; deltaChars: number; count: number; frame: Frame; spaced: boolean; overflow: boolean }>) {
	test(`websocket queue: ${row.name}`, async (t) => {
		providerWorld(t);
		const previous = (globalThis as { WebSocket?: unknown }).WebSocket;
		t.after(() => { (globalThis as { WebSocket?: unknown }).WebSocket = previous; });
		const delta = JSON.stringify({ type: "response.output_text.delta", item_id: "msg_1", output_index: 0, content_index: 0, delta: "x".repeat(row.deltaChars) });
		(globalThis as { WebSocket?: unknown }).WebSocket = fakeWebSocket([...Array(row.count).fill(delta), JSON.stringify(completedEvent)].map((event) => framePayload(event, row.frame)), row.spaced);
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
