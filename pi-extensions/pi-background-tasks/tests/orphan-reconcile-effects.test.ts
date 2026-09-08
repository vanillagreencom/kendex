import { expect, test } from "bun:test";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

const rows = [
	{ name: "gone orphan finalizes through the exact metadata hook order without signals", identity: "gone", finalized: 1, status: "failed", reason: "orphaned-pid-gone", reasonIsUndefined: false },
	{ name: "reused pid finalizes metadata without signalling the replacement", identity: "reused", finalized: 1, status: "failed", reason: "orphaned-pid-reused", reasonIsUndefined: false },
	{ name: "matching orphan remains running without hooks or signals", identity: "matching", finalized: 0, status: "running", reason: null, reasonIsUndefined: true },
];

test("orphan reconciliation effect rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "orphan effect table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const result = runSpawnFixture("orphan-reconcile.ts", { identity: row.identity });
		expect(result, row.name).toStrictEqual({
			result: { finalized: row.finalized },
			calls: row.finalized ? ["clearTaskTimers", "rememberSnapshot", "persistSnapshots", "sendTaskEvent", "rememberSnapshot", "persistSnapshots", "refreshUi"] : [],
			events: row.finalized ? [{ type: "exit", sameTask: true, id: "bg-97", status: "failed", reason: row.reason }] : [],
			task: { id: "bg-97", status: row.status, reason: row.reason, reasonIsUndefined: row.reasonIsUndefined, exitCode: null, closed: row.finalized === 1, exitNotified: row.finalized === 1, stopReason: null },
			signals: [], childSignals: [], spawns: [], syncCalls: [], unexpected: [],
		});
	}
}, SPAWN_FIXTURE_TIMEOUT_MS * (rows.length + 1));
