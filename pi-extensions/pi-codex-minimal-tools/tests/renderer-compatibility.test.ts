import assert from "node:assert/strict";
import test from "node:test";
import { createApplyPatchToolDefinition } from "../src/tools/apply-patch.js";

test("apply_patch definition is compatible with pi-tool-renderer assumptions", () => {
	const tool = createApplyPatchToolDefinition({ deferRendering: true }) as Record<string, any>;
	assert.equal(tool.name, "apply_patch");
	assert.ok(tool.parameters.properties.input);
	assert.deepEqual(tool.parameters.required, ["input"]);
	assert.equal(tool.renderShell, "self");
	assert.equal("renderCall" in tool, false);
	assert.equal("renderResult" in tool, false);
});
