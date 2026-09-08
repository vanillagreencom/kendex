import { expect, test } from "bun:test";
import { WAKE_MANIFEST_FIELD_MAX_CHARS as cap, truncateForTranscript } from "../extensions/wake-events.js";

// Stop templates exercise the helper only; registered stop coverage has its own fixture.
const rows = [
	{ name: "Stopped template bounds huge command", value: "B".repeat(100_000), expected: "B".repeat(cap - 1) + "…", verb: "Stopped" },
	{ name: "Stopping template bounds huge command", value: "B".repeat(100_000), expected: "B".repeat(cap - 1) + "…", verb: "Stopping" },
	{ name: "small value is unchanged", value: "echo log", expected: "echo log", verb: "Stopped" },
	{ name: "empty value is unchanged", value: "", expected: "", verb: "Stopped" },
	{ name: "missing value remains undefined", value: undefined, expected: undefined, verb: "Stopped" },
	{ name: "exact cap is unchanged", value: "B".repeat(cap), expected: "B".repeat(cap), verb: "Stopped" },
];

test("transcript truncation rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "truncation table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const command = truncateForTranscript(row.value, cap);
		const message = `${row.verb} bg-log-1 (${command ?? ""}).`;
		expect({ command, message, boundedCommand: command === undefined || command.length <= cap, boundedMessage: Buffer.byteLength(message, "utf8") < cap + 128, excludesBomb: !message.includes("B".repeat(cap + 1)) }, row.name).toStrictEqual({
			command: row.expected, message: `${row.verb} bg-log-1 (${row.expected ?? ""}).`, boundedCommand: true, boundedMessage: true, excludesBomb: true,
		});
	}
});
