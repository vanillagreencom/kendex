import { expect, test } from "bun:test";
import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import type { ManagedTask } from "../extensions/types.js";
import { recordingHooks } from "./fixtures/lifecycle.js";
import { orphanTask } from "./fixtures/orphan-watcher.js";

interface TimerState {
	delays: number[];
	unrefs: number[];
	cleared: number[];
	active: number[];
	reads: number;
	probes: number[];
	eventIds: string[];
	states: [string, ManagedTask["status"], boolean, boolean | undefined][];
}
interface TimerRow {
	name: string;
	pollMs?: number;
	tasks: Partial<ManagedTask>[];
	steps: { action: "start" | "stop" | "fire"; handle?: number; expected: TimerState }[];
}

const rows: TimerRow[] = [
	{
		name: "start arms an interval and stop clears that handle",
		pollMs: 5_000, tasks: [],
		steps: [
			{ action: "start", expected: { delays: [5_000], unrefs: [0], cleared: [], active: [0], reads: 0, probes: [], eventIds: [], states: [] } },
			{ action: "stop", expected: { delays: [5_000], unrefs: [0], cleared: [0], active: [], reads: 0, probes: [], eventIds: [], states: [] } },
		],
	},
	{
		name: "second start retains the original timer",
		pollMs: 5_000, tasks: [],
		steps: [
			{ action: "start", expected: { delays: [5_000], unrefs: [0], cleared: [], active: [0], reads: 0, probes: [], eventIds: [], states: [] } },
			{ action: "start", expected: { delays: [5_000], unrefs: [0], cleared: [], active: [0], reads: 0, probes: [], eventIds: [], states: [] } },
			{ action: "stop", expected: { delays: [5_000], unrefs: [0], cleared: [0], active: [], reads: 0, probes: [], eventIds: [], states: [] } },
		],
	},
	{
		name: "captured default interval polls and restart uses a new handle",
		tasks: [{ id: "bg-timer", pid: 4242 }],
		steps: [
			{ action: "start", expected: { delays: [30_000], unrefs: [0], cleared: [], active: [0], reads: 0, probes: [], eventIds: [], states: [["bg-timer", "running", false, false]] } },
			{ action: "fire", handle: 0, expected: { delays: [30_000], unrefs: [0], cleared: [], active: [0], reads: 1, probes: [4242], eventIds: ["bg-timer"], states: [["bg-timer", "failed", true, true]] } },
			{ action: "stop", expected: { delays: [30_000], unrefs: [0], cleared: [0], active: [], reads: 1, probes: [4242], eventIds: ["bg-timer"], states: [["bg-timer", "failed", true, true]] } },
			{ action: "start", expected: { delays: [30_000, 30_000], unrefs: [0, 1], cleared: [0], active: [1], reads: 1, probes: [4242], eventIds: ["bg-timer"], states: [["bg-timer", "failed", true, true]] } },
			{ action: "fire", handle: 1, expected: { delays: [30_000, 30_000], unrefs: [0, 1], cleared: [0], active: [1], reads: 2, probes: [4242], eventIds: ["bg-timer"], states: [["bg-timer", "failed", true, true]] } },
			{ action: "stop", expected: { delays: [30_000, 30_000], unrefs: [0, 1], cleared: [0, 1], active: [], reads: 2, probes: [4242], eventIds: ["bg-timer"], states: [["bg-timer", "failed", true, true]] } },
		],
	},
];

test("orphan watcher interval lifecycle", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "orphan timer table must contain rows").toBeGreaterThan(0);
	for (const row of rows) {
		const tasks = row.tasks.map((task) => orphanTask(task));
		const recorder = recordingHooks();
		const handles: { callback: () => void; unref: () => void }[] = [];
		const active = new Set<NodeJS.Timeout>();
		const delays: number[] = [];
		const unrefs: number[] = [];
		const cleared: number[] = [];
		let reads = 0;
		const probes: number[] = [];
		const watcher = createOrphanWatcher({
			getTasks() { reads++; return tasks; }, hooks: recorder.hooks, pollMs: row.pollMs,
			identityProbe(pid) { probes.push(pid); return null; },
			unitActiveProbe() { throw new Error("unexpected systemd unit probe"); },
			setIntervalFn(callback, delay) {
				const handle = { callback, unref() { unrefs.push(handles.indexOf(handle)); } };
				handles.push(handle);
				delays.push(delay);
				const timer = handle as unknown as NodeJS.Timeout;
				active.add(timer);
				return timer;
			},
			clearIntervalFn(handle) {
				cleared.push(handles.indexOf(handle as unknown as (typeof handles)[number]));
				active.delete(handle);
			},
		});
		const observed: TimerState[] = [];
		try {
			for (const step of row.steps) {
				switch (step.action) {
					case "start": watcher.start(); break;
					case "stop": watcher.stop(); break;
					case "fire": {
						const handle = step.handle === undefined ? undefined : handles[step.handle];
						if (!handle || !active.has(handle as unknown as NodeJS.Timeout)) throw new Error("requested timer is not active");
						handle.callback();
						break;
					}
				}
				observed.push({
					delays: [...delays], unrefs: [...unrefs], cleared: [...cleared],
					active: [...active].map((handle) => handles.indexOf(handle as unknown as (typeof handles)[number])),
					reads, probes: [...probes], eventIds: recorder.observe(tasks).events.map((event) => event.id),
					states: tasks.map((task) => [task.id, task.status, task.closed, task.exitNotified]),
				});
			}
			expect(observed, row.name).toStrictEqual(row.steps.map((step) => step.expected));
		} finally {
			watcher.stop();
		}
	}
});
