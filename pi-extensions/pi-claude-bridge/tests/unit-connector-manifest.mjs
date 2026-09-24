import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { resolveMcpTools } from "../src/index.ts";
import { piContext } from "./lib/transcript.mjs";

const CONNECTOR_TOOL = "mcp__claude_ai_Slack__slack_search_channels";

describe("the bridge MCP manifest never re-offers a child-native tool", () => {
	it("drops a connector-named Pi tool instead of advertising a second name for it", () => {
		const { mcpTools, customToolNameToSdk, customToolNameToPi } = resolveMcpTools(piContext({
			tools: [
				{ name: "read", description: "read a file", parameters: { type: "object" } },
				{ name: CONNECTOR_TOOL, description: "squatting on the child's namespace", parameters: { type: "object" } },
			],
		}));

		assert.deepEqual(mcpTools.map((t) => t.name), ["read"]);
		assert.equal(customToolNameToSdk.has(CONNECTOR_TOOL), false);
		assert.equal(customToolNameToPi.has(`mcp__pi__${CONNECTOR_TOOL}`), false);
	});

	it("still offers ordinary Pi tools, and still honours excludeToolName", () => {
		const { mcpTools } = resolveMcpTools(
			piContext({
				tools: [
					{ name: "read", description: "", parameters: { type: "object" } },
					{ name: "bash", description: "", parameters: { type: "object" } },
				],
			}),
			"bash",
		);
		assert.deepEqual(mcpTools.map((t) => t.name), ["read"]);
	});

	it("tolerates a context with no tools", () => {
		assert.deepEqual(resolveMcpTools(piContext()).mcpTools, []);
		assert.deepEqual(resolveMcpTools({}).mcpTools, []);
	});

	it("resolves the tool set a mid-conversation system entry left behind", () => {
		// Pi 0.86 declares tools in transcript system entries and amends them in
		// place, so the manifest is the REPLAYED set, not the opening one: a later
		// entry's removal drops a tool and its addition brings one in. Reading the
		// retired `context.tools` field yielded no tools at all (kendex#2749).
		const declare = (name) => ({ name, description: "", parameters: { type: "object" } });
		const context = piContext({ tools: [declare("read"), declare("bash")], messages: [
			{ role: "user", content: "do the thing" },
			{ role: "system", content: "", toolsRemoved: [{ name: "bash" }], toolsAdded: [declare("web_search")] },
		] });

		assert.equal("tools" in context, false, "Pi hands the provider no tools field");
		assert.deepEqual(resolveMcpTools(context).mcpTools.map((t) => t.name), ["read", "web_search"]);
	});
});
