import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";
import { zstdDecompressSync } from "node:zlib";
import * as piAi from "@earendil-works/pi-ai";
import { providerWorld, runCodexProvider, successSseResponse } from "./helpers/provider.js";

async function capturedRequest(t: TestContext, modelOverrides: Record<string, unknown> = {}): Promise<{ headers: Headers; body: Record<string, unknown> }> {
	providerWorld(t);
	let captured: RequestInit | undefined;
	globalThis.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
		captured = init;
		return successSseResponse();
	}) as typeof fetch;
	await runCodexProvider({}, modelOverrides);
	assert.ok(captured?.body instanceof Uint8Array);
	return { headers: new Headers(captured.headers), body: JSON.parse(zstdDecompressSync(captured.body).toString("utf8")) };
}

// Pi 1.4.0 and later give the User-Agent through getIdentityHeaders, `pi/<version> (...)`;
// an older host gets the one Pi sent before, `pi (<platform> <release>; <arch>)`.
// `older-pi-host.test.ts` runs these rows on a host without the export.
test("SSE transport sends the pi originator and the host's User-Agent", async (t) => {
	const { headers } = await capturedRequest(t);
	assert.equal(headers.get("originator"), "pi");
	assert.match(headers.get("user-agent") ?? "", "getIdentityHeaders" in piAi ? /^pi\/\d+\.\d+\.\d+ \(/ : /^pi \(.+; .+\)$/);
});

// Pi's clamp fits the output cap into the context window; a host without the
// api/simple-options subpath, Pi 0.75, sends the model's cap unclamped.
test("SSE transport sends max_output_tokens within the context window where the host clamps it", async (t) => {
	const { body } = await capturedRequest(t, { contextWindow: 50_000, maxTokens: 128_000 });
	const clamps = await import("@earendil-works/pi-ai/api/simple-options").then(() => true, () => false);
	const cap = body.max_output_tokens as number;
	if (clamps) assert.ok(cap >= 16 && cap < 50_000, String(cap));
	else assert.equal(cap, 128_000);
});

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

