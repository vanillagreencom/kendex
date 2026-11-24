import assert from "node:assert/strict";
import test from "node:test";
import { isRetryableAssistantError } from "@earendil-works/pi-ai";
import { isRetryableError } from "../src/provider-shim.js";
import { providerWorld, runCodexProvider, sseResponse } from "./helpers/provider.js";

for (const row of [
	{ status: 524, message: "Cloudflare timeout", expected: true },
	{ status: 400, message: "grpc ResourceExhausted", expected: true },
	{ status: 400, message: "socket connection was closed unexpectedly", expected: true },
	{ status: 400, message: "please retry your request", expected: true },
	{ status: 400, message: "you can retry your request", expected: true },
	{ status: 400, message: "Service unavailable", expected: true },
	{ status: 400, message: "server error", expected: true },
	{ status: 400, message: "Internal server error", expected: true },
	{ status: 400, message: "HTTP 503", expected: true },
	{ status: 429, message: "insufficient_quota", expected: false },
	{ status: 429, message: "ResourceExhausted: quota exceeded", expected: false },
	{ status: 400, message: "Do not retry the request: invalid schema", expected: false },
	{ status: 400, message: "billing account disabled", expected: false },
	{ status: 400, message: "invalid schema", expected: false },
]) {
	test(`retry classification: ${row.status}/${row.message}`, () => assert.equal(isRetryableError(row.status, row.message), row.expected));
}

// The server ends a WebSocket at 60 minutes, even mid-response. Pi's agent retries the
// turn on a fresh connection when the failed message reads as retryable, so the shim's
// error for it must keep a form Pi's classifier reads, whichever field carries it.
for (const row of [
	{ name: "code", event: { type: "error", code: "websocket_connection_limit_reached" } },
	{ name: "message", event: { type: "error", message: "Responses websocket connection limit reached" } },
]) {
	test(`a mid-stream connection limit is retried by Pi's agent: ${row.name}`, async (t) => {
		providerWorld(t);
		const created = { type: "response.created", response: { id: "resp_limit" } };
		globalThis.fetch = async () => sseResponse(`data: ${JSON.stringify(created)}\n\ndata: ${JSON.stringify(row.event)}\n\n`);
		const result = await runCodexProvider();
		assert.equal(result.stopReason, "error");
		assert.equal(isRetryableAssistantError(result), true, result.errorMessage);
	});
}
