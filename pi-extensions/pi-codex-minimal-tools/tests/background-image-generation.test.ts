import assert from "node:assert/strict";
import test from "node:test";
import { buildBackgroundImageRequest, buildHeaders, parseImageGenCommandArgs, selectCodexImageModel, summarizeNonImageResponse } from "../src/background-image-generation.js";

function codexToken(accountId: string): string {
	const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: accountId } })).toString("base64");
	return `header.${payload}.signature`;
}

test("parseImageGenCommandArgs separates @reference images from prompt", () => {
	assert.deepEqual(parseImageGenCommandArgs("make it green @icon.png 'with soft shadows' @refs/logo.webp"), {
		prompt: "make it green with soft shadows",
		imagePaths: ["icon.png", "refs/logo.webp"],
	});
});

test("parseImageGenCommandArgs treats pasted image paths as references", () => {
	assert.deepEqual(parseImageGenCommandArgs("make this button green /tmp/pi-clipboard-abc.png"), {
		prompt: "make this button green",
		imagePaths: ["/tmp/pi-clipboard-abc.png"],
	});
	assert.deepEqual(parseImageGenCommandArgs("edit file:///tmp/reference.webp."), {
		prompt: "edit",
		imagePaths: ["/tmp/reference.webp"],
	});
});

test("buildBackgroundImageRequest requests generate without reference images", () => {
	const body = buildBackgroundImageRequest({ prompt: "draw a red apple", referenceImages: [], responsesModel: "gpt-5.6-sol", imageModel: "gpt-image-2" });
	assert.equal(body.model, "gpt-5.6-sol");
	assert.deepEqual(body.tools, [{ type: "image_generation", model: "gpt-image-2", output_format: "png", action: "generate" }]);
	assert.deepEqual(body.tool_choice, { type: "image_generation" });
});

test("buildBackgroundImageRequest requests edit with reference images", () => {
	const body = buildBackgroundImageRequest({
		prompt: "change icon to green",
		referenceImages: [{ path: "/tmp/icon.png", mimeType: "image/png", base64: "abc" }],
		responsesModel: "gpt-5.6-sol",
		imageModel: "gpt-image-2",
	});
	assert.deepEqual(body.tools, [{ type: "image_generation", model: "gpt-image-2", output_format: "png", action: "edit" }]);
	const input = body.input as Array<{ content: Array<{ type: string; text?: string; image_url?: string }> }>;
	assert.equal(input[0].content[0].text, "Edit the provided image(s): change icon to green");
	assert.equal(input[0].content[1].type, "input_image");
	assert.equal(input[0].content[1].image_url, "data:image/png;base64,abc");
});

test("selectCodexImageModel prefers current image-capable Codex model and registry fallback", () => {
	const current = { provider: "openai-codex", id: "gpt-5.4", input: ["text", "image"] };
	assert.equal(selectCodexImageModel(current, undefined), current);
	const fallback = { provider: "openai-codex", id: "gpt-5.6-sol", input: ["text", "image"] };
	assert.equal(selectCodexImageModel({ provider: "anthropic", id: "claude", input: ["text", "image"] }, { getAll: () => [fallback] }), fallback);
	assert.equal(selectCodexImageModel({ provider: "anthropic", id: "claude", input: ["text", "image"] }, { getAvailable: () => [fallback] }), fallback);
	assert.equal(selectCodexImageModel({ provider: "openai-codex", id: "text-only", input: ["text"] }, { find: (_provider, _id) => fallback }), fallback);
	assert.equal(selectCodexImageModel({ provider: "openai-codex", id: "text-only", input: ["text"] }, { getAll: () => [{ provider: "openai-codex", id: "also-text-only", input: ["text"] }] }), undefined);
});

test("buildHeaders treats null provider headers as deletions, not the string \"null\"", () => {
	const model = { headers: { "x-inherited": "keep", "x-dropped": "stale" } } as never;
	const headers = buildHeaders(model, codexToken("acct-1"), { "x-dropped": null, "x-added": "value" });
	assert.equal(headers.get("x-dropped"), null);
	assert.equal(headers.get("x-inherited"), "keep");
	assert.equal(headers.get("x-added"), "value");
});

test("buildHeaders keeps the request's own pinned headers even when nulled by the provider", () => {
	const model = { headers: {} } as never;
	const headers = buildHeaders(model, codexToken("acct-2"), {
		Authorization: null,
		"chatgpt-account-id": null,
		originator: null,
		"content-type": null,
	});
	assert.equal(headers.get("authorization"), `Bearer ${codexToken("acct-2")}`);
	assert.equal(headers.get("chatgpt-account-id"), "acct-2");
	assert.equal(headers.get("originator"), "pi");
	assert.equal(headers.get("content-type"), "application/json");
});

test("summarizeNonImageResponse includes status, error, and text output", () => {
	const summary = summarizeNonImageResponse({
		status: "failed",
		error: { message: "image tool failed" },
		output: [{ type: "message", content: [{ type: "output_text", text: "Could not generate that image." }] }],
	});
	assert.equal(summary, "No image was returned by Codex: status failed · image tool failed · Could not generate that image.");
});
