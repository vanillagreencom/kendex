import { expect, test } from "bun:test";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { forEachSessionJsonlLineAsync } from "../extensions/qol/session-search/jsonl.ts";
import { runtimeCopy, scratch } from "./search-fixture.ts";

test("async JSONL keeps split UTF-8 records, skips oversized lines and closes on cancellation", async () => {
	const root = scratch();
	try {
		const path = join(root, "stream.jsonl");
		const first = `${"a".repeat(65535)}🐈`;
		writeFileSync(path, `${first}\r\n${"x".repeat(2 * 1024 * 1024 + 1)}\nlast`);
		const check = async (read: typeof forEachSessionJsonlLineAsync) => {
			const lines: string[] = [];
			await read(path, (line) => lines.push(line), new AbortController().signal);
			expect(lines).toEqual([first, "last"]);
			const selected: string[] = [];
			await read(path, (line) => { selected.push(line); return false; }, new AbortController().signal);
			expect(selected).toEqual([first]);
			const cancelled = new AbortController(); cancelled.abort();
			await expect(read(path, () => {}, cancelled.signal)).rejects.toThrow();
		};
		await check(forEachSessionJsonlLineAsync);
		await runtimeCopy<{ forEachSessionJsonlLineAsync: typeof forEachSessionJsonlLineAsync }>("qol/session-search/jsonl.ts", [{ file: "qol/session-search/jsonl.ts", from: "const maxLineChars = options?.maxLineChars ?? 2 * 1024 * 1024;", to: "const maxLineChars = options?.maxLineChars ?? 4 * 1024 * 1024;" }], async (mutant) => { await expect(check(mutant.forEachSessionJsonlLineAsync)).rejects.toThrow(); });
		await runtimeCopy<{ forEachSessionJsonlLineAsync: typeof forEachSessionJsonlLineAsync }>("qol/session-search/jsonl.ts", [{ file: "qol/session-search/jsonl.ts", from: 'if (!skipping && onLine(pending.endsWith("\\r") ? pending.slice(0, -1) : pending) === false) return;', to: 'if (!skipping && onLine(pending.endsWith("\\r") ? pending.slice(0, -1) : pending) === false) void 0;' }], async (mutant) => { await expect(check(mutant.forEachSessionJsonlLineAsync)).rejects.toThrow(); });
	} finally { rmSync(root, { recursive: true, force: true }); }
});
