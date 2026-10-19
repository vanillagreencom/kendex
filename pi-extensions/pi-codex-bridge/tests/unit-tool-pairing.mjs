import assert from "node:assert/strict";
import test from "node:test";
import { deliverToolResults } from "../src/tool-pairing.ts";

function pendingCall(requestId, callId, piToolName = "read") {
	return {
		requestId,
		piToolName,
		params: {
			threadId: "thread-1",
			turnId: "turn-1",
			callId,
			namespace: null,
			tool: "read",
			arguments: {},
		},
	};
}

function result(callId, toolName = "read", isError = false) {
	return {
		role: "toolResult",
		toolCallId: callId,
		toolName,
		content: [{ type: "text", text: `result-${callId}` }],
		isError,
		timestamp: 1,
	};
}

test("tool results answer the app-server RPC id and preserve success", () => {
	const sent = [];
	const pending = new Map([
		["call-a", pendingCall("rpc-a", "call-a")],
		["call-b", pendingCall("rpc-b", "call-b", "bash")],
	]);
	deliverToolResults({ respond: (id, value) => sent.push([id, value]) }, pending, [
		result("call-a"),
		result("call-b", "bash", true),
	]);
	assert.deepEqual(sent, [
		["rpc-a", { contentItems: [{ type: "inputText", text: "result-call-a" }], success: true }],
		["rpc-b", { contentItems: [{ type: "inputText", text: "result-call-b" }], success: false }],
	]);
	assert.equal(pending.size, 0);
});

test("a mismatched batch sends no partial response", () => {
	const sent = [];
	const pending = new Map([
		["call-a", pendingCall("rpc-a", "call-a")],
		["call-b", pendingCall("rpc-b", "call-b")],
	]);
	assert.throws(
		() => deliverToolResults({ respond: (id, value) => sent.push([id, value]) }, pending, [result("call-a")]),
		/codex-tool-result-missing count=1/,
	);
	assert.deepEqual(sent, []);
	assert.equal(pending.size, 2);
});

test("an unknown or duplicate call id is refused", () => {
	const responder = { respond: () => assert.fail("a refused batch must not answer") };
	assert.throws(
		() => deliverToolResults(responder, new Map([["call-a", pendingCall("rpc-a", "call-a")]]), [result("other")]),
		/codex-tool-result-unmatched call=other/,
	);
	assert.throws(
		() => deliverToolResults(responder, new Map([["call-a", pendingCall("rpc-a", "call-a")]]), [result("call-a"), result("call-a")]),
		/codex-tool-result-duplicate call=call-a/,
	);
});
