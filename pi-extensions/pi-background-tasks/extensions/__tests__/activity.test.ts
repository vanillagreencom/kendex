import { expect, test } from "bun:test";
import { fakeTask } from "../../tests/fixtures/lifecycle.js";
import { buildBackgroundTaskActivity } from "../activity.js";
import type { BackgroundTaskStatus } from "../types.js";

const rows: {
	name: string;
	status: BackgroundTaskStatus;
	exitCode: number | null;
	command: string;
	kind: "start" | "exit";
	sequence: number;
	expected: { type: string; severity: string; importance: string; command: string };
}[] = [
	{ name: "completed", status: "completed", exitCode: 0, command: "printf ready", kind: "exit", sequence: 4,
		expected: { type: "bg_task.completed", severity: "success", importance: "normal", command: "printf ready" } },
	{ name: "failed", status: "failed", exitCode: 1, command: "printf ready", kind: "exit", sequence: 4,
		expected: { type: "bg_task.failed", severity: "error", importance: "important", command: "printf ready" } },
	{ name: "timed out", status: "timed_out", exitCode: 1, command: "printf ready", kind: "exit", sequence: 4,
		expected: { type: "bg_task.timed_out", severity: "error", importance: "important", command: "printf ready" } },
	{ name: "stopped", status: "stopped", exitCode: 1, command: "printf ready", kind: "exit", sequence: 4,
		expected: { type: "bg_task.stopped", severity: "warning", importance: "important", command: "printf ready" } },
	{ name: "long command", status: "running", exitCode: null, command: "x".repeat(260), kind: "start", sequence: 0,
		expected: { type: "bg_task.started", severity: "info", importance: "noisy", command: "x".repeat(200) } },
];

test("activity event construction", () => {
	expect.hasAssertions();
	for (const row of rows) {
		const event = buildBackgroundTaskActivity(row.kind, fakeTask({ status: row.status, exitCode: row.exitCode, command: row.command }), { sequence: row.sequence });
		expect({
			type: event.type, severity: event.severity, importance: event.importance,
			command: event.details?.command, status: event.details?.status,
			exitCode: event.details?.exit_code, sequence: event.details?.sequence,
		}, row.name).toStrictEqual({ ...row.expected, status: row.status, exitCode: row.exitCode, sequence: row.sequence });
	}
});
