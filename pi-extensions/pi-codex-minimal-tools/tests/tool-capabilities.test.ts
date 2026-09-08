import assert from "node:assert/strict";
import test from "node:test";
import { computeToolCapabilities } from "../src/capabilities.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";

for (const row of [
	{ provider: "openai-codex", input: ["text", "image"], viewImage: true, enabled: [true, true, true] },
	{ provider: "openai-codex", input: ["text"], viewImage: true, enabled: [false, false, true] },
	{ provider: "openai", input: ["text", "image"], viewImage: true, enabled: [false, true, true] },
	{ provider: "claude-bridge", input: ["text", "image"], viewImage: true, enabled: [false, false, false] },
	{ provider: "openai-codex", input: ["text", "image"], viewImage: false, enabled: [true, false, true] },
]) {
	test(`capabilities: ${row.provider}/${row.input.join("+")}/view=${row.viewImage}`, () => {
		const caps = computeToolCapabilities({ provider: row.provider, id: "model", input: row.input }, { ...DEFAULT_SETTINGS, viewImage: row.viewImage });
		assert.deepEqual([caps.image_generation.enabled, caps.view_image.enabled, caps.apply_patch.enabled], row.enabled);
	});
}
