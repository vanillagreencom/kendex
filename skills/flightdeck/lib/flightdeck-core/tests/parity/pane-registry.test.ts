// Parity test: pane-registry (bash) vs pane-registry (TS).
// Runs inside the active tmux session (TMUX env must be set).

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
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
	spawnSync("git", ["-C", dir, "commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
	});
	return dir;
}

function run(cwd: string, args: string[], extraEnv: Record<string, string> = {}): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.FLIGHTDECK_STATE_DIR = "tmp";
	Object.assign(env, extraEnv);
	const r = spawnSync(SCRIPT, args, { cwd, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function readIssues(repo: string, session = process.env.TMUX_PARITY_SESSION ?? sessionName()): unknown {
	// `.issues` has been removed from the state schema; any test that
	// still expects an empty issues map sees a normalized `{}` so the
	// assertion stays valid.
	const file = join(repo, "tmp", `flightdeck-state-${session}.json`);
	const raw = JSON.parse(readFileSync(file, "utf8")).issues;
	return raw && typeof raw === "object" ? raw : {};
}

function readEntries(repo: string, session = process.env.TMUX_PARITY_SESSION ?? sessionName()): unknown {
	const file = join(repo, "tmp", `flightdeck-state-${session}.json`);
	return JSON.parse(readFileSync(file, "utf8")).entries;
}

function writeRawState(repo: string, state: unknown, session = process.env.TMUX_PARITY_SESSION ?? sessionName()): void {
	const dir = join(repo, "tmp");
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, `flightdeck-state-${session}.json`), JSON.stringify(state), "utf8");
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

// Single repo per test. `tsRepo` and `tsRepo` are aliases now that
// only the TS implementation exists; legacy parity-loop call sites that
// reference either name keep working without bifurcating state.
let tsRepo = "";

beforeEach(() => {
	tsRepo = makeRepo();
});

afterEach(() => {
	if (tsRepo && existsSync(tsRepo)) rmSync(tsRepo, { force: true, recursive: true });
});

describe("pane-registry parity", () => {
	test("init writes identical issue record (fake pane)", () => {
		for (const repo of [tsRepo]) {
			const r = run(repo, [
				"init", "FAKE-001",
				"--window", "fake-window",
				"--harness", "opencode",
				"--worktree", "/tmp/wt",
			]);
			expect(r.status).toBe(0);
		}
		expect(normalize(readIssues(tsRepo))).toEqual(normalize(readIssues(tsRepo)));
	});

	test("set-state writes valid state", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init", "FAKE-002", "--window", "w2", "--harness", "claude", "--worktree", "/tmp/wt"]);
			const r = run(repo, ["set-state", "FAKE-002", "prompting"]);
			expect(r.status).toBe(0);
		}
		expect(normalize(readIssues(tsRepo))).toEqual(normalize(readIssues(tsRepo)));
	});

	test("set-state updates adhoc-only .entries row", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init-entry", "adhoc-state", "--title", "Adhoc", "--kind", "adhoc", "--cwd", "/tmp/a", "--window", "1", "--harness", "pi", "--pane-id", "%301"]);
			const r = run(repo, ["set-state", "adhoc-state", "dead"]);
			expect(r.status).toBe(0);
		}
		const bEntries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		const tEntries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		expect(tEntries["adhoc-state"]!.state).toBe("dead");
		expect(tEntries["adhoc-state"]!.pane_id).toBe("%301");
		expect(normalize(tEntries)).toEqual(normalize(bEntries));
		expect(readIssues(tsRepo)).toEqual({});
	});

	test("set-state, set-substate, and set update both .entries and .issues for issue rows", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init-entry", "ISSUE-DUAL", "--title", "Issue Dual", "--kind", "issue", "--cwd", "/tmp/wt", "--window", "2", "--harness", "pi", "--pane-id", "%302", "--worktree", "/tmp/wt"]);
			expect(run(repo, ["set-state", "ISSUE-DUAL", "prompting"]).status).toBe(0);
			expect(run(repo, ["set-substate", "ISSUE-DUAL", "needs-human"]).status).toBe(0);
			expect(run(repo, ["set", "ISSUE-DUAL", "pane_target", JSON.stringify("test:2.0")]).status).toBe(0);
		}
		const entries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		expect(entries["ISSUE-DUAL"]!.state).toBe("prompting");
		expect(entries["ISSUE-DUAL"]!.substate).toBe("needs-human");
		expect(entries["ISSUE-DUAL"]!.pane_id).toBe("%302");
		expect(entries["ISSUE-DUAL"]!.pane_target).toBe("test:2.0");
	});

	test("set-state rejects invalid state", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init", "FAKE-003", "--window", "w3", "--harness", "pi", "--worktree", "/tmp/wt"]);
			const r = run(repo, ["set-state", "FAKE-003", "nonsense"]);
			expect(r.status).toBe(2);
		}
	});

	test("set-state corrupt registry state → exit 6 without touching state file", () => {
		const fs = require("node:fs") as typeof import("node:fs");
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, baseShim("test-session"));
			runShim(repo, statePath, ["init-entry", "CORRUPT-SET", "--title", "Corrupt", "--kind", "adhoc", "--cwd", "/tmp/c", "--window", "1", "--harness", "pi"]);
			const registryPath = stateFilePath(repo, "test-session");
			const corrupt = "{not valid json at all,,,";
			fs.writeFileSync(registryPath, corrupt);
			const r = runShim(repo, statePath, ["set-state", "CORRUPT-SET", "dead"]);
			expect(r.status).toBe(6);
			expect(r.stderr).toContain("registry read failed");
			expect(r.stderr).not.toContain("not found in .entries or .issues");
			expect(fs.readFileSync(registryPath, "utf8")).toBe(corrupt);
		}
	});

	test("log-decision appends to decisions_log", () => {
		run(tsRepo, ["init", "FAKE-004", "--window", "w4", "--harness", "codex", "--worktree", "/tmp/wt"]);
		run(tsRepo, ["log-decision", "FAKE-004", "merge-now", "answered Yes"]);
		run(tsRepo, ["log-decision", "FAKE-004", "cleanup-prompt", "answered No"]);
		const entries = readEntries(tsRepo) as Record<string, { decisions_log: Array<Record<string, unknown>> }>;
		expect(entries["FAKE-004"]!.decisions_log.length).toBe(2);
		expect(entries["FAKE-004"]!.decisions_log[0]!.prompt_tag).toBe("merge-now");
		expect(entries["FAKE-004"]!.decisions_log[1]!.prompt_tag).toBe("cleanup-prompt");
	});

	test("get returns the issue record; missing → exit 1", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init", "FAKE-005", "--window", "w5", "--harness", "opencode", "--worktree", "/tmp/wt"]);
		}
		const a = run(tsRepo, ["get", "FAKE-005"]);
		const b = run(tsRepo, ["get", "FAKE-005"]);
		expect(b.status).toBe(0);
		expect(a.status).toBe(0);
		const miss = run(tsRepo, ["get", "DOESNT-EXIST"]);
		expect(miss.status).toBe(1);
	});

	test("list --format inner-panes returns CSV of pane_targets", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init", "AAA-001", "--window", "wA", "--harness", "opencode", "--worktree", "/tmp/wt"]);
			run(repo, ["init", "BBB-002", "--window", "wB", "--harness", "claude", "--worktree", "/tmp/wt"]);
		}
		const a = run(tsRepo, ["list", "--format", "inner-panes"]);
		const b = run(tsRepo, ["list", "--format", "inner-panes"]);
		expect(b.stdout.trim().split(",").sort()).toEqual(a.stdout.trim().split(",").sort());
	});

	test("list --format inner-panes-live filters stale pane_ids and keeps harnesses aligned", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: {
					"%210": { pane_index: 0, path: "/tmp/live-a", window_id: "@21", window_index: 21, window_name: "live-a" },
					"%211": { pane_index: 0, path: "/tmp/live-b", window_id: "@22", window_index: 22, window_name: "live-b" },
				},
				session: "test-session",
				windows: { "@21": { index: 21, name: "live-a" }, "@22": { index: 22, name: "live-b" } },
			});
			runShim(repo, statePath, ["init-entry", "LIVE-A", "--title", "Live A", "--kind", "adhoc", "--cwd", "/tmp/live-a", "--window", "21", "--harness", "pi", "--pane-id", "%210", "--pane-target", "test-session:21.0"]);
			runShim(repo, statePath, ["init-entry", "STALE", "--title", "Stale", "--kind", "adhoc", "--cwd", "/tmp/stale", "--window", "23", "--harness", "claude", "--pane-id", "%999", "--pane-target", "test-session:23.0"]);
			runShim(repo, statePath, ["init-entry", "LIVE-B", "--title", "Live B", "--kind", "adhoc", "--cwd", "/tmp/live-b", "--window", "22", "--harness", "codex", "--pane-id", "%211", "--pane-target", "test-session:22.0"]);
		}
		const bashState = join(tsRepo, "shim-state.json");
		const tsState = join(tsRepo, "shim-state.json");
		const aPanes = runShim(tsRepo, bashState, ["list", "--format", "inner-panes-live"]);
		const bPanes = runShim(tsRepo, tsState, ["list", "--format", "inner-panes-live"]);
		const aHarnesses = runShim(tsRepo, bashState, ["list", "--format", "inner-harnesses-live"]);
		const bHarnesses = runShim(tsRepo, tsState, ["list", "--format", "inner-harnesses-live"]);
		const atomic = runShim(tsRepo, tsState, ["list", "--format", "inner-live-json"]);
		expect(aPanes.stdout.trim()).toBe("%210,%211");
		expect(bPanes.stdout.trim()).toBe("%210,%211");
		expect(aHarnesses.stdout.trim()).toBe("pi,codex");
		expect(bHarnesses.stdout.trim()).toBe("pi,codex");
		expect(JSON.parse(atomic.stdout)).toEqual([
			{ harness: "pi", pane_id: "%210" },
			{ harness: "codex", pane_id: "%211" },
		]);
	});

	test("list --format inner-live-json fails on tmux live-pane query failure", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: { "%210": { pane_index: 0, path: "/tmp/live-a", window_id: "@21", window_index: 21, window_name: "live-a" } },
				session: "test-session",
				windows: { "@21": { index: 21, name: "live-a" } },
			});
			runShim(repo, statePath, ["init-entry", "LIVE-A", "--title", "Live A", "--kind", "adhoc", "--cwd", "/tmp/live-a", "--window", "21", "--harness", "pi", "--pane-id", "%210", "--pane-target", "test-session:21.0"]);
			const r = runShim(repo, statePath, ["list", "--format", "inner-live-json"], { TMUX_SHIM_FAIL_LIST_PANES_A: "1" });
			expect(r.status).toBe(1);
			expect(r.stderr).toContain("tmux list-panes -a failed");
		}
	});

	test("init-entry writes a normalized adhoc entry", () => {
		for (const repo of [tsRepo]) {
			const r = run(repo, [
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
		const bEntries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		const tEntries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		expect(tEntries["adhoc.one"]!.kind).toBe("adhoc");
		expect(tEntries["adhoc.one"]!.pane_id).toBe("%777");
		expect(normalize(tEntries)).toEqual(normalize(bEntries));
		expect(readIssues(tsRepo)).toEqual({});
		expect(readIssues(tsRepo)).toEqual({});
	});

	test("init-entry --branch persists entry.branch on the tracked entry", () => {
		const r = run(tsRepo, [
			"init-entry", "adhoc-with-branch",
			"--title", "Branch demo",
			"--kind", "adhoc",
			"--cwd", "/tmp/scratch",
			"--window", "42",
			"--harness", "pi",
			"--pane-id", "%4242",
			"--branch", "feature/cross-source",
		]);
		expect(r.status).toBe(0);
		const entries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		expect(entries["adhoc-with-branch"]!.branch).toBe("feature/cross-source");
	});

	test("init-entry without --branch leaves entry.branch null", () => {
		const r = run(tsRepo, [
			"init-entry", "adhoc-no-branch",
			"--title", "No branch",
			"--kind", "adhoc",
			"--cwd", "/tmp/no-branch",
			"--window", "43",
			"--harness", "pi",
			"--pane-id", "%4343",
		]);
		expect(r.status).toBe(0);
		const entries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		expect(entries["adhoc-no-branch"]!.branch).toBeNull();
	});

	test("init-entry kind=issue records issue metadata under domain.issue", () => {
		const r = run(tsRepo, [
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
		const entries = readEntries(tsRepo) as Record<string, Record<string, unknown>>;
		const entry = entries["ISSUE-42"]!;
		expect(entry.kind).toBe("issue");
		const domain = entry.domain as { issue?: Record<string, unknown> } | null;
		expect(domain?.issue?.pr_number).toBe(42);
		expect(domain?.issue?.worktree).toBe("/tmp/wt42");
	});

	test("workflow init-entry records top-level PR/worktree metadata", () => {
		for (const repo of [tsRepo]) {
			run(repo, [
				"init-entry", "workflow-pr",
				"--title", "Workflow PR",
				"--kind", "workflow",
				"--cwd", "/tmp/main-repo",
				"--window", "44",
				"--harness", "pi",
				"--pane-id", "%404",
				"--worktree", "/tmp/workflow-wt",
				"--pr", "117",
			]);
			const row = (JSON.parse(run(repo, ["list", "--format", "json"]).stdout) as Record<string, unknown>[]).find((item) => item.id === "workflow-pr")!;
			expect(row.pr_number).toBe(117);
			expect(row.worktree).toBe("/tmp/workflow-wt");
		}
	});

	test("plan workflow entries flatten and update plan domain PR fields", () => {
		run(tsRepo, [
			"init-entry", "plan-item",
			"--title", "Plan item",
			"--kind", "workflow",
			"--cwd", "/repo/trees/flightdeck-plan-plan-item",
			"--window", "45",
			"--harness", "pi",
			"--pane-id", "%405",
		]);
		const planDomain = {
			plan_item: {
				depends_on: [],
				item_id: "plan-item",
				item_title: "Plan item",
				merge_commit: null,
				plan_path: "/repo/docs/plans/plan.md",
				plan_title: "Plan title",
				pr_number: null,
				worktree: "/repo/trees/flightdeck-plan-plan-item",
			},
		};
		expect(run(tsRepo, ["set", "plan-item", "domain", JSON.stringify(planDomain)]).status).toBe(0);
		expect(run(tsRepo, ["set", "plan-item", "pr_number", "222"]).status).toBe(0);
		expect(run(tsRepo, ["set", "plan-item", "merge_commit", JSON.stringify("abc123")]).status).toBe(0);

		const row = (JSON.parse(run(tsRepo, ["list", "--format", "json"]).stdout) as Record<string, unknown>[]).find((item) => item.id === "plan-item")!;
		expect(row.plan_item).toBe("plan-item");
		expect(row.pr_number).toBe(222);
		expect(row.worktree).toBe("/repo/trees/flightdeck-plan-plan-item");
		const entries = readEntries(tsRepo) as Record<string, { domain?: { plan_item?: Record<string, unknown> } }>;
		expect(entries["plan-item"]!.domain!.plan_item!.pr_number).toBe(222);
		expect(entries["plan-item"]!.domain!.plan_item!.merge_commit).toBe("abc123");
	});

	test("setEntryField rejects raw domain mutations that create multiple domain keys", () => {
		expect(run(tsRepo, [
			"init-entry", "ISSUE-DOMAIN-MUTEX",
			"--title", "Issue domain mutex",
			"--kind", "issue",
			"--cwd", "/tmp/wt-domain-mutex",
			"--window", "46",
			"--harness", "pi",
			"--worktree", "/tmp/wt-domain-mutex",
		]).status).toBe(0);
		const planItem = {
			depends_on: [],
			item_id: "plan-item",
			item_title: "Plan item",
			merge_commit: null,
			plan_path: "/repo/docs/plans/plan.md",
			plan_title: "Plan title",
			pr_number: null,
			worktree: "/repo/trees/flightdeck-plan-plan-item",
		};
		const r = run(tsRepo, ["set", "ISSUE-DOMAIN-MUTEX", "domain.plan_item", JSON.stringify(planItem)]);
		expect(r.status).toBe(2);
		expect(r.stderr).toContain("invalid domain mutation");
		expect(r.stderr).toContain("mutually exclusive");
		const entries = readEntries(tsRepo) as Record<string, { domain?: { plan_item?: unknown } }>;
		expect(entries["ISSUE-DOMAIN-MUTEX"]!.domain!.plan_item).toBeUndefined();
	});

	test("adapter arg commands accept pane ids for generic entries", async () => {
		const statePath = makeShimState(tsRepo, {
			panes: {
				"%405": { pane_index: 0, path: "/tmp/pi-pane-lookup", window_id: "@45", window_index: 45, window_name: "pi-pane-lookup" },
			},
			session: "test-session",
			windows: { "@45": { index: 45, name: "pi-pane-lookup" } },
		});
		const socketPath = join(tsRepo, "tmp", "pi-405.sock");
		mkdirSync(join(tsRepo, "tmp"), { recursive: true });
		const stubDir = join(tsRepo, "stub-bin");
		mkdirSync(stubDir, { recursive: true });
		const stub = join(stubDir, "pi-bridge");
		writeFileSync(stub, `#!/usr/bin/env bash
if [[ "$1" == "state" ]]; then
  printf '%s\n' '{"data":{"protocol":"pi-session-bridge.v1"}}'
else
  printf '%s\n' '[]'
fi
`, "utf8");
		chmodSync(stub, 0o755);
		const server = createServer();
		await new Promise<void>((resolveListen, rejectListen) => {
			server.once("error", rejectListen);
			server.listen(socketPath, resolveListen);
		});
		try {
			runShim(tsRepo, statePath, [
				"init-entry", "pi-pane-lookup",
				"--title", "Pi pane lookup",
				"--kind", "workflow",
				"--cwd", "/tmp/pi-pane-lookup",
				"--window", "45",
				"--harness", "pi",
				"--pane-id", "%405",
				"--pane-target", "test-session:45.0",
				"--pi-bridge-pid", String(process.pid),
				"--pi-bridge-socket", socketPath,
			]);
			const env = { PI_BRIDGE_BIN: stub };
			const byPaneId = runShim(tsRepo, statePath, ["pi-bridge-args", "%405"], env);
			expect(byPaneId.status).toBe(0);
			expect(byPaneId.stdout).toContain(`--pid ${process.pid}`);
			expect(byPaneId.stdout).toContain(`--socket ${socketPath}`);
			const byPaneTarget = runShim(tsRepo, statePath, ["pi-bridge-args", "test-session:45.0"], env);
			expect(byPaneTarget.status).toBe(0);
			expect(byPaneTarget.stdout).toContain(`--pid ${process.pid}`);
		} finally {
			server.close();
		}
	});

	test("adapter arg commands reject stale pane ids for generic entries", () => {
		const statePath = makeShimState(tsRepo, {
			panes: {},
			session: "test-session",
			windows: {},
		});
		runShim(tsRepo, statePath, [
			"init-entry", "stale-pi-pane",
			"--title", "Stale Pi pane",
			"--kind", "workflow",
			"--cwd", "/tmp/stale-pi-pane",
			"--window", "stale-pi-pane",
			"--harness", "pi",
			"--pane-id", "%999",
			"--pane-target", "test-session:99.0",
			"--pi-bridge-pid", String(process.pid),
			"--pi-bridge-socket", "/tmp/stale.sock",
		]);
		const byPaneId = runShim(tsRepo, statePath, ["pi-bridge-args", "%999"]);
		expect(byPaneId.status).toBe(1);
		expect(byPaneId.stderr).toContain("find-by-pane match %999 is stale");
	});

	test("list --format json returns normalized entries with issue-domain fields", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init-entry", "adhoc-json", "--title", "Adhoc", "--kind", "adhoc", "--cwd", "/tmp/a", "--window", "10", "--harness", "pi", "--pane-id", "%10"]);
			run(repo, ["init", "JSON-9", "--window", "json-9", "--harness", "codex", "--worktree", "/tmp/json-9", "--pr", "9"]);
		}
		const a = JSON.parse(run(tsRepo, ["list", "--format", "json"]).stdout) as Array<Record<string, unknown>>;
		const b = JSON.parse(run(tsRepo, ["list", "--format", "json"]).stdout) as Array<Record<string, unknown>>;
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

	test("list fails loud when tracked entries contain invalid plan brief metadata", () => {
		writeRawState(tsRepo, {
			entries: {
				"item-one": {
					cwd: join(tsRepo, "trees", "flightdeck-plan-item-one"),
					domain: {
						plan_item: {
							brief_artifact_path: "/tmp/outside/plan-briefs/plan/item-one.md",
							brief_sha256: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
							depends_on: [],
							item_id: "item-one",
							item_title: "Item one",
							merge_commit: null,
							plan_path: join(tsRepo, "docs", "plans", "plan.md"),
							plan_snapshot_sha256: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
							plan_title: "Plan title",
							pr_number: null,
							worktree: join(tsRepo, "trees", "flightdeck-plan-item-one"),
						},
					},
					harness: "pi",
					id: "item-one",
					kind: "workflow",
					state: "waiting",
				},
			},
		});
		const r = run(tsRepo, ["list", "--format", "json"]);
		expect(r.status).toBe(2);
		expect(r.stdout).toBe("");
		expect(r.stderr).toContain('Error: invalid .entries["item-one"].domain: invalid domain.plan_item.brief_artifact_path');
		expect(r.stderr).toContain("must be under state-owned plan-briefs root");
	});

	test("init-entry rejects bad input with parity", () => {
		const cases = [
			{ args: ["init-entry"], stderr: "Usage: pane-registry init-entry" },
			{ args: ["init-entry", "BAD-KIND", "--title", "Bad", "--kind", "bogus", "--cwd", "/tmp/bad", "--window", "1", "--harness", "pi"], stderr: "init-entry requires --kind" },
			{ args: ["init-entry", "NO-CWD", "--title", "Missing", "--kind", "adhoc", "--window", "1", "--harness", "pi"], stderr: "init-entry requires --title" },
			{ args: ["init-entry", "NO-HARNESS", "--title", "Missing", "--kind", "adhoc", "--cwd", "/tmp/missing", "--window", "1"], stderr: "init-entry requires --title" },
		];
		for (const c of cases) {
			const bash = run(tsRepo, c.args);
			const ts = run(tsRepo, c.args);
			expect(ts.status).toBe(2);
			expect(bash.status).toBe(2);
			expect(ts.stderr).toContain(c.stderr);
			expect(bash.stderr).toContain(c.stderr);
		}
	});

	test("find-by-pane resolves an issue", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: {
					"%210": { pane_index: 0, path: "/tmp/wt", window_id: "@21", window_index: 21, window_name: "wF" },
				},
				session: "test-session",
				windows: { "@21": { index: 21, name: "wF" } },
			});
			runShim(repo, statePath, ["init", "FBP-001", "--window", "21", "--harness", "pi", "--worktree", "/tmp/wt", "--pane-index", "0"]);
		}
		const target = "test-session:21.0";
		const a = runShim(tsRepo, join(tsRepo, "shim-state.json"), ["find-by-pane", target]);
		const b = runShim(tsRepo, join(tsRepo, "shim-state.json"), ["find-by-pane", target]);
		expect(JSON.parse(b.stdout)).toEqual({ id: "FBP-001", kind: "issue" });
		expect(JSON.parse(a.stdout)).toEqual({ id: "FBP-001", kind: "issue" });
	});

	test("find-by-pane resolves entry rows for adhoc and issue kinds", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: {
					"%110": { pane_index: 0, path: "/tmp/a", window_id: "@11", window_index: 11, window_name: "adhoc" },
					"%120": { pane_index: 0, path: "/tmp/l", window_id: "@12", window_index: 12, window_name: "legacy" },
				},
				session: "test-session",
				windows: { "@11": { index: 11, name: "adhoc" }, "@12": { index: 12, name: "legacy" } },
			});
			runShim(repo, statePath, ["init-entry", "adhoc-fbp", "--title", "Adhoc FBP", "--kind", "adhoc", "--cwd", "/tmp/a", "--window", "11", "--harness", "pi", "--pane-id", "%110", "--pane-target", "test-session:11.0"]);
			runShim(repo, statePath, ["init", "LEGACY-1", "--window", "12", "--harness", "pi", "--worktree", "/tmp/l", "--pane-index", "0"]);
		}
		expect(JSON.parse(runShim(tsRepo, join(tsRepo, "shim-state.json"), ["find-by-pane", "%110"]).stdout)).toEqual({ id: "adhoc-fbp", kind: "adhoc" });
		expect(JSON.parse(runShim(tsRepo, join(tsRepo, "shim-state.json"), ["find-by-pane", "%110"]).stdout)).toEqual({ id: "adhoc-fbp", kind: "adhoc" });
		expect(JSON.parse(runShim(tsRepo, join(tsRepo, "shim-state.json"), ["find-by-pane", "test-session:12.0"]).stdout)).toEqual({ id: "LEGACY-1", kind: "issue" });
		expect(JSON.parse(runShim(tsRepo, join(tsRepo, "shim-state.json"), ["find-by-pane", "test-session:12.0"]).stdout)).toEqual({ id: "LEGACY-1", kind: "issue" });
	});

	test("find-by-pane skips stale duplicate matches and returns a later live row", () => {
		const statePath = makeShimState(tsRepo, {
			panes: {
				"%333": { pane_index: 0, path: "/tmp/live", window_id: "@33", window_index: 33, window_name: "live-dup" },
			},
			session: "test-session",
			windows: { "@33": { index: 33, name: "live-dup" } },
		});
		runShim(tsRepo, statePath, ["init-entry", "old-stale", "--title", "Old stale", "--kind", "workflow", "--cwd", "/tmp/old", "--window", "33", "--harness", "pi", "--pane-id", "%999", "--pane-target", "test-session:33.0"]);
		runShim(tsRepo, statePath, ["init-entry", "new-live", "--title", "New live", "--kind", "workflow", "--cwd", "/tmp/live", "--window", "33", "--harness", "pi", "--pane-id", "%333", "--pane-target", "test-session:33.0"]);
		const r = runShim(tsRepo, statePath, ["find-by-pane", "test-session:33.0"]);
		expect(r.status).toBe(0);
		expect(JSON.parse(r.stdout)).toEqual({ id: "new-live", kind: "workflow" });
	});

	test("find-by-pane treats stale pane_id as no match and warns", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, baseShim("test-session"));
			runShim(repo, statePath, ["init-entry", "stale-fbp", "--title", "Stale", "--kind", "adhoc", "--cwd", "/tmp/stale", "--window", "99", "--harness", "pi", "--pane-id", "%999", "--pane-target", "test-session:99.0"]);
			const r = runShim(repo, statePath, ["find-by-pane", "%999"]);
			expect(r.status).toBe(1);
			expect(r.stdout).toBe("");
			expect(r.stderr).toContain("Warning: find-by-pane match %999 is stale");
		}
	});

	test("remove drops the issue from .issues", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init", "RM-001", "--window", "wR", "--harness", "opencode", "--worktree", "/tmp/wt"]);
			const r = run(repo, ["remove", "RM-001"]);
			expect(r.status).toBe(0);
		}
		expect(readIssues(tsRepo)).toEqual({});
		expect(readIssues(tsRepo)).toEqual({});
	});

	// Issue #37(C): adhoc entries live only in .entries; pre-fix `remove`
	// touched .issues only and silently left the .entries row behind.
	test("remove drops adhoc entries from .entries too", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init-entry", "RM-ADHOC", "--title", "Adhoc Rm", "--kind", "adhoc", "--cwd", "/tmp/a", "--window", "7", "--harness", "pi", "--pane-id", "%707"]);
			const before = readEntries(repo) as Record<string, unknown>;
			expect(before["RM-ADHOC"]).toBeDefined();
			const r = run(repo, ["remove", "RM-ADHOC"]);
			expect(r.status).toBe(0);
			expect((readEntries(repo) as Record<string, unknown>)["RM-ADHOC"]).toBeUndefined();
		}
	});

	// Issue #37(C): both deletes must be idempotent. Removing twice (or
	// removing an id present in only one map) must not error.
	test("remove is idempotent across .issues and .entries", () => {
		for (const repo of [tsRepo]) {
			run(repo, ["init", "RM-IDEM", "--window", "wI", "--harness", "opencode", "--worktree", "/tmp/wt"]);
			const r1 = run(repo, ["remove", "RM-IDEM"]);
			expect(r1.status).toBe(0);
			const r2 = run(repo, ["remove", "RM-IDEM"]);
			expect(r2.status).toBe(0);
		}
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
	windows: Record<string, { name: string; index: number; automatic_rename?: string }>;
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

function runShim(repo: string, statePath: string, args: string[], extraEnv: Record<string, string> = {}): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
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
	test("refresh-window-names writes current tmux window name without changing spawn title", () => {
		const statePath = makeShimState(tsRepo, baseShim("test-session", {
			panes: {
				"%210": { pane_index: 0, path: "/tmp/name-sync", window_id: "@21", window_index: 21, window_name: "Spawn name" },
			},
			windows: { "@21": { index: 21, name: "Spawn name" } },
		}));
		expect(runShim(tsRepo, statePath, [
			"init-entry", "name-sync",
			"--title", "Spawn title",
			"--kind", "adhoc",
			"--cwd", "/tmp/name-sync",
			"--window", "21",
			"--harness", "pi",
			"--pane-id", "%210",
			"--pane-target", "test-session:21.0",
		]).status).toBe(0);

		const shim = readShimState(statePath);
		shim.panes["%210"]!.window_name = "Pi renamed title";
		shim.windows["@21"]!.name = "Pi renamed title";
		writeFileSync(statePath, JSON.stringify(shim, null, 2));

		const refresh = runShim(tsRepo, statePath, ["refresh-window-names"]);
		expect(refresh.status).toBe(0);
		expect(JSON.parse(refresh.stdout).updated).toContain("name-sync");
		const entries = JSON.parse(readFileSync(stateFilePath(tsRepo, "test-session"), "utf8")).entries;
		expect(entries["name-sync"].title).toBe("Spawn title");
		expect(entries["name-sync"].window_name_current).toBe("Pi renamed title");
	});

	test("refresh-window-names warns and preserves names when tmux live-pane probe fails", () => {
		const statePath = makeShimState(tsRepo, baseShim("test-session", {
			panes: {
				"%211": { pane_index: 0, path: "/tmp/name-sync-probe", window_id: "@22", window_index: 22, window_name: "Probe title" },
			},
			windows: { "@22": { index: 22, name: "Probe title" } },
		}));
		expect(runShim(tsRepo, statePath, [
			"init-entry", "name-probe-fail",
			"--title", "Probe spawn",
			"--kind", "adhoc",
			"--cwd", "/tmp/name-sync-probe",
			"--window", "22",
			"--harness", "pi",
			"--pane-id", "%211",
			"--pane-target", "test-session:22.0",
		]).status).toBe(0);
		expect(runShim(tsRepo, statePath, ["set", "name-probe-fail", "window_name_current", JSON.stringify("Keep me")]).status).toBe(0);

		const refresh = runShim(tsRepo, statePath, ["refresh-window-names"], { TMUX_SHIM_FAIL_LIST_PANES_A: "1" });
		expect(refresh.status).toBe(0);
		const parsed = JSON.parse(refresh.stdout);
		expect(parsed.updated).toEqual([]);
		expect(parsed.cleared).toEqual([]);
		expect(parsed.warnings[0].reason).toBe("tmux-list-panes-failed");
		const entries = JSON.parse(readFileSync(stateFilePath(tsRepo, "test-session"), "utf8")).entries;
		expect(entries["name-probe-fail"].window_name_current).toBe("Keep me");
	});

	test("refresh-window-names fails nonzero when flightdeck-state cannot spawn", () => {
		const statePath = makeShimState(tsRepo, baseShim("test-session"));
		const refresh = runShim(tsRepo, statePath, ["refresh-window-names"], {
			FLIGHTDECK_TEST_STATE_SCRIPT: "/no/such/flightdeck-state",
		});
		expect(refresh.status).toBe(2);
		expect(refresh.stdout).toBe("");
		expect(refresh.stderr).toContain("flightdeck-state-spawn-failed");
		expect(refresh.stderr).toContain("/no/such/flightdeck-state");
	});

	test("refresh-window-names clears stale names only after missing pane is verified", () => {
		const statePath = makeShimState(tsRepo, baseShim("test-session"));
		expect(runShim(tsRepo, statePath, [
			"init-entry", "name-verified-missing",
			"--title", "Missing spawn",
			"--kind", "adhoc",
			"--cwd", "/tmp/name-missing",
			"--window", "23",
			"--harness", "pi",
			"--pane-id", "%999",
			"--pane-target", "test-session:23.0",
		]).status).toBe(0);
		expect(runShim(tsRepo, statePath, ["set", "name-verified-missing", "window_name_current", JSON.stringify("Old title")]).status).toBe(0);

		const refresh = runShim(tsRepo, statePath, ["refresh-window-names"]);
		expect(refresh.status).toBe(0);
		const parsed = JSON.parse(refresh.stdout);
		expect(parsed.cleared).toContain("name-verified-missing");
		expect(parsed.warnings).toEqual([]);
		const entries = JSON.parse(readFileSync(stateFilePath(tsRepo, "test-session"), "utf8")).entries;
		expect(entries["name-verified-missing"].window_name_current).toBeNull();
	});

	test("refresh-window-names does not recreate an entry removed after snapshot read", () => {
		const statePath = makeShimState(tsRepo, baseShim("test-session"));
		const fakeState = join(tsRepo, "fake-flightdeck-state.sh");
		const setLog = join(tsRepo, "set-called.log");
		writeFileSync(fakeState, `#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  tracked-entries)
    printf '%s\n' '{"ghost":{"pane_id":"%999","window_name_current":"Old title"}}'
    ;;
  get)
    if [[ "\${2:-}" == *'!= null'* ]]; then printf 'false\n'; else printf 'null\n'; fi
    ;;
  set)
    printf '%s\n' "$*" >> "\${FD_REFRESH_SET_LOG:?}"
    ;;
  *)
    echo "unexpected fake flightdeck-state args: $*" >&2
    exit 2
    ;;
esac
`);
		chmodSync(fakeState, 0o755);

		const refresh = runShim(tsRepo, statePath, ["refresh-window-names"], {
			FD_REFRESH_SET_LOG: setLog,
			FLIGHTDECK_TEST_STATE_SCRIPT: fakeState,
		});

		expect(refresh.status).toBe(0);
		expect(JSON.parse(refresh.stdout).cleared).toEqual([]);
		expect(existsSync(setLog)).toBe(false);
	});

	test("pane_id alive + terminal + single-pane window → kills the window", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: {
					"%100": { pane_index: 0, path: "/tmp/wt-a", window_id: "@10", window_index: 1, window_name: "issue-a" },
				},
				session: "test-session",
				windows: { "@10": { index: 1, name: "issue-a" } },
			});
			runShim(repo, statePath, ["init", "TD-1", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(repo, statePath, ["set", "TD-1", "pane_id", JSON.stringify("%100")]);
			runShim(repo, statePath, ["set-state", "TD-1", "merged"]);
			const r = runShim(repo, statePath, ["teardown-window", "TD-1"]);
			expect(r.status).toBe(0);
			const state = readShimState(statePath);
			expect(state.panes["%100"]).toBeUndefined();
			expect(state.windows["@10"]).toBeUndefined();
		}
	});

	test("pane_id alive + terminal + multi-pane window → kills only the pane", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: {
					"%100": { pane_index: 0, path: "/tmp/wt-a", window_id: "@10", window_index: 1, window_name: "issue-a" },
					"%101": { pane_index: 1, path: "/tmp/wt-a", window_id: "@10", window_index: 1, window_name: "issue-a" },
				},
				session: "test-session",
				windows: { "@10": { index: 1, name: "issue-a" } },
			});
			runShim(repo, statePath, ["init", "TD-2", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(repo, statePath, ["set", "TD-2", "pane_id", JSON.stringify("%100")]);
			runShim(repo, statePath, ["set-state", "TD-2", "merged"]);
			const r = runShim(repo, statePath, ["teardown-window", "TD-2"]);
			expect(r.status).toBe(0);
			const state = readShimState(statePath);
			expect(state.panes["%100"]).toBeUndefined();
			expect(state.panes["%101"]).toBeDefined();
			expect(state.windows["@10"]).toBeDefined();
		}
	});

	// Generic adhoc terminal states (complete|cancelled) must teardown
	// without --force, matching the issue-mode vocabulary
	// (merged|aborted|dead).
	for (const terminal of ["merged", "aborted", "dead", "complete", "cancelled"]) {
		test(`pane_id gone + state=${terminal} → no-op success`, () => {
			for (const repo of [tsRepo]) {
				const statePath = makeShimState(repo, baseShim("test-session"));
				runShim(repo, statePath, ["init", "TD-3", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
				runShim(repo, statePath, ["set", "TD-3", "pane_id", JSON.stringify("%999999")]);
				runShim(repo, statePath, ["set", "TD-3", "state", JSON.stringify(terminal)]);
				const r = runShim(repo, statePath, ["teardown-window", "TD-3"]);
				expect(r.status).toBe(0);
				expect(r.stdout).toContain("already closed");
			}
		});
	}

	test("pane_id gone + non-terminal state → exit 3 (registry drift)", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, baseShim("test-session"));
			runShim(repo, statePath, ["init", "TD-4", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(repo, statePath, ["set", "TD-4", "pane_id", JSON.stringify("%999998")]);
			// state remains "waiting".
			const r = runShim(repo, statePath, ["teardown-window", "TD-4"]);
			expect(r.status).toBe(3);
			expect(r.stderr).toContain("registry drift");
		}
	});

	// Issue #37(B): alive pane + generic terminal state (complete)
	// kills without --force, mirroring the legacy 'merged' behavior.
	test("pane_id alive + state=complete → kills without --force", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: {
					"%200": { pane_index: 0, path: "/tmp/wt-a", window_id: "@20", window_index: 1, window_name: "adhoc-a" },
				},
				session: "test-session",
				windows: { "@20": { index: 1, name: "adhoc-a" } },
			});
			runShim(repo, statePath, ["init", "TD-COMPLETE", "--window", "adhoc-a", "--harness", "pi", "--worktree", "/tmp/wt-a"]);
			runShim(repo, statePath, ["set", "TD-COMPLETE", "pane_id", JSON.stringify("%200")]);
			runShim(repo, statePath, ["set", "TD-COMPLETE", "state", JSON.stringify("complete")]);
			const r = runShim(repo, statePath, ["teardown-entry", "TD-COMPLETE"]);
			expect(r.status).toBe(0);
			expect(readShimState(statePath).panes["%200"]).toBeUndefined();
		}
	});

	test("pane_id alive + non-terminal state → exit 4 (policy refusal); --force kills", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: {
					"%100": { pane_index: 0, path: "/tmp/wt-a", window_id: "@10", window_index: 1, window_name: "issue-a" },
				},
				session: "test-session",
				windows: { "@10": { index: 1, name: "issue-a" } },
			});
			runShim(repo, statePath, ["init", "TD-FORCE", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(repo, statePath, ["set", "TD-FORCE", "pane_id", JSON.stringify("%100")]);
			// state stays "waiting".
			const r1 = runShim(repo, statePath, ["teardown-window", "TD-FORCE"]);
			expect(r1.status).toBe(4);
			expect(r1.stderr).toContain("policy refusal");
			// Issue #37(B): error must list both legacy and generic terminal
			// vocab so callers learn the right state names.
			expect(r1.stderr).toContain("complete|cancelled");
			// Pane still alive after refusal.
			expect(readShimState(statePath).panes["%100"]).toBeDefined();
			const r2 = runShim(repo, statePath, ["teardown-window", "TD-FORCE", "--force"]);
			expect(r2.status).toBe(0);
			expect(readShimState(statePath).panes["%100"]).toBeUndefined();
		}
	});

	test("unknown issue → exit 1 (idempotent, distinct from read-failure)", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, baseShim("test-session"));
			const r = runShim(repo, statePath, ["teardown-window", "DOES-NOT-EXIST"]);
			expect(r.status).toBe(1);
			expect(r.stderr).toContain("not found in registry");
		}
	});

	test("teardown-entry is an alias for teardown-window", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, baseShim("test-session"));
			runShim(repo, statePath, ["init", "TD-ALIAS", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(repo, statePath, ["set", "TD-ALIAS", "pane_id", JSON.stringify("%999990")]);
			runShim(repo, statePath, ["set-state", "TD-ALIAS", "aborted"]);
			const r = runShim(repo, statePath, ["teardown-entry", "TD-ALIAS"]);
			expect(r.status).toBe(0);
			expect(r.stdout).toContain("already closed");
		}
	});

	test("tmux kill fails and pane stays alive → exit 5", () => {
		// Reviewer BLOCKER: drive the shim to refuse kill-window/kill-pane
		// (non-zero exit + state unchanged). Post-kill liveness check sees
		// the pane is still listed and escalates instead of falsely
		// returning success.
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: {
					"%900": { pane_index: 0, path: "/tmp/wt-a", window_id: "@90", window_index: 1, window_name: "issue-a" },
				},
				session: "test-session",
				windows: { "@90": { index: 1, name: "issue-a" } },
			});
			runShim(repo, statePath, ["init", "TD-KILLFAIL", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			runShim(repo, statePath, ["set", "TD-KILLFAIL", "pane_id", JSON.stringify("%900")]);
			runShim(repo, statePath, ["set-state", "TD-KILLFAIL", "merged"]);
			const r = runShim(repo, statePath, ["teardown-window", "TD-KILLFAIL"], { TMUX_SHIM_REFUSE_KILL: "1" });
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
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, baseShim("test-session"));
			// Initialise the registry once so the state file exists, then
			// corrupt it. (Without an init step flightdeck-state would
			// return the normal exit-1 "file missing" path which IS the
			// idempotent case and correctly maps to teardown exit 1.)
			runShim(repo, statePath, ["init", "TD-CORRUPT", "--window", "issue-a", "--harness", "opencode", "--worktree", "/tmp/wt-a"]);
			const registryPath = stateFilePath(repo, "test-session");
			fs.writeFileSync(registryPath, "{not valid json at all,,,");
			const r = runShim(repo, statePath, ["teardown-window", "TD-CORRUPT"]);
			expect(r.status).toBe(6);
			expect(r.stderr).toContain("registry read failed");
			expect(r.stderr).not.toContain("not found in registry");
		}
	});
});

describe("pane-registry reconcile backfill safety (#16, shim-driven)", () => {
	test("index reuse: window_name mismatch → drift, no adoption, victim survives", () => {
		for (const repo of [tsRepo]) {
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
			runShim(repo, statePath, [
				"init", "REUSE-1",
				"--window", "orig-issue",
				"--harness", "opencode",
				"--worktree", "/tmp/wt-issue",
			]);
			// Force the legacy wire: numeric pane_target pointing at the
			// victim's address, pane_id cleared.
			runShim(repo, statePath, ["set", "REUSE-1", "pane_target", JSON.stringify("test-session:1.0")]);
			runShim(repo, statePath, ["set", "REUSE-1", "pane_id", "null"]);
			const r = runShim(repo, statePath, ["reconcile"]);
			// Reconcile must not adopt the victim's pane_id; must emit drift;
			// must not destroy the victim.
			expect(r.stderr).toContain("drift detected");
			expect(readShimState(statePath).panes["%500"]).toBeDefined();
			const entry = JSON.parse(runShim(repo, statePath, ["get", "REUSE-1"]).stdout) as Record<string, unknown>;
			expect(entry.pane_id).toBeNull();
		}
	});

	test("index reuse: worktree (cwd) mismatch alone → drift, no adoption", () => {
		for (const repo of [tsRepo]) {
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
			runShim(repo, statePath, [
				"init", "REUSE-2",
				"--window", "orig-issue",
				"--harness", "opencode",
				"--worktree", "/tmp/wt-issue",
				"--pane-index", "0",
			]);
			// Force pane_target to the victim's address and clear pane_id.
			runShim(repo, statePath, ["set", "REUSE-2", "pane_target", JSON.stringify("test-session:2.0")]);
			runShim(repo, statePath, ["set", "REUSE-2", "pane_id", "null"]);
			const r = runShim(repo, statePath, ["reconcile"]);
			expect(r.stderr).toContain("drift detected");
			const entry = JSON.parse(runShim(repo, statePath, ["get", "REUSE-2"]).stdout) as Record<string, unknown>;
			expect(entry.pane_id).toBeNull();
			expect(readShimState(statePath).panes["%600"]).toBeDefined();
		}
	});

	test("matching window_name + worktree → backfill adopts pane_id", () => {
		for (const repo of [tsRepo]) {
			const statePath = makeShimState(repo, {
				panes: {
					"%700": { pane_index: 0, path: "/tmp/wt-good/subdir", window_id: "@70", window_index: 3, window_name: "good-issue" },
				},
				session: "test-session",
				windows: { "@70": { index: 3, name: "good-issue" } },
			});
			runShim(repo, statePath, [
				"init", "GOOD-1",
				"--window", "good-issue",
				"--harness", "opencode",
				"--worktree", "/tmp/wt-good",
				"--pane-index", "0",
			]);
			runShim(repo, statePath, ["set", "GOOD-1", "pane_target", JSON.stringify("test-session:3.0")]);
			runShim(repo, statePath, ["set", "GOOD-1", "pane_id", "null"]);
			const r = runShim(repo, statePath, ["reconcile"]);
			expect(r.stderr).not.toContain("drift detected");
			expect(r.stdout).toContain("backfilled pane_id");
			const entry = JSON.parse(runShim(repo, statePath, ["get", "GOOD-1"]).stdout) as Record<string, unknown>;
			expect(entry.pane_id).toBe("%700");
		}
	});
});

// vstack#180: late hydrate-pi writes adapter bridge fields after
// open-terminal writes pi-spawn-<issue>.json, so the daemon's binder
// stops looping pi-subscriber-bind-skip.
describe("pane-registry hydrate-pi (vstack#180)", () => {
	test("copies pid/socket/session_id from pi spawn file into adapter (production sequence: init-entry first, spawn file second, then hydrate)", () => {
		const statePath = makeShimState(tsRepo, baseShim("test-session", {
			panes: {
				"%5137": { pane_index: 0, path: "/tmp/wt-180a", window_id: "@180", window_index: 1, window_name: "180" },
			},
			windows: { "@180": { index: 1, name: "180" } },
		}));
		const stateDir = join(tsRepo, "tmp", "fd-state");
		mkdirSync(stateDir, { recursive: true });
		// Simulate open-terminal's production sequence: tmux pane is opened
		// and registered via init-entry BEFORE the pi spawn file exists.
		// This is the regression scenario where the bug surfaced (#180).
		expect(runShim(tsRepo, statePath, [
			"init-entry", "180",
			"--title", "180", "--kind", "issue", "--tracker", "github", "--github-url", "https://github.com/owner/repo/issues/180",
			"--cwd", "/tmp/wt-180a", "--worktree", "/tmp/wt-180a",
			"--window", "1", "--harness", "pi",
			"--pane-id", "%5137", "--pane-target", "test-session:1.0",
		], { FD_STATE_DIR: stateDir }).status).toBe(0);
		const entryBefore = JSON.parse(runShim(tsRepo, statePath, ["get", "180"], { FD_STATE_DIR: stateDir }).stdout) as Record<string, any>;
		expect(entryBefore.adapter.pi_bridge_pid).toBeNull();
		expect(entryBefore.adapter.pi_bridge_socket).toBeNull();
		expect(entryBefore.adapter.pi_session_id).toBeNull();

		// Now open-terminal finishes pi-bridge discovery and writes the
		// spawn file. Without hydrate-pi, the tracked entry adapter slots
		// stay null forever, and the daemon loops pi-subscriber-bind-skip.
		writeFileSync(
			join(stateDir, "pi-spawn-180.json"),
			JSON.stringify({ pid: 2808779, socket: "/tmp/pi-session-bridge-1000/pi-2808779.sock", session_id: "019e46c0-1324-7db6-ab3c-13f975606a5e", directory: "/tmp/wt-180a" }),
		);

		const r = runShim(tsRepo, statePath, ["hydrate-pi", "180"], { FD_STATE_DIR: stateDir });
		expect(r.status).toBe(0);
		const payload = JSON.parse(r.stdout.trim()) as Record<string, unknown>;
		expect(payload.ok).toBe(true);
		expect(payload.pi_bridge_pid).toBe(2808779);
		expect(payload.pi_session_id).toBe("019e46c0-1324-7db6-ab3c-13f975606a5e");

		const entryAfter = JSON.parse(runShim(tsRepo, statePath, ["get", "180"], { FD_STATE_DIR: stateDir }).stdout) as Record<string, any>;
		expect(entryAfter.adapter.pi_bridge_pid).toBe(2808779);
		expect(entryAfter.adapter.pi_bridge_socket).toBe("/tmp/pi-session-bridge-1000/pi-2808779.sock");
		expect(entryAfter.adapter.pi_session_id).toBe("019e46c0-1324-7db6-ab3c-13f975606a5e");
	});

	test("rejects entries that are not harness=pi", () => {
		const statePath = makeShimState(tsRepo, baseShim("test-session"));
		const stateDir = join(tsRepo, "tmp", "fd-state");
		mkdirSync(stateDir, { recursive: true });
		writeFileSync(join(stateDir, "pi-spawn-not-pi.json"), JSON.stringify({ pid: 1, socket: "/x", session_id: "s" }));
		runShim(tsRepo, statePath, [
			"init-entry", "not-pi",
			"--title", "NotPi", "--kind", "adhoc",
			"--cwd", "/tmp/np", "--window", "1", "--harness", "claude",
		], { FD_STATE_DIR: stateDir });
		const r = runShim(tsRepo, statePath, ["hydrate-pi", "not-pi"], { FD_STATE_DIR: stateDir });
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("requires harness=pi");
	});

	test("errors when spawn file is absent", () => {
		const statePath = makeShimState(tsRepo, baseShim("test-session"));
		const stateDir = join(tsRepo, "tmp", "fd-state");
		mkdirSync(stateDir, { recursive: true });
		runShim(tsRepo, statePath, [
			"init-entry", "no-spawn",
			"--title", "NoSpawn", "--kind", "adhoc",
			"--cwd", "/tmp/ns", "--window", "1", "--harness", "pi",
		], { FD_STATE_DIR: stateDir });
		const r = runShim(tsRepo, statePath, ["hydrate-pi", "no-spawn"], { FD_STATE_DIR: stateDir });
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("no spawn file");
	});

	test("clears pi_bridge_* discovery_error when hydration succeeds", () => {
		const statePath = makeShimState(tsRepo, baseShim("test-session"));
		const stateDir = join(tsRepo, "tmp", "fd-state");
		mkdirSync(stateDir, { recursive: true });
		writeFileSync(join(stateDir, "pi-spawn-recover.json"), JSON.stringify({ pid: 4242, socket: "/tmp/pi-recover.sock", session_id: "recovered" }));
		runShim(tsRepo, statePath, [
			"init-entry", "recover",
			"--title", "Recover", "--kind", "adhoc",
			"--cwd", "/tmp/r", "--window", "1", "--harness", "pi",
			"--discovery-error", "pi_bridge_discovery_timeout",
		], { FD_STATE_DIR: stateDir });
		const before = JSON.parse(runShim(tsRepo, statePath, ["get", "recover"], { FD_STATE_DIR: stateDir }).stdout) as Record<string, unknown>;
		expect(before.discovery_error).toBe("pi_bridge_discovery_timeout");
		expect(runShim(tsRepo, statePath, ["hydrate-pi", "recover"], { FD_STATE_DIR: stateDir }).status).toBe(0);
		const after = JSON.parse(runShim(tsRepo, statePath, ["get", "recover"], { FD_STATE_DIR: stateDir }).stdout) as Record<string, unknown>;
		expect(after.discovery_error).toBeNull();
		expect((after.adapter as Record<string, unknown>).pi_bridge_pid).toBe(4242);
	});
});
