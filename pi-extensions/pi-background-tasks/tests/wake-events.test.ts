import { expect, test } from "bun:test";
import { DEFAULT_OUTPUT_ALERT_MAX_CHARS } from "../extensions/constants.js";
import type { BackgroundTaskEventDetails, WakeDiagnostic } from "../extensions/types.js";
import { taskSnapshot } from "../extensions/snapshot.js";
import { scheduleTaskWake, sendTaskWake, voidPendingTaskWakes, WAKE_CONTENT_COMMAND_MAX_CHARS, WAKE_MANIFEST_FIELD_MAX_CHARS } from "../extensions/wake-events.js";
import { fakeTask, fakeIdent } from "./fixtures/lifecycle.js";
import { sendDeps } from "./fixtures/wake.js";

test("wake send lifecycle rows", () => {
	const rows = [
		{ name: "output metadata and accounting", event: "output", status: "running", eventAt: 1_111, void: false, exhausted: false, sent: true, reason: undefined, wakes: 1, bytes: 64 },
		{ name: "exit metadata without output accounting", event: "exit", status: "completed", eventAt: 1_222, void: false, exhausted: false, sent: true, reason: undefined, wakes: 0, bytes: 0 },
		{ name: "exhausted budget still sends exit", event: "exit", status: "completed", eventAt: 7_000, void: false, exhausted: true, sent: true, reason: undefined, wakes: 20, bytes: 0 },
		{ name: "stopped output is suppressed", event: "output", status: "stopped", eventAt: 1_001, void: false, exhausted: false, sent: false, reason: "output-after-stop-suppressed", wakes: 0, bytes: 0 },
		{ name: "voided output is suppressed", event: "output", status: "running", eventAt: 1_333, void: true, exhausted: false, sent: false, reason: "voided", wakes: 0, bytes: 0 },
	] as const;
	expect.assertions(rows.length + 1);
	expect(rows.length).toBeGreaterThan(0);
	for (const row of rows) {
		const task = fakeTask({ id: "bg-7", status: row.status, notifyOnOutput: row.event === "output", notifyMode: "always",
			stopReason: row.status === "stopped" ? "user" : null,
			outputWakeBudget: { wakes: row.exhausted ? 20 : 0, bytes: 0, exhausted: row.exhausted, announcedAt: null } });
		const pending = scheduleTaskWake(task, row.event, row.eventAt);
		const diagnostics: WakeDiagnostic[] = [];
		const voided = row.void ? voidPendingTaskWakes(task, "stop", (d) => diagnostics.push(d), () => 1_400) : 0;
		const { deps, messages } = sendDeps("y".repeat(64), diagnostics);
		const sent = sendTaskWake(deps, row.event, task, { eventAt: pending.eventAt, sequence: pending.sequence });
		const record = { deliveredAt: row.sent ? 2_000 : null, eventAt: row.eventAt, eventType: row.event, sequence: 1, taskStatusAtEmit: row.status,
			...(row.reason ? { droppedReason: row.reason } : {}) };
		expect({ sent, voided, membership: [...task.voidedWakes], pending: task.pendingWakes,
			events: taskSnapshot(task).wakeEvents, budget: task.outputWakeBudget,
			messages: messages.map(({ message }) => { const d = message.details as BackgroundTaskEventDetails;
				return { eventAt: d.eventAt, deliveredAt: d.deliveredAt, sequence: d.sequence, eventType: d.eventType, taskStatusAtEmit: d.taskStatusAtEmit }; }),
			diagnostics: diagnostics.map(({ reason, sequence, timestamp }) => ({ reason, sequence, timestamp })),
		}, row.name).toStrictEqual({ sent: row.sent, voided: row.void ? 1 : 0, membership: row.void ? [1] : [], pending: [],
			events: [record], budget: { wakes: row.wakes, bytes: row.bytes, exhausted: row.exhausted, announcedAt: null },
			messages: row.sent ? [record] : [], diagnostics: row.void ? [
				{ reason: "wake-voided", sequence: 1, timestamp: 1_400 }, { reason: "voided-wake-fired", sequence: 1, timestamp: 2_000 },
			] : row.sent ? [] : [{ reason: row.reason, sequence: 1, timestamp: 2_000 }],
		});
	}
});

test("wake payload retained content", () => {
	const cap = WAKE_MANIFEST_FIELD_MAX_CHARS;
	const short = { command: "printf ready", title: "task", cwd: "/repo", notifyPattern: "READY", dedupeKey: "key", logFile: "/private/log" };
	const long = { command: "Z".repeat(100_000), title: "T".repeat(2_000), cwd: "/path/" + "C".repeat(2_000), notifyPattern: "P".repeat(2_000), dedupeKey: "D".repeat(2_000), logFile: "/tmp/" + "L".repeat(2_000) };
	const rows = [
		{ name: "truncated x output", event: "output", output: "x".repeat(1_000_000), fields: short, matched: undefined, expectedFields: short,
			tail: "[...truncated]\n" + "x".repeat(DEFAULT_OUTPUT_ALERT_MAX_CHARS), truncated: true, expectedPattern: undefined },
		{ name: "truncated y output", event: "output", output: "y".repeat(1_000_000), fields: short, matched: undefined, expectedFields: short,
			tail: "[...truncated]\n" + "y".repeat(DEFAULT_OUTPUT_ALERT_MAX_CHARS), truncated: true, expectedPattern: undefined },
		{ name: "exit uses full output tail", event: "exit", output: "line-a\nline-b\nline-c\n", fields: short, matched: undefined, expectedFields: short,
			tail: "line-a\nline-b\nline-c\n", truncated: false, expectedPattern: undefined },
		{ name: "oversized manifest fields", event: "output", output: "y".repeat(1_000_000), fields: long, matched: undefined,
			expectedFields: { command: "Z".repeat(cap - 1) + "…", title: "T".repeat(cap - 1) + "…", cwd: "/path/" + "C".repeat(cap - 7) + "…", notifyPattern: "P".repeat(cap - 1) + "…", dedupeKey: "D".repeat(cap - 1) + "…", logFile: "/tmp/" + "L".repeat(cap - 6) + "…" },
			tail: "[...truncated]\n" + "y".repeat(DEFAULT_OUTPUT_ALERT_MAX_CHARS), truncated: true, expectedPattern: undefined },
		{ name: "oversized matched pattern", event: "output", output: "y".repeat(1_000), fields: { ...short, notifyPattern: "P".repeat(100_000) }, matched: "P".repeat(100_000),
			expectedFields: { ...short, notifyPattern: "P".repeat(cap - 1) + "…" }, tail: "y".repeat(1_000), truncated: false, expectedPattern: "P".repeat(cap - 1) + "…" },
	] as const;
	expect.assertions(rows.length + 1);
	expect(rows.length).toBeGreaterThan(0);
	for (const row of rows) {
		const task = fakeTask({ ...row.fields, id: "bg-7", notifyOnOutput: true, status: row.event === "exit" ? "completed" : "running", procIdent: fakeIdent(4242),
			wakeEvents: [], pendingWakes: [], voidedWakeSequences: [], lastOutputDedupeByKey: { key: "hash" } });
		const { deps, messages } = sendDeps(row.output);
		const sent = sendTaskWake(deps, row.event, task, { eventAt: 1_111, matchedPattern: row.matched,
			...(row.event === "output" ? { newOutputTail: row.tail } : {}) });
		const d = messages[0]!.message.details as BackgroundTaskEventDetails;
		const s = d.task;
		const preview = row.fields.command.length > WAKE_CONTENT_COMMAND_MAX_CHARS ? "Z".repeat(WAKE_CONTENT_COMMAND_MAX_CHARS - 1) + "…" : row.fields.command;
		expect({ sent, count: messages.length, tail: d.outputTail, truncated: d.outputTailTruncated, matched: d.matchedPattern,
			content: messages[0]!.message.content,
			fields: { command: s.command, title: s.title, cwd: s.cwd, notifyPattern: s.notifyPattern, dedupeKey: s.dedupeKey, logFile: s.logFile },
			omitted: ["wakeEvents", "pendingWakes", "voidedWakeSequences", "lastOutputDedupeByKey", "procIdent"].filter((key) => key in s),
			newTailKeys: Object.keys(d).filter((key) => key === "newOutputTail"),
		}, row.name).toStrictEqual({ sent: true, count: 1, tail: row.tail, truncated: row.truncated, matched: row.expectedPattern,
			content: expect.stringContaining(preview),
			fields: row.expectedFields, omitted: [], newTailKeys: [] });
	}
});

test("wake payload byte and character bounds", () => {
	const rows = [
		{ name: "details bytes", measure: "details", limit: 4_096, pattern: false },
		{ name: "wrapped message bytes", measure: "message", limit: 4_096, pattern: false },
		{ name: "matched pattern message bytes", measure: "message", limit: 4_096, pattern: true },
		{ name: "command content characters", measure: "content", limit: WAKE_CONTENT_COMMAND_MAX_CHARS + 128, pattern: false },
		{ name: "overlong command run is absent", measure: "forbidden", limit: WAKE_CONTENT_COMMAND_MAX_CHARS + 1, pattern: false },
	] as const;
	expect.assertions(rows.length + 1);
	expect(rows.length).toBeGreaterThan(0);
	for (const row of rows) {
		const task = fakeTask({ id: "bg-7", notifyOnOutput: true, command: "Z".repeat(100_000), title: "T".repeat(2_000), cwd: "C".repeat(2_000),
			notifyPattern: "P".repeat(2_000), dedupeKey: "D".repeat(2_000), logFile: "L".repeat(2_000) });
		const { deps, messages } = sendDeps("y".repeat(row.pattern ? 1_000 : 1_000_000));
		sendTaskWake(deps, "output", task, { eventAt: 1_111, matchedPattern: row.pattern ? "P".repeat(100_000) : undefined });
		const message = messages[0]!.message;
		if (row.measure === "forbidden") {
			expect(message.content, row.name).not.toContain("Z".repeat(row.limit));
			continue;
		}
		const value = row.measure === "content" ? (message.content as string).length : Buffer.byteLength(JSON.stringify(
			row.measure === "details" ? message.details : { content: message.content, details: message.details }), "utf8");
		expect(value, row.name).toBeLessThan(row.limit);
	}
});
