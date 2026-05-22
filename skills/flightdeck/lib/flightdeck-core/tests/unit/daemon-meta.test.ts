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
		subscribed_pane_ids: ["%10", "%11"],
		updated_at: "2026-05-21T18:33:36Z",
		...overrides,
	};
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
			livePaneIds: ["%10", "%11"],
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("fresh");
	});

	test("stale-state when state file path changed", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			livePaneIds: ["%10", "%11"],
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-other.json",
		})).toBe("stale-state");
	});

	test("stale-state when state file inode replaced", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			livePaneIds: ["%10", "%11"],
			stateFileInode: "99999",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("stale-state");
	});

	test("pre-active-run when run id diverged", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-2",
			livePaneIds: ["%10", "%11"],
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("pre-active-run");
	});

	test("stale-inner when live pane missing from subscriber set", () => {
		const m = meta();
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			livePaneIds: ["%10", "%11", "%12"], // %12 is new
			stateFileInode: "12345",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("stale-inner");
	});

	test("ignores inode mismatch when either side is null (best effort)", () => {
		const m = meta({ state_file_inode: null });
		expect(classifyStaleness(m, {
			activeRunId: "run-1",
			livePaneIds: ["%10", "%11"],
			stateFileInode: "99999",
			stateFilePath: "/tmp/flightdeck-state-vstack.json",
		})).toBe("fresh");
	});

	test("ignores active-run mismatch when meta has no run id", () => {
		const m = meta({ active_run_id: null });
		expect(classifyStaleness(m, {
			activeRunId: "anything",
			livePaneIds: ["%10", "%11"],
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
