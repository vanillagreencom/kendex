import assert from "node:assert/strict";
import test from "node:test";
import { providerWorld, runCodexProvider, successSseResponse } from "./helpers/provider.js";

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

