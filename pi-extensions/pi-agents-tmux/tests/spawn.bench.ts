// Run with `npm run bench:spawn` from the package. It imports the historical
// runtime at BENCHMARK_BASELINE, whose capture runs to the faux bridge's natural
// exit, so it stays out of `npm test`; tests/pane-exec.test.ts holds the current
// deadline and kill escalation.
import assert from "node:assert/strict";
import { execCapture } from "../extensions/subagent/pane.js";
import { cleanupTempRuntimes, importMainRuntime, tempRuntime } from "./browser-fixture.js";

async function spawnMeasurement(capture: typeof execCapture) {
	const root = tempRuntime();
	// Real time measures process launch, deadline and OS reap. Main's unbounded
	// capture needs the faux bridge's finite lifetime to finish without a bench-owned kill.
	const script = 'process.on("SIGTERM", () => {}); console.log(process.pid); setTimeout(() => console.log("natural-exit"), 2000)';
	const started = performance.now();
	const result = await capture(process.execPath, ["-e", script], {
		cwd: root, timeoutMs: 200, env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root },
	});
	const elapsedMs = Math.round(performance.now() - started);
	const pids = result.stdout.trim().split("\n").map(Number).filter((pid) => pid > 0);
	assert.equal(pids.length, 1, "faux bridge must start before the measurement ends");
	for (const pid of pids) assert.throws(() => process.kill(pid, 0), { code: "ESRCH" }, "measured child must be reaped");
	return { elapsedMs, peak: pids.length, surviving: 0, exitCode: result.code, timedOut: /timed out/.test(String(result.error)), naturalExit: result.stdout.includes("natural-exit") };
}

try {
	const main = await importMainRuntime();
	const before = await spawnMeasurement(main.pane.execCapture);
	const after = await spawnMeasurement(execCapture);
	console.log(`spawn-benchmark ${JSON.stringify({ main: main.ref, before, after, deadlineMs: 200 })}`);
	assert.equal(before.timedOut, false);
	assert.equal(before.naturalExit, true);
	assert.equal(after.timedOut, true);
	assert.equal(after.naturalExit, false);
} finally {
	cleanupTempRuntimes();
}
