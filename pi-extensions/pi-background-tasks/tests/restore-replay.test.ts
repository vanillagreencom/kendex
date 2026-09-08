import { expect, test } from "bun:test";
import { replayMissedExitsLifecycle } from "../extensions/lifecycle.js";
import { restoredTaskFromSnapshot } from "../extensions/snapshot.js";
import type { BackgroundTaskSnapshot, BackgroundTaskStatus, BackgroundTaskTerminationReason, ProcessIdentity } from "../extensions/types.js";
import { fakeIdent, fakeSnapshot, recordingHooks } from "./fixtures/lifecycle.js";

interface RestoreReplayRow {
	name: string;
	snapshot: Partial<BackgroundTaskSnapshot>;
	identity: ProcessIdentity | null;
	expected: {
		status: BackgroundTaskStatus;
		closed: boolean;
		beforeNotified: boolean;
		afterNotified: boolean;
		reason: BackgroundTaskTerminationReason | undefined;
		replayed: number;
		eventIds: string[];
	};
}

const rows: RestoreReplayRow[] = [
	{
		name: "dead same-session running snapshot is stopped before exit replay",
		snapshot: { id: "bg-3", status: "running", exitCode: null, outputBytes: 89, exitNotified: false, notifyOnExit: true, procIdent: fakeIdent(2409160) },
		identity: null,
		expected: { status: "stopped", closed: true, beforeNotified: false, afterNotified: true, reason: "reconcile-on-restart", replayed: 1, eventIds: ["bg-3"] },
	},
	{
		name: "matching live identity remains running without an exit replay",
		snapshot: { id: "bg-3", status: "running", pid: 4242, notifyOnExit: true, procIdent: fakeIdent(4242) },
		identity: fakeIdent(4242),
		expected: { status: "running", closed: false, beforeNotified: false, afterNotified: false, reason: undefined, replayed: 0, eventIds: [] },
	},
	{
		name: "foreign-session snapshot is ineligible before replay",
		snapshot: { id: "bg-other", status: "running", exitNotified: false, notifyOnExit: true, sessionId: "sess-OTHER" },
		identity: null,
		expected: { status: "stopped", closed: true, beforeNotified: true, afterNotified: true, reason: "reconcile-on-restart", replayed: 0, eventIds: [] },
	},
];

test("restore followed by missed exit replay", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "restore-replay table must contain rows").toBeGreaterThan(0);
	for (const row of rows) {
		const recorder = recordingHooks();
		const restored = restoredTaskFromSnapshot(fakeSnapshot(row.snapshot), {
			identityProbe: () => row.identity, sessionId: "sess-1", now: 1_700_000_100_000,
		});
		// Capture the restore result before replay can change exitNotified.
		const before = { status: restored.status, closed: restored.closed, exitNotified: restored.exitNotified };
		const replayed = replayMissedExitsLifecycle([restored], recorder.hooks);
		expect({ before, replayed, afterNotified: restored.exitNotified, hooks: recorder.observe([restored]) }, row.name).toStrictEqual({
			before: { status: row.expected.status, closed: row.expected.closed, exitNotified: row.expected.beforeNotified },
			replayed: row.expected.replayed, afterNotified: row.expected.afterNotified,
			hooks: {
				events: row.expected.eventIds.map((id) => ({ type: "exit", id, reason: row.expected.reason, sameTask: true })),
				persists: row.expected.replayed, remembers: row.expected.replayed, refreshes: 0, timerClears: 0,
			},
		});
	}
});
