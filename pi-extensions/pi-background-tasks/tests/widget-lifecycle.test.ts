import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { resolve } from "node:path";

// Separate processes isolate peer mocks, the stack registry, settings and the clock
// from other suites that run real background tasks.
for (const [scenario, seconds] of [
	["expiry-above", 15],
	["expiry-below", 15],
	["sibling", 15],
	["hide", 15],
	["shutdown", 15],
	["switch", 15],
	["boundary-before", 2_147_483.646],
	["boundary-at", 2_147_483.647],
	["thirty-days", 2_592_000],
	["overflow", 1e308],
] as const) {
	test(`widget lifecycle: ${scenario}`, () => {
		const root = resolve(import.meta.dir, "../../../tmp");
		mkdirSync(root, { recursive: true });
		const dir = mkdtempSync(resolve(root, "widget-lifecycle-"));
		try {
			const result = spawnSync(process.execPath, [resolve(import.meta.dir, "fixtures/widget-lifecycle.ts"), scenario, String(seconds)], {
				cwd: dir,
				env: { ...process.env, PI_CODING_AGENT_DIR: dir, PI_BG_TASK_DIR: dir },
				encoding: "utf8",
				timeout: 10_000,
			});
			expect({ error: result.error?.message, status: result.status, stderr: result.stderr }).toEqual({ error: undefined, status: 0, stderr: "" });
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
}
