import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { convertResponsesMessages, processResponsesStream } from "../src/providers/openai-responses-shared.js";
import { saveOpenAICodexGeneratedImage } from "../src/provider-shim.js";

async function* asAsyncIterable(events: any[]) {
	for (const event of events) yield event;
}

function createAssistantOutput() {
	return {
		role: "assistant",
		content: [],
		api: "openai-codex-responses",
		provider: "openai-codex",
		model: "gpt-6-astra",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
		stopReason: "stop",
		timestamp: Date.now(),
	} as any;
}

const model = {
	provider: "openai-codex",
	api: "openai-codex-responses",
	id: "gpt-6-astra",
	input: ["text", "image"],
	reasoning: true,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
} as any;

test("processResponsesStream preserves completed image_generation_call items for later turns", async () => {
	const output = createAssistantOutput();
	const base64 = Buffer.from("png-bytes").toString("base64");
	const rawImageItem = {
		type: "image_generation_call",
		id: "ig_123",
		status: "completed",
		result: base64,
		output_format: "png",
		revised_prompt: "A tiny red square icon",
		quality: "high",
	};
	const expectedImageItem = {
		type: "image_generation_call",
		id: "ig_123",
		status: "completed",
		result: base64,
		revised_prompt: "A tiny red square icon",
	};

	await processResponsesStream(
		asAsyncIterable([
			{ type: "response.created", response: { id: "resp_1" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "image_generation_call", id: "ig_123", status: "in_progress" } },
			{ type: "response.output_item.done", output_index: 0, item: rawImageItem },
			{ type: "response.completed", response: { id: "resp_1", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } },
		]),
		output,
		{ push() {} } as any,
		model,
	);

	assert.deepEqual(output.content.filter((block: any) => block.type === "image_generation_call"), [
		{ type: "image_generation_call", item: expectedImageItem },
	]);
	assert.deepEqual(convertResponsesMessages(model, { messages: [output] } as any, new Set(["openai-codex"])), [expectedImageItem]);
});

test("processResponsesStream ignores in-progress image_generation_call items", async () => {
	const output = createAssistantOutput();
	await processResponsesStream(
		asAsyncIterable([
			{ type: "response.created", response: { id: "resp_1" } },
			{ type: "response.output_item.added", output_index: 0, item: { type: "image_generation_call", id: "ig_123", status: "in_progress" } },
			{ type: "response.completed", response: { id: "resp_1", status: "completed", usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } },
		]),
		output,
		{ push() {} } as any,
		model,
	);
	assert.deepEqual(output.content.filter((block: any) => block.type === "image_generation_call"), []);
});

test("processResponsesStream preserves image_generation_call items from terminal response output", async () => {
	const output = createAssistantOutput();
	const base64 = Buffer.from("png-bytes").toString("base64");
	const imageItem = {
		type: "image_generation_call",
		id: "ig_terminal",
		status: "completed",
		result: base64,
		revised_prompt: "A terminal-output image",
	};

	await processResponsesStream(
		asAsyncIterable([
			{
				type: "response.completed",
				response: {
					id: "resp_terminal",
					status: "completed",
					output: [imageItem],
					usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } },
				},
			},
		]),
		output,
		{ push() {} } as any,
		model,
	);

	assert.deepEqual(output.content.filter((block: any) => block.type === "image_generation_call"), [
		{ type: "image_generation_call", item: imageItem },
	]);
});

test("saveOpenAICodexGeneratedImage writes generated images under the configured default output dir", async () => {
	const cwd = await fs.mkdtemp(path.join(os.tmpdir(), "pi-codex-minimal-image-"));
	const encoded = Buffer.from("png-bytes").toString("base64");
	try {
		const saved = await saveOpenAICodexGeneratedImage(cwd, { responseId: "resp_123", callId: "ig_456", result: encoded, outputFormat: "png", imageModel: "gpt-image-2" });
		assert.match(saved.relativePath, /^\.pi[/\\]openai-codex-images[/\\][\dTZ-]+-[a-f0-9]{8}\.png$/);
		assert.equal(saved.latestRelativePath, path.join(".pi", "openai-codex-images", "latest.png"));
		assert.equal(saved.imageModel, "gpt-image-2");
		assert.deepEqual(await fs.readFile(saved.absolutePath), Buffer.from("png-bytes"));
		assert.deepEqual(await fs.readFile(saved.latestAbsolutePath), Buffer.from("png-bytes"));
	} finally {
		await fs.rm(cwd, { recursive: true, force: true });
	}
});
