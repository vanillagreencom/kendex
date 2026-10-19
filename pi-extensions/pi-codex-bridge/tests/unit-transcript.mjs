import assert from "node:assert/strict";
import test from "node:test";
import { encodeResponseId, findBoundary, replayInput } from "../src/transcript.ts";

const image = (data) => ({ type: "image", mimeType: "image/png", data });
const assistant = (stopReason, responseId, extra = {}) => ({ role: "assistant", content: [{ type: "text", text: "answer" }], api: "codex-app-server", provider: "pi-codex", model: "m", stopReason, responseId, timestamp: 3, ...extra });

test("a new thread's first turn keeps every image, earlier and trailing", () => {
	const input = replayInput([
		{ role: "system", content: "prompt", timestamp: 0 },
		{ role: "user", content: [{ type: "text", text: "look" }, image("AAAA")], timestamp: 1 },
		assistant("toolUse", undefined, { content: [{ type: "toolCall", id: "c", name: "read", arguments: { path: "x" } }] }),
		{ role: "toolResult", toolCallId: "c", toolName: "read", content: [image("BBBB")], isError: false, timestamp: 4 },
		assistant("stop", undefined),
		{ role: "user", content: [{ type: "text", text: "and this" }, image("CCCC")], timestamp: 5 },
	]);
	assert.match(input[0].text, /^Conversation so far, replayed from Pi:/);
	assert.deepEqual(input.slice(1), [
		{ type: "image", url: "data:image/png;base64,AAAA" },
		{ type: "image", url: "data:image/png;base64,BBBB" },
		{ type: "text", text: "and this", text_elements: [] },
		{ type: "image", url: "data:image/png;base64,CCCC" },
	]);
});

test("a first message goes to Codex as itself, images included", () => {
	assert.deepEqual(replayInput([{ role: "user", content: [{ type: "text", text: "hi" }, image("AAAA")], timestamp: 1 }]), [
		{ type: "text", text: "hi", text_elements: [] },
		{ type: "image", url: "data:image/png;base64,AAAA" },
	]);
});

test("only a clean pi-codex message with the bridge's id is a boundary", () => {
	const id = encodeResponseId("t", "u", "s");
	assert.deepEqual(findBoundary([assistant("stop", id), assistant("error", id), assistant("aborted", id), assistant("stop", "resp_other")]), { index: 0, threadId: "t", turnId: "u", toolSignature: "s", stopReason: "stop" });
	assert.equal(findBoundary([assistant("stop", id, { provider: "openai" })]), undefined);
});
