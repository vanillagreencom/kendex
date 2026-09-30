import assert from "node:assert/strict";
import test from "node:test";
import { codexWebSocket, providerWorld, runCodexProvider } from "./helpers/provider.js";

const user = (text: string) => ({ role: "user", content: text });

// The second request continues the first on the same session socket only when
// its input starts with the first request's input plus the first response.
for (const row of [
	{ name: "an extended transcript sends only the new input", firstUser: "hello", secondUser: "hello", continued: true },
	{ name: "a changed earlier message sends the full input", firstUser: "hello", secondUser: "hello, edited", continued: false },
]) {
	test(`websocket continuation: ${row.name}`, async (t) => {
		providerWorld(t);
		t.mock.timers.enable({ apis: ["setTimeout"] });
		const socket = codexWebSocket(t);
		const options = { transport: "websocket-cached", sessionId: `continuation-${row.continued}` };
		const first = await runCodexProvider(options, {}, { messages: [user(row.firstUser)] });
		assert.equal(first.stopReason, "stop", first.errorMessage);
		const second = await runCodexProvider(options, {}, { messages: [user(row.secondUser), first, user("next")] });
		assert.equal(second.stopReason, "stop", second.errorMessage);

		assert.equal(socket.requests.length, 2);
		const request = socket.requests[1];
		if (row.continued) {
			assert.equal(request.previous_response_id, "resp_1");
			assert.deepEqual(request.input, [{ role: "user", content: [{ type: "input_text", text: "next" }] }]);
		} else {
			assert.equal(request.previous_response_id, undefined);
			assert.equal(request.input.length, 3);
		}
	});
}

test("a WebSocket request that succeeds never serializes the full request body", async (t) => {
	providerWorld(t);
	t.mock.timers.enable({ apis: ["setTimeout"] });
	codexWebSocket(t);
	let body: unknown;
	const stringify = t.mock.method(JSON, "stringify");
	const result = await runCodexProvider({ transport: "websocket-cached", sessionId: "serialize-once", onPayload: (payload: unknown) => { body = payload; } }, {}, { messages: [user("hello")] });
	assert.equal(result.stopReason, "stop", result.errorMessage);
	assert.ok(body, "onPayload must receive the request body");
	assert.equal(stringify.mock.calls.filter((call) => call.arguments[0] === body).length, 0);
});
