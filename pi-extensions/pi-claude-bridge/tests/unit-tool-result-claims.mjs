import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { ctx, resetStack, takeQueuedOrParkedResult } from "../src/query-state.ts";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";
afterEach(() => cancelScheduledToolUseEnd(ctx()));
describe("post-boundary claim recovery (production path)", () => {
	beforeEach(() => resetStack());

	it("a late handler claims its parked result through claimToolCall after the boundary wiped the records", () => {
		const c = ctx();
		c.recordToolCall("x", "web_fetch", { url: "https://a.example" });
		c.pendingResults.set("x", { toolCallId: "x", content: [{ type: "text", text: "real" }] });
		c.takeStaleQueuedResults();
		c.resetToolTracking();

		const claim = c.claimToolCall("web_fetch", { url: "https://a.example" });
		assert.equal(claim.toolCallId, "x", "claim pairs the late handler with its own parked result");
		assert.equal(claim.match, "tool-args");
		assert.equal(takeQueuedOrParkedResult(c, claim.toolCallId).content[0].text, "real");
	});

	it("a late handler with a parked result never steals a live same-name call", () => {
		const c = ctx();
		c.recordToolCall("x", "bash", { command: "make deploy" });
		c.pendingResults.set("x", { toolCallId: "x", content: [{ type: "text", text: "deployed" }] });
		c.takeStaleQueuedResults();
		c.resetToolTracking();
		// The following turn streams same-name call Y, the sole live candidate.
		c.recordToolCall("y", "bash", { command: "echo other" });

		const lateClaim = c.claimToolCall("bash", { command: "make deploy" });
		assert.equal(lateClaim.toolCallId, "x", "exact-args parked pairing outranks the sole live fallback");
		const liveClaim = c.claimToolCall("bash", { command: "echo other" });
		assert.equal(liveClaim.toolCallId, "y", "the live call keeps its own id");
	});

	it("a sole result-backed candidate is claimable without exact args, several are refused", () => {
		const c = ctx();
		c.recordToolCall("x", "edit", { path: "a", edits: [] });
		c.pendingResults.set("x", { toolCallId: "x", content: [{ type: "text", text: "ok" }] });
		c.takeStaleQueuedResults();
		c.resetToolTracking();

		const sole = c.claimToolCall("edit", { path: "a", edits: [{ oldText: "1", newText: "2" }] });
		assert.equal(sole.toolCallId, "x");
		assert.equal(sole.match, "tool-name");
		assert.equal(sole.argsMismatch, true);

		resetStack();
		const c2 = ctx();
		for (const id of ["p", "q"]) {
			c2.recordToolCall(id, "read", { path: id });
			c2.pendingResults.set(id, { toolCallId: id, content: [{ type: "text", text: id }] });
		}
		c2.takeStaleQueuedResults();
		c2.resetToolTracking();
		const refused = c2.claimToolCall("read", { path: "neither" });
		assert.equal(refused.match, "none", "two candidates and no exact match: cross-pairing refused");
	});
});
