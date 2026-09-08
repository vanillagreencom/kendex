import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { finalizeToolUseTurnFromMcpInvocation } from "../src/assistant-stream.ts";
import { ctx, drainStrandedToolCalls, failStrandedToolCall, resetStack } from "../src/query-state.ts";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";
afterEach(() => cancelScheduledToolUseEnd(ctx()));
describe("stranded handler resolution", () => {
	beforeEach(() => resetStack());

	it("finalize with a dead stream fails the unforwarded waiting handler with a retryable error", () => {
		const c = ctx();
		let resolved;
		c.pendingToolCalls.set("t9", { toolName: "web_fetch", args: { url: "x" }, generation: 0, resolve: (r) => { resolved = r; } });

		finalizeToolUseTurnFromMcpInvocation(c, "t9", "web_fetch", { url: "x" });

		assert.ok(resolved, "handler resolved instead of waiting forever");
		assert.equal(resolved.isError, true);
		assert.equal(resolved.content[0].text.split("\n")[0], "tool-call-stranded=unforwarded");
		assert.equal(c.pendingToolCalls.size, 0);
		assert.ok(c.deadToolCallIds.has("t9"), "failed call can never be dispatched later");
	});

	it("failStrandedToolCall leaves forwarded handlers waiting for their steer-split result", () => {
		const c = ctx();
		let resolved;
		c.forwardedToolCallIds.add("t8");
		c.pendingToolCalls.set("t8", { toolName: "bash", args: {}, generation: 0, resolve: (r) => { resolved = r; } });

		assert.equal(failStrandedToolCall(c, "t8"), false);
		assert.equal(resolved, undefined);
		assert.ok(c.pendingToolCalls.has("t8"));
	});

	it("the delivery-site drain fails only unforwarded handlers from settled generations", () => {
		const c = ctx();
		c.callbackGeneration = 1;
		const results = {};
		const register = (id, generation) => c.pendingToolCalls.set(id, {
			toolName: "bash", args: {}, generation, resolve: (r) => { results[id] = r; },
		});
		register("old-unforwarded", 0);
		register("old-forwarded", 0);
		c.forwardedToolCallIds.add("old-forwarded");
		register("current", 1);

		const stranded = drainStrandedToolCalls(c);

		assert.deepEqual(stranded, [{ id: "old-unforwarded", toolName: "bash" }]);
		assert.equal(results["old-unforwarded"].isError, true);
		assert.equal(results["old-forwarded"], undefined, "Pi still owes this one a result");
		assert.equal(results["current"], undefined, "racing the live callback is not stranded");
		assert.ok(c.deadToolCallIds.has("old-unforwarded"));
		assert.ok(c.pendingToolCalls.has("old-forwarded"));
		assert.ok(c.pendingToolCalls.has("current"));
	});
});
