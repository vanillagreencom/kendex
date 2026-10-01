import { expect, test } from "bun:test";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

test("the dashboard renders before its log read and caches command layout by content and width", () => {
	const result = runSpawnFixture("dashboard.ts", {}) as { commandWraps: number };
	expect(result.commandWraps).toBe(4);
}, SPAWN_FIXTURE_TIMEOUT_MS);

test("must-fail: bypassing the command cache fails the dashboard suite", () => {
	expect(() => runSpawnFixture("dashboard.ts", {}, {
		file: "extensions/dashboard.ts",
		from: "if (!cached || cached.value !== value || cached.width !== detailWidth)",
		to: "if (true || !cached || cached.value !== value || cached.width !== detailWidth)",
	})).toThrow("unchanged command must use the cache");
}, SPAWN_FIXTURE_TIMEOUT_MS);
