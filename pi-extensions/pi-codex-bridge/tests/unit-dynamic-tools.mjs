import assert from "node:assert/strict";
import test from "node:test";
import { buildDynamicTools } from "../src/dynamic-tools.ts";

const schema = { type: "object", properties: {} };

test("Pi tool declarations become unique functions in one pi namespace, and no tools declare none", () => {
	const catalog = buildDynamicTools([
		{ name: "mcp/read", description: "Read", parameters: schema },
		{ name: "mcp read", description: "Read another", parameters: schema },
	]);
	assert.equal(catalog.declarations.length, 1);
	const [namespace] = catalog.declarations;
	assert.equal(namespace.type, "namespace");
	assert.equal(namespace.name, "pi");
	assert.deepEqual(namespace.tools.map((tool) => [tool.type, tool.name]), [["function", "mcp_read"], ["function", "mcp_read_2"]]);
	assert.equal(catalog.piNameByCodexName.get("mcp_read"), "mcp/read");
	assert.equal(catalog.piNameByCodexName.get("mcp_read_2"), "mcp read");
	assert.deepEqual(buildDynamicTools([]).declarations, []);
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
