import assert from "node:assert/strict";
import test from "node:test";
import { rewriteNativeOpenAiTools } from "../src/provider-native-tools.js";

const tools = [
	{ type: "function", name: "image_generation", parameters: { output_format: "webp" } },
	{ type: "function", function: { name: "web_search", parameters: {} } },
	{ type: "function", name: "read" },
];
const native = { type: "image_generation", model: "gpt-image-2", output_format: "webp", action: "auto" };

// The shim declares tools top-level, or in additional_tools input items on a model that takes them.
for (const row of [
	{ name: "top-level tools", payload: { tools }, rewrittenTools: (payload: any) => payload.tools },
	{
		name: "an additional_tools input item",
		payload: { input: [{ role: "developer", content: "Base prompt" }, { type: "additional_tools", role: "developer", tools }, { role: "user", content: "draw" }] },
		rewrittenTools: (payload: any) => payload.input[1].tools,
	},
]) {
	test(`rewriteNativeOpenAiTools rewrites image_generation in ${row.name}`, () => {
		const result = rewriteNativeOpenAiTools(row.payload, { imageModel: "gpt-image-2" });
		assert.deepEqual(result.rewritten, ["image_generation"]);
		assert.deepEqual(row.rewrittenTools(result.payload), [native, tools[1], tools[2]]);
	});
}
