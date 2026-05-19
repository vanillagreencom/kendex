import assert from "node:assert/strict";
import test from "node:test";
import { computeNextActiveTools, computeToolCapabilities } from "../src/capabilities.js";
import { DEFAULT_SETTINGS } from "../src/settings.js";

const codex55 = { provider: "openai-codex", id: "gpt-5.5", input: ["text", "image"] };
const textOnlyCodex = { provider: "openai-codex", id: "text-only-codex", input: ["text"] };
const openai = { provider: "openai", id: "gpt-5.5", input: ["text", "image"] };

test("capability gating follows provider and image support", () => {
	const withViewImage = { ...DEFAULT_SETTINGS, viewImage: true };

	const codex = computeToolCapabilities(codex55, withViewImage);
	assert.equal(codex.image_generation.enabled, true);
	assert.equal(codex.view_image.enabled, true);
	assert.equal(codex.apply_patch.enabled, true);

	const textOnlyCodexCaps = computeToolCapabilities(textOnlyCodex, withViewImage);
	assert.equal(textOnlyCodexCaps.image_generation.enabled, false);
	assert.equal(textOnlyCodexCaps.view_image.enabled, false);
	assert.equal(textOnlyCodexCaps.apply_patch.enabled, true);

	const openaiCaps = computeToolCapabilities(openai, withViewImage);
	assert.equal(openaiCaps.image_generation.enabled, false);
	assert.equal(openaiCaps.view_image.enabled, true);
	assert.equal(openaiCaps.apply_patch.enabled, true);

	const nonOpenAiVision = computeToolCapabilities({ provider: "claude-bridge", id: "claude-opus-4-7", input: ["text", "image"] }, withViewImage);
	assert.equal(nonOpenAiVision.image_generation.enabled, false);
	assert.equal(nonOpenAiVision.view_image.enabled, false);
	assert.equal(nonOpenAiVision.apply_patch.enabled, false);

	const defaults = computeToolCapabilities(codex55, DEFAULT_SETTINGS);
	assert.equal(defaults.view_image.enabled, false, "view_image is gated off by default");
});

test("active tool sync preserves native tools and only manages package tools", () => {
	const current = ["read", "grep", "find", "ls", "bash", "edit", "write", "old_custom"];
	const next = computeNextActiveTools(current, codex55, { ...DEFAULT_SETTINGS, viewImage: true });
	for (const nativeTool of ["read", "grep", "find", "ls", "bash", "edit", "write"]) assert.ok(next.activeTools.includes(nativeTool));
	assert.ok(next.activeTools.includes("old_custom"));
	assert.ok(next.activeTools.includes("image_generation"));
	assert.ok(next.activeTools.includes("view_image"));
	assert.ok(next.activeTools.includes("apply_patch"));
});

test("unsupported package tools are removed without touching native tools", () => {
	const current = ["read", "edit", "write", "image_generation", "view_image", "apply_patch"];
	const next = computeNextActiveTools(current, { provider: "anthropic", id: "claude", input: ["text"] }, { ...DEFAULT_SETTINGS, viewImage: true });
	assert.deepEqual(next.activeTools, ["read", "edit", "write"]);
	assert.deepEqual(next.removed.sort(), ["apply_patch", "image_generation", "view_image"].sort());
});
