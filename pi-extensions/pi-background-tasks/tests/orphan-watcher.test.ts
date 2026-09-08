import { expect, test } from "bun:test";
import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import type { BackgroundTaskStatus, BackgroundTaskTerminationReason, ManagedTask, ProcessIdentity } from "../extensions/types.js";
import { fakeIdent, recordingHooks } from "./fixtures/lifecycle.js";
import { orphanTask } from "./fixtures/orphan-watcher.js";

type TaskState = [string, BackgroundTaskStatus, number | null, boolean | undefined, boolean, BackgroundTaskTerminationReason | undefined];
type Event = [string, BackgroundTaskTerminationReason];
type Finalized = [string, "pid-gone" | "pid-reused"];
interface Poll {
	identities: Record<number, ProcessIdentity | null>;
	expected: { finalized: number; states: TaskState[]; events: Event[]; callbacks: Finalized[]; hooks: [number, number, number, number] };
}
interface WatcherRow { name: string; tasks: Partial<ManagedTask>[]; polls: Poll[] }

const rows: WatcherRow[] = [
	{
		name: "matching live identity stays running",
		tasks: [{ id: "bg-1", pid: 4242 }],
		polls: [{ identities: { 4242: fakeIdent(4242) }, expected: { finalized: 0, states: [["bg-1", "running", null, false, false, undefined]], events: [], callbacks: [], hooks: [0, 0, 0, 0] } }],
	},
	{
		name: "dead pid finalizes with pid-gone callback and termination annotation",
		tasks: [{ id: "bg-1", pid: 4242 }],
		polls: [{ identities: { 4242: null }, expected: { finalized: 1, states: [["bg-1", "failed", null, true, true, "orphaned-pid-gone"]], events: [["bg-1", "orphaned-pid-gone"]], callbacks: [["bg-1", "pid-gone"]], hooks: [2, 2, 1, 1] } }],
	},
	{
		name: "exec changes comm but keeps original pid and start token",
		tasks: [{ id: "bg-bash-exec", pid: 4242, command: "/bin/bash -lc 'sleep 5'", procIdent: { pid: 4242, startToken: "19283746", comm: "bash" } }],
		polls: [{ identities: { 4242: { pid: 4242, startToken: "19283746", comm: "sleep" } }, expected: { finalized: 0, states: [["bg-bash-exec", "running", null, false, false, undefined]], events: [], callbacks: [], hooks: [0, 0, 0, 0] } }],
	},
	{
		name: "reused pid finalizes with pid-reused callback and termination annotation",
		tasks: [{ id: "bg-3", pid: 12345, command: "approval-wait 81", procIdent: fakeIdent(12345) }],
		polls: [{ identities: { 12345: { ...fakeIdent(12345), startToken: "start-RECYCLED", comm: "unrelated" } }, expected: { finalized: 1, states: [["bg-3", "failed", null, true, true, "orphaned-pid-reused"]], events: [["bg-3", "orphaned-pid-reused"]], callbacks: [["bg-3", "pid-reused"]], hooks: [2, 2, 1, 1] } }],
	},
	{
		name: "matching first poll then reused pid",
		tasks: [{ id: "bg-3", pid: 12345, procIdent: fakeIdent(12345) }],
		polls: [
			{ identities: { 12345: fakeIdent(12345) }, expected: { finalized: 0, states: [["bg-3", "running", null, false, false, undefined]], events: [], callbacks: [], hooks: [0, 0, 0, 0] } },
			{ identities: { 12345: { ...fakeIdent(12345), startToken: "start-RECYCLED", comm: "unrelated" } }, expected: { finalized: 1, states: [["bg-3", "failed", null, true, true, "orphaned-pid-reused"]], events: [["bg-3", "orphaned-pid-reused"]], callbacks: [["bg-3", "pid-reused"]], hooks: [2, 2, 1, 1] } },
		],
	},
	{
		name: "matching first poll then dead pid",
		tasks: [{ id: "bg-3", pid: 4242, notifyOnExit: true }],
		polls: [
			{ identities: { 4242: fakeIdent(4242) }, expected: { finalized: 0, states: [["bg-3", "running", null, false, false, undefined]], events: [], callbacks: [], hooks: [0, 0, 0, 0] } },
			{ identities: { 4242: null }, expected: { finalized: 1, states: [["bg-3", "failed", null, true, true, "orphaned-pid-gone"]], events: [["bg-3", "orphaned-pid-gone"]], callbacks: [["bg-3", "pid-gone"]], hooks: [2, 2, 1, 1] } },
		],
	},
	{
		name: "mixed non-orphan and dead orphan tasks",
		tasks: [{ id: "bg-running-child", restored: false }, { id: "bg-already-terminal", status: "completed", exitCode: 0 }, { id: "bg-orphan-dead", pid: 4242 }],
		polls: [{ identities: { 2409160: null, 4242: null }, expected: {
			finalized: 1,
			states: [["bg-running-child", "running", null, false, false, undefined], ["bg-already-terminal", "completed", 0, false, false, undefined], ["bg-orphan-dead", "failed", null, true, true, "orphaned-pid-gone"]],
			events: [["bg-orphan-dead", "orphaned-pid-gone"]], callbacks: [["bg-orphan-dead", "pid-gone"]], hooks: [2, 2, 1, 1],
		} }],
	},
	{
		name: "multiple dead orphans finalize in task order",
		tasks: [{ id: "bg-1", pid: 1111 }, { id: "bg-2", pid: 2222 }, { id: "bg-3", pid: 3333 }],
		polls: [{ identities: { 1111: null, 2222: null, 3333: null }, expected: {
			finalized: 3,
			states: [["bg-1", "failed", null, true, true, "orphaned-pid-gone"], ["bg-2", "failed", null, true, true, "orphaned-pid-gone"], ["bg-3", "failed", null, true, true, "orphaned-pid-gone"]],
			events: [["bg-1", "orphaned-pid-gone"], ["bg-2", "orphaned-pid-gone"], ["bg-3", "orphaned-pid-gone"]],
			callbacks: [["bg-1", "pid-gone"], ["bg-2", "pid-gone"], ["bg-3", "pid-gone"]], hooks: [6, 6, 3, 3],
		} }],
	},
	{
		name: "finalized orphan has no effects on subsequent poll",
		tasks: [{ id: "bg-1", pid: 4242 }],
		polls: [
			{ identities: { 4242: null }, expected: { finalized: 1, states: [["bg-1", "failed", null, true, true, "orphaned-pid-gone"]], events: [["bg-1", "orphaned-pid-gone"]], callbacks: [["bg-1", "pid-gone"]], hooks: [2, 2, 1, 1] } },
			{ identities: { 4242: null }, expected: { finalized: 0, states: [["bg-1", "failed", null, true, true, "orphaned-pid-gone"]], events: [["bg-1", "orphaned-pid-gone"]], callbacks: [["bg-1", "pid-gone"]], hooks: [2, 2, 1, 1] } },
		],
	},
	{
		name: "no recorded identity uses current pid liveness",
		tasks: [{ id: "bg-legacy", pid: 4242, procIdent: undefined }],
		polls: [{ identities: { 4242: fakeIdent(4242) }, expected: { finalized: 0, states: [["bg-legacy", "running", null, false, false, undefined]], events: [], callbacks: [], hooks: [0, 0, 0, 0] } }],
	},
];

test("orphan watcher poll outcomes", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "orphan watcher table must contain rows").toBeGreaterThan(0);
	for (const row of rows) {
		const tasks = row.tasks.map((task) => orphanTask(task));
		const recorder = recordingHooks();
		let identities: Poll["identities"] = {};
		const callbacks: { id: string; reason: "pid-gone" | "pid-reused"; sameTask: boolean }[] = [];
		const watcher = createOrphanWatcher({
			getTasks: () => tasks, hooks: recorder.hooks,
			identityProbe(pid) {
				const identity = identities[pid];
				if (identity === undefined) throw new Error(`unexpected identity probe for ${pid}`);
				return identity;
			},
			unitActiveProbe() { throw new Error("unexpected systemd unit probe"); },
			setIntervalFn() { throw new Error("checkOnce must not arm a timer"); },
			clearIntervalFn() { throw new Error("checkOnce must not clear an interval"); },
			onFinalize(task, reason) { callbacks.push({ id: task.id, reason, sameTask: tasks.includes(task) }); },
		});
		const observed = [];
		for (const poll of row.polls) {
			identities = poll.identities;
			const { finalized } = watcher.checkOnce();
			const hooks = recorder.observe(tasks);
			// Store primitive task fields before a later poll changes the task.
			observed.push({
				finalized,
				states: tasks.map((task) => [task.id, task.status, task.exitCode, task.exitNotified, task.closed, task.terminationReason]),
				events: hooks.events,
				callbacks: callbacks.map((callback) => ({ ...callback })),
				hooks: [hooks.persists, hooks.remembers, hooks.refreshes, hooks.timerClears],
			});
		}
		expect(observed, row.name).toStrictEqual(row.polls.map(({ expected }) => ({
			...expected,
			events: expected.events.map(([id, reason]) => ({ id, reason, type: "exit", sameTask: true })),
			callbacks: expected.callbacks.map(([id, reason]) => ({ id, reason, sameTask: true })),
		})));
	}
});
