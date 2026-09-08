#!/usr/bin/env node
// Integration tests for tool execution + message interaction scenarios.
// Uses pi in RPC mode with the bridge + SlowTool test extension.
// Exercises how the bridge handles messages arriving during tool execution.

import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { createRpcHarness } from "./lib/rpc-harness.mjs";

const TEST_TIMEOUT = 30_000;

const harness = createRpcHarness({
	name: "tool-message",
	args: ["-e", "./tests/fixtures/slow-tool-extension.ts", "--model", "pi-claude/claude-haiku-4-5"],
	defaultTimeout: TEST_TIMEOUT,
});

describe("tool-message integration", () => {
	const { send, waitForEvent, waitForMatch, collectText, promptAndWait } = harness;

	// --- Lifecycle ---

	beforeEach(async () => {
		harness.start();
		await new Promise((r) => setTimeout(r, 2000));
	});

	afterEach(async () => {
		await harness.stop();
	});

	// --- Tests ---

	it("tool call completes normally", { timeout: TEST_TIMEOUT }, async () => {
		const text = await promptAndWait(
			"Call SlowTool with seconds=1. Then repeat exactly what it returned, nothing else."
		);
		assert.match(text, /\bslow_tool_ms=1000\b/);
	});

	it("followUp during tool execution delivers after tool completes", { timeout: TEST_TIMEOUT }, async () => {
		const collector = collectText();
		const toolStarted = waitForEvent("tool_execution_start");
		await send({
			type: "prompt",
			message: "Call SlowTool with seconds=5. Then repeat exactly what it returned.",
		});
		await toolStarted;
		// followUp is queued by pi until the current turn finishes
		const ended = waitForEvent("agent_end");
		await send({
			type: "prompt",
			message: "Reply with the exact word FOLLOWUP_COMPLETE after the tool result.",
			streamingBehavior: "followUp",
		});
		await ended;
		const text = collector.stop();
		assert.match(text, /\bslow_tool_ms=5000\b/);
		assert.match(text, /\bFOLLOWUP_COMPLETE\b/);
	});

	it("steer during tool execution still delivers tool result", { timeout: 15_000 }, async () => {
		// steer injects a user message into the context during an active
		// tool call. extractAllToolResults stops at the user message and returns 0
		// results, leaving the pending handler stuck.
		const collector = collectText();
		const toolStarted = waitForEvent("tool_execution_start");
		await send({
			type: "prompt",
			message: "Call SlowTool with seconds=2. Then repeat exactly what it returned.",
		});
		await toolStarted;
		const ended = waitForEvent("agent_end");
		await send({
			type: "prompt",
			message: "This is a steer message during tool execution.",
			streamingBehavior: "steer",
		});
		await ended;
		const text = collector.stop();
		assert.match(text, /\bslow_tool_ms=2000\b/);
	});

	it("parallel tool calls with steer delivers all results", { timeout: 30_000 }, async () => {
		const collector = collectText();
		const toolStarted = waitForEvent("tool_execution_start");
		await send({
			type: "prompt",
			message: "Call SlowTool three times in parallel: seconds=3, seconds=4, seconds=5. Then list all three results.",
		});
		// Wait for at least one tool to start, then inject steer
		await toolStarted;
		const ended = waitForEvent("agent_end");
		await send({
			type: "prompt",
			message: "This is a steer during parallel tool execution.",
			streamingBehavior: "steer",
		});
		await ended;
		const text = collector.stop();
		// All three tools should have their results in the response
		for (const milliseconds of [3000, 4000, 5000]) {
			assert.match(text, new RegExp(`\\bslow_tool_ms=${milliseconds}\\b`), `Missing result for ${milliseconds}: ${text}`);
		}
	});

	it("steer during text response (no tool call) completes both turns", { timeout: 30_000 }, async () => {
		// Steer during text-only streaming: the assistant is generating text (no tool
		// calls), a steer arrives, and pi delivers it after the current turn ends.
		// Risk: if activeQuery hasn't been cleared by the time pi calls streamSimple
		// for the steer, the bridge enters the tool-result-delivery path incorrectly.
		const collector = collectText();
		await send({
			type: "prompt",
			message: "Write at least 5 detailed paragraphs about the history of computing, from Babbage to modern times. Do NOT call any tools. Do NOT stop early.",
		});
		// Wait until text is actually streaming before injecting the steer
		await waitForMatch(
			(msg) => msg.type === "message_update" && msg.assistantMessageEvent?.type === "text_delta",
			"text_delta during assistant response",
		);
		const ended = waitForEvent("agent_end");
		await send({
			type: "prompt",
			message: "After you finish, also say the exact word 'PINEAPPLE' on its own line.",
			streamingBehavior: "steer",
		});
		await ended;
		const text = collector.stop();
		assert.match(text.toLowerCase(), /pineapple/);
	});

	it("steer during tool execution is visible to assistant", { timeout: 20_000 }, async () => {
		// Bug: when a steer arrives during tool execution, pi drains it at the turn
		// boundary and injects it into context alongside the tool result. The bridge
		// sees activeQuery=true, enters tool-result-delivery mode, extracts the tool
		// result, but silently ignores the trailing user message (the steer). Claude
		// never sees the steer content.
		const collector = collectText();
		const toolStarted = waitForEvent("tool_execution_start");
		await send({
			type: "prompt",
			message: "Call SlowTool with seconds=2. After it returns, repeat exactly what it returned.",
		});
		await toolStarted;
		const ended = waitForEvent("agent_end");
		await send({
			type: "prompt",
			message: "IMPORTANT: Also say the exact word 'MANGO' on its own line in your response.",
			streamingBehavior: "steer",
		});
		await ended;
		const text = collector.stop();
		assert.match(text.toLowerCase(), /mango/, `Steer content not visible to assistant: ${text.slice(0, 300)}`);
	});

	it("abort during tool execution recovers cleanly", { timeout: TEST_TIMEOUT }, async () => {
		const toolStarted = waitForEvent("tool_execution_start");
		await send({
			type: "prompt",
			message: "Call SlowTool with seconds=30.",
		});
		await toolStarted;
		const idle = waitForEvent("agent_end");
		await send({ type: "abort" });
		await idle;
		// Next prompt should work without hanging
		const text = await promptAndWait("Reply with just the word 'recovered'.");
		assert.match(text.toLowerCase(), /recovered/);
	});
});
