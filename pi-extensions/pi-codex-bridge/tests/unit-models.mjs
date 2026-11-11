import assert from "node:assert/strict";
import test from "node:test";
import { getSupportedThinkingLevels } from "@earendil-works/pi-ai";
import { buildPiModels, codexEffort } from "../src/models.ts";

const [model] = buildPiModels([{ model: "gpt-x", displayName: "GPT X", hidden: false, inputModalities: ["text"], reasoningEfforts: ["none", "low", "medium", "high", "xhigh"] }]);
const [noNone] = buildPiModels([{ model: "gpt-y", displayName: "GPT Y", hidden: false, inputModalities: ["text", "image"], reasoningEfforts: ["low", "medium"] }]);

test("Pi offers only the levels the Codex model lists, off as none", () => {
	assert.deepEqual(getSupportedThinkingLevels(model), ["off", "low", "medium", "high", "xhigh"]);
	assert.deepEqual(getSupportedThinkingLevels(noNone), ["low", "medium"]);
	assert.deepEqual(noNone.input, ["text", "image"]);
});

for (const [name, target, level, effort] of [
	["thinking off", model, undefined, "none"],
	["a listed level", model, "high", "high"],
	["a level the model lacks, clamped up", model, "minimal", "low"],
	["max, clamped to the highest listed", model, "max", "xhigh"],
	["off on a model without none", noNone, undefined, null],
]) {
	test(`the mapped effort is sent for ${name}`, () => {
		assert.equal(codexEffort(target, level), effort);
	});
}
