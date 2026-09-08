import { expect, test } from "bun:test";
import { TASK_DISPLAY_NAME_MAX_CHARS as cap, buildTaskSummaryLine, taskDisplayNameForTranscript } from "../extensions/format.js";
import { fakeSnapshot } from "./fixtures/lifecycle.js";

const rows = [
	{ name: "summary bounds huge title and command", title: "T".repeat(50_000), command: "Q".repeat(50_000), expected: "T".repeat(cap - 1) + "…" },
	{ name: "empty title falls back to bounded command", title: "", command: "Q".repeat(5_000), expected: "Q".repeat(cap - 1) + "…" },
	{ name: "short title is retained", title: "log", command: "echo log", expected: "log" },
];

test("transcript display and summary rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "display table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const task = fakeSnapshot({ title: row.title, command: row.command, id: "bg-log-1", pid: 4242, status: "completed", exitCode: 0 });
		const name = taskDisplayNameForTranscript(task);
		const line = buildTaskSummaryLine(task, task.updatedAt);
		expect({ name, line, nameBounded: name.length <= cap, lineBounded: line.length < cap + 128 }, row.name).toStrictEqual({
			name: row.expected, line: `bg-log-1 · completed (exit 0) · pid 4242 · ${row.expected} · now`, nameBounded: true, lineBounded: true,
		});
	}
});
