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
	taskNumberById,
} from "../extensions/subagent/browser.js";
import { COMPLETION_SUMMARY_UNAVAILABLE, extractLastAssistantTextFromTranscriptContent } from "../extensions/subagent/format.js";
import { oneShotTranscriptPath } from "../extensions/subagent/paths.js";
import {
	backfillTaskSummaryFromTranscript,
	readTaskRegistry,
	updateTaskRegistry,
} from "../extensions/subagent/tasks.js";
import type { ChatMessage, PaneTaskRecord, SubagentDashboardItem } from "../extensions/subagent/types.js";

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

function agent(name: string, pane = false): AgentConfig {
	return { name, pane, description: `${name} agent`, systemPrompt: "", source: "project", filePath: `${name}.md` };
}

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

test("history labels number repeated same-agent tasks latest-first friendly", () => {
	const first = record("reviewer-arch", "reviewer-arch-1700000000-11111111", "2026-05-14T05:00:00.000Z");
	const second = record("reviewer-arch", "reviewer-arch-1700000120-77abfc41", "2026-05-14T05:02:00.000Z");
	const numbers = taskNumberById([second, first]);

	assert.equal(numbers.get(first.taskId), 1);
	assert.equal(numbers.get(second.taskId), 2);
	assert.match(historyRecordLabel(second, numbers), /reviewer-arch #2 · \d{2}:\d{2} · 77abfc41/);
});

test("agent rows include pane task children sharing one transcript", () => {
	const sessionFile = join(tempRuntime(), "sessions", "planner.jsonl");
	const first = record("planner", "planner-1700000000-aaaaaaaa", "2026-05-14T05:00:00.000Z", { kind: "pane", paneId: "%1", transcriptPath: sessionFile });
	const second = record("planner", "planner-1700000120-bbbbbbbb", "2026-05-14T05:02:00.000Z", { kind: "pane", paneId: "%1", transcriptPath: sessionFile });
	const rows = buildAgentRows([agent("planner", true)], "", new Map(), [], { [first.taskId]: first, [second.taskId]: second });

	assert.equal(rows[0]?.rowType, "agent");
	const taskRows = rows.filter((row) => row.rowType === "task");
	assert.equal(taskRows.length, 2);
	assert.deepEqual(taskRows.map((row) => row.item?.transcriptPath), [sessionFile, sessionFile]);
	assert.match(taskRows[0]!.label, /#2/);
	assert.match(taskRows[1]!.label, /#1/);
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
