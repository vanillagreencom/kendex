import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import {
	appendBgChatMessages,
	buildAgentRows,
	historyRecordLabel,
	readTranscriptTail,
	renderAgentInspector,
	taskNumberById,
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
		historySelected: 0,
		historyScroll: 0,
		historySubtab: 0,
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

test("history labels number repeated same-agent tasks latest-first friendly", () => {
	const first = record("reviewer-arch", "reviewer-arch-1700000000-11111111", "2026-05-14T05:00:00.000Z");
	const second = record("reviewer-arch", "reviewer-arch-1700000120-77abfc41", "2026-05-14T05:02:00.000Z");
	const numbers = taskNumberById([second, first]);

	assert.equal(numbers.get(first.taskId), 1);
	assert.equal(numbers.get(second.taskId), 2);
	assert.match(historyRecordLabel(second, numbers), /reviewer-arch #2 · \d{2}:\d{2} · 77abfc41/);
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

test("History tab task rendering still exposes task trace metadata", async () => {
	const taskId = "planner-1700000120-bbbbbbbb";
	const taskRecord = record("planner", taskId, "2026-05-14T05:02:00.000Z", {
		summary: "completed planner summary",
		transcriptPath: "/tmp/planner-transcript.jsonl",
	});
	const numbers = taskNumberById([taskRecord]);
	const items = await traceViewerItems(taskRecord, numbers.get(taskId), { agents: [agent("planner", true, { effort: "xhigh" })] });

	assert.match(historyRecordLabel(taskRecord, numbers), /planner #1 · \d{2}:\d{2} · bbbbbbbb/);
	assert.match(items[0]!.text, /Task ID  planner-1700000120-bbbbbbbb/);
	assert.match(items[0]!.text, /Transcript  \/tmp\/planner-transcript\.jsonl/);
	assert.match(items[0]!.text, /completed planner summary/);
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
