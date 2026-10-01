import assert from "node:assert/strict";
import test from "node:test";
import { setImmediate } from "node:timers/promises";
import { fetchWithResponseHeaderTimeout } from "../src/provider-shim.js";
import { providerWorld, runCodexProvider, stalledHttpServer, withinDeadline } from "./helpers/provider.js";

// Real network I/O is needed to prove cancellation after headers on a live socket.
test("stalled SSE body observes cancellation after headers", async (t) => {
	providerWorld(t);
	const server = await stalledHttpServer(t);
	const controller = new AbortController();
	t.after(() => controller.abort());
	const pending = runCodexProvider({ signal: controller.signal, onResponse: () => controller.abort(), httpIdleTimeoutMs: 0 }, { baseUrl: server.url });
	const result = await withinDeadline(pending);
	assert.equal(result.stopReason, "aborted");
	await withinDeadline(server.closed);
});

for (const row of [
	{ name: "httpIdleTimeoutMs", options: { httpIdleTimeoutMs: 50 } },
	{ name: "Pi timeoutMs", options: { timeoutMs: 50 } },
]) {
	test(`stalled SSE body times out using ${row.name}`, async (t) => {
		providerWorld(t);
		const server = await stalledHttpServer(t);
		const controller = new AbortController();
		t.after(() => controller.abort());
		const result = await withinDeadline(runCodexProvider({ ...row.options, signal: controller.signal }, { baseUrl: server.url }));
		assert.equal(result.stopReason, "error");
		assert.equal(result.errorMessage?.split("\n")[0], "http_idle_timeout_ms=50");
		await withinDeadline(server.closed);
	});
}

test("SSE reader is cancelled on abort even when fetch does not wire its body to the signal", async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout"] });
	let cancels = 0;
	t.mock.method(globalThis, "fetch", async () => new Response(new ReadableStream({ cancel() { cancels++; } })));
	const controller = new AbortController();
	const response = await fetchWithResponseHeaderTimeout("https://example.test", {}, controller.signal);
	const pending = response.text();
	const rejected = assert.rejects(pending, /Request was aborted/);
	controller.abort();
	await rejected;
	assert.equal(cancels, 1);
});

test("SSE body idle deadline resets on each chunk and zero disables it", async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout"] });
	let source: ReadableStreamDefaultController<Uint8Array>;
	t.mock.method(globalThis, "fetch", async () => new Response(new ReadableStream<Uint8Array>({ start(controller) { source = controller; } })));
	const response = await fetchWithResponseHeaderTimeout("https://example.test", {}, undefined, 100, 50);
	let settled = false;
	const pending = response.text().finally(() => { settled = true; });
	const rejection = assert.rejects(pending, /http_idle_timeout_ms=50/);
	t.mock.timers.tick(49);
	source!.enqueue(new TextEncoder().encode("data: {}\n\n"));
	await setImmediate();
	t.mock.timers.tick(49);
	await setImmediate();
	assert.equal(settled, false, "SSE body read must stay pending until the reset idle deadline");
	t.mock.timers.tick(1);
	await rejection;
	const controller = new AbortController();
	const disabled = await fetchWithResponseHeaderTimeout("https://example.test", {}, controller.signal, 100, 0);
	const disabledRead = disabled.text();
	const aborted = assert.rejects(disabledRead, /Request was aborted/);
	t.mock.timers.tick(300_000);
	await setImmediate();
	controller.abort();
	await aborted;
});
