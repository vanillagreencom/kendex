import { expect, test } from "bun:test";
import { restoredTaskFromSnapshot, selectMissedExits, type RestoreOptions } from "../extensions/snapshot.js";
import type { BackgroundTaskSnapshot, ManagedTask } from "../extensions/types.js";
import { fakeIdent, fakeSnapshot } from "./fixtures/lifecycle.js";

test("restoredTaskFromSnapshot restores task state and missed exit eligibility", () => {
	const rows: {
		name: string;
		input: Partial<BackgroundTaskSnapshot>;
		omit?: ("procIdent" | "exitNotified" | "sessionId")[];
		options: RestoreOptions & { now: number; identityProbe: NonNullable<RestoreOptions["identityProbe"]> };
		expected: {
			status: ManagedTask["status"];
			stopReason: ManagedTask["stopReason"];
			closed: boolean;
			exitNotified: boolean;
			updatedAt: number;
			terminationReason: ManagedTask["terminationReason"];
			missedIds: string[];
			outputBytes: number;
			lastAnnouncedLength: number;
		};
	}[] = [
		{
			name: "dead running process clears its old exit notification",
			input: { status: "running", exitNotified: true, procIdent: fakeIdent(2409160), outputBytes: 89 },
			options: { now: 1_700_000_100_000, identityProbe: () => null, sessionId: "sess-1" },
			expected: {
				status: "stopped", stopReason: "shutdown", closed: true, exitNotified: false,
				updatedAt: 1_700_000_100_000, terminationReason: "reconcile-on-restart", missedIds: ["bg-3"],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "matching live process stays running with its original timestamp",
			input: { status: "running", pid: 4242, procIdent: fakeIdent(4242), outputBytes: 89 },
			options: { now: 1_700_000_200_000, identityProbe: fakeIdent, sessionId: "sess-1" },
			expected: {
				status: "running", stopReason: null, closed: false, exitNotified: false,
				updatedAt: 1_700_000_000_000, terminationReason: undefined, missedIds: [],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "reused process ID becomes stopped and eligible for exit replay",
			input: { status: "running", pid: 12345, exitNotified: false, procIdent: fakeIdent(12345), outputBytes: 89 },
			options: {
				now: 1_700_000_300_000, sessionId: "sess-1",
				identityProbe: (pid) => ({ pid, startToken: "start-RECYCLED", comm: "unrelated" }),
			},
			expected: {
				status: "stopped", stopReason: "shutdown", closed: true, exitNotified: false,
				updatedAt: 1_700_000_300_000, terminationReason: "reconcile-on-restart", missedIds: ["bg-3"],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "executable name drift with the same start token stays running",
			input: {
				status: "running", pid: 4242, command: "/bin/bash -lc 'sleep 5'", outputBytes: 89,
				procIdent: { pid: 4242, startToken: "19283746", comm: "bash" },
			},
			options: {
				now: 1_700_000_100_000, sessionId: "sess-1",
				identityProbe: (pid) => ({ pid, startToken: "19283746", comm: "sleep" }),
			},
			expected: {
				status: "running", stopReason: null, closed: false, exitNotified: false,
				updatedAt: 1_700_000_000_000, terminationReason: undefined, missedIds: [],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "absent recorded identity uses live process ID",
			input: { status: "running", pid: 4242, outputBytes: 89 }, omit: ["procIdent"],
			options: { now: 1_700_000_100_000, identityProbe: fakeIdent, sessionId: "sess-1" },
			expected: {
				status: "running", stopReason: null, closed: false, exitNotified: false,
				updatedAt: 1_700_000_000_000, terminationReason: undefined, missedIds: [],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "completed and notified snapshot keeps its terminal state",
			input: { status: "completed", exitNotified: true, exitCode: 0, outputBytes: 89 },
			options: { now: 1_700_000_100_000, identityProbe: () => null },
			expected: {
				status: "completed", stopReason: null, closed: true, exitNotified: true,
				updatedAt: 1_700_000_000_000, terminationReason: undefined, missedIds: [],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "terminal snapshot with absent exit notification becomes replay eligible",
			input: { status: "completed", exitCode: 0, notifyOnExit: true, outputBytes: 89 }, omit: ["exitNotified"],
			options: { now: 1_700_000_100_000, identityProbe: () => null },
			expected: {
				status: "completed", stopReason: null, closed: true, exitNotified: false,
				updatedAt: 1_700_000_000_000, terminationReason: undefined, missedIds: ["bg-3"],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "stopped snapshot explicitly never notified stays replay eligible",
			input: { status: "stopped", exitNotified: false, outputBytes: 89 },
			options: { now: 1_700_000_100_000, identityProbe: () => null },
			expected: {
				status: "stopped", stopReason: null, closed: true, exitNotified: false,
				updatedAt: 1_700_000_000_000, terminationReason: undefined, missedIds: ["bg-3"],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "foreign session snapshot cannot replay an exit",
			input: {
				status: "running", sessionId: "sess-OTHER", exitNotified: false,
				procIdent: fakeIdent(2409160), outputBytes: 89,
			},
			options: { now: 1_700_000_100_000, identityProbe: () => null, sessionId: "sess-1" },
			expected: {
				status: "stopped", stopReason: "shutdown", closed: true, exitNotified: true,
				updatedAt: 1_700_000_100_000, terminationReason: "reconcile-on-restart", missedIds: [],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "dead running snapshot with absent session identity is same session",
			input: { status: "running", outputBytes: 89 }, omit: ["sessionId"],
			options: { now: 1_700_000_100_000, identityProbe: () => null, sessionId: "sess-1" },
			expected: {
				status: "stopped", stopReason: "shutdown", closed: true, exitNotified: false,
				updatedAt: 1_700_000_100_000, terminationReason: "reconcile-on-restart", missedIds: ["bg-3"],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "stalled review waiter incident selects the restored task ID",
			input: {
				id: "bg-3", status: "running", exitCode: null, outputBytes: 89,
				exitNotified: false, notifyOnExit: true, procIdent: fakeIdent(2409160),
			},
			options: { now: 1_700_000_100_000, identityProbe: () => null, sessionId: "sess-1" },
			expected: {
				status: "stopped", stopReason: "shutdown", closed: true, exitNotified: false,
				updatedAt: 1_700_000_100_000, terminationReason: "reconcile-on-restart", missedIds: ["bg-3"],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "surviving review waiter incident has no false exit selection",
			input: { id: "bg-3", status: "running", pid: 4242, notifyOnExit: true, procIdent: fakeIdent(4242), outputBytes: 89 },
			options: { now: 1_700_000_100_000, identityProbe: fakeIdent, sessionId: "sess-1" },
			expected: {
				status: "running", stopReason: null, closed: false, exitNotified: false,
				updatedAt: 1_700_000_000_000, terminationReason: undefined, missedIds: [],
				outputBytes: 89, lastAnnouncedLength: 89,
			},
		},
		{
			name: "dead process restore stamps reconcile reason",
			input: { status: "running", pid: 4242, sessionId: "sess-A", outputBytes: 12, procIdent: { comm: "bash", pid: 4242, startToken: "start-4242" } },
			options: { now: 1_700_000_100_000, identityProbe: () => null, sessionId: "sess-A" },
			expected: {
				status: "stopped", stopReason: "shutdown", closed: true, exitNotified: false,
				updatedAt: 1_700_000_100_000, terminationReason: "reconcile-on-restart", missedIds: ["bg-3"],
				outputBytes: 12, lastAnnouncedLength: 12,
			},
		},
		{
			name: "live process restore keeps an undefined termination reason",
			input: {
				status: "running", pid: 4242, sessionId: "sess-A", outputBytes: 12, terminationReason: undefined,
				procIdent: { comm: "bash", pid: 4242, startToken: "start-4242" },
			},
			options: {
				now: 1_700_000_100_000, sessionId: "sess-A",
				identityProbe: (pid) => ({ comm: "bash", pid, startToken: "start-4242" }),
			},
			expected: {
				status: "running", stopReason: null, closed: false, exitNotified: false,
				updatedAt: 1_700_000_000_000, terminationReason: undefined, missedIds: [],
				outputBytes: 12, lastAnnouncedLength: 12,
			},
		},
		{
			name: "terminal snapshot retains a populated termination reason",
			input: { exitCode: 0, exitNotified: true, status: "completed", terminationReason: "self-exit", sessionId: "sess-A", outputBytes: 12 },
			options: { now: 1_700_000_100_000, identityProbe: () => null, sessionId: "sess-A" },
			expected: {
				status: "completed", stopReason: null, closed: true, exitNotified: true,
				updatedAt: 1_700_000_000_000, terminationReason: "self-exit", missedIds: [],
				outputBytes: 12, lastAnnouncedLength: 12,
			},
		},
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "snapshot restore rows must not be empty").toBeGreaterThan(0);
	for (const row of rows) {
		const snapshot = fakeSnapshot(row.input);
		for (const field of row.omit ?? []) delete snapshot[field];
		const restored = restoredTaskFromSnapshot(snapshot, row.options);
		expect({
			status: restored.status,
			stopReason: restored.stopReason,
			closed: restored.closed,
			exitNotified: restored.exitNotified,
			restored: restored.restored,
			updatedAt: restored.updatedAt,
			terminationReason: restored.terminationReason,
			missedIds: selectMissedExits([restored]).map((task) => task.id),
			outputBytes: restored.outputBytes,
			lastAnnouncedLength: restored.lastAnnouncedLength,
		}, row.name).toStrictEqual({ ...row.expected, restored: true });
	}
});
