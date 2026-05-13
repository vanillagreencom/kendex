// Parity test: pane-registry (bash) vs pane-registry (TS).
// Runs inside the active tmux session (TMUX env must be set).

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/pane-registry");

if (!process.env.TMUX) {
	test.skip("pane-registry parity requires tmux", () => undefined);
}

function makeRepo(): string {
	const dir = mkdtempSync(join(tmpdir(), "fdreg-parity-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
	});
	return dir;
}

function run(useTs: boolean, cwd: string, args: string[]): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	if (useTs) {
		env.FLIGHTDECK_USE_TS_PANE_REGISTRY = "1";
		// pane-registry calls flightdeck-state — propagate the TS flip so we
		// exercise the full TS path including state CRUD.
		env.FLIGHTDECK_USE_TS_FLIGHTDECK_STATE = "1";
	} else {
		delete env.FLIGHTDECK_USE_TS_PANE_REGISTRY;
		delete env.FLIGHTDECK_USE_TS_FLIGHTDECK_STATE;
	}
	delete env.FLIGHTDECK_USE_TS;
	env.FLIGHTDECK_STATE_DIR = "tmp";
	const r = spawnSync(SCRIPT, args, { cwd, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function readIssues(repo: string, session = process.env.TMUX_PARITY_SESSION ?? sessionName()): unknown {
	const file = join(repo, "tmp", `flightdeck-state-${session}.json`);
	return JSON.parse(readFileSync(file, "utf8")).issues;
}

function readEntries(repo: string, session = process.env.TMUX_PARITY_SESSION ?? sessionName()): unknown {
	const file = join(repo, "tmp", `flightdeck-state-${session}.json`);
	return JSON.parse(readFileSync(file, "utf8")).entries;
}

function sessionName(): string {
	const r = spawnSync("tmux", ["display-message", "-p", "#S"], { encoding: "utf8" });
	return (r.stdout ?? "").trim();
}

function normalize(issues: unknown): unknown {
	const out: Record<string, Record<string, unknown>> = {};
	for (const [k, v] of Object.entries(issues as Record<string, Record<string, unknown>>)) {
		const copy: Record<string, unknown> = { ...v };
		// timestamps differ between runs
		if (typeof copy.spawned_at === "string") copy.spawned_at = "<ISO>";
		if (typeof copy.last_polled_at === "string") copy.last_polled_at = "<ISO>";
		// pane_id is resolved from tmux — only present when the target pane
		// actually exists. Test windows are fake, so both should be null.
		out[k] = copy;
	}
	return out;
}

let bashRepo = "";
let tsRepo = "";

beforeEach(() => {
	bashRepo = makeRepo();
	tsRepo = makeRepo();
});

afterEach(() => {
	for (const d of [bashRepo, tsRepo]) {
		if (d && existsSync(d)) rmSync(d, { force: true, recursive: true });
	}
});

describe("pane-registry parity", () => {
	test("init writes identical issue record (fake pane)", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const r = run(useTs, repo, [
				"init", "FAKE-001",
				"--window", "fake-window",
				"--harness", "opencode",
				"--worktree", "/tmp/wt",
			]);
			expect(r.status).toBe(0);
		}
		expect(normalize(readIssues(tsRepo))).toEqual(normalize(readIssues(bashRepo)));
	});

	test("set-state writes valid state", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init", "FAKE-002", "--window", "w2", "--harness", "claude", "--worktree", "/tmp/wt"]);
			const r = run(useTs, repo, ["set-state", "FAKE-002", "prompting"]);
			expect(r.status).toBe(0);
		}
		expect(normalize(readIssues(tsRepo))).toEqual(normalize(readIssues(bashRepo)));
	});

	test("set-state rejects invalid state", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init", "FAKE-003", "--window", "w3", "--harness", "pi", "--worktree", "/tmp/wt"]);
			const r = run(useTs, repo, ["set-state", "FAKE-003", "nonsense"]);
			expect(r.status).toBe(2);
		}
	});

	test("log-decision appends to decisions_log", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init", "FAKE-004", "--window", "w4", "--harness", "codex", "--worktree", "/tmp/wt"]);
			run(useTs, repo, ["log-decision", "FAKE-004", "merge-now", "answered Yes"]);
			run(useTs, repo, ["log-decision", "FAKE-004", "cleanup-prompt", "answered No"]);
		}
		const bIssues = readIssues(bashRepo) as Record<string, { decisions_log: Array<Record<string, unknown>> }>;
		const tIssues = readIssues(tsRepo) as Record<string, { decisions_log: Array<Record<string, unknown>> }>;
		expect(tIssues["FAKE-004"]!.decisions_log.length).toBe(2);
		expect(bIssues["FAKE-004"]!.decisions_log.length).toBe(2);
		// Normalize timestamps
		const norm = (e: Array<Record<string, unknown>>) =>
			e.map((row) => ({ ...row, ts: "<ISO>" }));
		expect(norm(tIssues["FAKE-004"]!.decisions_log)).toEqual(norm(bIssues["FAKE-004"]!.decisions_log));
	});

	test("get returns the issue record; missing → exit 1", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init", "FAKE-005", "--window", "w5", "--harness", "opencode", "--worktree", "/tmp/wt"]);
		}
		const a = run(false, bashRepo, ["get", "FAKE-005"]);
		const b = run(true, tsRepo, ["get", "FAKE-005"]);
		expect(b.status).toBe(0);
		expect(a.status).toBe(0);
		const miss = run(true, tsRepo, ["get", "DOESNT-EXIST"]);
		expect(miss.status).toBe(1);
	});

	test("list --format inner-panes returns CSV of pane_targets", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init", "AAA-001", "--window", "wA", "--harness", "opencode", "--worktree", "/tmp/wt"]);
			run(useTs, repo, ["init", "BBB-002", "--window", "wB", "--harness", "claude", "--worktree", "/tmp/wt"]);
		}
		const a = run(false, bashRepo, ["list", "--format", "inner-panes"]);
		const b = run(true, tsRepo, ["list", "--format", "inner-panes"]);
		expect(b.stdout.trim().split(",").sort()).toEqual(a.stdout.trim().split(",").sort());
	});

	test("init-entry writes normalized adhoc entry without legacy issue projection", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const r = run(useTs, repo, [
				"init-entry", "adhoc.one",
				"--title", "Scratch Session",
				"--kind", "adhoc",
				"--cwd", "/tmp/scratch",
				"--window", "7",
				"--harness", "pi",
				"--pane-target", "test:7.0",
				"--pane-id", "%777",
			]);
			expect(r.status).toBe(0);
		}
		const bEntries = readEntries(bashRepo) as Record<string, Record<string, unknown>>;
		const tEntries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		expect(tEntries["adhoc.one"]!.kind).toBe("adhoc");
		expect(tEntries["adhoc.one"]!.pane_id).toBe("%777");
		expect(normalize(tEntries)).toEqual(normalize(bEntries));
		expect(readIssues(tsRepo)).toEqual({});
		expect(readIssues(bashRepo)).toEqual({});
	});

	test("init-entry kind=issue dual-writes .entries and .issues", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const r = run(useTs, repo, [
				"init-entry", "ISSUE-42",
				"--title", "Issue 42",
				"--kind", "issue",
				"--cwd", "/tmp/wt42",
				"--window", "issue-42",
				"--harness", "opencode",
				"--worktree", "/tmp/wt42",
				"--pr", "42",
			]);
			expect(r.status).toBe(0);
		}
		const bIssues = readIssues(bashRepo) as Record<string, Record<string, unknown>>;
		const tIssues = readIssues(tsRepo) as Record<string, Record<string, unknown>>;
		const tEntries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		expect(tEntries["ISSUE-42"]!.kind).toBe("issue");
		expect(tIssues["ISSUE-42"]!.pr_number).toBe(42);
		expect(normalize(tIssues)).toEqual(normalize(bIssues));
	});

	test("list --format json returns normalized entries with legacy issue fields", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init-entry", "adhoc-json", "--title", "Adhoc", "--kind", "adhoc", "--cwd", "/tmp/a", "--window", "10", "--harness", "pi", "--pane-id", "%10"]);
			run(useTs, repo, ["init", "JSON-9", "--window", "json-9", "--harness", "codex", "--worktree", "/tmp/json-9", "--pr", "9"]);
		}
		const a = JSON.parse(run(false, bashRepo, ["list", "--format", "json"]).stdout) as Array<Record<string, unknown>>;
		const b = JSON.parse(run(true, tsRepo, ["list", "--format", "json"]).stdout) as Array<Record<string, unknown>>;
		const normRows = (rows: Array<Record<string, unknown>>) => rows.map((row) => ({
			id: row.id,
			issue: row.issue,
			kind: row.kind,
			pane_id: row.pane_id,
			pr_number: row.pr_number,
			worktree: row.worktree,
		})).sort((x, y) => String(x.id).localeCompare(String(y.id)));
		expect(normRows(b)).toEqual(normRows(a));
		expect(normRows(b)).toContainEqual({ id: "JSON-9", issue: "JSON-9", kind: "issue", pane_id: null, pr_number: 9, worktree: "/tmp/json-9" });
		expect(normRows(b)).toContainEqual({ id: "adhoc-json", issue: null, kind: "adhoc", pane_id: "%10", pr_number: null, worktree: "/tmp/a" });
	});

	test("init-entry rejects bad input with parity", () => {
		const cases = [
			{ args: ["init-entry"], stderr: "Usage: pane-registry init-entry" },
			{ args: ["init-entry", "BAD-KIND", "--title", "Bad", "--kind", "bogus", "--cwd", "/tmp/bad", "--window", "1", "--harness", "pi"], stderr: "init-entry requires --kind" },
			{ args: ["init-entry", "NO-CWD", "--title", "Missing", "--kind", "adhoc", "--window", "1", "--harness", "pi"], stderr: "init-entry requires --title" },
			{ args: ["init-entry", "NO-HARNESS", "--title", "Missing", "--kind", "adhoc", "--cwd", "/tmp/missing", "--window", "1"], stderr: "init-entry requires --title" },
		];
		for (const c of cases) {
			const bash = run(false, bashRepo, c.args);
			const ts = run(true, tsRepo, c.args);
			expect(ts.status).toBe(2);
			expect(bash.status).toBe(2);
			expect(ts.stderr).toContain(c.stderr);
			expect(bash.stderr).toContain(c.stderr);
		}
	});

	test("find-by-pane resolves an issue", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, {
				panes: {
					"%210": { pane_index: 0, path: "/tmp/wt", window_id: "@21", window_index: 21, window_name: "wF" },
				},
				session: "test-session",
				windows: { "@21": { index: 21, name: "wF" } },
			});
			runShim(useTs, repo, statePath, ["init", "FBP-001", "--window", "21", "--harness", "pi", "--worktree", "/tmp/wt", "--pane-index", "0"]);
		}
		const target = "test-session:21.0";
		const a = runShim(false, bashRepo, join(bashRepo, "shim-state.json"), ["find-by-pane", target]);
		const b = runShim(true, tsRepo, join(tsRepo, "shim-state.json"), ["find-by-pane", target]);
		expect(JSON.parse(b.stdout)).toEqual({ id: "FBP-001", kind: "issue" });
		expect(JSON.parse(a.stdout)).toEqual({ id: "FBP-001", kind: "issue" });
	});

	test("find-by-pane resolves entry rows and legacy issue rows", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, {
				panes: {
					"%110": { pane_index: 0, path: "/tmp/a", window_id: "@11", window_index: 11, window_name: "adhoc" },
					"%120": { pane_index: 0, path: "/tmp/l", window_id: "@12", window_index: 12, window_name: "legacy" },
				},
				session: "test-session",
				windows: { "@11": { index: 11, name: "adhoc" }, "@12": { index: 12, name: "legacy" } },
			});
			runShim(useTs, repo, statePath, ["init-entry", "adhoc-fbp", "--title", "Adhoc FBP", "--kind", "adhoc", "--cwd", "/tmp/a", "--window", "11", "--harness", "pi", "--pane-id", "%110", "--pane-target", "test-session:11.0"]);
			runShim(useTs, repo, statePath, ["init", "LEGACY-1", "--window", "12", "--harness", "pi", "--worktree", "/tmp/l", "--pane-index", "0"]);
		}
		expect(JSON.parse(runShim(false, bashRepo, join(bashRepo, "shim-state.json"), ["find-by-pane", "%110"]).stdout)).toEqual({ id: "adhoc-fbp", kind: "adhoc" });
		expect(JSON.parse(runShim(true, tsRepo, join(tsRepo, "shim-state.json"), ["find-by-pane", "%110"]).stdout)).toEqual({ id: "adhoc-fbp", kind: "adhoc" });
		expect(JSON.parse(runShim(false, bashRepo, join(bashRepo, "shim-state.json"), ["find-by-pane", "test-session:12.0"]).stdout)).toEqual({ id: "LEGACY-1", kind: "issue" });
		expect(JSON.parse(runShim(true, tsRepo, join(tsRepo, "shim-state.json"), ["find-by-pane", "test-session:12.0"]).stdout)).toEqual({ id: "LEGACY-1", kind: "issue" });
	});

	test("find-by-pane treats stale pane_id as no match and warns", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, baseShim("test-session"));
			runShim(useTs, repo, statePath, ["init-entry", "stale-fbp", "--title", "Stale", "--kind", "adhoc", "--cwd", "/tmp/stale", "--window", "99", "--harness", "pi", "--pane-id", "%999", "--pane-target", "test-session:99.0"]);
			const r = runShim(useTs, repo, statePath, ["find-by-pane", "%999"]);
			expect(r.status).toBe(1);
			expect(r.stdout).toBe("");
			expect(r.stderr).toContain("Warning: find-by-pane match %999 is stale");
		}
	});

	test("remove drops the issue from .issues", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init", "RM-001", "--window", "wR", "--harness", "opencode", "--worktree", "/tmp/wt"]);
			const r = run(useTs, repo, ["remove", "RM-001"]);
			expect(r.status).toBe(0);
		}
		expect(readIssues(tsRepo)).toEqual({});
		expect(readIssues(bashRepo)).toEqual({});
	});
});

// --- teardown-window + reconcile (#16) ------------------------------------
//
// These tests run pane-registry against a deterministic tmux shim instead
// of the live tmux server (reviewer BLOCKER #4: don't create/split/kill
// real windows in CI). The shim is a bash script that reads/writes a JSON
// state file; PATH-prepending its directory makes both the bash and TS
// implementations resolve `tmux` to the shim. Each test owns its own
// state file, so runs are isolated.

const SHIM_DIR = resolve(HERE, "./tmux-shim");

interface ShimPane {
	window_id: string;
	window_name: string;
	path: string;
	window_index: number;
	pane_index: number;
}

interface ShimState {
	session: string;
	panes: Record<string, ShimPane>;
	windows: Record<string, { name: string; index: number }>;
}

function makeShimState(repo: string, state: ShimState): string {
	const path = join(repo, "shim-state.json");
	spawnSync("mkdir", ["-p", repo]);
	require("node:fs").writeFileSync(path, JSON.stringify(state, null, 2));
	return path;
}

function readShimState(path: string): ShimState {
	return JSON.parse(require("node:fs").readFileSync(path, "utf8"));
}

function runShim(useTs: boolean, repo: string, statePath: string, args: string[], extraEnv: Record<string, string> = {}): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	if (useTs) {
		env.FLIGHTDECK_USE_TS_PANE_REGISTRY = "1";
		env.FLIGHTDECK_USE_TS_FLIGHTDECK_STATE = "1";
	} else {
		delete env.FLIGHTDECK_USE_TS_PANE_REGISTRY;
		delete env.FLIGHTDECK_USE_TS_FLIGHTDECK_STATE;
	}
	delete env.FLIGHTDECK_USE_TS;
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.PATH = `${SHIM_DIR}:${env.PATH ?? ""}`;
	env.TMUX_SHIM_STATE = statePath;
	env.TMUX_PARITY_SESSION = readShimState(statePath).session;
	for (const [k, v] of Object.entries(extraEnv)) env[k] = v;
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function stateFilePath(repo: string, session: string): string {
	return join(repo, "tmp", `flightdeck-state-${session}.json`);
}

function baseShim(session: string, extras: Partial<ShimState> = {}): ShimState {
	return {
		panes: {},
		session,
		windows: {},
		...extras,
	};
}

describe("pane-registry teardown-window (#16, shim-driven)", () => {
	test("pane_id alive + terminal + single-pane window → kills the window", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, {
				panes: {
					"%100": { pane_index: 0, path: "/tmp/wt-a", window_id: "@10", window_index: 1, window_name: "issue-a" },
				},
				session: "test-session",
				windows: { "@10": { index: 1, name: "issue-a" } },
			});
			runShim(useTs, repo, statePath, ["init", "TD-1", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(useTs, repo, statePath, ["set", "TD-1", "pane_id", JSON.stringify("%100")]);
			runShim(useTs, repo, statePath, ["set-state", "TD-1", "merged"]);
			const r = runShim(useTs, repo, statePath, ["teardown-window", "TD-1"]);
			expect(r.status).toBe(0);
			const state = readShimState(statePath);
			expect(state.panes["%100"]).toBeUndefined();
			expect(state.windows["@10"]).toBeUndefined();
		}
	});

	test("pane_id alive + terminal + multi-pane window → kills only the pane", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, {
				panes: {
					"%100": { pane_index: 0, path: "/tmp/wt-a", window_id: "@10", window_index: 1, window_name: "issue-a" },
					"%101": { pane_index: 1, path: "/tmp/wt-a", window_id: "@10", window_index: 1, window_name: "issue-a" },
				},
				session: "test-session",
				windows: { "@10": { index: 1, name: "issue-a" } },
			});
			runShim(useTs, repo, statePath, ["init", "TD-2", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(useTs, repo, statePath, ["set", "TD-2", "pane_id", JSON.stringify("%100")]);
			runShim(useTs, repo, statePath, ["set-state", "TD-2", "merged"]);
			const r = runShim(useTs, repo, statePath, ["teardown-window", "TD-2"]);
			expect(r.status).toBe(0);
			const state = readShimState(statePath);
			expect(state.panes["%100"]).toBeUndefined();
			expect(state.panes["%101"]).toBeDefined();
			expect(state.windows["@10"]).toBeDefined();
		}
	});

	for (const terminal of ["merged", "aborted", "dead"]) {
		test(`pane_id gone + state=${terminal} → no-op success`, () => {
			for (const repo of [bashRepo, tsRepo]) {
				const useTs = repo === tsRepo;
				const statePath = makeShimState(repo, baseShim("test-session"));
				runShim(useTs, repo, statePath, ["init", "TD-3", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
				runShim(useTs, repo, statePath, ["set", "TD-3", "pane_id", JSON.stringify("%999999")]);
				runShim(useTs, repo, statePath, ["set-state", "TD-3", terminal]);
				const r = runShim(useTs, repo, statePath, ["teardown-window", "TD-3"]);
				expect(r.status).toBe(0);
				expect(r.stdout).toContain("already closed");
			}
		});
	}

	test("pane_id gone + non-terminal state → exit 3 (registry drift)", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, baseShim("test-session"));
			runShim(useTs, repo, statePath, ["init", "TD-4", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(useTs, repo, statePath, ["set", "TD-4", "pane_id", JSON.stringify("%999998")]);
			// state remains "waiting".
			const r = runShim(useTs, repo, statePath, ["teardown-window", "TD-4"]);
			expect(r.status).toBe(3);
			expect(r.stderr).toContain("registry drift");
		}
	});

	test("pane_id alive + non-terminal state → exit 4 (policy refusal); --force kills", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, {
				panes: {
					"%100": { pane_index: 0, path: "/tmp/wt-a", window_id: "@10", window_index: 1, window_name: "issue-a" },
				},
				session: "test-session",
				windows: { "@10": { index: 1, name: "issue-a" } },
			});
			runShim(useTs, repo, statePath, ["init", "TD-FORCE", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(useTs, repo, statePath, ["set", "TD-FORCE", "pane_id", JSON.stringify("%100")]);
			// state stays "waiting".
			const r1 = runShim(useTs, repo, statePath, ["teardown-window", "TD-FORCE"]);
			expect(r1.status).toBe(4);
			expect(r1.stderr).toContain("policy refusal");
			// Pane still alive after refusal.
			expect(readShimState(statePath).panes["%100"]).toBeDefined();
			const r2 = runShim(useTs, repo, statePath, ["teardown-window", "TD-FORCE", "--force"]);
			expect(r2.status).toBe(0);
			expect(readShimState(statePath).panes["%100"]).toBeUndefined();
		}
	});

	test("unknown issue → exit 1 (idempotent, distinct from read-failure)", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, baseShim("test-session"));
			const r = runShim(useTs, repo, statePath, ["teardown-window", "DOES-NOT-EXIST"]);
			expect(r.status).toBe(1);
			expect(r.stderr).toContain("not found in registry");
		}
	});

	test("teardown-entry is an alias for teardown-window", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, baseShim("test-session"));
			runShim(useTs, repo, statePath, ["init", "TD-ALIAS", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(useTs, repo, statePath, ["set", "TD-ALIAS", "pane_id", JSON.stringify("%999990")]);
			runShim(useTs, repo, statePath, ["set-state", "TD-ALIAS", "aborted"]);
			const r = runShim(useTs, repo, statePath, ["teardown-entry", "TD-ALIAS"]);
			expect(r.status).toBe(0);
			expect(r.stdout).toContain("already closed");
		}
	});

	test("tmux kill fails and pane stays alive → exit 5", () => {
		// Reviewer BLOCKER: drive the shim to refuse kill-window/kill-pane
		// (non-zero exit + state unchanged). Post-kill liveness check sees
		// the pane is still listed and escalates instead of falsely
		// returning success.
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, {
				panes: {
					"%900": { pane_index: 0, path: "/tmp/wt-a", window_id: "@90", window_index: 1, window_name: "issue-a" },
				},
				session: "test-session",
				windows: { "@90": { index: 1, name: "issue-a" } },
			});
			runShim(useTs, repo, statePath, ["init", "TD-KILLFAIL", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(useTs, repo, statePath, ["set", "TD-KILLFAIL", "pane_id", JSON.stringify("%900")]);
			runShim(useTs, repo, statePath, ["set-state", "TD-KILLFAIL", "merged"]);
			const r = runShim(useTs, repo, statePath, ["teardown-window", "TD-KILLFAIL"], { TMUX_SHIM_REFUSE_KILL: "1" });
			expect(r.status).toBe(5);
			expect(r.stderr).toContain("kill of");
			expect(r.stderr).toContain("%900 still alive");
			// Pane and window unchanged in shim state.
			const state = readShimState(statePath);
			expect(state.panes["%900"]).toBeDefined();
			expect(state.windows["@90"]).toBeDefined();
		}
	});

	test("corrupt registry state file → exit 6 (distinct from issue-not-found)", () => {
		// Reviewer BLOCKER: a flightdeck-state get failure (corrupt JSON
		// here — jq exits 5) must NOT be conflated with "issue not in
		// registry" (exit 1). close-issue.md treats exit 1 as idempotent;
		// exit 6 must surface so the operator sees state corruption.
		const fs = require("node:fs") as typeof import("node:fs");
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, baseShim("test-session"));
			// Initialise the registry once so the state file exists, then
			// corrupt it. (Without an init step flightdeck-state would
			// return the normal exit-1 "file missing" path which IS the
			// idempotent case and correctly maps to teardown exit 1.)
			runShim(useTs, repo, statePath, ["init", "TD-CORRUPT", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			const registryPath = stateFilePath(repo, "test-session");
			fs.writeFileSync(registryPath, "{not valid json at all,,,");
			const r = runShim(useTs, repo, statePath, ["teardown-window", "TD-CORRUPT"]);
			expect(r.status).toBe(6);
			expect(r.stderr).toContain("registry read failed");
			expect(r.stderr).not.toContain("not found in registry");
		}
	});
});

describe("pane-registry reconcile backfill safety (#16, shim-driven)", () => {
	test("index reuse: window_name mismatch → drift, no adoption, victim survives", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			// Reproduce the original #16 wire: the registry has a NUMERIC
			// pane_target (`HT:2.1` in the issue evidence) because the issue
			// was previously persisted with a session:window-index.pane-index
			// form. After the original window was destroyed and tmux reused
			// the index, that target now resolves to an unrelated live pane
			// (the daemon).
			const statePath = makeShimState(repo, {
				panes: {
					"%500": { pane_index: 0, path: "/some/daemon/cwd", window_id: "@50", window_index: 1, window_name: "flightdeck-daemon-s1" },
				},
				session: "test-session",
				windows: { "@50": { index: 1, name: "flightdeck-daemon-s1" } },
			});
			runShim(useTs, repo, statePath, [
				"init", "REUSE-1",
				"--window", "orig-issue",
				"--harness", "opencode",
				"--worktree", "/tmp/wt-issue",
			]);
			// Force the legacy wire: numeric pane_target pointing at the
			// victim's address, pane_id cleared.
			runShim(useTs, repo, statePath, ["set", "REUSE-1", "pane_target", JSON.stringify("test-session:1.0")]);
			runShim(useTs, repo, statePath, ["set", "REUSE-1", "pane_id", "null"]);
			const r = runShim(useTs, repo, statePath, ["reconcile"]);
			// Reconcile must not adopt the victim's pane_id; must emit drift;
			// must not destroy the victim.
			expect(r.stderr).toContain("drift detected");
			expect(readShimState(statePath).panes["%500"]).toBeDefined();
			const entry = JSON.parse(runShim(useTs, repo, statePath, ["get", "REUSE-1"]).stdout) as Record<string, unknown>;
			expect(entry.pane_id).toBeNull();
		}
	});

	test("index reuse: worktree (cwd) mismatch alone → drift, no adoption", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			// Pathological window-name collision: the new occupant happens to
			// have the same window name (e.g. user reused a friendly name),
			// but its cwd is a different worktree. The cwd-anchor invariant
			// must catch this and emit drift.
			const statePath = makeShimState(repo, {
				panes: {
					"%600": { pane_index: 0, path: "/tmp/wt-other", window_id: "@60", window_index: 2, window_name: "orig-issue" },
				},
				session: "test-session",
				windows: { "@60": { index: 2, name: "orig-issue" } },
			});
			runShim(useTs, repo, statePath, [
				"init", "REUSE-2",
				"--window", "orig-issue",
				"--harness", "opencode",
				"--worktree", "/tmp/wt-issue",
				"--pane-index", "0",
			]);
			// Force pane_target to the victim's address and clear pane_id.
			runShim(useTs, repo, statePath, ["set", "REUSE-2", "pane_target", JSON.stringify("test-session:2.0")]);
			runShim(useTs, repo, statePath, ["set", "REUSE-2", "pane_id", "null"]);
			const r = runShim(useTs, repo, statePath, ["reconcile"]);
			expect(r.stderr).toContain("drift detected");
			const entry = JSON.parse(runShim(useTs, repo, statePath, ["get", "REUSE-2"]).stdout) as Record<string, unknown>;
			expect(entry.pane_id).toBeNull();
			expect(readShimState(statePath).panes["%600"]).toBeDefined();
		}
	});

	test("matching window_name + worktree → backfill adopts pane_id", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const statePath = makeShimState(repo, {
				panes: {
					"%700": { pane_index: 0, path: "/tmp/wt-good/subdir", window_id: "@70", window_index: 3, window_name: "good-issue" },
				},
				session: "test-session",
				windows: { "@70": { index: 3, name: "good-issue" } },
			});
			runShim(useTs, repo, statePath, [
				"init", "GOOD-1",
				"--window", "good-issue",
				"--harness", "opencode",
				"--worktree", "/tmp/wt-good",
				"--pane-index", "0",
			]);
			runShim(useTs, repo, statePath, ["set", "GOOD-1", "pane_target", JSON.stringify("test-session:3.0")]);
			runShim(useTs, repo, statePath, ["set", "GOOD-1", "pane_id", "null"]);
			const r = runShim(useTs, repo, statePath, ["reconcile"]);
			expect(r.stderr).not.toContain("drift detected");
			expect(r.stdout).toContain("backfilled pane_id");
			const entry = JSON.parse(runShim(useTs, repo, statePath, ["get", "GOOD-1"]).stdout) as Record<string, unknown>;
			expect(entry.pane_id).toBe("%700");
		}
	});
});
