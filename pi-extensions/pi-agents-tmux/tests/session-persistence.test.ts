import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { after } from "node:test";
import {
	readLastSessionEntryId,
	sessionFileTailMatchesLeaf,
	stableSessionSnapshotFingerprint,
} from "../extensions/subagent/session-persistence.js";

const tempDirs: string[] = [];

after(() => {
	for (const dir of tempDirs) rmSync(dir, { force: true, recursive: true });
});

function tempSession(lines: unknown[]): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-agents-session-"));
	tempDirs.push(dir);
	const file = join(dir, "session.jsonl");
	writeFileSync(file, `${lines.map((line) => JSON.stringify(line)).join("\n")}\n`, "utf8");
	return file;
}

test("readLastSessionEntryId returns the final non-header entry id", async () => {
	const file = tempSession([
		{ type: "session", id: "session-id" },
		{ type: "message", id: "user-1", parentId: null, message: { role: "user", content: "hi" } },
		{ type: "custom", id: "custom-2", parentId: "user-1", customType: "x", data: {} },
	]);
	assert.equal(await readLastSessionEntryId(file), "custom-2");
});

test("sessionFileTailMatchesLeaf detects stale duplicate writers", async () => {
	const file = tempSession([
		{ type: "session", id: "session-id" },
		{ type: "message", id: "old-leaf", parentId: null, message: { role: "user", content: "old" } },
		{ type: "message", id: "new-leaf", parentId: "old-leaf", message: { role: "assistant", content: [] } },
	]);
	const staleCtx = { sessionManager: { getSessionFile: () => file, getLeafId: () => "old-leaf" } };
	const currentCtx = { sessionManager: { getSessionFile: () => file, getLeafId: () => "new-leaf" } };
	assert.equal(await sessionFileTailMatchesLeaf(staleCtx), false);
	assert.equal(await sessionFileTailMatchesLeaf(currentCtx), true);
});

test("stableSessionSnapshotFingerprint is order-stable for object keys", () => {
	assert.equal(
		stableSessionSnapshotFingerprint({ panes: { b: 2, a: 1 }, tasks: { z: { n: 1, m: 2 } } }),
		stableSessionSnapshotFingerprint({ tasks: { z: { m: 2, n: 1 } }, panes: { a: 1, b: 2 } }),
	);
});
