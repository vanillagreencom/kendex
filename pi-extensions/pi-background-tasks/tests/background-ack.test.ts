import { expect, test } from "bun:test";
import { bashBackgroundAckText } from "../extensions/auto-background.js";
import { WAKE_MANIFEST_FIELD_MAX_CHARS as cap } from "../extensions/wake-events.js";
import { fakeSnapshot } from "./fixtures/lifecycle.js";

const rows = [
	{ name: "huge acknowledgement fields retain bounded prefixes", huge: true },
	{ name: "small acknowledgement fields are unchanged", huge: false },
];

test("background acknowledgement rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "acknowledgement table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const task = fakeSnapshot({
			id: "bg-log-1", pid: 4242, command: row.huge ? "C".repeat(200_000) : "echo log",
			cwd: row.huge ? "/path/" + "P".repeat(5_000) : "/path/work",
			logFile: row.huge ? "/tmp/" + "L".repeat(5_000) : "/tmp/log",
			notifyOnOutput: true, notifyPattern: row.huge ? "R".repeat(5_000) : "ready",
			dedupeKey: row.huge ? "D".repeat(5_000) : "monitor",
		});
		const text = bashBackgroundAckText(task, { forced: false, notifyOnExit: true, notifyOnOutput: true, reason: "test", title: "test" });
		const expected = [
			"Started bg-log-1 (pid 4242) in the background.", "Reason: test.",
			`Command: ${row.huge ? "C".repeat(cap - 1) + "…" : "echo log"}`,
			`Cwd: ${row.huge ? "/path/" + "P".repeat(cap - 7) + "…" : "/path/work"}`,
			`Log: ${row.huge ? "/tmp/" + "L".repeat(cap - 6) + "…" : "/tmp/log"}`,
			`Wakeups: exit=yes, output=${row.huge ? "R".repeat(cap - 1) + "…" : "ready"}, mode=always, dedupeKey=${row.huge ? "D".repeat(cap - 1) + "…" : "monitor"}`,
			"Continue the turn without waiting. Use bg_task list/log/stop to inspect or terminate this task.",
		].join("\n");
		expect({ text, bounded: Buffer.byteLength(text, "utf8") < 4_096, excluded: ["C", "P", "L", "R", "D"].filter((char) => text.includes(char.repeat(cap + 1))) }, row.name).toStrictEqual({ text: expected, bounded: true, excluded: [] });
	}
});
