#!/usr/bin/env node
// Unit tests for pi→Anthropic message conversion (convert.ts).

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { convertPiMessages } from "../src/convert.js";
import { findUnpairedToolUses, recoverLaterToolResults } from "../src/tool-pairing-audit.js";

/** Shorthand: convert pi messages and return just the anthropic messages. */
function convert(messages, customToolNameToSdk) {
	return convertPiMessages(messages, customToolNameToSdk).anthropicMessages;
}

// --- Tests ---

describe("tool ID sanitization", () => {
	it("sanitizes tool-use and tool-result IDs identically", () => {
		for (const [id, name, args, content, expected] of [
			["functions.bash:0", "bash", { cmd: "ls" }, "file.txt", "functions_bash_0"],
			["tool call#1@foo", "bash", {}, "ok", "tool_call_1_foo"],
			["toolu_abc123-XYZ", "read", {}, "data", "toolu_abc123-XYZ"],
		]) {
			const result = convert([
				{ role: "assistant", content: [{ type: "toolCall", id, name, arguments: args }] },
				{ role: "toolResult", toolCallId: id, content },
			]);
			assert.deepEqual([result[0].content[0].id, result[1].content[0].tool_use_id], [expected, expected], id);
		}
	});

	it("tool_use and tool_result IDs stay paired after sanitization", () => {
		const ids = ["fn.read:0", "fn.write:1", "fn.bash:2"];
		const msgs = [];
		for (const id of ids) {
			msgs.push({ role: "assistant", content: [{ type: "toolCall", id, name: "bash", arguments: {} }] });
			msgs.push({ role: "toolResult", toolCallId: id, content: "ok" });
		}
		const result = convert(msgs);
		for (let i = 0; i < ids.length; i++) {
			const useId = result[i * 2].content[0].id;
			const resultId = result[i * 2 + 1].content[0].tool_use_id;
			assert.equal(useId, resultId, `pair ${i}: tool_use=${useId} tool_result=${resultId}`);
		}
	});
});

describe("empty text block filtering", () => {
	it("filters empty assistant text while retaining usable blocks", () => {
		for (const { name, content, expected } of [
			{ name: "empty text before tool", content: [{ type: "text", text: "" }, { type: "toolCall", id: "abc", name: "read", arguments: {} }], expected: [{ type: "tool_use", id: "abc", name: "Read", input: {} }] },
			{ name: "only empty text", content: [{ type: "text", text: "" }], expected: [{ type: "text", text: "[incompatible content omitted]" }] },
			{ name: "non-empty text", content: [{ type: "text", text: "Hello world" }], expected: [{ type: "text", text: "Hello world" }] },
			{ name: "interleaved empty text", content: [{ type: "text", text: "" }, { type: "text", text: "real content" }, { type: "text", text: "" }], expected: [{ type: "text", text: "real content" }] },
		]) {
			assert.deepEqual(convert([{ role: "assistant", content }]), [{ role: "assistant", content: expected }], name);
		}
	});
});

describe("thinking block filtering", () => {
	it("preserves signed Claude thinking and filters incompatible thinking", () => {
		for (const { name, provenance = {}, content, expected } of [
			{ name: "other provider", content: [{ type: "thinking", thinking: "let me think..." }, { type: "text", text: "answer" }], expected: [{ type: "text", text: "answer" }] },
			{ name: "canonical provider", provenance: { provider: "pi-claude" }, content: [{ type: "thinking", thinking: "reasoning...", thinkingSignature: "sig123" }, { type: "text", text: "answer" }], expected: [{ type: "thinking", thinking: "reasoning...", signature: "sig123" }, { type: "text", text: "answer" }] },
			{ name: "Anthropic API", provenance: { api: "anthropic" }, content: [{ type: "thinking", thinking: "hmm", thinkingSignature: "sig456" }, { type: "text", text: "done" }], expected: [{ type: "thinking", thinking: "hmm", signature: "sig456" }, { type: "text", text: "done" }] },
			{ name: "missing signature", provenance: { provider: "pi-claude" }, content: [{ type: "thinking", thinking: "no sig" }, { type: "text", text: "answer" }], expected: [{ type: "text", text: "answer" }] },
			{ name: "only incompatible thinking", content: [{ type: "thinking", thinking: "deep thoughts" }], expected: [{ type: "text", text: "[incompatible content omitted]" }] },
		]) {
			assert.deepEqual(convert([{ role: "assistant", ...provenance, content }]), [{ role: "assistant", content: expected }], name);
		}
	});

	it("non-Claude assistant provider provenance is preserved", () => {
		const result = convert([
			{ role: "assistant", provider: "openai", model: "gpt-test", content: [{ type: "text", text: "hello" }] },
		]);
		assert.equal(result[0].content[0].text, "[Prior Pi assistant response from openai/gpt-test]\n");
		assert.equal(result[0].content[1].text, "hello");
	});
});

describe("message structure", () => {
	it("toolResult → user with tool_result content", () => {
		const msgs = [
			{ role: "toolResult", toolCallId: "id1", content: "result text", isError: false },
		];
		const result = convert(msgs);
		assert.equal(result[0].role, "user");
		assert.equal(result[0].content[0].type, "tool_result");
		assert.equal(result[0].content[0].tool_use_id, "id1");
		assert.equal(result[0].content[0].content, "result text");
		assert.equal(result[0].content[0].is_error, false);
	});

	it("toolResult with isError=true", () => {
		const msgs = [
			{ role: "toolResult", toolCallId: "id1", content: "oh no", isError: true },
		];
		assert.equal(convert(msgs)[0].content[0].is_error, true);
	});

	it("multiple tool results in sequence", () => {
		const msgs = [
			{ role: "assistant", content: [
				{ type: "toolCall", id: "t1", name: "read", arguments: { path: "a.txt" } },
				{ type: "toolCall", id: "t2", name: "read", arguments: { path: "b.txt" } },
			]},
			{ role: "toolResult", toolCallId: "t1", content: "content a" },
			{ role: "toolResult", toolCallId: "t2", content: "content b" },
		];
		const result = convert(msgs);
		assert.equal(result.length, 2);
		assert.equal(result[0].role, "assistant");
		assert.equal(result[0].content.length, 2);
		assert.equal(result[1].role, "user");
		assert.equal(result[1].content[0].tool_use_id, "t1");
		assert.equal(result[1].content[1].tool_use_id, "t2");
	});

	it("grouped parallel tool results satisfy pairing audit", () => {
		const msgs = [
			{ role: "assistant", content: [
				{ type: "toolCall", id: "t1", name: "read", arguments: { path: "a.txt" } },
				{ type: "toolCall", id: "t2", name: "read", arguments: { path: "b.txt" } },
			] },
			{ role: "toolResult", toolCallId: "t1", content: "content a" },
			{ role: "toolResult", toolCallId: "t2", content: "content b" },
		];
		const result = convert(msgs);
		assert.equal(result[1].content.length, 2);
		assert.deepEqual(result[1].content.map((block) => block.tool_use_id), ["t1", "t2"]);
		assert.deepEqual(findUnpairedToolUses(result), []);
	});

	it("interleaved user prompts after a tool-use assistant are replayed after grouped tool results", () => {
		const msgs = [
			{ role: "assistant", content: [
				{ type: "toolCall", id: "t1", name: "read", arguments: { path: "a.txt" } },
				{ type: "toolCall", id: "t2", name: "read", arguments: { path: "b.txt" } },
			] },
			{ role: "toolResult", toolCallId: "t1", content: "content a" },
			{ role: "user", content: "please continue after tools" },
			{ role: "toolResult", toolCallId: "t2", content: "content b" },
		];

		const result = convert(msgs);
		assert.equal(result.length, 3);
		assert.deepEqual(result[1].content.map((block) => block.tool_use_id), ["t1", "t2"]);
		assert.equal(result[2].role, "user");
		assert.equal(result[2].content, "please continue after tools");
		assert.deepEqual(findUnpairedToolUses(result), []);
	});

	it("recovers real sibling results when a steer splits one parallel batch across later turns", () => {
		const msgs = [
			{ role: "assistant", content: [
				{ type: "toolCall", id: "t1", name: "SlowTool", arguments: { seconds: 3 } },
				{ type: "toolCall", id: "t2", name: "SlowTool", arguments: { seconds: 4 } },
				{ type: "toolCall", id: "t3", name: "SlowTool", arguments: { seconds: 5 } },
			] },
			{ role: "toolResult", toolCallId: "t1", content: "first" },
			{ role: "user", content: "steer" },
			{ role: "assistant", content: [{ type: "toolCall", id: "t2", name: "SlowTool", arguments: { seconds: 4 } }] },
			{ role: "toolResult", toolCallId: "t2", content: "second" },
			{ role: "assistant", content: [{ type: "toolCall", id: "t3", name: "SlowTool", arguments: { seconds: 5 } }] },
			{ role: "toolResult", toolCallId: "t3", content: "third" },
		];

		const result = convert(msgs);
		assert.deepEqual(findUnpairedToolUses(result).map((item) => item.id), ["t2", "t3"]);
		assert.deepEqual(
			recoverLaterToolResults(result).map((item) => item.id),
			["t2", "t3"],
		);
		assert.deepEqual(findUnpairedToolUses(result), []);
		assert.deepEqual(
			result[1].content.map((block) => block.tool_use_id),
			["t1", "t2", "t3"],
		);
		assert.equal(result[1].content[1].content, "second");
		assert.equal(result[1].content[2].content, "third");
	});

	it("inserts recovered tool_results BEFORE text blocks in the target user message", () => {
		// The target user message already mixes a delivered tool_result with
		// interleaved steer text. The recovered sibling result must land in the
		// leading tool_result run, not after the text (Anthropic convention).
		const messages = [
			{ role: "assistant", content: [
				{ type: "tool_use", id: "t1", name: "SlowTool", input: {} },
				{ type: "tool_use", id: "t2", name: "SlowTool", input: {} },
			] },
			{ role: "user", content: [
				{ type: "tool_result", tool_use_id: "t1", content: "first" },
				{ type: "text", text: "steer text" },
			] },
			{ role: "assistant", content: [{ type: "tool_use", id: "t2", name: "SlowTool", input: {} }] },
			{ role: "user", content: [{ type: "tool_result", tool_use_id: "t2", content: "second" }] },
		];

		assert.deepEqual(recoverLaterToolResults(messages).map((item) => item.id), ["t2"]);
		assert.deepEqual(
			messages[1].content.map((block) => block.type),
			["tool_result", "tool_result", "text"],
		);
		assert.deepEqual(
			messages[1].content.filter((block) => block.type === "tool_result").map((block) => block.tool_use_id),
			["t1", "t2"],
		);
	});

	it("converts a plain-string target user message and leads with the recovered result", () => {
		const messages = [
			{ role: "assistant", content: [{ type: "tool_use", id: "t1", name: "SlowTool", input: {} }] },
			{ role: "user", content: "steer only" },
			{ role: "assistant", content: [{ type: "tool_use", id: "t1", name: "SlowTool", input: {} }] },
			{ role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "late" }] },
		];

		assert.deepEqual(recoverLaterToolResults(messages).map((item) => item.id), ["t1"]);
		assert.deepEqual(messages[1].content.map((block) => block.type), ["tool_result", "text"]);
		assert.equal(messages[1].content[1].text, "steer only");
	});

	it("mixed conversation: user → assistant(tool) → toolResult → assistant(text)", () => {
		const msgs = [
			{ role: "user", content: "read file.txt" },
			{ role: "assistant", content: [
				{ type: "toolCall", id: "call1", name: "read", arguments: { path: "file.txt" } },
			]},
			{ role: "toolResult", toolCallId: "call1", content: "hello world" },
			{ role: "assistant", content: [{ type: "text", text: "The file says hello world." }] },
		];
		const result = convert(msgs);
		assert.equal(result.length, 4);
		assert.equal(result[0].role, "user");
		assert.equal(result[0].content, "read file.txt");
		assert.equal(result[1].role, "assistant");
		assert.equal(result[1].content[0].type, "tool_use");
		assert.equal(result[1].content[0].name, "Read");
		assert.equal(result[2].role, "user");
		assert.equal(result[2].content[0].type, "tool_result");
		assert.equal(result[3].role, "assistant");
		assert.equal(result[3].content[0].text, "The file says hello world.");
	});

	it("converts user text content shapes", () => {
		for (const [content, expected] of [
			["hello", "hello"], ["", "[empty]"],
			[[{ type: "text", text: "hi" }], [{ type: "text", text: "hi" }]],
			[[{ type: "text", text: "" }], "[image]"],
		]) {
			assert.deepEqual(convert([{ role: "user", content }])[0].content, expected, JSON.stringify(content));
		}
	});

	it("tool name mapping: pi names → SDK names", () => {
		const msgs = [
			{ role: "assistant", content: [
				{ type: "toolCall", id: "a", name: "read", arguments: {} },
				{ type: "toolCall", id: "b", name: "bash", arguments: {} },
			]},
		];
		const result = convert(msgs);
		assert.equal(result[0].content[0].name, "Read");
		assert.equal(result[0].content[1].name, "Bash");
	});

	it("toolResult with array content extracts text", () => {
		const msgs = [
			{ role: "toolResult", toolCallId: "x", content: [
				{ type: "text", text: "line 1" },
				{ type: "text", text: "line 2" },
			]},
		];
		assert.equal(convert(msgs)[0].content[0].content, "line 1\nline 2");
	});

	it("toolResult with image content preserves image blocks", () => {
		const result = convert([{ role: "toolResult", toolCallId: "x", content: [
			{ type: "text", text: "screenshot" },
			{ type: "image", mimeType: "image/png", data: "abc123" },
		] }]);
		const content = result[0].content[0].content;
		assert.equal(Array.isArray(content), true);
		assert.equal(content[0].type, "text");
		assert.equal(content[1].type, "image");
		assert.equal(content[1].source.media_type, "image/png");
	});
});
