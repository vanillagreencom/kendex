import assert from "node:assert/strict";
import test from "node:test";
import { normalizeContext } from "@earendil-works/pi-ai";
import { buildRequestBody } from "../src/provider-shim.js";
import { model } from "./helpers/responses.js";
import { rejectsMutation } from "./helpers/mutation.js";
import { completedEvent, providerWorld, runCodexProvider, sseResponse } from "./helpers/provider.js";

for (const row of [
	{ id: "registry-only-successor", map: { minimal: "low" }, level: "minimal", expected: "low" },
	{ id: "gpt-5.1", map: { xhigh: "xhigh" }, level: "xhigh", expected: "xhigh" },
	{ id: "gpt-5.1-codex-mini", map: { high: "low" }, level: "high", expected: "low" },
]) {
	test(`reasoning uses model properties: ${row.id}`, () => {
		const target = { ...model, id: row.id, thinkingLevelMap: row.map };
		const body = buildRequestBody(target, normalizeContext({ messages: [], tools: [] }), { reasoning: row.level } as never);
		assert.equal(body.reasoning?.effort, row.expected);
	});
}

test("reasoning property assertion rejects an ignored mapping", (t) => {
	rejectsMutation(t, "src/provider-shim.ts", "effort,\n\t\tsummary:", 'effort: "high",\n\t\tsummary:', "tests/model-properties.test.ts", "^reasoning uses model properties:");
});

for (const row of [
	{ id: "registry-only-successor", tier: "priority", input: 6, output: 20 },
	{ id: "gpt-6-astra", tier: "priority", input: 6, output: 20 },
	{ id: "registry-only-successor", tier: "flex", input: 1.5, output: 5 },
	{ id: "registry-only-successor", tier: "default", input: 3, output: 10 },
]) {
	test(`service tier pricing: ${row.tier}/${row.id}`, async (t) => {
		providerWorld(t);
		const event = { ...completedEvent, response: { ...completedEvent.response, service_tier: row.tier, usage: { input_tokens: 1_000_000, output_tokens: 2_000_000, total_tokens: 3_000_000, input_tokens_details: { cached_tokens: 0 } } } };
		globalThis.fetch = async () => sseResponse(`data: ${JSON.stringify(event)}\n\n`);
		const result = await runCodexProvider({ serviceTier: row.tier }, { id: row.id, cost: { input: 3, output: 5, cacheRead: 1, cacheWrite: 1 } });
		assert.equal(result.stopReason, "stop");
		assert.deepEqual(result.usage.cost, { input: row.input, output: row.output, cacheRead: 0, cacheWrite: 0, total: row.input + row.output });
	});
}

test("service tier pricing rejects the removed per-model multiplier", (t) => {
	rejectsMutation(t, "src/provider-shim.ts", "return 2;", "return 2.5;", "tests/model-properties.test.ts", "^service tier pricing: priority/");
});
