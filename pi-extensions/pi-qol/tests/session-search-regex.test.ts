import { expect, spyOn, test } from "bun:test";
import { Worker } from "node:worker_threads";
import { join } from "node:path";
import * as regexRuntime from "../extensions/qol/session-search/regex.ts";
import { searchQolSessionHits } from "../extensions/qol/session-search/search.ts";
import { runtimeCopy, session } from "./search-fixture.ts";

test("a pathological user regex over 1 MiB returns a deadline error without blocking input", async () => {
	const text = `${"a".repeat(1024 * 1024)}!`;
	const value = { ...session("/missing"), firstMessage: text, userMessages: [{ index: 1, text }] };
	const check = async (search: typeof searchQolSessionHits) => {
		const terminate = spyOn(Worker.prototype, "terminate");
		const unref = spyOn(Worker.prototype, "unref");
		let ticked = false;
		// A real timer proves that the busy regex does not run on Pi's input thread.
		const timer = setTimeout(() => { ticked = true; }, 5);
		const start = performance.now();
		try {
			await expect(search([value], "re:^(a+)+$", "/missing", new AbortController().signal)).rejects.toThrow("SESSION_SEARCH_REGEX_DEADLINE");
			const elapsedMs = performance.now() - start;
			console.log(`QOL_REGEX_DEADLINE ${JSON.stringify({ bytes: Buffer.byteLength(text), elapsedMs })}`);
			expect(elapsedMs).toBeLessThan(500);
			expect(ticked).toBe(true);
			expect(terminate).toHaveBeenCalledTimes(1);
			expect(unref).toHaveBeenCalledTimes(1);
		} finally {
			clearTimeout(timer);
			const exits = terminate.mock.results.map((result) => result.value);
			terminate.mockRestore();
			unref.mockRestore();
			// Keep real thread cleanup in the test, outside the response deadline.
			await Promise.all(exits);
		}
	};
	await check(searchQolSessionHits);
	await runtimeCopy<{ searchQolSessionHits: typeof searchQolSessionHits }>("qol/session-search/search.ts", [{ file: "qol/session-search/regex.ts", from: 'finish(new Error("SESSION_SEARCH_REGEX_DEADLINE: 25 ms")), 25)', to: 'finish(new Error("SESSION_SEARCH_REGEX_DEADLINE: 25 ms")), 1000)' }], async (mutant) => { await expect(check(mutant.searchQolSessionHits)).rejects.toThrow(); });
});

test("regex hit snippets use worker match positions and cancelled workers return no hits", async () => {
	const rows = [
		{ text: `${"x".repeat(300)} before NEEDLE after ${"y".repeat(300)}`, index: 308, snippet: `…${"x".repeat(16)} before NEEDLE after ${"y".repeat(123)}…` },
		{ text: `before${" ".repeat(300)}NEEDLE`, index: 306, snippet: "… NEEDLE" },
		{ text: `\n\tbefore${"\n\t".repeat(150)}NEEDLE after`, index: 308, snippet: "… NEEDLE after" },
	];
	const check = async (search: typeof searchQolSessionHits, matcher: typeof regexRuntime) => {
		// Stage a benign worker result: this assertion holds offset forwarding,
		// not the host's ability to schedule a worker within its deadline.
		const matches = spyOn(matcher, "sessionRegexMatches").mockImplementation(async (_source, texts) => texts.map((candidate) => {
			const row = rows.find((row) => row.text === candidate);
			return row ? { index: row.index, length: 6 } : null;
		}));
		try {
			for (const row of rows) {
				const value = { ...session("/missing"), userMessages: [{ index: 1, text: row.text }] };
				const hits = await search([value], "re:needle", "/missing", new AbortController().signal);
				expect(hits.map((hit) => hit.snippet)).toEqual([row.snippet]);
			}
		} finally { matches.mockRestore(); }
	};
	await check(searchQolSessionHits, regexRuntime);
	await runtimeCopy<{ searchQolSessionHits: typeof searchQolSessionHits }>("qol/session-search/search.ts", [{ file: "qol/session-search/search.ts", from: "buildPromptSnippet(message, parsed, regexMatches.get(message.text))", to: "buildPromptSnippet(message, parsed)" }], async (mutant, root) => {
		await expect(check(mutant.searchQolSessionHits, await import(join(root, "extensions/qol/session-search/regex.ts")))).rejects.toThrow();
	});
	await runtimeCopy<{ searchQolSessionHits: typeof searchQolSessionHits }>("qol/session-search/search.ts", [{ file: "qol/session-search/search.ts", from: "snippetAround(message.text, regexMatch.index", to: 'snippetAround(message.text.replace(/\\s+/g, " ").trim(), regexMatch.index' }], async (mutant, root) => {
		await expect(check(mutant.searchQolSessionHits, await import(join(root, "extensions/qol/session-search/regex.ts")))).rejects.toThrow("NEEDLE");
	});
	const controller = new AbortController();
	const value = { ...session("/missing"), userMessages: [{ index: 1, text: rows[0]!.text }] };
	const pending = searchQolSessionHits([value], "re:needle", "/missing", controller.signal);
	controller.abort();
	await expect(pending).rejects.toThrow("cancelled");
});
