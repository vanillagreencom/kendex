import { expect, test } from "bun:test";
import { runSpawnFixture } from "./fixtures/spawn-child-runner.js";

const rows = [
	{ name: "POSIX spawn requests a detached process group", platform: "linux", detached: true },
	{ name: "Windows spawn keeps the supported attached option", platform: "win32", detached: false },
];

test("registered extension spawn hardening rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "spawn hardening table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const result = runSpawnFixture("spawn-extension.ts", { mode: "spawn", platform: row.platform }) as Record<string, unknown>;
		expect({ spawn: result.spawn, before: result.before, final: result.final, signals: result.signals, childSignals: result.childSignals, unexpected: result.unexpected, remainingTimers: result.remainingTimers }, row.name).toStrictEqual({
			spawn: { file: "fixture-shell", args: ["-c", "fixture command"], detached: row.detached, stdio: ["ignore", "pipe", "pipe"], cwdIsPrivate: true, piRootIsPrivate: true, resultAction: "spawn", resultId: "bg-1", resultPid: 4242 },
			before: { id: "bg-1", pid: 4242, status: "running", reason: null, exitCode: null, exitNotified: false },
			final: { id: "bg-1", pid: 4242, status: "completed", reason: "self-exit", exitCode: 0, exitNotified: false },
			signals: [], childSignals: [], unexpected: [], remainingTimers: [],
		});
	}
});
