// A claude.ai connector tool is executed INSIDE the claude child. Mirroring one
// into the Pi stream made Pi's agent loop dispatch a tool it does not have and
// write `Tool <name> not found` into the transcript for a call that succeeded
// (drovr#311 / memsira#320). These tests pin the three emission paths that used
// to do it, plus the observation half.
import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { noteChildExecutedToolResults, processAssistantMessage, processStreamEvent } from "../src/index.ts";
import { isChildExecutedTool } from "../src/connectors.ts";
import { ctx, resetStack } from "../src/query-state.ts";

const model = {
	api: "claude-bridge",
	provider: "claude-bridge",
	id: "claude-haiku-4-5",
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
};

const CONNECTOR_TOOL = "mcp__claude_ai_Slack__slack_read_user_profile";

function installFakeStream() {
	const events = [];
	ctx().currentPiStream = {
		push(event) { events.push(event); },
		end(result) { events.push({ type: "stream_end", result }); },
	};
	return events;
}

function streamEvent(event) {
	return { type: "stream_event", event };
}

describe("child-executed tool classification", () => {
	it("claims every claude.ai connector namespace", () => {
		assert.equal(isChildExecutedTool(CONNECTOR_TOOL), true);
		assert.equal(isChildExecutedTool("mcp__claude_ai_Atlassian__getConfluencePage"), true);
		// Namespace-only, so an org-custom connector nobody has enumerated still counts.
		assert.equal(isChildExecutedTool("mcp__claude_ai_Some_Org_Thing__whatever"), true);
	});

	it("claims nothing else — a Pi tool mismatch must still surface as a dispatcher error", () => {
		assert.equal(isChildExecutedTool("bash"), false);
		assert.equal(isChildExecutedTool("mcp__custom-tools__read"), false);
		// A different MCP server is not a claude.ai connector.
		assert.equal(isChildExecutedTool("mcp__claude_code_docs__search"), false);
		assert.equal(isChildExecutedTool(undefined), false);
	});
});

describe("child-executed tools are never mirrored as Pi tool calls", () => {
	beforeEach(() => resetStack());

	it("skips a streamed connector tool_use and leaves the turn open", () => {
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();

		processStreamEvent(streamEvent({
			type: "content_block_start",
			index: 0,
			content_block: { type: "tool_use", id: "toolu_conn", name: CONNECTOR_TOOL, input: {} },
		}), new Map(), model);
		processStreamEvent(streamEvent({
			type: "content_block_delta",
			index: 0,
			delta: { type: "input_json_delta", partial_json: "{\"user_id\":\"U1\"}" },
		}), new Map(), model);
		processStreamEvent(streamEvent({ type: "content_block_stop", index: 0 }), new Map(), model);

		assert.equal(c.turnBlocks.length, 0, "connector call must not become a Pi content block");
		assert.equal(c.turnSawToolCall, false, "connector call is not a Pi turn boundary");
		assert.deepEqual(c.turnToolCallIds, [], "Pi owes no result, so nothing is expected back");
		assert.equal(c.currentPiStream !== null, true, "the Pi turn must stay open");
		assert.deepEqual(events.map((e) => e.type), ["start"]);
		assert.equal(c.childExecutedToolCalls.get("toolu_conn"), CONNECTOR_TOOL);
	});

	it("does not end the turn on a message_stop that only saw a connector call", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();

		processStreamEvent(streamEvent({
			type: "content_block_start",
			index: 0,
			content_block: { type: "tool_use", id: "toolu_conn", name: CONNECTOR_TOOL, input: {} },
		}), new Map(), model);
		processStreamEvent(streamEvent({ type: "message_stop" }), new Map(), model);

		assert.equal(c.currentPiStream !== null, true, "ending here would strand the answer text");
	});

	it("keeps streaming the answer text into the same Pi message after the connector call", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();

		processStreamEvent(streamEvent({
			type: "content_block_start",
			index: 0,
			content_block: { type: "tool_use", id: "toolu_conn", name: CONNECTOR_TOOL, input: {} },
		}), new Map(), model);
		processStreamEvent(streamEvent({ type: "content_block_stop", index: 0 }), new Map(), model);
		// The child's follow-up assistant message reuses index 0 for its text block.
		processStreamEvent(streamEvent({ type: "message_start", message: { model: "claude-haiku-4-5" } }), new Map(), model);
		processStreamEvent(streamEvent({
			type: "content_block_start",
			index: 0,
			content_block: { type: "text", text: "" },
		}), new Map(), model);
		processStreamEvent(streamEvent({
			type: "content_block_delta",
			index: 0,
			delta: { type: "text_delta", text: "Brad Mahaffey" },
		}), new Map(), model);
		processStreamEvent(streamEvent({ type: "content_block_stop", index: 0 }), new Map(), model);

		assert.equal(c.turnBlocks.length, 1);
		assert.equal(c.turnBlocks[0].type, "text");
		assert.equal(c.turnBlocks[0].text, "Brad Mahaffey", "a stale skip-index must not swallow real text");
	});

	it("skips a connector tool_use on the assistant-boundary path without ending the turn", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();
		c.turnSawStreamEvent = true;

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [{ type: "tool_use", id: "toolu_conn", name: CONNECTOR_TOOL, input: { user_id: "U1" } }],
			},
		}, model, new Map());

		assert.equal(c.turnBlocks.length, 0);
		assert.equal(c.turnSawToolCall, false);
		assert.equal(c.currentPiStream !== null, true, "no Pi tool call means no turn boundary");
		assert.equal(c.childExecutedToolCalls.get("toolu_conn"), CONNECTOR_TOOL);
	});

	it("skips a connector tool_use on the no-stream-events fallback path", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [
					{ type: "text", text: "checking" },
					{ type: "tool_use", id: "toolu_conn", name: CONNECTOR_TOOL, input: { user_id: "U1" } },
				],
			},
		}, model, new Map());

		assert.deepEqual(c.turnBlocks.map((b) => b.type), ["text"]);
		assert.equal(c.turnSawToolCall, false);
		assert.equal(c.currentPiStream !== null, true);
	});

	it("still mirrors a Pi tool call alongside a connector call in the same message", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();
		c.turnSawStreamEvent = true;

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [
					{ type: "tool_use", id: "toolu_conn", name: CONNECTOR_TOOL, input: {} },
					{ type: "tool_use", id: "toolu_pi", name: "mcp__custom-tools__read", input: { file_path: "README.md" } },
				],
			},
		}, model, new Map([["mcp__custom-tools__read", "read"]]));

		assert.equal(c.turnBlocks.length, 1, "only the Pi tool call is mirrored");
		assert.equal(c.turnBlocks[0].name, "read");
		assert.deepEqual(c.turnToolCallIds, ["toolu_pi"]);
		assert.equal(c.currentPiStream, null, "a real Pi tool call still ends the turn");
	});
});

describe("child-executed tool results", () => {
	beforeEach(() => resetStack());

	it("recognizes the child's own result without re-delivering it", () => {
		const c = ctx();
		c.resetTurnState(model);
		c.noteChildExecutedToolCall("toolu_conn", CONNECTOR_TOOL, 0);

		noteChildExecutedToolResults({
			type: "user",
			message: {
				content: [{ type: "tool_result", tool_use_id: "toolu_conn", content: "User ID: US9TAA048" }],
			},
		});

		// Observation only: nothing is queued for Pi, and no Pi block appears.
		assert.equal(c.pendingResults.size, 0);
		assert.equal(c.turnBlocks.length, 0);
	});

	it("ignores a tool_result for a call the child did not own", () => {
		const c = ctx();
		c.resetTurnState(model);
		c.noteChildExecutedToolCall("toolu_conn", CONNECTOR_TOOL, 0);

		noteChildExecutedToolResults({
			type: "user",
			message: { content: [{ type: "tool_result", tool_use_id: "toolu_other", content: "x" }] },
		});

		assert.equal(c.pendingResults.size, 0);
	});

	it("tolerates a plain user echo with no tool results", () => {
		ctx().resetTurnState(model);
		ctx().noteChildExecutedToolCall("toolu_conn", CONNECTOR_TOOL, 0);
		noteChildExecutedToolResults({ type: "user", message: { content: "just a prompt echo" } });
		noteChildExecutedToolResults({ type: "user", message: {} });
	});
});
