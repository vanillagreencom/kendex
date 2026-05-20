import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, truncateSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	createRun,
	ensureActiveRun,
	ensureProjectIndex,
	flightdeckRunStoreRoot,
	importLegacyArchives,
	legacyActivityPath,
	legacyStateDir,
	legacyStatePath,
	listRuns,
	loadProjectIndex,
	readActiveRun,
	resolveProjectIdentity,
	resolveProjectRunPaths,
	resolveRunPaths,
	showRun,
	terminateActiveRun,
	terminateRun,
} from "../../src/state/run-store.ts";

const ORIGINAL_HOME = process.env.HOME;
const ORIGINAL_STATE_DIR = process.env.FLIGHTDECK_STATE_DIR;
const ORIGINAL_PATH = process.env.PATH;
const SESSION = "RUNSTORE";

let sandbox = "";
let repo = "";
let home = "";

function makeRepo(name = "repo", remote?: string): string {
	const dir = join(sandbox, name);
	mkdirSync(dir, { recursive: true });
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
	});
	if (remote) spawnSync("git", ["-C", dir, "remote", "add", "origin", remote]);
	return dir;
}

function installTmuxShim(output: string, status = 0): void {
	const binDir = join(sandbox, `tmux-shim-${Math.random().toString(16).slice(2)}`);
	mkdirSync(binDir, { recursive: true });
	const bin = join(binDir, "tmux");
	const script = status === 0
		? `#!/usr/bin/env bash
printf '%b' ${JSON.stringify(output)}
`
		: `#!/usr/bin/env bash
echo ${JSON.stringify(output)} >&2
exit ${status}
`;
	writeFileSync(bin, script);
	chmodSync(bin, 0o755);
	process.env.PATH = `${binDir}:${ORIGINAL_PATH ?? ""}`;
}

function runFileSnapshot(created: ReturnType<typeof createRun>): { active: string; activity: string; metadata: string; state: string } {
	return {
		active: JSON.stringify(readActiveRun(repo)),
		activity: existsSync(created.paths.activity_jsonl) ? readFileSync(created.paths.activity_jsonl, "utf8") : "<missing>",
		metadata: readFileSync(created.paths.metadata_json, "utf8"),
		state: readFileSync(created.paths.state_json, "utf8"),
	};
}

function expectRunFilesUnchanged(created: ReturnType<typeof createRun>, before: { active: string; activity: string; metadata: string; state: string }): void {
	expect(JSON.stringify(readActiveRun(repo))).toBe(before.active);
	expect(existsSync(created.paths.activity_jsonl) ? readFileSync(created.paths.activity_jsonl, "utf8") : "<missing>").toBe(before.activity);
	expect(readFileSync(created.paths.metadata_json, "utf8")).toBe(before.metadata);
	expect(readFileSync(created.paths.state_json, "utf8")).toBe(before.state);
}

interface SummaryFailureCase {
	name: string;
	setup: (created: ReturnType<typeof createRun>) => string;
}

const SUMMARY_FAILURE_CASES: SummaryFailureCase[] = [
	{
		name: "missing",
		setup: () => "tmp/missing-summary.md",
	},
	{
		name: "directory",
		setup: () => {
			mkdirSync(join(repo, "tmp", "summary-dir"), { recursive: true });
			return "tmp/summary-dir";
		},
	},
	{
		name: "symlink",
		setup: () => {
			mkdirSync(join(repo, "tmp"), { recursive: true });
			const real = join(repo, "tmp", "real-summary.md");
			const link = join(repo, "tmp", "summary-link.md");
			writeFileSync(real, "# Summary\n", "utf8");
			symlinkSync(real, link);
			return "tmp/summary-link.md";
		},
	},
	{
		name: "outside project root",
		setup: () => {
			const outside = join(sandbox, "outside-summary.md");
			writeFileSync(outside, "# Outside\n", "utf8");
			return outside;
		},
	},
	{
		name: "source unreadable",
		setup: () => {
			mkdirSync(join(repo, "tmp"), { recursive: true });
			const source = join(repo, "tmp", "unreadable-summary.md");
			writeFileSync(source, "# Summary\n", "utf8");
			chmodSync(source, 0o000);
			return "tmp/unreadable-summary.md";
		},
	},
	{
		name: "copy failure",
		setup: (created) => {
			mkdirSync(join(repo, "tmp"), { recursive: true });
			const source = join(repo, "tmp", "valid-summary.md");
			writeFileSync(source, "# Summary\n", "utf8");
			mkdirSync(created.paths.summary_md, { recursive: true });
			return "tmp/valid-summary.md";
		},
	},
];

beforeEach(() => {
	sandbox = mkdtempSync(join(tmpdir(), "fd-run-store-"));
	home = join(sandbox, "home");
	mkdirSync(home, { recursive: true });
	process.env.HOME = home;
	if (ORIGINAL_STATE_DIR === undefined) delete process.env.FLIGHTDECK_STATE_DIR;
	else process.env.FLIGHTDECK_STATE_DIR = ORIGINAL_STATE_DIR;
	repo = makeRepo("alpha", "https://example.invalid/acme/alpha.git");
});

afterEach(() => {
	process.env.HOME = ORIGINAL_HOME;
	process.env.PATH = ORIGINAL_PATH;
	if (ORIGINAL_STATE_DIR === undefined) delete process.env.FLIGHTDECK_STATE_DIR;
	else process.env.FLIGHTDECK_STATE_DIR = ORIGINAL_STATE_DIR;
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

	test("terminating an older run does not clear a newer active pointer", () => {
		const first = createRun(repo, SESSION);
		const second = createRun(repo, "RUNSTORE2");
		const terminated = terminateRun(repo, first.metadata.run_id);
		expect(terminated.active_cleared).toBe(false);
		expect(readActiveRun(repo)?.active.run_id).toBe(second.metadata.run_id);
	});

	test("ensure reuses active run and creates fresh after active termination", () => {
		const first = ensureActiveRun(repo, SESSION);
		expect(first.action).toBe("created");
		const reused = ensureActiveRun(repo, SESSION);
		expect(reused.action).toBe("reused");
		expect(reused.metadata.run_id).toBe(first.metadata.run_id);

		const terminated = terminateActiveRun(repo, SESSION);
		expect(terminated.reason).toBe("terminated");
		expect(terminated.terminated?.active_cleared).toBe(true);
		expect(readActiveRun(repo)).toBeNull();

		const next = ensureActiveRun(repo, SESSION);
		expect(next.action).toBe("created");
		expect(next.metadata.run_id).not.toBe(first.metadata.run_id);
	});

	test("ensure does not finalize plan/workflow graph entries before panes are recorded", () => {
		const created = createRun(repo, SESSION);
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		writeFileSync(join(stateDir, `flightdeck-state-${SESSION}.json`), JSON.stringify({
			entries: {
				"plan-item": {
					domain: { plan_item: { item_id: "plan-item", plan_path: join(repo, "plan.md"), plan_title: "Plan" } },
					id: "plan-item",
					kind: "workflow",
					pane_id: null,
					state: "waiting",
				},
			},
			session_id: SESSION,
		}), "utf8");

		const ensured = ensureActiveRun(repo, SESSION);
		expect(ensured.action).toBe("reused");
		expect(ensured.metadata.run_id).toBe(created.metadata.run_id);
		expect(readActiveRun(repo)?.active.run_id).toBe(created.metadata.run_id);
	});

	test("ensure finalizes stale active run when recorded panes are absent", () => {
		const created = createRun(repo, SESSION);
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		writeFileSync(join(stateDir, `flightdeck-state-${SESSION}.json`), JSON.stringify({
			entries: { stale: { id: "stale", kind: "adhoc", pane_id: "%gone", state: "waiting" } },
			session_id: SESSION,
		}), "utf8");
		installTmuxShim("%other\n");

		const ensured = ensureActiveRun(repo, SESSION);
		expect(ensured.action).toBe("created-after-stale");
		expect(ensured.previous_run_id).toBe(created.metadata.run_id);
		expect(ensured.previous_termination?.metadata.terminated).toBe(true);
		expect(existsSync(ensured.previous_termination!.snapshot_path)).toBe(true);
		expect(readActiveRun(repo)?.active.run_id).toBe(ensured.metadata.run_id);
		expect(ensured.metadata.run_id).not.toBe(created.metadata.run_id);
		expect(showRun(repo, created.metadata.run_id).metadata.terminated).toBe(true);
	});

	test("ensure fails closed when active metadata is missing", () => {
		const created = createRun(repo, SESSION);
		rmSync(created.paths.metadata_json, { force: true });
		expect(() => ensureActiveRun(repo, SESSION)).toThrow(/active Flightdeck run metadata is missing/);
		expect(readActiveRun(repo)?.active.run_id).toBe(created.metadata.run_id);
	});

	test("ensure refuses non-stale active run from another tmux session", () => {
		const created = createRun(repo, SESSION);
		expect(() => ensureActiveRun(repo, "OTHERSESSION")).toThrow(/belongs to a different tmux session/);
		expect(readActiveRun(repo)?.active.run_id).toBe(created.metadata.run_id);
	});

	test("ensure refuses tmux session mismatch even when recorded panes are gone", () => {
		const created = createRun(repo, SESSION);
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		writeFileSync(join(stateDir, `flightdeck-state-${SESSION}.json`), JSON.stringify({
			entries: { stale: { id: "stale", kind: "adhoc", pane_id: "%gone", state: "waiting" } },
			session_id: SESSION,
		}), "utf8");
		installTmuxShim("%other\n");

		expect(() => ensureActiveRun(repo, "OTHERSESSION")).toThrow(/belongs to a different tmux session/);
		expect(readActiveRun(repo)?.active.run_id).toBe(created.metadata.run_id);
		expect(showRun(repo, created.metadata.run_id).metadata.terminated).toBe(false);
	});

	test("terminate-active refuses active pointer metadata tmux session mismatch before mutation", () => {
		const created = createRun(repo, SESSION);
		writeFileSync(created.paths.metadata_json, JSON.stringify({ ...created.metadata, tmux_session: "OTHERSESSION" }), "utf8");
		const before = runFileSnapshot(created);

		const result = terminateActiveRun(repo, SESSION);
		expect(result.reason).toBe("session-mismatch");
		expect(result.terminated).toBeNull();
		expect(result.diagnostic).toContain("metadata_tmux_session=OTHERSESSION");
		expectRunFilesUnchanged(created, before);
	});

	test("explicit terminate refuses tmux session mismatch before mutation", () => {
		const created = createRun(repo, SESSION);
		const before = runFileSnapshot(created);

		expect(() => terminateRun(repo, created.metadata.run_id, { tmuxSession: "OTHERSESSION" })).toThrow(/tmux session does not match requested termination session/);
		expectRunFilesUnchanged(created, before);
	});

	test("explicit terminate refuses matching active pointer with mismatched tmux session before mutation", () => {
		const created = createRun(repo, SESSION);
		const projectPaths = resolveProjectRunPaths(created.project);
		writeFileSync(projectPaths.active_run_json, JSON.stringify({ ...created.active, tmux_session: "OTHERSESSION" }), "utf8");
		const before = runFileSnapshot(created);

		expect(() => terminateRun(repo, created.metadata.run_id)).toThrow(/active Flightdeck run pointer tmux session does not match/);
		expectRunFilesUnchanged(created, before);
	});

	test("ensure refuses stale detection when tmux liveness query fails", () => {
		const created = createRun(repo, SESSION);
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		writeFileSync(join(stateDir, `flightdeck-state-${SESSION}.json`), JSON.stringify({
			entries: { maybe: { id: "maybe", kind: "adhoc", pane_id: "%maybe", state: "waiting" } },
			session_id: SESSION,
		}), "utf8");
		installTmuxShim("tmux unavailable", 7);

		expect(() => ensureActiveRun(repo, SESSION)).toThrow(/cannot verify active Flightdeck run liveness/);
		expect(readActiveRun(repo)?.active.run_id).toBe(created.metadata.run_id);
	});

	test("terminate syncs live compatibility state and summary into durable run", () => {
		const created = createRun(repo, SESSION);
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		const summary = join(stateDir, "flightdeck-summary-RUNSTORE-2026-05-19T000000Z.md");
		writeFileSync(summary, "# Summary\n", "utf8");
		writeFileSync(join(stateDir, `flightdeck-state-${SESSION}.json`), JSON.stringify({
			entries: { live: { id: "live", kind: "adhoc", pane_id: "%9", state: "complete" } },
			session_id: SESSION,
			summary_path: "tmp/flightdeck-summary-RUNSTORE-2026-05-19T000000Z.md",
		}), "utf8");

		const terminated = terminateRun(repo, created.metadata.run_id, { tmuxSession: SESSION });
		expect(terminated.metadata.summary_path).toBe(created.paths.summary_md);
		expect(readFileSync(created.paths.summary_md, "utf8")).toBe("# Summary\n");
		const state = JSON.parse(readFileSync(created.paths.state_json, "utf8"));
		expect(state.entries.live.id).toBe("live");
		expect(state.terminated).toBe(true);
		expect(existsSync(terminated.snapshot_path)).toBe(true);
	});

	test("explicit summary path failures are surfaced", () => {
		const created = createRun(repo, SESSION);
		expect(() => terminateRun(repo, created.metadata.run_id, { summaryPath: "tmp/missing-summary.md" })).toThrow(/invalid explicit --summary-path/);
		expect(readActiveRun(repo)?.active.run_id).toBe(created.metadata.run_id);
	});

	test("terminate-active explicit summary failure preserves durable activity before legacy sync", () => {
		const created = createRun(repo, SESSION);
		writeFileSync(created.paths.activity_jsonl, '{"type":"old.event"}\n', "utf8");
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		writeFileSync(join(stateDir, `flightdeck-state-${SESSION}.json`), JSON.stringify({
			entries: { live: { id: "live", kind: "adhoc", pane_id: "%9", state: "complete" } },
			session_id: SESSION,
		}), "utf8");
		writeFileSync(join(stateDir, `flightdeck-activity-${SESSION}.jsonl`), '{"type":"current.event"}\n', "utf8");
		const before = runFileSnapshot(created);

		expect(() => terminateActiveRun(repo, SESSION, { summaryPath: "tmp/missing-summary.md" })).toThrow(/invalid explicit --summary-path/);
		expectRunFilesUnchanged(created, before);
		expect(readFileSync(created.paths.activity_jsonl, "utf8")).toBe('{"type":"old.event"}\n');
	});

	test("terminating older run with explicit summary path does not sync current live state or activity", () => {
		const first = createRun(repo, SESSION);
		writeFileSync(first.paths.state_json, JSON.stringify({ entries: { old: { id: "old", kind: "adhoc", state: "complete" } }, session_id: SESSION }), "utf8");
		writeFileSync(first.paths.activity_jsonl, '{"type":"old.event"}\n', "utf8");
		const second = createRun(repo, SESSION);
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		writeFileSync(join(stateDir, `flightdeck-state-${SESSION}.json`), JSON.stringify({
			entries: { current: { id: "current", kind: "adhoc", state: "waiting" } },
			session_id: SESSION,
		}), "utf8");
		writeFileSync(join(stateDir, `flightdeck-activity-${SESSION}.jsonl`), '{"type":"current.event"}\n', "utf8");
		const summary = join(stateDir, "old-summary.md");
		writeFileSync(summary, "# Old summary\n", "utf8");

		const terminated = terminateRun(repo, first.metadata.run_id, { summaryPath: "tmp/old-summary.md" });
		expect(terminated.metadata.summary_path).toBe(first.paths.summary_md);
		expect(terminated.active_cleared).toBe(false);
		expect(readActiveRun(repo)?.active.run_id).toBe(second.metadata.run_id);
		const state = JSON.parse(readFileSync(first.paths.state_json, "utf8"));
		expect(Object.keys(state.entries)).toEqual(["old"]);
		expect(readFileSync(first.paths.activity_jsonl, "utf8")).toContain("old.event");
		expect(readFileSync(first.paths.activity_jsonl, "utf8")).not.toContain("current.event");
		const activitySnapshotPath = terminated.activity_snapshot_path!;
		expect(readFileSync(activitySnapshotPath, "utf8")).toContain("old.event");
		expect(readFileSync(activitySnapshotPath, "utf8")).not.toContain("current.event");
	});

	for (const mode of ["terminateRun", "terminateActiveRun"] as const) {
		for (const failureCase of SUMMARY_FAILURE_CASES) {
			test(`${mode} preserves run files when explicit summary path is invalid: ${failureCase.name}`, () => {
				const created = createRun(repo, SESSION);
				const summaryPath = failureCase.setup(created);
				const before = runFileSnapshot(created);

				if (mode === "terminateRun") {
					expect(() => terminateRun(repo, created.metadata.run_id, { summaryPath })).toThrow(/invalid explicit --summary-path/);
				} else {
					expect(() => terminateActiveRun(repo, SESSION, { summaryPath })).toThrow(/invalid explicit --summary-path/);
				}
				expectRunFilesUnchanged(created, before);
			});
		}
	}

	test("corrupt metadata cannot claim another run id to clear the active pointer", () => {
		const first = createRun(repo, SESSION);
		const second = createRun(repo, "RUNSTORE2");
		writeFileSync(first.paths.metadata_json, JSON.stringify({ ...first.metadata, run_id: second.metadata.run_id }), "utf8");

		expect(() => showRun(repo, first.metadata.run_id)).toThrow(/run_id .*does not match requested run/);
		expect(() => terminateRun(repo, first.metadata.run_id)).toThrow(/run_id .*does not match requested run/);
		expect(readActiveRun(repo)?.active.run_id).toBe(second.metadata.run_id);
		expect((JSON.parse(readFileSync(first.paths.state_json, "utf8")) as { terminated?: boolean }).terminated).toBe(false);
	});

	test("forged project index cannot bless matching run metadata", () => {
		const created = createRun(repo, SESSION);
		const projectPaths = resolveProjectRunPaths(created.project);
		const forgedProjectId = resolveProjectIdentity(makeRepo("forged", "https://example.invalid/acme/forged.git")).project_id;
		writeFileSync(projectPaths.project_json, JSON.stringify({ ...created.project, project_id: forgedProjectId }), "utf8");
		writeFileSync(created.paths.metadata_json, JSON.stringify({ ...created.metadata, project_id: forgedProjectId }), "utf8");
		writeFileSync(projectPaths.active_run_json, JSON.stringify({ ...created.active, project_id: forgedProjectId }), "utf8");
		const mismatch = /project index.*project_id .*does not match current project/;

		expect(() => loadProjectIndex(repo)).toThrow(mismatch);
		expect(() => ensureProjectIndex(repo)).toThrow(mismatch);
		expect(() => createRun(repo, "CREATE")).toThrow(mismatch);
		expect(() => importLegacyArchives(repo, "tmp")).toThrow(mismatch);
		expect(() => readActiveRun(repo)).toThrow(mismatch);
		expect(() => listRuns(repo)).toThrow(mismatch);
		expect(() => showRun(repo, created.metadata.run_id)).toThrow(mismatch);
		expect(() => terminateRun(repo, created.metadata.run_id)).toThrow(mismatch);
		expect((JSON.parse(readFileSync(projectPaths.project_json, "utf8")) as { project_id?: string }).project_id).toBe(forgedProjectId);
		expect((JSON.parse(readFileSync(projectPaths.active_run_json, "utf8")) as { project_id?: string }).project_id).toBe(forgedProjectId);
		expect((JSON.parse(readFileSync(created.paths.state_json, "utf8")) as { terminated?: boolean }).terminated).toBe(false);
	});

	test("forged active pointer project fails terminate before mutating run files", () => {
		const created = createRun(repo, SESSION);
		const projectPaths = resolveProjectRunPaths(created.project);
		const forgedProjectId = resolveProjectIdentity(makeRepo("forged", "https://example.invalid/acme/forged.git")).project_id;
		writeFileSync(projectPaths.active_run_json, JSON.stringify({ ...created.active, project_id: forgedProjectId }), "utf8");
		const stateBefore = readFileSync(created.paths.state_json, "utf8");
		const metadataBefore = readFileSync(created.paths.metadata_json, "utf8");

		expect(() => terminateRun(repo, created.metadata.run_id)).toThrow(/active run pointer.*project_id .*does not match project/);
		expect(readFileSync(created.paths.state_json, "utf8")).toBe(stateBefore);
		expect(readFileSync(created.paths.metadata_json, "utf8")).toBe(metadataBefore);
		expect((JSON.parse(readFileSync(projectPaths.active_run_json, "utf8")) as { project_id?: string }).project_id).toBe(forgedProjectId);
	});

	test("snapshot lookup rejects traversal and unsafe basenames", () => {
		const created = createRun(repo, SESSION);
		terminateRun(repo, created.metadata.run_id);
		expect(() => showRun(repo, created.metadata.run_id, "../project.json")).toThrow(/snapshot/);
		expect(() => showRun(repo, created.metadata.run_id, "..")).toThrow(/snapshot/);
		expect(() => showRun(repo, created.metadata.run_id, "2026-05-19T00:00:00Z/evil")).toThrow(/snapshot/);
	});

	test("durable JSON parse errors are surfaced with path context", () => {
		const created = createRun(repo, SESSION);
		writeFileSync(created.paths.metadata_json, "{not-json", "utf8");
		expect(() => listRuns(repo)).toThrow(new RegExp(created.paths.metadata_json.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
	});

	test("durable JSON null and non-object shapes fail loud instead of acting missing", () => {
		const activeCase = createRun(repo, SESSION);
		const projectPaths = resolveProjectRunPaths(activeCase.project);

		writeFileSync(projectPaths.active_run_json, "null", "utf8");
		expect(() => readActiveRun(repo)).toThrow(/active run pointer.*expected object/);

		const metadataCase = createRun(repo, "META");
		writeFileSync(metadataCase.paths.metadata_json, "null", "utf8");
		expect(() => listRuns(repo)).toThrow(/run metadata.*expected object/);

		rmSync(metadataCase.paths.run_dir, { force: true, recursive: true });
		const stateCase = createRun(repo, "STATE");
		writeFileSync(stateCase.paths.state_json, "[]", "utf8");
		expect(() => showRun(repo, stateCase.metadata.run_id)).toThrow(/run state.*expected object/);
		expect(() => terminateRun(repo, stateCase.metadata.run_id)).toThrow(/run state.*expected object/);

		writeFileSync(projectPaths.project_json, "42", "utf8");
		expect(() => loadProjectIndex(repo)).toThrow(/project index.*expected object/);
	});

	test("create rejects non-object live state instead of synthesizing empty state", () => {
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		const liveState = join(stateDir, `flightdeck-state-${SESSION}.json`);
		writeFileSync(liveState, "null", "utf8");
		expect(() => createRun(repo, SESSION)).toThrow(new RegExp(liveState.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
		expect(readFileSync(liveState, "utf8")).toBe("null");
	});

	test("create honors FLIGHTDECK_STATE_DIR from .env.local", () => {
		writeFileSync(join(repo, ".env.local"), "FLIGHTDECK_STATE_DIR=fd-state\n", "utf8");
		const configuredStateDir = join(repo, "fd-state");
		mkdirSync(configuredStateDir, { recursive: true });
		writeFileSync(join(configuredStateDir, `flightdeck-state-${SESSION}.json`), JSON.stringify({ session_id: SESSION, marker: "env-state" }), "utf8");
		const created = createRun(repo, SESSION);
		const state = JSON.parse(readFileSync(created.paths.state_json, "utf8")) as { marker?: string };
		expect(state.marker).toBe("env-state");
		expect(legacyStateDir(repo)).toBe(configuredStateDir);
	});

	test("explicit worktree project roots resolve to the main project identity", () => {
		const linked = join(sandbox, "alpha-linked");
		const result = spawnSync("git", ["-C", repo, "worktree", "add", "-q", "-b", "linked-branch", linked], { encoding: "utf8" });
		expect(result.status).toBe(0);
		const mainIdentity = resolveProjectIdentity(repo);
		const linkedIdentity = resolveProjectIdentity(linked);
		expect(linkedIdentity.project_id).toBe(mainIdentity.project_id);
		expect(linkedIdentity.root_path).toBe(mainIdentity.root_path);
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

	test("legacy archive import uses matching fallback activity without session_id and skips repeat deterministically", () => {
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		const archive = join(stateDir, "flightdeck-state-FALLBACK-2026-05-19T000000Z.json.archive");
		const activity = join(stateDir, "flightdeck-activity-FALLBACK-2026-05-19T000000Z.jsonl.archive");
		writeFileSync(activity, '{"type":"session.completed","session":"fallback"}\n', "utf8");
		writeFileSync(archive, JSON.stringify({ entries: {}, terminated: true }), "utf8");

		const result = importLegacyArchives(repo, "tmp");
		expect(result.diagnostics).toEqual([]);
		expect(result.imported).toHaveLength(1);
		expect(result.imported[0]?.tmux_session).toBe("FALLBACK");
		expect(readFileSync(result.imported[0]!.activity_path, "utf8")).toContain("fallback");
		const shown = showRun(repo, result.imported[0]!.run_id) as { state: { session_id?: string } };
		expect(shown.state.session_id).toBe("FALLBACK");
		expect(JSON.parse(readFileSync(result.imported[0]!.state_path, "utf8")).session_id).toBe("FALLBACK");
		const repeat = importLegacyArchives(repo, "tmp");
		expect(repeat.imported).toHaveLength(0);
		expect(repeat.skipped.map((item) => item.run_id)).toEqual([result.imported[0]!.run_id]);
	});

	test("legacy archive import skips malformed archives with diagnostics", () => {
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		const archive = join(stateDir, "flightdeck-state-BAD-2026-05-19T000000Z.json.archive");
		writeFileSync(archive, "{bad-json", "utf8");
		const result = importLegacyArchives(repo, "tmp");
		expect(result.imported).toHaveLength(0);
		expect(result.diagnostics.join("\n")).toContain(archive);
		expect(result.diagnostics.join("\n")).toContain("invalid JSON");
	});

	test("legacy activity archive import rejects outside paths, symlinks, and oversized files", () => {
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		const outside = join(sandbox, "flightdeck-activity-OUTSIDE-2026-05-19T000000Z.jsonl.archive");
		writeFileSync(outside, "secret\n", "utf8");
		const outsideArchive = join(stateDir, "flightdeck-state-OUTSIDE-2026-05-19T000000Z.json.archive");
		writeFileSync(outsideArchive, JSON.stringify({ activity_archive_path: outside, entries: {}, session_id: "OUTSIDE", terminated: true, terminated_at: "2026-05-19T00:00:00Z" }), "utf8");

		const symlinkTarget = join(stateDir, "target.jsonl");
		writeFileSync(symlinkTarget, "linked\n", "utf8");
		const symlinkActivity = join(stateDir, "flightdeck-activity-LINK-2026-05-19T000000Z.jsonl.archive");
		symlinkSync(symlinkTarget, symlinkActivity);
		const symlinkArchive = join(stateDir, "flightdeck-state-LINK-2026-05-19T000000Z.json.archive");
		writeFileSync(symlinkArchive, JSON.stringify({ entries: {}, session_id: "LINK", terminated: true, terminated_at: "2026-05-19T00:00:00Z" }), "utf8");

		const hugeActivity = join(stateDir, "flightdeck-activity-HUGE-2026-05-19T000000Z.jsonl.archive");
		writeFileSync(hugeActivity, "x", "utf8");
		truncateSync(hugeActivity, 50 * 1024 * 1024 + 1);
		const hugeArchive = join(stateDir, "flightdeck-state-HUGE-2026-05-19T000000Z.json.archive");
		writeFileSync(hugeArchive, JSON.stringify({ entries: {}, session_id: "HUGE", terminated: true, terminated_at: "2026-05-19T00:00:00Z" }), "utf8");

		const result = importLegacyArchives(repo, "tmp");
		expect(result.imported).toHaveLength(3);
		for (const run of result.imported) expect(readFileSync(run.activity_path, "utf8")).toBe("");
		const diagnostics = result.diagnostics.join("\n");
		expect(diagnostics).toContain("path escapes legacy state dir");
		expect(diagnostics).toContain("symlinks are not allowed");
		expect(diagnostics).toContain("file exceeds");
	});
});
