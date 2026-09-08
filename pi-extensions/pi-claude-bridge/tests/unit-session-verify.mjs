import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { verifyWrittenSession } from "../src/session-verify.js";

describe("verifyWrittenSession", () => {
	const dir = mkdtempSync(join(tmpdir(), "verify-session-"));
	const SID = "abc-123";
	const rec = (sessionId, i) => JSON.stringify({ sessionId, idx: i });
	after(() => rmSync(dir, { recursive: true, force: true }));

	it("reports each session-file integrity result", () => {
		const rows = [
			{ name: "round-trip", records: [rec(SID, 0), rec(SID, 1), rec(SID, 2)], count: 3, expected: [] },
			{ name: "missing", records: null, count: 0, expected: (path) => [`session-file-missing=${path}`] },
			{ name: "count", records: [rec(SID, 0), rec(SID, 1)], count: 5, expected: ["session-record-count=2 expected=5"] },
			{ name: "identity", records: [rec(SID, 0), rec("different-sid", 1)], count: 2, expected: ["session-id-drift=abc-123 first=abc-123 last=different-sid"] },
			{ name: "json", records: ["not json"], count: 1, expected: (path) => [`session-json-invalid=${path}`] },
		];
		for (const { name, records, count, expected } of rows) {
			const path = join(dir, `${name}.jsonl`);
			if (records !== null) writeFileSync(path, records.join("\n") + "\n");
			assert.deepEqual(
				verifyWrittenSession(path, SID, count).map((warning) => warning.split("\n")[0]),
				typeof expected === "function" ? expected(path) : expected,
				name,
			);
		}
	});
});
