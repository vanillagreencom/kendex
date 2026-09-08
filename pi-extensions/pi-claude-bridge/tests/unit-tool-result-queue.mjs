import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { ctx, resetStack, takeQueuedOrParkedResult } from "../src/query-state.ts";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";
afterEach(() => cancelScheduledToolUseEnd(ctx()));
describe("parked early results", () => {
	beforeEach(() => resetStack());

	it("a message-boundary reap parks results for a late handler instead of destroying them", () => {
		const c = ctx();
		c.queryToolNames.set("a", "web_fetch");
		c.pendingResults.set("a", { toolCallId: "a", content: [{ type: "text", text: "real output" }] });

		const stale = c.takeStaleQueuedResults();

		assert.deepEqual(stale, [{ id: "a", toolName: "web_fetch" }]);
		assert.equal(c.pendingResults.size, 0);
		const late = takeQueuedOrParkedResult(c, "a");
		assert.equal(late.content[0].text, "real output");
		assert.equal(takeQueuedOrParkedResult(c, "a"), undefined, "consumed exactly once");
	});

	it("takeQueuedOrParkedResult prefers the live queue over the parked store", () => {
		const c = ctx();
		c.pendingResults.set("a", { toolCallId: "a", content: [{ type: "text", text: "queued" }] });
		c.reapedResults.set("a", { toolCallId: "a", content: [{ type: "text", text: "parked" }] });

		assert.equal(takeQueuedOrParkedResult(c, "a").content[0].text, "queued");
		assert.equal(takeQueuedOrParkedResult(c, "a").content[0].text, "parked");
	});

	it("an id present in both stores is one claim candidate, not an ambiguous pair", () => {
		const c = ctx();
		c.recordToolCall("a", "web_fetch", { url: "https://a.example" });
		c.pendingResults.set("a", { toolCallId: "a", content: [{ type: "text", text: "queued" }] });
		c.reapedResults.set("a", { toolCallId: "a", content: [{ type: "text", text: "parked" }] });
		c.resetToolTracking();

		const claim = c.claimToolCall("web_fetch", { url: "https://a.example" });
		assert.equal(claim.toolCallId, "a");
		assert.equal(claim.ambiguous, false, "duplicate store membership must not inflate ambiguity");
	});
});
