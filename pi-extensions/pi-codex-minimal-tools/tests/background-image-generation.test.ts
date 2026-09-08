import assert from "node:assert/strict";
import test from "node:test";
import { buildBackgroundImageRequest } from "../src/background-image-generation.js";

for (const row of [
	{ action: "generate", prompt: "draw a red apple", referenceImages: [] },
	{ action: "edit", prompt: "change icon to green", referenceImages: [{ path: "/tmp/icon.png", mimeType: "image/png", base64: "abc" }] },
]) {
	test(`background image request: ${row.action}`, () => {
		const body = buildBackgroundImageRequest({ prompt: row.prompt, referenceImages: row.referenceImages, responsesModel: "gpt-6-astra", imageModel: "gpt-image-2" });
		assert.equal(body.model, "gpt-6-astra");
		assert.deepEqual(body.tools, [{ type: "image_generation", model: "gpt-image-2", output_format: "png", action: row.action }]);
		assert.deepEqual(body.tool_choice, { type: "image_generation" });
		if (row.action === "edit") {
			const input = body.input as Array<{ content: Array<{ type: string; text?: string; image_url?: string }> }>;
			assert.ok(input[0].content[0].text?.includes(row.prompt));
			assert.equal(input[0].content[1].type, "input_image");
			assert.equal(input[0].content[1].image_url, "data:image/png;base64,abc");
		}
	});
}
