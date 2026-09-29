import assert from "node:assert/strict";
import test from "node:test";
import { completedEvent, providerWorld, runCodexProvider, sseResponse, successSseResponse } from "./helpers/provider.js";

test("invalid grammar schema settles provider stream as an error", async (t) => {
	providerWorld(t);
	globalThis.fetch = async () => successSseResponse();
	const result = await runCodexProvider(
		{},
		{ compat: { supportsOpenAIGrammarTools: true } },
		{
			tools: [{
				name: "bad_grammar",
				description: "Bad grammar",
				parameters: { type: "object", properties: { a: { type: "string" }, b: { type: "string" } }, required: ["a", "b"] },
				constrainedSampling: { type: "grammar", variants: { openai_lark: "start: /.+/" } },
			}],
		},
	);

	assert.equal(result.stopReason, "error");
	assert.equal(result.errorMessage?.split("\n")[0], "grammar_schema=bad_grammar");
});


test("a streamed grammar tool call carries its input under the tool's own property", async (t) => {
	providerWorld(t);
	const item = { type: "custom_tool_call", id: "ctc_1", call_id: "call_1", name: "sql", input: "SELECT 1" };
	const events = [
		{ type: "response.output_item.added", output_index: 0, item: { ...item, input: "" } },
		{ type: "response.output_item.done", output_index: 0, item },
		completedEvent,
	];
	globalThis.fetch = async () => sseResponse(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join(""));
	const result = await runCodexProvider(
		{},
		{ compat: { supportsOpenAIGrammarTools: true } },
		{
			tools: [{
				name: "sql",
				description: "Generate SQL",
				parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
				constrainedSampling: { type: "grammar", variants: { openai_lark: "start: /.+/" } },
			}],
		},
	);

	assert.equal(result.stopReason, "toolUse", result.errorMessage);
	const call = result.content.find((block) => block.type === "toolCall");
	assert.deepEqual(call?.arguments, { query: "SELECT 1" });
});
