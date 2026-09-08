import { expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

import { forEachSessionJsonlLine } from "../extensions/session-lines.ts";

test("session JSONL line reader streams across small chunks", () => {
	const dir = sessionFixture();
	const path = join(dir, "chunks.jsonl");
	writeFileSync(path, "one\r\ntwo\nthree");
	const lines: string[] = [];
	forEachSessionJsonlLine(path, (line) => lines.push(line), 3);
	expect(lines).toEqual(["one", "two", "three"]);
});

