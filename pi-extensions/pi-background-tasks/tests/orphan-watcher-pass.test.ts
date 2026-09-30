import { expect, test } from "bun:test";
import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import { PROBE_CONCURRENCY } from "../extensions/probes.js";
import type { IdentityReading } from "../extensions/snapshot.js";
import { recordingHooks } from "./fixtures/lifecycle.js";
import { orphanTask } from "./fixtures/orphan-watcher.js";

// Probes answer that the pid is gone only when the test releases them.
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

test("an orphan pass bounds its probes, joins overlapping passes and yields to stop", async () => {
	const rows: {
		name: string;
		orphans: number;
		during: "none" | "second-pass" | "stop" | "finalize-first";
		expected: { maxInFlight: number; probes: number; reads: number; finalized: number[]; statuses: string[] };
	}[] = [
		{
			name: "six orphans probe at most the concurrency limit at once",
			orphans: 6, during: "none",
			expected: { maxInFlight: PROBE_CONCURRENCY, probes: 6, reads: 1, finalized: [6], statuses: Array(6).fill("failed") },
		},
		{
			name: "a pass started while one runs joins it",
			orphans: 2, during: "second-pass",
			expected: { maxInFlight: 2, probes: 2, reads: 1, finalized: [2, 2], statuses: ["failed", "failed"] },
		},
		{
			name: "stop during a pass finalizes nothing",
			orphans: 2, during: "stop",
			expected: { maxInFlight: 2, probes: 2, reads: 1, finalized: [0], statuses: ["running", "running"] },
		},
		{
			name: "a task finalized while its probe ran is not finalized again",
			orphans: 2, during: "finalize-first",
			expected: { maxInFlight: 2, probes: 2, reads: 1, finalized: [1], statuses: ["completed", "failed"] },
		},
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "orphan pass table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const tasks = Array.from({ length: row.orphans }, (_, index) => orphanTask({ id: `bg-${index + 1}`, pid: 5000 + index }));
		const recorder = recordingHooks();
		const waiting: (() => void)[] = [];
		let inFlight = 0;
		let maxInFlight = 0;
		let probes = 0;
		let reads = 0;
		const watcher = createOrphanWatcher({
			getTasks() { reads++; return tasks; },
			hooks: recorder.hooks,
			identityProbe(): Promise<IdentityReading> {
				probes++;
				inFlight++;
				maxInFlight = Math.max(maxInFlight, inFlight);
				return new Promise((resolve) => waiting.push(() => { inFlight--; resolve({ kind: "gone" }); }));
			},
			async unitActiveProbe() { throw new Error("unexpected systemd unit probe"); },
		});
		const passes = [watcher.checkOnce()];
		await settle();
		if (row.during === "second-pass") passes.push(watcher.checkOnce());
		if (row.during === "stop") watcher.stop();
		if (row.during === "finalize-first") { tasks[0]!.status = "completed"; tasks[0]!.closed = true; }
		let settled = false;
		void Promise.all(passes).then(() => { settled = true; });
		while (!settled) {
			waiting.shift()?.();
			await settle();
		}
		const finalized = (await Promise.all(passes)).map((pass) => pass.finalized);
		expect({ maxInFlight, probes, reads, finalized, statuses: tasks.map((task) => task.status) }, row.name).toStrictEqual(row.expected);
	}
});
