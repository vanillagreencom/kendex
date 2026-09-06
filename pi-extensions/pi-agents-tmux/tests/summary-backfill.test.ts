// A terminal record without a summary is backfilled from its transcript's
// last assistant text; every other shape leaves the record and the registry
// exactly as they were.

import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { after } from "node:test";
import { backfillTaskSummaryFromTranscript, readTaskRegistry, updateTaskRegistry } from "../extensions/subagent/tasks.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";
import { ABSENT, cleanupTempRuntimes, record, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

const assistantLines = [
	JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "Early output" }] } }),
	JSON.stringify({ ts: "2026-05-14T05:02:00.000Z", event: { type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "Final summary\nwith details" }] } } }),
];
const userOnly = [JSON.stringify({ type: "message", message: { role: "user", content: "hello" } })];

// The summary field of a record: its value, or ABSENT when the key is not
// on the record at all (a blank string is a value).
function summaryField(item: PaneTaskRecord | undefined): string {
	if (!item) return ABSENT;
	return Object.prototype.hasOwnProperty.call(item, "summary") ? JSON.stringify(item.summary) : ABSENT;
}

// label | transcript lines (none = the path does not exist) | record patch | registry-copy patch | expect `updated result-summary registry-summary`
const rows: Array<[string, string[] | undefined, Partial<PaneTaskRecord>, Partial<PaneTaskRecord>, string]> = [
	["a completed record takes the last assistant text", assistantLines, {}, {}, 'true "Final summary\\nwith details" "Final summary\\nwith details"'],
	["a corrupt transcript changes nothing", ["{not json"], {}, {}, `false ${ABSENT} ${ABSENT}`],
	["a missing transcript changes nothing", undefined, {}, {}, `false ${ABSENT} ${ABSENT}`],
	["a blank summary with no assistant text is removed", userOnly, { summary: "   " }, {}, `true ${ABSENT} ${ABSENT}`],
	["no summary key and no assistant text stays untouched", userOnly, {}, {}, `false ${ABSENT} ${ABSENT}`],
	["an existing summary is never overwritten", assistantLines, { summary: "some text" }, {}, 'false "some text" "some text"'],
	["a summary the registry copy gained meanwhile wins", assistantLines, {}, { summary: "registry text" }, 'false "registry text" "registry text"'],
	["a running record is not backfilled", assistantLines, { status: "running", completedAt: undefined }, {}, `false ${ABSENT} ${ABSENT}`],
	["a record without a transcript path is not backfilled", assistantLines, { transcriptPath: undefined }, {}, `false ${ABSENT} ${ABSENT}`],
];

test("summary backfill from the transcript", async () => {
	for (const [index, [label, lines, patch, registryPatch, expect]] of rows.entries()) {
		const runtimeRoot = tempRuntime();
		const taskId = `reviewer-arch-170000000${index}-77abfc41`;
		const transcriptPath = join(runtimeRoot, `transcript-${index}.jsonl`);
		if (lines) writeFileSync(transcriptPath, lines.join("\n"));
		const taskRecord = record("reviewer-arch", taskId, "2026-05-14T05:00:00.000Z", { transcriptPath, ...patch });
		await updateTaskRegistry(runtimeRoot, (records) => { records[taskId] = { ...taskRecord, ...registryPatch }; });

		const result = await backfillTaskSummaryFromTranscript(runtimeRoot, taskRecord);
		const stored = (await readTaskRegistry(runtimeRoot))[taskId];
		assert.equal(`${result.updated} ${summaryField(result.record)} ${summaryField(stored)}`, expect, label);
	}
});
