// Phase 5 sessions-first render coverage. Compact render assertions act as
// snapshots without pinning ANSI/color noise: no sessions, ad-hoc, issue,
// mixed mode, owner visibility policy, and stale daemon state.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { afterEach, beforeEach } from "node:test";

import { dashboardVisibleInPane } from "../extensions/dashboard-visibility.js";
import {
	renderAwaitingWatchHintLine,
	renderDashboardLines,
	renderStateErrorBanner,
	renderStaleHintLine,
	type DashboardState,
} from "../extensions/flightdeck.js";
import { flightdeckSessionStatus, readAwaitingWatchTrackedEntries, type FlightdeckSnapshot, type TrackedSession } from "../extensions/state.js";

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

function stripAnsi(s: string): string {
	return s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, "").replace(/\x07/g, "");
}

function joinRendered(lines: string[]): string {
	return lines.map(stripAnsi).join("\n");
}

const SAVED_ENV: Record<string, string | undefined> = {};
let ENV_PI_DIR = "";
let ENV_HOME = "";
let ENV_CWD = "";

beforeEach(() => {
	for (const key of ["PI_CODING_AGENT_DIR", "HOME", "XDG_CONFIG_HOME", "USERPROFILE"]) {
		SAVED_ENV[key] = process.env[key];
	}
	ENV_PI_DIR = mkdtempSync(join(tmpdir(), "pi-flightdeck-sessions-piconf-"));
	ENV_HOME = mkdtempSync(join(tmpdir(), "pi-flightdeck-sessions-home-"));
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

function adhoc(overrides: Partial<TrackedSession> = {}): TrackedSession {
	return {
		decisions_log: [],
		harness: "pi",
		id: "adhoc-1",
		issue: "adhoc-1",
		kind: "adhoc",
		last_polled_at: "2026-05-13T00:10:00Z",
		pane_id: "%21",
		pane_target: "HT:adhoc.0",
		spawned_at: "2026-05-13T00:00:00Z",
		state: "ready",
		title: "Explore docs",
		...overrides,
	};
}

function issue(overrides: Partial<TrackedSession> = {}): TrackedSession {
	return {
		decisions_log: [{ answer: "merge", prompt_tag: "merge-now", ts: "2026-05-13T00:12:00Z" }],
		domain: {
			issue: {
				id: "CC-777",
				merge_commit: "abcdef1234567890",
				pr_number: 88,
				scope_files_actual: 3,
				scope_files_declared: 2,
				worktree: "/repo/wt/CC-777",
			},
		},
		harness: "claude",
		id: "CC-777",
		issue: "CC-777",
		kind: "issue",
		last_polled_at: "2026-05-13T00:12:00Z",
		pane_id: "%22",
		pane_target: "HT:CC-777.0",
		spawned_at: "2026-05-13T00:01:00Z",
		state: "merge-ready",
		title: "Fix bug",
		...overrides,
	};
}

function workflow(overrides: Partial<TrackedSession> = {}): TrackedSession {
	return {
		decisions_log: [],
		harness: "codex",
		id: "workflow-1",
		issue: "workflow-1",
		kind: "workflow",
		last_polled_at: "2026-05-13T00:14:00Z",
		pane_id: "%23",
		pane_target: "HT:workflow.0",
		spawned_at: "2026-05-13T00:02:00Z",
		state: "waiting",
		title: "Release workflow",
		...overrides,
	};
}

function snapshot(entries: TrackedSession[], overrides: Partial<FlightdeckSnapshot> = {}): FlightdeckSnapshot {
	const entryMap = Object.fromEntries(entries.map((entry) => [entry.id, entry]));
	const issueEntries = entries.filter((entry) => typeof entry.domain?.issue?.id === "string" && entry.domain.issue.id.trim());
	return {
		daemon: {
			heartbeatAgeSec: 1,
			heartbeatExists: true,
			pid: 1234,
			pidAlive: true,
			stateDir: "/tmp/pi-flightdeck-daemon",
			subscriberCounts: { claude: 0, codex: 0, opencode: 0, pi: 0 },
			subscribers: [],
		},
		master: {
			conflict_graph: { computed_at: null, edges: [] },
			entries: entryMap,
			issues: Object.fromEntries(issueEntries.map((entry) => [entry.domain?.issue?.id ?? entry.id, entry])),
			merge_queue: issueEntries.length > 0 ? ["CC-777"] : [],
			owner: { cwd: "/repo", harness: "pi", pane_id: "%1" },
			paused_for_user: null,
			session_id: "HT",
			started_at: "2026-05-13T00:00:00Z",
			terminated: false,
		},
		livePaneIds: new Set(entries.map((entry) => entry.pane_id).filter((paneId): paneId is string => typeof paneId === "string" && paneId.length > 0)),
		pendingEvents: [],
		stateDir: "/tmp/pi-flightdeck-daemon",
		tmux: { paneId: "%1", sessionId: "$1", sessionKey: "s1", sessionName: "HT" },
		wakeEvents: [],
		...overrides,
	};
}

function dashboardText(entries: TrackedSession[], state: DashboardState = "compact"): string {
	return joinRendered(renderDashboardLines(snapshot(entries), plainTheme() as never, 140, state, ENV_CWD, new Map()));
}

test("compact dashboard with no sessions renders header plus empty state", () => {
	const text = dashboardText([]);
	assert.match(text, /Flightdeck/);
	assert.match(text, /0 sessions/);
	assert.match(text, /No tracked sessions yet/);
});

test("one ad-hoc session renders AH badge, title-first label, and no issue metadata", () => {
	const text = dashboardText([adhoc()]);
	assert.match(text, /1 session/);
	assert.match(text, /AH\s+Explore docs/);
	assert.match(text, /ready/);
	assert.doesNotMatch(text, /issue/);
	assert.doesNotMatch(text, /PR#/);
	assert.doesNotMatch(text, /wt\s+/);
});

test("one issue session renders ISS badge and issue-domain child metadata", () => {
	const text = dashboardText([issue()], "expanded");
	assert.match(text, /1 session/);
	assert.match(text, /1 issue/);
	assert.match(text, /ISS\s+Fix bug/);
	assert.match(text, /PR#88/);
	assert.match(text, /wt\s+\/repo\/wt\/CC-777/);
	assert.match(text, /scope 3\/2/);
});

test("compact dashboard renders 'pane gone' chip when entry pane is missing from tmux", () => {
	const entry = adhoc({ pane_id: "%999" });
	const snap = snapshot([entry], { livePaneIds: new Set(["%1", "%2"]) });
	const text = joinRendered(renderDashboardLines(snap, plainTheme() as never, 140, "compact", ENV_CWD, new Map()));
	assert.match(text, /stale/);
	assert.match(text, /pane gone/);
	assert.match(text, /\/flightdeck/);
	assert.doesNotMatch(text, /ready/);
	assert.doesNotMatch(text, /prune/);
});

test("compact dashboard renders missing-pane active states as dim stale rows", () => {
	const entry = workflow({ pane_id: "%999", state: "waiting", substate: "pr-open" });
	const snap = snapshot([entry], { livePaneIds: new Set(["%1", "%2"]) });
	const text = joinRendered(renderDashboardLines(snap, plainTheme() as never, 140, "compact", ENV_CWD, new Map()));
	assert.match(text, /stale/);
	assert.match(text, /pane gone/);
	assert.doesNotMatch(text, /waiting/);
	assert.doesNotMatch(text, /pr-open/);
});

test("compact dashboard does NOT mark entry as gone when pane is alive", () => {
	const entry = adhoc({ pane_id: "%55" });
	const snap = snapshot([entry], { livePaneIds: new Set(["%55", "%1"]) });
	const text = joinRendered(renderDashboardLines(snap, plainTheme() as never, 140, "compact", ENV_CWD, new Map()));
	assert.doesNotMatch(text, /pane gone/);
});

test("compact dashboard does NOT mark entry as gone when livePaneIds is empty (unknown)", () => {
	// livePaneIds = empty Set means "unknown" (not inside tmux); never
	// flag entries as gone in this state.
	const entry = adhoc({ pane_id: "%999" });
	const snap = snapshot([entry], { livePaneIds: new Set() });
	const text = joinRendered(renderDashboardLines(snap, plainTheme() as never, 140, "compact", ENV_CWD, new Map()));
	assert.doesNotMatch(text, /pane gone/);
});

test("one issue session compact row renders ISS badge, title, and state", () => {
	const text = dashboardText([issue()]);
	assert.match(text, /1 session/);
	assert.match(text, /1 issue/);
	assert.match(text, /ISS\s+Fix bug/);
	assert.match(text, /merge-ready/);
});

test("one workflow session renders WF kind badge", () => {
	const text = dashboardText([workflow()]);
	assert.match(text, /1 session/);
	assert.match(text, /WF\s+Release workflow/);
	assert.match(text, /waiting/);
	assert.doesNotMatch(text, /1 issue/);
});

test("dashboard app self-entry is hidden from mini-dashboard sessions", () => {
	const text = dashboardText([workflow({ harness: "shell", id: "flightdeck-dashboard", issue: "flightdeck-dashboard", title: " FD" })]);
	assert.match(text, /0 sessions/);
	assert.doesNotMatch(text, / FD/);
});

test("domain.issue metadata promotes corrupted kind to issue mode", () => {
	const corrupted = issue({ kind: "broken" });
	const text = dashboardText([corrupted]);
	assert.match(text, /1 issue/);
	assert.match(text, /ISS\s+Fix bug/);
});

test("mixed ad-hoc plus issue sessions show session total plus issue count", () => {
	const text = dashboardText([adhoc(), issue()]);
	assert.match(text, /2 sessions/);
	assert.match(text, /1 issue/);
	assert.match(text, /AH\s+Explore docs/);
	assert.match(text, /ISS\s+Fix bug/);
	assert.match(text, /PR#88/);
});

test("owner pane renders dashboard while peer pane is suppressed by owner visibility", () => {
	assert.equal(dashboardVisibleInPane({ currentPaneId: "%1", ownerPaneId: "%1", visibility: "owner" }), true);
	assert.equal(dashboardVisibleInPane({ currentPaneId: "%2", ownerPaneId: "%1", visibility: "owner" }), false);
});

test("stale daemon renders stale session-state copy", () => {
	// Daemon WAS started (heartbeat file exists, pid recorded) but is
	// now dead and stale — distinguishes from a never-started daemon
	// (`awaiting-watch`).
	const snap = snapshot([adhoc({ last_polled_at: "2026-05-13T00:00:00Z" })], {
		daemon: {
			heartbeatExists: true,
			heartbeatAgeSec: 1800,
			pid: 9999,
			pidAlive: false,
			stateDir: "/tmp/pi-flightdeck-daemon",
			subscriberCounts: { claude: 0, codex: 0, opencode: 0, pi: 0 },
			subscribers: [],
		},
	});
	assert.equal(flightdeckSessionStatus(snap, { now: Date.parse("2026-05-13T00:30:00Z") }), "stale");
	const text = joinRendered(renderStaleHintLine(snap, plainTheme() as never, 120));
	assert.match(text, /session state from/);
	assert.match(text, /daemon stopped/);
	assert.doesNotMatch(text, /issue tree/);
});

test("live master-state parse errors render a state-error banner", () => {
	const snap = snapshot([], {
		master: undefined,
		masterError: "Unexpected token n in JSON at position 1",
		masterStatePath: "/repo/tmp/flightdeck-state-HT.json",
	});
	assert.equal(flightdeckSessionStatus(snap), "state-error");
	const text = joinRendered(renderStateErrorBanner(snap, plainTheme() as never, 140));
	assert.match(text, /FLIGHTDECK STATE ERROR/);
	assert.match(text, /flightdeck-state-HT\.json/);
	assert.match(text, /Unexpected token/);
});

test("never-started daemon classifies as awaiting-watch, not stale", () => {
	const snap = snapshot([adhoc({ last_polled_at: "2026-05-13T00:00:00Z" })], {
		daemon: {
			heartbeatExists: false,
			pid: undefined,
			pidAlive: false,
			stateDir: "/tmp/pi-flightdeck-daemon",
			subscriberCounts: { claude: 0, codex: 0, opencode: 0, pi: 0 },
			subscribers: [],
		},
	});
	assert.equal(flightdeckSessionStatus(snap, { now: Date.parse("2026-05-13T00:30:00Z") }), "awaiting-watch");
});

test("awaiting-watch ignores tracked sessions whose pane ids are stale", () => {
	const snap = snapshot([adhoc({ last_polled_at: "2026-05-13T00:00:00Z", pane_id: "%999" })], {
		daemon: {
			heartbeatExists: false,
			pid: undefined,
			pidAlive: false,
			stateDir: "/tmp/pi-flightdeck-daemon",
			subscriberCounts: { claude: 0, codex: 0, opencode: 0, pi: 0 },
			subscribers: [],
		},
		livePaneIds: new Set(["%1", "%2"]),
	});

	assert.equal(readAwaitingWatchTrackedEntries(snap).length, 0);
	assert.equal(flightdeckSessionStatus(snap, { now: Date.parse("2026-05-13T00:30:00Z") }), "inactive");
	const text = joinRendered(renderAwaitingWatchHintLine(snap, plainTheme() as never, 120));
	assert.match(text, /0 tracked sessions/);
	assert.doesNotMatch(text, /1 tracked session/);
});
