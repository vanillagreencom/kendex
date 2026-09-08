import assert from "node:assert/strict";
import test from "node:test";
import { processResponsesStream } from "../src/providers/openai-responses-shared.js";
import { asAsyncIterable, createAssistantOutput, model } from "./helpers/responses.js";

const escapedInput = "SELECT \\\"quoted\\\"\\nline";
// Text, reasoning and grammar event sequences share the non-image stream contract.
const cases = [
	{
		name: "processResponsesStream tolerates a null-content message item before a function_call",
		events: [
			{ type: "response.created", response: { id: "resp_1" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: "msg_1" } },
			{ type: "response.output_item.done", output_index: 0, item: { type: "message", id: "msg_1", content: null } },
			{ type: "response.output_item.added", output_index: 1, item: { type: "function_call", id: "fc_1", call_id: "call_1", name: "read", arguments: "" } },
			{ type: "response.function_call_arguments.done", output_index: 1, arguments: '{"path":"/tmp/x"}' },
			{ type: "response.output_item.done", output_index: 1, item: { type: "function_call", id: "fc_1", call_id: "call_1", name: "read", arguments: '{"path":"/tmp/x"}' } },
			{ type: "response.completed", response: { id: "resp_1", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } },
		],
		grammar: false,
		check(output: ReturnType<typeof createAssistantOutput>, events: any[]) {
	const toolCalls = output.content.filter((block) => block.type === "toolCall");
	assert.equal(toolCalls.length, 1, "tool call should survive a null-content message item");
	assert.equal(toolCalls[0].name, "read");
	assert.deepEqual(toolCalls[0].arguments, { path: "/tmp/x" });
	assert.equal(output.stopReason, "toolUse");

	const textBlocks = output.content.filter((block) => block.type === "text");
	assert.equal(textBlocks[0]?.text, "", "null message content collapses to empty text");
		},
	},
	{
		name: "processResponsesStream records reasoning token usage and incomplete stop reason",
		events: [
			{ type: "response.created", response: { id: "resp_2" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "reasoning", id: "rs_1" } },
			{ type: "response.reasoning_text.delta", output_index: 0, delta: "hidden chain" },
			{ type: "response.output_item.done", output_index: 0, item: { type: "reasoning", id: "rs_1", summary: [], content: [{ text: "preserved reasoning" }] } },
			{ type: "response.incomplete", response: { id: "resp_2", status: "incomplete", usage: { input_tokens: 11, output_tokens: 7, total_tokens: 18, input_tokens_details: { cached_tokens: 3, cache_write_tokens: 2 }, output_tokens_details: { reasoning_tokens: 5 } } } },
		],
		grammar: false,
		check(output: ReturnType<typeof createAssistantOutput>, events: any[]) {
	assert.equal(output.stopReason, "length");
	assert.equal(output.usage.input, 6);
	assert.equal(output.usage.cacheWrite, 2);
	assert.equal((output.usage as any).reasoning, 5);
	const thinking = output.content.find((block) => block.type === "thinking") as any;
	assert.equal(thinking.thinking, "preserved reasoning");
		},
	},
	{
		name: "processResponsesStream converts streamed grammar input into normal tool arguments",
		events: [
			{ type: "response.created", response: { id: "resp_grammar" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "custom_tool_call", id: "ctc_1", call_id: "call_1", name: "sql", input: "" } },
			{ type: "response.custom_tool_call_input.delta", output_index: 0, delta: "SELECT " },
			{ type: "response.custom_tool_call_input.done", output_index: 0, input: "SELECT 1" },
			{ type: "response.output_item.done", output_index: 0, item: { type: "custom_tool_call", id: "ctc_1", call_id: "call_1", name: "sql", input: "SELECT 1" } },
			{ type: "response.completed", response: { id: "resp_grammar", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } },
		],
		grammar: true,
		check(output: ReturnType<typeof createAssistantOutput>, events: any[]) {
	const toolCall = output.content.find((block) => block.type === "toolCall") as any;
	assert.deepEqual(toolCall.arguments, { query: "SELECT 1" });
	assert.equal(toolCall.partialJson, undefined);
	assert.equal(output.stopReason, "toolUse");
	assert.equal(events.filter((event) => event.type === "toolcall_end").length, 1);
	const streamedJson = events.filter((event) => event.type === "toolcall_delta").map((event) => event.delta).join("");
	assert.deepEqual(JSON.parse(streamedJson), { query: "SELECT 1" });
		},
	},
	{
		name: "processResponsesStream handles done-only grammar input with escaping",
		events: [
			{ type: "response.created", response: { id: "resp_done_only" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "custom_tool_call", id: "ctc_2", call_id: "call_2", name: "sql", input: "" } },
			{ type: "response.output_item.done", output_index: 0, item: { type: "custom_tool_call", id: "ctc_2", call_id: "call_2", name: "sql", input: escapedInput } },
			{ type: "response.completed", response: { id: "resp_done_only", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } },
		],
		grammar: true,
		check(output: ReturnType<typeof createAssistantOutput>, events: any[]) {
	const streamedJson = events.filter((event) => event.type === "toolcall_delta").map((event) => event.delta).join("");
	assert.deepEqual(JSON.parse(streamedJson), { query: escapedInput });
	assert.deepEqual((output.content.find((block) => block.type === "toolCall") as any).arguments, { query: escapedInput });
		},
	},
	{
		name: "processResponsesStream rejects non-monotonic grammar input",
		events: [
				{ type: "response.created", response: { id: "resp_bad_grammar" } },
				{ type: "response.output_item.added", output_index: 0, item: { type: "custom_tool_call", id: "ctc_3", call_id: "call_3", name: "sql", input: "" } },
				{ type: "response.custom_tool_call_input.delta", output_index: 0, delta: "SELECT" },
				{ type: "response.custom_tool_call_input.done", output_index: 0, input: "DROP" },
		],
		grammar: true,
		code: "GRAMMAR_INPUT_NON_MONOTONIC",
	},
	{
		name: "processResponsesStream fails when stream ends before terminal response event",
		events: [
				{ type: "response.created", response: { id: "resp_missing_terminal" } },
				{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: "msg_1" } },
				{ type: "response.output_text.delta", output_index: 0, content_index: 0, delta: "partial" },
		],
		grammar: false,
		code: "RESPONSES_TERMINAL_MISSING",
	}
];

for (const row of cases) {
	test(row.name, async () => {
		const output = createAssistantOutput();
		const events: any[] = [];
		const run = () => processResponsesStream(asAsyncIterable(row.events), output, { push(event: unknown) { events.push(event); } } as never, model,
			row.grammar ? { grammarToolInputProperties: new Map([["sql", "query"]]) } : undefined);
		if (row.code) await assert.rejects(run, { code: row.code });
		else { await run(); row.check!(output, events); }
	});
}
