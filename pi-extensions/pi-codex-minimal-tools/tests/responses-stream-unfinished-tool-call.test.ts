import assert from "node:assert/strict";
import test from "node:test";
import { processResponsesStream } from "../src/providers/openai-responses-shared.js";
import { asAsyncIterable, createAssistantOutput, model } from "./helpers/responses.js";

const functionCall = { type: "function_call", id: "fc_1", call_id: "call_1", name: "bash", arguments: "" };
const customCall = { type: "custom_tool_call", id: "ctc_1", call_id: "call_1", name: "apply_patch", input: "" };
const completed = { type: "response.completed", response: { id: "resp_unfinished", status: "completed" } };

// Removing the final unfinished-call check makes these cases fail, including
// when an output index loses its pending state.
for (const row of [
	{
		name: "truncated function arguments",
		events: [
			{ type: "response.output_item.added", output_index: 0, item: functionCall },
			{ type: "response.function_call_arguments.delta", output_index: 0, delta: '{"command":"rm -rf bu' },
		],
	},
	{
		name: "empty function arguments",
		events: [{ type: "response.output_item.added", output_index: 0, item: functionCall }],
	},
	{
		name: "finished arguments without a finished item",
		events: [
			{ type: "response.output_item.added", output_index: 0, item: functionCall },
			{ type: "response.function_call_arguments.done", output_index: 0, arguments: '{"command":"pwd"}' },
		],
	},
	{
		name: "finished custom input without a finished item",
		events: [
			{ type: "response.output_item.added", output_index: 0, item: customCall },
			{ type: "response.custom_tool_call_input.done", output_index: 0, input: "*** Begin Patch\n" },
		],
	},
	{
		name: "a finished item with a different output index",
		events: [
			{ type: "response.output_item.added", output_index: 0, item: functionCall },
			{ type: "response.output_item.done", output_index: 1, item: { ...functionCall, arguments: '{"command":"pwd"}' } },
		],
	},
	{
		name: "missing output indexes overwrite pending state",
		events: [
			{ type: "response.output_item.added", item: functionCall },
			{ type: "response.output_item.added", item: { ...functionCall, id: "fc_2", call_id: "call_2" } },
			{ type: "response.output_item.done", item: { ...functionCall, id: "fc_2", call_id: "call_2", arguments: '{"command":"pwd"}' } },
		],
	},
]) {
	test(`completed Responses streams reject ${row.name}`, async () => {
		const output = createAssistantOutput();
		await assert.rejects(
			processResponsesStream(asAsyncIterable([...row.events, completed]), output, { push() {} } as never, model),
			/unfinished tool call/,
		);
	});
}
