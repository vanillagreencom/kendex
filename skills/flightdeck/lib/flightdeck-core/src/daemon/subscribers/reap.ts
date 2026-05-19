// Subscriber reap helper (vstack#58).
//
// When a tracked pane is destroyed (tmux kill-window, pane closed, or
// the entry is removed from the registry by reconcile), the daemon must
// stop the matching subscriber bash process and remove its pid/log
// files. The naive `unlinkSync(pidFile)` from the original reconcile
// reaper leaves the bash process running.
//
// Policy (from the brief, non-negotiable):
//   1. SIGTERM the captured pid's process group.
//   2. Wait up to graceMs (default 5s) for clean exit.
//   3. If still alive: SIGKILL the captured process group.
//   4. Remove the pid file (after the signal sequence resolves) only
//      if it still points at the reaped pid.
//   5. Remove the matching log file if known and the pidfile guard did
//      not detect a replacement subscriber.
//
// Failures (permission denied, missing pid file, malformed pid) warn-log
// and continue — never throw. The reap is best-effort cleanup.

import { existsSync, readFileSync, unlinkSync } from "node:fs";

export const REAP_DEFAULT_GRACE_MS = 5_000;

export type ReapOutcome =
	| "no-pid"
	| "already-gone"
	| "term-ok"
	| "kill-required"
	| "signal-error"
	| "kill-failed";

export interface ReapSubscriberInput {
	paneId: string;
	reason: string;
	pidFile: string;
	logFile?: string;
	pid?: number | null;
	graceMs?: number;
	harness?: string;
}

export interface ReapSubscriberResult {
	paneId: string;
	pid: number | null;
	outcome: ReapOutcome;
	pidFileRemoved: boolean;
	logFileRemoved: boolean;
	error?: string;
}

export interface ReapSubscriberDeps {
	signal?: (pid: number, sig: NodeJS.Signals | 0) => void;
	rm?: (path: string) => void;
	scheduleAfter?: (ms: number, fn: () => void) => { cancel(): void };
	log: (tag: string, msg: string) => void;
	readPidFile?: (path: string) => number | null;
}

function defaultReadPidFile(path: string): number | null {
	if (!path || !existsSync(path)) return null;
	try {
		const txt = readFileSync(path, "utf8").trim();
		if (!/^[1-9][0-9]*$/.test(txt)) return null;
		const pid = Number.parseInt(txt, 10);
		return Number.isFinite(pid) && pid > 0 ? pid : null;
	} catch { return null; }
}

function defaultSignal(pid: number, sig: NodeJS.Signals | 0): void {
	process.kill(pid, sig);
}

function defaultRm(path: string): void {
	unlinkSync(path);
}

function defaultScheduleAfter(ms: number, fn: () => void): { cancel(): void } {
	const handle = setTimeout(fn, ms);
	if (typeof (handle as any)?.unref === "function") (handle as any).unref();
	return { cancel: () => clearTimeout(handle) };
}

function targetAlive(signal: (pid: number, sig: NodeJS.Signals | 0) => void, target: number): boolean {
	try { signal(target, 0); return true; }
	catch (e) {
		const code = (e as NodeJS.ErrnoException).code;
		return code === "EPERM";
	}
}

function subscriberGroupAlive(signal: (pid: number, sig: NodeJS.Signals | 0) => void, pid: number): boolean {
	return targetAlive(signal, -pid);
}

type SubscriberSignalResult =
	| { sent: true; target: number; scope: "process-group" }
	| { sent: false; target: number; scope: "process-group"; error?: Error };

function signalSubscriber(signal: (pid: number, sig: NodeJS.Signals | 0) => void, pid: number, sig: NodeJS.Signals): SubscriberSignalResult {
	try {
		signal(-pid, sig);
		return { sent: true, target: -pid, scope: "process-group" };
	} catch (e) {
		const code = (e as NodeJS.ErrnoException).code;
		if (code !== "ESRCH") return { sent: false, target: -pid, scope: "process-group", error: e as Error };
		return { sent: false, target: -pid, scope: "process-group" };
	}
}

function tryRemove(rm: (path: string) => void, path: string | undefined, log: (tag: string, msg: string) => void, label: string): boolean {
	if (!path) return false;
	try {
		rm(path);
		return true;
	} catch (e) {
		const code = (e as NodeJS.ErrnoException).code;
		if (code !== "ENOENT") log("reap-warn", `${label}=${path} remove failed: ${(e as Error).message}`);
		return false;
	}
}

function cleanupIfPidStillMatches(opts: {
	pid: number;
	pidFile: string;
	logFile?: string;
	rm: (path: string) => void;
	readPidFile: (path: string) => number | null;
	log: (tag: string, msg: string) => void;
	harnessLabel: string;
	paneId: string;
	reason: string;
}): { pidFileRemoved: boolean; logFileRemoved: boolean } {
	const currentPid = opts.readPidFile(opts.pidFile);
	if (currentPid !== null && currentPid !== opts.pid) {
		opts.log("reap", `${opts.harnessLabel} pid=${opts.pid} pane=${opts.paneId} reason=${opts.reason} cleanup=skipped-current-pid current_pid=${currentPid}`);
		return { pidFileRemoved: false, logFileRemoved: false };
	}
	const pidFileRemoved = tryRemove(opts.rm, opts.pidFile, opts.log, "pid-file");
	const logFileRemoved = tryRemove(opts.rm, opts.logFile, opts.log, "log-file");
	return { pidFileRemoved, logFileRemoved };
}

/**
 * Reap a subscriber bash process. Returns immediately after the SIGTERM
 * is sent or the no-process path resolves; the grace SIGKILL is fired
 * asynchronously via scheduleAfter so the run loop is not blocked.
 *
 * The returned object reflects the state at SIGTERM-time. Tests that
 * need to verify the SIGKILL fallback should provide a deterministic
 * scheduleAfter that runs the deferred function immediately.
 */
export function reapSubscriber(input: ReapSubscriberInput, deps: ReapSubscriberDeps): ReapSubscriberResult {
	const signal = deps.signal ?? defaultSignal;
	const rm = deps.rm ?? defaultRm;
	const scheduleAfter = deps.scheduleAfter ?? defaultScheduleAfter;
	const readPidFile = deps.readPidFile ?? defaultReadPidFile;
	const graceMs = Math.max(0, input.graceMs ?? REAP_DEFAULT_GRACE_MS);
	const harnessLabel = input.harness ? `${input.harness}-subscriber` : "subscriber";
	const pid = input.pid ?? readPidFile(input.pidFile);
	if (!pid) {
		const pidFileRemoved = tryRemove(rm, input.pidFile, deps.log, "pid-file");
		const logFileRemoved = tryRemove(rm, input.logFile, deps.log, "log-file");
		return {
			paneId: input.paneId,
			pid: null,
			outcome: "no-pid",
			pidFileRemoved,
			logFileRemoved,
		};
	}
	if (!subscriberGroupAlive(signal, pid)) {
		const { pidFileRemoved, logFileRemoved } = cleanupIfPidStillMatches({
			pid,
			pidFile: input.pidFile,
			logFile: input.logFile,
			rm,
			readPidFile,
			log: deps.log,
			harnessLabel,
			paneId: input.paneId,
			reason: input.reason,
		});
		deps.log("reap", `${harnessLabel} pid=${pid} pane=${input.paneId} reason=${input.reason} outcome=already-gone`);
		return {
			paneId: input.paneId,
			pid,
			outcome: "already-gone",
			pidFileRemoved,
			logFileRemoved,
		};
	}
	let outcome: ReapOutcome = "term-ok";
	let signalError: string | undefined;
	const term = signalSubscriber(signal, pid, "SIGTERM");
	if (term.sent) {
		deps.log("reap", `${harnessLabel} pid=${pid} pane=${input.paneId} reason=${input.reason} signal=SIGTERM target=${term.target} scope=${term.scope}`);
	}
	if (!term.sent && term.error) {
		signalError = term.error.message;
		deps.log("reap-warn", `${harnessLabel} pid=${pid} pane=${input.paneId} reason=${input.reason} SIGTERM failed target=${term.target} scope=${term.scope}: ${signalError}`);
		outcome = "signal-error";
	}
	const result: ReapSubscriberResult = {
		paneId: input.paneId,
		pid,
		outcome,
		pidFileRemoved: false,
		logFileRemoved: false,
		error: signalError,
	};
	scheduleAfter(graceMs, () => {
		try {
			if (subscriberGroupAlive(signal, pid)) {
				const kill = signalSubscriber(signal, pid, "SIGKILL");
				if (kill.sent) {
					deps.log("reap", `${harnessLabel} pid=${pid} pane=${input.paneId} reason=${input.reason} outcome=kill-required target=${kill.target} scope=${kill.scope} (SIGTERM grace expired)`);
				} else if (kill.error) {
					deps.log("reap-warn", `${harnessLabel} pid=${pid} pane=${input.paneId} reason=${input.reason} SIGKILL failed target=${kill.target} scope=${kill.scope}: ${kill.error.message}`);
				} else {
					deps.log("reap", `${harnessLabel} pid=${pid} pane=${input.paneId} reason=${input.reason} outcome=term-ok-race`);
				}
			} else {
				deps.log("reap", `${harnessLabel} pid=${pid} pane=${input.paneId} reason=${input.reason} outcome=term-ok`);
			}
		} finally {
			const { pidFileRemoved, logFileRemoved } = cleanupIfPidStillMatches({
				pid,
				pidFile: input.pidFile,
				logFile: input.logFile,
				rm,
				readPidFile,
				log: deps.log,
				harnessLabel,
				paneId: input.paneId,
				reason: input.reason,
			});
			result.pidFileRemoved = pidFileRemoved;
			result.logFileRemoved = logFileRemoved;
		}
	});
	return result;
}
