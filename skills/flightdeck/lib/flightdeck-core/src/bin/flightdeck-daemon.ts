#!/usr/bin/env bun
// Bun signal-handler quirk: process.on("SIGTERM") registered AFTER
// `await import(...)` does not fire (verified empirically with bun
// 1.3.11). Install at the very top of the entry module, before any
// imports or awaits, then route to a callback that lifecycle.ts
// populates later.
type SigCallback = (sig: NodeJS.Signals) => void;
let sigCallback: SigCallback | null = null;
(globalThis as unknown as { __fdSigSet: (cb: SigCallback) => void }).__fdSigSet = (cb) => { sigCallback = cb; };
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"] as const) {
	process.on(sig, () => {
		if (sigCallback) sigCallback(sig);
		else process.exit(sig === "SIGINT" ? 130 : sig === "SIGHUP" ? 129 : 143);
	});
}

// Full TS port of skills/flightdeck/scripts/flightdeck-daemon.
//
// Actions: status / events / ack / find-window / health / stop / start.
// `start` routes through src/daemon/start.ts → foregroundStart → runLoop.
// Subscriber loop bodies live in scripts/lib/subscribers.bash and are
// invoked by the daemon as one bash subprocess per harness pane.

import { spawnSync } from "node:child_process";
import {
	existsSync,
	readFileSync,
	statSync,
	unlinkSync,
	readdirSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
	fdBusyFile,
	fdEventsFile,
	fdHeartbeatFile,
	fdLogFile,
	fdPidFile,
	fdPidLock,
	fdResolveStateDir,
	fdSessionKeyFromId,
	fdSessionLock,
	fdWakeEventsLog,
	fdWakePending,
} from "../paths/daemon.ts";
import { lockedCleanupState, lockedEventsDrain } from "../state/locking.ts";
import { FULL_REQUIRED, STATE_ONLY_REQUIRED, preflightDeps, onShutdown } from "../shared/preflight.ts";

// Per-action required set so the hot path (ack / events) doesn't pay
// a `command -v` fork per dep per invocation.
//
// Session-name preflight gate: when the session argument is a raw
// tmux session id ($N) or a session key (sN), key resolution doesn't
// need tmux — the key derives directly from the input. For a session
// NAME, tmux must be on PATH so resolveSessionId can map name → id
// without silently falling through to an empty key (which causes
// status/events/ack to report 'no daemon' instead of failing cleanly).
const _action = process.argv[2] ?? "";
let _sessionArg = "";
for (let i = 3; i < process.argv.length; i += 1) {
	const a = process.argv[i];
	if (a === "--session") { _sessionArg = process.argv[i + 1] ?? ""; break; }
	if (a && a.startsWith("--session=")) { _sessionArg = a.slice("--session=".length); break; }
}
const _needsTmuxResolve = !!_sessionArg && !/^\$\d+$/.test(_sessionArg) && !/^s\d+$/.test(_sessionArg);
const _stateOnlyAction = _action === "ack" || _action === "events";
if (_stateOnlyAction && !_needsTmuxResolve) {
	preflightDeps(STATE_ONLY_REQUIRED);
} else if (_stateOnlyAction) {
	preflightDeps([...STATE_ONLY_REQUIRED, "tmux"]);
} else {
	preflightDeps(FULL_REQUIRED);
}
onShutdown(() => { /* placeholder — daemon-start will register its own cleanups */ });

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT_PATH = resolve(HERE, "../../../../scripts/flightdeck-daemon");

function die(msg: string, code = 2): never {
	process.stderr.write(`${msg}\n`);
	process.exit(code);
}

function usage(): never {
	process.stderr.write(
`Usage:
  flightdeck-daemon start  --session <S> --master <pane> --inner <p1>[,<p2>...] [--master-harness <h>] [--inner-harnesses <h1>[,<h2>...]] [--foreground|--in-tmux-window] [--debug-pane <pane_id>]
  flightdeck-daemon stop        --session <S>
  flightdeck-daemon status      --session <S>
  flightdeck-daemon health      --session <S>
  flightdeck-daemon find-window --session <S>
  flightdeck-daemon events      --session <S>
  flightdeck-daemon ack         --session <S>

start exit codes:
  1 lock/spawn/runtime failure
  2 usage, missing dependency/session, or inner-pane validation failure
  4 stale --master pane (re-resolve from $TMUX_PANE and retry once)
`);
	process.exit(2);
}

const argv = process.argv.slice(2);
const action = argv.shift();
if (!action) usage();

let sessionName = "";
const rest: string[] = [];
for (let i = 0; i < argv.length; i += 1) {
	if (argv[i] === "--session") { sessionName = argv[++i] ?? ""; continue; }
	if (argv[i]!.startsWith("--session=")) { sessionName = argv[i]!.slice("--session=".length); continue; }
	rest.push(argv[i]!);
}
if (!sessionName) die("--session required");



// Resolve tmux session_id + session_key from either a session name or a
// raw tmux session_id ($N). Mirrors bash resolve_session_pair.
//
// Fall back to using the provided input as a name when tmux can't resolve
// it (session already gone) so stop/status/events/ack can still clean up
// stale daemon files. Uses tab as the delimiter so session names with
// spaces work.
function resolveSessionId(input: string): { id: string; key: string; name: string } {
	const r = spawnSync("tmux", ["display-message", "-p", "-t", input, "#{session_name}\t#{session_id}"], { encoding: "utf8" });
	if (r.status === 0 && r.stdout) {
		const [name, id] = (r.stdout ?? "").trim().split("\t");
		if (id) return { id, key: fdSessionKeyFromId(id), name: name ?? input };
	}
	// Tmux session gone or unknown — use the input as the session key
	// directly when it already looks like one (e.g. "s143"). Otherwise
	// treat as a name and emit an empty key so callers report "no daemon"
	// rather than silently doing nothing.
	if (/^s\d+$/.test(input)) return { id: "", key: input, name: input };
	if (/^\$\d+$/.test(input)) return { id: input, key: fdSessionKeyFromId(input), name: input };
	return { id: "", key: "", name: input };
}

const { id: sessionId, key: sessionKey, name: resolvedSessionName } = resolveSessionId(sessionName);
sessionName = resolvedSessionName;

const stateDir = fdResolveStateDir();

// start: run the TS daemon. The run-loop owns wake delivery, subscriber
// lifecycle, and state-file mutations under the per-session lock.
if (action === "start") {
	{
		const { start } = await import("../daemon/start.ts");
		// Parse start args inline.
		let masterTarget = "";
		let masterHarness = "";
		let innerTargetsCsv = "";
		let sawInner = false;
		let innerHarnessesCsv = "";
		let foreground = false;
		let spawnMode: "detach" | "tmux-window" = (process.env.FD_SPAWN_MODE === "tmux-window") ? "tmux-window" : "detach";
		let debugPane = "";
		// Round-5 #1: --from-handoff signals that we're the successor
		// of a max-lifetime parent. foregroundStart skips the fresh-
		// start wipe so the predecessor's preserved wake-pending /
		// events / wake-events.log survive.
		let fromHandoff = false;
		const args = rest.slice();
		for (let i = 0; i < args.length; i += 1) {
			const a = args[i]!;
			switch (a) {
				case "--master": masterTarget = args[++i] ?? ""; break;
				case "--master-harness": masterHarness = args[++i] ?? ""; break;
				case "--inner": sawInner = true; innerTargetsCsv = args[++i] ?? ""; break;
				case "--inner-harnesses": innerHarnessesCsv = args[++i] ?? ""; break;
				case "--foreground":
				case "--no-detach": foreground = true; break;
				case "--in-tmux-window": spawnMode = "tmux-window"; break;
				case "--from-handoff": fromHandoff = true; break;
				case "--debug-pane": debugPane = args[++i] ?? ""; break;
				default: die(`unknown arg: ${a}`);
			}
		}
		const innerTargets = innerTargetsCsv.split(",").map((item) => item.trim()).filter(Boolean);
		if (!masterTarget || !sawInner || (!fromHandoff && innerTargets.length === 0)) die("start needs --master and --inner");
		if (!sessionId) die(`Error: tmux session '${sessionName}' not found`);

		const pollSec = Number.parseInt(process.env.FD_POLL_SEC ?? "2", 10) || 2;
		const stabilitySec = Number.parseInt(process.env.FD_STABILITY ?? "3", 10) || 3;
		const captureLines = Number.parseInt(process.env.FD_CAPTURE_LINES ?? "200", 10) || 200;
		const graceSec = Number.parseInt(process.env.FD_GRACE_SEC ?? "30", 10) || 30;
		const heartbeatTicks = Number.parseInt(process.env.FD_HEARTBEAT_TICKS ?? "60", 10) || 60;
		const maxLifetime = Number.parseInt(process.env.FD_MAX_LIFETIME ?? "14400", 10);
		const wakePendingTtl = Number.parseInt(process.env.FD_WAKE_PENDING_TTL ?? "300", 10) || 300;
		const masterTurnTtl = Number.parseInt(process.env.FD_MASTER_TURN_TTL ?? "3600", 10) || 3600;
		const defaultHarness = process.env.FD_HARNESS ?? "";
		const verbose = process.env.FD_VERBOSE === "1";

		const { dirname, resolve } = await import("node:path");
		const scriptsDir = dirname(SCRIPT_PATH);
		const classifierCandidate = process.env.FD_CLASSIFIER ?? resolve(scriptsDir, "prompt-classify");
		const { statSync } = await import("node:fs");
		let classifierBin = "";
		try { const s = statSync(classifierCandidate); if (s.isFile() && (s.mode & 0o111)) classifierBin = classifierCandidate; }
		catch { /* */ }
		const paneRegistryBin = resolve(scriptsDir, "pane-registry");

		await start({
			stateDir,
			sessionId,
			sessionKey,
			sessionName,
			masterTarget,
			masterHarness,
			innerTargets,
			innerHarnesses: innerHarnessesCsv ? innerHarnessesCsv.split(",").map((item) => item.trim()) : [],
			classifierBin,
			defaultHarness,
			pollSec, stabilitySec, captureLines, graceSec,
			heartbeatTicks, maxLifetime, wakePendingTtl, masterTurnTtl,
			verbose, debugPane,
			spawnMode,
			foreground,
			fromHandoff,
			scriptPath: SCRIPT_PATH,
			origArgs: argv,
			paneRegistryBin,
		});
		process.exit(0);
	}
}
const pidFile = sessionKey ? fdPidFile(stateDir, sessionKey) : "";
const pidLock = sessionKey ? fdPidLock(stateDir, sessionKey) : "";
const logFile = sessionKey ? fdLogFile(stateDir, sessionKey) : "";
const sessionLock = sessionKey ? fdSessionLock(stateDir, sessionKey) : "";
const eventsFile = sessionKey ? fdEventsFile(stateDir, sessionKey) : "";
const wakePending = sessionKey ? fdWakePending(stateDir, sessionKey) : "";
const busyFile = sessionKey ? fdBusyFile(stateDir, sessionKey) : "";
const heartbeatFile = sessionKey ? fdHeartbeatFile(stateDir, sessionKey) : "";
const wakeEventsLog = sessionKey ? fdWakeEventsLog(stateDir, sessionKey) : "";

function pidAlive(pid: number): boolean {
	if (!Number.isFinite(pid) || pid <= 0) return false;
	try { process.kill(pid, 0); return true; }
	catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
}

function readPid(file: string): number | null {
	if (!existsSync(file)) return null;
	try {
		const txt = readFileSync(file, "utf8").trim();
		if (!/^[1-9][0-9]*$/.test(txt)) return null;
		return Number.parseInt(txt, 10);
	} catch { return null; }
}

function drainEvents(): void {
	if (!sessionLock || !eventsFile) return;
	// Full drain + stranded-recovery under SESSION_LOCK held by a bash
	// child for the duration of the work. Matches the bash daemon's
	// `drain_events` contract.
	const r = lockedEventsDrain(sessionLock, eventsFile);
	if (r.stdout) process.stdout.write(r.stdout);
	if (r.status !== 0) {
		process.stderr.write(r.stderr || "");
		process.exit(r.status ?? 1);
	}
}

function ackAndDrain(): void {
	if (!sessionLock || !eventsFile || !wakePending) return;
	// Drain + clear WAKE_PENDING under the SAME lock. The atomic ack
	// contract: master must see every event the daemon appended before
	// the pending clear, with no daemon append slipping in between.
	const r = lockedEventsDrain(sessionLock, eventsFile, { clearWakePending: wakePending });
	if (r.stdout) process.stdout.write(r.stdout);
	if (r.status !== 0) {
		process.stderr.write(r.stderr || "");
		process.exit(r.status ?? 1);
	}
}

function cmdStatus(): void {
	if (!pidFile || !existsSync(pidFile)) {
		process.stdout.write(`session=${sessionName} no daemon\n`);
		process.exit(1);
	}
	const pid = readPid(pidFile);
	if (pid && pidAlive(pid)) {
		process.stdout.write(`session=${sessionName} daemon=${pid} running session_id=${sessionId}\n`);
		process.exit(0);
	}
	process.stdout.write(`session=${sessionName} pid-file present but pid=${pid ?? ""} dead\n`);
	process.exit(2);
}

function cmdFindWindow(): void {
	if (!sessionId) die(`Error: tmux session '${sessionName}' not found`, 1);
	const windowName = `[fd] daemon-${sessionKey}`;
	const r = spawnSync("tmux", ["list-windows", "-t", sessionId, "-F", "#{window_id}\t#{window_name}"], { encoding: "utf8" });
	if (r.status !== 0) process.exit(1);
	for (const line of (r.stdout ?? "").split("\n")) {
		const [wid, wname] = line.split("\t");
		if (wname === windowName && wid) {
			process.stdout.write(`${wid}\n`);
			process.exit(0);
		}
	}
	process.exit(1);
}

function cmdHealth(): void {
	if (!pidFile || !existsSync(pidFile)) {
		process.stdout.write(`session=${sessionName} no daemon\n`);
		process.exit(1);
	}
	const pid = readPid(pidFile);
	if (!pid || !pidAlive(pid)) {
		process.stdout.write(`session=${sessionName} pid=${pid ?? ""} DEAD (stale pid file)\n`);
		process.exit(2);
	}
	let lastLogLine = "", lastLogTs = "";
	if (existsSync(logFile)) {
		try {
			const text = readFileSync(logFile, "utf8");
			const lines = text.split("\n").filter(Boolean);
			lastLogLine = lines[lines.length - 1] ?? "";
			lastLogTs = lastLogLine.split(/\s+/)[0] ?? "";
		} catch { /* */ }
	}
	let wpState = "absent", wpInFlight = "";
	if (existsSync(wakePending)) {
		wpState = "in-flight";
		try {
			const obj = JSON.parse(readFileSync(wakePending, "utf8")) as { in_flight?: unknown[] };
			wpInFlight = String(Array.isArray(obj.in_flight) ? obj.in_flight.length : "?");
		} catch { wpInFlight = "?"; }
	}
	let bfState = "unlocked", bfPid = "";
	if (existsSync(busyFile)) {
		bfState = "held";
		try {
			const obj = JSON.parse(readFileSync(busyFile, "utf8")) as { pid?: number };
			bfPid = obj.pid != null ? String(obj.pid) : "";
		} catch { /* */ }
	}
	let eventsCount = 0;
	if (existsSync(eventsFile)) {
		try { eventsCount = readFileSync(eventsFile, "utf8").split("\n").filter(Boolean).length; }
		catch { /* */ }
	}
	let heartbeatAge = "(missing)";
	if (existsSync(heartbeatFile)) {
		try {
			const m = statSync(heartbeatFile).mtimeMs;
			heartbeatAge = `${Math.floor(Date.now() / 1000 - m / 1000)}s`;
		} catch { /* */ }
	}
	const lines: string[] = [];
	lines.push(`session=${sessionName} session_id=${sessionId} daemon_pid=${pid} alive=true`);
	lines.push(`state_dir=${stateDir}`);
	lines.push(`last_log_ts=${lastLogTs || "(none)"}`);
	lines.push(`last_log=${lastLogLine || "(empty)"}`);
	lines.push(`heartbeat_age=${heartbeatAge}`);
	lines.push(`wake_pending=${wpState}${wpInFlight ? ` in_flight=${wpInFlight}` : ""}`);
	lines.push(`busy_lock=${bfState}${bfPid ? ` master_pid=${bfPid}` : ""}`);
	lines.push(`events_queued=${eventsCount}`);
	process.stdout.write(lines.join("\n") + "\n");
}

function collectDescendants(rootPid: number): number[] {
	// One `ps` snapshot built into an in-memory ppid → children map,
	// then BFS through the tree. Bash version forked pgrep per BFS
	// level (O(processes_at_each_level) forks); this is one fork
	// total regardless of subscriber-tree depth.
	const r = spawnSync("ps", ["-eo", "pid=,ppid="], { encoding: "utf8" });
	if (r.status !== 0) return [];
	const children = new Map<number, number[]>();
	for (const line of (r.stdout ?? "").split("\n")) {
		const parts = line.trim().split(/\s+/);
		if (parts.length !== 2) continue;
		const pid = Number.parseInt(parts[0]!, 10);
		const ppid = Number.parseInt(parts[1]!, 10);
		if (!Number.isFinite(pid) || !Number.isFinite(ppid)) continue;
		const list = children.get(ppid);
		if (list) list.push(pid);
		else children.set(ppid, [pid]);
	}
	const out: number[] = [];
	const queue: number[] = [rootPid];
	while (queue.length > 0) {
		const pid = queue.shift()!;
		for (const child of children.get(pid) ?? []) {
			out.push(child);
			queue.push(child);
		}
	}
	return out;
}

function lockedStateCleanup(opts: { nonblock?: boolean } = {}): void {
	// Remove all per-session daemon state files. Mirrors bash
	// `locked_state_cleanup`: all four file families under SESSION_LOCK
	// so a concurrent ack/drain doesn't see half-removed state. Also
	// reaps `.draining.<pid>` snapshots of both the events JSONL and
	// the wake-events log (the previous TS version only cleaned the
	// events JSONL family, leaking wake-events log + its drain orphans).
	//
	// Heartbeat is NOT removed here — bash's locked_state_cleanup
	// leaves it for the next startup gc sweep so an external observer
	// (pi-flightdeck dashboard, manual `health`) can still see when the
	// daemon last wrote, even after a clean stop. The gc path uses a
	// different code path that does remove it.
	if (!sessionLock) return;
	lockedCleanupState(sessionLock, {
		wakePending,
		eventsFile,
		wakeEventsLog,
		nonblock: opts.nonblock === true,
	});
}

function cmdStop(): void {
	if (!pidFile || !existsSync(pidFile)) die(`no daemon for session=${sessionName}`, 1);
	const pid = readPid(pidFile);
	if (!pid) {
		process.stderr.write(`stale PID file for session=${sessionName} (content=${pidFile ? readFileSync(pidFile, "utf8").trim() : ""}); removing without kill\n`);
		try { unlinkSync(pidFile); } catch { /* */ }
		lockedStateCleanup();
		process.exit(0);
	}
	if (!existsSync(pidLock)) {
		process.stderr.write(`PID lock missing for session=${sessionName}; refusing to kill (ambiguous state)\n`);
		process.exit(1);
	}
	// flock -n test. Fail-closed: only treat status === 0 as definitively
	// stale. Any other result (including spawn-error / missing flock) is
	// ambiguous — refuse to kill rather than risk reaping the wrong pid.
	const flockTest = spawnSync("flock", ["-n", pidLock, "true"]);
	if (flockTest.error) {
		process.stderr.write(`flock unavailable for session=${sessionName}; refusing to kill\n`);
		process.exit(1);
	}
	if (flockTest.status === 0) {
		process.stderr.write(`stale PID file for session=${sessionName} (lock free); removing without kill\n`);
		try { unlinkSync(pidFile); } catch { /* */ }
		lockedStateCleanup();
		process.exit(0);
	}
	// Lock held → daemon is running. Kill it.
	if (pidAlive(pid)) {
		try { process.kill(pid, "SIGTERM"); } catch { /* */ }
		spawnSync("sleep", ["0.5"]);
		if (pidAlive(pid)) { try { process.kill(pid, "SIGKILL"); } catch { /* */ } }
	}
	try { unlinkSync(pidFile); } catch { /* */ }
	// Reap subscriber pid files scoped to this session_key. For each,
	// kill the descendant tree first (bridge children, pipeline tails)
	// before the subscriber itself — matches the bash kill_all_*
	// helpers. Without this, pipeline children get reparented to init
	// and continue appending wake events.
	try {
		const entries = readdirSync(stateDir);
		for (const e of entries) {
			if (!e.endsWith(".pid")) continue;
			const ok = (e.startsWith(`fd-subscriber-${sessionKey}-`) ||
				e.startsWith(`fd-cc-subscriber-${sessionKey}-`) ||
				e.startsWith(`fd-pi-subscriber-${sessionKey}-`) ||
				e.startsWith(`fd-cx-subscriber-${sessionKey}-`));
			if (!ok) continue;
			const subFile = `${stateDir}/${e}`;
			try {
				const sub = readFileSync(subFile, "utf8").trim();
				const subPid = Number.parseInt(sub, 10);
				if (Number.isFinite(subPid) && subPid > 0 && pidAlive(subPid)) {
					for (const d of collectDescendants(subPid)) {
						try { process.kill(d, "SIGTERM"); } catch { /* */ }
					}
					try { process.kill(subPid, "SIGTERM"); } catch { /* */ }
				}
			} catch { /* */ }
			try { unlinkSync(subFile); } catch { /* */ }
		}
	} catch { /* */ }
	lockedStateCleanup();
	process.stdout.write(`stopped daemon pid=${pid}\n`);
}

switch (action) {
	case "stop":        cmdStop(); break;
	case "status":      cmdStatus(); break;
	case "events":      drainEvents(); break;
	case "ack":         ackAndDrain(); break;
	case "find-window": cmdFindWindow(); break;
	case "health":      cmdHealth(); break;
	default:            usage();
}
