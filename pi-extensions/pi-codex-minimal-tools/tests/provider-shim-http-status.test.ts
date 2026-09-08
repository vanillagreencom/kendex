import assert from "node:assert/strict";
import test from "node:test";
import { errorResponse, finishRetries, providerWorld, runCodexProvider, successSseResponse } from "./helpers/provider.js";

for (const row of [
	{ name: "terminal quota", status: 429, code: "usage_limit_reached", message: "upstream-quota", calls: 1, stopReason: "error", success: false },
	{ name: "invalid request", status: 400, code: "invalid_request", message: "Do not retry the request: invalid schema", calls: 1, stopReason: "error", success: false },
	{ name: "transient failure exhausted", status: 503, code: "server_error", message: "upstream-unavailable", calls: 4, stopReason: "error", success: false },
	{ name: "transient then success", status: 503, code: "server_error", message: "upstream-unavailable", calls: 2, stopReason: "stop", success: true },
]) {
	test(`provider HTTP outcome: ${row.name}`, async (t) => {
		providerWorld(t);
		t.mock.timers.enable({ apis: ["setTimeout"] });
		let calls = 0;
		globalThis.fetch = async () => {
			calls++;
			return row.success && calls > 1 ? successSseResponse() : errorResponse(row.status, { error: { code: row.code, plan_type: "PLUS", message: row.message } });
		};
		const result = await finishRetries(t, runCodexProvider());
		assert.equal(calls, row.calls);
		assert.equal(result.stopReason, row.stopReason);
		if (row.success) assert.equal(result.errorMessage, undefined);
		else {
			assert.ok(result.errorMessage);
			assert.ok(result.errorMessage.startsWith(`HTTP ${row.status}: `));
			if (row.code === "usage_limit_reached") {
				assert.ok(result.errorMessage.includes("plus"));
				assert.equal(result.errorMessage.includes(row.message), false);
			} else assert.equal(result.errorMessage, `HTTP ${row.status}: ${row.message}`);
		}
	});
}
