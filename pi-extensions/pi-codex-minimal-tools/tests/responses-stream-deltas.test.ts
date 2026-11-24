import assert from "node:assert/strict";
import test from "node:test";
import { processResponsesStream } from "../src/providers/openai-responses-shared.js";
import { asAsyncIterable, createAssistantOutput, model } from "./helpers/responses.js";

const completed = { type: "response.completed", response: { id: "resp_1", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } };

async function run(events: unknown[]) {
	const output = createAssistantOutput();
	const pushed: Array<{ type: string; delta?: string; text?: string; arguments?: unknown }> = [];
	const stream = {
		push(event: { type: string; delta?: string; contentIndex?: number }) {
			const block = event.contentIndex === undefined ? undefined : output.content[event.contentIndex] as { text?: string; thinking?: string; arguments?: unknown };
			pushed.push({ type: event.type, delta: event.delta, text: block?.text ?? block?.thinking, arguments: structuredClone(block?.arguments) });
		},
	};
	await processResponsesStream(asAsyncIterable(events), output, stream as never, model);
	return { output, pushed };
}

const text = (content_index: number, delta: string) => ({ type: "response.output_text.delta", output_index: 0, content_index, delta });
const refusal = (content_index: number, delta: string) => ({ type: "response.refusal.delta", output_index: 0, content_index, delta });
const summary = (summary_index: number, delta: string) => ({ type: "response.reasoning_summary_text.delta", output_index: 0, summary_index, delta });

// Each delta event reports the appended text and the block text right after it.
// A delta to the last part appends; a new part, a delta to an earlier part, or a
// block whose text left its parts behind renders every part again and emits only
// a pure extension of the previous text.
for (const row of [
	{
		name: "message parts",
		events: [
			{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: "msg_1" } },
			{ type: "response.content_part.added", output_index: 0, content_index: 0, part: { type: "output_text", text: "" } },
			text(0, "Hel"),
			text(0, "lo"),
			{ type: "response.content_part.added", output_index: 0, content_index: 1, part: { type: "output_text", text: "!" } },
			text(1, " there"),
			text(0, "X"),
			text(1, "?"),
			text(2, "+"),
			text(2, "+"),
		],
		deltas: [
			{ delta: "Hel", text: "Hel" },
			{ delta: "lo", text: "Hello" },
			{ delta: "! there", text: "Hello! there" },
			{ delta: "?", text: "HelloX! there?" },
			{ delta: "+", text: "HelloX! there?+" },
			{ delta: "+", text: "HelloX! there?++" },
		],
	},
	{
		name: "refusal parts",
		events: [
			{ type: "response.output_item.added", output_index: 0, item: { type: "message", id: "msg_1" } },
			{ type: "response.content_part.added", output_index: 0, content_index: 0, part: { type: "refusal", refusal: "" } },
			refusal(0, "Can"),
			refusal(0, "not"),
			{ type: "response.content_part.added", output_index: 0, content_index: 1, part: { type: "refusal", refusal: "!" } },
			refusal(1, " help"),
			refusal(0, "X"),
			refusal(1, "."),
		],
		deltas: [
			{ delta: "Can", text: "Can" },
			{ delta: "not", text: "Cannot" },
			{ delta: "! help", text: "Cannot! help" },
			{ delta: ".", text: "CannotX! help." },
		],
	},
	{
		name: "reasoning summary parts",
		events: [
			{ type: "response.output_item.added", output_index: 0, item: { type: "reasoning", id: "rs_1" } },
			{ type: "response.reasoning_summary_part.added", output_index: 0, summary_index: 0, part: { text: "" } },
			summary(0, "a"),
			summary(0, "b"),
			{ type: "response.reasoning_summary_part.added", output_index: 0, summary_index: 1, part: { text: "" } },
			summary(1, "c"),
			summary(1, "d"),
			{ type: "response.reasoning_summary_part.done", output_index: 0, summary_index: 1, part: { text: "cd" } },
			{ type: "response.reasoning_text.delta", output_index: 0, delta: "raw" },
			summary(1, "e"),
			summary(1, "f"),
			summary(2, "g"),
			summary(2, "h"),
		],
		deltas: [
			{ delta: "a", text: "a" },
			{ delta: "b", text: "ab" },
			{ delta: "\n\nc", text: "ab\n\nc" },
			{ delta: "d", text: "ab\n\ncd" },
			{ delta: "raw", text: "ab\n\ncdraw" },
			{ delta: "f", text: "ab\n\ncdef" },
			{ delta: "\n\ng", text: "ab\n\ncdef\n\ng" },
			{ delta: "h", text: "ab\n\ncdef\n\ngh" },
		],
	},
]) {
	test(`streamed ${row.name} emit their appended text`, async () => {
		const { pushed } = await run([...row.events, completed]);
		const deltas = pushed.filter((event) => event.type === "text_delta" || event.type === "thinking_delta").map(({ delta, text }) => ({ delta, text }));
		assert.deepEqual(deltas, row.deltas);
	});
}

const argumentDeltas = Array.from('{"path":"/tmp/streamed","content":"body"}', (delta) => ({ type: "response.function_call_arguments.delta", output_index: 0, delta }));
const argumentsJson = argumentDeltas.map((event) => event.delta).join("");
const functionCall = { type: "function_call", id: "fc_1", call_id: "call_1", name: "write", arguments: "" };

// Each delta is read once and the partial arguments show while the call streams; the
// whole text is parsed once, at completion, so a stream of one delta per character
// costs time linear in the argument length.
test("streamed function-call arguments show as they arrive and parse once at completion", async (t) => {
	const parse = t.mock.method(JSON, "parse");
	const { output, pushed } = await run([
		{ type: "response.output_item.added", output_index: 0, item: functionCall },
		...argumentDeltas,
		{ type: "response.function_call_arguments.done", output_index: 0, arguments: argumentsJson },
		{ type: "response.output_item.done", output_index: 0, item: { ...functionCall, arguments: argumentsJson } },
		completed,
	]);
	const argumentParses = parse.mock.calls.filter((call) => call.arguments[0] === argumentsJson).length;
	parse.mock.restore();
	assert.equal(argumentParses, 1);
	assert.deepEqual((output.content[0] as { arguments: unknown }).arguments, { path: "/tmp/streamed", content: "body" });
	const deltas = pushed.filter((event) => event.type === "toolcall_delta");
	assert.equal(deltas.map((event) => event.delta).join(""), argumentsJson);
	const pathClosed = argumentsJson.indexOf(",");
	assert.equal((deltas[pathClosed]?.arguments as { path?: string } | undefined)?.path, "/tmp/streamed");
	assert.equal(Object.keys(output.content[0]!).some((key) => key === "partialJson" || key === "customInput"), false, "no stream state on the block");
});

// The final arguments go through Pi's repairing parser; text that is still no JSON
// object carries argumentsError, so validation shows the model what it sent.
for (const row of [
	{ name: "an invalid \\u escape keeps every field", text: '{"command":"\\usepackage","count":1}', arguments: { command: "\\usepackage", count: 1 }, error: false },
	{ name: "malformed arguments carry argumentsError", text: '{"command":"ls"', arguments: {}, error: true },
]) {
	test(`completed function-call arguments: ${row.name}`, async () => {
		const { output } = await run([
			{ type: "response.output_item.added", output_index: 0, item: functionCall },
			{ type: "response.function_call_arguments.delta", output_index: 0, delta: row.text },
			{ type: "response.output_item.done", output_index: 0, item: { ...functionCall, arguments: row.text } },
			completed,
		]);
		const toolCall = output.content[0] as { arguments: unknown; argumentsError?: string };
		assert.deepEqual(toolCall.arguments, row.arguments);
		assert.equal(typeof toolCall.argumentsError === "string" && toolCall.argumentsError.includes(row.text), row.error);
	});
}
