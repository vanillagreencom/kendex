// Phase 0 owner-gating coverage. These tests mock the current tmux pane id
// through the snapshot (same source `resolveTmuxContext` uses in production)
// and prove the persistent dashboard renders only under the configured
// dashboardVisibility policy. Child-pane suppression remains a separate hard
// gate even when visibility is set to `always`.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { afterEach, beforeEach } from "node:test";
import {
	dashboardVisibleForSnapshot,
	dashboardVisibleInPane,
	type DashboardVisibility,
	isInFlightdeckChildPane,
	isFlightdeckObserverPane,
	renderObserverHeader,
} from "../extensions/dashboard-visibility.js";
import { renderDashboardLines } from "../extensions/flightdeck.js";
import type { FlightdeckSnapshot } from "../extensions/state.js";

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
let ENV_HOME = "";
let ENV_PI_DIR = "";
let ENV_CWD = "";

beforeEach(() => {
	for (const key of ["PI_CODING_AGENT_DIR", "HOME", "XDG_CONFIG_HOME", "USERPROFILE", "FLIGHTDECK_CHILD_PANE", "PI_SUBAGENT_CHILD_AGENT"]) {
		SAVED_ENV[key] = process.env[key];
	}
	ENV_HOME = mkdtempSync(join(tmpdir(), "pi-flightdeck-visibility-home-"));
	ENV_PI_DIR = mkdtempSync(join(tmpdir(), "pi-flightdeck-visibility-piconf-"));
	ENV_CWD = mkdtempSync(join(ENV_HOME, "isolated-cwd-"));
	process.env.HOME = ENV_HOME;
	process.env.PI_CODING_AGENT_DIR = ENV_PI_DIR;
	process.env.XDG_CONFIG_HOME = ENV_HOME;
	process.env.USERPROFILE = ENV_HOME;
});

afterEach(() => {
	for (const [key, value] of Object.entries(SAVED_ENV)) {
		if (value === undefined) delete process.env[key];
		else process.env[key] = value;
	}
	if (ENV_HOME) rmSync(ENV_HOME, { force: true, recursive: true });
	if (ENV_PI_DIR) rmSync(ENV_PI_DIR, { force: true, recursive: true });
});

function snapshot(currentPaneId: string, ownerPaneId: string): FlightdeckSnapshot {
	return {
		daemon: {
			heartbeatExists: false,
			pidAlive: true,
			stateDir: "/tmp/pi-flightdeck-daemon",
			subscriberCounts: { claude: 0, codex: 0, opencode: 0, pi: 0 },
			subscribers: [],
		},
		master: {
			conflict_graph: { computed_at: null, edges: [] },
			entries: {
				"CC-001": {
					domain: { issue: { id: "CC-001", pr_number: 101 } },
					harness: "pi",
					id: "CC-001",
					issue: "CC-001",
					kind: "issue",
					last_polled_at: "2026-05-13T00:00:00Z",
					pane_id: "%33",
					spawned_at: "2026-05-13T00:00:00Z",
					state: "waiting",
					title: "CC-001",
				},
			},
			issues: {},
			merge_queue: [],
			owner: {
				cwd: "/repo",
				harness: "pi",
				pane_id: ownerPaneId,
				pane_target: "HT:1.0",
				pid: 4242,
				pi_bridge_socket: "/tmp/pi.sock",
				pi_session_id: "pi-session-owner",
			},
			paused_for_user: null,
			session_id: "HT",
			started_at: "2026-05-13T00:00:00Z",
			terminated: false,
		},
		livePaneIds: new Set(["%33"]),
		pendingEvents: [],
		stateDir: "/tmp/pi-flightdeck-daemon",
		tmux: { paneId: currentPaneId, sessionId: "$1", sessionKey: "s1", sessionName: "HT" },
		wakeEvents: [],
	};
}

function renderIfVisible(visibility: DashboardVisibility, currentPaneId: string, ownerPaneId: string, inChildPane = false): string[] {
	const snap = snapshot(currentPaneId, ownerPaneId);
	if (!dashboardVisibleInPane({ currentPaneId: snap.tmux.paneId, inChildPane, ownerPaneId: snap.master?.owner?.pane_id, visibility })) return [];
	return renderDashboardLines(snap, plainTheme() as never, 120, "compact", ENV_CWD, new Map());
}

test("dashboardVisibility=owner renders when current pane matches owner pane", () => {
	const text = joinRendered(renderIfVisible("owner", "%42", "%42"));
	assert.match(text, /Flightdeck/);
	assert.match(text, /CC-001/);
});

test("dashboardVisibility=owner suppresses when current pane differs from owner pane", () => {
	const lines = renderIfVisible("owner", "%99", "%42");
	assert.deepEqual(lines, []);
	assert.equal(isFlightdeckObserverPane(snapshot("%99", "%42")), true);
	assert.match(renderObserverHeader(snapshot("%99", "%42"), plainTheme() as never, 120) ?? "", /Observer view \(owner: %42 · \/repo\)/);
});

test("dashboardVisibility=tmux-session renders in a non-owner pane", () => {
	const text = joinRendered(renderIfVisible("tmux-session", "%99", "%42"));
	assert.match(text, /Flightdeck/);
	assert.match(text, /CC-001/);
});

test("dashboardVisibility=tmux-session renders in owner pane", () => {
	const text = joinRendered(renderIfVisible("tmux-session", "%42", "%42"));
	assert.match(text, /Flightdeck/);
	assert.match(text, /CC-001/);
});

test("dashboardVisibility=always renders in a non-owner pane", () => {
	const text = joinRendered(renderIfVisible("always", "%99", "%42"));
	assert.match(text, /Flightdeck/);
	assert.match(text, /CC-001/);
});

test("dashboardVisibility=always renders in owner pane", () => {
	const text = joinRendered(renderIfVisible("always", "%42", "%42"));
	assert.match(text, /Flightdeck/);
	assert.match(text, /CC-001/);
});

test("child-pane suppression remains a separate hard gate", () => {
	const lines = renderIfVisible("always", "%99", "%42", true);
	assert.deepEqual(lines, []);
});

test("FLIGHTDECK_CHILD_PANE env var suppresses through production child-pane detection", () => {
	process.env.FLIGHTDECK_CHILD_PANE = "1";
	const snap = snapshot("%99", "%42");
	assert.equal(isInFlightdeckChildPane(), true);
	assert.equal(dashboardVisibleForSnapshot(snap, "always"), false);
});

test("PI_SUBAGENT_CHILD_AGENT env var suppresses through production child-pane detection", () => {
	process.env.PI_SUBAGENT_CHILD_AGENT = "1";
	const snap = snapshot("%99", "%42");
	assert.equal(isInFlightdeckChildPane(), true);
	assert.equal(dashboardVisibleForSnapshot(snap, "always"), false);
});
