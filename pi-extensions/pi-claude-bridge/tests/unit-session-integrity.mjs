import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { findUnpairedToolUses, insertLostToolResultPlaceholders, summarizeMissingToolNames } from "../src/tool-pairing-audit.js";

describe("tool pairing audit", () => {
	it("detects every tool_use that repairToolPairing would pad with a synthetic result", () => {
		const msgs = [
			{ role: "assistant", content: [
				{ type: "tool_use", id: "ok", name: "Read", input: {} },
				{ type: "tool_use", id: "lost-a", name: "Grep", input: {} },
				{ type: "tool_use", id: "lost-b", name: "Grep", input: {} },
			] },
			{ role: "user", content: [{ type: "tool_result", tool_use_id: "ok", content: "fine" }] },
		];

		const missing = findUnpairedToolUses(msgs);
		assert.deepEqual(missing.map((item) => item.id), ["lost-a", "lost-b"]);
		assert.deepEqual(summarizeMissingToolNames(missing), [{ name: "Grep", count: 2 }]);
	});

	it("detects a missing result before the next normal user turn", () => {
		const msgs = [
			{ role: "assistant", content: [{ type: "tool_use", id: "orphan", name: "Bash", input: {} }] },
			{ role: "user", content: "next prompt" },
		];

		const missing = findUnpairedToolUses(msgs);
		assert.equal(missing.length, 1);
		assert.equal(missing[0].id, "orphan");
		assert.equal(missing[0].toolName, "Bash");
		assert.equal(missing[0].userIndex, 1);
	});
});

describe("insertLostToolResultPlaceholders", () => {
	it("prepends explicit error results to the following user message", () => {
		const msgs = [
			{ role: "assistant", content: [
				{ type: "tool_use", id: "ok", name: "Read", input: {} },
				{ type: "tool_use", id: "lost", name: "Bash", input: {} },
			] },
			{ role: "user", content: [{ type: "tool_result", tool_use_id: "ok", content: "fine" }] },
		];

		insertLostToolResultPlaceholders(msgs, findUnpairedToolUses(msgs));

		assert.equal(msgs.length, 2);
		assert.equal(msgs[1].content[0].type, "tool_result");
		assert.equal(msgs[1].content[0].tool_use_id, "lost");
		assert.equal(msgs[1].content[0].is_error, true);
		assert.equal(msgs[1].content[0].content.split("\n")[0], "tool-result-lost=interrupted");
		assert.equal(msgs[1].content[1].tool_use_id, "ok", "real result preserved after placeholders");
		assert.deepEqual(findUnpairedToolUses(msgs), [], "nothing left for repairToolPairing to pad");
	});

	it("wraps a string user message and keeps its text", () => {
		const msgs = [
			{ role: "assistant", content: [{ type: "tool_use", id: "orphan", name: "Bash", input: {} }] },
			{ role: "user", content: "next prompt" },
		];

		insertLostToolResultPlaceholders(msgs, findUnpairedToolUses(msgs));

		assert.equal(msgs[1].content[0].type, "tool_result");
		assert.equal(msgs[1].content[0].tool_use_id, "orphan");
		assert.deepEqual(msgs[1].content[1], { type: "text", text: "next prompt" });
		assert.deepEqual(findUnpairedToolUses(msgs), []);
	});

	it("inserts a new user message when the tool_use is the last message", () => {
		const msgs = [
			{ role: "assistant", content: [{ type: "tool_use", id: "tail", name: "Bash", input: {} }] },
		];

		insertLostToolResultPlaceholders(msgs, findUnpairedToolUses(msgs));

		assert.equal(msgs.length, 2);
		assert.equal(msgs[1].role, "user");
		assert.equal(msgs[1].content[0].tool_use_id, "tail");
		assert.deepEqual(findUnpairedToolUses(msgs), []);
	});

	it("handles several affected assistant messages without index drift", () => {
		const msgs = [
			{ role: "assistant", content: [{ type: "tool_use", id: "a", name: "Bash", input: {} }] },
			{ role: "assistant", content: [{ type: "tool_use", id: "b", name: "Read", input: {} }] },
			{ role: "user", content: "closing prompt" },
		];

		insertLostToolResultPlaceholders(msgs, findUnpairedToolUses(msgs));

		assert.equal(msgs.length, 4);
		assert.equal(msgs[1].role, "user");
		assert.equal(msgs[1].content[0].tool_use_id, "a");
		assert.equal(msgs[3].content[0].tool_use_id, "b");
		assert.deepEqual(findUnpairedToolUses(msgs), []);
	});
});
