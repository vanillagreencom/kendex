import { expect, test } from "bun:test";
import { resolvePolicyMode, isSanitizeExceptTool } from "../extensions/output-policy.ts";
import { withConfig } from "./fixtures.ts";

test("policy mode selection", () => {
	for (const [config, expected] of [
		[{}, "balanced"], [{ policyMode: "compact" }, "compact"],
		[{ policyMode: "compat" }, "compat"], [{ policyMode: "ludicrous" }, "balanced"],
	] as const) {
		withConfig(config, (cwd) => { expect(resolvePolicyMode(cwd)).toBe(expected); });
	}
});

test("detail exemption selection", () => {
	for (const [config, tool, expected] of [
		[{}, "tasks_write", true], [{}, "bg_task", true], [{}, "subagent", true],
		[{}, "grep", false], [{}, "ext.tasks_write", true],
		[{ "sanitizeDetails.exceptTools": "my_state_tool,other" }, "my_state_tool", true],
		[{ "sanitizeDetails.exceptTools": "my_state_tool,other" }, "tasks_write", false],
	] as const) {
		withConfig(config, (cwd) => { expect(isSanitizeExceptTool(tool, cwd)).toBe(expected); });
	}
});
