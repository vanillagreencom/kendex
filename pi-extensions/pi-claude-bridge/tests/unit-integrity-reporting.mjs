import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { QueryContext } from "../src/query-state.js";
import { __testGetBridgeIntegrityState, __testSetBridgeIntegrityState, reportToolResultMismatch } from "../src/index.js";

let dir;
let diagPath;
let notifications;

function makeMismatchContext() {
	const queryCtx = new QueryContext();
	queryCtx.activeQuery = { id: "query" };
	queryCtx.recordToolCall("t0", "read", { path: "safe.txt" });
	queryCtx.recordToolCall("t1", "bash", { command: "echo should-not-leak" });
	queryCtx.markToolResultDelivered("t0");
	queryCtx.markToolResultResolved("t0");
	queryCtx.markToolResultDelivered("t1");
	queryCtx.pendingResults.set("t1", { toolCallId: "t1", content: [{ type: "text", text: "queued" }] });
	return queryCtx;
}

function readDiagEntries() {
	return readFileSync(diagPath, "utf8").trim().split("\n").map((line) => JSON.parse(line));
}

describe("tool-result integrity reporting", () => {
	beforeEach(() => {
		dir = mkdtempSync("/tmp/claude-bridge-integrity-");
		diagPath = join(dir, "diag.log");
		process.env.CLAUDE_BRIDGE_DIAG_PATH = diagPath;
		notifications = [];
		__testSetBridgeIntegrityState({
			ui: { notify: (message, level) => notifications.push({ message, level }) },
			sharedSession: { sessionId: "session-12345678", cursor: 4, cwd: "/repo" },
		});
	});

	afterEach(() => {
		__testSetBridgeIntegrityState({ ui: null, sharedSession: null });
		delete process.env.CLAUDE_BRIDGE_DIAG_PATH;
		rmSync(dir, { recursive: true, force: true });
	});

	it("query teardown emits one diagnostic, notifies, and marks rebuild without forceRotate", () => {
		const reported = reportToolResultMismatch(makeMismatchContext(), "query teardown", "/repo");

		assert.equal(reported, true);
		assert.equal(notifications.length, 1);
		assert.equal(notifications[0].level, "error");
		assert.match(notifications[0].message, /delivered 2\/2, resolved 1\/2/);
		const entries = readDiagEntries();
		assert.equal(entries.length, 1);
		assert.equal(entries[0].label, "tool_result_delivery_mismatch");
		assert.equal(entries[0].progress.expectedCount, 2);
		assert.deepEqual(entries[0].progress.queuedIds, ["t1"]);
		assert.equal(JSON.stringify(entries[0]).includes("should-not-leak"), false);
		assert.equal(statSync(diagPath).mode & 0o777, 0o600);
		const { sharedSession } = __testGetBridgeIntegrityState();
		assert.equal(sharedSession.needsRebuild, true);
		assert.equal(sharedSession.forceRotate, undefined);
	});

	it("abort teardown marks forceRotate and still reports exactly once", () => {
		const queryCtx = makeMismatchContext();
		assert.equal(reportToolResultMismatch(queryCtx, "abort", "/repo", { forceRotate: true }), true);
		assert.equal(reportToolResultMismatch(queryCtx, "abort", "/repo", { forceRotate: true }), false);

		assert.equal(readDiagEntries().length, 1);
		assert.equal(notifications.length, 1);
		const { sharedSession } = __testGetBridgeIntegrityState();
		assert.equal(sharedSession.needsRebuild, true);
		assert.equal(sharedSession.forceRotate, true);
	});

	it("notification failure does not throw or skip rebuild marking", () => {
		__testSetBridgeIntegrityState({
			ui: { notify: () => { throw new Error("notify failed"); } },
			sharedSession: { sessionId: "session-12345678", cursor: 4, cwd: "/repo" },
		});

		assert.doesNotThrow(() => reportToolResultMismatch(makeMismatchContext(), "query teardown", "/repo"));
		assert.equal(readDiagEntries().length, 1);
		assert.equal(__testGetBridgeIntegrityState().sharedSession.needsRebuild, true);
	});
});
