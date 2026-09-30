import assert from "node:assert/strict";
import * as fs from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { spyOn } from "bun:test";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import { atomicWriteFile } from "../extensions/subagent/file-lock.js";
import { taskRegistryReader } from "../extensions/subagent/task-records.js";
import * as tasks from "../extensions/subagent/tasks.js";
import { assertCachedCompletionPoll, assertCachedRegistryUpdate, assertSequentialUsageUpdates, cleanupTempRuntimes, importRuntimeCopy, taskRegistryReads, tempRuntime } from "./browser-fixture.js";
import { fakePi, type Emitted } from "./needs-completion-fixture.js";

after(cleanupTempRuntimes);
after(() => taskRegistryReader.clear());

test("completion polling reads no registry content on an unchanged second poll", async () => {
	await assertCachedCompletionPoll(tasks);
});

test("registry updates use a cached snapshot and isolate nested mutations until persistence", async () => {
	await assertCachedRegistryUpdate(tasks, taskRegistryReader);
});

test("sequential child usage writes and the next poll reuse the reader-owned snapshot", async () => {
	await assertSequentialUsageUpdates(tasks, taskRegistryReader);
});

test("a failed atomic replacement does not publish the mutator's records", async () => {
	const root = tempRuntime();
	await tasks.writeTaskRegistry(root, { child: { taskId: "child", agent: "engineer", task: "work", status: "running", createdAt: "2026-09-30T00:00:00Z", filesChanged: ["before.ts"] } });
	const snapshot = taskRegistryReader.read(root);
	const rename = spyOn(fs.promises, "rename").mockRejectedValueOnce(new Error("replacement failed"));
	try {
		await assert.rejects(() => tasks.updateTaskRegistry(root, (records) => {
			records.child!.filesChanged!.push("unwritten.ts");
		}), /replacement failed/);
	} finally {
		rename.mockRestore();
	}
	assert.equal(taskRegistryReader.read(root), snapshot);
	assert.deepEqual((await tasks.readTaskRegistry(root)).child?.filesChanged, ["before.ts"]);
});

test("the next completion poll uses an externally replaced registry with unchanged size and time", async () => {
	const root = tempRuntime();
	fs.mkdirSync(join(root, "outbox", "engineer"), { recursive: true });
	const record = { taskId: "child", agent: "engineer", task: "work", kind: "pane" as const, status: "running" as const, createdAt: "2026-09-30T00:00:00Z", paneId: "%1", transcriptPath: "before.jsonl" };
	await tasks.writeTaskRegistry(root, { child: record });
	const file = taskRegistryPath(root);
	fs.utimesSync(file, 1_800_000_000, 1_800_000_000);
	const size = fs.statSync(file).size;
	const emitted: Emitted = [];
	await tasks.pollPaneCompletions(root, fakePi(emitted));
	// Another Pi process publishes an atomic replacement; equal size and mtime
	// must not hide its new pane and transcript from completion collection.
	await atomicWriteFile(file, `${JSON.stringify({ child: { ...record, paneId: "%2", transcriptPath: "latest.jsonl" } }, null, "\t")}\n`);
	fs.utimesSync(file, 1_800_000_000, 1_800_000_000);
	assert.equal(fs.statSync(file).size, size);
	fs.writeFileSync(join(root, "outbox", "engineer", "child.json"), JSON.stringify({ taskId: "child", agent: "engineer", status: "completed", summary: "done" }));
	assert.equal(await taskRegistryReads(root, async () => {
		assert.equal(await tasks.pollPaneCompletions(root, fakePi(emitted)), 1);
	}), 1);
	assert.deepEqual(emitted.filter(({ name }) => name === "subagents:completed").map(({ payload }) => [payload.paneId, payload.transcriptPath]), [["%2", "latest.jsonl"]]);
});

test("registry updates keep external records that arrived after the snapshot was cached", async () => {
	const root = tempRuntime();
	await tasks.writeTaskRegistry(root, {});
	taskRegistryReader.read(root);
	const external = { taskId: "external", agent: "scout", task: "work", status: "running" as const, createdAt: "2026-09-30T00:00:00Z" };
	await atomicWriteFile(taskRegistryPath(root), JSON.stringify({ external }));
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
		before: "records = taskRegistryReader.mutableCopy(runtimeRoot);",
		after: "records = structuredClone(await readTaskRegistry(runtimeRoot));",
		check: (runtime: typeof tasks) => assertCachedRegistryUpdate(runtime, taskRegistryReader),
	},
	{
		name: "shared nested mutations",
		before: "records = taskRegistryReader.mutableCopy(runtimeRoot);",
		after: "records = { ...taskRegistryReader.read(runtimeRoot) };",
		check: (runtime: typeof tasks) => assertCachedRegistryUpdate(runtime, taskRegistryReader),
	},
	{
		name: "local-write snapshot invalidation",
		before: "mutator(records);\n\t\tconst content = await atomicWriteJson(filePath, records);\n\t\ttaskRegistryReader.rememberWrite(runtimeRoot, content);",
		after: "mutator(records);\n\t\tconst content = await atomicWriteJson(filePath, records);\n\t\ttaskRegistryReader.rememberWrite(runtimeRoot, content);\n\t\ttaskRegistryReader.clear();",
		check: (runtime: typeof tasks) => assertSequentialUsageUpdates(runtime, taskRegistryReader),
	},
	{
		name: "replacement writer snapshot invalidation",
		before: "taskRegistryReader.rememberWrite(runtimeRoot, content);\n\t});\n}\n\nexport async function updateTaskRegistry",
		after: "taskRegistryReader.rememberWrite(runtimeRoot, content);\n\t\ttaskRegistryReader.clear();\n\t});\n}\n\nexport async function updateTaskRegistry",
		check: assertCachedCompletionPoll,
	},
];
for (const control of controls) {
	test(`must-fail control: ${control.name} violates the real-function assertion`, async () => {
		const mutant = await importRuntimeCopy("tasks.ts", control.before, control.after) as typeof tasks;
		await assert.rejects(() => control.check(mutant), control.name === "shared nested mutations" ? TypeError : assert.AssertionError);
	});
}
