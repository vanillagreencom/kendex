// The Monitor tree: how records group into sessions, the session and task
// numbers, the section and collapse rows, the cursor clamp and the empty tree.

import assert from "node:assert/strict";
import test from "node:test";
import { buildMonitorSessionGroups, clampMonitorUiToRows, monitorTaskRowLabel, monitorTreeRows, renderMonitorTree, taskNumberById } from "../extensions/subagent/browser.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";
import { ABSENT, record, stripAnsi, theme, uiState } from "./browser-fixture.js";

const at = (minute: number) => `2026-05-14T05:${String(minute).padStart(2, "0")}:00.000Z`;

// Each group as `type agent [task ids newest first]` with an `active` mark, in tree order.
function groupShape(records: PaneTaskRecord[]): string[] {
	return buildMonitorSessionGroups(records).map((group) => `${group.type} ${group.agent} [${group.records.map((item) => item.taskId).join(",")}]${group.isActive ? " active" : ""}`);
}

const paneFirst = record("reviewer-arch", "p1", at(0), { kind: "pane", paneId: "%9", sessionMode: "new" });
const paneSecond = record("reviewer-arch", "p2", at(1), { kind: "pane", paneId: "%9", status: "running", completedAt: undefined, sessionMode: "resumed" });
const laneFirst = record("rust", "l1", at(2), { kind: "oneshot", sessionKey: "review-issue-123", sessionMode: "resumed" });
const laneSecond = record("rust", "l2", at(3), { kind: "oneshot", sessionKey: "review-issue-123", sessionMode: "resumed" });
const shotFirst = record("reviewer-doc", "s1", at(4), { kind: "oneshot", sessionMode: "fresh" });
const shotSecond = record("reviewer-doc", "s2", at(5), { kind: "oneshot", sessionMode: "fresh" });

// label | records | expect groups in tree order
const groupRows: Array<[string, PaneTaskRecord[], string[]]> = [
	["pane by pane id, lane by session key, one-shots alone; newest invocation first", [paneFirst, paneSecond, laneFirst, laneSecond, shotFirst, shotSecond], [
		"bg-one-shot reviewer-doc [s2]",
		"bg-one-shot reviewer-doc [s1]",
		"bg-lane rust [l2,l1]",
		"pane reviewer-arch [p2,p1] active",
	]],
	["a pane without a pane id groups by its transcript path", [
		record("planner", "t1", at(0), { kind: "pane", transcriptPath: "/tmp/pi-runtime/sessions/planner.jsonl" }),
		record("planner", "t2", at(1), { kind: "pane", transcriptPath: "/tmp/pi-runtime/sessions/planner.jsonl" }),
		record("reviewer-arch", "t3", at(2), { kind: "pane", transcriptPath: "/tmp/pi-runtime/sessions/reviewer-arch.jsonl" }),
	], ["pane reviewer-arch [t3]", "pane planner [t2,t1]"]],
	["a record with no kind and a blank session key is a one-shot", [{ taskId: "c1", agent: "reviewer-error", task: "Inspect errors", status: "completed", createdAt: at(0), sessionKey: "" } as PaneTaskRecord], ["bg-one-shot reviewer-error [c1]"]],
	["order follows the newest invocation, never updatedAt", [
		record("planner", "old-active", at(0), { kind: "oneshot", status: "running", completedAt: undefined, updatedAt: at(30) }),
		record("reviewer-doc", "newest-completed", at(20), { kind: "oneshot", updatedAt: at(21) }),
		record("reviewer-test", "new-active", at(10), { kind: "oneshot", status: "running", completedAt: undefined, updatedAt: at(11) }),
		record("rust", "pane-old", at(30), { kind: "pane", paneId: "%9", status: "running", completedAt: undefined, updatedAt: at(59) }),
		record("rust", "pane-new", at(35), { kind: "pane", paneId: "%9", status: "running", completedAt: undefined, updatedAt: at(36) }),
	], ["pane rust [pane-new,pane-old] active", "bg-one-shot reviewer-doc [newest-completed]", "bg-one-shot reviewer-test [new-active] active", "bg-one-shot planner [old-active] active"]],
	["a record missing its agent is dropped", [record("", "x1", at(0)), shotFirst], ["bg-one-shot reviewer-doc [s1]"]],
];

test("session grouping", () => {
	for (const [label, records, expect] of groupRows) {
		assert.deepEqual(groupShape(records), expect, label);
	}
});

test("a group's latestAt is its newest invocation", () => {
	const group = buildMonitorSessionGroups([
		record("rust", "pane-old", at(30), { kind: "pane", paneId: "%9", updatedAt: at(59) }),
		record("rust", "pane-new", at(35), { kind: "pane", paneId: "%9", updatedAt: at(36) }),
	])[0]!;
	assert.equal(group.latestAt, at(35));
});

const shotA = record("reviewer-arch", "reviewer-arch-1700000000-11111111", at(0), { kind: "oneshot", sessionMode: "fresh" });
const shotB = record("reviewer-arch", "reviewer-arch-1700000120-77abfc41", at(2), { kind: "oneshot", sessionMode: "fresh" });
const paneA = record("planner", "planner-1700000180-aaaaaaaa", at(3), { kind: "pane", paneId: "%1" });
const paneB = record("planner", "planner-1700000240-bbbbbbbb", at(4), { kind: "pane", paneId: "%1" });
const numbered = [shotB, shotA, paneB, paneA];

test("task numbers restart per session; repeat launches number the sessions", () => {
	const numbers = taskNumberById(numbered);
	const groups = buildMonitorSessionGroups(numbered);
	const sessionNumber = (id: string) => groups.find((group) => group.records[0]?.taskId === id)?.sessionNumber ?? ABSENT;
	assert.deepEqual(
		[numbers.get(shotA.taskId), numbers.get(shotB.taskId), numbers.get(paneA.taskId), numbers.get(paneB.taskId), sessionNumber(shotA.taskId), sessionNumber(shotB.taskId), sessionNumber(paneB.taskId)],
		[1, 1, 1, 2, 1, 2, ABSENT],
	);
});

// label | record | number | expect row label
const labelRows: Array<[string, PaneTaskRecord, number | undefined, string]> = [
	["#1 is suppressed", paneA, 1, "· 0s"],
	["#2 is shown", paneB, 2, "#2 · 0s"],
	["no number is suppressed", paneA, undefined, "· 0s"],
	["a just-started running task reads <1m, minute-granular", record("planner", "planner-now", new Date().toISOString(), { kind: "pane", status: "running", completedAt: undefined }), 1, "· <1m"],
];

test("task row label", () => {
	for (const [label, item, number, expect] of labelRows) {
		assert.equal(monitorTaskRowLabel(item, new Map(number ? [[item.taskId, number]] : [])), expect, label);
	}
});

const running = record("planner", "planner-1700000000-aaaaaaaa", at(0), { kind: "pane", paneId: "%1", status: "running", completedAt: undefined, sessionMode: "resumed" });
const done = record("reviewer-doc", "reviewer-doc-1700000060-bbbbbbbb", at(1), { kind: "oneshot", status: "completed", sessionMode: "fresh" });
const unknown = record("reviewer-error", "reviewer-error-1700000120-cccccccc", at(2), { kind: "oneshot", status: "unknown", sessionMode: "fresh" });
const threeGroups = buildMonitorSessionGroups([running, done, unknown]);
const firstSessionKey = threeGroups[0]!.id;

// Each tree row as `kind label|agent|task id`, with `collapsed` on a collapsed section.
function rowShape(rows: ReturnType<typeof monitorTreeRows>): string[] {
	return rows.map((row) => row.kind === "section" ? `section ${row.label}${row.collapsed ? " collapsed" : ""}` : row.kind === "session" ? `session ${row.group.agent}` : `task ${row.record.taskId}`);
}

// label | collapsed sections | collapsed sessions | expect rows
const treeRows: Array<[string, string[], string[], string[]]> = [
	["active and completed sections, sessions expanded", [], [], [
		"section Active (2)", "session reviewer-error", `task ${unknown.taskId}`, "session planner", `task ${running.taskId}`,
		"section Completed (1)", "session reviewer-doc", `task ${done.taskId}`,
	]],
	["a collapsed session hides its tasks", [], [firstSessionKey], [
		"section Active (2)", "session reviewer-error", "session planner", `task ${running.taskId}`,
		"section Completed (1)", "session reviewer-doc", `task ${done.taskId}`,
	]],
	["a collapsed section hides its sessions", ["active"], [], [
		"section Active (2) collapsed",
		"section Completed (1)", "session reviewer-doc", `task ${done.taskId}`,
	]],
];

test("tree rows", () => {
	for (const [label, sections, sessions, expect] of treeRows) {
		assert.deepEqual(rowShape(monitorTreeRows(threeGroups, new Set(sections as any), new Set(sessions))), expect, label);
	}
});

const sixRows = monitorTreeRows(buildMonitorSessionGroups([running, done]));

// label | selected | scroll | listRows | expect `selected scroll`
const clampRows: Array<[string, number, number, number, string]> = [
	["a section row stays selectable; a runaway scroll returns to it", 3, 99, 10, "3 0"],
	["a runaway selection lands on the last row and scrolls it into view", 99, 0, 2, "5 4"],
	["a selection above the scroll pulls the scroll up", 1, 4, 2, "1 1"],
];

test("cursor clamp", () => {
	assert.equal(sixRows.length, 6);
	for (const [label, selected, scroll, listRows, expect] of clampRows) {
		const ui = uiState({ monitorSelected: selected, monitorScroll: scroll });
		clampMonitorUiToRows(ui, sixRows, listRows);
		assert.equal(`${ui.monitorSelected} ${ui.monitorScroll}`, expect, label);
	}
});

test("the empty tree is the title with a zero count and the dispatch hint", () => {
	const lines = renderMonitorTree([], [], new Set(), uiState({ tab: "monitor", pane: "list" }), 120, theme as any, 10).map((line) => stripAnsi(line).replace(/\s+/g, " ").trim());
	assert.deepEqual(lines, ["Sessions (0)", "", "No tasks yet. Dispatch via `subagent` or `/agents`."]);
});

test("the rendered tree prints session and task rows without #1", () => {
	const lines = renderMonitorTree(monitorTreeRows(buildMonitorSessionGroups(numbered)), numbered, new Set(), uiState({ tab: "monitor", pane: "list" }), 180, theme as any, 20).map((line) => stripAnsi(line).trim());
	// The relative time after the task count and the status icon before `Task` are read elsewhere.
	assert.deepEqual(lines.filter((line) => /^[▶▼]/.test(line) || /Task/.test(line)).map((line) => line.replace(/(\d+ tasks?) · .*$/, "$1").replace(/^\S+ Task/, "Task")), [
		"▼ Active (0)",
		"▼ Completed (3)",
		"▼ planner · 2 tasks",
		"Task #2 · 0s · completed",
		"Task · 0s · completed",
		"▼ reviewer-arch · 1 task",
		"Task · 0s · completed",
		"▼ reviewer-arch · 1 task",
		"Task · 0s · completed",
	]);
});
