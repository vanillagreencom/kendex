import assert from "node:assert/strict";
import test from "node:test";
import { convertResponsesMessages } from "../src/providers/openai-responses-shared.js";
import { model } from "./helpers/responses.js";

test("empty tool results emit a non-empty function output", () => {
	const messages = convertResponsesMessages(model, {
		messages: [{ role: "toolResult", toolCallId: "call_1|fc_1", toolName: "noop", content: [], isError: false, timestamp: Date.now() }],
	} as any, new Set(["openai-codex"]));
	assert.equal(messages.length, 1);
	const message = messages[0] as { type: string; call_id: string; output: string };
	assert.equal(message.type, "function_call_output");
	assert.equal(message.call_id, "call_1");
	assert.equal(typeof message.output, "string");
	assert.ok(message.output.length > 0);
});
