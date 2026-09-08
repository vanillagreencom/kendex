import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { createApplyPatchToolDefinition, executeApplyPatchTool } from "../src/tools/apply-patch.js";
import { world } from "./helpers/world.js";

test("registered apply_patch returns text and file details without a custom renderer", async (t) => {
	const { cwd } = world(t);
	const tool = createApplyPatchToolDefinition({ cwd, deferRendering: true });
	const execute = tool.execute as (id: string, params: { input: string }, signal: undefined, update: undefined, ctx: { cwd: string }) => ReturnType<typeof executeApplyPatchTool>;
	assert.equal(typeof execute, "function");
	const result = await execute("patch-1", { input: "*** Begin Patch\n*** Add File: hello.txt\n+hello\n*** End Patch" }, undefined, undefined, { cwd });
	assert.equal(result.content[0]?.type, "text");
	assert.ok(result.content[0]?.text.length > 0);
	assert.deepEqual(result.details.files.map(({ kind, path }) => ({ kind, path })), [{ kind: "add", path: "hello.txt" }]);
	assert.equal(readFileSync(join(cwd, "hello.txt"), "utf8"), "hello");
});
