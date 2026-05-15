import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import {
	appendBgChatMessages,
	agentSystemPromptMarkdownTheme,
	buildMonitorSessionGroups,
	buildAgentRows,
	clampMonitorUiToRows,
	monitorFooterHint,
	monitorTreeRows,
	renderMonitorDetail,
	renderAgentBrowserTabs,
	renderAgentInspector,
	renderAgentList,
	renderMonitorTree,
	renderMonitorSessionDetail,
	taskNumberById,
	traceViewerItems,
} from "../extensions/subagent/browser.js";
import { latestDashboardActivity, renderDashboardWidgetLines } from "../extensions/subagent/dashboard.js";
import { COMPLETION_SUMMARY_UNAVAILABLE, extractLastAssistantTextFromTranscriptContent, highlightInlinePreview, oneLinePreview } from "../extensions/subagent/format.js";
import { oneShotTranscriptPath } from "../extensions/subagent/paths.js";
import { formatTaskRecordResult } from "../extensions/subagent/renderers.js";
import { animateSpinnersEnabled } from "../extensions/subagent/settings.js";
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

const ansiTheme = {
	bg: (_tone: string, text: string) => text,
	bold: (text: string) => `\x1b[1m${text}\x1b[22m`,
	fg: (tone: string, text: string) => {
		const colors: Record<string, string> = { accent: "\x1b[36m", dim: "\x1b[2m", error: "\x1b[31m", success: "\x1b[32m", warning: "\x1b[33m" };
		const code = colors[tone];
		return code ? `${code}${text}\x1b[39m` : text;
	},
	inverse: (text: string) => text,
};

function tempRuntime(): string {
	return mkdtempSync(join(tmpdir(), "pi-agents-dashboard-ux-"));
}

function writeManagerConfig(cwd: string, config: Record<string, unknown>): void {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({
		vstack: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": config } } },
	}));
}

function withTempPiUserDir<T>(fn: () => T): T {
	const previous = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = tempRuntime();
	try {
		return fn();
	} finally {
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
	}
}

function stripAnsi(text: string): string {
	return text.replace(/\x1b\[[0-9;]*m/g, "");
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
		selected: 0,
		scroll: 0,
		monitorSelected: 0,
		monitorScroll: 0,
		monitorSubtab: 0,
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
	assert.match(renderSubagentSingle(singleResult({ sessionMode: "foo" as any })), /completed · bg · ctrl\+o to expand/);
	assert.doesNotMatch(renderSubagentSingle(singleResult({ sessionMode: "foo" as any })), / · foo/);

	const cwd = tempRuntime();
	writeManagerConfig(cwd, { dashboard: true });
	const dashboard = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ sessionMode: "foo" as any }) } }, theme as any, cwd, 220).join("\n");
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

test("dashboard label suppresses #1 and only numbers tasks from the second onward", () => {
	const cwd = tempRuntime();
	writeManagerConfig(cwd, { dashboard: true });
	const lone = renderDashboardWidgetLines({
		collapsed: false, mode: "normal", visible: true,
		items: { a: dashboardItem({ taskId: "reviewer-arch-1700000000-aaaaaaaa", startedAt: "2026-05-14T05:00:00.000Z" }) },
	}, theme as any, cwd, 220).join("\n");
	assert.match(stripAnsi(lone), /reviewer-arch · completed/);
	assert.doesNotMatch(stripAnsi(lone), /reviewer-arch #\d/);

	const twin = renderDashboardWidgetLines({
		collapsed: false, mode: "normal", visible: true,
		items: {
			a: dashboardItem({ taskId: "reviewer-arch-1700000000-aaaaaaaa", startedAt: "2026-05-14T05:00:00.000Z" }),
			b: dashboardItem({ taskId: "reviewer-arch-1700000060-bbbbbbbb", startedAt: "2026-05-14T05:01:00.000Z" }),
		},
	}, theme as any, cwd, 220).join("\n");
	assert.match(stripAnsi(twin), /reviewer-arch #2 /);
	assert.doesNotMatch(stripAnsi(twin), /reviewer-arch #1\b/);
});

test("dashboard label uses occurrence number even when persisted task numbers are session-local 1", async () => {
	const cwd = tempRuntime();
	writeManagerConfig(cwd, { dashboard: true });
	// Two bg one-shot launches of the same agent each become their own
	// session in `taskNumberById` and both get persisted `#1`. The label
	// helpers must fall through to in-memory occurrence so the second row
	// reads `<agent> #2`, not a second copy of `<agent>`.
	const recordA = record("reviewer-arch", "reviewer-arch-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", { kind: "oneshot", status: "completed", completedAt: "2026-05-14T05:00:30.000Z" });
	const recordB = record("reviewer-arch", "reviewer-arch-1700000060-bbbbbbbb", "2026-05-14T05:01:00.000Z", { kind: "oneshot", status: "running" });
	await updateTaskRegistry(cwd, (records) => { records[recordA.taskId] = recordA; records[recordB.taskId] = recordB; });
	const persisted = await readTaskRegistry(cwd);
	const numbers = taskNumberById(Object.values(persisted));
	assert.equal(numbers.get(recordA.taskId), 1);
	assert.equal(numbers.get(recordB.taskId), 1);

	const rendered = renderDashboardWidgetLines({
		collapsed: false, mode: "normal", visible: true,
		items: {
			a: dashboardItem({ taskId: recordA.taskId, startedAt: recordA.createdAt, status: "completed" }),
			b: dashboardItem({ taskId: recordB.taskId, startedAt: recordB.createdAt, status: "running" }),
		},
	}, theme as any, cwd, 220, cwd).join("\n");
	const plain = stripAnsi(rendered);
	assert.match(plain, /reviewer-arch #2 +· working/);
	assert.doesNotMatch(plain, /reviewer-arch #1\b/);
	assert.match(plain, /reviewer-arch +· completed/);
});

test("dashboard mini widget shows session-mode chips", () => {
	const cwd = tempRuntime();
	writeManagerConfig(cwd, { dashboard: true });
	const fresh = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ sessionMode: "fresh" }) } }, theme as any, cwd, 220).join("\n");
	assert.match(fresh, /completed · bg · fresh/);

	const lane = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ sessionMode: "resumed", sessionKey: "very-long-session-key" }) } }, theme as any, cwd, 220).join("\n");
	assert.match(lane, /completed · bg · lane:very-l…-key/);

	const paneNew = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ kind: "pane", sessionMode: "new" }) } }, theme as any, cwd, 220).join("\n");
	assert.match(paneNew, /completed · pane · new/);

	const paneResumed = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ kind: "pane", sessionMode: "resumed" }) } }, theme as any, cwd, 220).join("\n");
	assert.match(paneResumed, /completed · pane · resumed/);
});

test("dashboard compact activity uses latest agent action, not prompt fallback", () => {
	const cwd = tempRuntime();
	writeManagerConfig(cwd, { dashboard: true });
	const transcript = join(cwd, "agent.jsonl");
	writeFileSync(transcript, [
		JSON.stringify({ event: { type: "message_end", message: { role: "user", content: [{ type: "text", text: "Task: initial prompt" }] } } }),
		JSON.stringify({ event: { type: "message_end", message: { role: "assistant", content: [{ type: "toolCall", name: "Bash" }] } } }),
	].join("\n"));
	const running = dashboardItem({ status: "running", task: "initial prompt", message: "initial prompt", transcriptPath: transcript });

	assert.equal(latestDashboardActivity(running), "tool: Bash");
	const rendered = renderDashboardWidgetLines({ collapsed: false, mode: "compact", visible: true, items: { a: running } }, theme as any, cwd, 220).join("\n");
	assert.match(rendered, /tool: Bash/);
	assert.doesNotMatch(rendered, /said: tool|initial prompt/);

	const promptOnly = dashboardItem({ status: "running", task: "initial prompt", message: "initial prompt" });
	assert.equal(latestDashboardActivity(promptOnly), undefined);
	const promptOnlyRendered = renderDashboardWidgetLines({ collapsed: false, mode: "compact", visible: true, items: { a: promptOnly } }, theme as any, cwd, 220).join("\n");
	assert.doesNotMatch(promptOnlyRendered, /initial prompt/);
});

test("dashboard expanded message lines mark inbound prompt and outbound result", () => {
	const cwd = tempRuntime();
	writeManagerConfig(cwd, { dashboard: true });
	const rendered = stripAnsi(renderDashboardWidgetLines({
		collapsed: false,
		mode: "expanded",
		visible: true,
		items: { a: dashboardItem({ status: "completed", task: "Inspect tests", message: "No gaps found.", messageProvenance: "persisted" }) },
	}, theme as any, cwd, 220).join("\n"));

	assert.match(rendered, /├─ -> Inspect tests/);
	assert.match(rendered, /└─ <- No gaps found\./);
});

test("dashboard expanded message lines use configured ASCII tree connectors", () => {
	const cwd = tempRuntime();
	writeManagerConfig(cwd, { dashboard: true, treeStyle: "ascii" });
	const rendered = stripAnsi(renderDashboardWidgetLines({
		collapsed: false,
		mode: "expanded",
		visible: true,
		items: { a: dashboardItem({ status: "completed", task: "Inspect tests", message: "No gaps found.", messageProvenance: "persisted" }) },
	}, theme as any, cwd, 220).join("\n"));

	assert.match(rendered, /\|-- -> Inspect tests/);
	assert.match(rendered, /`-- <- No gaps found\./);
});

test("dashboard spinner setting replaces running animation with static gear", () => {
	const cwd = tempRuntime();
	writeManagerConfig(cwd, { dashboard: true, animateSpinners: false });

	const rendered = renderDashboardWidgetLines({ collapsed: false, mode: "normal", visible: true, items: { a: dashboardItem({ status: "running" }) } }, theme as any, cwd, 220).join("\n");

	assert.match(rendered, /\uf013/);
	assert.doesNotMatch(rendered, /[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/);

	const running = record("planner", "planner-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", { kind: "pane", status: "running" });
	const animateSpinners = animateSpinnersEnabled(cwd);
	assert.equal(animateSpinners, false);
	const tree = renderMonitorTree(monitorTreeRows(buildMonitorSessionGroups([running])), [running], new Set(), uiState({ tab: "monitor", pane: "list" }), 120, theme as any, 10, animateSpinners).join("\n");
	const detail = renderMonitorSessionDetail(buildMonitorSessionGroups([running])[0], taskNumberById([running]), uiState({ tab: "monitor" }), 140, 20, theme as any, animateSpinners).join("\n");
	assert.match(tree, /\uf013/);
	assert.doesNotMatch(tree, /[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/);
	assert.match(detail, /\uf013/);
	assert.doesNotMatch(detail, /[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/);
});

test("spinner setting defaults and project override precedence", () => {
	withTempPiUserDir(() => {
		const cwd = tempRuntime();
		assert.equal(animateSpinnersEnabled(cwd), true);

		writeManagerConfig(cwd, { animateSpinners: "no" });
		assert.equal(animateSpinnersEnabled(cwd), true);

		const userDir = process.env.PI_CODING_AGENT_DIR!;
		mkdirSync(userDir, { recursive: true });
		writeFileSync(join(userDir, "settings.json"), JSON.stringify({
			vstack: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": { animateSpinners: false } } } },
		}));
		writeManagerConfig(cwd, { animateSpinners: true });
		assert.equal(animateSpinnersEnabled(cwd), true);

		writeManagerConfig(cwd, { animateSpinners: false });
		assert.equal(animateSpinnersEnabled(cwd), false);
	});
});

test("Monitor session detail owns agent session model and effort metadata", async () => {
	const taskRecord = record("reviewer-arch", "reviewer-arch-session", "2026-05-14T05:00:00.000Z", {
		effort: "xhigh",
		model: "openai-codex/gpt-5.5:xhigh",
		sessionKey: "feature-x",
		sessionMode: "resumed",
	});
	const group = buildMonitorSessionGroups([taskRecord])[0]!;
	const sessionDetail = renderMonitorSessionDetail(group, taskNumberById([taskRecord]), uiState({ tab: "monitor" }), 160, 30, theme as any, true, { agents: [agent("reviewer-arch")] }).join("\n");
	const taskItems = await traceViewerItems(taskRecord, 1, { agents: [agent("reviewer-arch")] }, group.sessionNumber);

	assert.match(sessionDetail, /^Agent:\s+reviewer-arch$/m);
	assert.match(sessionDetail, /^Model:\s+openai-codex\/gpt-5\.5$/m);
	assert.match(sessionDetail, /^Effort:\s+xhigh$/m);
	assert.match(sessionDetail, /^Session:\s+resumed · lane: feature-x$/m);
	assert.doesNotMatch(taskItems[0]!.text, /^(Agent|Session #|Model|Effort|Session)\s+/m);
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
	assert.match((await traceViewerItems(taskRecord))[1]!.text, new RegExp(longSummary.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
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

test("Monitor numbers repeated agent launches as sessions and resets task numbers per session", async () => {
	const first = record("reviewer-arch", "reviewer-arch-1700000000-11111111", "2026-05-14T05:00:00.000Z", { kind: "oneshot", sessionMode: "fresh" });
	const second = record("reviewer-arch", "reviewer-arch-1700000120-77abfc41", "2026-05-14T05:02:00.000Z", { kind: "oneshot", sessionMode: "fresh" });
	const paneFirst = record("planner", "planner-1700000180-aaaaaaaa", "2026-05-14T05:03:00.000Z", { kind: "pane", paneId: "%1" });
	const paneSecond = record("planner", "planner-1700000240-bbbbbbbb", "2026-05-14T05:04:00.000Z", { kind: "pane", paneId: "%1" });
	const records = [second, first, paneSecond, paneFirst];
	const numbers = taskNumberById(records);

	assert.equal(numbers.get(first.taskId), 1);
	assert.equal(numbers.get(second.taskId), 1);
	assert.equal(numbers.get(paneFirst.taskId), 1);
	assert.equal(numbers.get(paneSecond.taskId), 2);

	const groups = buildMonitorSessionGroups(records);
	const latestReviewerGroup = groups.find((group) => group.agent === "reviewer-arch" && group.records[0]?.taskId === second.taskId)!;
	const firstReviewerGroup = groups.find((group) => group.agent === "reviewer-arch" && group.records[0]?.taskId === first.taskId)!;
	assert.equal(firstReviewerGroup.sessionNumber, 1);
	assert.equal(latestReviewerGroup.sessionNumber, 2);

	const tree = renderMonitorTree(monitorTreeRows(groups), records, new Set(), uiState({ tab: "monitor", pane: "list" }), 180, theme as any, 20).join("\n").replace(/\x1b\[[0-9;]*m/g, "");
	assert.match(tree, /reviewer-arch · 1 task · /);
	// `#1` is suppressed everywhere; only `#2+` should appear.
	assert.match(tree, /Task · \d{2}:\d{2} · completed/);
	assert.doesNotMatch(tree, /Task #1\b/);
	assert.doesNotMatch(tree, /bg · reviewer-arch|session #2 · fresh|reviewer-arch #2/);

	const items = await traceViewerItems(second, numbers.get(second.taskId), { agents: [agent("reviewer-arch")] }, latestReviewerGroup.sessionNumber);
	const detail = renderMonitorDetail(second, new Map([[second.taskId, { items }]]), uiState({ tab: "monitor", pane: "inspector" }), 180, 30, theme as any).join("\n").replace(/\x1b\[[0-9;]*m/g, "");
	const sessionDetail = renderMonitorSessionDetail(latestReviewerGroup, numbers, uiState({ tab: "monitor" }), 180, 30, theme as any, true, { agents: [agent("reviewer-arch")] }).join("\n");
	assert.equal(detail.split("\n")[0]?.trim(), "Detail");
	assert.doesNotMatch(detail.split("\n")[0] ?? "", /reviewer-arch|session #|task #|completed|fresh|gpt/);
	assert.doesNotMatch(items[0]!.text, /^(Agent|Session #|Model|Effort|Session)\s+/m);
	assert.match(sessionDetail, /^Agent:\s+reviewer-arch$/m);
	assert.match(sessionDetail, /^Session #:\s+2$/m);
	// `#1` is suppressed; the trace summary skips the `Task #   1` line entirely.
	assert.doesNotMatch(items[0]!.text, /Task #   1\b/);
	assert.doesNotMatch(detail, /reviewer-arch #2/);
});

test("Monitor tab line replaces History", () => {
	const line = renderAgentBrowserTabs("monitor", 120, theme as any);

	assert.match(line, /Monitor/);
	assert.doesNotMatch(line, /History/);
});

test("Monitor footer omits filter and transcript toggle hints", () => {
	const footer = monitorFooterHint(theme as any).replace(/\x1b\[[0-9;]*m/g, "");

	assert.match(footer, /enter open\/toggle/);
	assert.doesNotMatch(footer, /filter|x expand|x compact/);
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

test("Monitor active/completed sections and tree expansion work", () => {
	const running = record("planner", "planner-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", { kind: "pane", paneId: "%1", status: "running", sessionMode: "resumed" });
	const done = record("reviewer-doc", "reviewer-doc-1700000060-bbbbbbbb", "2026-05-14T05:01:00.000Z", { kind: "oneshot", status: "completed", sessionMode: "fresh" });
	const unknown = record("reviewer-error", "reviewer-error-1700000120-cccccccc", "2026-05-14T05:02:00.000Z", { kind: "oneshot", status: "unknown", sessionMode: "fresh" });
	const groups = buildMonitorSessionGroups([running, done, unknown]);

	const rows = monitorTreeRows(groups);
	assert.equal(rows.filter((row) => row.kind === "section").length, 2);
	assert.deepEqual(rows.filter((row) => row.kind === "section").map((row) => row.label), ["Active (2)", "Completed (1)"]);
	assert.equal(rows.filter((row) => row.kind === "session").length, 3);
	assert.equal(rows.filter((row) => row.kind === "task").length, 3);

	const firstSession = rows.find((row) => row.kind === "session")!;
	const collapsed = monitorTreeRows(groups, new Set(), new Set([firstSession.key]));
	assert.equal(collapsed.filter((row) => row.kind === "task").length, 2);

	const collapsedActive = monitorTreeRows(groups, new Set(["active"]));
	assert.equal(collapsedActive.find((row) => row.kind === "section" && row.section === "active")?.collapsed, true);
	assert.equal(collapsedActive.filter((row) => row.kind === "session").length, 1);
});

test("Monitor clamp keeps section rows selectable", () => {
	const running = record("planner", "planner-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", { kind: "pane", status: "running" });
	const done = record("reviewer-doc", "reviewer-doc-1700000060-bbbbbbbb", "2026-05-14T05:01:00.000Z", { kind: "oneshot", status: "completed" });
	const groups = buildMonitorSessionGroups([running, done]);
	const rows = monitorTreeRows(groups);
	const ui = uiState({ monitorSelected: 3, monitorScroll: 99 });

	clampMonitorUiToRows(ui, rows, 10);

	assert.equal(ui.monitorSelected, 3);
	assert.equal(ui.monitorScroll, 0);
});

test("Monitor empty tree renders dispatch hint", () => {
	const rendered = renderMonitorTree([], [], new Set(), uiState({ tab: "monitor", pane: "list" }), 120, theme as any, 10).join("\n");

	assert.match(rendered, /Sessions\s+\(0\)/);
	assert.doesNotMatch(rendered, /Monitor\s+\(0\)/);
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

	assert.equal(plain.split("\n")[0]?.trim(), "Detail");
	assert.doesNotMatch(plain.split("\n")[0] ?? "", /pane|planner|resumed/);
	assert.match(plain, /Session type:\s+pane/);
	assert.match(plain, /Tasks:\s+2 tasks · completed:1 · running:1/);
	assert.match(plain, /Usage:/);
	assert.match(plain, /Pane ID:\s+%1/);
	assert.match(plain, /Transcript:\s+\/tmp\/planner-session\.jsonl/);
	assert.match(plain, /Task #2 · \d{2}:\d{2} · running/);

	const colored = renderMonitorSessionDetail(group, taskNumberById([first, second]), uiState({ tab: "monitor" }), 140, 40, ansiTheme as any).join("\n");
	assert.match(colored, /\x1b\[35m\x1b\[1mSession/);
	assert.match(colored, /\n\n\x1b\[35m\x1b\[1mTask list/);
});

test("Monitor footer labels arrow navigation as pane switch", () => {
	const rendered = stripAnsi(monitorFooterHint(theme as any));

	assert.match(rendered, /←\/→ pane/);
	assert.doesNotMatch(rendered, /tree↔detail/);
});

test("Agents tab rows are flat static catalog entries", () => {
	const rows = buildAgentRows([agent("planner", true), agent("scout")], new Map());

	assert.deepEqual(rows.map((row) => row.label), ["planner", "scout"]);
});

test("Agents tab list shows only kind and scope chips after agent name", () => {
	const rows = buildAgentRows([
		agent("planner", true, { model: "openai-codex/gpt-5.5", source: "project" }),
		agent("scout", false, { model: "openai-codex/gpt-5.5", source: "user" }),
	], new Map());
	const rendered = stripAnsi(renderAgentList(rows, new Map(), uiState({ selected: 0 }), 160, theme as any, 20).join("\n"));

	assert.match(rendered, /planner · pane · project/);
	assert.match(rendered, /scout · bg · user/);
	assert.doesNotMatch(rendered, /gpt-5\.5|openai-codex| xhigh| default| · P| · U/);
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
	assert.doesNotMatch(rendered, /planner \[(pane|bg)\]|\[(P|U)\]/);
	assert.doesNotMatch(rendered, new RegExp(taskId));
	assert.doesNotMatch(rendered, /Task ID|Transcript|Latest Message|completion summary unavailable|Last task|Pane session/i);
});

test("Agents Inspector colors prompt label magenta but markdown tokens accent", () => {
	const config = agent("planner", true, {
		systemPrompt: "# Planner Agent\n\nUse `plan.md`.\n\n- Keep scope tight.",
	});
	const rendered = renderAgentInspector(config, new Map(), uiState(), 120, 40, ansiTheme as any).join("\n");
	const markdownTheme = agentSystemPromptMarkdownTheme(ansiTheme as any);
	const promptTokens = [
		markdownTheme.heading(ansiTheme.bold("Planner Agent")),
		markdownTheme.code("plan.md"),
		markdownTheme.listBullet("- "),
	].join("\n");

	assert.match(rendered, /\x1b\[35m\x1b\[1mSystem Prompt/);
	assert.match(promptTokens, /\x1b\[36m\x1b\[1mPlanner Agent/);
	assert.match(promptTokens, /\x1b\[36mplan\.md/);
	assert.match(promptTokens, /\x1b\[36m- /);
	assert.doesNotMatch(promptTokens, /\x1b\[35m/);
});

test("Monitor tab task rendering still exposes task trace metadata", async () => {
	const taskId = "planner-1700000120-bbbbbbbb";
	const taskRecord = record("planner", taskId, "2026-05-14T05:02:00.000Z", {
		model: "openai-codex/gpt-5.5:xhigh",
		effort: "xhigh",
		summary: "completed planner summary",
		completionArchivePath: "/tmp/planner-completion.json",
		completionSourcePath: "/tmp/planner-source.json",
		transcriptPath: "/tmp/planner-transcript.jsonl",
	});
	const numbers = taskNumberById([taskRecord]);
	const items = await traceViewerItems(taskRecord, numbers.get(taskId), { agents: [agent("planner", true, { effort: "xhigh" })] });

	assert.equal(items.length, 2);
	assert.match(items[0]!.text, /Task ID  planner-1700000120-bbbbbbbb/);
	assert.doesNotMatch(items[0]!.text, /^(Agent|Session #|Model|Effort|Session)\s+/m);
	assert.match(items[0]!.text, /Artifacts\n---------/);
	assert.match(items[0]!.text, /Transcript  \/tmp\/planner-transcript\.jsonl/);
	assert.match(items[0]!.text, /Archive   \/tmp\/planner-completion\.json/);
	assert.match(items[0]!.text, /Source   \/tmp\/planner-source\.json/);
	assert.match(items[0]!.text, /Task\n----\nTask for planner/);
	assert.doesNotMatch(items[0]!.text, /Overview|completed planner summary/);
	assert.equal(items[1]!.path, "/tmp/planner-completion.json");
	assert.match(items[1]!.text, /Summary\n-------\ncompleted planner summary/);
	assert.match(items[1]!.text, /Files changed\n-------------\nNone reported/);
	assert.match(items[1]!.text, /Validation\n----------\nNone reported/);
	assert.match(items[1]!.text, /Completion JSON\n---------------\nCompletion JSON file could not be read\./);
});

test("Monitor completion tab shows persisted bg result without JSON warning", async () => {
	const taskRecord = record("reviewer-doc", "reviewer-doc-1700000120-bg", "2026-05-14T05:02:00.000Z", {
		kind: "oneshot",
		sessionMode: "fresh",
		summary: "completed reviewer summary",
	});
	const items = await traceViewerItems(taskRecord, 1, { agents: [agent("reviewer-doc")] });

	assert.equal(items.length, 2);
	assert.equal(items[1]!.label, "Completion");
	assert.equal(items[1]!.path, undefined);
	assert.equal(items[1]!.type, "summary");
	assert.match(items[1]!.text, /Summary\n-------\ncompleted reviewer summary/);
	assert.match(items[1]!.text, /Files changed\n-------------\nNone reported/);
	assert.match(items[1]!.text, /Validation\n----------\nNone reported/);
	assert.doesNotMatch(items[1]!.text, /Completion JSON|unavailable|No completion JSON artifact/);
});

test("Monitor right-pane section labels use ANSI magenta", async () => {
	const taskRecord = record("planner", "planner-1700000120-section", "2026-05-14T05:02:00.000Z", { summary: "done" });
	const items = await traceViewerItems(taskRecord, 1, { agents: [agent("planner", true)] });
	const rendered = renderMonitorDetail(taskRecord, new Map([[taskRecord.taskId, { items }]]), uiState({ tab: "monitor", pane: "inspector" }), 120, 40, ansiTheme as any).join("\n");

	assert.match(rendered, /\x1b\[35m\x1b\[1mTask/);
	assert.doesNotMatch(rendered, /Overview/);
});

test("inline JSON highlighter protects keys before status value coloring", () => {
	const malformed = highlightInlinePreview('{"ok": "passed', ansiTheme as any);
	assert.match(malformed, /\x1b\[36m"ok"\x1b\[39m/);
	assert.doesNotMatch(malformed, /\x1b\[32mok\x1b\[39m/);
	assert.doesNotMatch(malformed, /\x1b\[32mpassed\x1b\[39m/);

	const dangling = highlightInlinePreview('{"passed": }', ansiTheme as any);
	assert.match(dangling, /\x1b\[36m"passed"\x1b\[39m/);
	assert.doesNotMatch(dangling, /\x1b\[32mpassed\x1b\[39m/);

	const validValue = highlightInlinePreview('{"status": "passed"}', ansiTheme as any);
	assert.match(validValue, /\x1b\[36m"status"\x1b\[39m/);
	assert.match(validValue, /\x1b\[32mpassed\x1b\[39m/);
});
