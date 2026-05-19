import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
	emitMergeAction,
	emitMergePlanUpdated,
	emitRepoMainSync,
	emitSessionStarted,
	emitWorkflowDecision,
} from "../../src/activity/workflow-emit.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const CORE_ROOT = resolve(HERE, "../..");
const GITHUB_EMIT = resolve(HERE, "../../../../../github/scripts/_activity-emit.sh");
const LINEAR_EMIT = resolve(HERE, "../../../../../linear/scripts/_activity-emit.sh");

interface ActivityEvent {
	type: string;
	severity: string;
	importance: string;
	source: string;
	summary: string;
	entry_id?: string;
	refs?: Record<string, unknown>;
	details?: Record<string, unknown>;
}

let tmp = "";
let originalActivityFile: string | undefined;
let originalManaged: string | undefined;
let originalSession: string | undefined;

beforeEach(() => {
	tmp = mkdtempSync(join(tmpdir(), "fd-workflow-activity-"));
	originalActivityFile = process.env.FLIGHTDECK_ACTIVITY_FILE;
	originalManaged = process.env.FLIGHTDECK_MANAGED;
	originalSession = process.env.FLIGHTDECK_SESSION;
	delete process.env.FLIGHTDECK_ACTIVITY_FILE;
	delete process.env.FLIGHTDECK_MANAGED;
	delete process.env.FLIGHTDECK_SESSION;
});

afterEach(() => {
	restoreEnv("FLIGHTDECK_ACTIVITY_FILE", originalActivityFile);
	restoreEnv("FLIGHTDECK_MANAGED", originalManaged);
	restoreEnv("FLIGHTDECK_SESSION", originalSession);
	if (tmp && existsSync(tmp)) rmSync(tmp, { force: true, recursive: true });
});

function restoreEnv(name: string, value: string | undefined): void {
	if (value === undefined) delete process.env[name];
	else process.env[name] = value;
}

function activityPath(name = "activity.jsonl"): string {
	return join(tmp, name);
}

function events(path = activityPath()): ActivityEvent[] {
	if (!existsSync(path)) return [];
	const text = readFileSync(path, "utf8").trim();
	return text ? text.split("\n").map((line) => JSON.parse(line) as ActivityEvent) : [];
}

function runHelper(script: string, args: string[], env: Record<string, string | undefined>): { status: number | null; stderr: string; stdout: string } {
	const childEnv: Record<string, string> = { ...(process.env as Record<string, string>) };
	for (const [key, value] of Object.entries(env)) {
		if (value === undefined) delete childEnv[key];
		else childEnv[key] = value;
	}
	const result = spawnSync("bash", [script, ...args], { cwd: CORE_ROOT, encoding: "utf8", env: childEnv });
	return { status: result.status, stderr: result.stderr ?? "", stdout: result.stdout ?? "" };
}

describe("workflow activity helpers", () => {
	test("helpers emit expected rows when FLIGHTDECK_ACTIVITY_FILE is set", () => {
		const file = activityPath();
		process.env.FLIGHTDECK_ACTIVITY_FILE = file;
		emitSessionStarted({ sessionId: "S1" });
		emitWorkflowDecision({ entryId: "ISS-1", refs: { issue_id: "ISS-1", pr_number: 42 }, sessionId: "S1" }, "force-push", {
			answer: "Approved force-push",
			sequence: 1,
		});

		const rows = events(file);
		expect(rows.map((row) => row.type)).toEqual(["session.started", "decision.recorded"]);
		expect(rows[0]).toMatchObject({ severity: "info", source: "workflow" });
		expect(rows[1]).toMatchObject({ entry_id: "ISS-1", refs: { issue_id: "ISS-1", pr_number: 42 }, severity: "info" });
	});

	test("helpers do not emit when unmanaged and no activity path resolves", () => {
		emitSessionStarted({ sessionId: "S2" });
		emitWorkflowDecision({ entryId: "ISS-2", sessionId: "S2" }, "descope", { answer: "Rejected" });
		expect(existsSync(activityPath())).toBe(false);
	});

	test("state-file activity path requires managed workflow gate", () => {
		const file = activityPath();
		const stateFile = join(tmp, "state.json");
		writeFileSync(stateFile, JSON.stringify({ activity_path: file, session_id: "S2b" }), "utf8");
		emitSessionStarted({ sessionId: "S2b", stateFile });
		expect(events(file)).toHaveLength(0);
		process.env.FLIGHTDECK_MANAGED = "1";
		emitSessionStarted({ sessionId: "S2b", stateFile });
		expect(events(file)).toHaveLength(1);
	});

	test("merge action helper splits transient and permanent blocked severity", () => {
		const file = activityPath();
		process.env.FLIGHTDECK_ACTIVITY_FILE = file;
		emitMergeAction({ sessionId: "S2c" }, 9, "blocked", { reason: "unknown", transient: true });
		emitMergeAction({ sessionId: "S2c" }, 10, "blocked", { reason: "conflict", transient: false });
		expect(events(file).map((row) => [row.type, row.severity, row.refs?.pr_number])).toEqual([
			["pr.merge_blocked", "warning", 9],
			["pr.merge_blocked", "error", 10],
		]);
	});

	test("merge plan helper emits daemon.warning with conflict count", () => {
		const file = activityPath();
		process.env.FLIGHTDECK_ACTIVITY_FILE = file;
		emitMergePlanUpdated({ sessionId: "S3" }, [12, 34], {
			computed_at: "2026-05-15T00:00:00Z",
			edges: [{ prs: [12, 34], shared_files: ["src/lib.rs"] }],
		});

		const [row] = events(file);
		expect(row).toMatchObject({ severity: "warning", source: "workflow", type: "daemon.warning" });
		expect(row?.details).toMatchObject({ conflict_count: 1, queue_count: 2 });
	});

	test("repo main sync helper emits success, blocked, and failed rows", () => {
		const file = activityPath();
		process.env.FLIGHTDECK_ACTIVITY_FILE = file;
		emitRepoMainSync({ sessionId: "S3b" }, {
			ahead: 0,
			behind: 0,
			commands_suggested: [],
			dirty_paths: [],
			reason: "fast-forwarded-worktree",
			status: "synced",
		}, { branch: "main", remote: "origin" });
		emitRepoMainSync({ sessionId: "S3b" }, {
			ahead: 8,
			behind: 9,
			commands_suggested: ["git log --left-right main...origin/main", "leave local main divergent"],
			dirty_paths: ["local.txt"],
			reason: "local-branch-diverged",
			status: "blocked",
		});
		emitRepoMainSync({ sessionId: "S3b" }, {
			ahead: 0,
			behind: 0,
			commands_suggested: [],
			diagnostics: [{ command: "git -C /repo fetch origin --prune", exit_status: 128, stderr: "fatal: network down" }],
			dirty_paths: [],
			reason: "git-fetch-failed: git -C /repo fetch origin --prune; exit 128; fatal: network down",
			status: "failed",
		});

		const rows = events(file);
		expect(rows[0]).toMatchObject({ severity: "success", source: "workflow", summary: "Local main synced to origin/main", type: "repo.main_synced" });
		expect(rows[0]?.details).toMatchObject({
			ahead: 0,
			behind: 0,
			branch: "main",
			commands_suggested: [],
			dirty_paths: [],
			project_root: null,
			reason: "fast-forwarded-worktree",
			remote: "origin",
			status: "synced",
		});
		expect(rows[1]).toMatchObject({ severity: "warning", summary: "Local main sync blocked: local-branch-diverged", type: "repo.main_sync_blocked" });
		expect(rows[1]?.details).toMatchObject({
			ahead: 8,
			behind: 9,
			branch: "main",
			commands_suggested: ["git log --left-right main...origin/main", "leave local main divergent"],
			dirty_paths: ["local.txt"],
			reason: "local-branch-diverged",
			remote: "origin",
			status: "blocked",
		});
		expect(rows[2]).toMatchObject({ severity: "error", summary: "Local main sync failed: git-fetch-failed: git -C /repo fetch origin --prune; exit 128; fatal: network down", type: "repo.main_sync_failed" });
		expect(rows[2]?.details).toMatchObject({
			ahead: 0,
			behind: 0,
			diagnostics: [{ command: "git -C /repo fetch origin --prune", exit_status: 128, stderr: "fatal: network down" }],
			reason: "git-fetch-failed: git -C /repo fetch origin --prune; exit 128; fatal: network down",
			status: "failed",
		});
	});
});

describe("github and linear wrapper activity helpers", () => {
	test("github helper emits managed pr.merged and stays silent unmanaged", () => {
		const managedFile = activityPath("github-managed.jsonl");
		const managed = runHelper(GITHUB_EMIT, [
			"pr.merged",
			"--severity", "success",
			"--importance", "important",
			"--summary", "PR #77 merged",
			"--pr-number", "77",
			"--commit", "abc123",
		], { FLIGHTDECK_ACTIVITY_FILE: managedFile, FLIGHTDECK_MANAGED: undefined, FLIGHTDECK_SESSION: "S4" });
		expect(managed.status).toBe(0);
		expect(events(managedFile)).toHaveLength(1);
		expect(events(managedFile)[0]).toMatchObject({ refs: { commit: "abc123", pr_number: 77 }, severity: "success", source: "github", type: "pr.merged" });

		const unmanagedFile = activityPath("github-unmanaged.jsonl");
		const unmanaged = runHelper(GITHUB_EMIT, ["pr.merged", "--pr-number", "77"], {
			FLIGHTDECK_ACTIVITY_FILE: undefined,
			FLIGHTDECK_MANAGED: undefined,
			FLIGHTDECK_SESSION: "S4",
		});
		expect(unmanaged.status).toBe(0);
		expect(existsSync(unmanagedFile)).toBe(false);
	});

	test("linear helper emits managed issue activity and stays silent unmanaged", () => {
		const managedFile = activityPath("linear-managed.jsonl");
		const managed = runHelper(LINEAR_EMIT, [
			"linear.issue_finished",
			"--severity", "success",
			"--summary", "PROJ-7 issue_finished",
			"--issue-id", "PROJ-7",
			"--linear-id", "PROJ-7",
			"--details-json", '{"state":"Done"}',
		], { FLIGHTDECK_ACTIVITY_FILE: managedFile, FLIGHTDECK_MANAGED: undefined, FLIGHTDECK_SESSION: "S5" });
		expect(managed.status).toBe(0);
		expect(events(managedFile)).toHaveLength(1);
		expect(events(managedFile)[0]).toMatchObject({ refs: { issue_id: "PROJ-7", linear_id: "PROJ-7" }, severity: "success", source: "linear", type: "linear.issue_finished" });

		const unmanagedFile = activityPath("linear-unmanaged.jsonl");
		const unmanaged = runHelper(LINEAR_EMIT, ["linear.issue_finished", "--issue-id", "PROJ-7"], {
			FLIGHTDECK_ACTIVITY_FILE: undefined,
			FLIGHTDECK_MANAGED: undefined,
			FLIGHTDECK_SESSION: "S5",
		});
		expect(unmanaged.status).toBe(0);
		expect(existsSync(unmanagedFile)).toBe(false);
	});
});
