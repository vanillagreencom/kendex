// Render-output coverage for completed sessions after pi-flightdeck became a
// status shell. Terminated archives remain readable state, but the inline
// mini-dashboard is active-run-only and must not show completed history by
// default.

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { afterEach, beforeEach } from "node:test";
import { renderDashboardLines } from "../extensions/flightdeck.js";
import { renderArchiveErrorBanner } from "../extensions/render-terminated.js";
import {
	buildSnapshotFromInputs,
	flightdeckSessionStatus,
	type FlightdeckSnapshot,
	type SettingsLike,
	type TmuxContext,
} from "../extensions/state.js";

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

const SETTINGS: SettingsLike = { flightdeckStateDir: "tmp", stateDir: "" };
const TMUX: TmuxContext = { paneId: "%1", sessionId: "$1", sessionKey: "s1", sessionName: "HT" };
const SAVED_ENV: Record<string, string | undefined> = {};
let ENV_PI_DIR = "";
let ENV_HOME = "";

beforeEach(() => {
	for (const key of ["PI_CODING_AGENT_DIR", "HOME", "XDG_CONFIG_HOME", "USERPROFILE"]) {
		SAVED_ENV[key] = process.env[key];
	}
	ENV_PI_DIR = mkdtempSync(join(tmpdir(), "pi-flightdeck-render-piconf-"));
	ENV_HOME = mkdtempSync(join(tmpdir(), "pi-flightdeck-render-home-"));
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

function mergedIssueEntry(id: string): Record<string, unknown> {
	return {
		decisions_log: [{ answer: "merged", prompt_tag: "terminal-state-reached", ts: "2026-05-13T00:15:35Z" }],
		domain: { issue: { id, merge_commit: "156d9df02ce8fb3a798f233c73e489338db969f9", pr_number: 81 } },
		harness: "claude",
		id,
		kind: "issue",
		last_polled_at: "2026-05-13T00:15:35Z",
		spawned_at: "2026-05-12T23:00:00Z",
		state: "merged",
		title: id,
		window: id,
	};
}

function simulateTerminate(tmpDir: string): string {
	const payload = {
		conflict_graph: { computed_at: null, edges: [] },
		entries: { "CC-503": mergedIssueEntry("CC-503") },
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

test("terminated archive is preserved but mini-dashboard status is inactive", () => {
	const { snapshot, cleanup } = buildPostTerminateSnapshot();
	try {
		assert.equal(snapshot.master?.terminated, true);
		assert.equal(flightdeckSessionStatus(snapshot), "inactive");
	} finally {
		cleanup();
	}
});

test("direct dashboard renderer can still render preserved terminated archive data", () => {
	const { snapshot, cleanup } = buildPostTerminateSnapshot();
	try {
		const text = joinRendered(renderDashboardLines(snapshot, plainTheme() as never, 120, "compact", process.cwd(), new Map()));
		assert.match(text, /session complete/);
		assert.match(text, /CC-503/);
		assert.match(text, /PR#81/);
	} finally {
		cleanup();
	}
});

test("dashboard renders archive-read-error banner when every candidate archive is malformed", () => {
	const { projectRoot, stateDir, tmpDir, cleanup } = makeProject();
	try {
		writeFileSync(join(tmpDir, "flightdeck-state-HT-20260513T002128Z.json.archive"), "{corrupt", "utf8");
		const snapshot = buildSnapshotFromInputs({ projectRoot, stateDir, tmux: TMUX }, SETTINGS);
		assert.equal(snapshot.master, undefined);
		assert.match(snapshot.masterError ?? "", /no readable terminated archive/);
		const text = joinRendered(renderArchiveErrorBanner(snapshot, plainTheme() as never, 120));
		assert.match(text, /ARCHIVE READ ERROR/);
		assert.match(text, /no readable terminated archive/);
		assert.match(text, /\.json\.archive/);
		assert.ok(!/session complete/.test(text), "must NOT render the session-complete chip when archive is unreadable");
	} finally {
		cleanup();
	}
});
