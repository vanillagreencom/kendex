import assert from "node:assert/strict";
import test from "node:test";
import { zstdDecompressSync } from "node:zlib";
import { providerWorld, runCodexProvider, successSseResponse } from "./helpers/provider.js";

// Model and caller headers override the originator and User-Agent defaults; null removes one.
test("SSE transport sends compressed tool choice and applies nullable header overrides", async (t) => {
		providerWorld(t);
	let captured: RequestInit | undefined;
	globalThis.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
		captured = init;
		return successSseResponse();
	}) as typeof fetch;

	const result = await runCodexProvider(
		{ toolChoice: "required", headers: { "x-added": "stream", "x-remove": null, "User-Agent": null } },
		{ headers: { "x-model": "model", "x-remove": "model", originator: "model-originator", "User-Agent": "model-agent" } },
	);

	assert.equal(result.stopReason, "stop");
	assert.ok(captured);
	const headers = new Headers(captured.headers);
	assert.equal(headers.get("content-encoding"), "zstd");
	assert.equal(headers.get("x-added"), "stream");
	assert.equal(headers.get("x-model"), "model");
	assert.equal(headers.has("x-remove"), false);
	assert.equal(headers.get("originator"), "model-originator");
	assert.equal(headers.has("user-agent"), false);
	assert.ok(captured.body instanceof Uint8Array);
	const payload = JSON.parse(zstdDecompressSync(captured.body).toString("utf8"));
	assert.equal(payload.tool_choice, "required");
});

