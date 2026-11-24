import assert from "node:assert/strict";
import test from "node:test";
import { normalizeContext } from "@earendil-works/pi-ai";
import { streamSimple as piStreamSimple } from "@earendil-works/pi-ai/api/openai-codex-responses";
import { buildRequestBody } from "../src/provider-shim.js";
import { model } from "./helpers/responses.js";

const typed = { type: "object", properties: { value: { type: "string" } }, required: ["value"] };
const optional = { type: "object", properties: { value: { type: "string" }, limit: { type: "number" } }, required: ["value"] };
// OpenAI strict mode rejects a node without a type (`items: {}`, a bare const); a bare enum is typed.
const untyped = { type: "object", properties: { values: { type: "array", items: {} } }, required: ["values"] };
const enumOnly = { type: "object", properties: { mode: { enum: ["a", "b"] } }, required: ["mode"] };
for (const row of [
	{ name: "strict supported", supported: true, strict: "require", parameters: typed, sentStrict: true },
	{ name: "strict unsupported", supported: false, strict: "require", parameters: typed, code: "STRICT_SAMPLING_UNSUPPORTED" },
	{ name: "an optional property is sent required and nullable", supported: true, strict: "prefer", parameters: optional, sentStrict: true },
	{ name: "prefer with an untyped node falls back to non-strict", supported: true, strict: "prefer", parameters: untyped, sentStrict: null },
	{ name: "require with an untyped node refuses", supported: true, strict: "require", parameters: untyped, code: "STRICT_SAMPLING_UNSUPPORTED" },
	{ name: "an enum-only node stays strict", supported: true, strict: "prefer", parameters: enumOnly, sentStrict: true },
]) {
	test(`request constrained sampling: ${row.name}`, async () => {
		const target = { ...model, compat: { supportsStrictMode: row.supported } } as typeof model;
		const context = normalizeContext({ messages: [], tools: [{ name: "strict_tool", description: "Strict tool", parameters: row.parameters, constrainedSampling: { type: "json_schema", strict: row.strict } }] } as never);
		const build = () => buildRequestBody(target, context);
		if (row.code) return assert.throws(build, { code: row.code });
		const tools = build().tools;
		assert.equal((tools?.[0] as { strict: boolean | null }).strict, row.sentStrict);
		assert.deepEqual(tools, (await piRequestBody(target, undefined, context)).tools);
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
// Pi 0.82 through 0.85 hand the tool fields and name a loaded tool on the tool result.
test("Codex request body places dynamically added tools at transcript load point (Pi below 0.86)", () => {
	const loader = { name: "search_tools", description: "Search", parameters: { type: "object", properties: {} } };
	const deferred = { name: "special_tool", description: "Special", parameters: { type: "object", properties: {} } };
	const body = buildRequestBody({ ...model, compat: { supportsToolSearch: true } }, ({
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
test("Codex deferred tool loading emits each definition once (Pi below 0.86)", () => {
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
	const body = buildRequestBody({ ...model, compat: { supportsToolSearch: true } }, ({
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
async function piRequestBody(target: typeof model, reasoning: string | undefined, context = normalizeContext({ messages: [], tools: [] } as never)): Promise<Record<string, unknown>> {
	const claims = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" } })).toString("base64");
	let body: Record<string, unknown> | undefined;
	const stop = new Error("payload captured");
	const stream = piStreamSimple(target, context, {
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

// Pi 1.6.0 sends Off as effort none, mapped through the model's Off entry, with a summary.
for (const row of [
	{ name: "Off maps to the model's Off effort", map: { off: "low" }, reasoning: "off", effort: "low" },
	{ name: "Off with no Off entry sends none", map: undefined, reasoning: "off", effort: "none" },
	{ name: "no thinking level sends the Off effort", map: { off: "none" }, reasoning: undefined, effort: "none" },
	{ name: "Off level on a null Off entry clamps to minimal", map: { off: null, minimal: "low" }, reasoning: "off", effort: "low" },
	// pi-ai's openai-codex gpt-6-astra maps Off to null; Pi's agent and
	// compaction call it with no thinking level.
	{ name: "no thinking level with a null Off entry sends no field", map: { off: null, minimal: "low" }, reasoning: undefined, effort: undefined },
	{ name: "high keeps its summary", map: { off: "none" }, reasoning: "high", effort: "high" },
]) {
	test(`request reasoning effort matches Pi: ${row.name}`, async () => {
		const target = { ...model, thinkingLevelMap: row.map } as typeof model;
		const shim = buildRequestBody(target, normalizeContext({ messages: [], tools: [] } as never), { reasoning: row.reasoning } as never);
		assert.equal(shim.reasoning?.effort, row.effort);
		assert.deepEqual(shim.reasoning, (await piRequestBody(target, row.reasoning)).reasoning);
	});
}

test("request reasoning effort matches Pi: a model without reasoning sends no field", async () => {
	const target = { ...model, reasoning: false } as typeof model;
	const shim = buildRequestBody(target, normalizeContext({ messages: [], tools: [] } as never), { reasoning: "off" } as never);
	assert.equal(shim.reasoning, undefined);
	assert.equal((await piRequestBody(target, "off")).reasoning, undefined);
});

const tool = (name: string, description = `${name} tool`) => ({ name, description, parameters: { type: "object", properties: { value: { type: "string" } }, required: ["value"] } });
/** The request as it is sent: JSON drops undefined fields. */
const wire = (value: unknown) => JSON.parse(JSON.stringify(value));
const reply = (text: string, providerThinkingLevel?: string) => ({
	role: "assistant",
	content: [{ type: "text", text, textSignature: JSON.stringify({ v: 1, id: `msg_${text.replace(/\W/g, "_")}` }) }],
	api: model.api,
	provider: model.provider,
	model: model.id,
	...(providerThinkingLevel === undefined ? {} : { providerThinkingLevel }),
	usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
	stopReason: "stop",
	timestamp: 0,
});
// A transcript that adds, removes and redefines tools after the first turn.
const toolChanges = normalizeContext({
	systemPrompt: "Base prompt",
	tools: [tool("first"), tool("second")],
	messages: [
		{ role: "user", content: "one", timestamp: 1 },
		reply("done one", "low"),
		{ role: "system", content: "Later instruction", toolsAdded: [tool("third")], toolsRemoved: [{ name: "first" }], timestamp: 2 },
		{ role: "user", content: "two", timestamp: 3 },
		reply("done two", "high"),
		{ role: "system", content: "", toolsAdded: [tool("second", "second tool, redefined")], toolsRemoved: [{ name: "second" }], timestamp: 4 },
		{ role: "user", content: "three", timestamp: 5 },
	],
} as never);

for (const row of [
	{ name: "every tool in additional_tools items, removals announced", compat: { supportsMidConvoSystemMessages: true, supportsAdditionalTools: true }, reasoning: "high", has: "additional_tools" },
	{ name: "tool search loads after the last removal", compat: { supportsMidConvoSystemMessages: true, supportsToolSearch: true }, reasoning: "high", has: undefined },
	{ name: "tool changes folded into the top-level list", compat: {}, reasoning: "high", has: undefined },
	{ name: "thinking levels as configuration_update items", compat: { supportsMidConvoSystemMessages: true, supportsAdditionalTools: true, supportsMidConvoEffort: true }, reasoning: "medium", has: "configuration_update" },
	{ name: "Off as a configuration_update item", compat: { supportsMidConvoSystemMessages: true, supportsAdditionalTools: true, supportsMidConvoEffort: true }, reasoning: "off", has: "configuration_update" },
]) {
	test(`request tools, prompt and thinking level match Pi: ${row.name}`, async () => {
		const target = { ...model, compat: row.compat } as typeof model;
		const shim = buildRequestBody(target, toolChanges, { reasoning: row.reasoning } as never);
		const pi = await piRequestBody(target, row.reasoning, toolChanges);
		if (row.has) assert.ok(shim.input.some((item) => (item as { type?: string }).type === row.has), JSON.stringify(shim.input));
		assert.deepEqual(wire({ input: shim.input, tools: shim.tools, reasoning: shim.reasoning }), wire({ input: pi.input, tools: pi.tools, reasoning: pi.reasoning }));
	});
}

// Another model's thinking sent as text reads as part of the new model's reply.
test("request drops another model's thinking like Pi", async () => {
	const context = normalizeContext({
		messages: [
			{ role: "user", content: "one", timestamp: 1 },
			{ ...reply("answer"), model: "gpt-6-other", content: [{ type: "thinking", thinking: "private reasoning" }, reply("answer").content[0]] },
			{ role: "user", content: "two", timestamp: 2 },
		],
	} as never);
	const shim = buildRequestBody(model, context);
	assert.equal(JSON.stringify(shim.input).includes("private reasoning"), false);
	// A reply from another model replays without its text signature; its fallback message id is the shim's own.
	const withoutMessageIds = (input: unknown) => wire(input).map((item: { type?: string; id?: string }) => (item.type === "message" ? { ...item, id: undefined } : item));
	assert.deepEqual(withoutMessageIds(shim.input), withoutMessageIds((await piRequestBody(model, undefined, context)).input));
});

// Some providers refuse whitespace-only tool content with a 400.
test("request sends whitespace-only tool output as the empty-output placeholder", () => {
	const context = normalizeContext({
		tools: [tool("bash")],
		messages: [
			{ role: "user", content: "run", timestamp: 1 },
			{ ...reply(""), content: [{ type: "toolCall", id: "call_1|fc_1", name: "bash", arguments: { value: "true" } }], stopReason: "toolUse" },
			{ role: "toolResult", toolCallId: "call_1|fc_1", toolName: "bash", content: [{ type: "text", text: "\r\n" }], isError: false, timestamp: 2 },
		],
	} as never);
	const output = buildRequestBody(model, context).input.find((item) => (item as { type?: string }).type === "function_call_output") as { output?: unknown };
	assert.equal(output.output, "(no tool output)");
});
