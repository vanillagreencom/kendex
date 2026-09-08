import "./lib/debug-env.mjs";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { it } from "node:test";
import { __testSetBridgeIntegrityState } from "../src/bridge-state.ts";
import { verifyWrittenSession } from "../src/session-persistence.ts";

const rows = [
	{ name: "healthy", records: [{ sessionId: "session" }], count: 1 },
	{ name: "missing file", records: undefined, count: 1, key: (path) => `session-file-missing=${path}` },
	{ name: "missing record", records: [{ sessionId: "session" }], count: 2, key: () => "session-record-count=1 expected=2" },
];
for (const row of rows) it(`session notification: ${row.name}`, () => {
	const root = mkdtempSync(join(tmpdir(), "bridge-session-notification-"));
	const path = join(root, "session.jsonl");
	const notifications = [];
	__testSetBridgeIntegrityState({ ui: { notify: (message, level) => notifications.push({ message, level }) } });
	try {
		if (row.records) writeFileSync(path, row.records.map((record) => JSON.stringify(record)).join("\n"));
		verifyWrittenSession(path, "session", row.count, root, undefined);
		assert.deepEqual(notifications.map(({ message, level }) => [message.split("\n")[0], level]), row.key ? [[row.key(path), "warning"]] : []);
	} finally {
		__testSetBridgeIntegrityState({ ui: null });
		rmSync(root, { recursive: true, force: true });
	}
});
