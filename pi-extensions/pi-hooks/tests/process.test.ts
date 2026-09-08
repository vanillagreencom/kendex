import { expect, spyOn, test } from "bun:test";
import * as childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";

import { runCommandAsync } from "../extensions/process.ts";

// Real commands cover OS pipes and missing executables. Timeout signaling is
// controlled below, so a broken kill cannot leave a real process behind.
for (const row of [
	{ name: "normal exit", command: "bash", args: ["-c", "printf out; printf err >&2; exit 3"], code: 3, out: "out", err: "err" },
	{ name: "missing executable", command: "kendex-no-such-binary", args: [], code: -1, out: "", err: undefined },
]) {
	test(row.name, async () => {
		const result = await runCommandAsync(row.command, row.args, process.cwd(), 5000);
		expect(result.exitCode).toBe(row.code);
		expect(result.stdout).toBe(row.out);
		if (row.err !== undefined) expect(result.stderr).toBe(row.err);
		expect(result.timedOut).toBe(false);
	});
}

for (const row of [
	{ name: "cooperative timeout cancels escalation", closeOnTerm: true, signals: ["SIGTERM"] },
	{ name: "ignored timeout escalates", closeOnTerm: false, signals: ["SIGTERM", "SIGKILL"] },
]) {
	test(row.name, async () => {
		const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stderr: new PassThrough(), stdin: null, pid: 711 });
		const timers = new Map<number, { delay: number; callback: () => void }>();
		let sequence = 0;
		const signals: string[] = [];
		const spawn = spyOn(childProcess, "spawn").mockImplementation(() => child as unknown as childProcess.ChildProcess);
		const timer = spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void, delay: number) => {
			const id = ++sequence;
			timers.set(id, { delay, callback });
			return id;
		}) as typeof setTimeout);
		const clear = spyOn(globalThis, "clearTimeout").mockImplementation(((id: number) => { timers.delete(id); }) as typeof clearTimeout);
		const kill = spyOn(process, "kill").mockImplementation((pid, signal) => {
			expect(pid).toBe(-child.pid);
			signals.push(String(signal));
			if (signal === "SIGTERM" && row.closeOnTerm) child.emit("close", null, signal);
			return true;
		});
		const advance = (delay: number) => {
			for (const [id, entry] of [...timers]) {
				if (entry.delay > delay) continue;
				timers.delete(id);
				entry.callback();
			}
		};
		try {
			let settled = false;
			const run = runCommandAsync("child", [], process.cwd(), 200).then((result) => { settled = true; return result; });
			expect(spawn).toHaveBeenCalledTimes(1);
			advance(199);
			expect(signals).toEqual([]);
			advance(200);
			await Promise.resolve();
			expect(signals).toEqual(["SIGTERM"]);
			expect(settled).toBe(row.closeOnTerm);
			if (row.closeOnTerm) expect(timers.size).toBe(0);
			advance(1000);
			await Promise.resolve();
			expect(settled).toBe(true);
			if (!settled) throw new Error("timeout did not settle");
			const result = await run;
			expect(signals).toEqual(row.signals);
			expect(result.exitCode).toBe(-1);
			expect(result.timedOut).toBe(true);
			if (row.closeOnTerm) expect(result.stderr.trim()).toBe("SIGTERM");
			expect(timers.size).toBe(0);
		} finally {
			kill.mockRestore();
			clear.mockRestore();
			timer.mockRestore();
			spawn.mockRestore();
			child.stdout.destroy();
			child.stderr.destroy();
		}
	});
}
