import assert from "node:assert/strict";
import test from "node:test";
import { processResponsesStream } from "../src/providers/openai-responses-shared.js";

async function* asAsyncIterable(events: any[]) {
	for (const event of events) yield event;
}

function createAssistantOutput() {
	return {
		role: "assistant",
		content: [],
		api: "openai-codex-responses",
		provider: "openai-codex",
		model: "gpt-5.6-sol",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
		stopReason: "stop",
		timestamp: Date.now(),
	} as any;
}

const model = {
	provider: "openai-codex",
	api: "openai-codex-responses",
	id: "gpt-5.6-sol",
	input: ["text"],
	reasoning: true,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
} as any;

// OpenAI-compatible streams can emit reasoning -> empty message (content: null)
// -> function_call. The tool call must survive the null-content message item.
test("processResponsesStream tolerates a null-content message item before a function_call", async () => {
	const output = createAssistantOutput();

	await processResponsesStream(
		asAsyncIterable([
			{ type: "response.created", response: { id: "resp_1" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: "msg_1" } },
			{ type: "response.output_item.done", output_index: 0, item: { type: "message", id: "msg_1", content: null } },
			{ type: "response.output_item.added", output_index: 1, item: { type: "function_call", id: "fc_1", call_id: "call_1", name: "read", arguments: "" } },
			{ type: "response.function_call_arguments.done", output_index: 1, arguments: '{"path":"/tmp/x"}' },
			{ type: "response.output_item.done", output_index: 1, item: { type: "function_call", id: "fc_1", call_id: "call_1", name: "read", arguments: '{"path":"/tmp/x"}' } },
			{ type: "response.completed", response: { id: "resp_1", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } },
		]),
		output,
		{ push() {} } as any,
		model,
	);

	const toolCalls = output.content.filter((block: any) => block.type === "toolCall");
	assert.equal(toolCalls.length, 1, "tool call should survive a null-content message item");
	assert.equal(toolCalls[0].name, "read");
	assert.deepEqual(toolCalls[0].arguments, { path: "/tmp/x" });
	assert.equal(output.stopReason, "toolUse");

	const textBlocks = output.content.filter((block: any) => block.type === "text");
	assert.equal(textBlocks[0]?.text, "", "null message content collapses to empty text");
});

test("processResponsesStream records reasoning token usage and incomplete stop reason", async () => {
	const output = createAssistantOutput();

	await processResponsesStream(
		asAsyncIterable([
			{ type: "response.created", response: { id: "resp_2" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "reasoning", id: "rs_1" } },
			{ type: "response.reasoning_text.delta", output_index: 0, delta: "hidden chain" },
			{ type: "response.output_item.done", output_index: 0, item: { type: "reasoning", id: "rs_1", summary: [], content: [{ text: "preserved reasoning" }] } },
			{ type: "response.incomplete", response: { id: "resp_2", status: "incomplete", usage: { input_tokens: 11, output_tokens: 7, total_tokens: 18, input_tokens_details: { cached_tokens: 3, cache_write_tokens: 2 }, output_tokens_details: { reasoning_tokens: 5 } } } },
		]),
		output,
		{ push() {} } as any,
		model,
	);

	assert.equal(output.stopReason, "length");
	assert.equal(output.usage.input, 6);
	assert.equal(output.usage.cacheWrite, 2);
	assert.equal((output.usage as any).reasoning, 5);
	const thinking = output.content.find((block: any) => block.type === "thinking") as any;
	assert.equal(thinking.thinking, "preserved reasoning");
});

test("processResponsesStream converts streamed grammar input into normal tool arguments", async () => {
	const output = createAssistantOutput();
	const events: any[] = [];

	await processResponsesStream(
		asAsyncIterable([
			{ type: "response.created", response: { id: "resp_grammar" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "custom_tool_call", id: "ctc_1", call_id: "call_1", name: "sql", input: "" } },
			{ type: "response.custom_tool_call_input.delta", output_index: 0, delta: "SELECT " },
			{ type: "response.custom_tool_call_input.done", output_index: 0, input: "SELECT 1" },
			{ type: "response.output_item.done", output_index: 0, item: { type: "custom_tool_call", id: "ctc_1", call_id: "call_1", name: "sql", input: "SELECT 1" } },
			{ type: "response.completed", response: { id: "resp_grammar", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } },
		]),
		output,
		{ push(event: any) { events.push(event); } } as any,
		model,
		{ grammarToolInputProperties: new Map([["sql", "query"]]) },
	);

	const toolCall = output.content.find((block: any) => block.type === "toolCall") as any;
	assert.deepEqual(toolCall.arguments, { query: "SELECT 1" });
	assert.equal(toolCall.partialJson, undefined);
	assert.equal(output.stopReason, "toolUse");
	assert.equal(events.filter((event) => event.type === "toolcall_end").length, 1);
	const streamedJson = events.filter((event) => event.type === "toolcall_delta").map((event) => event.delta).join("");
	assert.deepEqual(JSON.parse(streamedJson), { query: "SELECT 1" });
});

test("processResponsesStream handles done-only grammar input with escaping", async () => {
	const output = createAssistantOutput();
	const events: any[] = [];
	const input = "SELECT \\\"quoted\\\"\\nline";

	await processResponsesStream(
		asAsyncIterable([
			{ type: "response.created", response: { id: "resp_done_only" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "custom_tool_call", id: "ctc_2", call_id: "call_2", name: "sql", input: "" } },
			{ type: "response.output_item.done", output_index: 0, item: { type: "custom_tool_call", id: "ctc_2", call_id: "call_2", name: "sql", input } },
			{ type: "response.completed", response: { id: "resp_done_only", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } },
		]),
		output,
		{ push(event: any) { events.push(event); } } as any,
		model,
		{ grammarToolInputProperties: new Map([["sql", "query"]]) },
	);

	const streamedJson = events.filter((event) => event.type === "toolcall_delta").map((event) => event.delta).join("");
	assert.deepEqual(JSON.parse(streamedJson), { query: input });
	assert.deepEqual((output.content.find((block: any) => block.type === "toolCall") as any).arguments, { query: input });
});

test("processResponsesStream rejects non-monotonic grammar input", async () => {
	const output = createAssistantOutput();
	await assert.rejects(
		() => processResponsesStream(
			asAsyncIterable([
				{ type: "response.created", response: { id: "resp_bad_grammar" } },
				{ type: "response.output_item.added", output_index: 0, item: { type: "custom_tool_call", id: "ctc_3", call_id: "call_3", name: "sql", input: "" } },
				{ type: "response.custom_tool_call_input.delta", output_index: 0, delta: "SELECT" },
				{ type: "response.custom_tool_call_input.done", output_index: 0, input: "DROP" },
			]),
			output,
			{ push() {} } as any,
			model,
			{ grammarToolInputProperties: new Map([["sql", "query"]]) },
		),
		/non-monotonically/,
	);
});

test("processResponsesStream fails when stream ends before terminal response event", async () => {
	const output = createAssistantOutput();
	await assert.rejects(
		() => processResponsesStream(
			asAsyncIterable([
				{ type: "response.created", response: { id: "resp_missing_terminal" } },
				{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: "msg_1" } },
				{ type: "response.output_text.delta", output_index: 0, content_index: 0, delta: "partial" },
			]),
			output,
			{ push() {} } as any,
			model,
		),
		/OpenAI Responses stream ended before a terminal response event/,
	);
});
