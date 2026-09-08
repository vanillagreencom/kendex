import { expect, test } from "bun:test";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupStaleSpills } from "../event-history.js";
import { dir, useHistoryFixture } from "./lib/history-fixture.ts";

useHistoryFixture();
for (const row of [
	{ name: "own pid", filename: `${process.pid}.jsonl`, alive: false, keep: true },
	{ name: "dead pid", filename: "9999999.jsonl", alive: false, keep: false },
	{ name: "live pid", filename: `${process.pid + 12_345}.jsonl`, alive: true, keep: true },
	{ name: "non-spill file", filename: "ignored.txt", alive: false, keep: true },
]) {
	test(`spill cleanup ${row.name}`, () => {
		const rawDir = join(dir, "raw");
		mkdirSync(rawDir, { recursive: true });
		const file = join(rawDir, row.filename);
		writeFileSync(file, "fixture\n");
		cleanupStaleSpills(rawDir, () => row.alive);
		expect(existsSync(file)).toBe(row.keep);
	});
}
