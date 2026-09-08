import { expect, test } from "bun:test";
import { summarizeTaskStatus } from "../extensions/format.js";
import type { BackgroundTaskStatus } from "../extensions/types.js";

const rows: { name: string; status: BackgroundTaskStatus; exitCode: number | null; reason?: string; expected: string }[] = [
	{ name: "completed self-exit omits reason", status: "completed", exitCode: 0, reason: "self-exit", expected: "completed (exit 0)" },
	{ name: "failed self-exit omits reason", status: "failed", exitCode: 137, reason: "self-exit", expected: "failed (exit 137)" },
	{ name: "extension stop appends reason", status: "stopped", exitCode: null, reason: "extension-stop", expected: "stopped (extension-stop)" },
	{ name: "restart reconciliation appends reason", status: "stopped", exitCode: null, reason: "reconcile-on-restart", expected: "stopped (reconcile-on-restart)" },
	{ name: "gone orphan appends reason", status: "failed", exitCode: null, reason: "orphaned-pid-gone", expected: "failed (exit ?) (orphaned-pid-gone)" },
	{ name: "external exit appends reason", status: "failed", exitCode: null, reason: "external", expected: "failed (exit ?) (external)" },
	{ name: "stopped without reason", status: "stopped", exitCode: null, expected: "stopped" },
	{ name: "completed without reason", status: "completed", exitCode: 0, expected: "completed (exit 0)" },
];

test("task status formatting rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "status table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		expect(summarizeTaskStatus(row.status, row.exitCode, row.reason), row.name).toBe(row.expected);
	}
});
