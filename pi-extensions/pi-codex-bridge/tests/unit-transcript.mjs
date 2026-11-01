import assert from "node:assert/strict";
import test from "node:test";
import { afterBoundary, encodeResponseId, findBoundary, replayInput, systemPromptDigest } from "../src/transcript.ts";

const image = (data) => ({ type: "image", mimeType: "image/png", data });
const assistant = (stopReason, responseId, extra = {}) => ({ role: "assistant", content: [{ type: "text", text: "answer" }], api: "codex-app-server", provider: "pi-codex", model: "m", stopReason, responseId, timestamp: 3, ...extra });

// Each history message's images follow its own text, so Codex can tell which
// message held which image.
test("a new thread's first turn keeps every image beside the message that held it", () => {
	const input = replayInput([
		{ role: "system", content: "prompt", timestamp: 0 },
		{ role: "user", content: [{ type: "text", text: "look" }, image("AAAA")], timestamp: 1 },
		assistant("toolUse", undefined, { content: [{ type: "toolCall", id: "c", name: "read", arguments: { path: "x" } }] }),
		{ role: "toolResult", toolCallId: "c", toolName: "read", content: [image("BBBB")], isError: false, timestamp: 4 },
		assistant("stop", undefined, { content: [{ type: "text", text: "seen" }] }),
		{ role: "user", content: [{ type: "text", text: "and this" }, image("CCCC")], timestamp: 5 },
	]);
	assert.deepEqual(input.map((item) => item.type === "image" ? item.url : "text"), [
		"text",
		"data:image/png;base64,AAAA",
		"text",
		"data:image/png;base64,BBBB",
		"text",
		"text",
		"data:image/png;base64,CCCC",
	]);
	assert.match(input[0].text, /^Conversation so far, replayed from Pi:[^]*look$/);
	assert.doesNotMatch(input[2].text, /look/);
	assert.match(input[2].text, /\[called read[^]*Tool result \(read\)/);
	assert.match(input[4].text, /seen$/);
	assert.deepEqual(input[5], { type: "text", text: "and this", text_elements: [] });
});

test("a first message goes to Codex as itself, images included", () => {
	assert.deepEqual(replayInput([{ role: "user", content: [{ type: "text", text: "hi" }, image("AAAA")], timestamp: 1 }]), [
		{ type: "text", text: "hi", text_elements: [] },
		{ type: "image", url: "data:image/png;base64,AAAA" },
	]);
});

test("only a clean pi-codex message with the bridge's id is a boundary", () => {
	const id = encodeResponseId("t", "u", "s", "p");
	const calls = { content: [{ type: "toolCall", id: "c1", name: "read", arguments: {} }, { type: "text", text: "x" }, { type: "toolCall", id: "c2", name: "read", arguments: {} }] };
	assert.deepEqual(findBoundary([assistant("toolUse", id, calls), assistant("error", id), assistant("aborted", id), assistant("stop", "resp_other")]), { index: 0, threadId: "t", turnId: "u", toolSignature: "s", promptDigest: "p", model: "m", toolCallIds: ["c1", "c2"], stopReason: "toolUse" });
	assert.equal(findBoundary([assistant("stop", id, { provider: "openai" })]), undefined);
});

test("the prompt digest follows Pi's current system prompt", () => {
	const system = (content) => ({ role: "system", content, timestamp: 0 });
	assert.equal(systemPromptDigest([system("one")]), systemPromptDigest([system("one")]));
	assert.notEqual(systemPromptDigest([system("one")]), systemPromptDigest([system("two")]));
});

// What may follow a boundary while Codex still holds the transcript.
const user = (text) => ({ role: "user", content: text, timestamp: 6 });
const result = { role: "toolResult", toolCallId: "c", toolName: "read", content: [], isError: false, timestamp: 7 };
for (const [name, stopReason, later, clean] of [
	["user input", "stop", [user("next")], true],
	["the boundary's tool results and user input", "toolUse", [result, user("next")], true],
	["another provider's turn", "stop", [user("q"), assistant("stop", undefined, { provider: "anthropic" }), user("r")], false],
	["a pi-codex turn that errored", "stop", [user("q"), assistant("error", undefined), user("r")], false],
	["tool results after a boundary that called no tool", "stop", [result], false],
]) {
	test(`after a boundary: ${name}`, () => {
		const messages = [assistant(stopReason, encodeResponseId("t", "u", "s", "p")), ...later];
		assert.equal(afterBoundary(messages, findBoundary(messages)).clean, clean);
	});
}
