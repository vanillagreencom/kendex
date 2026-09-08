import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { resolveConfiguredEffort } from "../src/index.ts";

describe("Claude bridge effort overrides", () => {
	it("resolves configured effort by model and precedence", () => {
		for (const { name, model, mapped, config, expected } of [
			{ name: "mapped Pi effort", model: "claude-opus-4-8", mapped: "xhigh", config: {}, expected: "xhigh" },
			{ name: "global override", model: "claude-opus-4-8", mapped: "xhigh", config: { forceEffort: "max" }, expected: "max" },
			{ name: "model precedes global", model: "claude-opus-4-8", mapped: "xhigh", config: { forceEffort: "high", modelEffortOverrides: { "claude-opus-4-8": "max" } }, expected: "max" },
			{ name: "provider-qualified model", model: "claude-opus-4-8", mapped: "xhigh", config: { modelEffortOverrides: { "pi-claude/claude-opus-4-8": "max" } }, expected: "max" },
			{ name: "unknown provider key", model: "claude-opus-4-8", mapped: "xhigh", config: { modelEffortOverrides: { "claude-bridge/claude-opus-4-8": "max" } }, expected: "xhigh" },
			{ name: "wildcard", model: "claude-haiku-4-5", mapped: "medium", config: { modelEffortOverrides: { "*": "low" } }, expected: "low" },
			{ name: "invalid global value", model: "claude-opus-4-8", mapped: "xhigh", config: { forceEffort: "ultracode" }, expected: "xhigh" },
			{ name: "invalid model value", model: "claude-opus-4-8", mapped: "xhigh", config: { modelEffortOverrides: { "claude-opus-4-8": "turbo" } }, expected: "xhigh" },
		]) {
			assert.equal(resolveConfiguredEffort(model, mapped, config), expected, name);
		}
	});
});
