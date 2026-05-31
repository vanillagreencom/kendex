// Unit tests: isMasterBusy + clearStaleWakePending against the bash
// daemon contract (see flightdeck-daemon.bash::is_master_busy +
// clear_stale_wake_pending). Tmux pane existence is stubbed via the
// real tmux call (skipped when not in a TMUX session).
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { isMasterBusy, clearStaleWakePending } from "../../src/daemon/busy.ts";

let dir = "";
function path(name: string): string { return join(dir, name); }

beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "fd-busy-")); });
afterEach(() => { if (dir) rmSync(dir, { recursive: true, force: true }); });

describe("isMasterBusy", () => {
	test("missing file → not busy", () => {
		expect(isMasterBusy({ busyFile: path("nope.busy"), masterId: "%1", masterTurnTtl: 3600 })).toBe(false);
	});

	test("malformed JSON → not busy", () => {
		const f = path("bad.busy");
		writeFileSync(f, "not json");
		expect(isMasterBusy({ busyFile: f, masterId: "%1", masterTurnTtl: 3600 })).toBe(false);
	});

	test("pane mismatch → not busy", () => {
		const f = path("mismatch.busy");
		writeFileSync(f, JSON.stringify({ master_pane_id: "%2", pid: process.pid }));
		expect(isMasterBusy({ busyFile: f, masterId: "%1", masterTurnTtl: 3600 })).toBe(false);
	});

	test("alive pid + matching pane in tmux session → busy", () => {
		if (!process.env.TMUX_PANE) return; // skip outside tmux
		const f = path("ok.busy");
		writeFileSync(f, JSON.stringify({ master_pane_id: process.env.TMUX_PANE, pid: process.pid, started_at: new Date().toISOString() }));
		expect(isMasterBusy({ busyFile: f, masterId: process.env.TMUX_PANE, masterTurnTtl: 3600 })).toBe(true);
	});

	test("dead pid + TTL expired → not busy", () => {
		if (!process.env.TMUX_PANE) return;
		const f = path("ttl.busy");
		const oldIso = new Date(Date.now() - 7200_000).toISOString(); // 2h ago
		writeFileSync(f, JSON.stringify({ master_pane_id: process.env.TMUX_PANE, pid: 999999999, started_at: oldIso }));
		expect(isMasterBusy({ busyFile: f, masterId: process.env.TMUX_PANE, masterTurnTtl: 3600 })).toBe(false);
	});

	test("dead pid + TTL not expired → busy (fall-through)", () => {
		// pid is dead, TTL is 1h, started 10s ago → bash falls through to
		// the TTL gate; since 10s < TTL the daemon treats it as busy.
		// (Bash daemon comment: "Pid was recorded but is dead. Fall
		// through to TTL — the agent may have crashed mid-turn and we
		// want to eventually wake on someone else.")
		if (!process.env.TMUX_PANE) return;
		const f = path("recent.busy");
		writeFileSync(f, JSON.stringify({ master_pane_id: process.env.TMUX_PANE, pid: 999999999, started_at: new Date().toISOString() }));
		expect(isMasterBusy({ busyFile: f, masterId: process.env.TMUX_PANE, masterTurnTtl: 3600 })).toBe(true);
	});
});

describe("clearStaleWakePending", () => {
	test("missing wake-pending → no-op", () => {
		let logged = "";
		clearStaleWakePending({
			masterId: "%1",
			sessionLock: path("session.lock"),
			wakePending: path("missing.pending"),
			busyFile: path("nope.busy"),
			masterTurnTtl: 3600,
			wakePendingTtl: 300,
			notifiedHash: new Map(),
			lastEventKey: new Map(),
			lastBellHash: new Map(),
			log: (_t, m) => { logged = m; },
		});
		expect(logged).toBe("");
	});

	test("master busy → don't clear", () => {
		if (!process.env.TMUX_PANE) return;
		const wp = path("active.pending");
		const bf = path("active.busy");
		writeFileSync(wp, JSON.stringify({ delivered_at_epoch: 0, in_flight: [{ pane_id: "%999", hash: "abc", tag: "bell", is_bell: true }] }));
		writeFileSync(bf, JSON.stringify({ master_pane_id: process.env.TMUX_PANE, pid: process.pid, started_at: new Date().toISOString() }));
		const notified = new Map([["%999", "abc"]]);
		clearStaleWakePending({
			masterId: process.env.TMUX_PANE,
			sessionLock: path("session.lock"),
			wakePending: wp,
			busyFile: bf,
			masterTurnTtl: 3600,
			wakePendingTtl: 0,
			notifiedHash: notified,
			lastEventKey: new Map(),
			lastBellHash: new Map(),
			log: () => {},
		});
		expect(existsSync(wp)).toBe(true);
		expect(notified.has("%999")).toBe(true);
	});

	test("master gone + TTL expired → revert + remove", () => {
		const wp = path("stale.pending");
		writeFileSync(wp, JSON.stringify({
			delivered_at_epoch: Math.floor(Date.now() / 1000) - 600,
			in_flight: [
				{ pane_id: "%101", hash: "h1", tag: "bell", is_bell: true },
				{ pane_id: "%102", hash: "h2", tag: "merge-now", is_bell: false },
			],
		}));
		const notified = new Map([["%101", "h1"], ["%102", "h2"]]);
		const eventKey = new Map([["%101|h1|bell", true as const], ["%102|h2|merge-now", true as const]]);
		const bellHash = new Map([["%101", "h1"]]);
		const logs: Array<[string, string]> = [];
		clearStaleWakePending({
			masterId: "%999-no-such",
			sessionLock: path("session.lock"),
			wakePending: wp,
			busyFile: path("missing.busy"),
			masterTurnTtl: 3600,
			wakePendingTtl: 300,
			notifiedHash: notified,
			lastEventKey: eventKey,
			lastBellHash: bellHash,
			log: (t, m) => logs.push([t, m]),
		});
		expect(existsSync(wp)).toBe(false);
		expect(notified.has("%101")).toBe(false);
		expect(notified.has("%102")).toBe(false);
		expect(eventKey.has("%101|h1|bell")).toBe(false);
		expect(eventKey.has("%102|h2|merge-now")).toBe(false);
		expect(bellHash.has("%101")).toBe(false);
		expect(logs.some(([t]) => t === "wake-pending-revert")).toBe(true);
		expect(logs.some(([t]) => t === "wake-pending-stale")).toBe(true);
	});

	test("master gone + TTL expired → removes event-identity dedup key", () => {
		const wp = path("identity-stale.pending");
		const dedupKey = "%287|pre-pr-ready-for-review|event:turn:round-4";
		writeFileSync(wp, JSON.stringify({
			delivered_at_epoch: Math.floor(Date.now() / 1000) - 600,
			in_flight: [{ pane_id: "%287", hash: "07be2c0e1920", tag: "pre-pr-ready-for-review", is_bell: false, dedup_key: dedupKey }],
		}));
		const notified = new Map([["%287", "07be2c0e1920"]]);
		const eventKey = new Map([[dedupKey, true as const], ["%287|07be2c0e1920|pre-pr-ready-for-review", true as const]]);
		clearStaleWakePending({
			masterId: "%999-no-such",
			sessionLock: path("session.lock"),
			wakePending: wp,
			busyFile: path("missing.busy"),
			masterTurnTtl: 3600,
			wakePendingTtl: 300,
			notifiedHash: notified,
			lastEventKey: eventKey,
			lastBellHash: new Map(),
			log: () => {},
		});
		expect(existsSync(wp)).toBe(false);
		expect(notified.has("%287")).toBe(false);
		expect(eventKey.has(dedupKey)).toBe(false);
		expect(eventKey.has("%287|07be2c0e1920|pre-pr-ready-for-review")).toBe(true);
	});

	test("master gone but TTL not expired → no-op", () => {
		const wp = path("recent.pending");
		writeFileSync(wp, JSON.stringify({
			delivered_at_epoch: Math.floor(Date.now() / 1000) - 5,
			in_flight: [{ pane_id: "%101", hash: "h1", tag: "bell", is_bell: true }],
		}));
		const notified = new Map([["%101", "h1"]]);
		clearStaleWakePending({
			masterId: "%999-no-such",
			sessionLock: path("session.lock"),
			wakePending: wp,
			busyFile: path("missing.busy"),
			masterTurnTtl: 3600,
			wakePendingTtl: 300,
			notifiedHash: notified,
			lastEventKey: new Map(),
			lastBellHash: new Map(),
			log: () => {},
		});
		expect(existsSync(wp)).toBe(true);
		expect(notified.has("%101")).toBe(true);
		// Quiet linter
		void spawnSync;
	});
});
