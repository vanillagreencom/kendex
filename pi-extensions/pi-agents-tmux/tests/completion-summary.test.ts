// How a bg completion reaches the chat history: the persisted summary
// whole, the fallback message unless it only echoes the prompt, and the
// unavailable marker otherwise.

import assert from "node:assert/strict";
import test from "node:test";
import { appendBgChatMessages } from "../extensions/subagent/browser.js";
import { COMPLETION_SUMMARY_UNAVAILABLE, oneLinePreview } from "../extensions/subagent/format.js";
import { formatTaskRecordResult } from "../extensions/subagent/renderers.js";
import type { ChatMessage, PaneTaskRecord, SubagentDashboardItem } from "../extensions/subagent/types.js";
import { ABSENT, dashboardItem, record } from "./browser-fixture.js";

const taskId = "reviewer-arch-1700000000-77abfc41";
const task = "Check test coverage";
const longSummary = Array.from({ length: 80 }, (_, index) => `finding-${index}`).join(" ");

function item(patch: Partial<SubagentDashboardItem>): SubagentDashboardItem {
	return dashboardItem({ agent: "reviewer-arch", kind: "oneshot", status: "completed", task, taskId, startedAt: "2026-05-14T05:00:00.000Z", completedAt: "2026-05-14T05:02:00.000Z", updatedAt: "2026-05-14T05:02:00.000Z", ...patch });
}

// The delegation and completion bodies synthesized for one task id.
function bodies(messages: ChatMessage[], id: string): string {
	const delegation = messages.find((message) => message.taskId === id && message.kind === "delegation");
	const completion = messages.find((message) => message.taskId === id && message.kind === "completion");
	return `delegation=${delegation ? `${delegation.to} ${JSON.stringify(delegation.body)}` : ABSENT} completion=${completion ? JSON.stringify(completion.body) : ABSENT}`;
}

const secondId = "reviewer-arch-1700000060-bbbbbbbb";
const unavailable = JSON.stringify(COMPLETION_SUMMARY_UNAVAILABLE);

// label | items | registry record (none = not persisted) | observed task id | expect
const rows: Array<[string, SubagentDashboardItem[], PaneTaskRecord | undefined, string, string]> = [
	["no message and no record: unavailable", [item({})], undefined, taskId, `delegation=@reviewer-arch "Check test coverage" completion=${unavailable}`],
	["a persisted summary reaches chat whole", [item({ message: oneLinePreview(longSummary, 120) })], record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { summary: longSummary }), taskId, `delegation=@reviewer-arch "Check test coverage" completion=${JSON.stringify(longSummary)}`],
	["a persisted summary equal to the task is not suppressed", [item({ message: task, messageProvenance: "persisted" })], record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { task, summary: task }), taskId, `delegation=@reviewer-arch "Check test coverage" completion=${JSON.stringify(task)}`],
	["a task-echo fallback equal to the task is suppressed", [item({ message: task, messageProvenance: "task-echo-fallback" })], undefined, taskId, `delegation=@reviewer-arch "Check test coverage" completion=${unavailable}`],
	["a task-echo fallback that differs is the body", [item({ message: "actual completion body", messageProvenance: "task-echo-fallback" })], undefined, taskId, `delegation=@reviewer-arch "Check test coverage" completion="actual completion body"`],
	["a working item has no completion yet", [item({ status: "running", completedAt: undefined })], undefined, taskId, `delegation=@reviewer-arch "Check test coverage" completion=${ABSENT}`],
	["a second launch of the agent is addressed as #2", [item({}), item({ taskId: secondId, startedAt: "2026-05-14T05:01:00.000Z" })], undefined, secondId, `delegation=@reviewer-arch #2 "Check test coverage" completion=${unavailable}`],
	["a pane item is not synthesized", [item({ kind: "pane" })], undefined, taskId, `delegation=${ABSENT} completion=${ABSENT}`],
];

test("bg completion messages", () => {
	for (const [label, items, persisted, id, expect] of rows) {
		const messages: ChatMessage[] = [];
		appendBgChatMessages(messages, items, persisted ? { [persisted.taskId]: persisted } : {});
		assert.equal(bodies(messages, id), expect, label);
	}
});

test("the persisted summary reaches the result text whole", () => {
	const taskRecord = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { summary: longSummary, transcriptPath: "/tmp/reviewer-arch.jsonl" });
	assert.ok(formatTaskRecordResult(taskRecord).includes(longSummary));
});
