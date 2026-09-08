import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import test from "node:test";
import { finishRetries, providerWorld, runCodexProvider } from "./helpers/provider.js";

test("provider applies the configured response-header deadline", async (t) => {
	providerWorld(t);
	t.mock.timers.enable({ apis: ["setTimeout"] });
	const signals: AbortSignal[] = [];
	globalThis.fetch = (_url, init) => new Promise<Response>((_resolve, reject) => {
		assert.ok(init?.signal);
		signals.push(init.signal);
		init.signal.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
	});
	const pending = runCodexProvider({ timeoutMs: 45_000 });
	await setImmediate();
	assert.equal(signals.length, 1);
	t.mock.timers.tick(44_999);
	await setImmediate();
	assert.equal(signals[0].aborted, false);
	t.mock.timers.tick(1);
	await setImmediate();
	assert.equal(signals[0].aborted, true);
	// Each subsequent retry also owns its own response-header deadline.
	let settled = false;
	void pending.then(() => { settled = true; });
	for (let step = 0; step < 12 && !settled; step++) {
		t.mock.timers.tick(45_000);
		await setImmediate();
	}
	assert.equal(settled, true);
	const result = await pending;
	assert.equal(result.stopReason, "error");
	assert.equal(result.errorMessage?.split("\n")[0], "response_header_timeout_ms=45000");
});
