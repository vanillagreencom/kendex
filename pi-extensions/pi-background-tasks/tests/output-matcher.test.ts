import { expect, test } from "bun:test";
import { runNodeFixture } from "./fixtures/node-runtime.js";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

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

test("registered output timeout completes, reports once, suppresses output and retains exit delivery", () => {
	const result = runSpawnFixture("spawn-extension.ts", { mode: "matcher" }) as { matcherEvidence: unknown };
	expect(result.matcherEvidence).toEqual({ callbackCompletions: 21, notices: 1, outputWakes: 0, exitWakes: 1 });
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: rethrowing the matcher timeout rejects the registered output callback", () => {
	expect(() => runSpawnFixture("spawn-extension.ts", { mode: "matcher" }, {
		file: "extensions/background-tasks.ts",
		from: "if (!(error instanceof OutputMatcherBudgetError)) throw error;",
		to: "if (true || !(error instanceof OutputMatcherBudgetError)) throw error;",
	})).toThrow("spawn_fixture.output_callback=rejected");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: dropping the matcher notice leaves headless callers without a failure", () => {
	expect(() => runSpawnFixture("spawn-extension.ts", { mode: "matcher" }, {
		file: "extensions/wake-events.ts",
		from: "deps.sendMessage({\n\t\tcontent: `Background task ${task.id}: ${boundedError}",
		to: "((..._args: unknown[]) => {})({\n\t\tcontent: `Background task ${task.id}: ${boundedError}",
	})).toThrow("matcher must report one notice without output wakes");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: recording a timeout as an ordinary non-match loses its cause", () => {
	expect(() => runSpawnFixture("spawn-extension.ts", { mode: "matcher" }, {
		file: "extensions/background-tasks.ts",
		from: "persistScheduledOutputDrop(task, pending, \"notify-pattern-timeout\",",
		to: "persistScheduledOutputDrop(task, pending, \"notify-pattern-no-match\",",
	})).toThrow("notify-pattern-timeout");
}, SPAWN_FIXTURE_TIMEOUT_MS);

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
