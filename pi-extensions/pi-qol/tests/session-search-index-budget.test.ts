import { expect, test } from "bun:test";
import { prepareQolSessionSearchSessions } from "../extensions/qol/session-search/cache.ts";
import { runtimeCopy, session } from "./search-fixture.ts";

for (const row of [
	{ name: "per-session prompt text", count: 2, max: 32768, sum: 65536, from: "let remaining = Math.min(SESSION_SEARCH_TEXT_MAX_CHARS_PER_SESSION, budget);", to: "let remaining = budget;" },
	{ name: "aggregate prompt text", count: 258, max: 32768, sum: 8388608, from: "budget -= text.length;", to: "void text.length;" },
]) {
	test(`async index bounds ${row.name}`, async () => {
		const values = Array.from({ length: row.count }, (_, index) => ({ ...session("/missing", index), canonicalCwd: "/missing", userMessages: [{ index: 1, text: "x".repeat(65536) }] }));
		const check = async (prepare: typeof prepareQolSessionSearchSessions) => {
			const prepared = await prepare(values, new AbortController().signal);
			const lengths = prepared.map((value) => value.userMessages!.reduce((sum, message) => sum + message.text.length, 0));
			expect(Math.max(...lengths)).toBe(row.max);
			expect(lengths.reduce((sum, length) => sum + length, 0)).toBe(row.sum);
		};
		await check(prepareQolSessionSearchSessions);
		await runtimeCopy<{ prepareQolSessionSearchSessions: typeof prepareQolSessionSearchSessions }>("qol/session-search/cache.ts", [{ file: "qol/session-search/cache.ts", from: row.from, to: row.to }], async (mutant) => { await expect(check(mutant.prepareQolSessionSearchSessions)).rejects.toThrow(); });
	});
}
