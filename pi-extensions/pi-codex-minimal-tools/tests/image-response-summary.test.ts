import assert from "node:assert/strict";
import test from "node:test";
import { summarizeNonImageResponse } from "../src/background-image-generation.js";

test("non-image response summary retains upstream status, error and text", () => {
	const response = { status: "failed", error: { message: "upstream-error-token" }, output: [{ type: "message", content: [{ type: "output_text", text: "upstream-output-token" }] }] };
	const summary = summarizeNonImageResponse(response);
	for (const value of [response.status, response.error.message, response.output[0].content[0].text]) assert.ok(summary.includes(value), value);
});
