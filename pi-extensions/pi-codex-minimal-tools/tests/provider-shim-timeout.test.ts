import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import test from "node:test";
import { fetchWithResponseHeaderTimeout } from "../src/provider-shim.js";

test("response header timeout aborts a pending fetch at its configured deadline", async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout"] });
	let signal: AbortSignal | null | undefined;
	t.mock.method(globalThis, "fetch", (_url: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
		signal = init?.signal;
		signal?.addEventListener("abort", () => reject(signal?.reason), { once: true });
	}));
	const pending = fetchWithResponseHeaderTimeout("https://example.test/backend-api/codex/responses", { method: "POST" }, undefined, 45_000);
	const rejection = assert.rejects(pending, { code: "RESPONSE_HEADER_TIMEOUT", timeoutMs: 45_000 });
	assert.ok(signal);
	t.mock.timers.tick(44_999);
	await setImmediate();
	assert.equal(signal.aborted, false);
	t.mock.timers.tick(1);
	await setImmediate();
	assert.equal(signal.aborted, true);
	await rejection;
});
