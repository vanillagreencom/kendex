import { expect, mock, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

mock.module("@earendil-works/pi-tui", () => ({
	truncateToWidth: (text: string, width: number) => text.slice(0, width),
	visibleWidth: (text: string) => text.length,
}));

function promptSessions(root: string, count: number, prompt: string, prompts = 1): never[] {
	const line = JSON.stringify({ type: "message", message: { role: "user", content: prompt } });
	return Array.from({ length: count }, (_, index) => {
		const path = join(root, `session-${index}.jsonl`);
		writeFileSync(path, `${Array.from({ length: prompts }, () => line).join("\n")}\n`);
		return { path, firstMessage: "", name: "" } as never;
	});
}

// Unbounded, each prompt below backtracks for seconds under V8 and up to
// JavaScriptCore's own backtracking limit, about half a second, under bun; the
// twenty of them run past ten seconds. Bun interrupts a match only when it ends,
// so each 250 ms deadline lands near 550 ms: the batch's deadline, then the first
// session's own, take about 1.1 s, and the 5 s bound leaves room for a loaded runner.
test("a catastrophic re: query stops at one session's deadline with RegexTimeoutError", async () => {
	const { matchSessions, parseQuery, RegexTimeoutError } = await import("../extensions/search.ts");
	const sessions = promptSessions(sessionFixture(), 2, `${"a".repeat(28)}!`, 10);

	const started = performance.now();
	expect(() => matchSessions(sessions, parseQuery("re:^(a|a)+$"))).toThrow(RegexTimeoutError);
	expect(performance.now() - started).toBeLessThan(5_000);
});

// `error.*timeout` over repeated "error " costs time quadratic in the prompt's
// length. The prompt grows in steps that about double one pass's cost until a
// pass costs 40 ms on this machine, so a pass stays near 80 ms at most, under the
// 250 ms deadline; enough sessions are matched together that the batch passes
// 600 ms.
test("a re: batch past the deadline whose sessions each stay under it matches every session", async () => {
	const { matchSessions, parseQuery } = await import("../extensions/search.ts");
	const pattern = /error.*timeout/i;
	let prompt = "";
	let cost = 0;
	for (let words = 1_000; cost < 40; words = Math.ceil(words * 1.4)) {
		prompt = "error ".repeat(words);
		const started = performance.now();
		prompt.search(pattern);
		cost = performance.now() - started;
	}
	const sessions = promptSessions(sessionFixture(), Math.ceil(600 / cost), prompt);

	expect(matchSessions(sessions, parseQuery(`re:${pattern.source}`))).toEqual(sessions.map(() => ({ matches: false, score: 0 })));
});
