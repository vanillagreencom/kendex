import assert from "node:assert/strict";
import test from "node:test";
import { convertResponsesMessages, processResponsesStream } from "../src/providers/openai-responses-shared.js";
import { asAsyncIterable, createAssistantOutput, model } from "./helpers/responses.js";

const completed = { type: "image_generation_call", id: "ig_123", status: "completed", result: Buffer.from("png-bytes").toString("base64"), revised_prompt: "A tiny red square icon" };
const inProgress = { type: "image_generation_call", id: "ig_123", status: "in_progress" };
const terminal = { type: "response.completed", response: { id: "resp_1", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } };

// Image-call preservation is the image sub-surface of the Responses stream.
for (const row of [
	{
		name: "completed item drops unsupported fields and survives transcript conversion",
		events: [
			{ type: "response.created", response: { id: "resp_1" } },
			{ type: "response.output_item.added", output_index: 0, item: inProgress },
			{ type: "response.output_item.done", output_index: 0, item: { ...completed, output_format: "png", quality: "high" } },
			terminal,
		], expected: [completed],
	},
	{
		name: "in-progress item is not preserved",
		events: [{ type: "response.created", response: { id: "resp_1" } }, { type: "response.output_item.added", output_index: 0, item: inProgress }, terminal], expected: [],
	},
	{
		name: "terminal response output",
		events: [{ ...terminal, response: { ...terminal.response, output: [completed] } }], expected: [completed],
	},
]) {
	test(`image stream: ${row.name}`, async () => {
		const output = createAssistantOutput();
		await processResponsesStream(asAsyncIterable(row.events), output, { push() {} } as never, model);
		assert.deepEqual((output.content as Array<{ type: string }>).filter((block) => block.type === "image_generation_call"), row.expected.map((item) => ({ type: "image_generation_call", item })));
		assert.deepEqual(convertResponsesMessages(model, { messages: [output] }, new Set(["openai-codex"])), row.expected);
	});
}
