import { expect, test } from "bun:test";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

test("restored exits read their tail before delivery and suppress completions after clear or shutdown", () => {
	const result = runSpawnFixture("restored-exit.ts", {}) as { delivered: number };
	expect(result.delivered).toBe(1);
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: dropping the asynchronous exit tail fails the registered lifecycle suite", () => {
	expect(() => runSpawnFixture("restored-exit.ts", {}, {
		file: "extensions/background-tasks.ts", from: "options, tail) });", to: "options, \"\") });",
	})).toThrow("spawn_fixture.child_exit=1");
}, SPAWN_FIXTURE_TIMEOUT_MS);
