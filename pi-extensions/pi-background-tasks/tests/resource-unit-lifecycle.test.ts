import { expect, test } from "bun:test";
import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import { restoredTaskFromSnapshot } from "../extensions/snapshot.js";
import type { ManagedTask, ProcessIdentity } from "../extensions/types.js";
import { fakeSnapshot, fakeTask, recordingHooks } from "./fixtures/lifecycle.js";

test("systemd unit state takes precedence over wrapper identity during restore and polling", () => {
	const unit = "kendex-pi-bg-bg-7.service";
	const identity = { comm: "systemd-run", pid: 4242, startToken: "start-4242" };
	const rows: {
		name: string; operation: "restore" | "watch"; active: boolean; identity: ProcessIdentity | null; expected: object;
	}[] = [
		{
			name: "active unit keeps restored task running despite missing wrapper", operation: "restore", active: true, identity: null,
			expected: { status: "running", closed: false, exitNotified: false, terminationReason: undefined, result: undefined },
		},
		{
			name: "inactive unit stops restored task despite live wrapper", operation: "restore", active: false, identity,
			expected: { status: "stopped", closed: true, exitNotified: false, terminationReason: "reconcile-on-restart", result: undefined },
		},
		{
			name: "watcher leaves active unit running before probing wrapper", operation: "watch", active: true, identity: null,
			expected: { status: "running", closed: false, exitNotified: false, terminationReason: undefined, result: { finalized: 0 } },
		},
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "resource unit lifecycle rows must not be empty").toBeGreaterThan(0);
	for (const row of rows) {
		const snapshot = fakeSnapshot({
			command: "sleep 60", cwd: "/tmp/work", id: "bg-rc", logFile: "/tmp/bg-rc.log", outputBytes: 0,
			pid: 4242, procIdent: identity, sessionId: "session-A", title: "sleep 60",
			resourceControl: { mode: "systemd-run", requestedMode: "auto", unitName: unit },
		});
		const unitCalls: string[] = [];
		const identityCalls: number[] = [];
		const unitActiveProbe = (name: string) => { unitCalls.push(name); return row.active; };
		const identityProbe = (pid: number) => { identityCalls.push(pid); return row.identity; };
		const recorder = recordingHooks();
		let task: ManagedTask;
		let result: { finalized: number } | undefined;
		if (row.operation === "restore") {
			task = restoredTaskFromSnapshot(snapshot, { sessionId: "session-A", identityProbe, unitActiveProbe, now: 1_700_000_001_000 });
		} else {
			task = fakeTask({
				...snapshot, restored: true, notifyMode: "transition", pendingWakes: [], voidedWakeSequences: [],
				voidedWakes: new Set<number>(), wakeEvents: [], wakeSequence: 0,
			});
			const watcher = createOrphanWatcher({ getTasks: () => [task], hooks: recorder.hooks, identityProbe, unitActiveProbe });
			result = watcher.checkOnce();
		}
		expect({
			state: { status: task.status, closed: task.closed, exitNotified: task.exitNotified, terminationReason: task.terminationReason, result },
			unitCalls, identityCalls, hooks: recorder.observe([task]),
		}, row.name).toStrictEqual({
			state: row.expected, unitCalls: [unit], identityCalls: [],
			hooks: { events: [], persists: 0, remembers: 0, refreshes: 0, timerClears: 0 },
		});
	}
});
