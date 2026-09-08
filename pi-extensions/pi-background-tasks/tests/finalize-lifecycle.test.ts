import { expect, test } from "bun:test";
import { finalizeTaskLifecycle } from "../extensions/lifecycle.js";
import type { BackgroundTaskStatus, BackgroundTaskTerminationReason, ManagedTask } from "../extensions/types.js";
import { fakeTask, recordingHooks } from "./fixtures/lifecycle.js";

interface FinalizeRow {
	name: string;
	task?: Partial<ManagedTask>;
	exitCode: number | null;
	statusOverride?: BackgroundTaskStatus;
	reasonOverride?: BackgroundTaskTerminationReason;
	sendReturns?: boolean;
	secondClose?: boolean;
	expected: {
		status: BackgroundTaskStatus;
		reason: BackgroundTaskTerminationReason;
		exitNotified?: boolean;
		persists?: number;
		output?: string;
		outputBytes?: number;
	};
}

const partialOutput = "Warning: GH_TOKEN/GITHUB_TOKEN failed gh auth; unsetting them and using gh keyring auth.\n";
const rows: FinalizeRow[] = [
	{ name: "clean self-exit", exitCode: 0, expected: { status: "completed", reason: "self-exit" } },
	{ name: "null exit code is external", exitCode: null, expected: { status: "failed", reason: "external" } },
	{ name: "nonzero self-exit", exitCode: 1, expected: { status: "failed", reason: "self-exit" } },
	{ name: "user stop derives extension-stop", task: { stopReason: "user" }, exitCode: null, expected: { status: "stopped", reason: "extension-stop" } },
	{ name: "timeout stop derives timeout", task: { stopReason: "timeout" }, exitCode: null, expected: { status: "timed_out", reason: "timeout" } },
	{ name: "status override wins over user stop and successful exit", task: { stopReason: "user" }, exitCode: 0, statusOverride: "failed", expected: { status: "failed", reason: "extension-stop" } },
	{ name: "sender false retains pending exit notification", exitCode: 0, sendReturns: false, expected: { status: "completed", reason: "self-exit", exitNotified: false, persists: 1 } },
	// The sender result is injected; this row does not test the host sender's setting gate.
	{ name: "sender false with notifyOnExit disabled", task: { notifyOnExit: false }, exitCode: 0, sendReturns: false, expected: { status: "completed", reason: "self-exit", exitNotified: false, persists: 1 } },
	{ name: "second close leaves task and every hook unchanged", exitCode: 0, secondClose: true, expected: { status: "completed", reason: "self-exit" } },
	{ name: "partial output survives external termination", task: { output: partialOutput, outputBytes: 89 }, exitCode: null, expected: { status: "failed", reason: "external", output: partialOutput, outputBytes: 89 } },
	{ name: "zero output still sends an exit", task: { output: "", outputBytes: 0 }, exitCode: 0, expected: { status: "completed", reason: "self-exit", output: "", outputBytes: 0 } },
	{ name: "pre-stamped extension-stop survives finalize", task: { stopReason: "user", terminationReason: "extension-stop" }, exitCode: null, expected: { status: "stopped", reason: "extension-stop" } },
	{ name: "shutdown stop derives session-shutdown", task: { stopReason: "shutdown" }, exitCode: null, expected: { status: "stopped", reason: "session-shutdown" } },
	{ name: "explicit reason wins over pre-stamped and derived reason", task: { stopReason: "user", terminationReason: "extension-stop" }, exitCode: null, reasonOverride: "orphaned-pid-reused", expected: { status: "stopped", reason: "orphaned-pid-reused" } },
	{ name: "pre-stamped reason wins over a different derivation", task: { terminationReason: "extension-stop" }, exitCode: 0, expected: { status: "completed", reason: "extension-stop" } },
];

test("finalize lifecycle outcomes", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "finalize table must contain rows").toBeGreaterThan(0);
	for (const row of rows) {
		const task = fakeTask(row.task);
		const recorder = recordingHooks(row.sendReturns);
		const result = finalizeTaskLifecycle(task, row.exitCode, recorder.hooks, row.statusOverride, row.reasonOverride);
		const observe = () => ({
			sameTask: result === task, status: task.status, exitCode: task.exitCode,
			exitNotified: task.exitNotified, closed: task.closed, reason: task.terminationReason,
			output: task.output, outputBytes: task.outputBytes, hooks: recorder.observe([task]),
		});
		const first = observe();
		const expected = {
			sameTask: true, status: row.expected.status, exitCode: row.exitCode,
			exitNotified: row.expected.exitNotified ?? true, closed: true, reason: row.expected.reason,
			output: row.expected.output ?? "", outputBytes: row.expected.outputBytes ?? 0,
			hooks: {
				events: [{ type: "exit", id: "bg-3", reason: row.expected.reason, sameTask: true }],
				persists: row.expected.persists ?? 2, remembers: row.expected.persists ?? 2,
				refreshes: 1, timerClears: 1,
			},
		};
		let second;
		if (row.secondClose) {
			const taskBefore = { ...task };
			const secondResult = finalizeTaskLifecycle(task, 99, recorder.hooks);
			second = { before: first, after: observe(), taskBefore, taskAfter: { ...task }, sameTask: secondResult === task };
		}
		expect({ first, second }, row.name).toStrictEqual({
			first: expected,
			second: row.secondClose ? { before: expected, after: expected, taskBefore: second?.taskBefore, taskAfter: second?.taskBefore, sameTask: true } : undefined,
		});
	}
});
