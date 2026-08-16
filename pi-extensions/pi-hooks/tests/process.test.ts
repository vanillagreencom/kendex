import { describe, expect, test } from "bun:test";

import { runCommandAsync } from "../extensions/process.ts";

const CWD = process.cwd();

describe("runCommandAsync", () => {
	test("collects stdout and the exit code of a normal run", async () => {
		const result = await runCommandAsync("bash", ["-c", "printf out; printf err >&2; exit 3"], CWD, 5000);
		expect(result.exitCode).toBe(3);
		expect(result.stdout).toBe("out");
		expect(result.stderr).toBe("err");
		expect(result.timedOut).toBe(false);
	});

	test("a missing binary settles instead of rejecting", async () => {
		const result = await runCommandAsync("vstack-no-such-binary", [], CWD, 5000);
		expect(result.exitCode).toBe(-1);
		expect(result.timedOut).toBe(false);
	});

	test("a child that exits on SIGTERM is never escalated to SIGKILL", async () => {
		const started = Date.now();
		const result = await runCommandAsync("sleep", ["10"], CWD, 200);
		const elapsed = Date.now() - started;

		expect(result.timedOut).toBe(true);
		// Settled by the child's own exit, so the escalation callback never ran:
		// its message is absent and the run finished well inside the 1s window.
		expect(result.stderr).toContain("SIGTERM");
		expect(result.stderr).not.toContain("was killed");
		expect(elapsed).toBeLessThan(1000);
	});

	test("a child that ignores SIGTERM is escalated to SIGKILL", async () => {
		const result = await runCommandAsync(
			"bash",
			["-c", 'trap "" TERM; while true; do sleep 0.2; done'],
			CWD,
			200,
		);
		expect(result.timedOut).toBe(true);
		expect(result.exitCode).toBe(-1);
		expect(result.stderr).toContain("timed out after 200ms and was killed");
	});
});
