import assert from "node:assert/strict";
import test, { after } from "node:test";
import { execCapture } from "../extensions/subagent/pane.js";
import { cleanupTempRuntimes, importRuntimeCopy, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

async function stalled(capture: typeof execCapture): Promise<void> {
	const root = tempRuntime();
	// Real time here lets the OS start and reap a SIGTERM-resistant faux bridge.
	const result = await capture(process.execPath, ["-e", 'process.on("SIGTERM", () => {}); console.log(process.pid); setInterval(() => {}, 1000)'], {
		cwd: root, timeoutMs: 200, signal: AbortSignal.timeout(1600), env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root },
	});
	assert.match(String(result.error), /timed out/);
	assert.equal(result.code, 1);
	const pid = Number(result.stdout.trim());
	assert.ok(pid > 0, "faux bridge must have started");
	assert.throws(() => process.kill(pid, 0), { code: "ESRCH" }, "no bridge child may survive the timeout");
}

test("execCapture deadlines reap a stalled bridge, including kill escalation", async () => {
	await stalled(execCapture);
	const mutant = await importRuntimeCopy("pane.ts", 'setTimeout(() => stop(new Error(`${command} timed out after ${timeoutMs}ms`)), timeoutMs)', 'setTimeout(() => {}, timeoutMs)') as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(stalled(mutant.execCapture), /timed out/);
});

test("an already cancelled capture starts nothing", async () => {
	const controller = new AbortController();
	controller.abort(new Error("cancelled-before-spawn"));
	const result = await execCapture("missing-command-must-not-spawn", [], { signal: controller.signal, env: {} });
	assert.equal(result.error, controller.signal.reason);
});
