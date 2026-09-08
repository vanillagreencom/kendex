import { it } from "node:test";
import assert from "node:assert/strict";
import { mapToolName } from "../src/index.ts";

const names = new Map([["mcp__custom-tools__grep", "grep"], ["mcp__custom-tools__cameltool", "CamelTool"]]);
const mapping = [
	["Read", undefined, "read"],
	["mcp__custom-tools__grep", names, "grep"],
	["mcp__custom-tools__Grep", names, "grep"],
	["mcp__custom_tools__grep", undefined, "grep"],
	["mcp/custom-tools/grep", undefined, "grep"],
	["mcp/custom_tools/grep", undefined, "grep"],
	["mcp__custom_tools__CamelTool", names, "CamelTool"],
];
for (const [name, manifest, expected] of mapping) it(`maps ${name}`, () => { assert.equal(mapToolName(name, manifest), expected); });
