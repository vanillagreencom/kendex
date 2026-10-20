import assert from "node:assert/strict";
import test from "node:test";
import { buildDynamicTools } from "../src/dynamic-tools.ts";

const schema = { type: "object", properties: {} };

test("Pi tool declarations become unique functions in one pi namespace, and no tools declare none", () => {
	const catalog = buildDynamicTools([{ name: "read", description: "Read", parameters: schema }]);
	assert.equal(catalog.declarations.length, 1);
	const [namespace] = catalog.declarations;
	assert.equal(namespace.type, "namespace");
	assert.equal(namespace.name, "pi");
	assert.deepEqual(namespace.tools.map((tool) => tool.type), ["function"]);
	assert.deepEqual(buildDynamicTools([]).declarations, []);
});

// Pi names, in declaration order, and the Codex name each must get. Codex
// 0.163.0 refuses `mcp` and `mcp__*`.
const longReserved = `mcp__${"x".repeat(70)}`;
for (const row of [
	{ name: "sanitized names stay unique", pi: ["mcp/read", "mcp read"], codex: ["mcp_read", "mcp_read_2"] },
	{ name: "reserved names are escaped", pi: ["mcp", "mcp__srv__tool"], codex: ["pi_mcp", "pi_mcp__srv__tool"] },
	{ name: "an escaped name taken by another tool is suffixed", pi: ["pi_mcp", "mcp"], codex: ["pi_mcp", "mcp_2"] },
	{ name: "a suffix that forms a reserved name is escaped", pi: ["mcp_", "mcp/"], codex: ["mcp_", "pi_mcp__2"] },
	{ name: "a long reserved name is escaped within the length limit", pi: [longReserved], codex: [`pi_mcp__${"x".repeat(56)}`] },
]) {
	test(`Pi tool names map to Codex names: ${row.name}`, () => {
		const catalog = buildDynamicTools(row.pi.map((name) => ({ name, description: name, parameters: schema })));
		assert.deepEqual(catalog.declarations[0].tools.map((tool) => tool.name), row.codex);
		assert.deepEqual(row.codex.map((name) => catalog.piNameByCodexName.get(name)), row.pi);
	});
}

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
