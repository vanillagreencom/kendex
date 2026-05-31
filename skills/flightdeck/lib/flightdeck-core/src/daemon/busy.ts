// Port of flightdeck-daemon.bash::is_master_busy + clear_stale_wake_pending.
//
// Master-busy lock semantics (bash daemon header):
//   - Master writes BUSY_FILE = {pid, master_pane_id, started_at} at
//     turn-start via temp+mv.
//   - Daemon reads it before delivering a wake. is_master_busy returns
//     true iff:
//       - file exists and parses as JSON
//       - .master_pane_id == our master_id
//       - the master pane still exists in tmux
//       - .pid is alive (when present); on a dead pid, fall through to
//         the TTL gate so a crashed master eventually unblocks wakes
//       - .started_at is within FD_MASTER_TURN_TTL (default 1h)
//   - NEVER removes BUSY_FILE in the hot path — master may be mid-write
//     of a fresh lock. Cleanup is GC's job.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, unlinkSync } from "node:fs";
import { lockedAtomicWrite } from "../state/locking.ts";
import { withInprocFlock } from "../shared/inproc-flock.ts";

function tmuxPaneExists(paneId: string): boolean {
	const r = spawnSync("tmux", ["list-panes", "-t", paneId], { stdio: ["ignore", "ignore", "ignore"] });
	return r.status === 0;
}

function pidAlive(pid: number): boolean {
	if (!Number.isFinite(pid) || pid <= 0) return false;
	try { process.kill(pid, 0); return true; }
	catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
}

function parseDateToEpoch(iso: string): number | null {
	// Match bash `date -d <ISO>` semantics. JS Date.parse handles ISO 8601
	// natively. Returns null for unparseable input so the TTL gate falls
	// through (mirrors bash's "skip TTL rather than mis-parse" guard).
	const ms = Date.parse(iso);
	if (!Number.isFinite(ms)) return null;
	return Math.floor(ms / 1000);
}

interface BusyOpts {
	busyFile: string;
	masterId: string;
	masterTurnTtl: number;
}

export function isMasterBusy(opts: BusyOpts): boolean {
	const { busyFile, masterId, masterTurnTtl } = opts;
	if (!existsSync(busyFile)) return false;
	let parsed: { pid?: unknown; master_pane_id?: unknown; started_at?: unknown };
	try {
		parsed = JSON.parse(readFileSync(busyFile, "utf8"));
	} catch { return false; }
	const lockPane = typeof parsed.master_pane_id === "string" ? parsed.master_pane_id : "";
	const lockStarted = typeof parsed.started_at === "string" ? parsed.started_at : "";
	const lockPidRaw = parsed.pid;
	if (!lockPane) return false;
	if (lockPane !== masterId) return false;
	if (!tmuxPaneExists(lockPane)) return false;

	// Owner PID check. Bash rejects pid=0 / "null" explicitly.
	const lockPidStr = typeof lockPidRaw === "number" ? String(lockPidRaw)
		: typeof lockPidRaw === "string" ? lockPidRaw : "";
	if (lockPidStr && lockPidStr !== "null" && lockPidStr !== "0") {
		if (/^[1-9][0-9]*$/.test(lockPidStr) && pidAlive(Number.parseInt(lockPidStr, 10))) {
			return true;
		}
		// Dead pid → fall through to TTL.
	}

	if (lockStarted) {
		const startedEpoch = parseDateToEpoch(lockStarted);
		if (startedEpoch !== null) {
			const age = Math.floor(Date.now() / 1000) - startedEpoch;
			if (age > masterTurnTtl) return false;
		}
	}
	return true;
}

// Match bash's nameref-arg signature shape. The three Maps are mutated in
// place to revert state for entries that were "in flight" when the
// master crashed: NOTIFIED_HASH, LAST_EVENT_KEY, LAST_BELL_HASH.
//
// SESSION_LOCK is held by lockedAtomicWrite via the bash child for the
// full read+revert+rm window so a concurrent daemon append doesn't see
// half-removed pending state.
export interface ClearStaleOpts {
	masterId: string;
	sessionLock: string;
	wakePending: string;
	busyFile: string;
	masterTurnTtl: number;
	wakePendingTtl: number;
	notifiedHash: Map<string, string>;
	lastEventKey: Map<string, true>;
	lastBellHash: Map<string, string>;
	log: (tag: string, msg: string) => void;
}

export function clearStaleWakePending(opts: ClearStaleOpts): void {
	const { sessionLock, wakePending, busyFile, masterId, masterTurnTtl, wakePendingTtl,
		notifiedHash, lastEventKey, lastBellHash, log } = opts;

	// Fast-path: no wake-pending → nothing to do, no lock needed.
	// (perf #7) Race is harmless: a wake-pending appearing between this
	// check and the next tick is processed normally.
	if (!existsSync(wakePending)) return;

	// CRITICAL: hold SESSION_LOCK across the entire read + busy-check +
	// revert + rm window. Splitting risks a wake delivered into a
	// master turn that started between our read and our rm. Native
	// in-process flock(2) keeps this synchronous + zero subprocess.
	let shouldClear = false;
	let revertEntries: Array<{ p: string; h: string; t: string; isBell: string; dedupKey: string }> = [];
	let age = 0;

	withInprocFlock(sessionLock, () => {
		if (!existsSync(wakePending)) return;
		let payload: { delivered_at_epoch?: number; in_flight?: Array<{ pane_id?: string; hash?: string; tag?: string; is_bell?: boolean; dedup_key?: string }> };
		try { payload = JSON.parse(readFileSync(wakePending, "utf8")); }
		catch { return; }
		const delivered = typeof payload.delivered_at_epoch === "number" ? payload.delivered_at_epoch : 0;
		age = Math.max(0, Math.floor(Date.now() / 1000) - delivered);
		if (isMasterBusy({ busyFile, masterId, masterTurnTtl })) return;
		if (age <= wakePendingTtl) return;

		for (const row of payload.in_flight ?? []) {
			const p = row.pane_id ?? "";
			const h = row.hash ?? "";
			const t = row.tag ?? "";
			const isBell = row.is_bell === true ? "true" : "false";
			const dedupKey = typeof row.dedup_key === "string" ? row.dedup_key : "";
			if (!p) continue;
			revertEntries.push({ p, h, t, isBell, dedupKey });
		}
		try { unlinkSync(wakePending); shouldClear = true; }
		catch { /* race: gone already */ }
	});

	if (!shouldClear) return;

	for (const { p, h, t, isBell, dedupKey } of revertEntries) {
		if (notifiedHash.get(p) === h) notifiedHash.delete(p);
		const ek = dedupKey || `${p}|${h}|${t}`;
		if (lastEventKey.has(ek)) lastEventKey.delete(ek);
		if (isBell === "true" && lastBellHash.get(p) === h) lastBellHash.delete(p);
		log("wake-pending-revert", `reverted state for ${p} hash=${h} tag=${t} bell=${isBell}`);
	}
	log("wake-pending-stale", `age=${age}s > TTL=${wakePendingTtl}s, no busy lock; clearing`);
	void lockedAtomicWrite; void spawnSync;
}
