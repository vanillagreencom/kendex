import { it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { processAssistantMessage, processStreamEvent } from "../src/index.ts";
import { ctx, resetStack } from "../src/query-state.ts";
const CONNECTOR_TOOL = "mcp__claude_ai_Slack__slack_read_user_profile";
import { model, installFakeStream, streamEvent } from "./lib/tool-stream.mjs";
import { cancelScheduledToolUseEnd } from "../src/assistant-stream.ts";
afterEach(() => cancelScheduledToolUseEnd(ctx()));

beforeEach(() => resetStack());
const childRoutes = [
	{ name: "connector stream", tool: CONNECTOR_TOOL, id: "toolu_conn", input: { user_id: "U1" }, route: "stream", owned: true },
	{ name: "ToolSearch stream", tool: "ToolSearch", id: "toolu_ts", input: { query: "select:WebFetch" }, route: "stream", owned: false },
	{ name: "connector message stop", tool: CONNECTOR_TOOL, id: "toolu_conn", input: {}, route: "stop", owned: true },
	{ name: "ToolSearch message stop", tool: "ToolSearch", id: "toolu_ts", input: {}, route: "stop", owned: false },
	{ name: "connector assistant boundary", tool: CONNECTOR_TOOL, id: "toolu_conn", input: { user_id: "U1" }, route: "boundary", owned: true },
	{ name: "ToolSearch assistant boundary", tool: "ToolSearch", id: "toolu_ts", input: { query: "select:WebFetch" }, route: "boundary", owned: false },
	{ name: "connector fallback", tool: CONNECTOR_TOOL, id: "toolu_conn", input: { user_id: "U1" }, route: "fallback", owned: true },
	{ name: "ToolSearch fallback", tool: "ToolSearch", id: "toolu_ts", input: { query: "select:WebFetch" }, route: "fallback", owned: false },
];
for (const row of childRoutes) it(row.name, () => {
	resetStack();
	const c = ctx();
	c.resetTurnState(model);
	const events = installFakeStream();
	const call = { type: "tool_use", id: row.id, name: row.tool, input: row.input };
	if (row.route === "stream" || row.route === "stop") {
		processStreamEvent(streamEvent({ type: "content_block_start", index: 0, content_block: call }), new Map(), model);
		if (row.route === "stream") {
			processStreamEvent(streamEvent({ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify(row.input) } }), new Map(), model);
			processStreamEvent(streamEvent({ type: "content_block_stop", index: 0 }), new Map(), model);
		} else processStreamEvent(streamEvent({ type: "message_stop" }), new Map(), model);
	} else {
		c.turnSawStreamEvent = row.route === "boundary";
		const content = row.route === "fallback" ? [{ type: "text", text: "checking" }, call] : [call];
		processAssistantMessage({ type: "assistant", message: { content } }, model, new Map());
	}
	assert.deepEqual({
		blocks: c.turnBlocks.map((b) => b.type),
		toolBoundary: c.turnSawToolCall,
		toolIds: c.turnToolCallIds,
		queued: c.pendingResults.size,
		streamOpen: c.currentPiStream !== null,
		ownedCalls: [...c.childExecutedToolCalls],
		audit: [...c.connectorCallAudit].map(([id, entry]) => [id, entry.name]),
	}, { blocks: row.route === "fallback" ? ["text"] : [], toolBoundary: false, toolIds: [], queued: 0, streamOpen: true, ownedCalls: row.owned ? [[row.id, row.tool]] : [], audit: row.owned ? [[row.id, row.tool]] : [] });
	if (row.route === "stream") assert.deepEqual({ events: events.map((event) => event.type), skipped: c.childExecutedStreamIndexes.has(0) }, { events: ["start"], skipped: true });
});

const foreignRoutes = [
	["bare stream", "grep", "stream", false], ["nameless stream", undefined, "stream", false],
	["foreign stream", "mcp__filesystem__read_file", "stream", true], ["foreign slash stream", "mcp/filesystem/read_file", "stream", true],
	["foreign boundary", "mcp__filesystem__read_file", "boundary", true], ["foreign fallback", "mcp__filesystem__read_file", "fallback", true],
	["bare fallback", "bash", "fallback", false],
];
for (const [name, toolName, route, committed] of foreignRoutes) it(name, () => {
	resetStack();
	const c = ctx();
	c.resetTurnState(model);
	installFakeStream();
	const manifest = new Map([["mcp__custom-tools__read", "read"], ["mcp__custom-tools__grep", "grep"]]);
	const call = { type: "tool_use", id: "call", ...(toolName === undefined ? {} : { name: toolName }), input: {} };
	if (route === "stream") {
		processStreamEvent(streamEvent({ type: "content_block_start", index: 0, content_block: call }), manifest, model);
		processStreamEvent(streamEvent({ type: "content_block_stop", index: 0 }), manifest, model);
	} else {
		c.turnSawStreamEvent = route === "boundary";
		processAssistantMessage({ type: "assistant", message: { content: [call] } }, model, manifest);
	}
	assert.deepEqual([c.turnBlocks.length, c.turnSawToolCall, c.turnToolCallIds, c.committedOutput], [0, false, [], committed]);
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
		// The boundary arms the grace timer instead of ending the turn directly
		// and lets message_stop end it, so message_delta's usage can land first.
		assert.equal(c.turnSawToolCall, true);
		assert.ok(c.scheduledToolUseEnd, "a real Pi tool call arms the deferred turn end");
		processStreamEvent(streamEvent({ type: "message_stop" }), new Map(), model);
		assert.equal(c.currentPiStream, null, "message_stop ends the tool-use turn");
		assert.equal(c.scheduledToolUseEnd, null, "grace timer disarmed at turn end");
	});

it("still mirrors a Pi tool coincidentally named like a child built-in", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();
		c.turnSawStreamEvent = true;

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [{ type: "tool_use", id: "toolu_x", name: "mcp__custom-tools__ToolSearchX", input: {} }],
			},
		}, model, new Map([["mcp__custom-tools__ToolSearchX", "ToolSearchX"]]));

		assert.equal(c.turnBlocks.length, 1, "an exact-name miss stays a real Pi tool call");
		assert.equal(c.turnBlocks[0].name, "ToolSearchX");
		assert.equal(c.turnSawToolCall, true);
	});

it("mirrors a streamed MCP-resource read under its stream-side spelling (kendex#1007)", () => {
		// What actually arrives on the stream is the SDK's ALIASED name
		// (`ReadMcpResourceTool`, not the request-side `ReadMcpResource`), and it
		// must surface in Pi: the mirror is the resource-read audit surface for
		// hosts with no view of the child transcript.
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();

		processStreamEvent(streamEvent({
			type: "content_block_start",
			index: 0,
			content_block: { type: "tool_use", id: "toolu_rr", name: "ReadMcpResourceTool", input: {} },
		}), new Map([["mcp__custom-tools__grep", "grep"]]), model);

		assert.equal(c.turnBlocks.length, 1, "a resource read is a visible Pi tool call");
		assert.equal(c.turnBlocks[0].name, "ReadMcpResourceTool");
		assert.equal(c.turnSawToolCall, true);
		assert.equal(c.childExecutedStreamIndexes.has(0), false, "its deltas must stream, not be skipped");
	});

it("mirrors an MCP-resource enumeration on the assistant-boundary path too (kendex#1007)", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();
		c.turnSawStreamEvent = true;

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [{ type: "tool_use", id: "toolu_lr", name: "ListMcpResourcesTool", input: { server: "s1" } }],
			},
		}, model, new Map([["mcp__custom-tools__grep", "grep"]]));

		assert.equal(c.turnBlocks.length, 1);
		assert.equal(c.turnBlocks[0].name, "ListMcpResourcesTool");
		assert.equal(c.turnSawToolCall, true);
	});
