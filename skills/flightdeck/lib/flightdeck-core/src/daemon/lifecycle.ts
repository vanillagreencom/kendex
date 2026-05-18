// Daemon lifecycle pieces: heartbeat writer,
// signal-trap installation, max-lifetime self-exec, startup-cleanup
// helpers. The pieces that compose the daemon lifecycle outside the
// run-loop body itself.
//
// DESIGN DIVERGENCE FROM BASH (parent-approved Option A):
// ---------------------------------------------------------
// Bash daemon: `exec "$0" "${ORIG_ARGS[@]}"` on max-lifetime replaces
// the process in place. PID is preserved across the self-exec.
//
// TS daemon: Bun/node has no execve binding. Instead, spawn a detached
// successor via setsid + nohup and exit cleanly. The successor's start
// path runs the same flow (acquire PID lock, write PID_FILE with its
// own PID, run loop). **The daemon PID changes** across max-lifetime
// boundaries in TS mode; bash preserves it.
//
// Why the change is safe:
//   - Master's ack contract uses BUSY_FILE.pid (master's own pid),
//     not the daemon's pid. Daemon PID change is invisible to master.
//   - External callers (`flightdeck-daemon status/health/stop`) re-read
//     PID_FILE on every call. They observe the successor's PID and
//     operate against it correctly.
//   - Subscriber children's parent_pid arg becomes stale after the
//     successor takes over. They exit cleanly via `kill -0 "$parent_pid"`
//     failure. The successor's first run-loop tick respawns them via
//     spawn_*_subscriber's reattach-or-spawn logic.
//   - PID_FILE / heartbeat / wake-pending / events.jsonl / wake-events.log
//     all survive the handoff (same paths, same locking discipline).
//
// What may briefly differ:
//   - A ~100ms gap where no daemon is in the run-loop (successor
//     fork → PID lock acquire → first tick). Equivalent to bash exec's
//     re-init cost.
//   - Subscribers respawn (one fresh child per inner pane) instead of
//     continuing across the exec. Same observable outcome since
//     subscribers are idempotent against reattach.
//
// Operator-facing: see README.md daemon tuning table for the FD_MAX_LIFETIME
// note. The TS divergence is transparent to flightdeck masters and the
// pi-flightdeck dashboard.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, openSync, utimesSync } from "node:fs";

import { emitDaemonStopped, emitMaxLifetimeHandoff, type DaemonActivityContext } from "./activity.ts";

export function touchHeartbeat(file: string): void {
	// `utimesSync(file, atime, mtime)` requires the file to exist.
	// Create it on first call.
	try { utimesSync(file, Date.now() / 1000, Date.now() / 1000); }
	catch (e) {
		if ((e as NodeJS.ErrnoException).code === "ENOENT") {
			try { closeSync(openSync(file, "a")); } catch { /* best effort */ }
		}
	}
}

export interface ShutdownOpts {
	pidFile: string;
	heartbeatFile: string;
	eventsFile: string;
	wakeEventsLog: string;
	sessionLock: string;
	killSubscribers: () => void;
	lockedCleanup: () => void;
	log: (tag: string, msg: string) => void;
	masterId: () => string;
	activity?: DaemonActivityContext;
}

// Handoff mode: when set, the EXIT cleanup MUST NOT remove PID_FILE /
// heartbeat / wake-pending / events / wake-events log. The successor
// inherits all of these as part of Option A's contract.
let handoffMode = false;
export function setHandoffMode(on: boolean): void { handoffMode = on; }

let daemonExitReason = "other";
export function setDaemonExitReason(reason: "master-gone" | "session-gone" | "signal-term" | "signal-int" | "other"): void {
	daemonExitReason = reason;
}

let daemonMasterId = "";
export function setDaemonMasterId(masterId: string): void { daemonMasterId = masterId; }

function emitDaemonExitedEvent(opts: ShutdownOpts): void {
	if (!opts.eventsFile || !opts.sessionLock) {
		const msg = "missing eventsFile or sessionLock";
		opts.log("daemon-exited-emit-failed", msg);
		process.stderr.write(`[daemon-exited-emit-failed] ${msg}\n`);
		throw new Error(msg);
	}
	const ts = new Date().toISOString();
	const reason = daemonExitReason || "other";
	const masterId = daemonMasterId || opts.masterId();
	emitDaemonStopped(opts.activity ?? {}, { masterId, pid: process.pid, reason });
	const hash = createHash("sha256").update(`${ts}|${reason}|${masterId}|${process.pid}`).digest("hex").slice(0, 12);
	const row = JSON.stringify({
		ts,
		pane_id: masterId,
		event_type: "daemon-exited",
		reason,
		master_id: masterId,
		pid: process.pid,
		hash,
		tag: "daemon-exited",
		stable_age_sec: 0,
		details: { event_type: "daemon-exited", reason, master_id: masterId, pid: process.pid },
	});
	const r = spawnSync("bash", ["-c", "exec 219>\"$1\"; flock 219; printf '%s\\n' \"$2\" >> \"$3\"", "_", opts.sessionLock, row, opts.eventsFile], { encoding: "utf8" });
	if (r.status !== 0 || r.error) {
		const msg = `events_file=${opts.eventsFile} reason=${reason} error=${r.error ? r.error.message : (r.stderr || "unknown")}`;
		opts.log("daemon-exited-emit-failed", msg);
		process.stderr.write(`[daemon-exited-emit-failed] ${msg}\n`);
		throw new Error(msg);
	}
}

// Install EXIT + SIGINT/TERM/HUP handlers. Idempotent.
//
// Subtle: Bun's `process.on('exit')` does NOT fire on uncaught signal
// termination. We log + clean inside the signal handler itself (not in
// process.exit's exit hook) and then exit with the conventional 128+sig
// status so the parent observes the right exit code.
let installed = false;
export function installShutdownHandlers(opts: ShutdownOpts): void {
	if (installed) return;
	installed = true;
	let cleaned = false;
	const cleanup = (): void => {
		if (cleaned) return;
		cleaned = true;
		if (handoffMode) {
			// Max-lifetime handoff: leave all state files for the successor.
			// Subscribers also stay alive — they exit on parent_pid death
			// and the successor respawns them.
			opts.log("stop-handoff", `pid=${process.pid} (state files preserved for successor)`);
			return;
		}
		opts.log("stop", `pid=${process.pid}`);
		try { opts.killSubscribers(); } catch { /* */ }
		for (const f of [opts.pidFile, opts.heartbeatFile]) {
			if (!f) continue;
			try { const { unlinkSync } = require("node:fs") as typeof import("node:fs"); unlinkSync(f); }
			catch { /* missing OK */ }
		}
		try { opts.lockedCleanup(); } catch { /* */ }
		try { emitDaemonExitedEvent(opts); } catch { /* already logged */ }
	};
	process.on("exit", cleanup);
	const sigStatus: Record<string, number> = { SIGINT: 130, SIGTERM: 143, SIGHUP: 129 };
	const sigHandler = (sig: NodeJS.Signals): void => {
		setDaemonExitReason(sig === "SIGINT" ? "signal-int" : "signal-term");
		cleanup();
		process.exit(sigStatus[sig] ?? 0);
	};
	// Bun quirk workaround: process.on("SIGTERM") after `await import()`
	// doesn't fire. The CLI entry installs top-level signal listeners
	// and exposes a globalThis hook that we populate here.
	const hook = (globalThis as unknown as { __fdSigSet?: (cb: typeof sigHandler) => void }).__fdSigSet;
	if (typeof hook === "function") {
		hook(sigHandler);
	} else {
		process.on("SIGINT", sigHandler);
		process.on("SIGTERM", sigHandler);
		process.on("SIGHUP", sigHandler);
	}
}

// Max-lifetime self-exec. Spawn a detached successor with the same
// argv, then exit cleanly. Successor uses setsid + nohup so it
// survives the parent's exit; stdio redirected to LOG.
//
// PID is NOT preserved across this boundary in the TS port (Option A
// divergence — see module header). External tooling that watches the
// daemon PID must re-read PID_FILE each call rather than caching the
// initial PID. `flightdeck-daemon status/health/stop` already do this.
export interface MaxLifetimeExecOpts {
	scriptPath: string;
	origArgs: string[];
	logFile: string;
	activity?: DaemonActivityContext;
	handoffInnerTargets?: string[];
	handoffInnerHarnesses?: string[];
}

function replaceArgValue(args: string[], flag: string, value: string): string[] {
	const out: string[] = [];
	let replaced = false;
	for (let i = 0; i < args.length; i += 1) {
		const arg = args[i]!;
		if (arg === flag) {
			if (!replaced) {
				out.push(flag, value);
				replaced = true;
			}
			i += 1;
			continue;
		}
		if (arg.startsWith(`${flag}=`)) {
			if (!replaced) {
				out.push(flag, value);
				replaced = true;
			}
			continue;
		}
		out.push(arg);
	}
	if (!replaced) out.push(flag, value);
	return out;
}

export function maxLifetimeExec(opts: MaxLifetimeExecOpts): never {
	const { scriptPath, origArgs, logFile } = opts;
	// Engage handoff mode BEFORE spawning the successor: the EXIT
	// cleanup in installShutdownHandlers must not delete PID_FILE /
	// heartbeat / wake-pending / events / wake-events log. The
	// successor takes ownership and rewrites PID_FILE on its start path.
	setHandoffMode(true);

	// Build successor invocation. opts.origArgs is the post-action
	// argv slice (--session ... --master ... etc.); we must prepend
	// 'start' to reconstruct the trampoline action. We also append
	// --foreground so the successor goes straight to foregroundStart
	// instead of re-detaching, AND --from-handoff so the successor
	// knows to skip the fresh-start wipe (round-5 #1 — the parent
	// preserved wake-pending/events/wake-events.log for us).
	const SKIP = new Set(["--in-tmux-window", "--foreground", "--no-detach", "--from-handoff"]);
	let handoffArgs = origArgs.filter((a) => !SKIP.has(a));
	if (opts.handoffInnerTargets) {
		handoffArgs = replaceArgValue(handoffArgs, "--inner", opts.handoffInnerTargets.join(","));
	}
	if (opts.handoffInnerHarnesses) {
		handoffArgs = replaceArgValue(handoffArgs, "--inner-harnesses", opts.handoffInnerHarnesses.join(","));
	}
	const childArgs = ["start", ...handoffArgs, "--foreground", "--from-handoff"];

	// Shell wrapper: $1 is the log path; shift it out of $@ before
	// exec so 'nohup "$@"' runs the script + args (not the log file).
	// Pre-round-4 bug: log path was left in $@ and nohup tried to run
	// it as a command, producing 'permission denied'.
	const script = `log="$1"; shift; setsid nohup "$@" </dev/null >>"$log" 2>&1 &\necho $!`;
	const spawned = spawnSync("bash", ["-c", script, "_", logFile, scriptPath, ...childArgs], { encoding: "utf8" });
	if (spawned.stderr) process.stderr.write(spawned.stderr);
	const successorPid = Number.parseInt((spawned.stdout ?? "").trim(), 10);
	emitMaxLifetimeHandoff(opts.activity ?? {}, Number.isFinite(successorPid) ? successorPid : null);
	process.exit(0);
}

// Helper for the kill_all_oc_subscribers behavior: reap subscriber
// pid files scoped to this session's key, killing each subscriber's
// descendant tree before the subscriber itself.
export interface KillSubscribersOpts {
	stateDir: string;
	sessionKey: string;
	collectDescendants: (pid: number) => number[];
}

export function killAllSubscribers(opts: KillSubscribersOpts): void {
	const { stateDir, sessionKey, collectDescendants } = opts;
	const { readdirSync, readFileSync, unlinkSync } = require("node:fs") as typeof import("node:fs");
	const { join } = require("node:path") as typeof import("node:path");
	let entries: string[];
	try { entries = readdirSync(stateDir); } catch { return; }
	for (const entry of entries) {
		const ok = entry.endsWith(".pid") && (
			entry.startsWith(`fd-subscriber-${sessionKey}-`) ||
			entry.startsWith(`fd-cc-subscriber-${sessionKey}-`) ||
			entry.startsWith(`fd-pi-subscriber-${sessionKey}-`) ||
			entry.startsWith(`fd-cx-subscriber-${sessionKey}-`)
		);
		if (!ok) continue;
		const file = join(stateDir, entry);
		try {
			const txt = readFileSync(file, "utf8").trim();
			const pid = Number.parseInt(txt, 10);
			if (Number.isFinite(pid) && pid > 0) {
				let alive = false;
				try { process.kill(pid, 0); alive = true; }
				catch (e) { alive = (e as NodeJS.ErrnoException).code === "EPERM"; }
				if (alive) {
					for (const d of collectDescendants(pid)) {
						try { process.kill(d, "SIGTERM"); } catch { /* */ }
					}
					try { process.kill(pid, "SIGTERM"); } catch { /* */ }
				}
			}
		} catch { /* */ }
		try { unlinkSync(file); } catch { /* */ }
	}
}
