import { expect, test } from "bun:test";
import { replayMissedExitsLifecycle } from "../extensions/lifecycle.js";
import type { ManagedTask } from "../extensions/types.js";
import { fakeTask, recordingHooks } from "./fixtures/lifecycle.js";

interface ReplayRow {
	name: string;
	tasks: Partial<ManagedTask>[];
	sendReturns?: boolean;
	expected: { replayed: number; eventIds: string[]; notified: boolean[]; persists: number; remembers: number };
}

const rows: ReplayRow[] = [
	{
		name: "mixed tasks replay only the pending enabled terminal exit",
		tasks: [
			{ id: "bg-1", status: "running" },
			{ id: "bg-2", status: "stopped", exitNotified: false, notifyOnExit: true },
			{ id: "bg-3", status: "completed", exitNotified: true, exitCode: 0 },
			{ id: "bg-4", status: "failed", exitNotified: false, exitCode: 1, notifyOnExit: false },
		],
		expected: { replayed: 1, eventIds: ["bg-2"], notified: [false, true, true, false], persists: 1, remembers: 1 },
	},
	{ name: "running task causes no event or persistence", tasks: [{ status: "running" }], expected: { replayed: 0, eventIds: [], notified: [false], persists: 0, remembers: 0 } },
	{ name: "already notified terminal task is excluded", tasks: [{ status: "completed", exitNotified: true, exitCode: 0 }], expected: { replayed: 0, eventIds: [], notified: [true], persists: 0, remembers: 0 } },
	{ name: "disabled terminal notification is excluded", tasks: [{ status: "failed", notifyOnExit: false, exitCode: 1 }], expected: { replayed: 0, eventIds: [], notified: [false], persists: 0, remembers: 0 } },
	{ name: "pending stopped exit is replayed", tasks: [{ status: "stopped" }], expected: { replayed: 1, eventIds: ["bg-3"], notified: [true], persists: 1, remembers: 1 } },
	{ name: "sender false leaves notification pending", tasks: [{ id: "bg-2", status: "stopped", exitNotified: false }], sendReturns: false, expected: { replayed: 0, eventIds: ["bg-2"], notified: [false], persists: 0, remembers: 0 } },
	{ name: "empty task collection causes no effects", tasks: [], expected: { replayed: 0, eventIds: [], notified: [], persists: 0, remembers: 0 } },
	{
		name: "multiple successful replays persist once",
		tasks: [{ id: "bg-1", status: "completed", exitCode: 0 }, { id: "bg-2", status: "failed", exitCode: 1 }],
		expected: { replayed: 2, eventIds: ["bg-1", "bg-2"], notified: [true, true], persists: 1, remembers: 2 },
	},
];

test("missed exit replay outcomes", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "replay table must contain rows").toBeGreaterThan(0);
	for (const row of rows) {
		const tasks = row.tasks.map((task) => fakeTask(task));
		const recorder = recordingHooks(row.sendReturns);
		const replayed = replayMissedExitsLifecycle(tasks, recorder.hooks);
		expect({ replayed, notified: tasks.map((task) => task.exitNotified), hooks: recorder.observe(tasks) }, row.name).toStrictEqual({
			replayed: row.expected.replayed,
			notified: row.expected.notified,
			hooks: {
				events: row.expected.eventIds.map((id) => ({ type: "exit", id, reason: undefined, sameTask: true })),
				persists: row.expected.persists, remembers: row.expected.remembers, refreshes: 0, timerClears: 0,
			},
		});
	}
});
