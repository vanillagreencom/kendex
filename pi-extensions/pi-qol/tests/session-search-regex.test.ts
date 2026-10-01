import { expect, spyOn, test } from "bun:test";
import { Worker } from "node:worker_threads";
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
	const value = { ...session("/missing"), userMessages: [{ index: 1, text: "before NEEDLE after" }] };
	const hits = await searchQolSessionHits([value], "re:needle", "/missing", new AbortController().signal);
	expect(hits.map((hit) => hit.snippet)).toEqual(["before NEEDLE after"]);
	const controller = new AbortController();
	const pending = searchQolSessionHits([value], "re:needle", "/missing", controller.signal);
	controller.abort();
	await expect(pending).rejects.toThrow("cancelled");
});
