import { expect, test } from "bun:test";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

// The registered extension runs with outputSettleMs and
// outputWakeBudgetMaxWakes unset: twelve settled bursts fire on the default
// settle window, and the default count budget lets ten of them wake.
test("unset wake settings run on the shipped defaults", () => {
	const result = runSpawnFixture("spawn-extension.ts", { mode: "wake-defaults" }) as { wakeEvidence: unknown };
	expect(result.wakeEvidence).toEqual({ outputWakes: 10, budgetNotices: 1 });
}, SPAWN_FIXTURE_TIMEOUT_MS);
