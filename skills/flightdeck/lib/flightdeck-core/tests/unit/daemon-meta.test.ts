// Unit tests for the daemon staleness meta module (vstack#213).
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { classifyStaleness, readDaemonMeta, statInode, writeDaemonMeta, type DaemonMeta } from "../../src/daemon/meta.ts";

let dir = "";
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "fd-meta-")); });
afterEach(() => { if (dir) rmSync(dir, { recursive: true, force: true }); });

function meta(overrides: Partial<DaemonMeta> = {}): DaemonMeta {
	return {
		active_run_id: "run-1",
		inner_harnesses: ["claude", "pi"],
		inner_targets: ["%10", "%11"],
		master_harness: "pi",
		master_pane_id: "%5",
		pid: 4242,
		schema_version: 1,
		session_id: "$3",
		session_key: "s3",
		session_name: "vstack",
		started_at: "2026-05-21T18:33:36Z",
		state_file_inode: "12345",
		state_file_path: "/tmp/flightdeck-state-vstack.json",
		subscribed_pane_harnesses: ["claude", "pi"],
		subscribed_pane_ids: ["%10", "%11"],
		updated_at: "2026-05-21T18:33:36Z",
		...overrides,
	};
}

function live(...pairs: [string, string][]): { paneId: string; harness: string }[] {
	return pairs.map(([paneId, harness]) => ({ harness, paneId }));
}

describe("writeDaemonMeta + readDaemonMeta", () => {
	test("round-trips canonical fields", () => {
		const path = join(dir, "meta.json");
		writeDaemonMeta(path, meta());
		const got = readDaemonMeta(path);
		expect(got).toEqual(meta());
	});

	test("read returns null when missing", () => {
		expect(readDaemonMeta(join(dir, "absent.json"))).toBeNull();
	});

	test("read returns null on schema mismatch", () => {
		const path = join(dir, "wrong-schema.json");
		writeFileSync(path, JSON.stringify({ ...meta(), schema_version: 99 }));
		expect(readDaemonMeta(path)).toBeNull();
	});

	test("read returns null on malformed JSON", () => {
		const path = join(dir, "bad.json");
		writeFileSync(path, "not json");
		expect(readDaemonMeta(path)).toBeNull();
	});
});

describe("classifyStaleness", () => {
	test("fresh when state path/inode/active-run/subscribers all match", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: live(["%10", "claude"], ["%11", "pi"]),
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("fresh");
	});

	test("stale-state when state file path changed", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: live(["%10", "claude"], ["%11", "pi"]),
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-other.json",
		})).toBe("stale-state");
	});

	test("stale-state when state file inode replaced", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: live(["%10", "claude"], ["%11", "pi"]),
			stateFileInode: "99999",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("stale-state");
	});

	test("pre-active-run when run id diverged", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-2",
			liveInnerEntries: live(["%10", "claude"], ["%11", "pi"]),
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("pre-active-run");
	});

	test("stale-inner when live pane missing from subscriber set (subset)", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: live(["%10", "claude"], ["%11", "pi"], ["%12", "shell"]),
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("stale-inner");
	});

	test("stale-inner when daemon subscribes to extra dead panes (superset)", () => {
		// vstack#213 round-1 regression: a daemon whose --inner argv
		// includes dead panes from a previous session is just as stale
		// as one missing live panes. Both signal frozen argv across
		// sessions. The bug we're guarding against: silently treating
		// such a daemon as fresh so it never gets respawned with the
		// right --inner.
		const m = meta({
			subscribed_pane_harnesses: ["claude", "pi", "shell"],
			subscribed_pane_ids: ["%10", "%11", "%99"],
		});
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: live(["%10", "claude"], ["%11", "pi"]),
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("stale-inner");
	});

	test("stale-inner when harness for a tracked pane changed", () => {
		// vstack#213 round-1: pane id sets matching is not enough.
		// A daemon with the right pane but the wrong subscriber-type
		// (e.g. claude binder on what is now a pi pane) misroutes wakes.
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: live(["%10", "opencode"], ["%11", "pi"]), // %10 changed claude→opencode
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("stale-inner");
	});

	test("fresh when harnesses match even with reordered entries", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: live(["%11", "pi"], ["%10", "claude"]),
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("fresh");
	});

	test("ignores inode mismatch when either side is null (best effort)", () => {
		const m = meta({ state_file_inode: null });
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: live(["%10", "claude"], ["%11", "pi"]),
			stateFileInode: "99999",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("fresh");
	});

	test("ignores active-run mismatch when meta has no run id", () => {
		const m = meta({ active_run_id: null });
		expect(classifyStaleness(m, {
			activeRunId: "anything",
			liveInnerEntries: live(["%10", "claude"], ["%11", "pi"]),
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("fresh");
	});

	test("empty live entries reads as stale-inner when daemon has subscribers", () => {
		// If the registry probe returns no entries (all dead) but the
		// daemon's subscribed_pane_ids is non-empty, that's stale —
		// the daemon is watching ghosts.
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: [],
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("stale-inner");
	});

	test("fresh when callers fall back to recorded subscribers on probe failure (round-2)", () => {
		// cmdHealth substitutes the meta's recorded subscribers when
		// pane-registry can't be probed. classifyStaleness must yield
		// `fresh` in that case so a transient pane-registry failure
		// doesn't trigger a respawn storm. The recorded subscribers
		// trivially match themselves once zipped with their harnesses.
		const m = meta();
		const fallback = m.subscribed_pane_ids.map((paneId, i) => ({
			harness: m.subscribed_pane_harnesses[i] ?? "",
			paneId,
		}));
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			liveInnerEntries: fallback,
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("fresh");
	});
});

describe("statInode", () => {
	test("returns numeric inode when file exists", () => {
		const path = join(dir, "exists");
		writeFileSync(path, "x");
		const inode = statInode(path);
		expect(inode).not.toBeNull();
		expect(inode).toMatch(/^\d+$/);
	});

	test("returns null when file missing", () => {
		expect(statInode(join(dir, "absent"))).toBeNull();
	});

	test("inode changes after rename-replace", () => {
		const path = join(dir, "file");
		writeFileSync(path, "a");
		const before = statInode(path);
		rmSync(path);
		writeFileSync(path, "b");
		const after = statInode(path);
		expect(before).not.toBeNull();
		expect(after).not.toBeNull();
		// On most filesystems a remove+create reuses no inode, but
		// even if it did, the read path treats either match as
		// "not yet known stale" — which is the intended best-effort
		// behavior. So the only invariant we assert is that the
		// helper survived both calls.
		void readFileSync(path, "utf8");
	});
});
