// Parity test: flightdeck-state (bash) vs flightdeck-state (TS).
// Each scenario runs identical sequence of subcommands against an
// isolated tmp git repo and asserts the resulting state JSON is
// byte-equal after timestamp normalization.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { entryIdForIssue, readTrackedEntries, writeTrackedEntry } from "../../src/state/tracked-entry.ts";
import type { TrackedEntry } from "../../src/state/types.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-state");
const SESSION = "PARITY";

function makeRepo(): string {
	const dir = mkdtempSync(join(tmpdir(), "fdstate-parity-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--allow-empty", "-m", "init"], { env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" } });
	return dir;
}

function run(useTs: boolean, cwd: string, args: string[], extraEnv: Record<string, string | undefined> = {}): { stdout: string; stderr: string; status: number | null } {
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
	for (const [key, value] of Object.entries(extraEnv)) {
		if (value === undefined) delete env[key];
		else env[key] = value;
	}
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

function readOwnerViaJq(repoRoot: string, sortKeys = false): string {
	const path = join(repoRoot, "tmp", `flightdeck-state-${SESSION}.json`);
	const args = sortKeys ? ["-S", ".owner", path] : [".owner", path];
	const r = spawnSync("jq", args, { encoding: "utf8" });
	expect(r.status).toBe(0);
	return r.stdout;
}

function writeState(repoRoot: string, state: unknown): void {
	const dir = join(repoRoot, "tmp");
	mkdirSync(dir, { recursive: true });
	writeFileSync(join(dir, `flightdeck-state-${SESSION}.json`), JSON.stringify(state), "utf8");
}

function parseRunJson<T>(r: { stdout: string; status: number | null; stderr: string }): T {
	expect(r.status).toBe(0);
	if (r.stderr) expect(r.stderr).toBe("");
	return JSON.parse(r.stdout) as T;
}

function parseRunJsonWithWarning<T>(r: { stdout: string; status: number | null; stderr: string }, warning: string): T {
	expect(r.status).toBe(0);
	expect(r.stderr).toBe(`${warning}\n`);
	return JSON.parse(r.stdout) as T;
}

function sampleTrackedEntry(): TrackedEntry {
	return {
		adapter: {
			cc_transcript: "/tmp/cc.jsonl",
			cx_thread_id: "cx-thread-1",
			cx_ws: "ws://127.0.0.1/codex",
			oc_session_id: "oc-session-1",
			oc_url: "http://127.0.0.1:4096",
			pi_bridge_pid: 5555,
			pi_bridge_socket: "/tmp/pi.sock",
			pi_session_id: "pi-entry-session",
		},
		cwd: "/repo/trees/CC-202",
		decisions_log: [{ answer: "yes-own-only", prompt_tag: "cleanup-prompt", ts: "2026-05-13T00:00:00Z" }],
		domain: {
			issue: {
				id: "CC-202",
				merge_commit: "abc123",
				orchestration_started: true,
				pr_number: 202,
				scope_files_actual: 4,
				scope_files_declared: 3,
				worktree: "/repo/trees/CC-202",
			},
		},
		harness: "pi",
		id: "CC-202",
		kind: "issue",
		last_capture_hash: "sha256:abc",
		last_polled_at: "2026-05-13T00:02:00Z",
		last_response_at: "2026-05-13T00:01:00Z",
		launch: { effort: "medium", model: "openai-codex/gpt-5.5" },
		merge_commit: "abc123",
		pane_id: "%202",
		pane_target: "PARITY:2.0",
		spawned_at: "2026-05-13T00:00:00Z",
		state: "prompting",
		substate: "cleanup-prompt",
		title: "Tracked entry seam",
		window: "CC-202",
	};
}

function writePiBridgeStub(repoRoot: string, body: string): string {
	const dir = join(repoRoot, "stub-bin");
	mkdirSync(dir, { recursive: true });
	const bin = join(dir, "pi-bridge");
	writeFileSync(bin, `#!/usr/bin/env bash\n${body}\n`, "utf8");
	chmodSync(bin, 0o755);
	return dir;
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
			pi_session_id: "pi-session-parity",
			pi_bridge_socket: "/tmp/pi-session-bridge/parity.sock",
			discovery_error: null,
		};
		expect((readState(bashRepo) as { owner?: unknown }).owner).toEqual(expectedOwner);
		expect((readState(tsRepo) as { owner?: unknown }).owner).toEqual(expectedOwner);
		expect(readOwnerViaJq(tsRepo)).toBe(readOwnerViaJq(bashRepo));
		expect(readOwnerViaJq(tsRepo, true)).toBe(readOwnerViaJq(bashRepo, true));
	});

	test("init prefers TMUX_PANE when owner pane override is absent", () => {
		run(false, bashRepo, ["init"], { FLIGHTDECK_OWNER_PANE_ID: undefined, TMUX: "/tmp/tmux-fake", TMUX_PANE: "%tmux-env" });
		run(true, tsRepo, ["init"], { FLIGHTDECK_OWNER_PANE_ID: undefined, TMUX: "/tmp/tmux-fake", TMUX_PANE: "%tmux-env" });
		expect((readState(bashRepo) as { owner?: { pane_id?: unknown } }).owner?.pane_id).toBe("%tmux-env");
		expect((readState(tsRepo) as { owner?: { pane_id?: unknown } }).owner?.pane_id).toBe("%tmux-env");
		expect(readOwnerViaJq(tsRepo)).toBe(readOwnerViaJq(bashRepo));
	});

	test("init records schema_version and additive entries map", () => {
		run(false, bashRepo, ["init"]);
		run(true, tsRepo, ["init"]);
		const bashState = readState(bashRepo) as { schema_version?: unknown; entries?: unknown; owner?: unknown };
		const tsState = readState(tsRepo) as { schema_version?: unknown; entries?: unknown; owner?: unknown };
		expect(bashState.schema_version).toBe(1.1);
		expect(tsState.schema_version).toBe(1.1);
		expect(bashState.entries).toEqual({});
		expect(tsState.entries).toEqual({});
		expect(bashState.owner).toBeTruthy();
		expect(tsState.owner).toBeTruthy();
	});

	test("tracked-entries maps v1 issues into TrackedEntry records", () => {
		const legacy = {
			conflict_graph: { computed_at: null, edges: [] },
			issues: {
				"CC-101": {
					decisions_log: [{ answer: "apply", prompt_tag: "review-fix", ts: "2026-05-13T00:00:00Z" }],
					harness: "pi",
					last_capture_hash: "sha256:101",
					last_polled_at: "2026-05-13T00:02:00Z",
					last_response_at: "2026-05-13T00:01:00Z",
					launch: { effort: "high", model: "gpt-5.5" },
					orchestration_started: true,
					pane_id: "%101",
					pane_target: "PARITY:1.0",
					pi_bridge_pid: 5101,
					pi_bridge_socket: "/tmp/pi-101.sock",
					pi_session_id: "pi-101",
					pr_number: 101,
					scope_files_actual: 8,
					scope_files_declared: 5,
					spawned_at: "2026-05-13T00:00:00Z",
					state: "prompting",
					substate: "merge-ready-but-unknown",
					window: "CC-101",
					worktree: "/repo/trees/CC-101",
				},
			},
			merge_queue: ["CC-101"],
			paused_for_user: null,
			terminated: false,
		};
		writeState(bashRepo, legacy);
		writeState(tsRepo, legacy);
		const expected = readTrackedEntries(legacy);
		expect(expected["CC-101"]).toMatchObject({
			adapter: { pi_bridge_pid: 5101, pi_bridge_socket: "/tmp/pi-101.sock", pi_session_id: "pi-101" },
			cwd: "/repo/trees/CC-101",
			domain: { issue: { id: "CC-101", pr_number: 101, worktree: "/repo/trees/CC-101" } },
			id: "CC-101",
			kind: "issue",
			state: "prompting",
		});
		const a = parseRunJson<Record<string, TrackedEntry>>(run(false, bashRepo, ["tracked-entries"]));
		const b = parseRunJson<Record<string, TrackedEntry>>(run(true, tsRepo, ["tracked-entries"]));
		expect(a).toEqual(expected);
		expect(b).toEqual(expected);
	});

	test("tracked-entries returns v2-only entries when issues map is absent", () => {
		const entry = sampleTrackedEntry();
		const state = { entries: { [entry.id]: entry }, merge_queue: [] };
		writeState(bashRepo, state);
		writeState(tsRepo, state);
		const expected = { [entry.id]: entry };
		expect(readTrackedEntries(state)).toEqual(expected);
		expect(parseRunJson<Record<string, TrackedEntry>>(run(false, bashRepo, ["tracked-entries"]))).toEqual(expected);
		expect(parseRunJson<Record<string, TrackedEntry>>(run(true, tsRepo, ["tracked-entries"]))).toEqual(expected);
	});

	test("tracked-entries merges legacy issues under entries with entries winning by id", () => {
		const entry = sampleTrackedEntry();
		const state = {
			entries: { [entry.id]: { ...entry, state: "prompting", title: "entry wins" } },
			issues: {
				[entry.id]: { state: "waiting", worktree: "/repo/legacy-a" },
				"CC-303": { harness: "claude", pane_id: "%303", pr_number: 303, state: "waiting", worktree: "/repo/trees/CC-303" },
			},
			merge_queue: [entry.id, "CC-303"],
		};
		writeState(bashRepo, state);
		writeState(tsRepo, state);
		const expected = readTrackedEntries(state);
		expect(Object.keys(expected).sort()).toEqual(["CC-202", "CC-303"]);
		expect(expected["CC-202"]?.title).toBe("entry wins");
		expect(expected["CC-202"]?.domain?.issue?.worktree).toBe("/repo/trees/CC-202");
		expect(expected["CC-303"]).toMatchObject({ domain: { issue: { id: "CC-303", pr_number: 303 } }, id: "CC-303", kind: "issue" });
		expect(parseRunJson<Record<string, TrackedEntry>>(run(false, bashRepo, ["tracked-entries"]))).toEqual(expected);
		expect(parseRunJson<Record<string, TrackedEntry>>(run(true, tsRepo, ["tracked-entries"]))).toEqual(expected);
	});

	test("tracked-entries skips malformed entries and keeps matching legacy issue projection", () => {
		const state = {
			entries: { "CC-404": "not-an-object" },
			issues: { "CC-404": { pane_id: "%404", pr_number: 404, state: "waiting", worktree: "/repo/trees/CC-404" } },
		};
		writeState(bashRepo, state);
		writeState(tsRepo, state);
		const expected = readTrackedEntries(state);
		const warning = 'Warning: invalid .entries value(s) for "CC-404"; skipping.';
		expect(expected["CC-404"]).toMatchObject({ domain: { issue: { id: "CC-404", pr_number: 404 } }, id: "CC-404", kind: "issue" });
		expect(parseRunJsonWithWarning<Record<string, TrackedEntry>>(run(false, bashRepo, ["tracked-entries"]), warning)).toEqual(expected);
		expect(parseRunJsonWithWarning<Record<string, TrackedEntry>>(run(true, tsRepo, ["tracked-entries"]), warning)).toEqual(expected);
	});

	test("tracked-entries warns and falls back to key for malformed internal entry id", () => {
		const entry = { ...sampleTrackedEntry(), id: "bad id" };
		const state = { entries: { "CC-1": entry } };
		writeState(bashRepo, state);
		writeState(tsRepo, state);
		const expected = readTrackedEntries(state);
		const warning = 'Warning: invalid .entries["CC-1"].id "bad id"; using entry key.';
		expect(expected["CC-1"]?.id).toBe("CC-1");
		expect(parseRunJsonWithWarning<Record<string, TrackedEntry>>(run(false, bashRepo, ["tracked-entries"]), warning)).toEqual(expected);
		expect(parseRunJsonWithWarning<Record<string, TrackedEntry>>(run(true, tsRepo, ["tracked-entries"]), warning)).toEqual(expected);
	});

	test("writeTrackedEntry adds entries and projects issue compatibility fields", () => {
		const entry = sampleTrackedEntry();
		const state: { entries?: Record<string, TrackedEntry>; issues?: Record<string, unknown> } = { issues: {} };
		writeTrackedEntry(state, entry.id, entry);
		expect(state.entries?.[entry.id]).toEqual(entry);
		expect(state.issues?.["CC-202"]).toMatchObject({
			decisions_log: entry.decisions_log,
			harness: "pi",
			merge_commit: "abc123",
			pane_id: "%202",
			pi_bridge_pid: 5555,
			pi_bridge_socket: "/tmp/pi.sock",
			pi_session_id: "pi-entry-session",
			pr_number: 202,
			state: "prompting",
			worktree: "/repo/trees/CC-202",
		});
	});

	test("entry id validation rejects blank ids in helpers and CLI", () => {
		expect(entryIdForIssue("")).toBeNull();
		const entry = sampleTrackedEntry();
		expect(() => writeTrackedEntry({ issues: {} }, " ", { ...entry, id: " " })).toThrow(/invalid entry id/);
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init"]);
			const blankArg = run(useTs, repo, ["write-entry", " ", JSON.stringify({ ...entry, id: " " })]);
			expect(blankArg.status).toBe(2);
			expect(blankArg.stderr).toContain("Error: invalid entry id: must be non-empty and match ^[A-Za-z0-9._-]+$");
			const blankJsonId = run(useTs, repo, ["write-entry", entry.id, JSON.stringify({ ...entry, id: " " })]);
			expect(blankJsonId.status).toBe(2);
			expect(blankJsonId.stderr).toContain("Error: invalid entry.id: must be non-empty and match ^[A-Za-z0-9._-]+$");
		}
	});

	test("write-entry rejects blank and malformed domain.issue.id", () => {
		const entry = sampleTrackedEntry();
		expect(() => writeTrackedEntry({ issues: {} }, entry.id, { ...entry, domain: { issue: { ...entry.domain!.issue!, id: "" } } })).toThrow(/invalid domain.issue.id/);
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init"]);
			const blankDomain = run(useTs, repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { issue: { ...entry.domain!.issue!, id: "" } } })]);
			expect(blankDomain.status).toBe(2);
			expect(blankDomain.stderr).toContain("Error: invalid domain.issue.id: must be non-empty and match ^[A-Za-z0-9._-]+$");
			const malformedDomain = run(useTs, repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { issue: { ...entry.domain!.issue!, id: "bad id" } } })]);
			expect(malformedDomain.status).toBe(2);
			expect(malformedDomain.stderr).toContain("Error: invalid domain.issue.id: must be non-empty and match ^[A-Za-z0-9._-]+$");
		}
	});

	test("unknown schema warns on read and refuses write unless override is set", () => {
		const entry = sampleTrackedEntry();
		const future = { entries: {}, issues: {}, schema_version: "9.9" };
		writeState(bashRepo, future);
		writeState(tsRepo, future);
		const warning = 'Warning: unknown schema_version "9.9", treating as 1.1 (read-only safe).';
		expect(parseRunJsonWithWarning<Record<string, TrackedEntry>>(run(false, bashRepo, ["tracked-entries"]), warning)).toEqual({});
		expect(parseRunJsonWithWarning<Record<string, TrackedEntry>>(run(true, tsRepo, ["tracked-entries"]), warning)).toEqual({});
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const refused = run(useTs, repo, ["write-entry", entry.id, JSON.stringify(entry)]);
			expect(refused.status).toBe(2);
			expect(refused.stderr).toContain('Error: unknown schema_version "9.9"; refusing write (set FLIGHTDECK_ALLOW_FUTURE_SCHEMA=1 to override)');
			const allowed = run(useTs, repo, ["write-entry", entry.id, JSON.stringify(entry)], { FLIGHTDECK_ALLOW_FUTURE_SCHEMA: "1" });
			expect(allowed.status).toBe(0);
			expect(allowed.stderr).toBe(`${warning}\n`);
		}
	});

	test("phase warns on unknown schema before reading flightdeck state fallback", () => {
		const future = { issues: { "CC-777": { state: "waiting" } }, schema_version: "9.9" };
		writeState(bashRepo, future);
		writeState(tsRepo, future);
		const warning = 'Warning: unknown schema_version "9.9", treating as 1.1 (read-only safe).';
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			const phase = run(useTs, repo, ["phase", "CC-777"]);
			expect(phase.status).toBe(0);
			expect(phase.stdout.trim()).toBe("fd:waiting");
			expect(phase.stderr).toBe(`${warning}\n`);
		}
	});

	test("write-entry round-trips through tracked-entries", () => {
		const entry = sampleTrackedEntry();
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init"]);
			const write = run(useTs, repo, ["write-entry", entry.id, JSON.stringify(entry)]);
			expect(write.status).toBe(0);
			const state = readState(repo) as { entries?: Record<string, TrackedEntry>; issues?: Record<string, Record<string, unknown>> };
			expect(state.entries?.[entry.id]).toEqual(entry);
			expect(state.issues?.["CC-202"]).toMatchObject({ pr_number: 202, state: "prompting", worktree: "/repo/trees/CC-202" });
			const tracked = parseRunJson<Record<string, TrackedEntry>>(run(useTs, repo, ["tracked-entries"]));
			expect(tracked[entry.id]).toEqual(entry);
		}
		expect(normalize(readState(bashRepo))).toEqual(normalize(readState(tsRepo)));
	});

	test("write-entry canonicalizes padded entry and domain issue ids before storing", () => {
		const padded = {
			...sampleTrackedEntry(),
			domain: { issue: { ...sampleTrackedEntry().domain!.issue!, id: " CC-1 " } },
			id: " CC-1 ",
		};
		for (const repo of [bashRepo, tsRepo]) {
			const useTs = repo === tsRepo;
			run(useTs, repo, ["init"]);
			const write = run(useTs, repo, ["write-entry", " CC-1 ", JSON.stringify(padded)]);
			expect(write.status).toBe(0);
			const state = readState(repo) as { entries?: Record<string, TrackedEntry>; issues?: Record<string, Record<string, unknown>> };
			expect(state.entries?.["CC-1"]?.id).toBe("CC-1");
			expect(state.entries?.["CC-1"]?.domain?.issue?.id).toBe("CC-1");
			expect(state.issues?.["CC-1"]?.worktree).toBe("/repo/trees/CC-202");
			expect(Object.keys(state.entries ?? {})).toEqual(["CC-1"]);
			expect(Object.keys(state.issues ?? {})).toEqual(["CC-1"]);
		}
		expect(normalize(readState(bashRepo))).toEqual(normalize(readState(tsRepo)));
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

	test("pi owner discovery failure warns and persists discovery_error identically", () => {
		const overrides: Record<string, string | undefined> = {
			FLIGHTDECK_OWNER_HARNESS: "pi",
			FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET: undefined,
			FLIGHTDECK_OWNER_PI_SESSION_ID: undefined,
			PI_BRIDGE_SOCKET_PATH: undefined,
			PI_SESSION_ID: undefined,
			PATH: "/usr/bin:/bin",
		};
		const a = run(false, bashRepo, ["init"], overrides);
		const b = run(true, tsRepo, ["init"], overrides);
		expect(a.status).toBe(0);
		expect(b.status).toBe(0);
		expect(a.stderr).toContain("Warning: pi-bridge metadata discovery failed (pi_bridge_not_found); proceeding with null pi_session_id/pi_bridge_socket.");
		expect(b.stderr).toContain("Warning: pi-bridge metadata discovery failed (pi_bridge_not_found); proceeding with null pi_session_id/pi_bridge_socket.");
		expect(normalize(readState(bashRepo))).toEqual(normalize(readState(tsRepo)));
		expect(readOwnerViaJq(tsRepo)).toBe(readOwnerViaJq(bashRepo));
	});

	test("pi owner discovery timeout warns and persists discovery_error identically", () => {
		const stub = writePiBridgeStub(bashRepo, "sleep 10");
		const overrides: Record<string, string | undefined> = {
			FLIGHTDECK_OWNER_HARNESS: "pi",
			FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET: undefined,
			FLIGHTDECK_OWNER_PI_SESSION_ID: undefined,
			FLIGHTDECK_PI_BRIDGE_DISCOVERY_TIMEOUT_MS: "1000",
			FLIGHTDECK_PI_BRIDGE_DISCOVERY_TIMEOUT_SEC: "1",
			PI_BRIDGE_SOCKET_PATH: undefined,
			PI_SESSION_ID: undefined,
			PATH: `${stub}:/usr/bin:/bin`,
		};
		const start = Date.now();
		const a = run(false, bashRepo, ["init"], overrides);
		const b = run(true, tsRepo, ["init"], overrides);
		expect(Date.now() - start).toBeLessThan(3500);
		expect(a.status).toBe(0);
		expect(b.status).toBe(0);
		expect(a.stderr).toContain("Warning: pi-bridge metadata discovery failed (pi_bridge_timeout); proceeding with null pi_session_id/pi_bridge_socket.");
		expect(b.stderr).toContain("Warning: pi-bridge metadata discovery failed (pi_bridge_timeout); proceeding with null pi_session_id/pi_bridge_socket.");
		expect((readState(tsRepo) as { owner?: { discovery_error?: string } }).owner?.discovery_error).toBe("pi_bridge_timeout");
		expect(readOwnerViaJq(tsRepo)).toBe(readOwnerViaJq(bashRepo));
	});

	test("pi owner partial bridge metadata warns and persists discovery_error identically", () => {
		const stub = writePiBridgeStub(bashRepo, "printf '%s\\n' '[{\"pid\":4242,\"sessionId\":\"pi-session-only\"}]'");
		const overrides: Record<string, string | undefined> = {
			FLIGHTDECK_OWNER_HARNESS: "pi",
			FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET: undefined,
			FLIGHTDECK_OWNER_PI_SESSION_ID: undefined,
			PI_BRIDGE_SOCKET_PATH: undefined,
			PI_SESSION_ID: undefined,
			PATH: `${stub}:/usr/bin:/bin`,
		};
		const a = run(false, bashRepo, ["init"], overrides);
		const b = run(true, tsRepo, ["init"], overrides);
		expect(a.status).toBe(0);
		expect(b.status).toBe(0);
		expect(a.stderr).toContain("Warning: pi-bridge metadata discovery failed (pi_bridge_partial_metadata); proceeding with null pi_session_id/pi_bridge_socket.");
		expect(b.stderr).toContain("Warning: pi-bridge metadata discovery failed (pi_bridge_partial_metadata); proceeding with null pi_session_id/pi_bridge_socket.");
		expect((readState(tsRepo) as { owner?: { discovery_error?: string; pi_session_id?: string; pi_bridge_socket?: string | null } }).owner).toMatchObject({
			discovery_error: "pi_bridge_partial_metadata",
			pi_bridge_socket: null,
			pi_session_id: "pi-session-only",
		});
		expect(readOwnerViaJq(tsRepo)).toBe(readOwnerViaJq(bashRepo));
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
