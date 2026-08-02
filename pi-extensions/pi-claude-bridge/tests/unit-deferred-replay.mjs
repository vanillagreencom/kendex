/**
 * Tests for planDeferredUserReplay — the re-entrant branch's capture plan for
 * user messages pi injects mid-query (steer drain, followUp delivery).
 *
 * vstack#967: when the context ended in MULTIPLE trailing user messages, only
 * the last was deferred while the cursor advanced past all of them — the
 * earlier ones were permanently and silently lost. The plan must cover the
 * entire trailing user run, and the caller advances the cursor to the end of
 * the context only when the plan produced a replay prompt (otherwise it stops
 * at runStart so nothing unclaimed is skipped).
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { planDeferredUserReplay } from "../src/index.ts";

const user = (text) => ({ role: "user", content: text });
const toolResult = () => ({ role: "toolResult", content: [], toolCallId: "t1" });
const assistant = () => ({ role: "assistant", content: [] });

describe("planDeferredUserReplay", () => {
	it("captures BOTH trailing users after a tool result (vstack#967 shape)", () => {
		const messages = [assistant(), toolResult(), user("u_a"), user("u_b")];

		const plan = planDeferredUserReplay(messages);

		assert.equal(plan.runStart, 2);
		assert.equal(plan.userMessageCount, 2);
		// Both messages, in order, in one combined replay prompt.
		assert.equal(plan.prompt, "u_a\n\nu_b");
		// Caller contract: prompt captured → cursor lands at messages.length,
		// covering exactly the messages that were deferred.
		assert.equal(messages.length, plan.runStart + plan.userMessageCount);
	});

	it("keeps the single trailing user unchanged", () => {
		const plan = planDeferredUserReplay([assistant(), toolResult(), user("steer")]);

		assert.equal(plan.runStart, 2);
		assert.equal(plan.userMessageCount, 1);
		assert.equal(plan.prompt, "steer");
	});

	it("returns no prompt when the context does not end in a user message", () => {
		const plan = planDeferredUserReplay([assistant(), toolResult()]);

		assert.equal(plan.runStart, 2);
		assert.equal(plan.userMessageCount, 0);
		assert.equal(plan.prompt, null);
	});

	it("returns no prompt for an all-empty user run so the caller can diagnose it", () => {
		const plan = planDeferredUserReplay([assistant(), toolResult(), user(""), user("  ")]);

		// runStart still marks the run — the caller holds the cursor here instead
		// of silently claiming messages that were never captured.
		assert.equal(plan.runStart, 2);
		assert.equal(plan.userMessageCount, 2);
		assert.equal(plan.prompt, null);
	});
});

// vstack#993 item 2: the replay queue was text-only (string[]), so a mid-query
// user message carrying image blocks replayed as its text alone and the images
// were silently dropped. The plan now also carries the block form when images
// are present, and an image-only run must be captured, not skipped.
describe("planDeferredUserReplay image blocks (vstack#993)", () => {
	const image = () => ({ type: "image", data: "aGk=", mimeType: "image/png" });

	it("carries blocks alongside text for a mixed run", () => {
		const messages = [
			{ role: "assistant", content: [] },
			{ role: "user", content: [{ type: "text", text: "look at this" }, image()] },
			{ role: "user", content: "and fix it" },
		];

		const plan = planDeferredUserReplay(messages);

		assert.equal(plan.userMessageCount, 2);
		assert.equal(plan.prompt, "look at this\n\nand fix it");
		assert.ok(Array.isArray(plan.blocks), "block form present when the run carries images");
		assert.ok(plan.blocks.some((b) => b.type === "image"), "image block preserved");
		assert.ok(plan.blocks.some((b) => b.type === "text" && b.text === "and fix it"), "text preserved in block form");
	});

	it("captures an image-only run (no usable text) instead of skipping it", () => {
		const messages = [
			{ role: "assistant", content: [] },
			{ role: "user", content: [image()] },
		];

		const plan = planDeferredUserReplay(messages);

		assert.equal(plan.prompt, null);
		assert.ok(Array.isArray(plan.blocks) && plan.blocks.length > 0, "image-only run still produces a replay payload");
	});

	it("returns null blocks for a text-only run", () => {
		const plan = planDeferredUserReplay([{ role: "user", content: "plain" }]);
		assert.equal(plan.blocks, null);
		assert.equal(plan.prompt, "plain");
	});
});
