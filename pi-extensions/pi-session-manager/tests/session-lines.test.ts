import { expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

import { forEachSessionJsonlLine } from "../extensions/session-lines.ts";

const longRecord = `{"text":"${"é".repeat(500)}"}`;

for (const row of [
	{ name: "lines split across small chunks", content: "one\r\ntwo\nthree", chunkSize: 3, expected: ["one", "two", "three"] },
	{ name: "a record spanning many chunks, a multibyte character and a CRLF split between them", content: `${longRecord}\r\nnext\n`, chunkSize: 7, expected: [longRecord, "next"] },
	{ name: "blank lines between records", content: "a\n\nb\n", chunkSize: 2, expected: ["a", "", "b"] },
]) {
	test(`session JSONL line reader: ${row.name}`, () => {
		const path = join(sessionFixture(), "chunks.jsonl");
		writeFileSync(path, row.content);
		const lines: string[] = [];
		forEachSessionJsonlLine(path, (line) => lines.push(line), row.chunkSize);
		expect(lines).toEqual(row.expected);
	});
}
