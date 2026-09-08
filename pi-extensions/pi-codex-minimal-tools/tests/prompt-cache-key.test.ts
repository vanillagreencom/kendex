import assert from "node:assert/strict";
import test from "node:test";
import { clampOpenAIPromptCacheKey } from "../src/provider-shim.js";

test("Codex prompt cache keys clamp to 64 Unicode characters", () => {
	const key = `${"a".repeat(63)}😀suffix`;
	const clamped = clampOpenAIPromptCacheKey(key);
	assert.equal(Array.from(clamped ?? "").length, 64);
	assert.equal(clamped, `${"a".repeat(63)}😀`);
});
