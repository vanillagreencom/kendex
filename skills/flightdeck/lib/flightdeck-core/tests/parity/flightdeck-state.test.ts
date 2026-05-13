// Parity test: flightdeck-state (bash) vs flightdeck-state (TS).
// Each scenario runs identical sequence of subcommands against an
// isolated tmp git repo and asserts the resulting state JSON is
// byte-equal after timestamp normalization.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-state");
const SESSION = "PARITY";

function makeRepo(): string {
	const dir = mkdtempSync(join(tmpdir(), "fdstate-parity-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--allow-empty", "-m", "init"], { env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } });
	return dir;
}

function run(useTs: boolean, cwd: string, args: string[]): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.FLIGHTDECK_STATE_DIR = "tmp";
	if (useTs) env.FLIGHTDECK_USE_TS_FLIGHTDECK_STATE = "1";
	else env.FLIGHTDECK_USE_TS_FLIGHTDECK_STATE = "0";
	delete env.FLIGHTDECK_USE_TS;
	env.FLIGHTDECK_OWNER_HARNESS = "pi";
	env.FLIGHTDECK_OWNER_PANE_ID = "%42";
	env.FLIGHTDECK_OWNER_PANE_TARGET = "PARITY:7.0";
	env.FLIGHTDECK_OWNER_CWD = "/tmp/flightdeck-owner-parity";
	env.FLIGHTDECK_OWNER_PID = "4242";
	env.FLIGHTDECK_OWNER_PI_SESSION_ID = "pi-session-parity";
	env.FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET = "/tmp/pi-session-bridge/parity.sock";
	// Bash parses <action> first, then --session — preserve that order.
	const [action, ...rest] = args;
	const full = action ? [action, "--session", SESSION, ...rest] : ["--session", SESSION];
	const r = spawnSync(SCRIPT, full, { cwd, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function readState(repoRoot: string): unknown {
	const path = join(repoRoot, "tmp", `flightdeck-state-${SESSION}.json`);
	return JSON.parse(readFileSync(path, "utf8"));
}

function writeState(repoRoot: string, state: unknown): void {
	const dir = join(repoRoot, "tmp");
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, `flightdeck-state-${SESSION}.json`), JSON.stringify(state), "utf8");
}

function normalize(state: unknown): unknown {
	const s = state as Record<string, unknown>;
	// Strip timestamps that legitimately vary between bash and TS runs.
	if (typeof s.started_at === "string") s.started_at = "<ISO>";
	if (typeof s.terminated_at === "string") s.terminated_at = "<ISO>";
	return s;
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

describe("flightdeck-state parity", () => {
	test("init creates identical state shape", () => {
		const a = run(false, bashRepo, ["init"]);
		const b = run(true, tsRepo, ["init"]);
		expect(a.status).toBe(0);
		expect(b.status).toBe(0);
		expect(normalize(readState(bashRepo))).toEqual(normalize(readState(tsRepo)));
	});

	test("init records owner metadata identically", () => {
		run(false, bashRepo, ["init"]);
		run(true, tsRepo, ["init"]);
		const expectedOwner = {
			cwd: "/tmp/flightdeck-owner-parity",
			harness: "pi",
			pane_id: "%42",
			pane_target: "PARITY:7.0",
			pid: 4242,
			pi_bridge_socket: "/tmp/pi-session-bridge/parity.sock",
			pi_session_id: "pi-session-parity",
		};
		expect((readState(bashRepo) as { owner?: unknown }).owner).toEqual(expectedOwner);
		expect((readState(tsRepo) as { owner?: unknown }).owner).toEqual(expectedOwner);
	});

	test("init backfills owner metadata on legacy state without clobbering fields", () => {
		const legacy = {
			conflict_graph: { computed_at: null, edges: [] },
			issues: { "CC-LEGACY": { state: "waiting" } },
			merge_queue: ["CC-LEGACY"],
			paused_for_user: null,
			session_id: SESSION,
			started_at: "2026-05-13T00:00:00Z",
			terminated: false,
		};
		writeState(bashRepo, legacy);
		writeState(tsRepo, legacy);
		run(false, bashRepo, ["init"]);
		run(true, tsRepo, ["init"]);
		expect(normalize(readState(bashRepo))).toEqual(normalize(readState(tsRepo)));
		const state = readState(tsRepo) as { issues?: Record<string, unknown>; merge_queue?: string[]; owner?: { pane_id?: string } };
		expect(Object.keys(state.issues ?? {})).toEqual(["CC-LEGACY"]);
		expect(state.merge_queue).toEqual(["CC-LEGACY"]);
		expect(state.owner?.pane_id).toBe("%42");
	});

	test("init is idempotent", () => {
		run(false, bashRepo, ["init"]);
		run(false, bashRepo, ["init"]);
		run(true, tsRepo, ["init"]);
		run(true, tsRepo, ["init"]);
		expect(normalize(readState(bashRepo))).toEqual(normalize(readState(tsRepo)));
	});

	test("set + get round-trip", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init"]);
			run(useTs, repo, ["set", "terminated", "true"]);
			run(useTs, repo, ["set", `.issues["CC-001"]`, '{"state":"waiting"}']);
		}
		expect(normalize(readState(bashRepo))).toEqual(normalize(readState(tsRepo)));
		const a = run(false, bashRepo, ["get", ".issues[\"CC-001\"].state"]);
		const b = run(true, tsRepo, ["get", ".issues[\"CC-001\"].state"]);
		expect(b.stdout).toBe(a.stdout);
		expect(b.stdout.trim()).toBe("waiting");
	});

	test("append adds to array", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init"]);
			run(useTs, repo, ["append", "merge_queue", '"CC-001"']);
			run(useTs, repo, ["append", "merge_queue", '"CC-002"']);
		}
		expect(normalize(readState(bashRepo))).toEqual(normalize(readState(tsRepo)));
	});

	test("increment bumps integer fields", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init"]);
			run(useTs, repo, ["increment", "tick_count"]);
			run(useTs, repo, ["increment", "tick_count"]);
			run(useTs, repo, ["increment", "tick_count"]);
		}
		const a = run(false, bashRepo, ["get", ".tick_count"]);
		const b = run(true, tsRepo, ["get", ".tick_count"]);
		expect(b.stdout.trim()).toBe(a.stdout.trim());
		expect(b.stdout.trim()).toBe("3");
	});

	test("path returns canonical file path", () => {
		const a = run(false, bashRepo, ["path"]);
		const b = run(true, tsRepo, ["path"]);
		// Paths differ only in repo root prefix; both end with the same suffix.
		expect(a.stdout.endsWith(`tmp/flightdeck-state-${SESSION}.json\n`)).toBe(true);
		expect(b.stdout.endsWith(`tmp/flightdeck-state-${SESSION}.json\n`)).toBe(true);
	});

	test("archive moves file with .archive suffix", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init"]);
			run(useTs, repo, ["set", "terminated_at", '"2026-05-11T00:00:00Z"']);
			const r = run(useTs, repo, ["archive"]);
			expect(r.status).toBe(0);
			expect(r.stdout).toMatch(/-2026-05-11T000000Z\.json\.archive\n$/);
		}
	});

	// Regression: issue #17. `terminate.md § 5` previously ran
	// `pane-registry remove-merged` after `set terminated true` and before
	// `archive`, which deleted every merged-issue history from the archive.
	// The workflow now skips `remove-merged` on terminate; the archive is
	// the authoritative post-mortem record. This test pins the contract
	// directly against `flightdeck-state` so future refactors don't
	// reintroduce data loss: simulate a merged-issue session, run the
	// terminate sequence, and assert every preserved field round-trips
	// through the archive.
	test("terminate sequence preserves merged-issue history in archive (issue #17)", () => {
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init"]);
			run(useTs, repo, ["set", `.issues["CC-503"]`, JSON.stringify({
				state: "merged",
				pr_number: 81,
				merge_commit: "156d9df02ce8fb3a798f233c73e489338db969f9",
				harness: "claude",
				window: "CC-503",
				decisions_log: [
					{ ts: "2026-05-13T00:00:01Z", prompt_tag: "review-fix", answer: "apply" },
					{ ts: "2026-05-13T00:10:00Z", prompt_tag: "merge-now", answer: "yes" },
					{ ts: "2026-05-13T00:15:35Z", prompt_tag: "terminal-state-reached", answer: "merged" },
				],
			})]);
			run(useTs, repo, ["set", "terminated", "true"]);
			run(useTs, repo, ["set", "terminated_at", '"2026-05-13T00:21:28Z"']);
			run(useTs, repo, ["set", "summary_path", '"tmp/flightdeck-summary-HT-2026-05-13T002128Z.md"']);
			const archive = run(useTs, repo, ["archive"]);
			expect(archive.status).toBe(0);
			const archivePath = archive.stdout.trim();
			const data = JSON.parse(readFileSync(archivePath, "utf8"));
			expect(data.terminated).toBe(true);
			expect(data.terminated_at).toBe("2026-05-13T00:21:28Z");
			expect(data.summary_path).toBe("tmp/flightdeck-summary-HT-2026-05-13T002128Z.md");
			expect(Object.keys(data.issues)).toEqual(["CC-503"]);
			expect(data.issues["CC-503"].state).toBe("merged");
			expect(data.issues["CC-503"].pr_number).toBe(81);
			expect(data.issues["CC-503"].merge_commit).toBe("156d9df02ce8fb3a798f233c73e489338db969f9");
			expect(data.issues["CC-503"].decisions_log).toHaveLength(3);
			expect(data.issues["CC-503"].decisions_log[2].prompt_tag).toBe("terminal-state-reached");
		}
	});
});
