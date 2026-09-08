import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { processAssistantMessage, processStreamEvent } from "../src/index.ts";
import { FINALIZE_MAX_REARMS, endToolUseTurn, finalizeToolUseTurnFromMcpInvocation } from "../src/assistant-stream.ts";
import { ctx, resetStack } from "../src/query-state.ts";
import { model, installFakeStream } from "./lib/tool-stream.mjs";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";
afterEach(() => cancelScheduledToolUseEnd(ctx()));
describe("grace finalize argument settlement", () => {
	beforeEach(() => resetStack());

	it("settles a still-partial block from the handler's authoritative args, never the partial JSON", () => {
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		c.recordToolCall("t1", "web_fetch", {});
		c.turnBlocks.push({
			type: "toolCall", id: "t1", name: "web_fetch",
			arguments: {}, partialJson: "{\"url\":\"https://trunc", index: 0,
		});

		finalizeToolUseTurnFromMcpInvocation(c, "t1", "web_fetch", { url: "https://example.com/CHANGELOG.md" });

		const end = events.find((e) => e.type === "toolcall_end");
		assert.deepEqual(end.toolCall.arguments, { url: "https://example.com/CHANGELOG.md" });
		const done = events.find((e) => e.type === "done");
		assert.equal(done.reason, "toolUse");
		assert.deepEqual(done.message.content[0].arguments, { url: "https://example.com/CHANGELOG.md" });
		assert.equal(c.currentPiStream, null, "turn ended");
		assert.ok(c.forwardedToolCallIds.has("t1"), "executed call is marked forwarded");
	});

	it("settles fired siblings from their handlers' args and re-arms for silent ones instead of truncating", () => {
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		for (const [id, name] of [["t1", "bash"], ["t2", "bash"], ["t3", "bash"]]) {
			c.recordToolCall(id, name, {});
			c.turnBlocks.push({ type: "toolCall", id, name, arguments: {}, partialJson: "{\"comman", index: c.turnBlocks.length });
		}
		c.pendingToolCalls.set("t2", { toolName: "bash", args: { command: "echo sibling" }, generation: 0, resolve: () => {} });

		finalizeToolUseTurnFromMcpInvocation(c, "t1", "bash", { command: "ls" });

		assert.deepEqual(c.turnBlocks[0].arguments, { command: "ls" });
		assert.deepEqual(c.turnBlocks[1].arguments, { command: "echo sibling" });
		assert.ok("partialJson" in c.turnBlocks[2], "silent sibling stays unsettled");
		assert.ok(c.currentPiStream, "turn NOT ended while a sibling has no arguments anywhere");
		assert.ok(c.scheduledToolUseEnd, "grace re-armed for the lagging stream");
		assert.equal(events.some((e) => e.type === "done"), false);

		// Grace exhausted: the inexecutable block is pruned, never executed.
		finalizeToolUseTurnFromMcpInvocation(c, "t1", "bash", { command: "ls" }, FINALIZE_MAX_REARMS);

		const done = events.find((e) => e.type === "done");
		assert.ok(done, "turn ends once grace is exhausted");
		assert.deepEqual(done.message.content.map((b) => b.id), ["t1", "t2"]);
		assert.ok(c.forwardedToolCallIds.has("t1"));
		assert.ok(c.forwardedToolCallIds.has("t2"));
		assert.equal(c.forwardedToolCallIds.has("t3"), false, "pruned call is not owed a result");
	});
});
describe("turn-end safety invariants", () => {
	beforeEach(() => resetStack());

	it("endToolUseTurn never ships a still-partial block", () => {
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		c.recordToolCall("sealed", "bash", { command: "ls" });
		c.turnBlocks.push({ type: "toolCall", id: "sealed", name: "bash", arguments: { command: "ls" } });
		c.recordToolCall("partial", "bash", {});
		c.turnBlocks.push({ type: "toolCall", id: "partial", name: "bash", arguments: {}, partialJson: "{\"comman", index: 1 });

		endToolUseTurn(c);

		const done = events.find((e) => e.type === "done");
		assert.deepEqual(done.message.content.map((b) => b.id), ["sealed"]);
		assert.ok(c.forwardedToolCallIds.has("sealed"));
		assert.equal(c.forwardedToolCallIds.has("partial"), false, "a pruned call is not owed a result");
	});

	it("a completed-message block suppresses its lagging same-turn stream twin", () => {
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		c.turnSawStreamEvent = true;
		// Completed yield beat the stream: block recorded complete.
		processAssistantMessage({ type: "assistant", message: {
			content: [{ type: "tool_use", id: "t1", name: "mcp__custom-tools__bash", input: { command: "echo hi" } }],
		} }, model, new Map([["mcp__custom-tools__bash", "bash"]]));
		assert.equal(c.turnBlocks.length, 1);

		// The same call's stream twin arrives afterwards.
		processStreamEvent({ type: "stream_event", event: {
			type: "content_block_start", index: 0,
			content_block: { type: "tool_use", id: "t1", name: "mcp__custom-tools__bash" },
		} }, new Map([["mcp__custom-tools__bash", "bash"]]), model);
		processStreamEvent({ type: "stream_event", event: { type: "content_block_stop", index: 0 } }, new Map(), model);

		assert.equal(c.turnBlocks.length, 1, "no second copy of the block");
		assert.equal("partialJson" in c.turnBlocks[0], false, "the complete copy is untouched");
		endToolUseTurn(c);
		const done = events.find((e) => e.type === "done");
		assert.deepEqual(done.message.content.map((b) => b.id), ["t1"], "the id ships exactly once");
	});

	it("finalize for a forwarded id still ends the turn for its executable siblings", () => {
		const c = ctx();
		c.forwardedToolCallIds.add("old");
		c.resetTurnState(model);
		const events = installFakeStream();
		c.recordToolCall("live", "bash", { command: "ls" });
		c.turnBlocks.push({ type: "toolCall", id: "live", name: "bash", arguments: { command: "ls" } });

		finalizeToolUseTurnFromMcpInvocation(c, "old", "bash", { command: "x" });

		const done = events.find((e) => e.type === "done");
		assert.ok(done, "the consumed grace timer still ends the turn");
		assert.deepEqual(done.message.content.map((b) => b.id), ["live"], "the forwarded id is not re-emitted");
	});

	it("a completed-message yield on a dead stream never mutates the delivered turn", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();
		c.recordToolCall("t1", "bash", { command: "ls" });
		c.turnBlocks.push({ type: "toolCall", id: "t1", name: "bash", arguments: { command: "ls" } });
		endToolUseTurn(c);
		const deliveredContent = c.turnOutput.content;
		const lengthAtDelivery = deliveredContent.length;
		c.turnSawStreamEvent = true;

		processAssistantMessage({ type: "assistant", message: {
			content: [
				{ type: "tool_use", id: "t1", name: "mcp__custom-tools__bash", input: { command: "ls" } },
				{ type: "tool_use", id: "t2", name: "mcp__custom-tools__bash", input: { command: "pwd" } },
			] } }, model, new Map([["mcp__custom-tools__bash", "bash"]]));

		assert.equal(deliveredContent.length, lengthAtDelivery, "Pi's delivered message is never appended to behind its back");
	});
});
