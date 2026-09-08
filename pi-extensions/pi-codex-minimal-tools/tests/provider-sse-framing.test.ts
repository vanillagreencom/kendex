import assert from "node:assert/strict";
import test from "node:test";
import { completedEvent, providerWorld, runCodexProvider, sseResponse } from "./helpers/provider.js";

// The Codex backend can close the stream right after the terminal event
// without the blank line that ends an SSE frame. EOF ends that frame.
const unterminatedTerminalFrames: Array<{ name: string; body: string }> = [
	{ name: "LF-terminated final line", body: `data: ${JSON.stringify(completedEvent)}\n` },
	{ name: "CRLF-terminated final line", body: `data: ${JSON.stringify(completedEvent)}\r\n` },
	{ name: "no line terminator", body: `data: ${JSON.stringify(completedEvent)}` },
];

for (const frame of unterminatedTerminalFrames) {
	test(`SSE terminal event without a trailing blank line completes the stream (${frame.name})`, async (t) => {
		providerWorld(t);
		globalThis.fetch = (async () => sseResponse(frame.body)) as typeof fetch;

		const result = await runCodexProvider();

		assert.equal(result.errorMessage, undefined);
		assert.equal(result.stopReason, "stop");
	});
}

test("malformed residual SSE data at EOF is ignored like any malformed frame", async (t) => {
		providerWorld(t);
	globalThis.fetch = (async () => sseResponse(`data: ${JSON.stringify(completedEvent)}\n\ndata: {not json`)) as typeof fetch;

	const result = await runCodexProvider();

	assert.equal(result.stopReason, "stop");
});

