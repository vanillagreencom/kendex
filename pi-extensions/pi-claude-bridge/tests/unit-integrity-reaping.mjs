import { integrityWorld } from "./lib/integrity-fixture.mjs";
import { test } from "node:test";
import assert from "node:assert/strict";
import { QueryContext } from "../src/query-state.js";
import { reapStaleQueuedResults } from "../src/index.js";

test("stale queued results remain consumable and leave payload-free records", (t) => {
	const world = integrityWorld(t);
	const queryCtx = new QueryContext();
	queryCtx.recordToolCall("bash-lost", "bash", { command: "echo should-not-leak" });
	queryCtx.pendingResults.set("bash-lost", { toolCallId: "bash-lost", content: [{ type: "text", text: "should-not-leak" }] });
	queryCtx.resetToolTracking();

	reapStaleQueuedResults(queryCtx);

	assert.equal(queryCtx.pendingResults.size, 0);
	assert.equal(queryCtx.reapedResults.size, 1);
	assert.equal(queryCtx.reapedResults.get("bash-lost").content[0].text, "should-not-leak");
	const diag = world.readDiagEntries();
	assert.equal(diag.length, 1);
	assert.equal(diag[0].label, "stale_queued_tool_results_parked");
	assert.deepEqual(diag[0].stale, [{ id: "bash-lost", toolName: "bash" }]);
	assert.equal(world.sessionEntries.length, 1);
	assert.equal(world.sessionEntries[0].data.label, "stale_queued_tool_results_parked");
	assert.deepEqual(world.notifications.map(({ message, level }) => ({ key: message.split("\n")[0], level })),
		[{ key: 'queued-results-parked={"count":1,"tools":["bash"]}', level: "warning" }]);
	assert.equal(JSON.stringify(diag).includes("should-not-leak"), false);
	assert.equal(JSON.stringify(world.sessionEntries).includes("should-not-leak"), false);
});

test("reaping nothing appends nothing", (t) => {
	const world = integrityWorld(t);
	reapStaleQueuedResults(new QueryContext());
	assert.equal(world.sessionEntries.length, 0);
	assert.equal(world.notifications.length, 0);
});
