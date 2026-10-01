import { expect, test } from "bun:test";
import { runNodeFixture } from "./fixtures/node-runtime.js";

test("asynchronous per-task log tails bound reads, invalidate metadata, and report errors", async () => {
	const result = await runNodeFixture("log-tail.ts");
	expect(result.error).toBeUndefined();
	expect(result.status, result.stderr).toBe(0);
}, 10_000);

test("must-fail: unbounded reads and a disabled tail cache each fail the log reader suite", async () => {
	const mutations = [
		{ from: "const length = Math.min(size, lengthLimit);", to: "const length = size;" },
		{ from: "if (tail?.logFile === task.logFile", to: "if (false && tail?.logFile === task.logFile" },
	];
	expect.assertions(mutations.length * 2);
	for (const mutation of mutations) {
		const result = await runNodeFixture("log-tail.ts", { file: "extensions/log-tail.ts", ...mutation });
		expect(result.error).toBeUndefined();
		expect(result.status, result.stderr).toBe(1);
	}
}, 10_000);
