// Regression coverage for issue #17. The dashboard previously collapsed
// after `terminate.md` finished a session: `pane-registry remove-merged`
// emptied `.issues` before archive, then `flightdeckSessionStatus` saw
// `terminated: true` with zero issues and returned `inactive`, hiding
// the completion summary. After the fix:
//   1) the master state shape carries the merged-issue history through
//      to the archive, and
//   2) `flightdeckSessionStatus` returns a new `terminated` status so
//      the renderer keeps the dashboard / Overview / Conflicts &
//      merges tabs populated until the user dismisses.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
	flightdeckSessionStatus,
	type FlightdeckSnapshot,
	mergedIssueHistory,
	readMasterState,
} from "../extensions/state.js";

function makeSnapshot(masterShape: Record<string, unknown>, daemonAlive = false): FlightdeckSnapshot {
	const dir = mkdtempSync(join(tmpdir(), "pi-flightdeck-state-"));
	const file = join(dir, "master.json");
	writeFileSync(file, JSON.stringify(masterShape), "utf8");
	const { state } = readMasterState(file);
	rmSync(dir, { force: true, recursive: true });
	return {
		daemon: {
			heartbeatExists: false,
			pidAlive: daemonAlive,
			stateDir: "/tmp",
			subscriberCounts: { claude: 0, codex: 0, opencode: 0, pi: 0 },
			subscribers: [],
		},
		master: state,
		pendingEvents: [],
		stateDir: "/tmp",
		tmux: { paneId: "%1", sessionId: "$1", sessionKey: "s1", sessionName: "HT" },
		wakeEvents: [],
	};
}

test("readMasterState surfaces summary_path + merge_commit from terminated archive shape", () => {
	const snapshot = makeSnapshot({
		terminated: true,
		terminated_at: "2026-05-13T00:21:28Z",
		summary_path: "tmp/flightdeck-summary-HT-2026-05-13T002128Z.md",
		issues: {
			"CC-503": {
				state: "merged",
				pr_number: 81,
				merge_commit: "156d9df02ce8fb3a798f233c73e489338db969f9",
				decisions_log: [{ ts: "2026-05-13T00:15:35Z", prompt_tag: "terminal-state-reached", answer: "merged" }],
			},
		},
	});
	assert.equal(snapshot.master?.terminated, true);
	assert.equal(snapshot.master?.summary_path, "tmp/flightdeck-summary-HT-2026-05-13T002128Z.md");
	assert.equal(snapshot.master?.issues["CC-503"]?.merge_commit, "156d9df02ce8fb3a798f233c73e489338db969f9");
	assert.equal(snapshot.master?.issues["CC-503"]?.decisions_log?.length, 1);
});

test("flightdeckSessionStatus returns 'terminated' when terminated AND issues preserved", () => {
	const snapshot = makeSnapshot({
		terminated: true,
		terminated_at: "2026-05-13T00:21:28Z",
		issues: {
			"CC-503": { state: "merged", pr_number: 81, merge_commit: "156d9df" },
		},
	});
	assert.equal(flightdeckSessionStatus(snapshot), "terminated");
});

test("flightdeckSessionStatus is 'inactive' when terminated and issues were wiped (legacy regression shape)", () => {
	const snapshot = makeSnapshot({ terminated: true, terminated_at: "2026-05-13T00:21:28Z", issues: {} });
	assert.equal(flightdeckSessionStatus(snapshot), "inactive");
});

test("mergedIssueHistory orders by last_polled_at desc and filters to merged", () => {
	const snapshot = makeSnapshot({
		terminated: true,
		issues: {
			"A-1": { state: "merged", pr_number: 1, last_polled_at: "2026-05-13T00:10:00Z" },
			"A-2": { state: "merged", pr_number: 2, last_polled_at: "2026-05-13T00:20:00Z" },
			"A-3": { state: "aborted", pr_number: 3 },
			"A-4": { state: "waiting" },
		},
	});
	const history = mergedIssueHistory(snapshot.master);
	assert.equal(history.length, 2);
	assert.equal(history[0]?.issue, "A-2");
	assert.equal(history[1]?.issue, "A-1");
});
