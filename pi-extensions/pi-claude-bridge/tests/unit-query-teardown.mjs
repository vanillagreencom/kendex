/**
 * Tests for query teardown keyed to the CAPTURED query context (audit C1).
 *
 * A parent query can end abnormally (abort, child process death) while a
 * reentrant subagent context is still pushed. Teardown keyed on the live ctx()
 * used to mutate the subagent's state and skip the parent's own drain entirely.
 * These tests pin the fixed behavior: teardownQuery touches only the context it
 * was given, and popContextFor never pops someone else's context.
 * Uses the real module — no API calls, no extension activation.
 */
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Route diag/integrity output away from the real user dir BEFORE the modules load.
const scratch = mkdtempSync(join(tmpdir(), "claude-bridge-teardown-test-"));
process.env.CLAUDE_BRIDGE_DIAG_PATH = join(scratch, "diag.log");
process.env.PI_CODING_AGENT_DIR = scratch;

const { ctx, popContext, popContextFor, pushContext, resetStack, stackDepth } = await import("../src/query-state.js");
const { teardownQuery } = await import("../src/query-teardown.js");

import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";

function registerWaitingCall(queryCtx, toolCallId, toolName = "read") {
	return new Promise((resolve) => {
		queryCtx.pendingToolCalls.set(toolCallId, {
			toolName,
			resolve: (result) => {
				queryCtx.markToolResultResolved(toolCallId);
				resolve(result);
			},
		});
	});
}

describe("popContextFor", () => {
	beforeEach(() => resetStack());

	it("pops normally when the target is the live context", () => {
		const parent = ctx();
		parent.activeQuery = "q-parent";
		pushContext();
		const child = ctx();
		child.deferredUserMessages.push("steer");

		assert.equal(popContextFor(child), true);
		assert.equal(ctx(), parent);
		assert.equal(stackDepth(), 0);
		assert.deepEqual(parent.deferredUserMessages, ["steer"]);
	});

	it("splices a buried context out of the stack without touching the live child", () => {
		const outer = ctx();
		outer.activeQuery = "q-outer";
		pushContext();
		const mid = ctx();
		mid.activeQuery = "q-mid";
		mid.deferredUserMessages.push("mid-steer");
		pushContext();
		const grandchild = ctx();

		// mid is buried under the live grandchild; popping it must not disturb ctx().
		assert.equal(popContextFor(mid), true);
		assert.equal(ctx(), grandchild);
		assert.equal(stackDepth(), 1);
		// mid's deferred messages went to ITS parent (outer), not the grandchild.
		assert.deepEqual(outer.deferredUserMessages, ["mid-steer"]);
		assert.deepEqual(grandchild.deferredUserMessages, []);

		// The grandchild's own pop now restores the correct grandparent.
		popContext();
		assert.equal(ctx(), outer);
		assert.equal(stackDepth(), 0);
	});

	it("returns false for a context that is nowhere in the state", () => {
		const parent = ctx();
		parent.activeQuery = "q";
		pushContext();
		const child = ctx();
		popContext();

		assert.equal(popContextFor(child), false);
		assert.equal(ctx(), parent);
	});
});

describe("teardownQuery", () => {
	beforeEach(() => resetStack());

	it("tears down a plain outermost query: drains handlers, clears results, releases activeQuery", async () => {
		const queryCtx = ctx();
		const sdkQuery = { id: "sdk-query" };
		queryCtx.activeQuery = sdkQuery;
		queryCtx.recordToolCall("call-1", "read", { path: "a" });
		const waiting = registerWaitingCall(queryCtx, "call-1");
		queryCtx.pendingResults.set("call-2", { content: [], isError: false });

		assert.equal(teardownQuery(queryCtx, sdkQuery, "query-end", "/tmp", false), true);
		assert.equal(queryCtx.activeQuery, null);
		assert.equal(queryCtx.pendingToolCalls.size, 0);
		assert.equal(queryCtx.pendingResults.size, 0);
		const result = await waiting;
		assert.equal(result.isError, true);
	});

	it("no-ops when the query is no longer the context's active one", () => {
		const queryCtx = ctx();
		const replacement = { id: "continuation" };
		queryCtx.activeQuery = replacement;
		registerWaitingCall(queryCtx, "call-1");

		assert.equal(teardownQuery(queryCtx, { id: "original" }, "query-end", "/tmp", false), false);
		assert.equal(queryCtx.activeQuery, replacement);
		assert.equal(queryCtx.pendingToolCalls.size, 1);
	});

	it("parent aborting while a subagent context is pushed drains the PARENT, not the child", async () => {
		// The C1 defect scenario: outermost parent query ends abnormally while a
		// reentrant child context is live. Live-ctx teardown drained the child's
		// handlers and left the parent's leaked; keyed teardown does the reverse.
		const parent = ctx();
		const parentQuery = { id: "parent-query" };
		parent.activeQuery = parentQuery;
		parent.recordToolCall("parent-call", "bash", { cmd: "ls" });
		const parentWaiting = registerWaitingCall(parent, "parent-call", "bash");

		pushContext();
		const child = ctx();
		child.activeQuery = { id: "child-query" };
		child.recordToolCall("child-call", "read", { path: "b" });
		registerWaitingCall(child, "child-call");

		assert.equal(teardownQuery(parent, parentQuery, "abort", "/tmp", false), true);

		// Parent handler drained as an abort error; parent released.
		const result = await parentWaiting;
		assert.equal(result.isError, true);
		assert.match(result.content[0].text, /aborted/);
		assert.equal(parent.activeQuery, null);

		// Child completely untouched and still the live context.
		assert.equal(ctx(), child);
		assert.equal(child.pendingToolCalls.size, 1);
		assert.notEqual(child.activeQuery, null);
		assert.equal(stackDepth(), 1);
	});

	it("reentrant query teardown pops its own context even when a grandchild is live", async () => {
		const outer = ctx();
		outer.activeQuery = "q-outer";

		pushContext();
		const mid = ctx();
		const midQuery = { id: "mid-query" };
		mid.activeQuery = midQuery;
		mid.deferredUserMessages.push("mid-steer");
		const midWaiting = registerWaitingCall(mid, "mid-call");

		pushContext();
		const grandchild = ctx();
		grandchild.activeQuery = { id: "grandchild-query" };

		assert.equal(teardownQuery(mid, midQuery, "query-end", "/tmp", true), true);

		const result = await midWaiting;
		assert.equal(result.isError, true);
		// Grandchild stays live; mid was spliced out and its deferreds went to outer.
		assert.equal(ctx(), grandchild);
		assert.equal(stackDepth(), 1);
		assert.deepEqual(outer.deferredUserMessages, ["mid-steer"]);

		popContext();
		assert.equal(ctx(), outer);
	});

	it("reentrant teardown with the child as live context restores the parent (common path)", () => {
		const parent = ctx();
		parent.activeQuery = "q-parent";
		pushContext();
		const child = ctx();
		const childQuery = { id: "child-query" };
		child.activeQuery = childQuery;
		child.deferredUserMessages.push("child-steer");

		assert.equal(teardownQuery(child, childQuery, "query-end", "/tmp", true), true);
		assert.equal(ctx(), parent);
		assert.equal(stackDepth(), 0);
		assert.deepEqual(parent.deferredUserMessages, ["child-steer"]);
	});
});
