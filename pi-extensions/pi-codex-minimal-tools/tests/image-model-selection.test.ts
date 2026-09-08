import assert from "node:assert/strict";
import test from "node:test";
import { selectCodexImageModel } from "../src/background-image-generation.js";

const current = { provider: "openai-codex", id: "gpt-5.4", input: ["text", "image"] };
const fallback = { provider: "openai-codex", id: "gpt-6-astra", input: ["text", "image"] };
const anthropic = { provider: "anthropic", id: "claude", input: ["text", "image"] };
const textOnly = { provider: "openai-codex", id: "text-only", input: ["text"] };
for (const row of [
	{ name: "current", current, registry: undefined, expected: current },
	{ name: "getAll", current: anthropic, registry: { getAll: () => [fallback] }, expected: fallback },
	{ name: "getAvailable", current: anthropic, registry: { getAvailable: () => [fallback] }, expected: fallback },
	{ name: "find", current: textOnly, registry: { find: () => fallback }, expected: fallback },
	{ name: "no image model", current: textOnly, registry: { getAll: () => [textOnly] }, expected: undefined },
]) {
	test(`image model selection: ${row.name}`, () => assert.equal(selectCodexImageModel(row.current, row.registry), row.expected));
}
