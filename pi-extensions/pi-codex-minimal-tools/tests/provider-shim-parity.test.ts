import assert from "node:assert/strict";
import test from "node:test";
import { normalizeContext } from "@earendil-works/pi-ai";
import { streamSimple as piStreamSimple } from "@earendil-works/pi-ai/api/openai-codex-responses";
import { buildRequestBody } from "../src/provider-shim.js";
import { model } from "./helpers/responses.js";

for (const row of [
	{ name: "strict supported", strict: true, supported: true, code: undefined },
	{ name: "strict unsupported", strict: true, supported: false, code: "STRICT_SAMPLING_UNSUPPORTED" },
]) {
	test(`request constrained sampling: ${row.name}`, () => {
		const build = () => buildRequestBody({ ...model, compat: { supportsStrictMode: row.supported } } as never, normalizeContext({ messages: [], tools: [{ name: "strict_tool", description: "Strict tool", parameters: { type: "object", properties: { value: { type: "string" } }, required: ["value"] }, constrainedSampling: { type: "json_schema", strict: "require" } }] } as never));
		if (row.code) assert.throws(build, { code: row.code });
		else assert.equal((build().tools?.[0] as { strict: boolean }).strict, true);
	});
}

for (const row of [
	{ name: "Lark", supported: true, variant: "openai_lark", definition: " start: /.+/ ", syntax: "lark", malformed: false },
	{ name: "function fallback", supported: false, variant: "openai_regex", definition: ".+", syntax: "regex", malformed: false },
	{ name: "regex", supported: true, variant: "openai_regex", definition: "[a-z]+", syntax: "regex", malformed: false },
	{ name: "whitespace regex", supported: true, variant: "openai_regex", definition: " ^foo$ ", syntax: "regex", malformed: false },
	{ name: "malformed schema", supported: true, variant: "openai_lark", definition: "start: /.+/", syntax: "lark", malformed: true },
]) {
	test(`request grammar: ${row.name}`, () => {
		const parameters = row.malformed ? { type: "object", properties: { first: { type: "string" }, second: { type: "string" } }, required: ["first", "second"] } : { type: "object", properties: { query: { type: "string" } }, required: ["query"] };
		const build = () => buildRequestBody({ ...model, compat: { supportsOpenAIGrammarTools: row.supported } } as never, normalizeContext({ messages: [], tools: [{ name: "sql", description: "Generate SQL", parameters, constrainedSampling: { type: "grammar", variants: { [row.variant]: row.definition } } }] } as never));
		if (row.malformed) assert.throws(build, { code: "GRAMMAR_SCHEMA", tool: "sql" });
		else if (row.supported) assert.deepEqual(build().tools?.[0], { type: "custom", name: "sql", description: "Generate SQL", format: { type: "grammar", syntax: row.syntax, definition: row.definition } });
		else assert.equal((build().tools?.[0] as { type: string }).type, "function");
	});
}

// Pi 1.0.0 keeps a replayed tool call's item id only when the same model made it
// and its prefix matches the item type: fc_ for function_call, ctc_ for
// custom_tool_call.
const sameModel = { api: model.api, provider: model.provider, model: model.id };
const otherModel = { ...sameModel, model: "gpt-6-other" };
const otherProvider = { api: "anthropic-messages", provider: "anthropic", model: "claude-test" };
for (const row of [
	{ name: "grammar call drops an fc_ id", tool: "sql", callId: "call_1|fc_1", source: sameModel, type: "custom_tool_call", id: undefined },
	{ name: "grammar call keeps a ctc_ id", tool: "sql", callId: "call_1|ctc_1", source: sameModel, type: "custom_tool_call", id: "ctc_1" },
	{ name: "grammar call from a different model drops a ctc_ id", tool: "sql", callId: "call_1|ctc_1", source: otherModel, type: "custom_tool_call", id: undefined },
	{ name: "grammar call from another provider drops its normalized fc_ id", tool: "sql", callId: "call_1|toolu_1", source: otherProvider, type: "custom_tool_call", id: undefined },
	{ name: "function call keeps an fc_ id", tool: "lookup", callId: "call_1|fc_1", source: sameModel, type: "function_call", id: "fc_1" },
	{ name: "function call drops a ctc_ id", tool: "lookup", callId: "call_1|ctc_1", source: sameModel, type: "function_call", id: undefined },
	{ name: "function call from a different model drops an fc_ id", tool: "lookup", callId: "call_1|fc_1", source: otherModel, type: "function_call", id: undefined },
]) {
	test(`replayed tool call item id matches Pi: ${row.name}`, () => {
		const target = { ...model, compat: { supportsOpenAIGrammarTools: true } } as typeof model;
		const tools = [
			{ name: "sql", description: "Generate SQL", parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] }, constrainedSampling: { type: "grammar", variants: { openai_lark: "start: /.+/" } } },
			{ name: "lookup", description: "Look up", parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } },
		];
		const assistant = {
			role: "assistant",
			content: [{ type: "toolCall", id: row.callId, name: row.tool, arguments: { query: "select 1" } }],
			...row.source,
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
			stopReason: "toolUse",
			timestamp: 0,
		};
		const body = buildRequestBody(target, normalizeContext({ messages: [assistant], tools } as never));
		const call = body.input.find((item: any) => item.call_id === "call_1") as any;
		assert.equal(call?.type, row.type);
		assert.equal(call.id, row.id);
	});
}

test("Codex request body forwards required tool choice", () => {
	const body = buildRequestBody(model, normalizeContext({ messages: [], tools: [] } as any), { toolChoice: "required" } as any);
	assert.equal(body.tool_choice, "required");
});
test("Codex request body places dynamically added tools at transcript load point", () => {
	const loader = { name: "search_tools", description: "Search", parameters: { type: "object", properties: {} } };
	const deferred = { name: "special_tool", description: "Special", parameters: { type: "object", properties: {} } };
	const body = buildRequestBody({ ...model, compat: { supportsToolSearch: true } }, normalizeContext({
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
	} as any));
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
	const body = buildRequestBody({ ...model, compat: { supportsToolSearch: true } }, normalizeContext({
		tools: [deferred],
		messages: [toolResult("call_1"), toolResult("call_2")],
	} as any));
	assert.equal(body.input.filter((item: any) => item.type === "tool_search_output").length, 1);
});
test("Codex cache retention none suppresses session cache key", () => {
	const body = buildRequestBody(model, normalizeContext({ messages: [], tools: [] } as any), {
		cacheRetention: "none",
		sessionId: "session-123",
	} as any);
	assert.equal(body.prompt_cache_key, undefined);
});

// Pi's own openai-codex-responses builds the request the shim replaces; its
// onPayload hook hands the body over before any transport runs.
async function piRequestBody(target: typeof model, reasoning: string | undefined): Promise<Record<string, unknown>> {
	const claims = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" } })).toString("base64");
	let body: Record<string, unknown> | undefined;
	const stop = new Error("payload captured");
	const stream = piStreamSimple(target, normalizeContext({ messages: [], tools: [] } as never), {
		apiKey: `header.${claims}.signature`,
		reasoning,
		onPayload: (payload: unknown) => {
			body = payload as Record<string, unknown>;
			throw stop;
		},
	} as never);
	const result = await stream.result();
	assert.equal(result.errorMessage, stop.message, "Pi's provider must stop at the payload hook");
	assert.ok(body, "Pi's provider must hand its request body to onPayload");
	return body;
}

for (const row of [
	{ name: "Off maps to the model's Off effort", map: { off: "low" }, reasoning: "off" },
	{ name: "Off with no Off entry sends none", map: undefined, reasoning: "off" },
	{ name: "no thinking level sends the Off effort", map: { off: "none" }, reasoning: undefined },
	{ name: "Off level on a null Off entry clamps to minimal", map: { off: null, minimal: "low" }, reasoning: "off" },
	// pi-ai's openai-codex gpt-6-astra maps Off to null; Pi's agent and
	// compaction call it with no thinking level.
	{ name: "no thinking level with a null Off entry sends no field", map: { off: null, minimal: "low" }, reasoning: undefined },
	{ name: "high keeps its summary", map: { off: "none" }, reasoning: "high" },
]) {
	test(`request reasoning effort matches Pi: ${row.name}`, async () => {
		const target = { ...model, thinkingLevelMap: row.map } as typeof model;
		const shim = buildRequestBody(target, normalizeContext({ messages: [], tools: [] } as never), { reasoning: row.reasoning } as never);
		assert.deepEqual(shim.reasoning, (await piRequestBody(target, row.reasoning)).reasoning);
	});
}

test("request reasoning effort matches Pi: a model without reasoning sends no field", async () => {
	const target = { ...model, reasoning: false } as typeof model;
	const shim = buildRequestBody(target, normalizeContext({ messages: [], tools: [] } as never), { reasoning: "off" } as never);
	assert.equal(shim.reasoning, undefined);
	assert.equal((await piRequestBody(target, "off")).reasoning, undefined);
});
