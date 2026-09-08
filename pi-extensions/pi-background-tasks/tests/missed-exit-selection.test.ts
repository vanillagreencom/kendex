import { expect, test } from "bun:test";
import { selectMissedExits } from "../extensions/snapshot.js";
import type { ManagedTask } from "../extensions/types.js";
import { fakeTask } from "./fixtures/lifecycle.js";

test("selectMissedExits selects exact task IDs from notification and status inputs", () => {
	const rows: { name: string; tasks: Partial<ManagedTask>[]; expected: string[] }[] = [
		{
			name: "mixed tasks retain selection order",
			tasks: [
				{ id: "bg-1", status: "running" },
				{ id: "bg-2", status: "stopped", exitNotified: false, notifyOnExit: true },
				{ id: "bg-3", status: "completed", exitNotified: true, exitCode: 0, notifyOnExit: true },
				{ id: "bg-4", status: "failed", exitNotified: false, exitCode: 1, notifyOnExit: false },
				{ id: "bg-5", status: "timed_out", exitNotified: false, notifyOnExit: true },
			],
			expected: ["bg-2", "bg-5"],
		},
		{
			name: "running task with no exit notification is excluded",
			tasks: [{ id: "bg-1", status: "running", exitNotified: false }], expected: [],
		},
		{
			name: "stopped task with notification enabled is selected",
			tasks: [{ id: "bg-2", status: "stopped", exitNotified: false, notifyOnExit: true }], expected: ["bg-2"],
		},
		{
			name: "completed task with prior notification is excluded",
			tasks: [{ id: "bg-3", status: "completed", exitCode: 0, exitNotified: true, notifyOnExit: true }], expected: [],
		},
		{
			name: "failed task with notifications disabled is excluded",
			tasks: [{ id: "bg-4", status: "failed", exitCode: 1, exitNotified: false, notifyOnExit: false }], expected: [],
		},
		{
			name: "timed out task with notification enabled is selected",
			tasks: [{ id: "bg-5", status: "timed_out", exitNotified: false, notifyOnExit: true }], expected: ["bg-5"],
		},
		{
			name: "completed task with undefined notification is excluded",
			tasks: [{ id: "bg-1", status: "completed", exitCode: 0, exitNotified: undefined }], expected: [],
		},
		{
			name: "stopped task with undefined notification is excluded",
			tasks: [{ id: "bg-2", status: "stopped", exitNotified: undefined }], expected: [],
		},
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "missed exit selection rows must not be empty").toBeGreaterThan(0);
	for (const row of rows) {
		const tasks = row.tasks.map((input) => fakeTask({ outputBytes: 89, ...input }));
		expect(selectMissedExits(tasks).map((task) => task.id), row.name).toEqual(row.expected);
	}
});
