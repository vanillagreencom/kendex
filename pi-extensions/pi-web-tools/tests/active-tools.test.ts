import assert from "node:assert/strict";
import test from "node:test";
import { computeNextActiveTools, desiredWebTools } from "../src/active-tools.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";

const model = { provider: "openai-codex", id: "gpt-6-astra" };
for (const { name, current, key, included, excluded } of [
	{ name: "preserve native tools", current: ["read", "bash", "image_generation", "web_search"], key: false, included: ["read", "bash", "image_generation", "web_search"], excluded: [] },
	{ name: "no-key tools", current: undefined, key: false, included: ["web_fetch", "get_web_content"], excluded: ["web_research", "web_answer", "code_search"] },
	{ name: "advanced Exa tools", current: undefined, key: true, included: ["web_fetch", "web_research", "code_search"], excluded: [] },
]) {
	test(`active tools: ${name}`, () => {
		const settings = { ...DEFAULT_SETTINGS, apiKeys: key ? { exa: "exa-key" } : {}, warnings: [], exaAdvancedEnabled: key };
		const result = current ? computeNextActiveTools(current, model, settings) : desiredWebTools(model, settings);
		assert.deepEqual({ included: included.filter((name) => result.includes(name)), excluded: excluded.filter((name) => result.includes(name)) }, { included, excluded: [] });
	});
}
