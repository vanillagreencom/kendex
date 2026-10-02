import { expect, mock, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { sessionFixture } from "./lib/session-fixture.ts";

mock.module("@earendil-works/pi-tui", () => ({
	truncateToWidth: (text: string, width: number) => text.slice(0, width),
	visibleWidth: (text: string) => text.length,
}));

// Unbounded, each prompt below backtracks for seconds under V8 and up to
// JavaScriptCore's own backtracking limit, about half a second, under bun; ten
// of them run past the two-second bound. The 250 ms deadline plus the runtime's
// interrupt latency stays under it.
test("a catastrophic re: query stops at its deadline with RegexTimeoutError", async () => {
	const { matchSessions, parseQuery, RegexTimeoutError } = await import("../extensions/search.ts");
	const path = join(sessionFixture(), "session.jsonl");
	const prompt = JSON.stringify({ type: "message", message: { role: "user", content: `${"a".repeat(28)}!` } });
	writeFileSync(path, `${Array.from({ length: 10 }, () => prompt).join("\n")}\n`);
	const session = { path, firstMessage: "", name: "" } as never;

	const started = performance.now();
	expect(() => matchSessions([session], parseQuery("re:^(a|a)+$"))).toThrow(RegexTimeoutError);
	expect(performance.now() - started).toBeLessThan(2_000);
});
