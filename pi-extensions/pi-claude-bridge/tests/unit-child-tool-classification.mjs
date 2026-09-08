import { it } from "node:test";
import assert from "node:assert/strict";
import { isChildExecutedTool, isChildInternalTool, isConnectorTool } from "../src/connectors.ts";

const rows = [
	["mcp__claude_ai_Slack__slack_read_user_profile", true, false, true],
	["mcp__claude_ai_Atlassian__getConfluencePage", true, false, true],
	["mcp__claude_ai_Some_Org_Thing__whatever", true, false, true],
	["ToolSearch", true, true, false], ["ScheduleWakeup", true, true, false],
	["ListMcpResources", false, false, false], ["ReadMcpResource", false, false, false],
	["ListMcpResourcesTool", false, false, false], ["ReadMcpResourceTool", false, false, false],
	["bash", false, false, false], ["mcp__custom-tools__read", false, false, false],
	["mcp__claude_code_docs__search", false, false, false], [undefined, false, false, false],
	["ToolSearchX", false, false, false], ["mytoolsearch", false, false, false],
	["toolsearch", false, false, false], ["XToolSearch", false, false, false],
	["ToolSearch2", false, false, false], ["ToolSearchTool", false, false, false],
	["listmcpresources", false, false, false], ["ReadMcpResourceToolX", false, false, false],
];
for (const [name, executed, internal, connector] of rows) it(`classifies ${name}`, () => {
	assert.deepEqual([isChildExecutedTool(name), isChildInternalTool(name), isConnectorTool(name)], [executed, internal, connector]);
});
