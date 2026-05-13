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

	test("find-by-pane resolves an issue", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			// Pin --pane-index 0 so the test target is deterministic across
			// tmux configs that set pane-base-index to 1.
			run(useTs, repo, ["init", "FBP-001", "--window", "wF", "--harness", "pi", "--worktree", "/tmp/wt", "--pane-index", "0"]);
		}
		const session = sessionName();
		const target = `${session}:wF.0`;
		const a = run(false, bashRepo, ["find-by-pane", target]);
		const b = run(true, tsRepo, ["find-by-pane", target]);
		expect(b.stdout.trim()).toBe("FBP-001");
		expect(a.stdout.trim()).toBe("FBP-001");
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

// --- teardown-window (#16) -------------------------------------------------
//
// teardown-window is the destructive cleanup helper called from
// workflows/close-issue.md § 4. The point of #16 is that the old
// `WINDOW_TARGET="${pane_target%.*}"; tmux kill-window` path could destroy
// an unrelated window after tmux reused the recorded window index. These
// tests cover the three branches of the new helper:
//
//   1. pane_id alive, single-pane window  → kill the window
//   2. pane_id alive, multi-pane window   → kill only the pane
//   3. pane_id gone + terminal state       → no-op success (already closed)
//   4. pane_id gone + non-terminal state   → exit 3 (registry drift)
//   5. pane_target reused by another window (#16) → helper must NOT kill it
//
// All branches are exercised against both bash and TS implementations.

function sessionId(): string {
	return spawnSync("tmux", ["display-message", "-p", "#S"], { encoding: "utf8" }).stdout.trim();
}

function makeWindow(name: string): { paneId: string; windowId: string } {
	const r = spawnSync(
		"tmux",
		["new-window", "-d", "-P", "-n", name, "-F", "#{pane_id}\t#{window_id}"],
		{ encoding: "utf8" },
	);
	const [paneId, windowId] = (r.stdout ?? "").trim().split("\t");
	if (!paneId || !windowId) throw new Error(`failed to create window ${name}: ${r.stderr}`);
	return { paneId, windowId };
}

function killWindowIfExists(windowId: string): void {
	spawnSync("tmux", ["kill-window", "-t", windowId], { stdio: "ignore" });
}

function paneStillExists(paneId: string): boolean {
	const r = spawnSync("tmux", ["list-panes", "-a", "-F", "#{pane_id}"], { encoding: "utf8" });
	return (r.stdout ?? "").split("\n").includes(paneId);
}

function setIssueField(useTs: boolean, repo: string, issue: string, field: string, jsonValue: string): void {
	run(useTs, repo, ["set", issue, field, jsonValue]);
}

describe("pane-registry teardown-window (#16)", () => {
	test("pane_id alive + single-pane window → kills the window", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const name = `td-single-${useTs ? "ts" : "bash"}-${process.pid}`;
			const { paneId, windowId } = makeWindow(name);
			try {
				run(useTs, repo, ["init", "TD-1", "--window", name, "--harness", "opencode", "--worktree", "/tmp/wt"]);
				setIssueField(useTs, repo, "TD-1", "pane_id", JSON.stringify(paneId));
				const r = run(useTs, repo, ["teardown-window", "TD-1"]);
				expect(r.status).toBe(0);
				expect(paneStillExists(paneId)).toBe(false);
			} finally {
				killWindowIfExists(windowId);
			}
		}
	});

	test("pane_id alive + multi-pane window → kills only the pane", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const name = `td-multi-${useTs ? "ts" : "bash"}-${process.pid}`;
			const { paneId, windowId } = makeWindow(name);
			// Split the window so it has two panes; we'll target the first.
			const split = spawnSync(
				"tmux",
				["split-window", "-d", "-t", paneId, "-P", "-F", "#{pane_id}"],
				{ encoding: "utf8" },
			);
			const siblingId = split.stdout.trim();
			try {
				run(useTs, repo, ["init", "TD-2", "--window", name, "--harness", "opencode", "--worktree", "/tmp/wt"]);
				setIssueField(useTs, repo, "TD-2", "pane_id", JSON.stringify(paneId));
				const r = run(useTs, repo, ["teardown-window", "TD-2"]);
				expect(r.status).toBe(0);
				expect(paneStillExists(paneId)).toBe(false);
				// Sibling pane (and therefore the window) must still exist.
				expect(paneStillExists(siblingId)).toBe(true);
			} finally {
				killWindowIfExists(windowId);
			}
		}
	});

	test("pane_id gone + terminal state → no-op success", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init", "TD-3", "--window", "td-fake", "--harness", "opencode", "--worktree", "/tmp/wt"]);
			setIssueField(useTs, repo, "TD-3", "pane_id", JSON.stringify("%999999"));
			run(useTs, repo, ["set-state", "TD-3", "merged"]);
			const r = run(useTs, repo, ["teardown-window", "TD-3"]);
			expect(r.status).toBe(0);
			expect(r.stdout).toContain("already closed");
		}
	});

	test("pane_id gone + non-terminal state → exit 3 (registry drift)", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init", "TD-4", "--window", "td-fake", "--harness", "opencode", "--worktree", "/tmp/wt"]);
			setIssueField(useTs, repo, "TD-4", "pane_id", JSON.stringify("%999998"));
			// state remains "waiting" (default from init).
			const r = run(useTs, repo, ["teardown-window", "TD-4"]);
			expect(r.status).toBe(3);
			expect(r.stderr).toContain("registry drift");
		}
	});

	test("#16 scenario: stale pane_target reused by unrelated window is NOT killed", () => {
		// Reproduce the issue: registry has a stale pane_target whose index
		// has been reassigned to a different window. The helper must rely
		// on the stable pane_id only; the unrelated window must survive.
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const victimName = `td-victim-${useTs ? "ts" : "bash"}-${process.pid}`;
			const victim = makeWindow(victimName);
			try {
				const session = sessionId();
				// Compute the victim's `session:window-index.pane-index`.
				const meta = spawnSync(
					"tmux",
					["display-message", "-t", victim.paneId, "-p", "#{window_index}.#{pane_index}"],
					{ encoding: "utf8" },
				).stdout.trim();
				const stalePaneTarget = `${session}:${meta}`;
				run(useTs, repo, ["init", "TD-5", "--window", "orig-window-name", "--harness", "opencode", "--worktree", "/tmp/wt"]);
				// Simulate the recorded state from issue #16: pane_id is the
				// original (now-dead) one; pane_target now points at an
				// unrelated live window via tmux index reuse.
				setIssueField(useTs, repo, "TD-5", "pane_id", JSON.stringify("%999997"));
				setIssueField(useTs, repo, "TD-5", "pane_target", JSON.stringify(stalePaneTarget));
				run(useTs, repo, ["set-state", "TD-5", "merged"]);
				const r = run(useTs, repo, ["teardown-window", "TD-5"]);
				expect(r.status).toBe(0);
				expect(paneStillExists(victim.paneId)).toBe(true);
			} finally {
				killWindowIfExists(victim.windowId);
			}
		}
	});

	test("unknown issue → exit 1", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const r = run(useTs, repo, ["teardown-window", "DOES-NOT-EXIST"]);
			expect(r.status).toBe(1);
		}
	});
});
