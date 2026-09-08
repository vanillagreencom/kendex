import { test } from "node:test";
import assert from "node:assert/strict";
import { connectorBuiltinAllowlistHook, CONNECTOR_DISCOVERY_TOOLS } from "../bundle/index.js";

// The SDK delivers canonical discovery aliases as well as request spellings.
test("connector session allowlist permits its tools and denies unrelated or unreadable input", async () => {
	const hook = connectorBuiltinAllowlistHook();
	const rows = [
		["mcp__custom-tools__read", true],
		["mcp__custom-tools__anything_else", true],
		["mcp__claude_ai_Gmail__search_threads", true],
		["mcp__claude_ai_Some_Org_Thing__whatever", true],
		...CONNECTOR_DISCOVERY_TOOLS.map((name) => [name, true]),
		["ToolSearch", true],
		["ListMcpResources", true],
		["ListMcpResourcesTool", true],
		["ReadMcpResource", true],
		["ReadMcpResourceTool", true],
		["ReadMcpResourceToolX", false],
		["XListMcpResourcesTool", false],
		["ToolSearchTool", false],
		["readmcpresourcetool", false],
		["ListMcpResourcesToo", false],
		["McpResourceTool", false],
		["Bash", false],
		["SlashCommand", false],
		["SomeFutureBuiltin2027", false],
		["mcp__some_other_server__do_thing", false],
		[42, false],
	];
	const inputs = rows.map(([name, allowed]) => [String(name), { hook_event_name: "PreToolUse", tool_name: name, tool_input: {}, tool_use_id: "t1" }, allowed]);
	inputs.push(["throwing input", new Proxy({}, {
		get(_target, prop) {
			if (prop === "hook_event_name") return "PreToolUse";
			throw new Error("hostile input");
		},
	}), false]);
	for (const [name, input, allowed] of inputs) {
		const out = await hook(input, "t1", { signal: new AbortController().signal });
		assert.deepEqual({ continue: out.continue, decision: out.hookSpecificOutput?.permissionDecision },
			allowed ? { continue: true, decision: undefined } : { continue: undefined, decision: "deny" }, name);
	}
});
