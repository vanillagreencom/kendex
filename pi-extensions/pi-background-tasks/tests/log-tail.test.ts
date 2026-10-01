import { expect, test } from "bun:test";
import { runNodeFixture } from "./fixtures/node-runtime.js";

test("asynchronous per-task log tails preserve character limits, bound reads, invalidate metadata, and report errors", async () => {
	const result = await runNodeFixture("log-tail.ts");
	expect(result.error).toBeUndefined();
	expect(result.status, result.stderr).toBe(0);
}, 10_000);

test("must-fail: byte-as-character limits, unbounded reads and a disabled tail cache fail the log reader suite", async () => {
	const mutations = [
		{ from: "const length = Math.min(size, 3 * lengthLimit + 1);", to: "const length = Math.min(size, lengthLimit);", failure: "character tail: bmp" },
		{ from: "const length = Math.min(size, 3 * lengthLimit + 1);", to: "const length = size;", failure: "UTF-8 byte bound: bmp" },
		{ from: "if (tail?.logFile === task.logFile", to: "if (false && tail?.logFile === task.logFile", failure: "unchanged tasks must keep independent caches" },
	];
	expect.assertions(mutations.length * 3);
	for (const mutation of mutations) {
		const result = await runNodeFixture("log-tail.ts", { file: "extensions/log-tail.ts", ...mutation });
		expect(result.error).toBeUndefined();
		expect(result.status, result.stderr).toBe(1);
		expect(result.stderr).toContain(mutation.failure);
	}
}, 10_000);
