import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import {
	appendBgChatMessages,
	buildMonitorSessionGroups,
	buildAgentRows,
	clampMonitorUiToRows,
	filteredMonitorSessionGroups,
	monitorRecordLabel,
	monitorTreeRows,
	readTranscriptTail,
	renderAgentBrowserTabs,
	renderAgentInspector,
	renderMonitorTree,
	renderMonitorSessionDetail,
	taskNumberById,
	transcriptCompactRows,
	traceViewerItems,
} from "../extensions/subagent/browser.js";
import { renderDashboardWidgetLines } from "../extensions/subagent/dashboard.js";
import { COMPLETION_SUMMARY_UNAVAILABLE, extractLastAssistantTextFromTranscriptContent, oneLinePreview } from "../extensions/subagent/format.js";
import { oneShotTranscriptPath } from "../extensions/subagent/paths.js";
import { formatTaskRecordResult } from "../extensions/subagent/renderers.js";
import { subagentToolRenderers } from "../extensions/subagent/subagent-render.js";
import {
	backfillTaskSummaryFromTranscript,
	readTaskRegistry,
	updateTaskRegistry,
} from "../extensions/subagent/tasks.js";
import type { AgentBrowserUiState, AgentPaneStatus, ChatMessage, PaneTaskRecord, SingleResult, SubagentDashboardItem, SubagentDetails } from "../extensions/subagent/types.js";

const theme = {
	bg: (_tone: string, text: string) => text,
	bold: (text: string) => text,
	fg: (_tone: string, text: string) => text,
	inverse: (text: string) => text,
};

function tempRuntime(): string {
	return mkdtempSync(join(tmpdir(), "pi-agents-dashboard-ux-"));
}

function record(agent: string, taskId: string, createdAt: string, patch: Partial<PaneTaskRecord> = {}): PaneTaskRecord {
	return {
		taskId,
		agent,
		task: `Task for ${agent}`,
		status: "completed",
		createdAt,
		completedAt: createdAt,
		updatedAt: createdAt,
		...patch,
	};
}

function agent(name: string, pane = false, patch: Partial<AgentConfig> = {}): AgentConfig {
	return { name, pane, description: `${name} agent`, systemPrompt: "", source: "project", filePath: `${name}.md`, ...patch };
}

function uiState(patch: Partial<AgentBrowserUiState> = {}): AgentBrowserUiState {
	return {
		inspectorScroll: 0,
		pane: "inspector",
		tab: "agents",
		scope: "both",
		search: "",
		selected: 0,
		scroll: 0,
		agentSubtab: 0,
		activeSelected: 0,
		activeScroll: 0,
		monitorSelected: 0,
		monitorScroll: 0,
		monitorSubtab: 0,
		monitorFilter: "all",
		...patch,
	};
}

function livePaneStatus(agentName: string, patch: Partial<NonNullable<AgentPaneStatus["entry"]>> = {}): AgentPaneStatus {
	return {
		live: true,
		entry: {
			agent: agentName,
			paneId: "%1",
			windowName: `agent-${agentName}`,
			cwd: process.cwd(),
			sessionFile: "/tmp/transcript.jsonl",
			promptFile: "/tmp/prompt.md",
			launcherFile: "/tmp/launcher.sh",
			startedAt: "2026-05-14T05:00:00.000Z",
			...patch,
		},
	};
}

function singleResult(patch: Partial<SingleResult> = {}): SingleResult {
	return {
		agent: "reviewer-arch",
		agentSource: "project",
		exitCode: 0,
		messages: [{ role: "assistant", content: [{ type: "text", text: "done" }], timestamp: Date.now() } as any],
		stderr: "",
		task: "Review architecture.",
		taskId: "reviewer-arch-1700000000-aaaaaaaa",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		...patch,
	};
}

function renderSubagentSingle(result: SingleResult): string {
	const details: SubagentDetails = { mode: "single", agentScope: "project", projectAgentsDir: null, results: [result] };
	return subagentToolRenderers.renderResult({ content: [{ type: "text", text: "done" }], details }, {}, theme, { cwd: process.cwd() }).render(220).join("\n");
}

function dashboardItem(patch: Partial<SubagentDashboardItem> = {}): SubagentDashboardItem {
	return {
		agent: "reviewer-arch",
		kind: "oneshot",
		status: "completed",
		taskId: "reviewer-arch-1700000000-aaaaaaaa",
		updatedAt: "2026-05-14T05:02:00.000Z",
		...patch,
	};
}

test("subagent renderer shows session-mode chips", () => {
	assert.match(renderSubagentSingle(singleResult({ sessionMode: "fresh" })), /completed · bg · fresh/);
	assert.match(renderSubagentSingle(singleResult({ sessionMode: "resumed", sessionKey: "very-long-session-key", sessionKeyExplicit: true })), /completed · bg · lane:very-l…-key/);
	assert.match(renderSubagentSingle(singleResult({ paneId: "%1", paneSessionMode: "new", sessionMode: "new" })), /Queued task · pane · new/);
	assert.match(renderSubagentSingle(singleResult({ paneId: "%1", paneSessionMode: "live", sessionMode: "resumed" })), /Queued task · pane · resumed/);
});

test("session-mode rendering ignores corrupt mode values", async () => {
	assert.match(renderSubagentSingle(singleResult({ sessionMode: "foo" as any })), /completed · bg · ctrl\+o expand/);
	assert.doesNotMatch(renderSubagentSingle(singleResult({ sessionMode: "foo" as any })), / · foo/);

	const dashboard = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ sessionMode: "foo" as any }) } }, theme as any, process.cwd(), 220).join("\n");
	assert.match(dashboard, /completed · bg/);
	assert.doesNotMatch(dashboard, / · foo/);

	const trace = await traceViewerItems(record("reviewer-arch", "reviewer-arch-corrupt-session", "2026-05-14T05:00:00.000Z", { sessionMode: "foo" as any, sessionKey: "feature-x" }));
	assert.doesNotMatch(trace[0]!.text, /^Session\s+/m);
});

test("long sessionKey chip keeps suffix to avoid collisions", () => {
	const first = renderSubagentSingle(singleResult({ sessionMode: "resumed", sessionKey: "feature-x-iss-12345", sessionKeyExplicit: true }));
	const second = renderSubagentSingle(singleResult({ sessionMode: "resumed", sessionKey: "feature-x-iss-12399", sessionKeyExplicit: true }));
	assert.match(first, /lane:featur…2345/);
	assert.match(second, /lane:featur…2399/);
	assert.notEqual(first.match(/lane:[^ ·\n]+/)?.[0], second.match(/lane:[^ ·\n]+/)?.[0]);
});

test("dashboard mini widget shows session-mode chips", () => {
	const fresh = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ sessionMode: "fresh" }) } }, theme as any, process.cwd(), 220).join("\n");
	assert.match(fresh, /completed · bg · fresh/);

	const lane = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ sessionMode: "resumed", sessionKey: "very-long-session-key" }) } }, theme as any, process.cwd(), 220).join("\n");
	assert.match(lane, /completed · bg · lane:very-l…-key/);

	const paneNew = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ kind: "pane", sessionMode: "new" }) } }, theme as any, process.cwd(), 220).join("\n");
	assert.match(paneNew, /completed · pane · new/);

	const paneResumed = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ kind: "pane", sessionMode: "resumed" }) } }, theme as any, process.cwd(), 220).join("\n");
	assert.match(paneResumed, /completed · pane · resumed/);
});

test("trace summary includes session line only when sessionMode is persisted", async () => {
	const withSession = await traceViewerItems(record("reviewer-arch", "reviewer-arch-session", "2026-05-14T05:00:00.000Z", { sessionMode: "resumed", sessionKey: "feature-x" }));
	assert.match(withSession[0]!.text, /^Session\s+resumed · lane: feature-x$/m);

	const withoutSession = await traceViewerItems(record("reviewer-arch", "reviewer-arch-no-session", "2026-05-14T05:00:00.000Z"));
	assert.doesNotMatch(withoutSession[0]!.text, /^Session\s+/m);
});

test("completed one-shot record backfills summary from transcript final assistant text", async () => {
	const runtimeRoot = tempRuntime();
	const taskId = "reviewer-arch-1700000000-77abfc41";
	const transcriptPath = oneShotTranscriptPath(runtimeRoot, "reviewer-arch", taskId);
	mkdirSync(dirname(transcriptPath), { recursive: true });
	writeFileSync(transcriptPath, [
		JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "Early output" }] } }),
		JSON.stringify({ ts: "2026-05-14T05:02:00.000Z", event: { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "Final summary\nwith details" }] } } }),
	].join("\n"));
	await updateTaskRegistry(runtimeRoot, (records) => {
		records[taskId] = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { transcriptPath });
	});

	const result = await backfillTaskSummaryFromTranscript(runtimeRoot, (await readTaskRegistry(runtimeRoot))[taskId]!);
	assert.equal(result.updated, true);
	assert.equal(result.record.summary, "Final summary\nwith details");
	assert.equal((await readTaskRegistry(runtimeRoot))[taskId]?.summary, "Final summary\nwith details");
});

test("summary backfill skips corrupt transcript without changing record", async () => {
	const runtimeRoot = tempRuntime();
	const taskId = "reviewer-arch-corrupt";
	const transcriptPath = join(runtimeRoot, "corrupt.jsonl");
	writeFileSync(transcriptPath, "{not json\n");
	const taskRecord = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { transcriptPath });
	await updateTaskRegistry(runtimeRoot, (records) => { records[taskId] = taskRecord; });

	const result = await backfillTaskSummaryFromTranscript(runtimeRoot, taskRecord);
	assert.equal(result.updated, false);
	assert.deepEqual(result.record, taskRecord);
	assert.deepEqual((await readTaskRegistry(runtimeRoot))[taskId], taskRecord);
});

test("summary backfill skips missing transcript without changing record", async () => {
	const runtimeRoot = tempRuntime();
	const taskId = "reviewer-arch-missing";
	const taskRecord = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { transcriptPath: join(runtimeRoot, "missing.jsonl") });
	await updateTaskRegistry(runtimeRoot, (records) => { records[taskId] = taskRecord; });

	const result = await backfillTaskSummaryFromTranscript(runtimeRoot, taskRecord);
	assert.equal(result.updated, false);
	assert.deepEqual(result.record, taskRecord);
	assert.deepEqual((await readTaskRegistry(runtimeRoot))[taskId], taskRecord);
});

test("blank summary with valid transcript but no assistant text is removed", async () => {
	const runtimeRoot = tempRuntime();
	const taskId = "reviewer-arch-blank";
	const transcriptPath = join(runtimeRoot, "no-assistant.jsonl");
	writeFileSync(transcriptPath, JSON.stringify({ type: "message", message: { role: "user", content: "hello" } }));
	const taskRecord = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { summary: "   ", transcriptPath });
	await updateTaskRegistry(runtimeRoot, (records) => { records[taskId] = taskRecord; });

	const result = await backfillTaskSummaryFromTranscript(runtimeRoot, taskRecord);
	assert.equal(result.updated, true);
	assert.equal(Object.prototype.hasOwnProperty.call(result.record, "summary"), false);
	assert.equal(Object.prototype.hasOwnProperty.call((await readTaskRegistry(runtimeRoot))[taskId]!, "summary"), false);
});

test("existing nonblank summary is not overwritten by transcript backfill", async () => {
	const runtimeRoot = tempRuntime();
	const taskId = "reviewer-arch-existing";
	const transcriptPath = join(runtimeRoot, "assistant.jsonl");
	writeFileSync(transcriptPath, JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "transcript text" }] } }));
	const taskRecord = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { summary: "some text", transcriptPath });
	await updateTaskRegistry(runtimeRoot, (records) => { records[taskId] = taskRecord; });

	const result = await backfillTaskSummaryFromTranscript(runtimeRoot, taskRecord);
	assert.equal(result.updated, false);
	assert.equal(result.record.summary, "some text");
	assert.equal((await readTaskRegistry(runtimeRoot))[taskId]?.summary, "some text");
});

test("chat completion synthesis never echoes delegation prompt and annotates task id data", () => {
	const taskId = "reviewer-test-1700000000-77abfc41";
	const item: SubagentDashboardItem = {
		agent: "reviewer-test",
		kind: "oneshot",
		message: "Check test coverage",
		status: "completed",
		task: "Check test coverage",
		taskId,
		startedAt: "2026-05-14T05:00:00.000Z",
		completedAt: "2026-05-14T05:02:00.000Z",
		updatedAt: "2026-05-14T05:02:00.000Z",
	};
	const messages: ChatMessage[] = [];
	appendBgChatMessages(messages, [item]);

	const completion = messages.find((message) => message.kind === "completion");
	assert.equal(completion?.body, COMPLETION_SUMMARY_UNAVAILABLE);
	assert.equal(completion?.taskId, taskId);
});

test("full persisted one-shot summary feeds chat history and result formatting", async () => {
	const taskId = "reviewer-arch-1700000000-77abfc41";
	const longSummary = Array.from({ length: 80 }, (_, index) => `finding-${index}`).join(" ");
	assert.ok(longSummary.length > 600);
	const taskRecord = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", {
		summary: longSummary,
		transcriptPath: "/tmp/reviewer-arch.jsonl",
	});
	const item: SubagentDashboardItem = {
		agent: "reviewer-arch",
		kind: "oneshot",
		message: oneLinePreview(longSummary, 120),
		status: "completed",
		task: taskRecord.task,
		taskId,
		startedAt: taskRecord.createdAt,
		completedAt: taskRecord.completedAt,
		updatedAt: taskRecord.updatedAt!,
	};
	const messages: ChatMessage[] = [];
	appendBgChatMessages(messages, [item], { [taskId]: taskRecord });

	assert.equal(messages.find((message) => message.kind === "completion")?.body, longSummary);
	assert.match((await traceViewerItems(taskRecord))[0]!.text, new RegExp(longSummary.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
	assert.match(formatTaskRecordResult(taskRecord), new RegExp(longSummary.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});

test("persisted summary equal to task text is not suppressed", () => {
	const taskId = "reviewer-arch-echo";
	const task = "repeat this exact sentence";
	const taskRecord = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { task, summary: task });
	const item: SubagentDashboardItem = {
		agent: "reviewer-arch",
		kind: "oneshot",
		message: task,
		messageProvenance: "persisted",
		status: "completed",
		task,
		taskId,
		startedAt: taskRecord.createdAt,
		completedAt: taskRecord.completedAt,
		updatedAt: taskRecord.updatedAt!,
	};
	const messages: ChatMessage[] = [];
	appendBgChatMessages(messages, [item], { [taskId]: taskRecord });

	assert.equal(messages.find((message) => message.kind === "completion")?.body, task);
});

test("task echo fallback is suppressed but different fallback renders", () => {
	const taskId = "reviewer-arch-fallback";
	const task = "review this exact text";
	const echoItem: SubagentDashboardItem = {
		agent: "reviewer-arch",
		kind: "oneshot",
		message: task,
		messageProvenance: "task-echo-fallback",
		status: "completed",
		task,
		taskId,
		startedAt: "2026-05-14T05:00:00.000Z",
		completedAt: "2026-05-14T05:01:00.000Z",
		updatedAt: "2026-05-14T05:01:00.000Z",
	};
	const differentItem = { ...echoItem, taskId: "reviewer-arch-different", message: "actual completion body" };
	const messages: ChatMessage[] = [];
	appendBgChatMessages(messages, [echoItem, differentItem]);

	assert.equal(messages.find((message) => message.taskId === echoItem.taskId && message.kind === "completion")?.body, COMPLETION_SUMMARY_UNAVAILABLE);
	assert.equal(messages.find((message) => message.taskId === differentItem.taskId && message.kind === "completion")?.body, "actual completion body");
});

test("monitor labels number repeated same-agent tasks latest-first friendly", () => {
	const first = record("reviewer-arch", "reviewer-arch-1700000000-11111111", "2026-05-14T05:00:00.000Z");
	const second = record("reviewer-arch", "reviewer-arch-1700000120-77abfc41", "2026-05-14T05:02:00.000Z");
	const numbers = taskNumberById([second, first]);

	assert.equal(numbers.get(first.taskId), 1);
	assert.equal(numbers.get(second.taskId), 2);
	assert.match(monitorRecordLabel(second, numbers), /reviewer-arch #2 · \d{2}:\d{2} · 77abfc41/);
});

test("Monitor tab line replaces History", () => {
	const line = renderAgentBrowserTabs("monitor", false, 120, theme as any);

	assert.match(line, /Monitor/);
	assert.doesNotMatch(line, /History/);
});

test("Monitor session grouping derives pane, lane, and one-shot sessions", () => {
	const paneFirst = record("reviewer-arch", "reviewer-arch-1700000000-11111111", "2026-05-14T05:00:00.000Z", { kind: "pane", paneId: "%9", status: "completed", sessionMode: "new" });
	const paneSecond = record("reviewer-arch", "reviewer-arch-1700000060-22222222", "2026-05-14T05:01:00.000Z", { kind: "pane", paneId: "%9", status: "running", sessionMode: "resumed" });
	const laneFirst = record("rust", "rust-1700000120-33333333", "2026-05-14T05:02:00.000Z", { kind: "oneshot", sessionKey: "review-issue-123", sessionMode: "resumed" });
	const laneSecond = record("rust", "rust-1700000180-44444444", "2026-05-14T05:03:00.000Z", { kind: "oneshot", sessionKey: "review-issue-123", sessionMode: "resumed" });
	const shotFirst = record("reviewer-doc", "reviewer-doc-1700000240-55555555", "2026-05-14T05:04:00.000Z", { kind: "oneshot", sessionMode: "fresh" });
	const shotSecond = record("reviewer-doc", "reviewer-doc-1700000300-66666666", "2026-05-14T05:05:00.000Z", { kind: "oneshot", sessionMode: "fresh" });

	const groups = buildMonitorSessionGroups([paneFirst, paneSecond, laneFirst, laneSecond, shotFirst, shotSecond]);

	assert.equal(groups.length, 4);
	assert.equal(groups.find((group) => group.type === "pane")?.records.length, 2);
	assert.equal(groups.find((group) => group.type === "bg-lane")?.records.length, 2);
	assert.equal(groups.filter((group) => group.type === "bg-one-shot").length, 2);
	assert.equal(groups.find((group) => group.type === "pane")?.isActive, true);
});

test("Monitor pane fallback grouping uses full transcript path", () => {
	const first = record("planner", "planner-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", {
		kind: "pane",
		paneId: undefined,
		transcriptPath: "/tmp/pi-runtime/sessions/planner.jsonl",
	});
	const second = record("reviewer-arch", "reviewer-arch-1700000060-bbbbbbbb", "2026-05-14T05:01:00.000Z", {
		kind: "pane",
		paneId: undefined,
		transcriptPath: "/tmp/pi-runtime/sessions/reviewer-arch.jsonl",
	});

	const groups = buildMonitorSessionGroups([first, second]);

	assert.equal(groups.filter((group) => group.type === "pane").length, 2);
	assert.deepEqual(groups.map((group) => group.records.length), [1, 1]);
});

test("Monitor corrupt records default to one-shot grouping without crashing", () => {
	const corrupt = {
		taskId: "reviewer-error-1700000000-aaaaaaaa",
		agent: "reviewer-error",
		task: "Inspect errors",
		status: "completed",
		createdAt: "2026-05-14T05:00:00.000Z",
		sessionKey: "",
	} as PaneTaskRecord;

	const groups = buildMonitorSessionGroups([corrupt]);

	assert.equal(groups.length, 1);
	assert.equal(groups[0]!.type, "bg-one-shot");
	assert.equal(groups[0]!.kind, "oneshot");
});

test("Monitor active/completed filter and tree expansion work", () => {
	const running = record("planner", "planner-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", { kind: "pane", paneId: "%1", status: "running", sessionMode: "resumed" });
	const done = record("reviewer-doc", "reviewer-doc-1700000060-bbbbbbbb", "2026-05-14T05:01:00.000Z", { kind: "oneshot", status: "completed", sessionMode: "fresh" });
	const unknown = record("reviewer-error", "reviewer-error-1700000120-cccccccc", "2026-05-14T05:02:00.000Z", { kind: "oneshot", status: "unknown", sessionMode: "fresh" });
	const groups = buildMonitorSessionGroups([running, done, unknown]);

	assert.deepEqual(filteredMonitorSessionGroups(groups, "active").map((group) => group.agent), ["reviewer-error", "planner"]);
	assert.deepEqual(filteredMonitorSessionGroups(groups, "completed").map((group) => group.agent), ["reviewer-doc"]);

	const rows = monitorTreeRows(groups, "all");
	assert.equal(rows.filter((row) => row.kind === "section").length, 2);
	assert.equal(rows.filter((row) => row.kind === "session").length, 3);
	assert.equal(rows.filter((row) => row.kind === "task").length, 3);

	const firstSession = rows.find((row) => row.kind === "session")!;
	const collapsed = monitorTreeRows(groups, "all", new Set([firstSession.key]));
	assert.equal(collapsed.filter((row) => row.kind === "task").length, 2);
});

test("Monitor filter cycle reset moves selection to first visible row", () => {
	const running = record("planner", "planner-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", { kind: "pane", status: "running" });
	const done = record("reviewer-doc", "reviewer-doc-1700000060-bbbbbbbb", "2026-05-14T05:01:00.000Z", { kind: "oneshot", status: "completed" });
	const groups = buildMonitorSessionGroups([running, done]);
	const rows = monitorTreeRows(groups, "active");
	const ui = uiState({ monitorSelected: 3, monitorScroll: 99 });

	ui.monitorSelected = 0;
	ui.monitorScroll = 0;
	ui.monitorSubtab = 0;
	ui.inspectorScroll = 0;
	clampMonitorUiToRows(ui, rows, 10);

	assert.equal(ui.monitorSelected, 0);
	assert.equal(ui.monitorScroll, 0);
});

test("Monitor empty tree renders dispatch hint", () => {
	const rendered = renderMonitorTree([], [], new Set(), uiState({ tab: "monitor", pane: "list" }), 120, theme as any, 10).join("\n");

	assert.match(rendered, /No tasks yet\. Dispatch via `subagent` or `\/agents`\./);
});

test("Monitor session selection shows aggregate detail", () => {
	const first = record("planner", "planner-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", {
		kind: "pane",
		paneId: "%1",
		sessionMode: "resumed",
		status: "completed",
		transcriptPath: "/tmp/planner-session.jsonl",
		usage: { input: 10, output: 20, cacheRead: 30, cacheWrite: 40, cost: 0.01, contextTokens: 50, turns: 1 },
	});
	const second = record("planner", "planner-1700000060-bbbbbbbb", "2026-05-14T05:01:00.000Z", {
		kind: "pane",
		paneId: "%1",
		sessionMode: "resumed",
		status: "running",
		usage: { input: 1, output: 2, cacheRead: 3, cacheWrite: 4, cost: 0.02, contextTokens: 5, turns: 2 },
	});
	const group = buildMonitorSessionGroups([first, second])[0]!;
	const rendered = renderMonitorSessionDetail(group, taskNumberById([first, second]), uiState({ tab: "monitor" }), 140, 40, theme as any).join("\n");
	const plain = rendered.replace(/\x1b\[[0-9;]*m/g, "");

	assert.match(plain, /pane · planner · resumed/);
	assert.match(plain, /Session type:\s+pane/);
	assert.match(plain, /Tasks:\s+2 tasks · completed:1 · running:1/);
	assert.match(plain, /Usage:/);
	assert.match(plain, /Pane ID:\s+%1/);
	assert.match(plain, /Transcript:\s+\/tmp\/planner-session\.jsonl/);
	assert.match(plain, /Task #2 · \d{2}:\d{2} · bbbbbbbb · running/);
});

test("Agents tab rows are flat static catalog entries", () => {
	const rows = buildAgentRows([agent("planner", true), agent("scout")], "", new Map());

	assert.deepEqual(rows.map((row) => row.label), ["planner", "scout"]);
});

test("Agents tab search only matches static agent metadata", () => {
	const config = agent("planner", true, { description: "Plans implementation work.", model: "openai-codex/gpt-5.5" });

	assert.equal(buildAgentRows([config], "", new Map()).length, 1);
	assert.equal(buildAgentRows([config], "implementation", new Map()).length, 1);
	assert.equal(buildAgentRows([config], "bbbbbbbb", new Map()).length, 0);
	assert.equal(buildAgentRows([config], "completion summary", new Map()).length, 0);
});

test("Agents Inspector shows static config only for agent with active tasks", () => {
	const taskId = "planner-1700000120-bbbbbbbb";
	const config = agent("planner", true, {
		color: "orange",
		denyTools: ["subagent", "question"],
		description: "Plans implementation work.",
		effort: "xhigh",
		filePath: ".pi/agents/planner.md",
		model: "openai-codex/gpt-5.5",
		systemPrompt: "Planner system prompt body.",
	});
	const statuses = new Map<string, AgentPaneStatus>([["planner", livePaneStatus("planner", {
		lastTaskAt: "2026-05-14T05:02:00.000Z",
		lastTaskId: taskId,
		sessionFile: "/tmp/planner-transcript.jsonl",
	})]]);

	const rendered = renderAgentInspector(config, statuses, uiState(), 120, 40, theme as any).join("\n");

	assert.match(rendered, /planner/);
	assert.match(rendered, /Plans implementation work\./);
	assert.match(rendered, /Model: openai-codex\/gpt-5\.5/);
	assert.match(rendered, /Effort: xhigh/);
	assert.match(rendered, /Kind: persistent pane/);
	assert.match(rendered, /Deny tools: subagent, question/);
	assert.match(rendered, /Color: orange/);
	assert.match(rendered, /Source path: \.pi\/agents\/planner\.md/);
	assert.match(rendered, /Pane: running \(started \d{2}:\d{2}\)/);
	assert.match(rendered, /System Prompt/);
	assert.match(rendered, /Planner system prompt body\./);
	assert.doesNotMatch(rendered, new RegExp(taskId));
	assert.doesNotMatch(rendered, /Task ID|Transcript|Latest Message|completion summary unavailable|Last task|Pane session/i);
});

test("Monitor tab task rendering still exposes task trace metadata", async () => {
	const taskId = "planner-1700000120-bbbbbbbb";
	const taskRecord = record("planner", taskId, "2026-05-14T05:02:00.000Z", {
		summary: "completed planner summary",
		transcriptPath: "/tmp/planner-transcript.jsonl",
	});
	const numbers = taskNumberById([taskRecord]);
	const items = await traceViewerItems(taskRecord, numbers.get(taskId), { agents: [agent("planner", true, { effort: "xhigh" })] });

	assert.match(monitorRecordLabel(taskRecord, numbers), /planner #1 · \d{2}:\d{2} · bbbbbbbb/);
	assert.match(items[0]!.text, /Task ID  planner-1700000120-bbbbbbbb/);
	assert.match(items[0]!.text, /Transcript  \/tmp\/planner-transcript\.jsonl/);
	assert.match(items[0]!.text, /completed planner summary/);
});

test("Monitor task Summary includes compact Transcript rows", async () => {
	const runtimeRoot = tempRuntime();
	const transcriptPath = join(runtimeRoot, "monitor-transcript.jsonl");
	writeFileSync(transcriptPath, [
		JSON.stringify({ ts: "2026-05-14T05:00:00.000Z", event: { type: "message_end", message: { role: "user", content: [{ type: "text", text: "Please inspect this\nwith detail" }] } } }),
		JSON.stringify({ ts: "2026-05-14T05:00:01.000Z", event: { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "Working on it\nsecond line" }] } } }),
		JSON.stringify({ ts: "2026-05-14T05:00:02.000Z", event: { type: "message_end", message: { role: "assistant", content: [{ type: "toolCall", name: "bash", arguments: { command: "echo hi" } }] } } }),
		JSON.stringify({ ts: "2026-05-14T05:00:03.000Z", event: { type: "exit", code: 0 } }),
	].join("\n"));
	const taskRecord = record("planner", "planner-1700000120-bbbbbbbb", "2026-05-14T05:00:00.000Z", { transcriptPath });

	const rows = transcriptCompactRows(taskRecord);
	assert.deepEqual(rows, [
		"05:00:00 → prompt Please inspect this",
		"05:00:01 ← assistant Working on it",
		"05:00:02 ← tool bash {\"command\":\"echo hi\"}",
		"05:00:03 ← exit code 0",
	]);

	const summary = (await traceViewerItems(taskRecord))[0]!.text;
	assert.match(summary, /Transcript\n----------\n05:00:00 → prompt Please inspect this\n05:00:01 ← assistant Working on it\n05:00:02 ← tool bash/);
});

test("Monitor compact Transcript handles missing and malformed JSONL", async () => {
	const runtimeRoot = tempRuntime();
	const missingPath = join(runtimeRoot, "missing.jsonl");
	const missingRecord = record("planner", "planner-1700000000-missing", "2026-05-14T05:00:00.000Z", { task: "Missing transcript task", transcriptPath: missingPath });

	assert.deepEqual(transcriptCompactRows(missingRecord), [
		"05:00:00 → prompt Missing transcript task",
		"--:--:-- ← error (transcript unavailable)",
	]);
	assert.match((await traceViewerItems(missingRecord))[0]!.text, /\(transcript unavailable\)/);

	const malformedPath = join(runtimeRoot, "malformed.jsonl");
	writeFileSync(malformedPath, "{not json\n");
	const malformedRecord = record("planner", "planner-1700000000-malformed", "2026-05-14T05:00:00.000Z", { task: "Malformed transcript task", transcriptPath: malformedPath });

	assert.deepEqual(transcriptCompactRows(malformedRecord), [
		"05:00:00 → prompt Malformed transcript task",
		"--:--:-- ← error (malformed transcript JSONL)",
	]);
	assert.match((await traceViewerItems(malformedRecord))[0]!.text, /\(malformed transcript JSONL\)/);
});

test("transcript tail preserves multiline assistant text and tool JSON structure", () => {
	const runtimeRoot = tempRuntime();
	const transcriptPath = join(runtimeRoot, "transcript.jsonl");
	writeFileSync(transcriptPath, [
		JSON.stringify({ ts: "2026-05-14T05:00:00.000Z", event: { type: "turn_start" } }),
		JSON.stringify({ ts: "2026-05-14T05:00:01.000Z", event: { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "line one\nline two" }] } } }),
		JSON.stringify({ ts: "2026-05-14T05:00:02.000Z", event: { type: "message_end", message: { role: "assistant", content: [{ type: "toolCall", name: "bash", arguments: { command: "echo hi" } }] } } }),
	].join("\n"));

	const tail = readTranscriptTail(transcriptPath, 40).join("\n");
	assert.match(tail, /assistant/);
	assert.match(tail, /line one\nline two/);
	assert.match(tail, /tool call bash/);
	assert.match(tail, /"command": "echo hi"/);
	assert.equal(extractLastAssistantTextFromTranscriptContent(tail), undefined);
});
