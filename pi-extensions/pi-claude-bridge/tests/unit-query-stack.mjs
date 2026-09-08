import assert from "node:assert/strict";
import { describe, it, beforeEach } from "node:test";
import { ctx, pushContext, popContext, popContextFor, resetStack, stackDepth } from "../src/query-state.js";

describe("context stack guards", () => {
	beforeEach(() => resetStack());

	it("pushContext throws with no active query", () => {
		assert.throws(() => pushContext(), (error) => error.message.split("\n")[0] === "query-stack-push=inactive");
	});

	it("popContext throws on empty stack", () => {
		assert.throws(() => popContext(), (error) => error.message.split("\n")[0] === "query-stack-pop=empty");
	});
});

describe("stack isolation and restore", () => {
	beforeEach(() => resetStack());

	it("push/pop isolates state and restores parent", () => {
		// Parent setup
		ctx().activeQuery = { id: "parent" };
		ctx().pendingToolCalls.set("t1", { toolName: "read", resolve: () => {} });
		ctx().latestCursor = 42;
		ctx().deferredUserMessages = ["parent-msg"];

		// Push — child should be clean
		pushContext();
		assert.strictEqual(ctx().activeQuery, null);
		assert.strictEqual(ctx().pendingToolCalls.size, 0);
		assert.strictEqual(ctx().pendingResults.size, 0);
		assert.strictEqual(ctx().latestCursor, 0);
		assert.deepStrictEqual(ctx().deferredUserMessages, []);

		// Mutate child
		ctx().activeQuery = { id: "child" };
		ctx().pendingToolCalls.set("t2", { toolName: "write", resolve: () => {} });
		ctx().latestCursor = 99;

		// Pop — parent restored
		popContext();
		assert.deepStrictEqual(ctx().activeQuery, { id: "parent" });
		assert.strictEqual(ctx().pendingToolCalls.size, 1);
		assert.ok(ctx().pendingToolCalls.has("t1"));
		assert.strictEqual(ctx().latestCursor, 42);
	});

	it("deferred messages merge on pop in FIFO order", () => {
		ctx().activeQuery = { id: "parent" };
		ctx().deferredUserMessages = ["parent-1", "parent-2"];

		pushContext();
		ctx().deferredUserMessages = ["child-1", "child-2"];

		popContext();
		assert.deepStrictEqual(
			ctx().deferredUserMessages,
			["parent-1", "parent-2", "child-1", "child-2"],
		);
	});

	it("triple-nested isolation — each level independent, pop restores", () => {
		// Level 0 (root)
		ctx().activeQuery = { id: "L0" };
		ctx().latestCursor = 10;
		ctx().deferredUserMessages = ["L0-msg"];

		// Level 1
		pushContext();
		assert.strictEqual(stackDepth(), 1);
		ctx().activeQuery = { id: "L1" };
		ctx().latestCursor = 20;
		ctx().deferredUserMessages = ["L1-msg"];

		// Level 2
		pushContext();
		assert.strictEqual(stackDepth(), 2);
		ctx().activeQuery = { id: "L2" };
		ctx().latestCursor = 30;
		ctx().deferredUserMessages = ["L2-msg"];

		// Pop L2 → L1 (L2's deferred merge into L1)
		popContext();
		assert.strictEqual(stackDepth(), 1);
		assert.deepStrictEqual(ctx().activeQuery, { id: "L1" });
		assert.strictEqual(ctx().latestCursor, 20);
		assert.deepStrictEqual(ctx().deferredUserMessages, ["L1-msg", "L2-msg"]);

		// Pop L1 → L0 (L1+L2's deferred merge into L0)
		popContext();
		assert.strictEqual(stackDepth(), 0);
		assert.deepStrictEqual(ctx().activeQuery, { id: "L0" });
		assert.strictEqual(ctx().latestCursor, 10);
		assert.deepStrictEqual(ctx().deferredUserMessages, ["L0-msg", "L1-msg", "L2-msg"]);
	});
});

describe("context pinning (MCP handler closure pattern)", () => {
	beforeEach(() => resetStack());

	it("captured context ref stays valid across push/pop", () => {
		ctx().activeQuery = { id: "parent" };
		ctx().pendingToolCalls.set("t1", { toolName: "read", resolve: () => {} });

		// Simulate handler capturing parent context before push
		const capturedCtx = ctx();

		pushContext();
		// After push, ctx() is the child — but capturedCtx still points to parent
		assert.notStrictEqual(ctx(), capturedCtx);
		assert.strictEqual(capturedCtx.pendingToolCalls.size, 1);
		assert.ok(capturedCtx.pendingToolCalls.has("t1"));

		// Mutate child — captured parent unaffected
		ctx().pendingToolCalls.set("t2", { toolName: "write", resolve: () => {} });
		assert.strictEqual(capturedCtx.pendingToolCalls.size, 1);

		// Pop restores parent as current
		popContext();
		assert.strictEqual(ctx(), capturedCtx);
	});

	it("captured parent context tracks a parent result while child query is current", () => {
		ctx().activeQuery = { id: "parent" };
		ctx().recordToolCall("parent-tool", "read", { path: "parent.txt" });
		const capturedParent = ctx();

		pushContext();
		ctx().activeQuery = { id: "child" };
		ctx().recordToolCall("child-tool", "read", { path: "child.txt" });

		capturedParent.markToolResultDelivered("parent-tool");
		capturedParent.markToolResultResolved("parent-tool");
		const parentProgress = capturedParent.toolResultProgress();
		const childProgress = ctx().toolResultProgress();

		assert.equal(parentProgress.resolvedCount, 1);
		assert.equal(childProgress.resolvedCount, 0);
		assert.deepStrictEqual(childProgress.missingDeliveredIds, ["child-tool"]);

		popContext();
		assert.strictEqual(ctx(), capturedParent);
	});
});

describe("popContextFor", () => {
	beforeEach(() => resetStack());

	it("pops normally when the target is the live context", () => {
		const parent = ctx();
		parent.activeQuery = "q-parent";
		pushContext();
		const child = ctx();
		child.deferredUserMessages.push({ text: "steer" });

		assert.equal(popContextFor(child), true);
		assert.equal(ctx(), parent);
		assert.equal(stackDepth(), 0);
		assert.deepEqual(parent.deferredUserMessages, [{ text: "steer" }]);
	});

	it("splices a buried context out of the stack without touching the live child", () => {
		const outer = ctx();
		outer.activeQuery = "q-outer";
		pushContext();
		const mid = ctx();
		mid.activeQuery = "q-mid";
		mid.deferredUserMessages.push({ text: "mid-steer" });
		pushContext();
		const grandchild = ctx();

		// mid is buried under the live grandchild; popping it must not disturb ctx().
		assert.equal(popContextFor(mid), true);
		assert.equal(ctx(), grandchild);
		assert.equal(stackDepth(), 1);
		// mid's deferred messages went to ITS parent (outer), not the grandchild.
		assert.deepEqual(outer.deferredUserMessages, [{ text: "mid-steer" }]);
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

