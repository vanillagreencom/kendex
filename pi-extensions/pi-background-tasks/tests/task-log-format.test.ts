import { expect, test } from "bun:test";
import { DEFAULT_LOG_TAIL_MAX_CHARS as cap } from "../extensions/constants.js";
import { formatTaskLog, taskLogTruncation } from "../extensions/format.js";
import { WAKE_MANIFEST_FIELD_MAX_CHARS as fieldCap } from "../extensions/wake-events.js";
import { withLogSettings } from "./fixtures/log-settings.js";

const marker = "retained log tail\n";
const tail = marker + "y".repeat(cap - marker.length - 1) + "!";
const rows = [
	{ name: "short descriptor is absent", output: "short\n".repeat(10), path: "/tmp/log", clipped: false },
	{ name: "small output is unchanged", output: "all good\n".repeat(50), path: "/tmp/log", clipped: false },
	{ name: "exact cap is unchanged", output: "x".repeat(cap), path: "/tmp/log", clipped: false },
	{ name: "huge output retains the exact tail and descriptor", output: "x".repeat(cap * 4) + tail, path: "/tmp/big.log", clipped: true },
	{ name: "empty output uses sentinel", output: "", path: "/tmp/log", clipped: false },
	{ name: "long log path is bounded in banner and descriptor", output: "z".repeat(cap * 3) + tail, path: "/tmp/" + "L".repeat(10_000), clipped: true },
];

test("log formatting and descriptor rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "log formatting table must contain cases").toBeGreaterThan(0);
	withLogSettings((cwd) => {
		for (const row of rows) {
			const formatted = formatTaskLog(row.output, row.path, cwd);
			const descriptor = taskLogTruncation(row.output, row.path, cwd);
			const safePath = row.path.length <= fieldCap ? row.path : row.path.slice(0, fieldCap - 1) + "…";
			const expected = row.clipped
				? `[...truncated]\n${tail}\n\n[Background log truncated. Showing last ${cap} of ${row.output.length} character(s). Full log: ${safePath}]`
				: row.output || "(empty)";
			expect({ formatted, descriptor, bounded: formatted.length < cap + (row.path.length > fieldCap ? fieldCap : 0) + 256, excludesLongPath: !formatted.includes("L".repeat(fieldCap + 1)) }, row.name).toStrictEqual({
				formatted: expected,
				descriptor: row.clipped ? { direction: "tail", truncated: true, fullOutputPath: safePath, shownChars: cap, totalChars: row.output.length } : undefined,
				bounded: true, excludesLongPath: true,
			});
		}
	});
});
