import assert from "node:assert/strict";
import test from "node:test";
import { hasOpenAiModelsLoaded } from "../src/activation.js";

for (const row of [
	{ name: "anthropic", ctx: { model: { provider: "anthropic", id: "claude" }, modelRegistry: { getAll: () => [] } }, expected: false },
	{ name: "substring", ctx: { model: { provider: "notopenai", id: "claude" }, modelRegistry: { getAll: () => [] } }, expected: false },
	{ name: "current", ctx: { model: { provider: "openai-codex", id: "gpt-6-astra" }, modelRegistry: { getAll: () => [] } }, expected: true },
	{ name: "getAll", ctx: { modelRegistry: { getAll: () => [{ provider: "openai", id: "gpt-6-astra" }] } }, expected: true },
	{ name: "find", ctx: { modelRegistry: { find: (provider: string, id: string) => provider === "openai" && id === "gpt-5.2" ? { provider, id } : undefined } }, expected: true },
]) {
	test(`OpenAI model detection: ${row.name}`, () => assert.equal(hasOpenAiModelsLoaded(row.ctx), row.expected));
}
