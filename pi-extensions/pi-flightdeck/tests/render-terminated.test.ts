// Render-output coverage for the post-termination view (BLOCKER #5).
//
// The state-shape tests (`terminated-state.test.ts`) prove the snapshot
// pipeline serves preserved history after archive. These tests run the
// actual renderer against that snapshot and grep the rendered lines for
// the user-visible fields:
//   * "session complete" chip (header)
//   * decisions_log rows in the Decisions tab
//   * merge history populated with the merged PR + short SHA
//   * summary path surface
//
// We strip ANSI from the rendered lines before grepping so style changes
// (themes, ANSI escapes) don't churn the assertions.

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { afterEach, beforeEach } from "node:test";
import {
	type DashboardState,
	makeInitialPopupState,
	renderConflictsTab,
	renderDashboardLines,
	renderDecisionsTab,
	renderOverviewTab,
} from "../extensions/flightdeck.js";
import { renderArchiveErrorBanner } from "../extensions/render-terminated.js";
import {
	buildSnapshotFromInputs,
	type FlightdeckSnapshot,
	type SettingsLike,
	type TmuxContext,
} from "../extensions/state.js";

// Stub Theme — returns plain text for fg/bg/bold/inverse/italic etc.
// The renderers only call fg/bg/bold/inverse, so this is sufficient
// structural compatibility for render-output assertions. Avoids
// initializing the real Theme class (which requires color tables and
// terminal capability detection that aren't relevant here).
type ThemeLike = {
	fg(_color: string, text: string): string;
	bg(_color: string, text: string): string;
	bold(text: string): string;
	italic(text: string): string;
	underline(text: string): string;
	inverse(text: string): string;
	strikethrough(text: string): string;
};

function plainTheme(): ThemeLike {
	const passthrough = (_c: string, t: string) => t;
	const wrap = (t: string) => t;
	return {
		bg: passthrough,
		bold: wrap,
		fg: passthrough,
		inverse: wrap,
		italic: wrap,
		strikethrough: wrap,
		underline: wrap,
	};
}

// Strip ANSI escape sequences (helpful even with the plain stub if
// upstream helpers emit raw ANSI like ANSI_BELL or formatShortcutHint).
function stripAnsi(s: string): string {
	return s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "").replace(/\x07/g, "");
}

function joinRendered(lines: string[]): string {
	return lines.map(stripAnsi).join("\n");
}

const SETTINGS: SettingsLike = { flightdeckStateDir: "tmp", stateDir: "" };
const TMUX: TmuxContext = { paneId: "%1", sessionId: "$1", sessionKey: "s1", sessionName: "HT" };

function makeProject(): { projectRoot: string; stateDir: string; tmpDir: string; cleanup: () => void } {
	const dir = mkdtempSync(join(tmpdir(), "pi-flightdeck-render-"));
	const tmp = join(dir, "tmp");
	mkdirSync(tmp, { recursive: true });
	const daemonDir = mkdtempSync(join(tmpdir(), "pi-flightdeck-render-daemon-"));
	return {
		cleanup: () => {
			rmSync(dir, { force: true, recursive: true });
			rmSync(daemonDir, { force: true, recursive: true });
		},
		projectRoot: dir,
		stateDir: daemonDir,
		tmpDir: tmp,
	};
}

// Env isolation (BLOCKER round 4 from review). The dashboard renderer
// reads `dashboardMaxItems`, `treeStyle`, etc. via
// `flightdeck.ts:readVstackConfig`, which lays user-global settings
// (`$PI_CODING_AGENT_DIR/settings.json` or `~/.pi/agent/settings.json`)
// over project settings discovered by walking up from `cwd`. Without
// pinning these, a host with `dashboardMaxItems=1` in its global
// settings would silently make the "compact view lists merged issues"
// test fail because CC-510 falls below the display cap. We point
// PI_CODING_AGENT_DIR and HOME at fresh empty dirs so config lookup
// finds nothing on every test invocation, and we always pass a
// project-isolated `cwd` to the render functions instead of a
// hard-coded path that might escape upward into a real `.pi`.
//
// Verified by re-running these tests with a polluted PI_CODING_AGENT_DIR
// (settings.json with dashboardMaxItems=1) — isolated harness passes;
// removing the harness reproduces the failure described in the review.
const SAVED_ENV: Record<string, string | undefined> = {};
let ENV_PI_DIR = "";
let ENV_HOME = "";
let ENV_CWD = "";

beforeEach(() => {
	for (const key of ["PI_CODING_AGENT_DIR", "HOME", "XDG_CONFIG_HOME", "USERPROFILE"]) {
		SAVED_ENV[key] = process.env[key];
	}
	ENV_PI_DIR = mkdtempSync(join(tmpdir(), "pi-flightdeck-render-piconf-"));
	ENV_HOME = mkdtempSync(join(tmpdir(), "pi-flightdeck-render-home-"));
	// `cwd` passed to render fns: walks up looking for .pi/.git/.vstack-lock
	// and stops at root if none found. Putting it under HOME with no
	// markers keeps `projectPiSettingsPath` resolving to a non-existent
	// file under HOME, which `existsSync` cleanly rejects.
	ENV_CWD = mkdtempSync(join(ENV_HOME, "isolated-cwd-"));
	process.env.PI_CODING_AGENT_DIR = ENV_PI_DIR;
	process.env.HOME = ENV_HOME;
	process.env.XDG_CONFIG_HOME = ENV_HOME;
	process.env.USERPROFILE = ENV_HOME;
});

afterEach(() => {
	for (const [key, value] of Object.entries(SAVED_ENV)) {
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
	if (ENV_PI_DIR) rmSync(ENV_PI_DIR, { force: true, recursive: true });
	if (ENV_HOME) rmSync(ENV_HOME, { force: true, recursive: true });
});

function isolatedCwd(): string {
	return ENV_CWD;
}

function simulateTerminate(tmpDir: string): string {
	const payload = {
		conflict_graph: { computed_at: null, edges: [] },
		issues: {
			"CC-503": {
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
			},
			"CC-510": {
				decisions_log: [
					{ answer: "merged", prompt_tag: "terminal-state-reached", ts: "2026-05-13T00:08:00Z" },
				],
				harness: "claude",
				last_polled_at: "2026-05-13T00:08:00Z",
				merge_commit: "abcdef1234567890abcdef1234567890abcdef12",
				pr_number: 82,
				state: "merged",
				window: "CC-510",
			},
		},
		merge_queue: [],
		paused_for_user: null,
		started_at: "2026-05-12T22:00:00Z",
		summary_path: "tmp/flightdeck-summary-HT-2026-05-13T002128Z.md",
		terminated: true,
		terminated_at: "2026-05-13T00:21:28Z",
	};
	const live = join(tmpDir, "flightdeck-state-HT.json");
	writeFileSync(live, JSON.stringify(payload), "utf8");
	const archive = join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive");
	renameSync(live, archive);
	return archive;
}

function buildPostTerminateSnapshot(): { snapshot: FlightdeckSnapshot; cleanup: () => void } {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	simulateTerminate(tmpDir);
	const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
	return { cleanup, snapshot };
}

// ----- dashboard ------------------------------------------------------------

test("dashboard header renders 'session complete' chip when master.terminated is true", () => {
	const { snapshot, cleanup } = buildPostTerminateSnapshot();
	try {
		const lines = renderDashboardLines(snapshot, plainTheme() as never, 120, "compact" as DashboardState, isolatedCwd(), new Map());
		const text = joinRendered(lines);
		assert.match(text, /session complete/);
		assert.ok(!/daemon dead/.test(text), "must NOT show 'daemon dead' on terminate");
	} finally {
		cleanup();
	}
});

test("dashboard compact view lists merged issues with state + PR after terminate", () => {
	const { snapshot, cleanup } = buildPostTerminateSnapshot();
	try {
		const lines = renderDashboardLines(snapshot, plainTheme() as never, 120, "compact" as DashboardState, isolatedCwd(), new Map());
		const text = joinRendered(lines);
		assert.match(text, /CC-503/);
		assert.match(text, /CC-510/);
		assert.match(text, /merged/);
		assert.match(text, /PR#81/);
		assert.match(text, /PR#82/);
	} finally {
		cleanup();
	}
});

test("dashboard hidden state renders nothing", () => {
	const { snapshot, cleanup } = buildPostTerminateSnapshot();
	try {
		const lines = renderDashboardLines(snapshot, plainTheme() as never, 120, "hidden" as DashboardState, isolatedCwd(), new Map());
		assert.deepEqual(lines, []);
	} finally {
		cleanup();
	}
});

// ----- Conflicts & merges tab ----------------------------------------------

test("Conflicts & merges tab shows merge history with PR + short SHA after terminate", () => {
	const { snapshot, cleanup } = buildPostTerminateSnapshot();
	try {
		const lines = renderConflictsTab(snapshot, makeInitialPopupState(), 120, plainTheme() as never);
		const text = joinRendered(lines);
		assert.match(text, /Merge history/);
		assert.match(text, /CC-503/);
		assert.match(text, /PR#81/);
		assert.match(text, /156d9df/); // short SHA
		assert.match(text, /CC-510/);
		assert.match(text, /PR#82/);
		assert.match(text, /abcdef1/);
	} finally {
		cleanup();
	}
});

test("Conflicts & merges tab surfaces summary_path", () => {
	const { snapshot, cleanup } = buildPostTerminateSnapshot();
	try {
		const lines = renderConflictsTab(snapshot, makeInitialPopupState(), 120, plainTheme() as never);
		const text = joinRendered(lines);
		assert.match(text, /tmp\/flightdeck-summary-HT-2026-05-13T002128Z\.md/);
	} finally {
		cleanup();
	}
});

// ----- Decisions tab --------------------------------------------------------

test("Decisions tab renders preserved decisions_log entries for merged issues", () => {
	const { snapshot, cleanup } = buildPostTerminateSnapshot();
	try {
		const lines = renderDecisionsTab(snapshot, makeInitialPopupState(), 120, plainTheme() as never, 40, isolatedCwd());
		const text = joinRendered(lines);
		assert.match(text, /review-fix/);
		assert.match(text, /merge-now/);
		assert.match(text, /terminal-state-reached/);
		assert.match(text, /CC-503/);
	} finally {
		cleanup();
	}
});

// ----- Overview tab ---------------------------------------------------------

test("Overview tab shows terminated banner with summary path after terminate", () => {
	const { snapshot, cleanup } = buildPostTerminateSnapshot();
	try {
		const lines = renderOverviewTab(snapshot, makeInitialPopupState(), 120, plainTheme() as never, 40, new Map());
		const text = joinRendered(lines);
		assert.match(text, /session complete/);
		assert.match(text, /2026-05-13T00:21:28Z/);
		assert.match(text, /tmp\/flightdeck-summary-HT-2026-05-13T002128Z\.md/);
		assert.match(text, /CC-503/);
	} finally {
		cleanup();
	}
});

// ----- edge cases: missing summary path / empty merges ---------------------

test("Conflicts & merges tab renders gracefully when no merges recorded", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		const payload = {
			conflict_graph: { computed_at: null, edges: [] },
			issues: { "X-1": { state: "aborted", harness: "claude" } },
			merge_queue: [],
			paused_for_user: null,
			started_at: "2026-05-12T22:00:00Z",
			terminated: true,
			terminated_at: "2026-05-13T00:21:28Z",
		};
		const live = join(tmpDir, "flightdeck-state-HT.json");
		writeFileSync(live, JSON.stringify(payload), "utf8");
		renameSync(live, join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"));
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		const text = joinRendered(renderConflictsTab(snapshot, makeInitialPopupState(), 120, plainTheme() as never));
		assert.match(text, /Merge history/);
		assert.match(text, /no merges recorded/);
	} finally {
		cleanup();
	}
});

test("dashboard renders archive-read-error banner when every candidate archive is malformed (BLOCK round 3)", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "{corrupt", "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		// Sanity: the snapshot itself is in the archive-error state.
		assert.equal(snapshot.master, undefined);
		assert.match(snapshot.masterError ?? "", /no readable terminated archive/);
		// Render the banner directly — the in-extension widget composes it
		// from the same fn when `flightdeckSessionStatus` returns
		// `archive-error`.
		const text = joinRendered(renderArchiveErrorBanner(snapshot, plainTheme() as never, 120));
		assert.match(text, /ARCHIVE READ ERROR/);
		assert.match(text, /no readable terminated archive/);
		assert.match(text, /\.json\.archive/);
		assert.ok(!/session complete/.test(text), "must NOT render the session-complete chip when archive is unreadable");
	} finally {
		cleanup();
	}
});

test("Overview tab renders gracefully when terminated archive lacks summary_path", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		const payload = {
			conflict_graph: { computed_at: null, edges: [] },
			issues: {
				"CC-503": {
					decisions_log: [],
					harness: "claude",
					pr_number: 81,
					state: "merged",
				},
			},
			merge_queue: [],
			paused_for_user: null,
			started_at: "2026-05-12T22:00:00Z",
			terminated: true,
			terminated_at: "2026-05-13T00:21:28Z",
		};
		const live = join(tmpDir, "flightdeck-state-HT.json");
		writeFileSync(live, JSON.stringify(payload), "utf8");
		renameSync(live, join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"));
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		const text = joinRendered(renderOverviewTab(snapshot, makeInitialPopupState(), 120, plainTheme() as never, 40, new Map()));
		assert.match(text, /session complete/);
		assert.ok(!/summary:/.test(text), "must not render summary: label when path is absent");
		assert.match(text, /CC-503/);
	} finally {
		cleanup();
	}
});
