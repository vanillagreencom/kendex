// Port of flightdeck-daemon.bash::{wake_master, resolve_pi_master_pid,
// clear_bell_for_window, locked_rm_wake_pending}.
//
// Wake delivery contract (bash daemon comment):
//   - All WAKE_PENDING mutations under SESSION_LOCK.
//   - Pi master: route through pi-bridge send --pid <master_pid> first
//     so /skill:flightdeck expands inline in pi-session-bridge. If the
//     bridge is unavailable, fall back to tmux send-keys -l + Enter.
//   - Other harnesses: tmux load-buffer + paste-buffer + send-keys
//     Enter to deliver the wake.
//   - On any delivery failure, re-take SESSION_LOCK and remove
//     WAKE_PENDING so the next tick can retry.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { piBridgeSpawnSync, piResolveBridgeBin } from "../paths/pi.ts";
import { withInprocFlock } from "../shared/inproc-flock.ts";
import { emitWakeDeliveryFailure, type DaemonActivityContext } from "./activity.ts";
import { wakePayloadForHarness } from "./wake-payload.ts";

type SpawnSyncLike = (
	command: string,
	args: string[],
	options?: { encoding?: BufferEncoding | "buffer"; timeout?: number; input?: string; killSignal?: NodeJS.Signals | number },
) => { status: number | null; stdout?: unknown; stderr?: unknown; signal?: NodeJS.Signals | null; output?: unknown[] | null };

// Walk pgrep -P recursively. Used to map a pane's shell pid to the
// pi process descendants for pi-bridge candidate matching (bash
// resolve_pi_master_pid).
function collectDescendants(rootPid: number): number[] {
	// Re-use the one-ps-snapshot pattern from flightdeck-daemon.ts.
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

interface BridgeEntry { pid?: number; cwd?: string; startedAt?: string; started_at?: string }

// Find the pi-bridge pid that corresponds to the master pane. Bash's
// resolve_pi_master_pid:
//   1. Get bridge list from `pi-bridge list --json`.
//   2. Prefer matching the master pane's process tree (shell pid +
//      descendants); collapse to one candidate when present.
//   3. Fallback: cwd + tty intersection against bridge entries and
//      live `pi` processes; fail-closed if more than one candidate
//      remains.
export function resolvePiMasterPid(masterId: string): number | null {
	const bin = piResolveBridgeBin();
	if (!bin) return null;
	const listR = piBridgeSpawnSync(bin, ["list", "--json"]);
	if (listR.status !== 0 || !listR.stdout || listR.stdout.trim() === "null") return null;
	let entries: BridgeEntry[];
	try { entries = JSON.parse(listR.stdout) as BridgeEntry[]; }
	catch { return null; }
	if (!Array.isArray(entries)) return null;

	// Master pane's shell pid → bridge pid via process-tree match.
	const shellPidR = spawnSync("tmux", ["display-message", "-t", masterId, "-p", "#{pane_pid}"], { encoding: "utf8" });
	const masterShellPid = Number.parseInt((shellPidR.stdout ?? "").trim(), 10);
	if (Number.isFinite(masterShellPid) && masterShellPid > 0) {
		const tree = new Set<number>([masterShellPid, ...collectDescendants(masterShellPid)]);
		const byTree = entries
			.filter((e) => typeof e.pid === "number" && tree.has(e.pid))
			.sort((a, b) => {
				// Match bash's sort_by(.startedAt // .started_at // 0) ordering.
				const aT = a.startedAt ?? a.started_at ?? "0";
				const bT = b.startedAt ?? b.started_at ?? "0";
				return aT.localeCompare(bT);
			});
		if (byTree.length > 0) {
			const last = byTree[byTree.length - 1]!;
			if (typeof last.pid === "number") return last.pid;
		}
	}

	// Fallback: cwd + tty intersection. Less precise; fail-closed when
	// ambiguous.
	const cwdR = spawnSync("tmux", ["display-message", "-t", masterId, "-p", "#{pane_current_path}"], { encoding: "utf8" });
	const masterCwd = (cwdR.stdout ?? "").trim();
	if (!masterCwd) return null;
	const ttyR = spawnSync("tmux", ["display-message", "-t", masterId, "-p", "#{pane_tty}"], { encoding: "utf8" });
	const masterTty = (ttyR.stdout ?? "").trim();

	const bridgeCwdEntries = entries.filter((e) => (e.cwd ?? "") === masterCwd);
	if (bridgeCwdEntries.length === 0) return null;

	// Find live `pi` processes whose /proc cwd matches the master.
	const pgrepR = spawnSync("pgrep", ["-a", "-f", "(^|/)pi( |$)"], { encoding: "utf8" });
	if (pgrepR.status !== 0) return null;
	const piCwdPids = new Set<number>();
	for (const line of (pgrepR.stdout ?? "").split("\n")) {
		const m = /^(\d+)\s/.exec(line.trim());
		if (!m) continue;
		const pid = Number.parseInt(m[1]!, 10);
		const cwdLink = spawnSync("readlink", ["-f", `/proc/${pid}/cwd`], { encoding: "utf8" });
		if ((cwdLink.stdout ?? "").trim() === masterCwd) piCwdPids.add(pid);
	}
	if (piCwdPids.size === 0) return null;

	const candidates: number[] = [];
	const ttyCandidates: number[] = [];
	for (const e of bridgeCwdEntries) {
		if (typeof e.pid !== "number") continue;
		if (!piCwdPids.has(e.pid)) continue;
		try { process.kill(e.pid, 0); } catch (err) {
			if ((err as NodeJS.ErrnoException).code !== "EPERM") continue;
		}
		candidates.push(e.pid);
		if (masterTty) {
			for (const fd of ["0", "1", "2"]) {
				const link = spawnSync("readlink", ["-f", `/proc/${e.pid}/fd/${fd}`], { encoding: "utf8" });
				if ((link.stdout ?? "").trim() === masterTty) {
					ttyCandidates.push(e.pid);
					break;
				}
			}
		}
	}
	if (ttyCandidates.length === 1) return ttyCandidates[0]!;
	if (candidates.length === 1) return candidates[0]!;
	return null;
}

// Clear the tmux window bell flag by selecting the window and
// switching back. Matches bash clear_bell_for_window.
export function clearBellForWindow(sessionId: string, windowId: string): void {
	if (!windowId) return;
	const orig = spawnSync("tmux", ["display-message", "-p", "-t", sessionId, "#{window_id}"], { encoding: "utf8" });
	const origWid = (orig.stdout ?? "").trim();
	if (!origWid) return;
	spawnSync("tmux", ["select-window", "-t", windowId, ";", "select-window", "-t", origWid], { stdio: "ignore" });
}

// Locked rm of WAKE_PENDING. Used by wake_master delivery-failure
// rollback path and by the master-busy-revert flow.
export function lockedRmWakePending(sessionLock: string, wakePending: string): void {
	spawnSync("flock", ["-x", sessionLock, "rm", "-f", wakePending], { stdio: "ignore" });
}

interface WakeMasterOpts {
	masterId: string;
	masterHarness: string;
	sessionKey: string;
	sessionLock: string;
	wakePending: string;
	busyFile: string;
	masterTurnTtl: number;
	daemonPid: number;
	combined: string;
	inFlightJson: string; // already a JSON array string
	log: (tag: string, msg: string) => void;
	isMasterBusy: () => boolean;
	paneTargetFor: (paneId: string) => string;
	// Round-4 nice: caller may supply a cached pi master pid resolver
	// so resolvePiMasterPid (multiple subprocesses + bridge list) only
	// runs once per daemon lifetime.
	resolvePiMasterPidOverride?: () => number | null;
	// Test seam for wake delivery subprocesses.
	spawnSyncOverride?: SpawnSyncLike;
	activity?: DaemonActivityContext;
}

// Returns true on successful wake delivery, false on skip or failure.
//
// CRITICAL: the entire (no-in-flight, not-busy, write-pending) decision
// runs under SESSION_LOCK. Splitting the check from the write — even by
// microseconds — lets master take SESSION_LOCK between daemon's busy
// probe and daemon's write, causing a wake mid-turn. This violated the
// atomic master-busy + ack contract before round-4 fix.
//
// Side effects:
//   - On success: WAKE_PENDING populated atomically + wake delivered.
//   - On failure during delivery (post-lock): WAKE_PENDING removed so
//     the next tick can retry.
export function wakeMaster(opts: WakeMasterOpts): boolean {
	const { masterId, masterHarness, sessionKey, sessionLock, wakePending, busyFile,
		daemonPid, combined, inFlightJson, log, isMasterBusy, paneTargetFor } = opts;
	const run: SpawnSyncLike = opts.spawnSyncOverride ?? ((command, args, options) => spawnSync(command, args, options));
	void busyFile;

	// Resolve master pane target outside the lock — paneTargetFor reads
	// the once-per-tick PaneCache so this is a Map lookup, no I/O.
	const target = paneTargetFor(masterId);
	if (!target) {
		log("master-gone", `master pane ${masterId} no longer resolvable`);
		emitWakeDeliveryFailure(opts.activity, { reason: "master-pane-unresolved", targetMasterPid: masterId });
		return false;
	}

	// Under SESSION_LOCK: check no in-flight, check master not busy,
	// write WAKE_PENDING atomically. All three operations happen in one
	// flock-held critical section so master can't slip in between.
	let outcome: "in-flight" | "busy" | "written" = "in-flight";
	withInprocFlock(sessionLock, () => {
		if (existsSync(wakePending)) {
			outcome = "in-flight";
			return;
		}
		if (isMasterBusy()) {
			outcome = "busy";
			return;
		}
		// Test seam: FD_WAKE_TEST_DELAY_MS injects a synchronous sleep
		// between the busy check and the wake-pending write. The race
		// regression test exercises this so a concurrent worker can
		// take the SESSION_LOCK during the gap and observe whether the
		// fix holds. Production path reads the env once per call, zero
		// overhead when unset.
		const delayMs = Number.parseInt(process.env.FD_WAKE_TEST_DELAY_MS ?? "0", 10);
		if (Number.isFinite(delayMs) && delayMs > 0) {
			const until = Date.now() + delayMs;
			while (Date.now() < until) { /* busy-wait: must be sync inside the lock callback */ }
		}
		const nowIso = new Date().toISOString();
		const nowEpoch = Math.floor(Date.now() / 1000);
		const tmpPending = `${wakePending}.tmp.${process.pid}`;
		const wakePendingObj = JSON.stringify({
			delivered_at: nowIso,
			delivered_at_epoch: nowEpoch,
			master_pane_id: masterId,
			daemon_pid: daemonPid,
			in_flight: JSON.parse(inFlightJson || "[]"),
		});
		try {
			writeFileSync(tmpPending, wakePendingObj);
			renameSync(tmpPending, wakePending);
			outcome = "written";
		} catch (e) {
			log("wake-fail", `wake-pending write failed: ${(e as Error).message ?? String(e)}`);
			emitWakeDeliveryFailure(opts.activity, { reason: "wake-pending-write-failed", targetMasterPid: masterId });
			outcome = "in-flight";
		}
	});
	if (outcome === "in-flight") {
		if (existsSync(wakePending)) log("skip-wake", "wake-pending already in flight");
		return false;
	}
	if (outcome === "busy") {
		log("skip-wake", `master busy (${combined})`);
		return false;
	}
	void readFileSync;

	// 2. After releasing the lock, deliver the wake.
	const payload = wakePayloadForHarness(masterHarness);
	if (masterHarness === "pi") {
		const bin = piResolveBridgeBin();
		const masterPid = opts.resolvePiMasterPidOverride
			? opts.resolvePiMasterPidOverride()
			: resolvePiMasterPid(masterId);
		if (bin && masterPid) {
			const r = run(bin, ["send", "--pid", String(masterPid), payload], { encoding: "utf8", killSignal: "SIGKILL", timeout: 10_000 });
			if (r.status === 0) {
				log("wake", `master=${masterId} harness=pi via=pi-bridge pid=${masterPid} reasons=${combined}`);
				return true;
			}
			log("wake-fail", `pi-bridge send failed pid=${masterPid}; falling back to tmux send-keys`);
		} else {
			log("wake-fail", `pi master bridge unresolved (bin=${bin ?? "missing"} pid=${masterPid ?? "unknown"}); falling back to tmux send-keys`);
		}

		const literal = run("tmux", ["send-keys", "-t", target, "-l", payload], { encoding: "utf8" });
		if (literal.status !== 0) {
			log("wake-fail", "send-keys -l failed");
			emitWakeDeliveryFailure(opts.activity, { reason: "tmux-send-keys-literal-failed", targetMasterPid: masterPid ?? masterId });
			lockedRmWakePending(sessionLock, wakePending);
			return false;
		}
		const enter = run("tmux", ["send-keys", "-t", target, "Enter"], { encoding: "utf8" });
		if (enter.status !== 0) {
			log("wake-fail", "send-keys Enter failed");
			emitWakeDeliveryFailure(opts.activity, { reason: "tmux-send-keys-enter-failed", targetMasterPid: masterPid ?? masterId });
			lockedRmWakePending(sessionLock, wakePending);
			return false;
		}
		log("wake", `master=${masterId} harness=pi via=tmux-send-keys reasons=${combined}`);
		return true;
	}

	const bufferName = `fd-wake-${sessionKey}`;
	const lb = run("tmux", ["load-buffer", "-b", bufferName, "-"], { input: payload, encoding: "utf8" });
	if (lb.status !== 0) {
		log("wake-fail", "load-buffer failed");
		emitWakeDeliveryFailure(opts.activity, { reason: "tmux-load-buffer-failed", targetMasterPid: masterId });
		lockedRmWakePending(sessionLock, wakePending);
		return false;
	}
	const pb = run("tmux", ["paste-buffer", "-p", "-t", target, "-b", bufferName, "-d"], { encoding: "utf8" });
	if (pb.status !== 0) {
		log("wake-fail", "paste-buffer failed");
		emitWakeDeliveryFailure(opts.activity, { reason: "tmux-paste-buffer-failed", targetMasterPid: masterId });
		lockedRmWakePending(sessionLock, wakePending);
		return false;
	}
	const sk = run("tmux", ["send-keys", "-t", target, "Enter"], { encoding: "utf8" });
	if (sk.status !== 0) {
		log("wake-fail", "send-keys Enter failed");
		emitWakeDeliveryFailure(opts.activity, { reason: "tmux-send-keys-enter-failed", targetMasterPid: masterId });
		lockedRmWakePending(sessionLock, wakePending);
		return false;
	}
	log("wake", `master=${masterId} harness=${masterHarness || "?"} via=tmux reasons=${combined}`);
	return true;
}
