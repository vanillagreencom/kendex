import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { processAssistantMessage, processStreamEvent } from "../src/index.ts";
import { endToolUseTurn, finalizeToolUseTurnFromMcpInvocation } from "../src/assistant-stream.ts";
import { ctx, resetStack } from "../src/query-state.ts";
import { model, installFakeStream } from "./lib/tool-stream.mjs";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";
afterEach(() => cancelScheduledToolUseEnd(ctx()));
describe("cross-turn duplicate dispatch suppression", () => {
	beforeEach(() => resetStack());

	function endTurnWithCall(id) {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();
		c.recordToolCall(id, "bash", { command: "x" });
		c.turnBlocks.push({ type: "toolCall", id, name: "bash", arguments: { command: "x" } });
		endToolUseTurn(c);
		return c;
	}

	it("endToolUseTurn stamps every executed call as forwarded", () => {
		const c = endTurnWithCall("t1");
		assert.ok(c.forwardedToolCallIds.has("t1"));
	});

	it("a lagging stream replay of a forwarded call is suppressed, deltas and stops included", () => {
		const c = endTurnWithCall("t1");
		c.resetTurnState(model);
		const events = installFakeStream();

		processStreamEvent({ type: "stream_event", event: {
			type: "content_block_start", index: 0,
			content_block: { type: "tool_use", id: "t1", name: "mcp__custom-tools__bash" },
		} }, new Map([["mcp__custom-tools__bash", "bash"]]), model);
		processStreamEvent({ type: "stream_event", event: {
			type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: "{\"command\":\"x\"}" },
		} }, new Map(), model);
		processStreamEvent({ type: "stream_event", event: { type: "content_block_stop", index: 0 } }, new Map(), model);

		assert.equal(c.turnBlocks.length, 0, "duplicate block never recorded");
		assert.ok(c.suppressedStreamIndexes.has(0));
		assert.equal(events.some((e) => String(e.type).startsWith("toolcall")), false, "no toolcall events reach Pi");
		assert.equal(c.turnSawToolCall, false, "a suppressed duplicate is not a turn boundary");
	});

	it("a completed-message replay of a forwarded call is skipped and does not end the turn", () => {
		const c = endTurnWithCall("t1");
		c.resetTurnState(model);
		const events = installFakeStream();

		processAssistantMessage({ type: "assistant", message: {
			content: [{ type: "tool_use", id: "t1", name: "mcp__custom-tools__bash", input: { command: "x" } }],
		} }, model, new Map([["mcp__custom-tools__bash", "bash"]]));

		assert.equal(c.turnBlocks.length, 0);
		assert.equal(events.some((e) => String(e.type).startsWith("toolcall")), false);
		assert.ok(c.currentPiStream, "not a tool_use boundary: the stream stays open");
	});

	it("the finalize synthesize path never re-emits a forwarded or dead id", () => {
		const c = endTurnWithCall("t1");
		c.resetTurnState(model);
		const events = installFakeStream();

		finalizeToolUseTurnFromMcpInvocation(c, "t1", "bash", { command: "x" });

		assert.equal(events.some((e) => String(e.type).startsWith("toolcall")), false);
		assert.ok(c.currentPiStream, "turn left to its own terminal events");
	});
});
