import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { processAssistantMessage, processStreamEvent } from "../src/index.ts";
import { ctx, resetStack } from "../src/query-state.ts";

const model = {
	api: "claude-bridge",
	provider: "claude-bridge",
	id: "claude-haiku-4-5",
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
};

function installFakeStream() {
	const events = [];
	const stream = {
		push(event) { events.push(event); },
		end(result) { events.push({ type: "stream_end", result }); },
	};
	ctx().currentPiStream = stream;
	return events;
}

describe("assistant tool-use boundary fallback", () => {
	beforeEach(() => resetStack());

	it("ends a streamed tool-use turn when the SDK assistant message arrives before message_stop", () => {
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		c.turnSawStreamEvent = true;
		c.turnSawToolCall = true;
		c.turnToolCallIds = ["toolu_1"];
		c.turnBlocks.push({
			type: "toolCall",
			id: "toolu_1",
			name: "bash",
			arguments: {},
			partialJson: "{\"command\":\"echo hi\"}",
			index: 0,
		});

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [{
					type: "tool_use",
					id: "toolu_1",
					name: "mcp__custom-tools__bash",
					input: { command: "echo hi" },
				}],
			},
		}, model, new Map([["mcp__custom-tools__bash", "bash"]]));

		assert.equal(c.currentPiStream, null);
		assert.equal(c.turnOutput.stopReason, "toolUse");
		assert.deepEqual(c.turnToolCallIds, ["toolu_1"]);
		assert.equal(c.turnBlocks.length, 1, "must not duplicate streamed tool call block");
		assert.equal(c.turnBlocks[0].arguments.command, "echo hi");
		assert.ok(!("partialJson" in c.turnBlocks[0]), "partial JSON should be finalized");
		assert.equal(events.at(-2).type, "done");
		assert.equal(events.at(-2).reason, "toolUse");
		assert.equal(events.at(-1).type, "stream_end");
	});

	it("adds missing tool-use blocks from assistant message before ending the turn", () => {
		const c = ctx();
		c.resetTurnState(model);
		const events = installFakeStream();
		c.turnSawStreamEvent = true;

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [{
					type: "tool_use",
					id: "toolu_missing",
					name: "mcp__custom-tools__read",
					input: { file_path: "README.md" },
				}],
			},
		}, model, new Map([["mcp__custom-tools__read", "read"]]));

		assert.equal(c.currentPiStream, null);
		assert.deepEqual(c.turnToolCallIds, ["toolu_missing"]);
		assert.equal(c.turnBlocks.length, 1);
		assert.equal(c.turnBlocks[0].name, "read");
		assert.equal(c.turnBlocks[0].arguments.path, "README.md");
		assert.deepEqual(events.map((event) => event.type), ["start", "toolcall_start", "toolcall_end", "done", "stream_end"]);
	});

	it("records assistant tool-use ids even after the stream already ended", () => {
		const c = ctx();
		c.resetTurnState(model);
		c.turnSawStreamEvent = true;
		c.turnSawToolCall = true;
		c.currentPiStream = null;
		c.recordToolCall("toolu_streamed", "bash", { command: "echo first", timeout: 120 });
		c.turnBlocks.push({
			type: "toolCall",
			id: "toolu_streamed",
			name: "bash",
			arguments: { command: "echo first", timeout: 120 },
		});

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [
					{
						type: "tool_use",
						id: "toolu_streamed",
						name: "mcp__custom-tools__bash",
						input: { command: "echo first" },
					},
					{
						type: "tool_use",
						id: "toolu_missing_after_stop",
						name: "mcp__custom-tools__write",
						input: { file_path: "out.txt", content: "ok" },
					},
				],
			},
		}, model, new Map([
			["mcp__custom-tools__bash", "bash"],
			["mcp__custom-tools__write", "write"],
		]));

		assert.equal(c.currentPiStream, null);
		assert.deepEqual(c.turnToolCallIds, ["toolu_streamed", "toolu_missing_after_stop"]);
		assert.equal(c.turnBlocks.length, 2);
		assert.equal(c.turnBlocks[1].name, "write");
		assert.equal(c.turnBlocks[1].arguments.path, "out.txt");
	});

	it("ignores a late bare message_stop so the next assistant fallback still renders text", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();

		processStreamEvent({ type: "stream_event", event: { type: "message_stop" } }, new Map(), model);

		assert.equal(c.turnSawStreamEvent, false, "late stop-only event must not mask assistant fallback");
		assert.equal(c.currentPiStream !== null, true);

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [{ type: "text", text: "next turn text" }],
			},
		}, model, new Map());

		assert.equal(c.turnBlocks.length, 1);
		assert.equal(c.turnBlocks[0].type, "text");
		assert.equal(c.turnBlocks[0].text, "next turn text");
	});

	it("ignores late unmatched content_block events so assistant fallback is not masked", () => {
		const c = ctx();
		c.resetTurnState(model);
		installFakeStream();

		processStreamEvent({ type: "stream_event", event: { type: "content_block_delta", index: 7, delta: { type: "text_delta", text: "late" } } }, new Map(), model);
		processStreamEvent({ type: "stream_event", event: { type: "content_block_stop", index: 7 } }, new Map(), model);

		assert.equal(c.turnSawStreamEvent, false, "unmatched late content events must not mask assistant fallback");
		assert.equal(c.turnBlocks.length, 0);

		processAssistantMessage({
			type: "assistant",
			message: {
				content: [{ type: "text", text: "fallback after stale content event" }],
			},
		}, model, new Map());

		assert.equal(c.turnBlocks.length, 1);
		assert.equal(c.turnBlocks[0].text, "fallback after stale content event");
	});

	it("updates the Pi assistant model when Claude Code switches models at message_start", () => {
		const c = ctx();
		c.resetTurnState({ ...model, id: "claude-fable-5" });
		installFakeStream();

		processStreamEvent({
			type: "stream_event",
			event: {
				type: "message_start",
				message: {
					model: "claude-opus-4-8",
					usage: { input_tokens: 1, output_tokens: 0 },
				},
			},
		}, new Map(), model);

		assert.equal(c.turnOutput.model, "claude-opus-4-8");
		assert.equal(c.turnSawStreamEvent, false);
	});

	it("records fallback assistant blocks without rendering them as text", () => {
		const c = ctx();
		c.resetTurnState({ ...model, id: "claude-fable-5" });
		installFakeStream();

		processAssistantMessage({
			type: "assistant",
			message: {
				model: "claude-opus-4-8",
				content: [{
					type: "fallback",
					from: { model: "claude-fable-5" },
					to: { model: "claude-opus-4-8" },
				}],
			},
		}, model, new Map());

		assert.equal(c.turnOutput.model, "claude-opus-4-8");
		assert.equal(c.turnBlocks.length, 0);
	});
});
