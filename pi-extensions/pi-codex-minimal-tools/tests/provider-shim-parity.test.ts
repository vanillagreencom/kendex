import assert from "node:assert/strict";
import test from "node:test";
import { zstdDecompressSync } from "node:zlib";
import {
	buildCodexUserAgent,
	buildRequestBody,
	clampOpenAIPromptCacheKey,
	compressRequestBodyZstd,
	createCodexRequestId,
	getEnvApiKeyCompat,
	isPreviousResponseNotFoundError,
	isRetryableError,
} from "../src/provider-shim.js";
import { convertResponsesMessages } from "../src/providers/openai-responses-shared.js";

const model = {
	id: "gpt-6-astra",
	name: "GPT-6 Astra",
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

test("Codex request body enables required strict JSON-schema tools", () => {
	const body = buildRequestBody(model, {
		messages: [],
		tools: [{
			name: "strict_tool",
			description: "Strict tool",
			parameters: { type: "object", properties: { value: { type: "string" } }, required: ["value"] },
			constrainedSampling: { type: "json_schema", strict: "require" },
		}],
	} as any);
	assert.equal((body.tools?.[0] as any).strict, true);
});

test("Codex request body rejects required strict tools when model disables strict mode", () => {
	assert.throws(() => buildRequestBody({ ...model, compat: { supportsStrictMode: false } }, {
		messages: [],
		tools: [{
			name: "strict_tool",
			description: "Strict tool",
			parameters: { type: "object", properties: { value: { type: "string" } }, required: ["value"] },
			constrainedSampling: { type: "json_schema", strict: "require" },
		}],
	} as any), /requires JSON-schema constrained sampling/);
});

test("Codex request body emits supported grammar tools as OpenAI custom tools", () => {
	const body = buildRequestBody({ ...model, compat: { supportsOpenAIGrammarTools: true } }, {
		messages: [],
		tools: [{
			name: "sql",
			description: "Generate SQL",
			parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
			constrainedSampling: { type: "grammar", variants: { openai_lark: " start: /.+/ " } },
		}],
	} as any);
	assert.deepEqual(body.tools?.[0], {
		type: "custom",
		name: "sql",
		description: "Generate SQL",
		format: { type: "grammar", syntax: "lark", definition: " start: /.+/ " },
	});
});

test("Codex request body falls back to function tools when grammar capability is off", () => {
	const body = buildRequestBody(model, {
		messages: [],
		tools: [{
			name: "sql",
			description: "Generate SQL",
			parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] },
			constrainedSampling: { type: "grammar", variants: { openai_regex: ".+" } },
		}],
	} as any);
	assert.equal((body.tools?.[0] as any).type, "function");
});

test("Codex request body supports regex grammar and rejects malformed grammar schemas", () => {
	const regexBody = buildRequestBody({ ...model, compat: { supportsOpenAIGrammarTools: true } }, {
		messages: [],
		tools: [{
			name: "regex_tool",
			description: "Regex",
			parameters: { type: "object", properties: { input: { type: "string" } }, required: ["input"] },
			constrainedSampling: { type: "grammar", variants: { openai_regex: "[a-z]+" } },
		}],
	} as any);
	assert.deepEqual((regexBody.tools?.[0] as any).format, { type: "grammar", syntax: "regex", definition: "[a-z]+" });
	const whitespaceBody = buildRequestBody({ ...model, compat: { supportsOpenAIGrammarTools: true } }, {
		messages: [],
		tools: [{
			name: "whitespace_regex",
			description: "Whitespace-sensitive regex",
			parameters: { type: "object", properties: { input: { type: "string" } }, required: ["input"] },
			constrainedSampling: { type: "grammar", variants: { openai_regex: " ^foo$ " } },
		}],
	} as any);
	assert.equal((whitespaceBody.tools?.[0] as any).format.definition, " ^foo$ ");
	assert.throws(() => buildRequestBody({ ...model, compat: { supportsOpenAIGrammarTools: true } }, {
		messages: [],
		tools: [{
			name: "bad_grammar",
			description: "Bad",
			parameters: { type: "object", properties: { first: { type: "string" }, second: { type: "string" } }, required: ["first", "second"] },
			constrainedSampling: { type: "grammar", variants: { openai_lark: "start: /.+/" } },
		}],
	} as any), /exactly one required string property/);
});

test("Codex request body places dynamically added tools at transcript load point", () => {
	const loader = { name: "search_tools", description: "Search", parameters: { type: "object", properties: {} } };
	const deferred = { name: "special_tool", description: "Special", parameters: { type: "object", properties: {} } };
	const body = buildRequestBody({ ...model, compat: { supportsToolSearch: true } }, {
		tools: [loader, deferred],
		messages: [{
			role: "toolResult",
			toolCallId: "call_1|fc_1",
			toolName: "search_tools",
			content: [{ type: "text", text: "Loaded special_tool" }],
			addedToolNames: ["special_tool"],
			isError: false,
			timestamp: Date.now(),
		}],
	} as any);
	assert.deepEqual((body.tools ?? []).map((tool: any) => tool.name), ["search_tools"]);
	const searchOutput = body.input.find((item: any) => item.type === "tool_search_output") as any;
	assert.ok(searchOutput);
	assert.equal(searchOutput.tools[0].name, "special_tool");
	assert.equal(searchOutput.tools[0].defer_loading, true);
});

test("Codex deferred tool loading emits each definition once", () => {
	const deferred = { name: "special_tool", description: "Special", parameters: { type: "object", properties: {} } };
	const toolResult = (id: string) => ({
		role: "toolResult",
		toolCallId: `${id}|fc_${id}`,
		toolName: "search_tools",
		content: [{ type: "text", text: "Loaded special_tool" }],
		addedToolNames: ["special_tool"],
		isError: false,
		timestamp: Date.now(),
	});
	const body = buildRequestBody({ ...model, compat: { supportsToolSearch: true } }, {
		tools: [deferred],
		messages: [toolResult("call_1"), toolResult("call_2")],
	} as any);
	assert.equal(body.input.filter((item: any) => item.type === "tool_search_output").length, 1);
});

test("Codex cache retention none suppresses session cache key", () => {
	const body = buildRequestBody(model, { messages: [], tools: [] } as any, {
		cacheRetention: "none",
		sessionId: "session-123",
	} as any);
	assert.equal(body.prompt_cache_key, undefined);
});

test("Codex prompt cache keys clamp to 64 Unicode characters", () => {
	const key = `${"a".repeat(63)}😀suffix`;
	const clamped = clampOpenAIPromptCacheKey(key);
	assert.equal(Array.from(clamped ?? "").length, 64);
	assert.equal(clamped, `${"a".repeat(63)}😀`);
});

test("Codex sessionless request IDs are UUIDv7", () => {
	assert.match(createCodexRequestId(), /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test("Codex retry classifier mirrors upstream transient and terminal cases", () => {
	assert.equal(isRetryableError(524, "Cloudflare timeout"), true);
	assert.equal(isRetryableError(400, "grpc ResourceExhausted"), true);
	assert.equal(isRetryableError(400, "socket connection was closed unexpectedly"), true);
	assert.equal(isRetryableError(400, "please retry your request"), true);
	assert.equal(isRetryableError(400, "you can retry your request"), true);
	for (const message of ["Service unavailable", "server error", "Internal server error", "HTTP 503"]) {
		assert.equal(isRetryableError(400, message), true, message);
	}
	assert.equal(isRetryableError(429, "insufficient_quota"), false);
	assert.equal(isRetryableError(429, "ResourceExhausted: quota exceeded"), false);
	assert.equal(isRetryableError(400, "Do not retry the request: invalid schema"), false);
	assert.equal(isRetryableError(400, "billing account disabled"), false);
	assert.equal(isRetryableError(400, "invalid schema"), false);
});

test("Codex detects missing cached continuations by code or message", () => {
	assert.equal(isPreviousResponseNotFoundError({ code: "previous_response_not_found" }), true);
	assert.equal(isPreviousResponseNotFoundError(new Error("Codex error: previous_response_not_found")), true);
	assert.equal(isPreviousResponseNotFoundError(new Error("other failure")), false);
});

test("Codex SSE request bodies use reversible zstd compression", () => {
	const source = JSON.stringify({ model: "gpt-6-astra", input: [{ role: "user", content: "hello" }] });
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
