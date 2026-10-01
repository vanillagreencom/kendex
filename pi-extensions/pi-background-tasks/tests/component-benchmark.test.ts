import { expect, test } from "bun:test";
import { assertComponentBenchmarkBounds, runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS, type ComponentBenchmark } from "./fixtures/spawn-child-runner.js";

// An explicit measurement invocation supplies a baseline; ordinary package CI needs no git history.
const baseline = process.env.PI_BG_BENCHMARK_BASE_REF;
if (baseline === "") throw new Error("PI_BG_BENCHMARK_BASE_REF is empty");

test("restored 50 MB dashboard frames bound log operations and command wrapping", () => {
	const result = runSpawnFixture("component-benchmark.ts", {}) as ComponentBenchmark;
	console.log(`branch component benchmark: ${JSON.stringify(result)}`);
	assertComponentBenchmarkBounds(result);
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: bypassing the command cache exceeds the benchmark operation bound", () => {
	const result = runSpawnFixture("component-benchmark.ts", {}, {
		file: "extensions/dashboard.ts",
		from: "if (!cached || cached.value !== value || cached.width !== detailWidth)",
		to: "if (true || !cached || cached.value !== value || cached.width !== detailWidth)",
	}) as ComponentBenchmark;
	expect(() => assertComponentBenchmarkBounds(result)).toThrow("component operations: steady");
}, SPAWN_FIXTURE_TIMEOUT_MS);

test.skipIf(baseline === undefined)("must-fail: main exceeds the same dashboard operation bound", () => {
	const result = runSpawnFixture("component-benchmark.ts", {}, undefined, baseline) as ComponentBenchmark;
	console.log(`main component benchmark: ${JSON.stringify(result)}`);
	expect(result.phases[0].commandWraps).toBe(30);
	expect(result.phases[0].syncReads).toBe(1);
	expect(result.phases[0].wholeLogReads).toBe(0);
	expect(result.phases[6].syncReads).toBe(1);
	expect(() => assertComponentBenchmarkBounds(result)).toThrow("component operations: steady");
}, SPAWN_FIXTURE_TIMEOUT_MS);