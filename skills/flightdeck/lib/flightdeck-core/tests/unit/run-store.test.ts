import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	createRun,
	ensureProjectIndex,
	flightdeckRunStoreRoot,
	importLegacyArchives,
	legacyActivityPath,
	legacyStateDir,
	legacyStatePath,
	listRuns,
	readActiveRun,
	resolveProjectIdentity,
	resolveProjectRunPaths,
	resolveRunPaths,
	terminateRun,
} from "../../src/state/run-store.ts";

const ORIGINAL_HOME = process.env.HOME;
const SESSION = "RUNSTORE";

let sandbox = "";
let repo = "";
let home = "";

function makeRepo(name = "repo", remote?: string): string {
	const dir = join(sandbox, name);
	mkdirSync(dir, { recursive: true });
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
	});
	if (remote) spawnSync("git", ["-C", dir, "remote", "add", "origin", remote]);
	return dir;
}

beforeEach(() => {
	sandbox = mkdtempSync(join(tmpdir(), "fd-run-store-"));
	home = join(sandbox, "home");
	mkdirSync(home, { recursive: true });
	process.env.HOME = home;
	repo = makeRepo("alpha", "https://example.invalid/acme/alpha.git");
});

afterEach(() => {
	process.env.HOME = ORIGINAL_HOME;
	if (sandbox && existsSync(sandbox)) rmSync(sandbox, { force: true, recursive: true });
});

describe("Flightdeck durable run store", () => {
	test("project id is stable and includes remote plus root hash", () => {
		const first = resolveProjectIdentity(repo);
		const second = resolveProjectIdentity(repo);
		expect(second).toEqual(first);
		expect(first.id_source).toBe("git-remote+root");
		expect(first.project_id).toMatch(/^alpha-[a-f0-9]{16}$/);
		const sibling = makeRepo("sibling", "https://example.invalid/acme/alpha.git");
		expect(resolveProjectIdentity(sibling).project_id).not.toBe(first.project_id);
	});

	test("project id falls back to absolute root when no remote exists", () => {
		const local = makeRepo("local-only");
		const identity = resolveProjectIdentity(local);
		expect(identity.id_source).toBe("root");
		expect(identity.remote_url).toBeNull();
		expect(identity.project_id).toMatch(/^local-only-[a-f0-9]{16}$/);
	});

	test("path helpers generate durable project and run paths", () => {
		const { project } = ensureProjectIndex(repo, "2026-05-19T00:00:00Z");
		const projectPaths = resolveProjectRunPaths(project);
		expect(projectPaths.store_root).toBe(join(home, ".vstack", "flightdeck"));
		expect(projectPaths.project_json).toBe(join(flightdeckRunStoreRoot(), "projects", project.project_id, "project.json"));
		const runPaths = resolveRunPaths(projectPaths, "run-2026-05-19T000000Z-abcd1234");
		expect(runPaths.metadata_json).toBe(join(projectPaths.runs_dir, "run-2026-05-19T000000Z-abcd1234", "metadata.json"));
		expect(legacyStateDir(repo)).toBe(join(repo, "tmp"));
		expect(legacyStatePath(repo, SESSION)).toBe(join(repo, "tmp", `flightdeck-state-${SESSION}.json`));
		expect(legacyActivityPath(repo, SESSION)).toBe(join(repo, "tmp", `flightdeck-activity-${SESSION}.jsonl`));
	});

	test("create writes active pointer and terminate clears it with a snapshot", () => {
		const created = createRun(repo, SESSION);
		expect(created.metadata.terminated).toBe(false);
		expect(readActiveRun(repo)?.active.run_id).toBe(created.metadata.run_id);
		expect(existsSync(created.paths.state_json)).toBe(true);
		const terminated = terminateRun(repo, created.metadata.run_id);
		expect(terminated.metadata.terminated).toBe(true);
		expect(terminated.active_cleared).toBe(true);
		expect(readActiveRun(repo)).toBeNull();
		expect(existsSync(terminated.snapshot_path)).toBe(true);
		const state = JSON.parse(readFileSync(created.paths.state_json, "utf8")) as { terminated?: boolean };
		expect(state.terminated).toBe(true);
	});

	test("legacy archive import copies state and activity without deleting legacy files", () => {
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		const archive = join(stateDir, "flightdeck-state-RUNSTORE-2026-05-19T000000Z.json.archive");
		const activity = join(stateDir, "flightdeck-activity-RUNSTORE-2026-05-19T000000Z.jsonl.archive");
		writeFileSync(activity, '{"type":"session.completed"}\n', "utf8");
		writeFileSync(archive, JSON.stringify({
			activity_archive_path: activity,
			entries: { A: { id: "A", kind: "adhoc", state: "complete" } },
			session_id: SESSION,
			started_at: "2026-05-19T00:00:00Z",
			terminated: true,
			terminated_at: "2026-05-19T00:00:00Z",
		}), "utf8");

		const result = importLegacyArchives(repo, "tmp");
		expect(result.imported).toHaveLength(1);
		expect(result.skipped).toHaveLength(0);
		expect(existsSync(archive)).toBe(true);
		expect(existsSync(activity)).toBe(true);
		const run = result.imported[0]!;
		expect(run.imported).toBe(true);
		expect(run.imported_from).toBe(archive);
		expect(readFileSync(run.activity_path, "utf8")).toContain("session.completed");
		const shown = listRuns(repo).runs.find((item) => item.run_id === run.run_id);
		expect(shown?.terminated).toBe(true);
		const repeat = importLegacyArchives(repo, "tmp");
		expect(repeat.imported).toHaveLength(0);
		expect(repeat.skipped).toHaveLength(1);
	});
});
