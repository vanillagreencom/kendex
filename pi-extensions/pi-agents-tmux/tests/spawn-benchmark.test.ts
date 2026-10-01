import assert from "node:assert/strict";
import test, { after } from "node:test";
import { execCapture } from "../extensions/subagent/pane.js";
import { cleanupTempRuntimes, importMainRuntime, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

async function spawnMeasurement(capture: typeof execCapture) {
	const root = tempRuntime();
	// Real time measures process launch, deadline and OS reap. Main's unbounded
	// capture needs the faux bridge's finite lifetime to finish without a test-owned kill.
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

test("component benchmark: a stalled direct spawn ends at its deadline", async () => {
	const main = await importMainRuntime();
	const before = await spawnMeasurement(main.pane.execCapture);
	const after = await spawnMeasurement(execCapture);
	console.log(`spawn-benchmark ${JSON.stringify({ main: main.ref, before, after, deadlineMs: 200 })}`);
	assert.equal(before.timedOut, false);
	assert.equal(before.naturalExit, true);
	assert.equal(after.timedOut, true);
	assert.equal(after.naturalExit, false);
});

test("benchmark fixture works with only the event ref and with main advanced", async () => {
	const { execFileSync } = await import("node:child_process");
	const { resolve } = await import("node:path");
	const { BENCHMARK_BASELINE } = await import("./browser-fixture.js");
	const root = tempRuntime();
	const source = resolve(import.meta.dir, "../../..");
	const env = { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root };
	const git = (args: string[]) => execFileSync("git", args, { cwd: root, env, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
	git(["init"]);
	git(["fetch", "--depth=1", `file://${source}`, "HEAD"]);
	git(["update-ref", "refs/heads/event", "FETCH_HEAD"]);
	assert.equal(git(["for-each-ref", "--format=%(refname)"]), "refs/heads/event");
	// CI supplies the pinned object explicitly before running npm test.
	git(["fetch", "--depth=1", `file://${source}`, BENCHMARK_BASELINE]);
	assert.equal((await importMainRuntime(root)).ref, BENCHMARK_BASELINE);
	git(["update-ref", "refs/remotes/origin/main", "refs/heads/event"]);
	assert.equal((await importMainRuntime(root)).ref, BENCHMARK_BASELINE);
});
