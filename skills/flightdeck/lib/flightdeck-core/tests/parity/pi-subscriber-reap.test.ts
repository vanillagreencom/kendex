// Regression coverage for vstack#58: when a tracked pane is destroyed
// the daemon must reap the orphaned subscriber bash process and clean
// its pid/log files. G1's commit 5465d40 added reconcile-based reaping
// only on registry removal; this test asserts the SIGTERM->grace->SIGKILL
// policy of the dedicated reaper and that the pane-gone branch wires
// into it.

import { describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
	reapSubscriber,
	REAP_DEFAULT_GRACE_MS,
	type ReapSubscriberDeps,
} from "../../src/daemon/subscribers/reap.ts";

interface LogLine { tag: string; msg: string }

function buildLog(): { lines: LogLine[]; log: (tag: string, msg: string) => void } {
	const lines: LogLine[] = [];
	return { lines, log: (tag, msg) => lines.push({ tag, msg }) };
}

function mkPidLogFiles(pid: number): { pidFile: string; logFile: string; dir: string } {
	const dir = mkdtempSync(join(tmpdir(), "fd-reap-"));
	const pidFile = join(dir, "fd-pi-subscriber-test.pid");
	const logFile = join(dir, "fd-daemon.log.pi-sub-7");
	writeFileSync(pidFile, `${pid}\n`);
	writeFileSync(logFile, "subscriber log content\n");
	return { pidFile, logFile, dir };
}

function pidAlive(pid: number): boolean {
	try { process.kill(pid, 0); return true; }
	catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
}

async function waitFor(predicate: () => boolean, timeoutMs: number): Promise<boolean> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return true;
		await new Promise((r) => setTimeout(r, 25));
	}
	return predicate();
}

describe("reapSubscriber default grace policy (vstack#58)", () => {
	test("REAP_DEFAULT_GRACE_MS is 5 seconds per brief", () => {
		expect(REAP_DEFAULT_GRACE_MS).toBe(5000);
	});

	test("missing pid file -> no-pid outcome, both files removed if present", () => {
		const dir = mkdtempSync(join(tmpdir(), "fd-reap-"));
		const pidFile = join(dir, "missing.pid");
		const logFile = join(dir, "missing.log");
		writeFileSync(logFile, "x");
		const { lines, log } = buildLog();
		const result = reapSubscriber(
			{ paneId: "%7", reason: "pane-gone", pidFile, logFile },
			{ log },
		);
		expect(result.outcome).toBe("no-pid");
		expect(result.pid).toBeNull();
		expect(result.logFileRemoved).toBe(true);
		expect(existsSync(logFile)).toBe(false);
		expect(lines.length).toBe(0);
	});

	test("pid points at a dead process -> already-gone, files removed, logged", () => {
		const { pidFile, logFile } = mkPidLogFiles(999_999_999);
		const { lines, log } = buildLog();
		const result = reapSubscriber(
			{ paneId: "%7", reason: "pane-gone", pidFile, logFile },
			{ log, signal: (_pid, _sig) => { const err: NodeJS.ErrnoException = new Error("kill ESRCH"); err.code = "ESRCH"; throw err; } },
		);
		expect(result.outcome).toBe("already-gone");
		expect(result.pidFileRemoved).toBe(true);
		expect(result.logFileRemoved).toBe(true);
		expect(existsSync(pidFile)).toBe(false);
		expect(existsSync(logFile)).toBe(false);
		const reapLog = lines.find((l) => l.tag === "reap");
		expect(reapLog?.msg).toContain("outcome=already-gone");
	});
});

describe("reapSubscriber SIGTERM->grace->SIGKILL with mocked deps (vstack#58)", () => {
	test("alive process: SIGTERM fires, scheduleAfter triggers, files removed on grace", () => {
		const { pidFile, logFile } = mkPidLogFiles(42);
		const { lines, log } = buildLog();
		const signals: Array<{ pid: number; sig: NodeJS.Signals | 0 }> = [];
		const scheduled: Array<{ ms: number; fn: () => void }> = [];
		let stillAlive = true;
		const result = reapSubscriber(
			{ paneId: "%7", reason: "pane-gone", pidFile, logFile, graceMs: 50 },
			{
				log,
				signal: (pid, sig) => {
					signals.push({ pid, sig });
					if (sig === 0) { if (!stillAlive) { const e: NodeJS.ErrnoException = new Error("ESRCH"); e.code = "ESRCH"; throw e; } return; }
					if (sig === "SIGTERM") { stillAlive = false; return; }
				},
				scheduleAfter: (ms, fn) => { scheduled.push({ ms, fn }); return { cancel: () => undefined }; },
			},
		);
		expect(result.outcome).toBe("term-ok");
		expect(signals.some((s) => s.sig === "SIGTERM" && s.pid === -42)).toBe(true);
		expect(scheduled.length).toBe(1);
		expect(scheduled[0]?.ms).toBe(50);
		// Run the deferred check: pid is now "dead" (mocked), so no SIGKILL.
		scheduled[0]?.fn();
		expect(signals.some((s) => s.sig === "SIGKILL")).toBe(false);
		expect(existsSync(pidFile)).toBe(false);
		expect(existsSync(logFile)).toBe(false);
		const reapLog = lines.find((l) => l.tag === "reap" && l.msg.includes("outcome=term-ok"));
		expect(reapLog?.msg).toContain("outcome=term-ok");
	});

	test("deferred cleanup preserves replacement subscriber pid/log when pidfile changed", () => {
		const { pidFile, logFile } = mkPidLogFiles(42);
		const { lines, log } = buildLog();
		const scheduled: Array<{ ms: number; fn: () => void }> = [];
		let stillAlive = true;
		const result = reapSubscriber(
			{ paneId: "%7", reason: "pi-session-mismatch", pidFile, logFile, graceMs: 50, harness: "pi" },
			{
				log,
				signal: (_pid, sig) => {
					if (sig === 0) { if (!stillAlive) { const e: NodeJS.ErrnoException = new Error("ESRCH"); e.code = "ESRCH"; throw e; } return; }
					if (sig === "SIGTERM") { stillAlive = false; return; }
				},
				scheduleAfter: (ms, fn) => { scheduled.push({ ms, fn }); return { cancel: () => undefined }; },
			},
		);
		expect(result.outcome).toBe("term-ok");
		writeFileSync(pidFile, "4242\n");
		writeFileSync(logFile, "replacement subscriber log\n");
		scheduled[0]?.fn();
		expect(readFileSync(pidFile, "utf8").trim()).toBe("4242");
		expect(readFileSync(logFile, "utf8")).toContain("replacement subscriber log");
		expect(result.pidFileRemoved).toBe(false);
		expect(result.logFileRemoved).toBe(false);
		expect(lines.some((l) => l.msg.includes("cleanup=skipped-current-pid") && l.msg.includes("current_pid=4242"))).toBe(true);
	});

	test("process-group ESRCH never falls back to positive pid", () => {
		const { pidFile, logFile } = mkPidLogFiles(42);
		const { lines, log } = buildLog();
		const signals: Array<{ pid: number; sig: NodeJS.Signals | 0 }> = [];
		const result = reapSubscriber(
			{ paneId: "%7", reason: "pane-gone", pidFile, logFile, graceMs: 50 },
			{
				log,
				signal: (pid, sig) => {
					signals.push({ pid, sig });
					if (pid > 0) throw new Error(`unsafe positive pid signal ${pid}`);
					const e: NodeJS.ErrnoException = new Error("ESRCH");
					e.code = "ESRCH";
					throw e;
				},
				scheduleAfter: (_ms, _fn) => ({ cancel: () => undefined }),
			},
		);
		expect(result.outcome).toBe("already-gone");
		expect(signals).toEqual([{ pid: -42, sig: 0 }]);
		expect(lines.some((l) => l.msg.includes("outcome=already-gone"))).toBe(true);
	});

	test("grace SIGKILL path never falls back to positive pid when pidfile now points at replacement", () => {
		const { pidFile, logFile } = mkPidLogFiles(42);
		const { lines, log } = buildLog();
		const signals: Array<{ pid: number; sig: NodeJS.Signals | 0 }> = [];
		const scheduled: Array<{ ms: number; fn: () => void }> = [];
		const result = reapSubscriber(
			{ paneId: "%7", reason: "pi-session-mismatch", pidFile, logFile, graceMs: 50, harness: "pi" },
			{
				log,
				signal: (pid, sig) => {
					signals.push({ pid, sig });
					if (pid > 0) throw new Error(`unsafe positive pid signal ${pid}`);
					if (sig === 0 || sig === "SIGTERM") return;
					if (sig === "SIGKILL") {
						const e: NodeJS.ErrnoException = new Error("ESRCH");
						e.code = "ESRCH";
						throw e;
					}
				},
				scheduleAfter: (ms, fn) => { scheduled.push({ ms, fn }); return { cancel: () => undefined }; },
			},
		);
		expect(result.outcome).toBe("term-ok");
		writeFileSync(pidFile, "4242\n");
		writeFileSync(logFile, "replacement subscriber log\n");
		scheduled[0]?.fn();
		expect(signals.every((s) => s.pid < 0)).toBe(true);
		expect(signals.some((s) => s.sig === "SIGKILL" && s.pid === -42)).toBe(true);
		expect(readFileSync(pidFile, "utf8").trim()).toBe("4242");
		expect(readFileSync(logFile, "utf8")).toContain("replacement subscriber log");
		expect(result.pidFileRemoved).toBe(false);
		expect(result.logFileRemoved).toBe(false);
		expect(lines.some((l) => l.msg.includes("cleanup=skipped-current-pid") && l.msg.includes("current_pid=4242"))).toBe(true);
	});

	test("stubborn process: SIGKILL fires after grace, logged kill-required", () => {
		const { pidFile, logFile } = mkPidLogFiles(99);
		const { lines, log } = buildLog();
		const signals: Array<{ pid: number; sig: NodeJS.Signals | 0 }> = [];
		const scheduled: Array<{ ms: number; fn: () => void }> = [];
		const result = reapSubscriber(
			{ paneId: "%9", reason: "pane-gone", pidFile, logFile, graceMs: 50 },
			{
				log,
				signal: (pid, sig) => {
					signals.push({ pid, sig });
					// pid-alive probe (sig 0): always alive (stubborn).
					// SIGTERM accepted but ignored. SIGKILL accepted.
				},
				scheduleAfter: (_ms, fn) => { scheduled.push({ ms: _ms, fn }); return { cancel: () => undefined }; },
			},
		);
		expect(result.outcome).toBe("term-ok");
		expect(signals.find((s) => s.sig === "SIGTERM")).toBeDefined();
		scheduled[0]?.fn();
		expect(signals.find((s) => s.sig === "SIGKILL" && s.pid === -99)).toBeDefined();
		const reapLog = lines.find((l) => l.tag === "reap" && l.msg.includes("kill-required"));
		expect(reapLog).toBeDefined();
		expect(reapLog?.msg).toContain("pane=%9");
		expect(reapLog?.msg).toContain("reason=pane-gone");
		expect(existsSync(pidFile)).toBe(false);
		expect(existsSync(logFile)).toBe(false);
	});

	test("SIGTERM permission-denied -> warn-log, NO throw", () => {
		const { pidFile, logFile } = mkPidLogFiles(123);
		const { lines, log } = buildLog();
		expect(() => reapSubscriber(
			{ paneId: "%3", reason: "pane-gone", pidFile, logFile },
			{
				log,
				signal: (_pid, sig) => {
					if (sig === 0) return; // alive
					const err: NodeJS.ErrnoException = new Error("kill EPERM");
					err.code = "EPERM";
					throw err;
				},
				scheduleAfter: (_ms, _fn) => ({ cancel: () => undefined }),
			},
		)).not.toThrow();
		const warn = lines.find((l) => l.tag === "reap-warn");
		expect(warn).toBeDefined();
		expect(warn?.msg).toContain("SIGTERM failed");
	});

	test("pid file with garbage content -> treated as no-pid", () => {
		const dir = mkdtempSync(join(tmpdir(), "fd-reap-"));
		const pidFile = join(dir, "garbage.pid");
		writeFileSync(pidFile, "not-a-pid\n");
		const { lines, log } = buildLog();
		const result = reapSubscriber({ paneId: "%5", reason: "pane-gone", pidFile }, { log });
		expect(result.outcome).toBe("no-pid");
		expect(result.pid).toBeNull();
	});
});

describe("reapSubscriber against a real bash sleep process (vstack#58)", () => {
	test("end-to-end: spawn -> SIGTERM -> reaped, pid file removed, kill -0 returns ESRCH", async () => {
		const dir = mkdtempSync(join(tmpdir(), "fd-reap-real-"));
		const pidFile = join(dir, "fd-pi-subscriber-real.pid");
		const logFile = join(dir, "fd-daemon.log.pi-sub-real");
		const child = spawn("bash", ["-c", "sleep 60"], { stdio: "ignore", detached: true });
		child.unref();
		const pid = child.pid!;
		writeFileSync(pidFile, `${pid}\n`);
		writeFileSync(logFile, "x");
		const { lines, log } = buildLog();
		const result = reapSubscriber(
			{ paneId: "%real", reason: "pane-gone", pidFile, logFile, graceMs: 50, harness: "pi" },
			{ log },
		);
		expect(result.outcome).toBe("term-ok");
		const reaped = await waitFor(() => !pidAlive(pid), 2000);
		expect(reaped).toBe(true);
		await waitFor(() => !existsSync(pidFile), 1000);
		expect(existsSync(pidFile)).toBe(false);
		expect(existsSync(logFile)).toBe(false);
		const reapLog = lines.find((l) => l.tag === "reap");
		expect(reapLog?.msg).toContain("pane=%real");
		expect(reapLog?.msg).toContain("reason=pane-gone");
	});

	test("process-group reap kills subscriber pipeline child", async () => {
		const dir = mkdtempSync(join(tmpdir(), "fd-reap-group-"));
		const pidFile = join(dir, "fd-pi-subscriber-group.pid");
		const logFile = join(dir, "fd-daemon.log.pi-sub-group");
		const childPidFile = join(dir, "child.pid");
		const child = spawn("bash", ["-c", "sleep 60 & echo $! > \"$1\"; wait", "fd-reap-group", childPidFile], { stdio: "ignore", detached: true });
		child.unref();
		const pid = child.pid!;
		try {
			const childPidReady = await waitFor(() => existsSync(childPidFile), 2000);
			expect(childPidReady).toBe(true);
			const pipelineChildPid = Number.parseInt(readFileSync(childPidFile, "utf8").trim(), 10);
			expect(pidAlive(pipelineChildPid)).toBe(true);
			writeFileSync(pidFile, `${pid}\n`);
			writeFileSync(logFile, "x");
			const { lines, log } = buildLog();
			const result = reapSubscriber(
				{ paneId: "%group", reason: "pi-session-mismatch", pidFile, logFile, graceMs: 50, harness: "pi" },
				{ log },
			);
			expect(result.outcome).toBe("term-ok");
			const groupGone = await waitFor(() => !pidAlive(pid) && !pidAlive(pipelineChildPid), 2000);
			expect(groupGone).toBe(true);
			const cleanupDone = await waitFor(() => !existsSync(pidFile), 1000);
			expect(cleanupDone).toBe(true);
			expect(lines.some((l) => l.msg.includes("scope=process-group") || l.msg.includes("outcome=term-ok"))).toBe(true);
		} finally {
			try { process.kill(-pid, "SIGKILL"); } catch { /* */ }
			try { process.kill(pid, "SIGKILL"); } catch { /* */ }
		}
	});
});

describe("loop.ts pane-gone hook wires reapSubscriber (vstack#58)", () => {
	test("loop.ts contains the pane-gone reaping wiring", () => {
		const loopSrc = readFileSync(new URL("../../src/daemon/loop.ts", import.meta.url), "utf8");
		expect(loopSrc).toContain("reaping subscriber");
		expect(loopSrc).toMatch(/reapSubscriberForPane\([^)]+,\s*"pane-gone"\)/);
		expect(loopSrc).toContain("entry-removed");
	});
});
