import assert from "node:assert/strict";
import test from "node:test";
import { buildRequestBody } from "../src/provider-shim.js";
import { model } from "./helpers/responses.js";

for (const row of [
	{ name: "strict supported", strict: true, supported: true, code: undefined },
	{ name: "strict unsupported", strict: true, supported: false, code: "STRICT_SAMPLING_UNSUPPORTED" },
]) {
	test(`request constrained sampling: ${row.name}`, () => {
		const build = () => buildRequestBody({ ...model, compat: { supportsStrictMode: row.supported } } as never, { messages: [], tools: [{ name: "strict_tool", description: "Strict tool", parameters: { type: "object", properties: { value: { type: "string" } }, required: ["value"] }, constrainedSampling: { type: "json_schema", strict: "require" } }] } as never);
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
		const build = () => buildRequestBody({ ...model, compat: { supportsOpenAIGrammarTools: row.supported } } as never, { messages: [], tools: [{ name: "sql", description: "Generate SQL", parameters, constrainedSampling: { type: "grammar", variants: { [row.variant]: row.definition } } }] } as never);
		if (row.malformed) assert.throws(build, { code: "GRAMMAR_SCHEMA", tool: "sql" });
		else if (row.supported) assert.deepEqual(build().tools?.[0], { type: "custom", name: "sql", description: "Generate SQL", format: { type: "grammar", syntax: row.syntax, definition: row.definition } });
		else assert.equal((build().tools?.[0] as { type: string }).type, "function");
	});
}

test("Codex request body forwards required tool choice", () => {
	const body = buildRequestBody(model, { messages: [], tools: [] } as any, { toolChoice: "required" } as any);
	assert.equal(body.tool_choice, "required");
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
