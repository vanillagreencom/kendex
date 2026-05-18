// flightdeck-state CLI behavior. Runs against an isolated tmp git repo
// per test and asserts subcommand outputs + on-disk state.

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
	const dir = mkdtempSync(join(tmpdir(), "fdstate-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
	});
	return dir;
}

function run(cwd: string, args: string[], extraEnv: Record<string, string | undefined> = {}, input?: string): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.FLIGHTDECK_STATE_DIR = "tmp";
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
	const [action, ...rest] = args;
	const full = action ? [action, "--session", SESSION, ...rest] : ["--session", SESSION];
	const r = spawnSync(SCRIPT, full, { cwd, encoding: "utf8", env, input });
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

function parseRunJson<T>(r: { stdout: string; status: number | null; stderr: string }): T {
	expect(r.status).toBe(0);
	if (r.stderr) expect(r.stderr).toBe("");
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

let repo = "";

beforeEach(() => { repo = makeRepo(); });
afterEach(() => { if (repo && existsSync(repo)) rmSync(repo, { force: true, recursive: true }); });

describe("flightdeck-state CLI", () => {
	test("init creates canonical state shape", () => {
		const r = run(repo, ["init"]);
		expect(r.status).toBe(0);
		const state = readState(repo) as { activity_path?: unknown; activity_schema_version?: unknown; entries?: unknown; owner?: unknown; session_id?: unknown; terminated?: unknown };
		expect(state.entries).toEqual({});
		expect(state.session_id).toBe(SESSION);
		expect(state.terminated).toBe(false);
		expect(state.owner).toBeTruthy();
		expect(String(state.activity_path).endsWith(`tmp/flightdeck-activity-${SESSION}.jsonl`)).toBe(true);
		expect(state.activity_schema_version).toBe(1);
	});

	test("init records owner metadata", () => {
		run(repo, ["init"]);
		expect((readState(repo) as { owner?: unknown }).owner).toEqual({
			cwd: "/tmp/flightdeck-owner-parity",
			harness: "pi",
			pane_id: "%42",
			pane_target: "PARITY:7.0",
			pid: 4242,
			pi_session_id: "pi-session-parity",
			pi_bridge_socket: "/tmp/pi-session-bridge/parity.sock",
			discovery_error: null,
		});
	});

	test("init prefers TMUX_PANE when owner pane override is absent", () => {
		run(repo, ["init"], { FLIGHTDECK_OWNER_PANE_ID: undefined, TMUX: "/tmp/tmux-fake", TMUX_PANE: "%tmux-env" });
		expect((readState(repo) as { owner?: { pane_id?: unknown } }).owner?.pane_id).toBe("%tmux-env");
	});

	test("init is idempotent (rerun preserves existing state)", () => {
		run(repo, ["init"]);
		writeState(repo, { ...(readState(repo) as object), entries: { "MARKER": { id: "MARKER", kind: "adhoc" } } });
		run(repo, ["init"]);
		const state = readState(repo) as { entries?: Record<string, unknown> };
		expect(Object.keys(state.entries ?? {})).toEqual(["MARKER"]);
	});

	test("tracked-entries returns the .entries map", () => {
		const entry = sampleTrackedEntry();
		const state = { entries: { [entry.id]: entry }, merge_queue: [] };
		writeState(repo, state);
		const expected = { [entry.id]: entry };
		expect(readTrackedEntries(state)).toEqual(expected);
		expect(parseRunJson<Record<string, TrackedEntry>>(run(repo, ["tracked-entries"]))).toEqual(expected);
	});

	test("tracked-entries skips malformed entry values with a warning", () => {
		const state = { entries: { "BAD": "not-an-object" } };
		writeState(repo, state);
		const r = run(repo, ["tracked-entries"]);
		expect(r.status).toBe(0);
		expect(r.stderr).toContain('invalid .entries value(s) for "BAD"');
		expect(JSON.parse(r.stdout)).toEqual({});
	});

	test("tracked-entries warns and falls back to key for malformed internal entry id", () => {
		const entry = { ...sampleTrackedEntry(), id: "bad id" };
		const state = { entries: { "CC-1": entry } };
		writeState(repo, state);
		const r = run(repo, ["tracked-entries"]);
		expect(r.status).toBe(0);
		expect(r.stderr).toContain('invalid .entries["CC-1"].id "bad id"');
		const parsed = JSON.parse(r.stdout) as Record<string, TrackedEntry>;
		expect(parsed["CC-1"]?.id).toBe("CC-1");
	});

	test("write-entry round-trips through tracked-entries", () => {
		const entry = sampleTrackedEntry();
		run(repo, ["init"]);
		const write = run(repo, ["write-entry", entry.id, JSON.stringify(entry)]);
		expect(write.status).toBe(0);
		const state = readState(repo) as { entries?: Record<string, TrackedEntry> };
		expect(state.entries?.[entry.id]).toEqual(entry);
		const tracked = parseRunJson<Record<string, TrackedEntry>>(run(repo, ["tracked-entries"]));
		expect(tracked[entry.id]).toEqual(entry);
	});

	test("write-entry canonicalizes padded entry and domain issue ids before storing", () => {
		const padded = {
			...sampleTrackedEntry(),
			domain: { issue: { ...sampleTrackedEntry().domain!.issue!, id: " CC-1 " } },
			id: " CC-1 ",
		};
		run(repo, ["init"]);
		const write = run(repo, ["write-entry", " CC-1 ", JSON.stringify(padded)]);
		expect(write.status).toBe(0);
		const state = readState(repo) as { entries?: Record<string, TrackedEntry> };
		expect(state.entries?.["CC-1"]?.id).toBe("CC-1");
		expect(state.entries?.["CC-1"]?.domain?.issue?.id).toBe("CC-1");
		expect(Object.keys(state.entries ?? {})).toEqual(["CC-1"]);
	});

	test("entry id validation rejects blank ids in helpers and CLI", () => {
		expect(entryIdForIssue("")).toBeNull();
		const entry = sampleTrackedEntry();
		expect(() => writeTrackedEntry({}, " ", { ...entry, id: " " })).toThrow(/invalid entry id/);
		run(repo, ["init"]);
		const blankArg = run(repo, ["write-entry", " ", JSON.stringify({ ...entry, id: " " })]);
		expect(blankArg.status).toBe(2);
		expect(blankArg.stderr).toContain("Error: invalid entry id: must be non-empty and match ^[A-Za-z0-9._-]+$");
		const blankJsonId = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, id: " " })]);
		expect(blankJsonId.status).toBe(2);
		expect(blankJsonId.stderr).toContain("Error: invalid entry.id: must be non-empty and match ^[A-Za-z0-9._-]+$");
	});

	test("write-entry rejects blank and malformed domain.issue.id", () => {
		const entry = sampleTrackedEntry();
		expect(() => writeTrackedEntry({}, entry.id, { ...entry, domain: { issue: { ...entry.domain!.issue!, id: "" } } })).toThrow(/invalid domain.issue.id/);
		run(repo, ["init"]);
		const blank = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { issue: { ...entry.domain!.issue!, id: "" } } })]);
		expect(blank.status).toBe(2);
		expect(blank.stderr).toContain("Error: invalid domain.issue.id: must be non-empty and match ^[A-Za-z0-9._-]+$");
		const malformed = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { issue: { ...entry.domain!.issue!, id: "bad id" } } })]);
		expect(malformed.status).toBe(2);
		expect(malformed.stderr).toContain("Error: invalid domain.issue.id: must be non-empty and match ^[A-Za-z0-9._-]+$");
	});

	test("pi owner discovery failure warns and persists discovery_error", () => {
		const r = run(repo, ["init"], {
			FLIGHTDECK_OWNER_HARNESS: "pi",
			FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET: undefined,
			FLIGHTDECK_OWNER_PI_SESSION_ID: undefined,
			PI_BRIDGE_SOCKET_PATH: undefined,
			PI_SESSION_ID: undefined,
			PATH: "/usr/bin:/bin",
		});
		expect(r.status).toBe(0);
		expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed (pi_bridge_not_found); proceeding with null pi_session_id/pi_bridge_socket.");
	});

	test("pi owner discovery timeout warns and persists discovery_error", () => {
		const stub = writePiBridgeStub(repo, "sleep 10");
		const start = Date.now();
		const r = run(repo, ["init"], {
			FLIGHTDECK_OWNER_HARNESS: "pi",
			FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET: undefined,
			FLIGHTDECK_OWNER_PI_SESSION_ID: undefined,
			FLIGHTDECK_PI_BRIDGE_DISCOVERY_TIMEOUT_MS: "1000",
			PI_BRIDGE_SOCKET_PATH: undefined,
			PI_SESSION_ID: undefined,
			PATH: `${stub}:/usr/bin:/bin`,
		});
		expect(Date.now() - start).toBeLessThan(3500);
		expect(r.status).toBe(0);
		expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed (pi_bridge_timeout); proceeding with null pi_session_id/pi_bridge_socket.");
	});

	test("pi owner discovery falls back from helper pid to bridge cwd", () => {
		const stub = writePiBridgeStub(repo, `
if [[ "$*" == "list --json --pid 4242" ]]; then
  printf '%s\n' '[]'
else
  printf '%s\n' '[{"pid":5151,"sessionId":"pi-cwd-session","socketPath":"/tmp/pi-cwd.sock","cwd":"/tmp/flightdeck-owner-parity"}]'
fi
`);
		const r = run(repo, ["init"], {
			FLIGHTDECK_OWNER_HARNESS: "pi",
			FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET: undefined,
			FLIGHTDECK_OWNER_PI_SESSION_ID: undefined,
			PI_BRIDGE_SOCKET_PATH: undefined,
			PI_SESSION_ID: undefined,
			PATH: `${stub}:/usr/bin:/bin`,
		});
		expect(r.status).toBe(0);
		expect(r.stderr).toBe("");
		const owner = (readState(repo) as { owner?: { discovery_error?: string | null; pi_session_id?: string; pi_bridge_socket?: string | null } }).owner;
		expect(owner).toMatchObject({
			discovery_error: null,
			pi_bridge_socket: "/tmp/pi-cwd.sock",
			pi_session_id: "pi-cwd-session",
		});
	});


	test("non-pi explicit owner harness skips pi cwd fallback", () => {
		const stub = writePiBridgeStub(repo, `
printf '%s\n' '[{"pid":5151,"sessionId":"pi-cwd-session","socketPath":"/tmp/pi-cwd.sock","cwd":"/tmp/flightdeck-owner-parity"}]'
`);
		const r = run(repo, ["init"], {
			FLIGHTDECK_OWNER_HARNESS: "claude",
			FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET: undefined,
			FLIGHTDECK_OWNER_PI_SESSION_ID: undefined,
			PI_BRIDGE_SOCKET_PATH: undefined,
			PI_SESSION_ID: undefined,
			PATH: `${stub}:/usr/bin:/bin`,
		});
		expect(r.status).toBe(0);
		expect(r.stderr).toBe("");
		const owner = (readState(repo) as { owner?: { harness?: string; discovery_error?: string | null; pi_session_id?: string | null; pi_bridge_socket?: string | null } }).owner;
		expect(owner).toMatchObject({
			discovery_error: null,
			harness: "claude",
			pi_bridge_socket: null,
			pi_session_id: null,
		});
	});

	test("pi owner cwd fallback warns on ambiguous cwd matches", () => {
		const stub = writePiBridgeStub(repo, `
if [[ "$*" == "list --json --pid 4242" ]]; then
  printf '%s\n' '[]'
else
  printf '%s\n' '[{"pid":5151,"sessionId":"pi-cwd-a","socketPath":"/tmp/pi-cwd-a.sock","cwd":"/tmp/flightdeck-owner-parity"},{"pid":5152,"sessionId":"pi-cwd-b","socketPath":"/tmp/pi-cwd-b.sock","cwd":"/tmp/flightdeck-owner-parity"}]'
fi
`);
		const r = run(repo, ["init"], {
			FLIGHTDECK_OWNER_HARNESS: "pi",
			FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET: undefined,
			FLIGHTDECK_OWNER_PI_SESSION_ID: undefined,
			PI_BRIDGE_SOCKET_PATH: undefined,
			PI_SESSION_ID: undefined,
			PATH: `${stub}:/usr/bin:/bin`,
		});
		expect(r.status).toBe(0);
		expect(r.stderr).toContain("pi_bridge_ambiguous_cwd");
		const owner = (readState(repo) as { owner?: { discovery_error?: string | null; pi_session_id?: string | null; pi_bridge_socket?: string | null } }).owner;
		expect(owner).toMatchObject({
			discovery_error: "pi_bridge_ambiguous_cwd",
			pi_bridge_socket: null,
			pi_session_id: null,
		});
	});

	test("pi owner partial bridge metadata warns and persists discovery_error", () => {
		const stub = writePiBridgeStub(repo, "printf '%s\\n' '[{\"pid\":4242,\"sessionId\":\"pi-session-only\"}]'");
		const r = run(repo, ["init"], {
			FLIGHTDECK_OWNER_HARNESS: "pi",
			FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET: undefined,
			FLIGHTDECK_OWNER_PI_SESSION_ID: undefined,
			PI_BRIDGE_SOCKET_PATH: undefined,
			PI_SESSION_ID: undefined,
			PATH: `${stub}:/usr/bin:/bin`,
		});
		expect(r.status).toBe(0);
		expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed (pi_bridge_partial_metadata); proceeding with null pi_session_id/pi_bridge_socket.");
		const owner = (readState(repo) as { owner?: { discovery_error?: string; pi_session_id?: string; pi_bridge_socket?: string | null } }).owner;
		expect(owner).toMatchObject({
			discovery_error: "pi_bridge_partial_metadata",
			pi_bridge_socket: null,
			pi_session_id: "pi-session-only",
		});
	});

	test("set + get round-trip on tracked entries", () => {
		run(repo, ["init"]);
		run(repo, ["set", "terminated", "true"]);
		run(repo, ["set", `.entries["CC-001"]`, '{"id":"CC-001","kind":"adhoc","state":"waiting"}']);
		const r = run(repo, ["get", `.entries["CC-001"].state`]);
		expect(r.stdout.trim()).toBe("waiting");
	});

	test("append adds to an array field", () => {
		run(repo, ["init"]);
		run(repo, ["append", "merge_queue", '"CC-001"']);
		run(repo, ["append", "merge_queue", '"CC-002"']);
		const state = readState(repo) as { merge_queue?: string[] };
		expect(state.merge_queue).toEqual(["CC-001", "CC-002"]);
	});

	test("increment bumps integer fields", () => {
		run(repo, ["init"]);
		run(repo, ["increment", "tick_count"]);
		run(repo, ["increment", "tick_count"]);
		run(repo, ["increment", "tick_count"]);
		expect(run(repo, ["get", ".tick_count"]).stdout.trim()).toBe("3");
	});

	test("path returns canonical state file path", () => {
		const r = run(repo, ["path"]);
		expect(r.stdout.endsWith(`tmp/flightdeck-state-${SESSION}.json\n`)).toBe(true);
	});

	test("activity path returns canonical activity JSONL path", () => {
		const r = run(repo, ["activity", "path"]);
		expect(r.status).toBe(0);
		expect(r.stdout.endsWith(`tmp/flightdeck-activity-${SESSION}.jsonl\n`)).toBe(true);
	});

	test("activity append tail and export expose the CLI contract", () => {
		const activityFile = join(repo, "tmp", `flightdeck-activity-${SESSION}.jsonl`);
		const append = run(repo, ["activity", "append", JSON.stringify({
			entry_id: "A1",
			natural_key: "A1:start",
			severity: "success",
			source: "flightdeck",
			summary: "A1 registered",
			type: "entry.registered",
		})]);
		expect(append.status).toBe(0);
		const appendResult = JSON.parse(append.stdout) as { deduped?: boolean; id?: string };
		expect(appendResult.deduped).toBe(false);
		expect(typeof appendResult.id).toBe("string");
		const firstEvent = JSON.parse(readFileSync(activityFile, "utf8").trim()) as { id?: string; schema_version?: number; session_id?: string };
		expect(firstEvent.id).toBe(appendResult.id);
		expect(firstEvent.schema_version).toBe(1);
		expect(firstEvent.session_id).toBe(SESSION);

		const duplicate = run(repo, ["activity", "append", JSON.stringify({
			entry_id: "A1",
			natural_key: "A1:start",
			severity: "success",
			source: "flightdeck",
			summary: "A1 registered",
			type: "entry.registered",
		})]);
		expect(duplicate.status).toBe(0);
		expect(JSON.parse(duplicate.stdout)).toEqual({ deduped: true, id: appendResult.id });
		expect(readFileSync(activityFile, "utf8").trim().split("\n")).toHaveLength(1);

		const stdinAppend = run(repo, ["activity", "append"], {}, JSON.stringify({
			entry_id: "A2",
			natural_key: "A2:start",
			source: "daemon",
			summary: "A2 registered",
			type: "daemon.started",
		}));
		expect(stdinAppend.status).toBe(0);
		expect((JSON.parse(stdinAppend.stdout) as { deduped?: boolean }).deduped).toBe(false);

		const tail = run(repo, ["activity", "tail", "--json", "--limit", "5"]);
		expect(tail.status).toBe(0);
		const tailLines = tail.stdout.trim().split("\n");
		expect(tailLines).toHaveLength(2);
		expect(JSON.parse(tailLines[0]!) as { type: string }).toMatchObject({ type: "entry.registered" });

		const raw = readFileSync(activityFile, "utf8");
		const exported = run(repo, ["activity", "export", "--format", "jsonl"]);
		expect(exported.status).toBe(0);
		expect(exported.stdout).toBe(raw);
		const rawLines = raw.trim().split("\n");
		const filtered = run(repo, ["activity", "export", "--format", "jsonl", "--filter", "type=entry.registered,entry=A1"]);
		expect(filtered.status).toBe(0);
		expect(filtered.stdout).toBe(`${rawLines[0]}\n`);

		const markdown = run(repo, ["activity", "export", "--format", "markdown", "--filter", "type=entry.registered"]);
		expect(markdown.status).toBe(0);
		expect(markdown.stdout).toContain("A1 registered");
	});

	test("activity export honors --session and --state-file overrides", () => {
		run(repo, ["init"]);
		run(repo, ["activity", "append", JSON.stringify({
			entry_id: "PRIMARY",
			natural_key: "PRIMARY:start",
			source: "flightdeck",
			summary: "primary session line",
			type: "entry.registered",
		})]);
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		const altSession = "ALT";
		const altActivity = join(stateDir, `flightdeck-activity-${altSession}.jsonl`);
		const altEvent = {
			entry_id: "ALT1",
			id: "alt-1",
			natural_key: "ALT1:start",
			schema_version: 1,
			session_id: altSession,
			source: "flightdeck",
			summary: "alt session line",
			ts: "2026-05-15T10:00:00Z",
			type: "entry.registered",
		};
		writeFileSync(altActivity, `${JSON.stringify(altEvent)}\n`, "utf8");

		const exportedBySession = run(repo, ["activity", "export", "--session", altSession]);
		expect(exportedBySession.status).toBe(0);
		expect(exportedBySession.stdout).toBe(`${JSON.stringify(altEvent)}\n`);
		expect(exportedBySession.stdout).not.toContain("primary session line");

		const altStateFile = join(stateDir, `flightdeck-state-${altSession}.json`);
		writeFileSync(altStateFile, JSON.stringify({ session_id: altSession }), "utf8");
		const exportedByStateFile = run(repo, ["activity", "export", "--state-file", altStateFile]);
		expect(exportedByStateFile.status).toBe(0);
		expect(exportedByStateFile.stdout).toBe(`${JSON.stringify(altEvent)}\n`);

		const defaultExport = run(repo, ["activity", "export", "--format", "jsonl"]);
		expect(defaultExport.status).toBe(0);
		expect(defaultExport.stdout).toContain("primary session line");
	});

	test("activity append and filters reject invalid input", () => {
		const invalidSeverity = run(repo, ["activity", "append", JSON.stringify({
			severity: "bad",
			source: "flightdeck",
			summary: "bad",
			type: "entry.registered",
		})]);
		expect(invalidSeverity.status).not.toBe(0);
		expect(invalidSeverity.stderr).toContain("Error: invalid activity severity");

		run(repo, ["activity", "append", JSON.stringify({ natural_key: "ok", source: "flightdeck", summary: "ok", type: "entry.registered" })]);
		const badSyntax = run(repo, ["activity", "tail", "--json", "--filter", "severity:warning"]);
		expect(badSyntax.status).not.toBe(0);
		expect(badSyntax.stderr).toContain("Error: invalid activity filter clause");
		const unknownKey = run(repo, ["activity", "export", "--filter", "id=abc"]);
		expect(unknownKey.status).not.toBe(0);
		expect(unknownKey.stderr).toContain("Error: invalid activity filter key: id");
	});

	test("archive moves state and activity sidecars with .archive suffix using terminated_at when set", () => {
		run(repo, ["init"]);
		run(repo, ["activity", "append", JSON.stringify({ natural_key: "start", source: "flightdeck", summary: "started", type: "session.started" })]);
		run(repo, ["set", "terminated_at", '"2026-05-11T00:00:00Z"']);
		const r = run(repo, ["archive"]);
		expect(r.status).toBe(0);
		expect(r.stdout).toMatch(/-2026-05-11T000000Z\.json\.archive\n$/);
		const archived = JSON.parse(readFileSync(r.stdout.trim(), "utf8")) as { activity_archive_path?: string };
		expect(archived.activity_archive_path).toMatch(/flightdeck-activity-PARITY-2026-05-11T000000Z\.jsonl\.archive$/);
		expect(existsSync(archived.activity_archive_path!)).toBe(true);
		expect(readFileSync(archived.activity_archive_path!, "utf8")).toContain("session.started");
		expect(existsSync(join(repo, "tmp", `flightdeck-activity-${SESSION}.jsonl.archived`))).toBe(true);
	});

	test("activity append after archive reports archived without recreating live sidecar", () => {
		run(repo, ["init"]);
		run(repo, ["activity", "append", JSON.stringify({ natural_key: "start", source: "flightdeck", summary: "started", type: "session.started" })]);
		run(repo, ["set", "terminated_at", '"2026-05-11T00:00:00Z"']);
		const archive = run(repo, ["archive"]);
		expect(archive.status).toBe(0);
		const liveActivity = join(repo, "tmp", `flightdeck-activity-${SESSION}.jsonl`);
		const append = run(repo, ["activity", "append", JSON.stringify({ natural_key: "after", source: "flightdeck", summary: "after archive", type: "entry.registered" })]);
		expect(append.status).toBe(0);
		const appendResult = JSON.parse(append.stdout) as { archived?: boolean; deduped?: boolean; id?: string };
		expect(typeof appendResult.id).toBe("string");
		expect(appendResult.deduped).toBe(false);
		expect(appendResult.archived).toBe(true);
		expect(append.stderr).toContain("activity file is archived; skipping append");
		expect(existsSync(liveActivity)).toBe(false);
		const archived = JSON.parse(readFileSync(archive.stdout.trim(), "utf8")) as { activity_archive_path?: string };
		expect(readFileSync(archived.activity_archive_path!, "utf8")).not.toContain("after archive");
	});

	// Regression: issue #17. terminate.md § 5 previously ran
	// `pane-registry remove-merged` between `set terminated true` and
	// `archive`, deleting merged-issue history from the archive. The
	// workflow now skips remove-merged on terminate; this pins the
	// archive contract directly against `flightdeck-state` so future
	// refactors don't reintroduce the data loss.
	test("terminate sequence preserves merged-entry history in archive (issue #17)", () => {
		run(repo, ["init"]);
		const entry = {
			...sampleTrackedEntry(),
			id: "CC-503",
			state: "merged",
			domain: { issue: { id: "CC-503", pr_number: 81, merge_commit: "156d9df02ce8fb3a798f233c73e489338db969f9", worktree: "/repo/trees/CC-503" } },
			decisions_log: [
				{ ts: "2026-05-13T00:00:01Z", prompt_tag: "review-fix", answer: "apply" },
				{ ts: "2026-05-13T00:10:00Z", prompt_tag: "merge-now", answer: "yes" },
				{ ts: "2026-05-13T00:15:35Z", prompt_tag: "terminal-state-reached", answer: "merged" },
			],
		};
		run(repo, ["write-entry", entry.id, JSON.stringify(entry)]);
		run(repo, ["set", "terminated", "true"]);
		run(repo, ["set", "terminated_at", '"2026-05-13T00:21:28Z"']);
		run(repo, ["set", "summary_path", '"tmp/flightdeck-summary-HT-2026-05-13T002128Z.md"']);
		const archive = run(repo, ["archive"]);
		expect(archive.status).toBe(0);
		const data = JSON.parse(readFileSync(archive.stdout.trim(), "utf8"));
		expect(data.terminated).toBe(true);
		expect(data.terminated_at).toBe("2026-05-13T00:21:28Z");
		expect(data.summary_path).toBe("tmp/flightdeck-summary-HT-2026-05-13T002128Z.md");
		expect(Object.keys(data.entries)).toEqual(["CC-503"]);
		expect(data.entries["CC-503"].state).toBe("merged");
		expect(data.entries["CC-503"].domain.issue.pr_number).toBe(81);
		expect(data.entries["CC-503"].domain.issue.merge_commit).toBe("156d9df02ce8fb3a798f233c73e489338db969f9");
		expect(data.entries["CC-503"].decisions_log).toHaveLength(3);
		expect(data.entries["CC-503"].decisions_log[2].prompt_tag).toBe("terminal-state-reached");
	});
});
