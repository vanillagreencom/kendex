import assert from "node:assert/strict";
import test from "node:test";
import { buildDynamicTools } from "../src/dynamic-tools.ts";

const schema = { type: "object", properties: {} };

test("Pi tool declarations become unique app-server dynamic tools", () => {
	const catalog = buildDynamicTools([
		{ name: "mcp/read", description: "Read", parameters: schema },
		{ name: "mcp read", description: "Read another", parameters: schema },
	]);
	assert.deepEqual(catalog.declarations.map((tool) => tool.name), ["mcp_read", "mcp_read_2"]);
	assert.equal(catalog.piNameByCodexName.get("mcp_read"), "mcp/read");
	assert.equal(catalog.piNameByCodexName.get("mcp_read_2"), "mcp read");
});

test("the signature changes with any declared field and holds for an equal set", () => {
	const base = [{ name: "read", description: "Read", parameters: schema }];
	const signature = buildDynamicTools(base).signature;
	assert.equal(buildDynamicTools([{ ...base[0] }]).signature, signature);
	for (const changed of [
		[{ ...base[0], description: "Read a file" }],
		[{ ...base[0], parameters: { type: "object", properties: { path: { type: "string" } } } }],
		[...base, { name: "write", description: "Write", parameters: schema }],
	]) assert.notEqual(buildDynamicTools(changed).signature, signature);
});
