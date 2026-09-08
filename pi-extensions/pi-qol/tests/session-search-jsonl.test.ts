import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { forEachSessionJsonlLine } from "../extensions/qol/session-search/jsonl.ts";

test("session JSONL line reader streams across small chunks", () => {
	const root = mkdtempSync(join(tmpdir(), "pi-qol-jsonl-lines-"));
	try {
		expect.hasAssertions();
		const path = join(root, "chunks.jsonl");
		writeFileSync(path, "one\r\ntwo\nthree");
		const lines: string[] = [];
		forEachSessionJsonlLine(path, (line) => lines.push(line), 3);
		expect(lines).toEqual(["one", "two", "three"]);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});
