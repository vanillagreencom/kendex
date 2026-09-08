import { expect, test } from "bun:test";
import { compactBackgroundTaskSnapshot, WAKE_MANIFEST_FIELD_MAX_CHARS } from "../extensions/wake-events.js";
import { fakeSnapshot, fakeIdent } from "./fixtures/lifecycle.js";

test("compact wake snapshot fields", () => {
	const cap = WAKE_MANIFEST_FIELD_MAX_CHARS;
	const rows = [
		{ name: "bounded fields", fields: { command: "X".repeat(5_000), title: "Y".repeat(5_000), cwd: "Z".repeat(5_000), notifyPattern: "P".repeat(5_000), dedupeKey: "D".repeat(5_000), logFile: "L".repeat(5_000) },
			expected: { command: "X".repeat(cap - 1) + "…", title: "Y".repeat(cap - 1) + "…", cwd: "Z".repeat(cap - 1) + "…", notifyPattern: "P".repeat(cap - 1) + "…", dedupeKey: "D".repeat(cap - 1) + "…", logFile: "L".repeat(cap - 1) + "…" } },
		{ name: "short fields", fields: { command: "echo ok", title: "Hi", cwd: "/repo", notifyPattern: "READY", dedupeKey: "short", logFile: "/private/log.txt" },
			expected: { command: "echo ok", title: "Hi", cwd: "/repo", notifyPattern: "READY", dedupeKey: "short", logFile: "/private/log.txt" } },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length).toBeGreaterThan(0);
	for (const row of rows) {
		const full = fakeSnapshot({ ...row.fields, id: "bg-budget", pid: 4243, outputBytes: 12,
			startedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_050,
			wakeEvents: [{ deliveredAt: 1, eventAt: 1, eventType: "output", sequence: 1, taskStatusAtEmit: "running" }],
			voidedWakeSequences: [1, 2, 3], pendingWakes: [{ eventAt: 1, eventType: "output", sequence: 9 }],
			lastOutputDedupeByKey: { key: "hash" }, procIdent: fakeIdent(4243) });
		const compact = compactBackgroundTaskSnapshot(full);
		expect({ fields: { command: compact.command, title: compact.title, cwd: compact.cwd, notifyPattern: compact.notifyPattern, dedupeKey: compact.dedupeKey, logFile: compact.logFile },
			lifecycle: { id: compact.id, pid: compact.pid, status: compact.status, exitCode: compact.exitCode, outputBytes: compact.outputBytes, startedAt: compact.startedAt, updatedAt: compact.updatedAt },
			omitted: ["wakeEvents", "pendingWakes", "voidedWakeSequences", "lastOutputDedupeByKey", "procIdent"].filter((key) => key in compact),
		}, row.name).toStrictEqual({ fields: row.expected,
			lifecycle: { id: "bg-budget", pid: 4243, status: "running", exitCode: null, outputBytes: 12, startedAt: 1_700_000_000_000, updatedAt: 1_700_000_000_050 }, omitted: [] });
	}
});
