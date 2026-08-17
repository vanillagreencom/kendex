import assert from "node:assert/strict";
import test from "node:test";
import {
	formatLocalDateTime,
	formatRunDuration,
	monitorTaskRowLabel,
	monitorTaskRunTime,
} from "../extensions/subagent/browser/monitor-tree.js";
import { traceViewerItems } from "../extensions/subagent/browser/monitor-task-detail.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";

function record(overrides: Partial<PaneTaskRecord>): PaneTaskRecord {
	return {
		agent: "reviewer",
		createdAt: new Date().toISOString(),
		status: "running",
		task: "review the diff",
		taskId: "task-1",
		...overrides,
	};
}

test("running task row shows elapsed run-time, never clock-of-day", () => {
	const createdAt = new Date(Date.now() - 5 * 60_000).toISOString();
	const rec = record({ createdAt, updatedAt: new Date().toISOString() });
	const label = monitorTaskRowLabel(rec, new Map());
	assert.equal(label, "· 5m");
});

test("updatedAt never moves the displayed time", () => {
	const createdAt = new Date(Date.now() - 12 * 60_000).toISOString();
	const early = monitorTaskRunTime(record({ createdAt, updatedAt: "2001-01-01T01:01:00Z" }));
	const late = monitorTaskRunTime(record({ createdAt, updatedAt: new Date().toISOString() }));
	assert.equal(early, late);
	assert.equal(early, "12m");
});

test("terminal task shows total createdAt→completedAt duration, stable across polls", () => {
	const createdAt = "2026-03-24T23:59:33Z";
	const completedAt = "2026-03-25T00:16:58Z";
	const rec = record({ completedAt, createdAt, status: "completed", updatedAt: new Date().toISOString() });
	assert.equal(monitorTaskRunTime(rec), "17m");
	assert.equal(monitorTaskRowLabel(rec, new Map([["task-1", 2]])), "#2 · 17m");
});

test("terminal task without completedAt shows a dash, not updatedAt", () => {
	const rec = record({ createdAt: "2026-03-24T23:59:33Z", status: "failed", updatedAt: new Date().toISOString() });
	assert.equal(monitorTaskRunTime(rec), "—");
});

test("running sub-minute elapsed is minute-granular", () => {
	const rec = record({ createdAt: new Date(Date.now() - 20_000).toISOString() });
	assert.equal(monitorTaskRunTime(rec), "<1m");
});

test("task Summary carries Duration only once terminal", async () => {
	const done = record({ completedAt: "2026-03-25T00:16:58Z", createdAt: "2026-03-24T23:59:33Z", status: "completed" });
	const live = record({ createdAt: new Date(Date.now() - 5 * 60_000).toISOString() });
	const doneItems = await traceViewerItems(done);
	const liveItems = await traceViewerItems(live);
	assert.match(doneItems[0]!.text, /Duration {2}17m(\n|$)/);
	assert.doesNotMatch(liveItems[0]!.text, /Duration/);
});

test("formatRunDuration shapes", () => {
	assert.equal(formatRunDuration("2026-03-24T00:00:00Z", "2026-03-24T01:01:40Z"), "1h 01m");
	assert.equal(formatRunDuration("2026-03-24T00:00:00Z", "2026-03-24T00:00:45Z"), "45s");
	assert.equal(formatRunDuration("2026-03-24T01:00:00Z", "2026-03-24T00:00:00Z"), "—");
	assert.equal(formatRunDuration("not-a-date", "2026-03-24T00:00:00Z"), "—");
	assert.equal(formatRunDuration(undefined), "—");
});

test("formatLocalDateTime renders local wall time, not UTC ISO", () => {
	const iso = "2026-03-24T23:59:33Z";
	const date = new Date(iso);
	const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
	const year = date.getFullYear() === new Date().getFullYear() ? "" : ` ${date.getFullYear()}`;
	const expected = `${months[date.getMonth()]} ${date.getDate()}${year}, ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
	const rendered = formatLocalDateTime(iso);
	assert.equal(rendered, expected);
	assert.doesNotMatch(rendered, /Z$/);
	assert.doesNotMatch(rendered, /T\d{2}/);
	assert.equal(formatLocalDateTime("garbage"), "—");
	assert.equal(formatLocalDateTime(undefined), "—");
});
