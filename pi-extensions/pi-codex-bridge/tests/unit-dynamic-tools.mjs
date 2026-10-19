import assert from "node:assert/strict";
import test from "node:test";
import { buildDynamicTools } from "../src/dynamic-tools.ts";

test("Pi 0.86 tool declarations become unique app-server dynamic tools", () => {
	const catalog = buildDynamicTools([
		{ name: "mcp/read", description: "Read", parameters: { type: "object", properties: {} } },
		{ name: "mcp read", description: "Read another", parameters: { type: "object", properties: {} } },
	]);
	assert.deepEqual(catalog.declarations.map((tool) => tool.name), ["mcp_read", "mcp_read_2"]);
	assert.equal(catalog.piNameByCodexName.get("mcp_read"), "mcp/read");
	assert.equal(catalog.piNameByCodexName.get("mcp_read_2"), "mcp read");
	assert.match(catalog.signature, /mcp_read_2/);
});
