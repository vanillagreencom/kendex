import { expect, test } from "bun:test";
import { isOrphanRunning } from "../extensions/orphan-watcher.js";
import type { ManagedTask } from "../extensions/types.js";
import { orphanTask } from "./fixtures/orphan-watcher.js";

const rows: { name: string; task: Partial<ManagedTask>; expected: boolean }[] = [
	{ name: "restored running task with valid pid", task: { pid: 4242 }, expected: true },
	{ name: "non-restored task", task: { restored: false }, expected: false },
	{ name: "terminal task", task: { status: "stopped" }, expected: false },
	{ name: "task retains an in-session child handle", task: { child: {} as ManagedTask["child"] }, expected: false },
	{ name: "zero pid", task: { pid: 0 }, expected: false },
	{ name: "negative pid", task: { pid: -1 }, expected: false },
];

test("orphan eligibility", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "orphan eligibility table must contain rows").toBeGreaterThan(0);
	for (const row of rows) {
		expect(isOrphanRunning(orphanTask(row.task)), row.name).toBe(row.expected);
	}
});
