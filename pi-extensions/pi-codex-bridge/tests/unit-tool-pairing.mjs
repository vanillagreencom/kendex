import assert from "node:assert/strict";
import test from "node:test";
import { answerToolCalls, LOST_TOOL_RESULT_TEXT } from "../src/tool-pairing.ts";

const call = (requestId, callId, piToolName = "read") => ({ requestId, callId, piToolName });
const result = (callId, content, { toolName = "read", isError = false } = {}) => ({ role: "toolResult", toolCallId: callId, toolName, content, isError, timestamp: 1 });

test("each pending call is answered by its own RPC id, images as data URLs, lost calls as failed", () => {
	const answers = answerToolCalls([call("rpc-a", "a"), call("rpc-b", "b", "bash"), call("rpc-c", "c")], [
		result("b", [{ type: "text", text: "exit 1" }], { toolName: "bash", isError: true }),
		result("a", [{ type: "text", text: "pixels:" }, { type: "image", mimeType: "image/png", data: "iVBORw0K" }]),
	]);
	assert.deepEqual(answers, [
		{ requestId: "rpc-a", result: { contentItems: [{ type: "inputText", text: "pixels:" }, { type: "inputImage", imageUrl: "data:image/png;base64,iVBORw0K" }], success: true } },
		{ requestId: "rpc-b", result: { contentItems: [{ type: "inputText", text: "exit 1" }], success: false } },
		{ requestId: "rpc-c", result: { contentItems: [{ type: "inputText", text: LOST_TOOL_RESULT_TEXT }], success: false } },
	]);
});

for (const [name, results, key] of [
	["an unknown call id", [result("other", [])], "codex-tool-result-unmatched call=other"],
	["a repeated call id", [result("a", []), result("a", [])], "codex-tool-result-duplicate call=a"],
	["another tool's name", [result("a", [], { toolName: "bash" })], "codex-tool-result-name-mismatch call=a"],
]) {
	test(`a result batch with ${name} is refused whole`, () => {
		assert.throws(() => answerToolCalls([call("rpc-a", "a")], results), { message: key });
	});
}
