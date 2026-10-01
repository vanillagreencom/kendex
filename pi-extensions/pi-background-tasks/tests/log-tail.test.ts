import { expect, test } from "bun:test";
import { runNodeFixture } from "./fixtures/node-runtime.js";

test("asynchronous per-task log tails preserve character limits, bound reads, invalidate metadata, and report errors", async () => {
	const result = await runNodeFixture("log-tail.ts");
	expect(result.error).toBeUndefined();
	expect(result.status, result.stderr).toBe(0);
}, 10_000);

test("must-fail: character, cache and shared acquisition defects fail the log reader suite", async () => {
	const mutations = [
		{ name: "character bound", from: "const length = Math.min(size, 3 * lengthLimit + 1);", to: "const length = Math.min(size, lengthLimit);", failure: "character tail: bmp" },
		{ name: "byte bound", from: "const length = Math.min(size, 3 * lengthLimit + 1);", to: "const length = size;", failure: "UTF-8 byte bound: bmp" },
		{ name: "task cache", from: "if (tail?.logFile === task.logFile", to: "if (false && tail?.logFile === task.logFile", failure: "unchanged tasks must keep independent caches" },
		{ name: "shared admission", from: "while (active >= PROBE_CONCURRENCY && valid())", to: "while (false && active >= PROBE_CONCURRENCY && valid())", failure: "shared admission must hold through close" },
		{ name: "queued validity", from: "tails.get(task) === owned && isCurrent(task)", to: "true", failure: "stale queued reads must not open" },
		{ name: "close ownership", from: "try { if (file) await file.close(); }\n\t\t\t\t\tfinally { active -= 1; queued.shift()?.(); }", to: "active -= 1; queued.shift()?.(); if (file) await file.close();", failure: "shared admission must hold through close" },
		{ name: "clear ownership", from: "for (const wake of queued.splice(0)) wake();", to: "active = 0; for (const wake of queued.splice(0)) wake();", failure: "clear must not release active descriptors" },
	];
	expect.assertions(mutations.length * 3);
	for (const mutation of mutations) {
		const result = await runNodeFixture("log-tail.ts", { file: "extensions/log-tail.ts", ...mutation });
		console.log(JSON.stringify({ mutation: mutation.name, status: result.status, assertion: mutation.failure, matched: result.stderr.includes(mutation.failure) }));
		expect(result.error, mutation.name).toBeUndefined();
		expect(result.status, `${mutation.name}: ${result.stderr}`).toBe(1);
		expect(result.stderr, mutation.name).toContain(mutation.failure);
	}
}, 10_000);
