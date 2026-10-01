import assert from "node:assert/strict";
import test, { after } from "node:test";
import { execCapture } from "../extensions/subagent/pane.js";
import { cleanupTempRuntimes, importRuntimeCopy, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

async function stalled(capture: typeof execCapture): Promise<void> {
	const root = tempRuntime();
	// Real time here lets the OS start and reap a SIGTERM-resistant faux bridge.
	const result = await capture(process.execPath, ["-e", 'process.on("SIGTERM", () => {}); console.log(process.pid); setTimeout(() => console.log("natural-exit"), 2000)'], {
		cwd: root, timeoutMs: 200, signal: AbortSignal.timeout(1600), env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root },
	});
	assert.match(String(result.error), /timed out/);
	assert.equal(result.code, 1);
	assert.ok(!result.stdout.includes("natural-exit"), "kill escalation must end the stalled bridge");
	const pid = Number(result.stdout.trim());
	assert.ok(pid > 0, "faux bridge must have started");
	assert.throws(() => process.kill(pid, 0), { code: "ESRCH" }, "no bridge child may survive the timeout");
}

test("execCapture deadlines reap a stalled bridge, including kill escalation", { timeout: 10_000 }, async () => {
	await stalled(execCapture);
	const mutant = await importRuntimeCopy("pane.ts", 'setTimeout(() => stop(new Error(`${command} timed out after ${timeoutMs}ms`)), timeoutMs)', 'setTimeout(() => {}, timeoutMs)') as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(stalled(mutant.execCapture), /timed out/);
	const noEscalation = await importRuntimeCopy("pane.ts", 'if (failure) kill("SIGKILL");', 'if (failure) void failure;', [
		{ before: 'kill("SIGKILL");\n\t\t\t\tcloseBound', after: 'void failure;\n\t\t\t\tcloseBound' },
	]) as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(stalled(noEscalation.execCapture), /kill escalation must end/);
});

async function cancelledCapture(capture: typeof execCapture): Promise<void> {
	const controller = new AbortController();
	controller.abort(new Error("cancelled-before-spawn"));
	const result = await capture("missing-command-must-not-spawn", [], { signal: controller.signal, env: {} });
	assert.equal(result.error, controller.signal.reason, "pre-spawn cancellation must retain the abort reason");
}

test("an already cancelled capture starts nothing", async () => {
	await cancelledCapture(execCapture);
	const mutant = await importRuntimeCopy("pane.ts", 'if (signal?.aborted) return { code: 1, stdout: "", stderr: "Command aborted", error: signal.reason };', 'if (signal?.aborted) void signal.reason;') as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(cancelledCapture(mutant.execCapture), /pre-spawn cancellation/);
});

test("in-flight capture cancellation terminates the child", async () => {
	const cancelled = async (capture: typeof execCapture) => {
		const root = tempRuntime();
		// The OS must launch the faux bridge before the caller cancels it.
		const result = await capture(process.execPath, ["-e", 'console.log(process.pid); setTimeout(() => {}, 2000)'], {
			timeoutMs: 10_000, signal: AbortSignal.timeout(200), env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root },
		});
		assert.match(String(result.error), /aborted/);
		const pid = Number(result.stdout.trim());
		assert.ok(pid > 0);
		assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
	};
	await cancelled(execCapture);
	const mutant = await importRuntimeCopy("pane.ts", 'signal?.addEventListener("abort", abort, { once: true });', 'void signal;') as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(cancelled(mutant.execCapture), /aborted/);
});

test("command capture bounds each retained output stream", async () => {
	for (const stream of ["stdout", "stderr"] as const) {
		const bounded = async (capture: typeof execCapture) => {
			const root = tempRuntime();
			const result = await capture(process.execPath, ["-e", `process.${stream}.write("x".repeat(2 * 1024 * 1024))`], {
				env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root }, timeoutMs: 10_000,
			});
			assert.equal(result.code, 0);
			assert.equal(result[stream].length, 1024 * 1024, "retained command output must be bounded");
		};
		await bounded(execCapture);
		const mutant = await importRuntimeCopy("pane.ts", `${stream} = (${stream} + data.toString()).slice(-1024 * 1024);`, `${stream} = (${stream} + data.toString());`) as typeof import("../extensions/subagent/pane.js");
		await assert.rejects(bounded(mutant.execCapture), /retained command output must be bounded/);
	}
});
