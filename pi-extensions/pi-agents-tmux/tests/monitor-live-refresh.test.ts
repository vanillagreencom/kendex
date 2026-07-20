import assert from "node:assert/strict";
import test from "node:test";
import {
	buildMonitorSessionGroups,
	liveDashboardSignature,
	mergeLiveDashboardItems,
	monitorTreeRows,
	restoreMonitorSelectionByKey,
} from "../extensions/subagent/browser.js";
import { sortedMonitorRecords } from "../extensions/subagent/task-records.js";
import type { AgentBrowserUiState, PaneTaskRecord, PaneTaskRegistry, SubagentDashboardItem } from "../extensions/subagent/types.js";

function record(agent: string, taskId: string, createdAt: string, extra: Partial<PaneTaskRecord> = {}): PaneTaskRecord {
	return { agent, createdAt, status: "running", task: `${agent} work`, taskId, ...extra };
}

function item(agent: string, taskId: string, updatedAt: string, extra: Partial<SubagentDashboardItem> = {}): SubagentDashboardItem {
	return { agent, kind: "oneshot", startedAt: updatedAt, status: "running", task: `${agent} work`, taskId, updatedAt, ...extra };
}

function registryOf(...records: PaneTaskRecord[]): PaneTaskRegistry {
	return Object.fromEntries(records.map((entry) => [entry.taskId, entry]));
}

function uiState(overrides: Partial<AgentBrowserUiState> = {}): AgentBrowserUiState {
	return {
		inspectorScroll: 0,
		monitorScroll: 0,
		monitorSelected: 0,
		monitorSubtab: 0,
		pane: "list",
		scope: "both",
		scroll: 0,
		selected: 0,
		tab: "monitor",
		...overrides,
	};
}

function rowsFor(registry: PaneTaskRegistry, items: SubagentDashboardItem[]) {
	return monitorTreeRows(buildMonitorSessionGroups(sortedMonitorRecords(mergeLiveDashboardItems(registry, items))));
}

test("Monitor refresh surfaces an agent started after the snapshot was taken", () => {
	const snapshot = registryOf(record("planner", "planner-1", "2026-05-14T05:00:00.000Z"));
	const live = [item("planner", "planner-1", "2026-05-14T05:00:30.000Z"), item("reviewer-arch", "reviewer-arch-9", "2026-05-14T05:01:00.000Z")];

	const merged = mergeLiveDashboardItems(snapshot, live);

	assert.deepEqual(Object.keys(merged).sort(), ["planner-1", "reviewer-arch-9"]);
	assert.equal(merged["reviewer-arch-9"]?.status, "running");
	assert.equal(merged["reviewer-arch-9"]?.agent, "reviewer-arch");
	assert.equal(merged["reviewer-arch-9"]?.createdAt, "2026-05-14T05:01:00.000Z");
});

test("Monitor refresh transitions a finished agent off running and keeps snapshot-only detail", () => {
	const snapshot = registryOf(record("planner", "planner-1", "2026-05-14T05:00:00.000Z", { filesChanged: ["a.ts"], summary: "persisted summary" }));
	const live = [item("planner", "planner-1", "2026-05-14T05:02:00.000Z", { completedAt: "2026-05-14T05:02:00.000Z", status: "completed" })];

	const merged = mergeLiveDashboardItems(snapshot, live);

	assert.equal(merged["planner-1"]?.status, "completed");
	assert.equal(merged["planner-1"]?.completedAt, "2026-05-14T05:02:00.000Z");
	// Completion detail never reaches a dashboard item, so the snapshot must win there.
	assert.equal(merged["planner-1"]?.summary, "persisted summary");
	assert.deepEqual(merged["planner-1"]?.filesChanged, ["a.ts"]);
	assert.equal(merged["planner-1"]?.createdAt, "2026-05-14T05:00:00.000Z");

	const completedSection = monitorTreeRows(buildMonitorSessionGroups(sortedMonitorRecords(merged))).find((row) => row.kind === "section" && row.section === "completed");
	assert.equal(completedSection?.kind === "section" && completedSection.count, 1);
});

test("Monitor refresh maps the dashboard-only waiting status onto queued", () => {
	const merged = mergeLiveDashboardItems({}, [item("planner", "planner-1", "2026-05-14T05:00:00.000Z", { status: "waiting" })]);

	assert.equal(merged["planner-1"]?.status, "queued");
});

test("Live dashboard signature changes on lifecycle moves and is stable otherwise", () => {
	const running = item("planner", "planner-1", "2026-05-14T05:00:00.000Z");
	const base = liveDashboardSignature([running]);

	assert.equal(liveDashboardSignature([running]), base);
	assert.notEqual(liveDashboardSignature([{ ...running, status: "completed" }]), base);
	assert.notEqual(liveDashboardSignature([running, item("scout", "scout-2", "2026-05-14T05:01:00.000Z")]), base);
	// Order is not part of the fingerprint; only the lifecycle content is.
	const pair = [running, item("scout", "scout-2", "2026-05-14T05:01:00.000Z")];
	assert.equal(liveDashboardSignature([...pair].reverse()), liveDashboardSignature(pair));
});

test("Monitor selection stays on the same task when a refresh inserts rows above it", () => {
	const snapshot = registryOf(record("planner", "planner-1", "2026-05-14T05:00:00.000Z"));
	const before = rowsFor(snapshot, [item("planner", "planner-1", "2026-05-14T05:00:00.000Z")]);
	const ui = uiState({ monitorSelected: before.findIndex((row) => row.kind === "task" && row.record.taskId === "planner-1") });
	const selectedKey = before[ui.monitorSelected]?.key;
	assert.ok(selectedKey);

	// A newer agent starts; its session sorts above planner's, shifting every row below it.
	const after = rowsFor(snapshot, [item("planner", "planner-1", "2026-05-14T05:00:00.000Z"), item("scout", "scout-2", "2026-05-14T05:03:00.000Z")]);
	assert.notEqual(after.findIndex((row) => row.key === selectedKey), ui.monitorSelected);

	restoreMonitorSelectionByKey(ui, after, selectedKey);

	const stillSelected = after[ui.monitorSelected];
	assert.equal(stillSelected?.key, selectedKey);
	assert.equal(stillSelected?.kind === "task" && stillSelected.record.taskId, "planner-1");
});

test("Monitor selection survives a task moving from the active to the completed section", () => {
	const snapshot = registryOf(record("planner", "planner-1", "2026-05-14T05:00:00.000Z"));
	const before = rowsFor(snapshot, [item("planner", "planner-1", "2026-05-14T05:00:00.000Z")]);
	const ui = uiState({ monitorSelected: before.findIndex((row) => row.kind === "task" && row.record.taskId === "planner-1") });
	const selectedKey = before[ui.monitorSelected]!.key;

	const after = rowsFor(snapshot, [item("planner", "planner-1", "2026-05-14T05:02:00.000Z", { completedAt: "2026-05-14T05:02:00.000Z", status: "completed" })]);
	restoreMonitorSelectionByKey(ui, after, selectedKey);

	const stillSelected = after[ui.monitorSelected];
	assert.equal(stillSelected?.key, selectedKey);
	assert.equal(stillSelected?.kind === "task" && stillSelected.record.status, "completed");
});

test("Selection restore leaves the cursor put when the previously selected row disappeared", () => {
	const ui = uiState({ monitorSelected: 2 });

	restoreMonitorSelectionByKey(ui, rowsFor(registryOf(record("planner", "planner-1", "2026-05-14T05:00:00.000Z")), []), "gone:missing");

	assert.equal(ui.monitorSelected, 2);
});
