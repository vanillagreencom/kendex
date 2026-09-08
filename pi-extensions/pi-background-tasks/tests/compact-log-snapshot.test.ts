import { expect, test } from "bun:test";
import { compactBackgroundTaskSnapshot, WAKE_MANIFEST_FIELD_MAX_CHARS as cap } from "../extensions/wake-events.js";
import { fakeSnapshot } from "./fixtures/lifecycle.js";

const rows = [
	{ name: "huge command retains its bounded prefix", field: "command", input: "C".repeat(200_000), expected: "C".repeat(cap - 1) + "…" },
	{ name: "huge title retains its bounded prefix", field: "title", input: "T".repeat(2_000), expected: "T".repeat(cap - 1) + "…" },
	{ name: "huge cwd retains its bounded prefix", field: "cwd", input: "/path/" + "P".repeat(5_000), expected: "/path/" + "P".repeat(cap - 7) + "…" },
	{ name: "huge logFile retains its bounded prefix", field: "logFile", input: "/tmp/" + "L".repeat(5_000), expected: "/tmp/" + "L".repeat(cap - 6) + "…" },
	{ name: "small command is unchanged", field: "command", input: "echo log", expected: "echo log" },
] as const;

test("compact log snapshot field rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "compact snapshot table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const compact = compactBackgroundTaskSnapshot(fakeSnapshot({ [row.field]: row.input }));
		expect({ value: compact[row.field], bounded: compact[row.field].length <= cap }, row.name).toStrictEqual({ value: row.expected, bounded: true });
	}
});
