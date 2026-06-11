/**
 * Tests for MODELS construction + resolveModelId.
 * Pins: opus shortcut resolves to whichever opus is first in MODEL_IDS_IN_ORDER,
 * projection strips pi-ai's baseUrl/api/provider/headers, and ordering is preserved.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { FABLE_FALLBACK_MODEL_ID, FABLE_MODEL_ID, MODEL_IDS_IN_ORDER, buildModels, fallbackModelForPrimaryModel, resolveModelId } from "../src/models.js";

// Simulated pi-ai registry entry — extra fields mimic the ones pi-ai exposes
// that must not leak into the provider-registered MODELS array.
const mockPiAiModel = (id) => ({
	id, name: id, reasoning: true, input: ["text"], cost: { input: 1, output: 1 },
	contextWindow: 200000, maxTokens: 8000,
	thinkingLevelMap: { xhigh: id === "claude-opus-4-8" ? "xhigh" : "max" },
	// Leaky fields that should be stripped by the projection:
	baseUrl: "https://api.anthropic.com", api: "anthropic", provider: "anthropic",
	headers: { "x-api-key": "LEAK" },
});

describe("MODELS projection", () => {
	it("strips baseUrl/api/provider/headers", () => {
		const models = buildModels(MODEL_IDS_IN_ORDER.map(mockPiAiModel));
		for (const m of models) {
			assert.equal(m.baseUrl, undefined);
			assert.equal(m.api, undefined);
			assert.equal(m.provider, undefined);
			assert.equal(m.headers, undefined);
		}
	});

	it("preserves MODEL_IDS_IN_ORDER ordering", () => {
		const models = buildModels(MODEL_IDS_IN_ORDER.map(mockPiAiModel));
		assert.deepEqual(models.map((m) => m.id), MODEL_IDS_IN_ORDER);
	});

	it("lists Fable 5 before Opus models", () => {
		const models = buildModels(MODEL_IDS_IN_ORDER.map(mockPiAiModel));
		assert.equal(models[0]?.id, FABLE_MODEL_ID);
		assert.equal(models[1]?.id, FABLE_FALLBACK_MODEL_ID);
	});

	it("fills bridge-owned future IDs missing from pi-ai and drops unknown missing IDs", () => {
		const models = buildModels([mockPiAiModel("claude-haiku-4-5")]);
		assert.deepEqual(models.map((m) => m.id), ["claude-fable-5", "claude-opus-4-8", "claude-haiku-4-5"]);
		assert.equal(models.find((m) => m.id === "claude-fable-5")?.name, "Claude Fable 5");
		assert.equal(models.find((m) => m.id === "claude-fable-5")?.contextWindow, 1000000);
		assert.equal(models.find((m) => m.id === "claude-opus-4-8")?.maxTokens, 128000);
	});

	it("prefers pi-ai metadata over bridge fallback metadata", () => {
		const models = buildModels([{
			...mockPiAiModel("claude-fable-5"),
			name: "Registry Fable",
			contextWindow: 123,
			maxTokens: 456,
			thinkingLevelMap: { xhigh: "max" },
		}]);
		const fable = models.find((m) => m.id === "claude-fable-5");
		assert.equal(fable?.name, "Registry Fable");
		assert.equal(fable?.contextWindow, 123);
		assert.equal(fable?.maxTokens, 456);
		assert.deepEqual(fable?.thinkingLevelMap, { xhigh: "max" });
	});

	it("zeros out cost regardless of pi-ai pricing", () => {
		const models = buildModels(MODEL_IDS_IN_ORDER.map(mockPiAiModel));
		for (const m of models) {
			assert.deepEqual(m.cost, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
		}
	});

	it("preserves pi-ai thinkingLevelMap for per-model effort mapping", () => {
		const models = buildModels(MODEL_IDS_IN_ORDER.map(mockPiAiModel));
		assert.deepEqual(models.find((m) => m.id === "claude-opus-4-8")?.thinkingLevelMap, { xhigh: "xhigh" });
	});
});

describe("resolveModelId", () => {
	const models = buildModels(MODEL_IDS_IN_ORDER.map(mockPiAiModel));

	it("opus shortcut resolves to claude-opus-4-8 (first opus in order)", () => {
		assert.equal(resolveModelId(models, "opus"), "claude-opus-4-8");
	});

	it("fable shortcut resolves to claude-fable-5", () => {
		assert.equal(resolveModelId(models, "fable"), "claude-fable-5");
	});

	it("haiku shortcut resolves to claude-haiku-4-5", () => {
		assert.equal(resolveModelId(models, "haiku"), "claude-haiku-4-5");
	});

	it("full ID passes through unchanged", () => {
		assert.equal(resolveModelId(models, "claude-opus-4-6"), "claude-opus-4-6");
	});

	it("falls through to input when no match", () => {
		assert.equal(resolveModelId(models, "gpt-9"), "gpt-9");
	});

	it("configures Opus 4.8 availability fallback for Fable 5 only", () => {
		assert.equal(fallbackModelForPrimaryModel(FABLE_MODEL_ID), FABLE_FALLBACK_MODEL_ID);
		assert.equal(fallbackModelForPrimaryModel(FABLE_FALLBACK_MODEL_ID), undefined);
		assert.equal(fallbackModelForPrimaryModel("claude-sonnet-4-6"), undefined);
	});
});
