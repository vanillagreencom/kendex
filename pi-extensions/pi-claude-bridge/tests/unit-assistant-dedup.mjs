import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { processAssistantMessage } from "../src/index.ts";
import { ctx, resetStack } from "../src/query-state.ts";
import { model, installFakeStream } from "./lib/tool-stream.mjs";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";
afterEach(() => cancelScheduledToolUseEnd(ctx()));
describe("no-stream-events fallback: same-message re-yields", () => {
	beforeEach(() => resetStack());

	it("renders a re-yielded identical text block only once", () => {
		// The SDK yields the SAME assistant message more than once (partial +
		// completed copies share one id). A rate-limited turn must print its
		// warning only once through this path.
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		const msg = {
			type: "assistant",
			message: {
				id: "msg_dup",
				content: [{ type: "text", text: "You've hit your weekly limit · resets Jul 30, 4am" }],
				usage: { input_tokens: 1, output_tokens: 2 },
			},
		};

		processAssistantMessage(msg, model, new Map());
		processAssistantMessage(msg, model, new Map());

		assert.equal(c.turnBlocks.filter((b) => b.type === "text").length, 1);
		assert.equal(events.filter((e) => e.type === "text_start").length, 1);
	});

	it("a distinct new message still renders", () => {
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		const mk = (id, text) => ({ type: "assistant", message: { id, content: [{ type: "text", text }] } });

		processAssistantMessage(mk("msg_a", "first"), model, new Map());
		processAssistantMessage(mk("msg_b", "second"), model, new Map());

		assert.deepEqual(c.turnBlocks.filter((b) => b.type === "text").map((b) => b.text), ["first", "second"]);
		assert.equal(events.filter((e) => e.type === "text_start").length, 2);
	});

	it("renders identical text only once even when the yields carry different ids", () => {
		// A rejected turn's synthesized error message arrives as multiple yields
		// whose ids differ or are absent. Identical error blocks must still
		// collapse into one Pi message.
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		const text = "You've hit your weekly limit · resets Jul 30, 4am (America/Los_Angeles)";
		const mk = (id) => ({ type: "assistant", message: { ...(id ? { id } : {}), content: [{ type: "text", text }] } });

		processAssistantMessage(mk("msg_attempt_1"), model, new Map());
		processAssistantMessage(mk("msg_attempt_2"), model, new Map());
		processAssistantMessage(mk(undefined), model, new Map());

		assert.equal(c.turnBlocks.filter((b) => b.type === "text").length, 1);
		assert.equal(events.filter((e) => e.type === "text_start").length, 1);
	});

	it("does not duplicate a re-yielded tool call block and keeps claim state", () => {
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		const msg = {
			type: "assistant",
			message: {
				id: "msg_tool",
				content: [{ type: "tool_use", id: "toolu_dup", name: "mcp__custom-tools__bash", input: { command: "echo hi" } }],
			},
		};

		processAssistantMessage(msg, model, new Map([["mcp__custom-tools__bash", "bash"]]));
		const claim = c.claimToolCall("bash", { command: "echo hi", timeout: 120 });
		assert.equal(claim.toolCallId, "toolu_dup");

		processAssistantMessage(msg, model, new Map([["mcp__custom-tools__bash", "bash"]]));

		assert.equal(c.turnBlocks.filter((b) => b.type === "toolCall").length, 1, "no duplicate toolCall block");
		assert.equal(events.filter((e) => e.type === "toolcall_start").length, 1);
		assert.equal(c.claimedToolCallIds.has("toolu_dup"), true, "same-message re-yield must not wipe claim state");
	});
});
