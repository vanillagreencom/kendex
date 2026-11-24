import assert from "node:assert/strict";
import test from "node:test";
import { normalizeContext } from "@earendil-works/pi-ai";
import { buildRequestBody } from "../src/provider-shim.js";
import { model } from "./helpers/responses.js";

/* Since Pi 0.86 a provider receives a normalized transcript: the system
 * prompt and the tool declarations sit in `system` messages, and the
 * `systemPrompt` and `tools` fields are gone. A shim that reads those fields
 * sends every request with no system prompt and no tools. A Pi below 0.86 still
 * hands the fields and no system message, and exports no replay helper. A model
 * without mid-conversation system messages gets them folded into the leading one.
 * `codex-request-parity.test.ts` sends a real Pi session through the shim. */

const tool = (name: string) => ({ name, description: `${name} tool`, parameters: { type: "object", properties: {} } });

for (const row of [
	{
		name: "a normalized transcript, Pi 0.86 and later",
		context: normalizeContext({
			systemPrompt: "Base prompt",
			tools: [tool("first"), tool("second")],
			messages: [
				{ role: "user", content: "one", timestamp: 1 },
				{ role: "system", content: "Later instruction", toolsAdded: [tool("third")], toolsRemoved: [{ name: "first" }], timestamp: 2 },
				{ role: "user", content: "two", timestamp: 3 },
			],
		} as never),
		prompt: "Base prompt\n\nLater instruction",
		tools: ["second", "third"],
	},
	{
		name: "a context with the prompt and tool fields, Pi below 0.86",
		context: { systemPrompt: "Base prompt", tools: [tool("first"), tool("second")], messages: [{ role: "user", content: "one", timestamp: 1 }, { role: "user", content: "two", timestamp: 3 }] },
		prompt: "Base prompt",
		tools: ["first", "second"],
	},
]) {
	test(`the request carries the prompt and the tools of ${row.name}`, () => {
		const body = buildRequestBody(model, row.context as never);
		assert.equal(body.instructions, undefined);
		assert.deepEqual((body.tools ?? []).map((entry) => (entry as { name: string }).name), row.tools);
		assert.deepEqual(body.input.map((item) => (item as { role?: string }).role), ["developer", "user", "user"]);
		assert.equal((body.input[0] as { content?: unknown }).content, row.prompt);
	});
}
