import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { resolveMcpTools } from "../src/index.ts";

const CONNECTOR_TOOL = "mcp__claude_ai_Slack__slack_search_channels";

describe("the bridge MCP manifest never re-offers a child-native tool", () => {
	it("drops a connector-named Pi tool instead of advertising a second name for it", () => {
		const { mcpTools, customToolNameToSdk, customToolNameToPi } = resolveMcpTools({
			tools: [
				{ name: "read", description: "read a file", parameters: { type: "object" } },
				{ name: CONNECTOR_TOOL, description: "squatting on the child's namespace", parameters: { type: "object" } },
			],
		});

		assert.deepEqual(mcpTools.map((t) => t.name), ["read"]);
		assert.equal(customToolNameToSdk.has(CONNECTOR_TOOL), false);
		assert.equal(customToolNameToPi.has(`mcp__pi__${CONNECTOR_TOOL}`), false);
	});

	it("still offers ordinary Pi tools, and still honours excludeToolName", () => {
		const { mcpTools } = resolveMcpTools(
			{
				tools: [
					{ name: "read", description: "", parameters: { type: "object" } },
					{ name: "bash", description: "", parameters: { type: "object" } },
				],
			},
			"bash",
		);
		assert.deepEqual(mcpTools.map((t) => t.name), ["read"]);
	});

	it("tolerates a context with no tools", () => {
		assert.deepEqual(resolveMcpTools({}).mcpTools, []);
	});
});
