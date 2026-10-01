import assert from "node:assert/strict";
import test, { after } from "node:test";
import * as pane from "../extensions/subagent/pane.js";
import { assertQueuedPaneDedup, cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("pane queue uses the owner's working phase for duplicate tasks", () => assertQueuedPaneDedup(pane));

test("control: queue ignores the working phase and duplicates a live task", async () => {
	const mutant = await importRuntimeCopy("pane.ts", 'taskStatus(record.status).phase === "working"', 'false && taskStatus(record.status).phase === "working"') as typeof pane;
	await assert.rejects(() => assertQueuedPaneDedup(mutant), { name: "AssertionError", message: /working task must remain the only queued task/ });
});
