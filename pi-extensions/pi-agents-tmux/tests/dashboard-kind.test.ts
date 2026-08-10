import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import {
	completionPath,
	oneShotTranscriptPath,
	taskMarkdownPath,
} from "../extensions/subagent/paths.js";
import {
	inferTaskRecordKind,
	readTaskRegistry,
	refreshTaskDiagnostics,
	updateTaskRegistry,
} from "../extensions/subagent/tasks.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";

const tempDirs: string[] = [];

after(() => {
	for (const dir of tempDirs) rmSync(dir, { force: true, recursive: true });
});

function tempRuntime(): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-agents-dashboard-"));
	tempDirs.push(dir);
	return dir;
}

test("bg records stay bg even after legacy pane artifact pollution", async () => {
	const runtimeRoot = tempRuntime();
	const taskId = "reviewer-error-123";
	const record: PaneTaskRecord = {
		taskId,
		agent: "reviewer-error",
		task: "Review error handling.",
		status: "completed",
		// Legacy refreshTaskDiagnostics used to add these pane handoff paths to bg
		// records, which made dashboard restore label bg agents as pane.
		inboxFile: taskMarkdownPath(runtimeRoot, "inbox", "reviewer-error", taskId),
		outboxFile: completionPath(runtimeRoot, "reviewer-error", taskId),
		transcriptPath: oneShotTranscriptPath(runtimeRoot, "reviewer-error", taskId),
		createdAt: "2026-05-12T00:00:00.000Z",
		updatedAt: "2026-05-12T00:01:00.000Z",
	};

	assert.equal(inferTaskRecordKind(runtimeRoot, record), "oneshot");
	await updateTaskRegistry(runtimeRoot, (records) => {
		records[taskId] = record;
	});

	const refreshed = await refreshTaskDiagnostics(runtimeRoot, record);
	assert.equal(refreshed.record.kind, "oneshot");
	assert.equal(refreshed.record.inboxFile, undefined);
	assert.equal(refreshed.record.outboxFile, undefined);

	const persisted = (await readTaskRegistry(runtimeRoot))[taskId];
	assert.equal(persisted?.kind, "oneshot");
	assert.equal(persisted?.inboxFile, undefined);
	assert.equal(persisted?.outboxFile, undefined);
});

test("pane records remain pane when they use pane handoff artifacts", () => {
	const runtimeRoot = tempRuntime();
	const record: PaneTaskRecord = {
		taskId: "planner-123",
		agent: "planner",
		task: "Plan work.",
		status: "queued",
		paneId: "%7",
		inboxFile: taskMarkdownPath(runtimeRoot, "inbox", "planner", "planner-123"),
		transcriptPath: join(runtimeRoot, "sessions", "planner.jsonl"),
		createdAt: "2026-05-12T00:00:00.000Z",
	};

	assert.equal(inferTaskRecordKind(runtimeRoot, record), "pane");
});
