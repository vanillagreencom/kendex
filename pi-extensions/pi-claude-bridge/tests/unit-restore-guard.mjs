/**
 * Tests for shouldRestorePersistedBridgeEntry.
 *
 * The guard exists to keep forks from inheriting the parent's pointer at the
 * parent's external Claude jsonl. When pi forks a session, createBranchedSession
 * duplicates every non-label entry (including our claude-bridge-session markers)
 * from root→leaf into the fork pi.jsonl. The guard rejects markers whose
 * piSessionId or cwd does not match the active session, forcing the bridge
 * down the rebuild path instead.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { shouldRestorePersistedBridgeEntry } from "../src/index.ts";

const ENTRY = (overrides = {}) => ({
	sessionId: "claude-abc",
	cursor: 12,
	cwd: "/repo",
	piSessionId: "pi-A",
	fingerprint: "deadbeef",
	updatedAt: "2026-01-01T00:00:00Z",
	...overrides,
});

describe("shouldRestorePersistedBridgeEntry", () => {
	it("checks the persisted identity against the active session", () => {
		const rows = [
			{ name: "matching identity", entry: ENTRY(), currentId: "pi-A", cwd: "/repo", expected: undefined },
			{ name: "forked session", entry: ENTRY({ piSessionId: "pi-PARENT" }), currentId: "pi-FORK", cwd: "/repo", expected: "restore-session-mismatch=pi-PARENT current=pi-FORK" },
			{ name: "missing session identity", entry: ENTRY({ piSessionId: undefined }), currentId: "pi-A", cwd: "/repo", expected: "restore-session-missing=piSessionId" },
			{ name: "changed directory", entry: ENTRY({ cwd: "/old" }), currentId: "pi-A", cwd: "/new", expected: "restore-cwd-mismatch=/old current=/new" },
			{ name: "unknown current directory", entry: ENTRY(), currentId: "pi-A", cwd: undefined, expected: undefined },
			{ name: "unknown current session", entry: ENTRY(), currentId: undefined, cwd: "/repo", expected: undefined },
		];
		for (const { name, entry, currentId, cwd, expected } of rows) {
			assert.equal(shouldRestorePersistedBridgeEntry(entry, currentId, cwd)?.split("\n")[0], expected, name);
		}
	});
});
