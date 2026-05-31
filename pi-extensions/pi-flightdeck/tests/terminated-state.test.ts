// Regression coverage for issue #17. The dashboard previously collapsed
// after `terminate.md` finished a session:
//   1) `pane-registry remove-merged` emptied tracked entries before
//      `archive`, so the rotated file carried no history; AND
//   2) `flightdeck-state archive` renames the live file out of the way,
//      so `pi-flightdeck` read a missing live path and fell through to
//      `inactive` even when the archive carried the full session
//      history.
//
// After the full fix:
//   * `terminate.md` no longer calls `remove-merged`, so the archive
//     preserves the entries map (decisions_log, pr_number, merge_commit).
//   * `buildSnapshotFromInputs` falls back to the newest terminated
//     archive when the live file is missing.
//   * `flightdeckSessionStatus` keeps terminated archives inactive by default,
//     so the Pi mini-dashboard remains active-run-only.
//   * `readMasterState` normalizes nested `conflict_graph` /
//     `decisions_log` so a corrupt archive renders as empty-but-stable
//     instead of crashing renderers.
//
// Tests are layered: pure shape (readMasterState), policy
// (flightdeckSessionStatus / mergedIssueHistory / readTrackedEntries),
// end-to-end (buildSnapshotFromInputs against a real archive on disk),
// and active-run policy (terminated archives do not render inline by default).

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import test from "node:test";
import {
	buildSnapshotFromInputs,
	type FlightdeckSnapshot,
	findNewestTerminatedArchive,
	flightdeckSessionStatus,
	mergedIssueHistory,
	readMasterState,
	readOwnerVisibilityProbe,
	readTrackedEntries,
	resetRunStoreCacheForTests,
	resetTmuxContextCacheForTests,
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

function sha256(value: string): string {
	return createHash("sha256").update(value).digest("hex");
}

function safeSegment(value: string, fallback = "project"): string {
	const cleaned = value.trim().toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48);
	return cleaned || fallback;
}

function projectIdentityForTest(projectRoot: string): { projectId: string; name: string; root: string; rootHash: string } {
	const root = resolve(projectRoot);
	const rootHash = sha256(root);
	const name = basename(root) || "project";
	return { name, projectId: `${safeSegment(name)}-${sha256(rootHash).slice(0, 16)}`, root, rootHash };
}

function writeJson0600(path: string, payload: Record<string, unknown>): void {
	writeFileSync(path, JSON.stringify(payload), { encoding: "utf8", mode: 0o600 });
	chmodSync(path, 0o600);
}

function activePointerPathForTest(runStoreRoot: string, projectRoot: string, sessionName: string): string {
	return join(runStoreRoot, "projects", projectIdentityForTest(projectRoot).projectId, "active-runs", `${sessionName}.json`);
}

function writeDurableActiveRunState(runStoreRoot: string, projectRoot: string, sessionName: string, payload: Record<string, unknown>, runId = "run-current"): string {
	const identity = projectIdentityForTest(projectRoot);
	const projectId = identity.projectId;
	const projectDir = join(runStoreRoot, "projects", projectId);
	const runDir = join(projectDir, "runs", runId);
	mkdirSync(join(projectDir, "active-runs"), { recursive: true });
	mkdirSync(runDir, { recursive: true });
	const now = "2026-05-13T00:30:00Z";
	writeJson0600(join(projectDir, "project.json"), {
		created_at: now,
		id_source: "root",
		last_seen_at: now,
		name: identity.name,
		project_id: projectId,
		remote_url: null,
		root_hash: identity.rootHash,
		root_path: identity.root,
		schema_version: 1,
	});
	const statePath = join(runDir, "state.json");
	const activityPath = join(runDir, "activity.jsonl");
	const snapshotsPath = join(runDir, "snapshots");
	writeJson0600(statePath, payload);
	writeJson0600(join(runDir, "metadata.json"), {
		activity_path: activityPath,
		imported: false,
		imported_from: null,
		last_seen_at: now,
		legacy_activity_path: null,
		project_id: projectId,
		project_root: identity.root,
		run_id: runId,
		schema_version: 1,
		snapshots_path: snapshotsPath,
		started_at: now,
		state_path: statePath,
		summary_path: null,
		terminated: false,
		terminated_at: null,
		tmux_session: sessionName,
	});
	writeJson0600(join(projectDir, "active-runs", `${sessionName}.json`), {
		activity_path: join(runDir, "activity.jsonl"),
		project_id: projectId,
		run_id: runId,
		schema_version: 1,
		state_path: statePath,
		tmux_session: sessionName,
		updated_at: now,
	});
	return statePath;
}

interface MergedRecordOverrides {
	state?: string;
	last_polled_at?: string;
	pr_number?: number;
	merge_commit?: string;
	decisions_log?: Array<Record<string, unknown>>;
}

function makeMergedIssueRecord(id = "CC-503", overrides: MergedRecordOverrides = {}): Record<string, unknown> {
	// Tracked entry shape for a kind=issue entry. Issue-mode metadata
	// lives under domain.issue; overrides may set top-level state /
	// last_polled_at and the most-common domain.issue fields.
	return {
		decisions_log: overrides.decisions_log ?? [
			{ answer: "apply", prompt_tag: "review-fix", ts: "2026-05-13T00:00:01Z" },
			{ answer: "yes", prompt_tag: "merge-now", ts: "2026-05-13T00:10:00Z" },
			{ answer: "merged", prompt_tag: "terminal-state-reached", ts: "2026-05-13T00:15:35Z" },
		],
		domain: {
			issue: {
				id,
				merge_commit: overrides.merge_commit ?? "156d9df02ce8fb3a798f233c73e489338db969f9",
				pr_number: overrides.pr_number ?? 81,
				worktree: `/repo/trees/${id}`,
			},
		},
		harness: "claude",
		id,
		kind: "issue",
		last_polled_at: overrides.last_polled_at ?? "2026-05-13T00:15:35Z",
		spawned_at: "2026-05-12T23:00:00Z",
		state: overrides.state ?? "merged",
		title: id,
		window: id,
	};
}

function terminatedPayload(entries: Record<string, Record<string, unknown>>, overrides: Record<string, unknown> = {}): Record<string, unknown> {
	return {
		conflict_graph: { computed_at: null, edges: [] },
		entries,
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
			entries: {
				"CC-001": {
					id: "CC-001",
					kind: "issue",
					state: "merged",
					domain: { issue: { id: "CC-001" } },
					decisions_log: "this should be an array but isn't",
				},
				"CC-002": {
					id: "CC-002",
					kind: "issue",
					state: "merged",
					domain: { issue: { id: "CC-002" } },
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
		assert.deepEqual(state?.entries?.["CC-001"]?.decisions_log, []);
		assert.equal(state?.entries?.["CC-002"]?.decisions_log?.length, 1);
		assert.equal(state?.entries?.["CC-002"]?.decisions_log?.[0]?.prompt_tag, "x");
	} finally {
		cleanup();
	}
});

// ----- policy --------------------------------------------------------------

test("flightdeckSessionStatus is inactive when terminated archives preserve entries", () => {
	const { tmpDir, cleanup } = makeProject();
	try {
		const { archive } = simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"CC-503": makeMergedIssueRecord(),
		}));
		const { state } = readMasterState(archive);
		const snapshot = makeSnapshot(state);
		assert.equal(flightdeckSessionStatus(snapshot), "inactive");
	} finally {
		cleanup();
	}
});

test("flightdeckSessionStatus is 'inactive' when terminated and entries were wiped", () => {
	const snapshot = makeSnapshot({
		conflict_graph: { computed_at: null, edges: [] },
		entries: {},
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
			"A-1": makeMergedIssueRecord("A-1", { last_polled_at: "2026-05-13T00:10:00Z" }),
			"A-2": makeMergedIssueRecord("A-2", { last_polled_at: "2026-05-13T00:20:00Z" }),
			"A-3": { ...makeMergedIssueRecord("A-3"), state: "aborted" },
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
			"A-1": makeMergedIssueRecord("A-1"),
			"A-2": { ...makeMergedIssueRecord("A-2"), state: "aborted" },
		}));
		const { state } = readMasterState(archive);
		const entries = readTrackedEntries(state);
		assert.deepEqual(entries.map((e) => e.id).sort(), ["A-1", "A-2"]);
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
		assert.equal(flightdeckSessionStatus(snapshot), "inactive");
		assert.equal(readTrackedEntries(snapshot.master).length, 1);
	} finally {
		cleanup();
	}
});

test("buildSnapshotFromInputs prefers live file over archive when both exist (no shadowing)", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"OLD-1": makeMergedIssueRecord("OLD-1"),
		}, { terminated_at: "2026-05-01T00:00:00Z" }));
		const nowIso = new Date().toISOString();
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {
				"NEW-1": {
					id: "NEW-1",
					kind: "issue",
					state: "waiting",
					harness: "claude",
					last_polled_at: nowIso,
					domain: { issue: { id: "NEW-1", pr_number: 99 } },
				},
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

test("buildSnapshotFromInputs prefers durable active run over legacy terminated archive", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-"));
	process.env.FLIGHTDECK_RUN_STORE_ROOT = runStoreRoot;
	resetRunStoreCacheForTests();
	try {
		simulateTerminateArchive(tmpDir, "HT", terminatedPayload({
			"OLD-1": makeMergedIssueRecord("OLD-1"),
		}));
		const activeStatePath = writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			started_at: "2026-05-13T00:30:00Z",
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(snapshot.masterStatePath, activeStatePath);
		assert.equal(snapshot.master?.terminated, false);
		assert.equal(readTrackedEntries(snapshot.master).length, 0);
		assert.equal(snapshot.master?.issues["OLD-1"], undefined, "archived entries must not leak into a fresh empty active run");
		assert.equal(flightdeckSessionStatus(snapshot), "inactive");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("buildSnapshotFromInputs prefers durable active run over stale legacy live file", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-"));
	process.env.FLIGHTDECK_RUN_STORE_ROOT = runStoreRoot;
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			started_at: "2026-05-12T00:00:00Z",
			terminated: false,
		});
		const activeStatePath = writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			started_at: "2026-05-13T00:30:00Z",
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(snapshot.masterStatePath, activeStatePath);
		assert.equal(readTrackedEntries(snapshot.master).length, 0);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined, "legacy live file must not shadow durable active run");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("buildSnapshotFromInputs honors FLIGHTDECK_RUN_STORE_ROOT from .env.local over stale legacy live file", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-env-"));
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), `FLIGHTDECK_RUN_STORE_ROOT=${runStoreRoot}\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			started_at: "2026-05-12T00:00:00Z",
			terminated: false,
		});
		const activeStatePath = writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			started_at: "2026-05-13T00:30:00Z",
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(snapshot.masterStatePath, activeStatePath);
		assert.equal(readTrackedEntries(snapshot.master).length, 0);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined, ".env run-store active run must not be shadowed by stale legacy state");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("project .env run-store override does not leak into a later project without override", () => {
	const first = makeProject();
	const second = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const firstRunStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-first-"));
	const secondRunStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-second-"));
	process.env.FLIGHTDECK_RUN_STORE_ROOT = secondRunStoreRoot;
	writeFileSync(join(first.projectRoot, ".env.local"), `FLIGHTDECK_RUN_STORE_ROOT=${firstRunStoreRoot}\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		const firstActiveStatePath = writeDurableActiveRunState(firstRunStoreRoot, first.projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		writeLive(second.tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-2": makeMergedIssueRecord("LEGACY-2", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		const secondActiveStatePath = writeDurableActiveRunState(secondRunStoreRoot, second.projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const firstSnapshot = buildSnapshotFromInputs({ projectRoot: first.projectRoot, stateDir: first.stateDir, tmux: TMUX }, SETTINGS);
		const secondSnapshot = buildSnapshotFromInputs({ projectRoot: second.projectRoot, stateDir: second.stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(process.env.FLIGHTDECK_RUN_STORE_ROOT, secondRunStoreRoot, ".env override must stay scoped and not mutate process.env");
		assert.equal(firstSnapshot.masterStatePath, firstActiveStatePath);
		assert.equal(secondSnapshot.masterStatePath, secondActiveStatePath);
		assert.equal(secondSnapshot.master?.entries?.["LEGACY-2"], undefined, "first project override must not make second project fall back to stale legacy state");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(firstRunStoreRoot, { force: true, recursive: true });
		rmSync(secondRunStoreRoot, { force: true, recursive: true });
		first.cleanup();
		second.cleanup();
	}
});

test("blank project FLIGHTDECK_RUN_STORE_ROOT uses default store instead of inherited stale root", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const previousHome = process.env.HOME;
	const staleRunStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-stale-"));
	const home = mkdtempSync(join(tmpdir(), "pi-flightdeck-home-"));
	const defaultRunStoreRoot = join(home, ".vstack", "flightdeck");
	process.env.FLIGHTDECK_RUN_STORE_ROOT = staleRunStoreRoot;
	process.env.HOME = home;
	writeFileSync(join(projectRoot, ".env.local"), "FLIGHTDECK_RUN_STORE_ROOT=\n", "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		const activeStatePath = writeDurableActiveRunState(defaultRunStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(snapshot.masterStatePath, activeStatePath);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined, "blank project override must suppress inherited stale run-store root");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		if (previousHome === undefined) delete process.env.HOME;
		else process.env.HOME = previousHome;
		resetRunStoreCacheForTests();
		rmSync(staleRunStoreRoot, { force: true, recursive: true });
		rmSync(home, { force: true, recursive: true });
		cleanup();
	}
});

test("project .env shell override wins over inherited stale FLIGHTDECK_RUN_STORE_ROOT", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const staleRunStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-stale-"));
	const projectRunStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-shell-"));
	process.env.FLIGHTDECK_RUN_STORE_ROOT = staleRunStoreRoot;
	writeFileSync(join(projectRoot, ".env.local"), `CUSTOM_ROOT=${projectRunStoreRoot}\nFLIGHTDECK_RUN_STORE_ROOT="$CUSTOM_ROOT"\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		const activeStatePath = writeDurableActiveRunState(projectRunStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(snapshot.masterStatePath, activeStatePath);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined, "shell-expanded .env override must beat inherited stale run-store root");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(staleRunStoreRoot, { force: true, recursive: true });
		rmSync(projectRunStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("project .env run-store assignment with whitespace around equals fails closed", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-spaced-equals-"));
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), `FLIGHTDECK_RUN_STORE_ROOT = ${runStoreRoot}\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported whitespace around assignment/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("project .env unsupported run-store assignment forms fail closed", () => {
	const cases = [
		"FLIGHTDECK_RUN_STORE_ROOT+=/tmp/unsupported\n",
		"FLIGHTDECK_RUN_STORE_ROOT[0]=/tmp/unsupported\n",
		"FLIGHTDECK_RUN_STORE_ROOT=/tmp/unsupported\nunset FLIGHTDECK_RUN_STORE_ROOT\n",
		": ${FLIGHTDECK_RUN_STORE_ROOT:=/tmp/unsupported}\n",
	];
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	try {
		for (const envText of cases) {
			const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
			resetRunStoreCacheForTests();
			try {
				writeFileSync(join(projectRoot, ".env.local"), envText, "utf8");
				writeLive(tmpDir, "HT", {
					conflict_graph: { computed_at: null, edges: [] },
					entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
					merge_queue: [],
					paused_for_user: null,
					terminated: false,
				});

				const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

				assert.equal(flightdeckSessionStatus(snapshot), "state-error", envText.trim());
				assert.match(snapshot.masterError ?? "", /unsupported (.*FLIGHTDECK_RUN_STORE_ROOT|\.env directive|\.env assignment)/, envText.trim());
				assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined, envText.trim());
			} finally {
				resetRunStoreCacheForTests();
				cleanup();
			}
		}
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
	}
});

test("project .env unsupported helper assignment referenced by run-store fails closed", () => {
	const cases = [
		"CUSTOM_ROOT=/tmp/unsupported\nCUSTOM_ROOT+=-suffix\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\n",
		"CUSTOM_ROOT=/tmp/unsupported\nCUSTOM_ROOT[0]=/tmp/unsupported\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\n",
		"CUSTOM_ROOT=/tmp/unsupported\nCUSTOM_ROOT[0]+=-suffix\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\n",
		"CUSTOM_ROOT=/tmp/unsupported\nunset CUSTOM_ROOT\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\n",
		": ${CUSTOM_ROOT:=/tmp/unsupported}\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\n",
	];
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	try {
		for (const envText of cases) {
			const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
			resetRunStoreCacheForTests();
			try {
				writeFileSync(join(projectRoot, ".env.local"), envText, "utf8");
				writeLive(tmpDir, "HT", {
					conflict_graph: { computed_at: null, edges: [] },
					entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
					merge_queue: [],
					paused_for_user: null,
					terminated: false,
				});

				const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

				assert.equal(flightdeckSessionStatus(snapshot), "state-error", envText.trim());
				assert.match(snapshot.masterError ?? "", /unsupported (assignment for CUSTOM_ROOT|variable reference CUSTOM_ROOT|\.env assignment|\.env directive)/, envText.trim());
				assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined, envText.trim());
			} finally {
				resetRunStoreCacheForTests();
				cleanup();
			}
		}
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
	}
});

test("project .env source-provided run-store root fails closed before legacy fallback", () => {
	const cases = [
		"source ./flightdeck.env",
		". ./flightdeck.env",
		"source${IFS}./flightdeck.env",
		".${IFS}./flightdeck.env",
		"source${IFS:- }./flightdeck.env",
		".${IFS:- }./flightdeck.env",
		"\\source ./flightdeck.env",
		"\\. ./flightdeck.env",
		"source${SPACE}./flightdeck.env",
		".${SPACE}./flightdeck.env",
	];
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	try {
		for (const directive of cases) {
			const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
			const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-sourced-"));
			resetRunStoreCacheForTests();
			try {
				writeFileSync(join(projectRoot, ".env.local"), `${directive}\n`, "utf8");
				writeFileSync(join(projectRoot, "flightdeck.env"), `FLIGHTDECK_RUN_STORE_ROOT=${runStoreRoot}\n`, "utf8");
				writeLive(tmpDir, "HT", {
					conflict_graph: { computed_at: null, edges: [] },
					entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
					merge_queue: [],
					paused_for_user: null,
					terminated: false,
				});
				writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
					conflict_graph: { computed_at: null, edges: [] },
					entries: {},
					merge_queue: [],
					paused_for_user: null,
					terminated: false,
				});

				const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

				assert.equal(flightdeckSessionStatus(snapshot), "state-error", directive);
				assert.match(snapshot.masterError ?? "", /unsupported (env-mutating directive|\.env directive)/, directive);
				assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined, directive);
			} finally {
				resetRunStoreCacheForTests();
				rmSync(runStoreRoot, { force: true, recursive: true });
				cleanup();
			}
		}
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
	}
});

test("project .env source-tainted helper reference fails closed before legacy fallback", () => {
	const cases = ["source ./flightdeck.env", ". ./flightdeck.env"];
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	try {
		for (const directive of cases) {
			const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
			const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-source-taint-"));
			resetRunStoreCacheForTests();
			try {
				writeFileSync(join(projectRoot, ".env.local"), `CUSTOM_ROOT=${runStoreRoot}\n${directive}\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\n`, "utf8");
				writeFileSync(join(projectRoot, "flightdeck.env"), "CUSTOM_ROOT=/tmp/source-mutated-root\n", "utf8");
				writeLive(tmpDir, "HT", {
					conflict_graph: { computed_at: null, edges: [] },
					entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
					merge_queue: [],
					paused_for_user: null,
					terminated: false,
				});
				writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
					conflict_graph: { computed_at: null, edges: [] },
					entries: {},
					merge_queue: [],
					paused_for_user: null,
					terminated: false,
				});

				const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

				assert.equal(flightdeckSessionStatus(snapshot), "state-error", directive);
				assert.match(snapshot.masterError ?? "", /unsupported (variable reference CUSTOM_ROOT|env-mutating directive|\.env directive)/, directive);
				assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined, directive);
			} finally {
				resetRunStoreCacheForTests();
				rmSync(runStoreRoot, { force: true, recursive: true });
				cleanup();
			}
		}
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
	}
});

test("project .env array-style run-store value fails closed before legacy fallback", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), "FLIGHTDECK_RUN_STORE_ROOT=(/tmp/unsupported)\n", "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported shell expansion/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		cleanup();
	}
});

test("project .env escaped run-store root fails closed before legacy fallback", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), "FLIGHTDECK_RUN_STORE_ROOT=\\/tmp/pi-fd-root\n", "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported escape syntax/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		cleanup();
	}
});

test("project .env escaped helper root fails closed before legacy fallback", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), "CUSTOM_ROOT=/tmp/pi\\-fd-root\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\n", "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported (escape syntax|variable reference CUSTOM_ROOT)/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		cleanup();
	}
});

test("project .env tilde run-store root fails closed before legacy fallback", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const homeRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-home-env-"));
	const runStoreRoot = join(homeRoot, "store");
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), `HOME=${homeRoot}\nFLIGHTDECK_RUN_STORE_ROOT=~/store\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported tilde expansion/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(homeRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("project .env tilde helper root fails closed before legacy fallback", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), "CUSTOM_ROOT=~/store\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\n", "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported tilde expansion/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		cleanup();
	}
});

test("project .env run-store expansion uses sequential assignment order", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const firstRunStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-first-"));
	const secondRunStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-second-"));
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), `CUSTOM_ROOT=${firstRunStoreRoot}\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\nCUSTOM_ROOT=${secondRunStoreRoot}\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		const activeStatePath = writeDurableActiveRunState(firstRunStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(snapshot.masterStatePath, activeStatePath);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined, "later .env assignments must not change already-expanded run-store root");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(firstRunStoreRoot, { force: true, recursive: true });
		rmSync(secondRunStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("project .env run-store forward reference fails closed before legacy fallback", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-forward-"));
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), `FLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\nCUSTOM_ROOT=${runStoreRoot}\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /undefined variable CUSTOM_ROOT/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("project .env same-line run-store assignment fails closed before legacy fallback", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const firstRunStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-sameline-first-"));
	const secondRunStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-sameline-second-"));
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), `CUSTOM_ROOT=${firstRunStoreRoot}; FLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT; CUSTOM_ROOT=${secondRunStoreRoot}\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported FLIGHTDECK_RUN_STORE_ROOT assignment/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(firstRunStoreRoot, { force: true, recursive: true });
		rmSync(secondRunStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("project .env run-store export with extra assignment fails closed before legacy fallback", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-export-extra-"));
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), `CUSTOM_ROOT=${runStoreRoot}\nexport FLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT OTHER=/x\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported whitespace in value/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("project .env quoted run-store export with extra assignment fails closed before legacy fallback", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-quoted-export-extra-"));
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), `CUSTOM_ROOT=${runStoreRoot}\nexport FLIGHTDECK_RUN_STORE_ROOT="$CUSTOM_ROOT" OTHER="/x"\n`, "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported trailing tokens after quoted value/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("source directives fail closed even when project run-store override follows", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-source-"));
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), `source ./flightdeck.env\nCUSTOM_ROOT=${runStoreRoot}\nFLIGHTDECK_RUN_STORE_ROOT=$CUSTOM_ROOT\n`, "utf8");
	writeFileSync(join(projectRoot, "flightdeck.env"), "FLIGHTDECK_RUN_STORE_ROOT=/tmp/should-not-be-sourced\n", "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported (env-mutating directive|\.env directive)/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("command substitution in project .env fails closed without execution", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), "FLIGHTDECK_RUN_STORE_ROOT=$(touch SHOULD_NOT_EXIST)\n", "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
		assert.match(snapshot.masterError ?? "", /unsupported shell expansion/);
		assert.equal(existsSync(join(projectRoot, "SHOULD_NOT_EXIST")), false);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		cleanup();
	}
});

test("failed .env load stays state-error on repeated snapshot attempts", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
	writeFileSync(join(projectRoot, ".env.local"), "FLIGHTDECK_RUN_STORE_ROOT=$MISSING_FLIGHTDECK_ROOT\n", "utf8");
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});

		const first = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		const second = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(flightdeckSessionStatus(first), "state-error");
		assert.equal(flightdeckSessionStatus(second), "state-error");
		assert.match(first.masterError ?? "", /\.env load failed/);
		assert.match(second.masterError ?? "", /\.env load failed/);
		assert.equal(first.master?.entries?.["LEGACY-1"], undefined);
		assert.equal(second.master?.entries?.["LEGACY-1"], undefined);
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		cleanup();
	}
});

test("buildSnapshotFromInputs fails closed when project index is missing but active pointer exists", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-"));
	process.env.FLIGHTDECK_RUN_STORE_ROOT = runStoreRoot;
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		const identity = projectIdentityForTest(projectRoot);
		const projectDir = join(runStoreRoot, "projects", identity.projectId);
		const runDir = join(projectDir, "runs", "run-current");
		mkdirSync(join(projectDir, "active-runs"), { recursive: true });
		mkdirSync(runDir, { recursive: true });
		writeJson0600(join(projectDir, "active-runs", "HT.json"), {
			activity_path: join(runDir, "activity.jsonl"),
			project_id: identity.projectId,
			run_id: "run-current",
			schema_version: 1,
			state_path: join(runDir, "state.json"),
			tmux_session: "HT",
			updated_at: "2026-05-13T00:30:00Z",
		});

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(snapshot.master, undefined);
		assert.match(snapshot.masterError ?? "", /project index missing while durable run artifacts exist/);
		assert.ok(snapshot.masterStatePath?.endsWith("project.json"));
		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("buildSnapshotFromInputs fails closed when active run state file is missing", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-"));
	process.env.FLIGHTDECK_RUN_STORE_ROOT = runStoreRoot;
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		const activeStatePath = writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		rmSync(activeStatePath, { force: true });

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(snapshot.master, undefined);
		assert.match(snapshot.masterError ?? "", /active run state missing/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("buildSnapshotFromInputs fails closed when active pointer state_path is not canonical", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-"));
	process.env.FLIGHTDECK_RUN_STORE_ROOT = runStoreRoot;
	resetRunStoreCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: { "LEGACY-1": makeMergedIssueRecord("LEGACY-1", { state: "waiting" }) },
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			paused_for_user: null,
			terminated: false,
		});
		const pointerPath = activePointerPathForTest(runStoreRoot, projectRoot, "HT");
		const pointer = JSON.parse(readFileSync(pointerPath, "utf8")) as Record<string, unknown>;
		writeJson0600(pointerPath, { ...pointer, state_path: join(runStoreRoot, "outside-state.json") });

		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);

		assert.equal(snapshot.master, undefined);
		assert.match(snapshot.masterError ?? "", /state_path .* does not match canonical path/);
		assert.equal(snapshot.master?.entries?.["LEGACY-1"], undefined);
		assert.equal(flightdeckSessionStatus(snapshot), "state-error");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
		cleanup();
	}
});

test("readOwnerVisibilityProbe reads durable active-run owner instead of legacy tmp owner", () => {
	const { projectRoot, tmpDir, cleanup } = makeProject();
	const previousRunStoreRoot = process.env.FLIGHTDECK_RUN_STORE_ROOT;
	const runStoreRoot = mkdtempSync(join(tmpdir(), "pi-flightdeck-run-store-"));
	process.env.FLIGHTDECK_RUN_STORE_ROOT = runStoreRoot;
	resetRunStoreCacheForTests();
	resetTmuxContextCacheForTests();
	try {
		writeLive(tmpDir, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			owner: { cwd: projectRoot, harness: "pi", pane_id: "%legacy" },
			paused_for_user: null,
			terminated: false,
		});
		writeDurableActiveRunState(runStoreRoot, projectRoot, "HT", {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {},
			merge_queue: [],
			owner: { cwd: projectRoot, harness: "pi", pane_id: "%active" },
			paused_for_user: null,
			terminated: false,
		});

		const probe = readOwnerVisibilityProbe(projectRoot, SETTINGS, TMUX);

		assert.equal(probe?.ownerPaneId, "%active");
	} finally {
		if (previousRunStoreRoot === undefined) delete process.env.FLIGHTDECK_RUN_STORE_ROOT;
		else process.env.FLIGHTDECK_RUN_STORE_ROOT = previousRunStoreRoot;
		resetRunStoreCacheForTests();
		resetTmuxContextCacheForTests();
		rmSync(runStoreRoot, { force: true, recursive: true });
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
			"M-1": makeMergedIssueRecord("M-1", { last_polled_at: "2026-05-13T00:05:00Z" }),
			"A-1": { ...makeMergedIssueRecord("A-1"), state: "aborted" },
			"D-1": { ...makeMergedIssueRecord("D-1"), state: "dead" },
			"M-2": makeMergedIssueRecord("M-2", { last_polled_at: "2026-05-13T00:20:00Z" }),
		}));
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(flightdeckSessionStatus(snapshot), "inactive");
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
		assert.equal(flightdeckSessionStatus(snapshot), "inactive");
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
			"OLD-1": makeMergedIssueRecord("OLD-1", { pr_number: 99 }),
		}, { terminated_at: "2026-01-01T00:00:00Z" })), "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(snapshot.master?.terminated, true);
		assert.equal(snapshot.master?.issues["OLD-1"]?.pr_number, 99);
		assert.ok(snapshot.masterStatePath?.endsWith("20260101T000000Z.json.archive"), "should land on the older but valid archive");
		assert.equal(snapshot.masterError, undefined, "successful fallback should not leave masterError set");
		assert.equal(flightdeckSessionStatus(snapshot), "inactive");
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
		const payload = terminatedPayload({ "X-1": makeMergedIssueRecord("X-1", { pr_number: 1 }) });
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
	// path.
	let master: FlightdeckSnapshot["master"];
	if (masterShape && typeof masterShape === "object") {
		const wire = masterShape as Record<string, unknown>;
		master = {
			conflict_graph: (wire.conflict_graph as { edges?: Array<[string, string]>; computed_at?: string | null }) ?? { computed_at: null, edges: [] },
			entries: (wire.entries as Record<string, never>) ?? {},
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
		livePaneIds: new Set(),
		master,
		pendingEvents: [],
		stateDir: "/tmp",
		tmux: TMUX,
		wakeEvents: [],
	};
}
