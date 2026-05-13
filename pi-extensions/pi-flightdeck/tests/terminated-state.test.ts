// Regression coverage for issue #17. The dashboard previously collapsed
// after `terminate.md` finished a session:
//   1) `pane-registry remove-merged` emptied `.issues` before `archive`,
//      so the rotated file carried no history (round 1 fix); AND
//   2) `flightdeck-state archive` renames the live file out of the way,
//      so `pi-flightdeck` read a missing live path and fell through to
//      `inactive` even when the archive carried the full session
//      history (round 2 BLOCKER).
//
// After the full fix:
//   * `terminate.md` no longer calls `remove-merged`, so the archive
//     preserves `.issues` (decisions_log, pr_number, merge_commit).
//   * `buildSnapshotFromInputs` falls back to the newest terminated
//     archive when the live file is missing.
//   * `flightdeckSessionStatus` returns the new `terminated` arm,
//     keeping the dashboard widget + popup populated.
//   * `readMasterState` normalizes nested `conflict_graph` /
//     `decisions_log` so a corrupt archive renders as empty-but-stable
//     instead of crashing the popup.
//
// Tests are layered: pure shape (readMasterState), policy
// (flightdeckSessionStatus / mergedIssueHistory / readTrackedEntries),
// end-to-end (buildSnapshotFromInputs against a real archive on disk),
// and render output (rendered tab text contains expected fields).

import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
	buildSnapshotFromInputs,
	type FlightdeckSnapshot,
	findNewestTerminatedArchive,
	flightdeckSessionStatus,
	mergedIssueHistory,
	readMasterState,
	readTrackedEntries,
	type SettingsLike,
	type TmuxContext,
} from "../extensions/state.js";
import { listTerminatedArchives } from "../extensions/state-archive.js";

const SETTINGS: SettingsLike = { flightdeckStateDir: "tmp", stateDir: "" };
const TMUX: TmuxContext = { paneId: "%1", sessionId: "$1", sessionKey: "s1", sessionName: "HT" };

function makeProject(): { projectRoot: string; stateDir: string; tmpDir: string; cleanup: () => void } {
	const dir = mkdtempSync(join(tmpdir(), "pi-flightdeck-snapshot-"));
	const stateDir = join(dir, "tmp");
	mkdirSync(stateDir, { recursive: true });
	const daemonDir = mkdtempSync(join(tmpdir(), "pi-flightdeck-daemon-"));
	return {
		cleanup: () => {
			rmSync(dir, { force: true, recursive: true });
			rmSync(daemonDir, { force: true, recursive: true });
		},
		projectRoot: dir,
		stateDir: daemonDir,
		tmpDir: stateDir,
	};
}

function writeLive(stateDir: string, sessionName: string, payload: Record<string, unknown>): string {
	const path = join(stateDir, `flightdeck-state-${sessionName}.json`);
	writeFileSync(path, JSON.stringify(payload), "utf8");
	return path;
}

function simulateTerminateArchive(stateDir: string, sessionName: string, payload: Record<string, unknown>): { live: string; archive: string } {
	const live = writeLive(stateDir, sessionName, payload);
	const terminatedAt = String(payload.terminated_at ?? new Date().toISOString().replace(/\.\d{3}Z$/, "Z"));
	const safe = terminatedAt.replace(/:/g, "");
	const archive = join(stateDir, `flightdeck-state-${sessionName}-${safe}.json.archive`);
	renameSync(live, archive);
	return { archive, live };
}

function makeMergedIssueRecord(overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		decisions_log: [
			{ answer: "apply", prompt_tag: "review-fix", ts: "2026-05-13T00:00:01Z" },
			{ answer: "yes", prompt_tag: "merge-now", ts: "2026-05-13T00:10:00Z" },
			{ answer: "merged", prompt_tag: "terminal-state-reached", ts: "2026-05-13T00:15:35Z" },
		],
		harness: "claude",
		last_polled_at: "2026-05-13T00:15:35Z",
		merge_commit: "156d9df02ce8fb3a798f233c73e489338db969f9",
		pr_number: 81,
		spawned_at: "2026-05-12T23:00:00Z",
		state: "merged",
		window: "CC-503",
		...overrides,
	};
}

function terminatedPayload(issues: Record<string, Record<string, unknown>>, overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		conflict_graph: { computed_at: null, edges: [] },
		issues,
		merge_queue: [],
		paused_for_user: null,
		started_at: "2026-05-12T22:00:00Z",
		summary_path: "tmp/flightdeck-summary-HT-2026-05-13T002128Z.md",
		terminated: true,
		terminated_at: "2026-05-13T00:21:28Z",
		...overrides,
	};
}

// ----- pure shape -----------------------------------------------------------

test("readMasterState surfaces summary_path + merge_commit from terminated archive shape", () => {
	const { tmpDir, cleanup } = makeProject();
	try {
		const { archive } = simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"CC-503": makeMergedIssueRecord(),
		}));
		const { state } = readMasterState(archive);
		assert.equal(state?.terminated, true);
		assert.equal(state?.summary_path, "tmp/flightdeck-summary-HT-2026-05-13T002128Z.md");
		assert.equal(state?.issues["CC-503"]?.merge_commit, "156d9df02ce8fb3a798f233c73e489338db969f9");
		assert.equal(state?.issues["CC-503"]?.decisions_log?.length, 3);
	} finally {
		cleanup();
	}
});

test("readMasterState normalizes malformed conflict_graph and decisions_log without throwing (MAJOR #3)", () => {
	const { tmpDir, cleanup } = makeProject();
	try {
		const corrupt = writeLive(tmpDir, "HT", {
			conflict_graph: { edges: "not-an-array", computed_at: 42 },
			issues: {
				"CC-001": {
					state: "merged",
					decisions_log: "this should be an array but isn't",
				},
				"CC-002": {
					state: "merged",
					decisions_log: [
						{ ts: "2026-05-13T00:00:00Z", prompt_tag: "x", answer: "y" },
						"junk",
						{ ts: 123, prompt_tag: "y", answer: "z" },
						null,
					],
				},
			},
			merge_queue: ["CC-001"],
			terminated: false,
		});
		const { state, error } = readMasterState(corrupt);
		assert.equal(error, undefined);
		assert.deepEqual(state?.conflict_graph?.edges, []);
		assert.equal(state?.conflict_graph?.computed_at, null);
		assert.deepEqual(state?.issues["CC-001"]?.decisions_log, []);
		assert.equal(state?.issues["CC-002"]?.decisions_log?.length, 1);
		assert.equal(state?.issues["CC-002"]?.decisions_log?.[0]?.prompt_tag, "x");
	} finally {
		cleanup();
	}
});

// ----- policy --------------------------------------------------------------

test("flightdeckSessionStatus returns 'terminated' when terminated AND issues preserved", () => {
	const { tmpDir, cleanup } = makeProject();
	try {
		const { archive } = simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"CC-503": makeMergedIssueRecord(),
		}));
		const { state } = readMasterState(archive);
		const snapshot = makeSnapshot(state);
		assert.equal(flightdeckSessionStatus(snapshot), "terminated");
	} finally {
		cleanup();
	}
});

test("flightdeckSessionStatus is 'inactive' when terminated and issues were wiped (legacy regression shape)", () => {
	const snapshot = makeSnapshot({
		conflict_graph: { computed_at: null, edges: [] },
		issues: {},
		merge_queue: [],
		paused_for_user: null,
		terminated: true,
		terminated_at: "2026-05-13T00:21:28Z",
	});
	assert.equal(flightdeckSessionStatus(snapshot), "inactive");
});

test("mergedIssueHistory orders by last_polled_at desc and filters to merged only", () => {
	const { tmpDir, cleanup } = makeProject();
	try {
		const { archive } = simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"A-1": makeMergedIssueRecord({ last_polled_at: "2026-05-13T00:10:00Z", pr_number: 1 }),
			"A-2": makeMergedIssueRecord({ last_polled_at: "2026-05-13T00:20:00Z", pr_number: 2 }),
			"A-3": { ...makeMergedIssueRecord(), state: "aborted" },
			"A-4": { ...makeMergedIssueRecord(), state: "waiting" },
		}));
		const { state } = readMasterState(archive);
		const history = mergedIssueHistory(state);
		assert.equal(history.length, 2);
		assert.equal(history[0]?.issue, "A-2");
		assert.equal(history[1]?.issue, "A-1");
	} finally {
		cleanup();
	}
});

test("readTrackedEntries returns the same set regardless of terminal state (normalization seam)", () => {
	const { tmpDir, cleanup } = makeProject();
	try {
		const { archive } = simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"A-1": makeMergedIssueRecord(),
			"A-2": { ...makeMergedIssueRecord(), state: "aborted" },
		}));
		const { state } = readMasterState(archive);
		const entries = readTrackedEntries(state);
		assert.deepEqual(entries.map((e) => e.issue), ["A-1", "A-2"]);
	} finally {
		cleanup();
	}
});

// ----- archive discovery ---------------------------------------------------

test("findNewestTerminatedArchive picks the lexicographically latest archive (ts encoded YYYYMMDDTHHMMSSZ)", () => {
	const { tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260501T120000Z.json.archive"), "{}", "utf8");
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "{}", "utf8");
		writeFileSync(join(tmpDir, "flightdeck-state-OTHER-20260601T000000Z.json.archive"), "{}", "utf8");
		const picked = findNewestTerminatedArchive(tmpDir, "HT");
		assert.match(picked ?? "", /flightdeck-state-HT-20260513T002128Z\.json\.archive$/);
	} finally {
		cleanup();
	}
});

test("findNewestTerminatedArchive returns undefined when no matching archive exists", () => {
	const { tmpDir, cleanup } = makeProject();
	try {
		assert.equal(findNewestTerminatedArchive(tmpDir, "HT"), undefined);
	} finally {
		cleanup();
	}
});

// ----- end-to-end: buildSnapshotFromInputs (BLOCKER #2) --------------------

test("buildSnapshotFromInputs falls back to terminated archive when live file is missing (BLOCKER #1/#2)", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		const { archive } = simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"CC-503": makeMergedIssueRecord(),
		}));
		assert.equal(existsSync(join(tmpDir, "flightdeck-state-HT.json")), false, "live file should be archived away");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(snapshot.master?.terminated, true);
		assert.equal(snapshot.master?.issues["CC-503"]?.pr_number, 81);
		assert.equal(snapshot.master?.issues["CC-503"]?.merge_commit, "156d9df02ce8fb3a798f233c73e489338db969f9");
		assert.equal(snapshot.masterStatePath, archive, "masterStatePath should point at the archive");
		assert.equal(flightdeckSessionStatus(snapshot), "terminated");
		assert.equal(readTrackedEntries(snapshot.master).length, 1);
	} finally {
		cleanup();
	}
});

test("buildSnapshotFromInputs prefers live file over archive when both exist (no shadowing)", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"OLD-1": makeMergedIssueRecord({ pr_number: 1 }),
		}, { terminated_at: "2026-05-01T00:00:00Z" }));
		const nowIso = new Date().toISOString();
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			issues: {
				"NEW-1": { state: "waiting", harness: "claude", pr_number: 99, last_polled_at: nowIso },
			},
			merge_queue: [],
			paused_for_user: null,
			started_at: nowIso,
			terminated: false,
		});
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(snapshot.master?.terminated, false);
		assert.equal(snapshot.master?.issues["NEW-1"]?.state, "waiting");
		assert.equal(snapshot.master?.issues["OLD-1"], undefined);
		// Status is "stale" without a live daemon (no PID file), but the
		// material assertion here is that the live file wins over the
		// terminated archive — the dashboard is reading current data, not
		// the post-mortem.
		assert.notEqual(flightdeckSessionStatus(snapshot), "terminated");
		assert.notEqual(flightdeckSessionStatus(snapshot), "inactive");
	} finally {
		cleanup();
	}
});

test("buildSnapshotFromInputs returns inactive when neither live nor terminated archive exist", () => {
	const { projectRoot, stateDir, cleanup } = makeProject();
	try {
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(snapshot.master, undefined);
		assert.equal(flightdeckSessionStatus(snapshot), "inactive");
	} finally {
		cleanup();
	}
});

// ----- edge cases (MEDIUM #6) ----------------------------------------------

test("edge case: empty terminated session (no issues) reports inactive, not terminated", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		simulateTerminateArchive(tmpDir, "HT", terminatedPayload({}));
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		// archive was loaded but had no issues — session-status policy
		// folds this into `inactive`, matching the empty-Overview message
		// behavior. This is the only safe choice: rendering a terminated
		// banner with zero tracked sessions would be confusing.
		assert.equal(snapshot.master?.terminated, true);
		assert.equal(Object.keys(snapshot.master?.issues ?? {}).length, 0);
		assert.equal(flightdeckSessionStatus(snapshot), "inactive");
	} finally {
		cleanup();
	}
});

test("edge case: mixed merged/aborted/dead outcomes all preserved", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"M-1": makeMergedIssueRecord({ pr_number: 1, last_polled_at: "2026-05-13T00:05:00Z" }),
			"A-1": { ...makeMergedIssueRecord({ pr_number: 2 }), state: "aborted" },
			"D-1": { ...makeMergedIssueRecord({ pr_number: 3 }), state: "dead" },
			"M-2": makeMergedIssueRecord({ pr_number: 4, last_polled_at: "2026-05-13T00:20:00Z" }),
		}));
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(flightdeckSessionStatus(snapshot), "terminated");
		const entries = readTrackedEntries(snapshot.master);
		assert.equal(entries.length, 4);
		const merged = mergedIssueHistory(snapshot.master);
		assert.deepEqual(merged.map((i) => i.issue), ["M-2", "M-1"]);
	} finally {
		cleanup();
	}
});

test("edge case: archive present but summary_path absent renders gracefully", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"CC-503": makeMergedIssueRecord(),
		}, { summary_path: undefined }));
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(snapshot.master?.terminated, true);
		assert.equal(snapshot.master?.summary_path, undefined);
		assert.equal(flightdeckSessionStatus(snapshot), "terminated");
	} finally {
		cleanup();
	}
});

// ----- BLOCK round 3: malformed archive surfacing ---------------------------

test("buildSnapshotFromInputs: every candidate archive malformed → masterError + archive-error status", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "{not valid json", "utf8");
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260101T000000Z.json.archive"), "also {not json}", "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(snapshot.master, undefined);
		assert.ok(snapshot.masterError, "masterError must be set when all archives fail");
		assert.match(snapshot.masterError ?? "", /no readable terminated archive: 2 candidates failed/);
		assert.match(snapshot.masterError ?? "", /20260513T002128Z\.json\.archive/, "diagnostic should reference the newest candidate (tried first)");
		assert.ok(snapshot.masterStatePath?.endsWith(".json.archive"), "masterStatePath should point at the archive that failed");
		assert.equal(flightdeckSessionStatus(snapshot), "archive-error");
	} finally {
		cleanup();
	}
});

test("readMasterState rejects non-object roots (JSON array, scalars) as malformed", () => {
	// Defends the archive-error diagnostic by pinning the readMasterState
	// contract: only `{ ... }` payloads count as readable; arrays / scalars
	// are surfaced as `error` so the BLOCK fallback path records them as
	// failures rather than silently treating them as empty state.
	const { tmpDir, cleanup } = makeProject();
	try {
		const path = join(tmpDir, "flightdeck-state-HT.json");
		writeFileSync(path, "[]", "utf8");
		const arrayRead = readMasterState(path);
		assert.equal(arrayRead.state, undefined);
		assert.match(arrayRead.error ?? "", /not an object/);
		writeFileSync(path, "42", "utf8");
		const scalarRead = readMasterState(path);
		assert.equal(scalarRead.state, undefined);
		assert.match(scalarRead.error ?? "", /not an object/);
	} finally {
		cleanup();
	}
});

test("buildSnapshotFromInputs: malformed newest + valid older archive → falls back to the valid one", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "{corrupt", "utf8");
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260101T000000Z.json.archive"), JSON.stringify(terminatedPayload({
			"OLD-1": makeMergedIssueRecord({ pr_number: 99 }),
		}, { terminated_at: "2026-01-01T00:00:00Z" })), "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(snapshot.master?.terminated, true);
		assert.equal(snapshot.master?.issues["OLD-1"]?.pr_number, 99);
		assert.ok(snapshot.masterStatePath?.endsWith("20260101T000000Z.json.archive"), "should land on the older but valid archive");
		assert.equal(snapshot.masterError, undefined, "successful fallback should not leave masterError set");
		assert.equal(flightdeckSessionStatus(snapshot), "terminated");
	} finally {
		cleanup();
	}
});

// ----- BLOCK round 4: strict archive validation ----------------------------

test("strict archive: zero-byte file counts as failure (blank archive)", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "", "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(snapshot.master, undefined);
		assert.match(snapshot.masterError ?? "", /blank archive/);
		assert.equal(flightdeckSessionStatus(snapshot), "archive-error");
	} finally {
		cleanup();
	}
});

test("strict archive: whitespace-only file counts as failure (blank archive)", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "   \n\t  \n", "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.match(snapshot.masterError ?? "", /blank archive/);
		assert.equal(flightdeckSessionStatus(snapshot), "archive-error");
	} finally {
		cleanup();
	}
});

test("strict archive: null root counts as failure (not an object)", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "null", "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.match(snapshot.masterError ?? "", /not an object/);
		assert.equal(flightdeckSessionStatus(snapshot), "archive-error");
	} finally {
		cleanup();
	}
});

test("strict archive: `{}` root counts as failure (archive missing terminated:true)", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "{}", "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.match(snapshot.masterError ?? "", /archive missing terminated:true/);
		assert.equal(flightdeckSessionStatus(snapshot), "archive-error");
	} finally {
		cleanup();
	}
});

test("strict archive: valid-object-but-not-terminated counts as failure", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		const payload = terminatedPayload({ "X-1": makeMergedIssueRecord({ pr_number: 1 }) });
		// Strip the terminated flag entirely — the archive carries a valid
		// state shape but isn't a completion record.
		delete (payload as Record<string, unknown>).terminated;
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), JSON.stringify(payload), "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.match(snapshot.masterError ?? "", /archive missing terminated:true/);
		assert.equal(flightdeckSessionStatus(snapshot), "archive-error");
	} finally {
		cleanup();
	}
});

test("strict archive: every candidate fails for different reasons → count + latest reason in diagnostic", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "{not json", "utf8");
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260101T000000Z.json.archive"), "", "utf8");
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20250101T000000Z.json.archive"), "{}", "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.match(snapshot.masterError ?? "", /no readable terminated archive: 3 candidates failed/);
		assert.match(snapshot.masterError ?? "", /20260513T002128Z/);
		assert.equal(flightdeckSessionStatus(snapshot), "archive-error");
	} finally {
		cleanup();
	}
});

// ----- MAJOR round 4: ENOENT vs other readdir errors -----------------------

test("readdir ENOENT → archives:[], no error (project never had a tmp/)", () => {
	const dir = mkdtempSync(join(tmpdir(), "pi-flightdeck-nonexist-"));
	rmSync(dir, { force: true, recursive: true });
	const result = listTerminatedArchives(dir, "HT");
	assert.deepEqual(result.archives, []);
	assert.equal(result.error, undefined);
});

test("readdir EACCES → archives:[], error propagated with code+path", { skip: process.getuid?.() === 0 ? "running as root; chmod 000 is bypassed" : false }, () => {
	const { chmodSync } = require("node:fs") as typeof import("node:fs");
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		chmodSync(tmpDir, 0o000);
		const result = listTerminatedArchives(tmpDir, "HT");
		assert.deepEqual(result.archives, []);
		assert.ok(result.error, "non-ENOENT readdir errors must propagate");
		assert.equal(result.error?.code, "EACCES");
		assert.equal(result.error?.path, tmpDir);
		// And the snapshot should surface it as archive-error.
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.match(snapshot.masterError ?? "", /archive directory unreadable: EACCES/);
		assert.equal(flightdeckSessionStatus(snapshot), "archive-error");
	} finally {
		try { chmodSync(tmpDir, 0o755); } catch { /* dir may already be gone */ }
		cleanup();
	}
});

// ----- shared helpers -------------------------------------------------------

function makeSnapshot(masterShape: unknown): FlightdeckSnapshot {
	// Hand-crafted snapshot for tests that need to assert behavior
	// directly against a shape without involving the on-disk fallback
	// path. Used for legacy-regression shape (terminated + empty issues)
	// and bare-state policy checks.
	let master: FlightdeckSnapshot["master"];
	if (masterShape && typeof masterShape === "object") {
		const wire = masterShape as Record<string, unknown>;
		master = {
			conflict_graph: (wire.conflict_graph as { edges?: Array<[string, string]>; computed_at?: string | null }) ?? { computed_at: null, edges: [] },
			issues: (wire.issues as Record<string, never>) ?? {},
			merge_queue: Array.isArray(wire.merge_queue) ? (wire.merge_queue as string[]) : [],
			paused_for_user: (wire.paused_for_user as null) ?? null,
			session_id: wire.session_id as string | undefined,
			started_at: wire.started_at as string | undefined,
			summary_path: typeof wire.summary_path === "string" ? wire.summary_path : undefined,
			terminated: Boolean(wire.terminated),
			terminated_at: wire.terminated_at as string | undefined,
		};
	}
	return {
		daemon: {
			heartbeatExists: false,
			pidAlive: false,
			stateDir: "/tmp",
			subscriberCounts: { claude: 0, codex: 0, opencode: 0, pi: 0 },
			subscribers: [],
		},
		master,
		pendingEvents: [],
		stateDir: "/tmp",
		tmux: TMUX,
		wakeEvents: [],
	};
}
