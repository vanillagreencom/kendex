import { integrityWorld } from "./lib/integrity-fixture.mjs";
import { test } from "node:test";
import assert from "node:assert/strict";
import { statSync } from "node:fs";
import { QueryContext } from "../src/query-state.js";
import { __testGetBridgeIntegrityState, __testSetBridgeIntegrityState, INTEGRITY_CUSTOM_TYPE, reportToolResultMismatch } from "../src/index.js";

function completedContext() {
	const queryCtx = new QueryContext();
	queryCtx.activeQuery = { id: "query" };
	queryCtx.recordToolCall("t0", "read", { path: "safe.txt" });
	queryCtx.recordToolCall("t1", "bash", { command: "echo should-not-leak" });
	for (const id of ["t0", "t1"]) {
		queryCtx.markToolResultDelivered(id);
		queryCtx.markToolResultResolved(id);
	}
	return queryCtx;
}

test("mismatch reports respect interruption and notification options", async (t) => {
	const rows = [
		{ name: "unresolved result", defect: "unresolved", reason: "query teardown", options: {}, notify: true },
		{ name: "queued result", defect: "queued", reason: "query teardown", options: {}, notify: true },
		{ name: "expected abort", defect: "unresolved", reason: "abort", options: { expectedInterruption: true, forceRotate: true }, notify: false },
		{ name: "unexpected interruption", defect: "unresolved", reason: "stream idle timeout", options: { forceRotate: true }, notify: true },
		{ name: "notification failure", defect: "queued", reason: "query teardown", options: {}, notify: "throws" },
		{ name: "complete delivery", defect: undefined, reason: "query teardown", options: {}, notify: false },
	];
	for (const row of rows) {
		await t.test(row.name, (t) => {
			const world = integrityWorld(t);
			const queryCtx = completedContext();
			if (row.defect === "unresolved") queryCtx.resolvedToolResultIds.delete("t1");
			if (row.defect === "queued") queryCtx.pendingResults.set("t1", { toolCallId: "t1", content: [{ type: "text", text: "should-not-leak" }] });
			if (row.notify === "throws") __testSetBridgeIntegrityState({ ui: { notify() { throw new Error("notify failed"); } } });

			const reported = reportToolResultMismatch(queryCtx, row.reason, "/repo", row.options);
			const repeated = reportToolResultMismatch(queryCtx, row.reason, "/repo", row.options);
			const diagStat = statSync(world.diagPath, { throwIfNoEntry: false });
			const diagnostic = diagStat ? world.readDiagEntries() : [];
			const { sharedSession } = __testGetBridgeIntegrityState();
			const reports = row.defect !== undefined && !row.options.expectedInterruption;
			const queuedIds = row.defect === "queued" ? ["t1"] : [];
			const resolved = row.defect === "unresolved" ? 1 : 2;
			assert.deepEqual({
				reported, repeated,
				notifications: world.notifications.map(({ message, level }) => ({ level, key: message.split("\n")[0] })),
				diagnostics: diagnostic.map((entry) => ({ label: entry.label, expected: entry.progress.expectedCount, queuedIds: entry.progress.queuedIds })),
				mode: diagStat ? diagStat.mode & 0o777 : undefined,
				sessionEntries: world.sessionEntries.map((entry) => ({ customType: entry.customType, label: entry.data.label, queuedIds: entry.data.queuedIds, toolNames: entry.data.toolNames })),
				leaksOutput: JSON.stringify([diagnostic, world.sessionEntries]).includes("should-not-leak"),
				needsRebuild: sharedSession.needsRebuild, forceRotate: sharedSession.forceRotate,
			}, {
				reported: row.defect !== undefined, repeated: false,
				notifications: row.notify === true ? [{ level: "error", key: `tool-result-mismatch=${JSON.stringify({ delivered: 2, expected: 2, resolved, diagnostic: world.diagPath })}` }] : [],
				diagnostics: reports ? [{ label: "tool_result_delivery_mismatch", expected: 2, queuedIds }] : [],
				mode: reports ? 0o600 : undefined,
				sessionEntries: reports ? [{ customType: INTEGRITY_CUSTOM_TYPE, label: "tool_result_delivery_mismatch", queuedIds, toolNames: [{ name: "bash", count: 1 }] }] : [],
				leaksOutput: false,
				needsRebuild: row.defect !== undefined ? true : undefined,
				forceRotate: row.options.forceRotate,
			}, row.name);
		});
	}
});
