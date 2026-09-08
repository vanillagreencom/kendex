import assert from "node:assert/strict";
import test from "node:test";
import { computeNextActiveTools } from "../src/capabilities.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";

for (const row of [
	{
		provider: "openai-codex", input: ["text", "image"],
		current: ["read", "grep", "find", "ls", "bash", "edit", "write", "old_custom"],
		active: ["read", "grep", "find", "ls", "bash", "edit", "write", "old_custom", "image_generation", "view_image", "apply_patch"],
		removed: [],
	},
	{
		provider: "anthropic", input: ["text"],
		current: ["read", "edit", "write", "image_generation", "view_image", "apply_patch"],
		active: ["read", "edit", "write"], removed: ["apply_patch", "image_generation", "view_image"],
	},
]) {
	test(`active tool synchronization: ${row.provider}`, () => {
		const next = computeNextActiveTools(row.current, { provider: row.provider, id: "model", input: row.input }, { ...DEFAULT_SETTINGS, viewImage: true });
		assert.deepEqual([...next.activeTools].sort(), [...row.active].sort());
		assert.deepEqual([...next.removed].sort(), [...row.removed].sort());
	});
}
