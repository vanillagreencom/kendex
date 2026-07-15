import assert from "node:assert/strict";
import test from "node:test";
import { zstdDecompressSync } from "node:zlib";
import { buildCodexUserAgent, buildRequestBody, compressRequestBodyZstd, getEnvApiKeyCompat } from "../src/provider-shim.js";
import { convertResponsesMessages } from "../src/providers/openai-responses-shared.js";

const model = {
	id: "gpt-5.5",
	name: "GPT-5.5",
	api: "openai-codex-responses",
	provider: "openai-codex",
	baseUrl: "https://chatgpt.com/backend-api",
	reasoning: true,
	input: ["text"],
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	contextWindow: 272000,
	maxTokens: 128000,
} as any;

test("Codex request body forwards required tool choice", () => {
	const body = buildRequestBody(model, { messages: [], tools: [] } as any, { toolChoice: "required" } as any);
	assert.equal(body.tool_choice, "required");
});

test("Codex SSE request bodies use reversible zstd compression", () => {
	const source = JSON.stringify({ model: "gpt-5.5", input: [{ role: "user", content: "hello" }] });
	const compressed = compressRequestBodyZstd(source);
	assert.ok(compressed, "Node runtime must expose zstd compression");
	assert.equal(zstdDecompressSync(compressed).toString("utf8"), source);
});

test("Codex user agent synchronously includes OS metadata", () => {
	const userAgent = buildCodexUserAgent();
	assert.match(userAgent, /^pi \(.+; .+\)$/);
	assert.notEqual(userAgent, "pi (browser)");
});

test("Codex API-key lookup falls back to the pi-ai compat entrypoint", async () => {
	const key = await getEnvApiKeyCompat("openai-codex", {
		root: {},
		loadCompat: async () => ({ getEnvApiKey: (provider: string) => `key-for-${provider}` }),
	});
	assert.equal(key, "key-for-openai-codex");
});

test("Codex API-key lookup prefers the legacy root export", async () => {
	const key = await getEnvApiKeyCompat("openai-codex", {
		root: { getEnvApiKey: (provider: string) => `root-key-for-${provider}` },
		loadCompat: async () => { throw new Error("compat should not load"); },
	});
	assert.equal(key, "root-key-for-openai-codex");
});

test("empty tool results use no-output placeholder instead of image placeholder", () => {
	const messages = convertResponsesMessages(model, {
		messages: [{ role: "toolResult", toolCallId: "call_1|fc_1", toolName: "noop", content: [], isError: false, timestamp: Date.now() }],
	} as any, new Set(["openai-codex"]));
	assert.deepEqual(messages, [{ type: "function_call_output", call_id: "call_1", output: "(no tool output)" }]);
});