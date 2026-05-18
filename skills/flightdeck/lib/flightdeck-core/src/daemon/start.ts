// flightdeck-daemon `start` action body.
//
// Two phases:
//   A. Spawn dispatch (caller side, when --foreground is not set):
//      - detach: spawn a setsid + nohup child re-running this script
//        with --foreground appended. Block until child writes pid
//        file or 10s timeout.
//      - tmux-window: spawn a tmux new-window running this script
//        with --foreground appended; child writes pid file too.
//   B. Foreground (the actual daemon, --foreground set):
//      - PID lock acquisition with retry (flock -n on PID_LOCK, up to
//        30 × 200ms).
//      - PID file refusal logic (same-pid OK after max-lifetime
//        successor; alive-pid + lock-free → race, exit; dead pid →
//        log and overwrite).
//      - gcOrphanState + legacy-busy-file warning.
//      - Write PID_FILE.
//      - lockedCleanupState (fresh-start wipe of stale wake/event).
//      - Run the loop.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { inprocFlockAvailable, tryAcquireLockFd } from "../shared/inproc-flock.ts";

import { fdBusyFile, fdEventsFile, fdHeartbeatFile, fdLogFile, fdPidFile, fdPidLock, fdSessionLock, fdWakeEventsLog, fdWakePending } from "../paths/daemon.ts";
import { daemonLog, daemonWarn } from "./log.ts";
import { gcOrphanState } from "./gc.ts";
import { installShutdownHandlers, killAllSubscribers } from "./lifecycle.ts";
import { lockedCleanupState } from "../state/locking.ts";
import { emitDaemonStarted, resolveDaemonActivityContext } from "./activity.ts";
import { runLoop, type RunLoopOpts } from "./loop.ts";
import { PaneCache, resolvePaneId } from "./pane-meta.ts";

export interface StartOpts extends Omit<RunLoopOpts, "scriptPath" | "origArgs" | "fromHandoff"> {
	foreground: boolean;
	spawnMode: "detach" | "tmux-window";
	scriptPath: string;
	origArgs: string[];
	// Round-5 #1: set true when invoked as the successor of a
	// max-lifetime handoff. foregroundStart MUST NOT run the
	// fresh-start wipe of wake-pending/events/wake-events.log in this
	// mode — the parent preserved those files for us to consume.
	fromHandoff: boolean;
}

function sleepMs(ms: number): Promise<void> {
	return new Promise((res) => setTimeout(res, ms));
}

function validateMasterTargetAlive(target: string): void {
	const cache = new PaneCache();
	cache.refresh();
	const masterId = resolvePaneId(target);
	if (!masterId || !cache.alive(masterId)) {
		process.stderr.write(`error: master pane '${target}' does not exist; pass --master "$TMUX_PANE" or run 'tmux list-panes -a'\n`);
		process.exit(4);
	}
}

async function dispatchSpawn(opts: StartOpts): Promise<never> {
	validateMasterTargetAlive(opts.masterTarget);
	const pidFile = fdPidFile(opts.stateDir, opts.sessionKey);
	const logFile = fdLogFile(opts.stateDir, opts.sessionKey);
	// Build child args. opts.origArgs is the post-action argv slice
	// (--session ... --master ... --inner ...), so prepend 'start' to
	// reconstruct the trampoline action. Drop spawn-mode flags so the
	// child doesn't re-detach, then append --foreground.
	const SKIP_FLAGS = new Set(["--in-tmux-window", "--foreground", "--no-detach"]);
	const childArgs = ["start", ...opts.origArgs.filter((a) => !SKIP_FLAGS.has(a)), "--foreground"];

	if (opts.spawnMode === "tmux-window") {
		const windowName = `[fd] daemon-${opts.sessionKey}`;
		// tmux server doesn't inherit caller env (round-4 #4 fix).
		// Prepend `env KEY=VALUE ...` carrying the daemon-state knobs
		// so the child window writes state to the right directory and
		// re-enters the TS path under the same trampoline gate.
		const forwardKeys = [
			"FD_STATE_DIR",
			"FD_POLL_SEC",
			"FD_STABILITY",
			"FD_CAPTURE_LINES",
			"FD_HARNESS",
			"FD_CLASSIFIER",
			"FD_VERBOSE",
			"FD_WAKE_PENDING_TTL",
			"FD_MASTER_TURN_TTL",
			"FD_HEARTBEAT_TICKS",
			"FD_MAX_LIFETIME",
			"FD_GRACE_SEC",
			"FD_OC_POLL_SEC",
			"FD_OC_BACKOFF_MAX_SEC",
			"FD_ADAPTER_FRESHNESS_TTL",
			"FD_ADAPTER_READ_TIMEOUT_SEC",
			"FD_CODEX_RPC_TIMEOUT_MS",
			"FD_SPAWN_MODE",
			"PI_BIN",
			"PI_BRIDGE_BIN",
			"XDG_RUNTIME_DIR",
		];
		const envPrefix: string[] = ["env"];
		for (const k of forwardKeys) {
			const v = process.env[k];
			if (v === undefined || v === "") continue;
			envPrefix.push(`${k}=${v}`);
		}
		const quote = (s: string): string => `'${s.replace(/'/g, "'\\''")}'`;
		const cmdStr = [...envPrefix.map(quote), ...[opts.scriptPath, ...childArgs].map(quote)].join(" ");
		const r = spawnSync("tmux", ["new-window", "-d", "-t", opts.sessionId, "-n", windowName, cmdStr], { encoding: "utf8" });
		if (r.status !== 0) {
			process.stderr.write("Error: failed to spawn flightdeck-daemon tmux window\n");
			process.exit(1);
		}
	} else {
		// Detach via setsid + nohup with output appended to LOG.
		// $1 is the log file path; $2 onwards is the command and its
		// args. shift drops the log path so $@ becomes the command.
		const detachScript = `log="$1"; shift; setsid nohup "$@" </dev/null >>"$log" 2>&1 &\necho $!`;
		const r = spawnSync("bash", ["-c", detachScript, "_", logFile, opts.scriptPath, ...childArgs], { encoding: "utf8" });
		if (r.status !== 0) {
			process.stderr.write(`Error: detach spawn failed: ${r.stderr ?? ""}\n`);
			process.exit(1);
		}
	}

	// Block until child writes pid file or timeout. 10s matches bash.
	const deadline = Date.now() + 10_000;
	while (Date.now() < deadline) {
		if (existsSync(pidFile)) {
			try {
				const txt = readFileSync(pidFile, "utf8").trim();
				if (/^[1-9][0-9]*$/.test(txt)) {
					const pid = Number.parseInt(txt, 10);
					try { process.kill(pid, 0); }
					catch (e) { if ((e as NodeJS.ErrnoException).code !== "EPERM") { await sleepMs(200); continue; } }
					process.stdout.write(`daemon spawned pid=${pid} session=${opts.sessionName} mode=${opts.spawnMode}\n`);
					process.exit(0);
				}
			} catch { /* */ }
		}
		await sleepMs(200);
	}
	process.stderr.write(`Error: spawn timed out after 10s (${opts.spawnMode}); check ${logFile}\n`);
	process.exit(1);
}

async function foregroundStart(opts: StartOpts): Promise<void> {
	const pidFile = fdPidFile(opts.stateDir, opts.sessionKey);
	const pidLock = fdPidLock(opts.stateDir, opts.sessionKey);
	const logFile = fdLogFile(opts.stateDir, opts.sessionKey);
	const sessionLock = fdSessionLock(opts.stateDir, opts.sessionKey);
	const wakePending = fdWakePending(opts.stateDir, opts.sessionKey);
	const eventsFile = fdEventsFile(opts.stateDir, opts.sessionKey);
	const busyFile = fdBusyFile(opts.stateDir, opts.sessionKey);
	const heartbeatFile = fdHeartbeatFile(opts.stateDir, opts.sessionKey);
	const wakeEventsLog = fdWakeEventsLog(opts.stateDir, opts.sessionKey);

	const log = (tag: string, msg: string): void => daemonLog(logFile, tag, msg);
	const warn = (tag: string, msg: string): void => daemonWarn(logFile, tag, msg);
	const activity = resolveDaemonActivityContext(opts.sessionName);

	// PID-file lock acquisition. Mirror bash's 30 × 0.2s grace using
	// non-blocking flock(2) (LOCK_EX | LOCK_NB) via bun:ffi. On
	// success the fd is held open for the daemon's lifetime; on busy
	// we retry up to 30 times with a 200ms sleep between attempts. The
	// previous implementation used blocking flock which defeated the
	// retry grace (a held lock would block the first call past 6s).
	if (!inprocFlockAvailable()) {
		process.stderr.write("Error: in-process flock(2) unavailable; cannot acquire PID lock\n");
		process.exit(1);
	}
	let heldFd: number | null = null;
	for (let attempts = 0; attempts < 30; attempts += 1) {
		heldFd = tryAcquireLockFd(pidLock);
		if (heldFd !== null) break;
		await sleepMs(200);
	}
	if (heldFd === null) {
		process.stderr.write(`daemon already running for session=${opts.sessionName} (lock held after 30 retries)\n`);
		process.exit(1);
	}
	// heldFd intentionally not closed — the kernel keeps the flock
	// for the duration of this process. Released on exit() / kill via
	// the kernel's fd cleanup.
	void heldFd;

	// PID file refusal logic.
	if (existsSync(pidFile)) {
		const old = readFileSync(pidFile, "utf8").trim();
		if (old) {
			let alive = false;
			const pid = Number.parseInt(old, 10);
			if (Number.isFinite(pid) && pid > 0) {
				try { process.kill(pid, 0); alive = true; }
				catch (e) { alive = (e as NodeJS.ErrnoException).code === "EPERM"; }
			}
			if (alive) {
				// Bash allows same-pid case after max-lifetime self-exec.
				// We can't preserve PID on max-lifetime (Option A
				// divergence), so this branch is "another daemon already
				// running" — exit.
				process.stderr.write(`PID file claims pid=${old} which is alive but lock acquired — concurrent daemon?\n`);
				process.exit(1);
			} else {
				log("refuse-stale", `removing stale pid file pid=${old}`);
			}
		}
	}

	// Startup GC.
	gcOrphanState({
		stateDir: opts.stateDir,
		lockedCleanupForKey: (key) => {
			const sessLock = fdSessionLock(opts.stateDir, key);
			const wp = fdWakePending(opts.stateDir, key);
			const ef = fdEventsFile(opts.stateDir, key);
			const wel = fdWakeEventsLog(opts.stateDir, key);
			const hb = fdHeartbeatFile(opts.stateDir, key);
			lockedCleanupState(sessLock, {
				wakePending: wp,
				eventsFile: ef,
				wakeEventsLog: wel,
				heartbeatFile: hb,
				nonblock: true,
			});
		},
		log,
	});

	// Legacy busy-file warning.
	const legacyBusyCandidates = [`/tmp/fd-master-${opts.sessionKey}.busy`];
	const gitTop = spawnSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" });
	if (gitTop.status === 0) {
		const root = (gitTop.stdout ?? "").trim();
		if (root) legacyBusyCandidates.push(`${root}/tmp/fd-master-${opts.sessionKey}.busy`);
	}
	for (const legacy of legacyBusyCandidates) {
		if (legacy === busyFile) continue;
		if (existsSync(legacy)) {
			warn("path-mismatch", `legacy busy file at ${legacy} (current: ${busyFile}) — remove it; pre-#41 install`);
		}
	}

	validateMasterTargetAlive(opts.masterTarget);

	// Write own pid into the PID_FILE.
	writeFileSync(pidFile, `${process.pid}\n`);

	// Install signal traps + EXIT cleanup BEFORE the lockedCleanupState
	// so a signal during fresh-start wipe still cleans up subscriber
	// state / temp files.
	installShutdownHandlers({
		activity,
		pidFile,
		heartbeatFile,
		eventsFile,
		wakeEventsLog,
		sessionLock,
		killSubscribers: () => killAllSubscribers({
			stateDir: opts.stateDir,
			sessionKey: opts.sessionKey,
			collectDescendants: (pid) => {
				// Inline collectDescendants from flightdeck-daemon.ts.
				const r = spawnSync("ps", ["-eo", "pid=,ppid="], { encoding: "utf8" });
				if (r.status !== 0) return [];
				const children = new Map<number, number[]>();
				for (const line of (r.stdout ?? "").split("\n")) {
					const parts = line.trim().split(/\s+/);
					if (parts.length !== 2) continue;
					const p = Number.parseInt(parts[0]!, 10);
					const pp = Number.parseInt(parts[1]!, 10);
					if (!Number.isFinite(p) || !Number.isFinite(pp)) continue;
					const list = children.get(pp);
					if (list) list.push(p);
					else children.set(pp, [p]);
				}
				const out: number[] = [];
				const queue: number[] = [pid];
				while (queue.length > 0) {
					const c = queue.shift()!;
					for (const k of children.get(c) ?? []) { out.push(k); queue.push(k); }
				}
				return out;
			},
		}),
		lockedCleanup: () => {
			lockedCleanupState(sessionLock, {
				wakePending, eventsFile, wakeEventsLog,
				nonblock: true,
			});
		},
		log,
		masterId: () => opts.masterTarget,
	});

	emitDaemonStarted(activity, { lifetimeMax: opts.maxLifetime, mode: opts.spawnMode, pid: process.pid });

	// Fresh-start state wipe under SESSION_LOCK. Round-5 #1: skip
	// when invoked as a max-lifetime successor — the parent kept
	// wake-pending/events/wake-events.log for the successor to drain
	// on its first run-loop tick, and wiping them here would silently
	// drop in-flight wakes + unacked master events.
	if (opts.fromHandoff) {
		log("from-handoff", `pid=${process.pid} (preserving wake-pending/events/wake-events.log from predecessor)`);
	} else {
		// Preserve previous daemon-exited rows so the master can drain them after respawn.
		lockedCleanupState(sessionLock, { wakePending, wakeEventsLog });
	}

	void resolve;

	await runLoop({
		stateDir: opts.stateDir,
		sessionId: opts.sessionId,
		sessionKey: opts.sessionKey,
		sessionName: opts.sessionName,
		masterTarget: opts.masterTarget,
		masterHarness: opts.masterHarness,
		innerTargets: opts.innerTargets,
		innerHarnesses: opts.innerHarnesses,
		classifierBin: opts.classifierBin,
		defaultHarness: opts.defaultHarness,
		pollSec: opts.pollSec,
		stabilitySec: opts.stabilitySec,
		captureLines: opts.captureLines,
		graceSec: opts.graceSec,
		heartbeatTicks: opts.heartbeatTicks,
		maxLifetime: opts.maxLifetime,
		wakePendingTtl: opts.wakePendingTtl,
		masterTurnTtl: opts.masterTurnTtl,
		verbose: opts.verbose,
		debugPane: opts.debugPane,
		fromHandoff: opts.fromHandoff,
		scriptPath: opts.scriptPath,
		origArgs: opts.origArgs,
		paneRegistryBin: opts.paneRegistryBin,
		activity,
	});
}

export async function start(opts: StartOpts): Promise<void> {
	if (!opts.foreground) {
		await dispatchSpawn(opts);
		return;
	}
	await foregroundStart(opts);
}
