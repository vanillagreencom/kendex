import { expect, test } from "bun:test";
import { runNodeFixture } from "./fixtures/node-runtime.js";

const baseline = process.env.PI_BG_BENCHMARK_BASE_REF;
if (baseline === "") throw new Error("PI_BG_BENCHMARK_BASE_REF is empty");

test("a pathological notify regex on 1 MB reaches its deadline and reports only once", async () => {
	const result = await runNodeFixture("output-matcher.ts");
	expect(result.error).toBeUndefined();
	expect(result.status, result.stderr).toBe(0);
	const evidence = JSON.parse(result.stdout);
	expect(evidence.bytes).toBe(1_000_000);
	expect(evidence.elapsedMs).toBeLessThan(250);
	expect(evidence.reports).toBe(1);
	expect(evidence.disabledCalls).toBe(20);
	console.log(`matcher deadline evidence: ${result.stdout.trim()}`);
}, 10_000);

test("must-fail: removing the matcher deadline hangs the same pathological test", async () => {
	const result = await runNodeFixture("output-matcher.ts", {
		file: "format.ts",
		from: "script.runInContext(context, { timeout: OUTPUT_MATCHER_DEADLINE_MS })",
		to: "script.runInContext(context)",
	});
	expect(result.error).toBe("ETIMEDOUT");
	expect(result.signal).toBe("SIGKILL");
	expect(result.stdout).toBe("");
	console.log("must-fail matcher deadline: ETIMEDOUT SIGKILL");
}, 10_000);

test.skipIf(baseline === undefined)("must-fail: main hangs on the same 1 MB pathological notify regex", async () => {
	const result = await runNodeFixture("output-matcher.ts", undefined, baseline);
	expect(result.error).toBe("ETIMEDOUT");
	expect(result.signal).toBe("SIGKILL");
	expect(result.stdout).toBe("");
	console.log("main matcher deadline: ETIMEDOUT SIGKILL after 2000 ms on 1000000 bytes");
}, 10_000);
