import assert from "node:assert/strict";
import test, { after } from "node:test";
import subagentExtension from "../extensions/subagent/index.js";
import { cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";
import { assertSharedRegistryLifecycle } from "./extension-fixture.js";

after(cleanupTempRuntimes);

test("the extension shares its warmed registry with the parent poll and releases it on shutdown", async () => {
	await assertSharedRegistryLifecycle(subagentExtension);
});

const controls = [
	{
		name: "the former factory-private reader",
		actual: 1, expected: 0,
		before: 'import { taskRegistryReader, taskNumberById } from "./task-records.js";',
		after: 'import { TaskRegistryReader, taskNumberById } from "./task-records.js";',
		additionalEdits: [{
			before: "const transcriptTails = new TranscriptTailCache();",
			after: "const transcriptTails = new TranscriptTailCache();\n\tconst taskRegistryReader = new TaskRegistryReader();",
		}],
	},
	{
		name: "retaining the shared reader on shutdown",
		actual: 0, expected: 1,
		before: "transcriptTails.clear();\n\t\ttaskRegistryReader.clear();\n\t\tappliedRegistryRecords.clear();\n\t\tresetPaneCompletionDedup();",
		after: "transcriptTails.clear();\n\t\tvoid taskRegistryReader;\n\t\tappliedRegistryRecords.clear();\n\t\tresetPaneCompletionDedup();",
		additionalEdits: [],
	},
];

for (const control of controls) {
	test(`must-fail control: ${control.name} violates the extension lifecycle assertion`, async () => {
		const mutant = await importRuntimeCopy("index.ts", control.before, control.after, control.additionalEdits) as typeof import("../extensions/subagent/index.js");
		await assert.rejects(() => assertSharedRegistryLifecycle(mutant.default), {
			name: "AssertionError", actual: control.actual, expected: control.expected, operator: "strictEqual",
		});
	});
}