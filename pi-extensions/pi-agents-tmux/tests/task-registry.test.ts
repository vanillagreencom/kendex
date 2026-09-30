import assert from "node:assert/strict";
import * as fs from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import { taskRegistryReader } from "../extensions/subagent/task-records.js";
import * as tasks from "../extensions/subagent/tasks.js";
import { assertCachedCompletionPoll, assertCachedRegistryUpdate, cleanupTempRuntimes, importRuntimeCopy, tempRuntime } from "./browser-fixture.js";
import { fakePi, type Emitted } from "./needs-completion-fixture.js";

after(cleanupTempRuntimes);
after(() => taskRegistryReader.clear());

test("completion polling reads no registry content on an unchanged second poll", async () => {
	await assertCachedCompletionPoll(tasks);
});

test("registry updates use a cached snapshot and isolate nested mutations until persistence", async () => {
	await assertCachedRegistryUpdate(tasks, taskRegistryReader);
});

test("the next completion poll uses an externally replaced registry with unchanged size and time", async () => {
	const root = tempRuntime();
	fs.mkdirSync(join(root, "outbox", "engineer"), { recursive: true });
	const record = { taskId: "child", agent: "engineer", task: "work", kind: "pane" as const, status: "running" as const, createdAt: "2026-09-30T00:00:00Z", paneId: "%1", transcriptPath: "before.jsonl" };
	await tasks.writeTaskRegistry(root, { child: record });
	const file = taskRegistryPath(root);
	fs.utimesSync(file, 1_800_000_000, 1_800_000_000);
	const emitted: Emitted = [];
	await tasks.pollPaneCompletions(root, fakePi(emitted));
	// Another Pi process publishes an atomic replacement; equal size and mtime
	// must not hide its new pane and transcript from completion collection.
	await tasks.writeTaskRegistry(root, { child: { ...record, paneId: "%2", transcriptPath: "latest.jsonl" } });
	fs.utimesSync(file, 1_800_000_000, 1_800_000_000);
	fs.writeFileSync(join(root, "outbox", "engineer", "child.json"), JSON.stringify({ taskId: "child", agent: "engineer", status: "completed", summary: "done" }));
	assert.equal(await tasks.pollPaneCompletions(root, fakePi(emitted)), 1);
	assert.deepEqual(emitted.filter(({ name }) => name === "subagents:completed").map(({ payload }) => [payload.paneId, payload.transcriptPath]), [["%2", "latest.jsonl"]]);
});

test("registry updates keep external records that arrived after the snapshot was cached", async () => {
	const root = tempRuntime();
	await tasks.writeTaskRegistry(root, {});
	taskRegistryReader.read(root);
	const external = { taskId: "external", agent: "scout", task: "work", status: "running" as const, createdAt: "2026-09-30T00:00:00Z" };
	await tasks.writeTaskRegistry(root, { external });
	await tasks.updateTaskRegistry(root, (records) => { records.external!.status = "completed"; });
	assert.deepEqual(await tasks.readTaskRegistry(root), { external: { ...external, status: "completed" } });
});

const controls = [
	{
		name: "per-poll registry reads",
		before: "let tasks = taskRegistryReader.read(runtimeRoot);",
		after: "let tasks = await readTaskRegistry(runtimeRoot);",
		check: assertCachedCompletionPoll,
	},
	{
		name: "per-update registry reads",
		before: "records = structuredClone(taskRegistryReader.read(runtimeRoot));",
		after: "records = structuredClone(await readTaskRegistry(runtimeRoot));",
		check: (runtime: typeof tasks) => assertCachedRegistryUpdate(runtime, taskRegistryReader),
	},
	{
		name: "shared nested mutations",
		before: "records = structuredClone(taskRegistryReader.read(runtimeRoot));",
		after: "records = { ...taskRegistryReader.read(runtimeRoot) };",
		check: (runtime: typeof tasks) => assertCachedRegistryUpdate(runtime, taskRegistryReader),
	},
];
for (const control of controls) {
	test(`must-fail control: ${control.name} violates the real-function assertion`, async () => {
		const mutant = await importRuntimeCopy("tasks.ts", control.before, control.after) as typeof tasks;
		await assert.rejects(() => control.check(mutant), control.name === "shared nested mutations" ? TypeError : assert.AssertionError);
	});
}
