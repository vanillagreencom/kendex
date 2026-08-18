import assert from "node:assert/strict";
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
	buildMonitorSessionGroups,
	liveDashboardSignature,
	mergeLiveDashboardItems,
	monitorTreeRows,
	restoreMonitorSelectionByKey,
} from "../extensions/subagent/browser.js";
import {
	claimSummaryBackfill,
	claimTranscriptParse,
	patchTaskRecordUsage,
	pruneTranscriptFingerprints,
	refreshTranscriptUsage,
	taskNeedsTranscriptUsageRestore,
	transcriptUsageRefreshSnapshot,
} from "../extensions/subagent/index.js";
import { sortedMonitorRecords } from "../extensions/subagent/task-records.js";
import type { AgentBrowserUiState, PaneTaskRecord, PaneTaskRegistry, SubagentDashboardItem, UsageStats } from "../extensions/subagent/types.js";

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

test("transcript usage refresh keeps terminal tasks and evicts pruned fingerprints", () => {
	const transcriptPath = "/runtime/shared-pane.jsonl";
	const fingerprints = new Map([
		["planner-1", "planner-fingerprint"],
		["reviewer-2", "reviewer-fingerprint"],
		["stale-3", "stale-fingerprint"],
	]);
	const snapshot = transcriptUsageRefreshSnapshot(
		[
			item("planner", "planner-1", "2026-05-14T05:00:00.000Z", { transcriptPath }),
			item("reviewer", "reviewer-2", "2026-05-14T05:02:00.000Z", { status: "completed", transcriptPath }),
		],
		fingerprints,
	);

	assert.deepEqual(snapshot.map(({ item: entry }) => entry.taskId), ["planner-1", "reviewer-2"]);
	assert.deepEqual([...fingerprints.keys()], ["planner-1", "reviewer-2"]);
});

test("terminal transcript usage restore does not trust an existing partial total", () => {
	const partialUsage: UsageStats = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 1 };
	assert.equal(taskNeedsTranscriptUsageRestore({ status: "completed", transcriptPath: "/runtime/task.jsonl", usage: partialUsage }), true);
	assert.equal(taskNeedsTranscriptUsageRestore({ status: "running", transcriptPath: "/runtime/task.jsonl" }), false);
});

test("usage persistence remains retryable until the task record exists", () => {
	const usage: UsageStats = { input: 2, output: 3, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 5, turns: 1 };
	const registry = registryOf();
	assert.equal(patchTaskRecordUsage(registry, "planner-1", { usage }), false);

	registry["planner-1"] = record("planner", "planner-1", "2026-05-14T05:00:00.000Z");
	assert.equal(patchTaskRecordUsage(registry, "planner-1", { usage, model: "test-model" }), true);
	assert.deepEqual(registry["planner-1"]?.usage, usage);
	assert.equal(registry["planner-1"]?.model, "test-model");
});

test("terminal usage refresh stops re-parsing a failed persistence and rearms on appended final usage", async () => {
	const runtimeRoot = mkdtempSync(join(tmpdir(), "subagent-usage-refresh-"));
	const transcriptPath = join(runtimeRoot, "task.jsonl");
	const completed = item("planner", "planner-1", "2026-05-14T05:02:00.000Z", { status: "completed", transcriptPath });
	const fingerprints = new Map([["stale-2", "stale-fingerprint"]]);
	const persistedInputs: number[] = [];
	const persistUsage = async (_taskId: string, parsed: { usage: UsageStats }) => {
		persistedInputs.push(parsed.usage.input);
		return false;
	};
	try {
		writeFileSync(transcriptPath, JSON.stringify({ event: { type: "message_end", message: { usage: { input: 2, output: 3 } } } }));
		await refreshTranscriptUsage([completed], fingerprints, persistUsage);
		assert.deepEqual(persistedInputs, [2]);
		assert.equal(fingerprints.has("planner-1"), true);
		assert.equal(fingerprints.has("stale-2"), false);

		await refreshTranscriptUsage([completed], fingerprints, persistUsage);
		assert.deepEqual(persistedInputs, [2]);

		appendFileSync(transcriptPath, `\n${JSON.stringify({ event: { type: "message_end", message: { usage: { input: 5, output: 7 } } } })}`);
		await refreshTranscriptUsage([completed], fingerprints, persistUsage);
		assert.deepEqual(persistedInputs, [2, 7]);
		await refreshTranscriptUsage([completed], fingerprints, persistUsage);
		assert.deepEqual(persistedInputs, [2, 7]);
	} finally {
		rmSync(runtimeRoot, { force: true, recursive: true });
	}
});

test("terminal transcripts whose usage never persists are parsed once per task, not once per poll", async () => {
	const runtimeRoot = mkdtempSync(join(tmpdir(), "subagent-usage-poll-cost-"));
	const taskCount = 5;
	const pollCount = 20;
	const completed = Array.from({ length: taskCount }, (_unused, index) => {
		const transcriptPath = join(runtimeRoot, `task-${index}.jsonl`);
		writeFileSync(transcriptPath, JSON.stringify({ event: { type: "message_end", message: { usage: { input: index + 1, output: 1 } } } }));
		return item("planner", `planner-${index}`, "2026-05-14T05:02:00.000Z", { status: "completed", transcriptPath });
	});
	const fingerprints = new Map<string, string>();
	let persistCalls = 0;
	const persistUsage = async () => {
		persistCalls += 1;
		return false;
	};
	try {
		for (let poll = 0; poll < pollCount; poll += 1) await refreshTranscriptUsage(completed, fingerprints, persistUsage);

		assert.equal(persistCalls, taskCount);
	} finally {
		rmSync(runtimeRoot, { force: true, recursive: true });
	}
});

test("a transcript parse is claimed once per byte change and never for a missing file", async () => {
	const runtimeRoot = mkdtempSync(join(tmpdir(), "subagent-claim-parse-"));
	const transcriptPath = join(runtimeRoot, "task.jsonl");
	const fingerprints = new Map<string, string>();
	try {
		assert.equal(await claimTranscriptParse(transcriptPath, "planner-1", fingerprints), false);
		assert.equal(fingerprints.size, 0);

		writeFileSync(transcriptPath, "first\n");
		assert.equal(await claimTranscriptParse(transcriptPath, "planner-1", fingerprints), true);
		assert.equal(await claimTranscriptParse(transcriptPath, "planner-1", fingerprints), false);

		appendFileSync(transcriptPath, "second\n");
		assert.equal(await claimTranscriptParse(transcriptPath, "planner-1", fingerprints), true);
		assert.equal(await claimTranscriptParse(transcriptPath, "planner-1", fingerprints), false);
	} finally {
		rmSync(runtimeRoot, { force: true, recursive: true });
	}
});

test("summary backfill of a terminal transcript is attempted once per task, not once per poll", async () => {
	const runtimeRoot = mkdtempSync(join(tmpdir(), "subagent-backfill-poll-cost-"));
	const taskCount = 3;
	const pollCount = 20;
	// These records stay backfill-eligible for every poll — a failing backfill
	// never writes a summary — so only the claim can bound the transcript reads.
	const backfillable = Array.from({ length: taskCount }, (_unused, index) => {
		const transcriptPath = join(runtimeRoot, `task-${index}.jsonl`);
		writeFileSync(transcriptPath, JSON.stringify({ event: { type: "message_end", message: { usage: { input: 1, output: 1 } } } }));
		return record("planner", `planner-${index}`, "2026-05-14T05:00:00.000Z", { status: "completed", transcriptPath });
	});
	const summarized = record("scout", "scout-9", "2026-05-14T05:00:00.000Z", { status: "completed", summary: "done", transcriptPath: backfillable[0]!.transcriptPath });
	const running = record("rust", "rust-8", "2026-05-14T05:00:00.000Z", { transcriptPath: backfillable[0]!.transcriptPath });
	const transcriptless = record("doc", "doc-7", "2026-05-14T05:00:00.000Z", { status: "completed" });
	const fingerprints = new Map<string, string>();
	let attempts = 0;
	try {
		for (let poll = 0; poll < pollCount; poll += 1) {
			for (const candidate of [...backfillable, summarized, running, transcriptless]) {
				if (await claimSummaryBackfill(candidate, fingerprints)) attempts += 1;
			}
		}
		assert.equal(attempts, taskCount);
		assert.deepEqual([...fingerprints.keys()], ["planner-0", "planner-1", "planner-2"]);

		appendFileSync(backfillable[1]!.transcriptPath!, `\n${JSON.stringify({ event: { type: "message_end", message: { usage: { input: 2, output: 2 } } } })}`);
		for (const candidate of backfillable) {
			if (await claimSummaryBackfill(candidate, fingerprints)) attempts += 1;
		}

		assert.equal(attempts, taskCount + 1);
	} finally {
		rmSync(runtimeRoot, { force: true, recursive: true });
	}
});

test("fingerprint pruning drops tasks that left the registry", () => {
	const fingerprints = new Map([
		["planner-1", "planner-fingerprint"],
		["stale-3", "stale-fingerprint"],
	]);

	pruneTranscriptFingerprints(fingerprints, new Set(["planner-1"]));

	assert.deepEqual([...fingerprints.keys()], ["planner-1"]);
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
