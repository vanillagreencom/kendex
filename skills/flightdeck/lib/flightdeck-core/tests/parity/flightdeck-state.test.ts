// flightdeck-state CLI behavior. Runs against an isolated tmp git repo
// per test and asserts subcommand outputs + on-disk state.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveProjectRoot } from "../../src/shared/project.ts";
import { entryIdForIssue, readTrackedEntries, writeTrackedEntry } from "../../src/state/tracked-entry.ts";
import type { TrackedEntry } from "../../src/state/types.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-state");
const PROJECT_ROOT = resolveProjectRoot(resolve(HERE, "../../../../../.."));
const SESSION = "PARITY";

function makeRepo(): string {
	const dir = mkdtempSync(join(tmpdir(), "fdstate-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", "init"], {
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

function runDirect(cwd: string, args: string[], extraEnv: Record<string, string | undefined> = {}, input?: string): { stdout: string; stderr: string; status: number | null } {
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
	const r = spawnSync(SCRIPT, args, { cwd, encoding: "utf8", env, input });
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

function samplePlanEntry(projectRoot = PROJECT_ROOT): TrackedEntry {
	const briefPath = join(projectRoot, "tmp", "plan-briefs", "plan", "item-one.md");
	return {
		cwd: join(projectRoot, "trees", "flightdeck-plan-item-one"),
		decisions_log: [],
		domain: {
			plan_item: {
				brief_artifact_path: briefPath,
				brief_sha256: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
				depends_on: ["setup-foundation"],
				item_id: "item-one",
				item_title: "Item one",
				merge_commit: null,
				omitted_context: ["Pre-execution context"],
				parse_mode: "phase-style",
				plan_path: join(projectRoot, "docs", "plans", "plan.md"),
				plan_snapshot_sha256: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				plan_title: "Plan title",
				pr_number: null,
				worktree: join(projectRoot, "trees", "flightdeck-plan-item-one"),
			},
		},
		harness: "pi",
		id: "item-one",
		kind: "workflow",
		state: "waiting",
		title: "Item one",
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

	test("write-entry accepts plan item domain entries", () => {
		expect(() => writeTrackedEntry({}, samplePlanEntry().id, samplePlanEntry())).not.toThrow();
		const entry = samplePlanEntry(repo);
		run(repo, ["init"]);
		const write = run(repo, ["write-entry", entry.id, JSON.stringify(entry)]);
		expect(write.status).toBe(0);
		const tracked = parseRunJson<Record<string, TrackedEntry>>(run(repo, ["tracked-entries"]));
		expect(tracked[entry.id]?.domain?.plan_item).toMatchObject({
			brief_artifact_path: join(repo, "tmp", "plan-briefs", "plan", "item-one.md"),
			brief_sha256: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			depends_on: ["setup-foundation"],
			item_id: "item-one",
			merge_commit: null,
			omitted_context: ["Pre-execution context"],
			parse_mode: "phase-style",
			plan_path: join(repo, "docs", "plans", "plan.md"),
			plan_snapshot_sha256: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			plan_title: "Plan title",
			pr_number: null,
			worktree: join(repo, "trees", "flightdeck-plan-item-one"),
		});
	});

	test("tracked-entries fails loud instead of omitting invalid plan item brief paths", () => {
		const directEntry = samplePlanEntry();
		const directInvalid = {
			...directEntry,
			domain: { plan_item: { ...directEntry.domain!.plan_item!, brief_artifact_path: "/tmp/outside/plan-briefs/plan/item-one.md" } },
		};
		const warnings: string[] = [];
		expect(readTrackedEntries({ entries: { [directInvalid.id]: directInvalid } }, { warn: (message) => warnings.push(message) })).toEqual({});
		expect(warnings.join("\n")).toContain('Warning: invalid .entries["item-one"].domain: invalid domain.plan_item.brief_artifact_path');
		expect(() => readTrackedEntries({ entries: { [directInvalid.id]: directInvalid } }, { strictPlanItemDomain: true })).toThrow(/invalid \.entries\["item-one"\]\.domain: invalid domain\.plan_item\.brief_artifact_path/);

		const entry = samplePlanEntry(repo);
		const invalid = {
			...entry,
			domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: "/tmp/outside/plan-briefs/plan/item-one.md" } },
		};
		writeState(repo, { entries: { [invalid.id]: invalid } });
		const r = run(repo, ["tracked-entries"]);
		expect(r.status).toBe(2);
		expect(r.stdout).toBe("");
		expect(r.stderr).toContain('Error: invalid .entries["item-one"].domain: invalid domain.plan_item.brief_artifact_path');
		expect(r.stderr).toContain("must be under state-owned plan-briefs root");
	});

	test("write-entry rejects plan item mixed with Linear or GitHub domains", () => {
		const plan = samplePlanEntry();
		const linear = sampleTrackedEntry().domain!.issue!;
		const github = { merge_commit: null, number: 77, pr_number: null, url: "https://github.com/OWNER/REPO/issues/77", worktree: "/repo/trees/issue-77" };
		expect(() => writeTrackedEntry({}, plan.id, { ...plan, domain: { issue: linear, plan_item: plan.domain!.plan_item! } })).toThrow(/mutually exclusive/);
		expect(() => writeTrackedEntry({}, plan.id, { ...plan, domain: { github_issue: github, plan_item: plan.domain!.plan_item! } })).toThrow(/mutually exclusive/);

		run(repo, ["init"]);
		const cliPlan = samplePlanEntry(repo);
		const withLinear = run(repo, ["write-entry", cliPlan.id, JSON.stringify({ ...cliPlan, domain: { issue: linear, plan_item: cliPlan.domain!.plan_item! } })]);
		expect(withLinear.status).toBe(2);
		expect(withLinear.stderr).toContain("mutually exclusive");
		const withGithub = run(repo, ["write-entry", cliPlan.id, JSON.stringify({ ...cliPlan, domain: { github_issue: github, plan_item: cliPlan.domain!.plan_item! } })]);
		expect(withGithub.status).toBe(2);
		expect(withGithub.stderr).toContain("mutually exclusive");
	});

	test("write-entry rejects malformed plan item fields", () => {
		const localEntry = samplePlanEntry();
		expect(() => writeTrackedEntry({}, localEntry.id, { ...localEntry, domain: { plan_item: { ...localEntry.domain!.plan_item!, depends_on: ["bad dep"] } } })).toThrow(/domain.plan_item.depends_on/);
		const entry = samplePlanEntry(repo);
		run(repo, ["init"]);
		const missingMergeCommit = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, merge_commit: undefined } } })]);
		expect(missingMergeCommit.status).toBe(2);
		expect(missingMergeCommit.stderr).toContain("invalid domain.plan_item.merge_commit: missing required key");
		const badBriefHash = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_sha256: "not-a-hash" } } })]);
		expect(badBriefHash.status).toBe(2);
		expect(badBriefHash.stderr).toContain("invalid domain.plan_item.brief_sha256: must be sha256:<64 hex chars> or null");
		const missingBriefPath = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: undefined } } })]);
		expect(missingBriefPath.status).toBe(2);
		expect(missingBriefPath.stderr).toContain("brief_artifact_path/domain.plan_item.brief_sha256: both keys must be present together or omitted together");
		const relativeBrief = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: "tmp/plan-briefs/plan/item-one.md" } } })]);
		expect(relativeBrief.status).toBe(2);
		expect(relativeBrief.stderr).toContain("invalid domain.plan_item.brief_artifact_path: must be an absolute path under a state-owned plan-briefs directory");
		const fakeOutsideWithPlanBriefs = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: "/tmp/outside/plan-briefs/plan/item-one.md" } } })]);
		expect(fakeOutsideWithPlanBriefs.status).toBe(2);
		expect(fakeOutsideWithPlanBriefs.stderr).toContain("invalid domain.plan_item.brief_artifact_path: must be under state-owned plan-briefs root");
		const missingUnderRoot = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: join(repo, "tmp", "plan-briefs", "missing", "item-one.md") } } })]);
		expect(missingUnderRoot.status).toBe(0);
		const traversalBrief = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: `${join(repo, "tmp", "plan-briefs")}/../item-one.md` } } })]);
		expect(traversalBrief.status).toBe(2);
		expect(traversalBrief.stderr).toContain("invalid domain.plan_item.brief_artifact_path: must be normalized with no traversal segments");
		const outOfStateBrief = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: "/tmp/outside/item-one.md" } } })]);
		expect(outOfStateBrief.status).toBe(2);
		expect(outOfStateBrief.stderr).toContain("invalid domain.plan_item.brief_artifact_path: must be under state-owned plan-briefs root");
		const wrongFilename = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: join(repo, "tmp", "plan-briefs", "plan", "other.md") } } })]);
		expect(wrongFilename.status).toBe(2);
		expect(wrongFilename.stderr).toContain("invalid domain.plan_item.brief_artifact_path: filename must be item-one.md");
		const controlCharBrief = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: `${join(repo, "tmp", "plan-briefs", "plan", "item-one.md")}\u0000` } } })]);
		expect(controlCharBrief.status).toBe(2);
		expect(controlCharBrief.stderr).toContain("invalid domain.plan_item.brief_artifact_path: must not contain control characters");
		const missingSnapshotHash = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, plan_snapshot_sha256: undefined } } })]);
		expect(missingSnapshotHash.status).toBe(2);
		expect(missingSnapshotHash.stderr).toContain("invalid domain.plan_item.plan_snapshot_sha256: required when brief_artifact_path is present");

		const symlinkRoot = join(repo, "tmp", "plan-briefs");
		mkdirSync(symlinkRoot, { recursive: true });
		const symlinkPlanOutside = mkdtempSync(join(repo, "plan-outside-"));
		const symlinkPlanDir = join(symlinkRoot, "evil-plan");
		symlinkSync(symlinkPlanOutside, symlinkPlanDir, "dir");
		const missingViaSymlink = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: join(symlinkPlanDir, "missing", "item-one.md") } } })]);
		expect(missingViaSymlink.status).toBe(2);
		expect(missingViaSymlink.stderr).toContain("invalid domain.plan_item.brief_artifact_path: must not traverse symlinks");
		rmSync(symlinkPlanDir, { force: true, recursive: true });

		const outsideState = mkdtempSync(join(tmpdir(), "fd-state-outside-"));
		const stateLink = join(repo, "tmp", "state-link");
		symlinkSync(outsideState, stateLink, "dir");
		expect(run(repo, ["init"], { FLIGHTDECK_STATE_DIR: "tmp/state-link" }).status).toBe(0);
		const stateLinkBriefPath = join(stateLink, "plan-briefs", "plan", "item-one.md");
		const stateDirSymlinkMissing = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: stateLinkBriefPath } } })], { FLIGHTDECK_STATE_DIR: "tmp/state-link" });
		expect(stateDirSymlinkMissing.status).toBe(2);
		expect(stateDirSymlinkMissing.stderr).toContain("invalid domain.plan_item.brief_artifact_path: state directory must not be a symlink");
		mkdirSync(join(outsideState, "plan-briefs", "plan"), { recursive: true });
		writeFileSync(join(outsideState, "plan-briefs", "plan", "item-one.md"), "brief", "utf8");
		const stateDirSymlinkExisting = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: stateLinkBriefPath } } })], { FLIGHTDECK_STATE_DIR: "tmp/state-link" });
		expect(stateDirSymlinkExisting.status).toBe(2);
		expect(stateDirSymlinkExisting.stderr).toContain("invalid domain.plan_item.brief_artifact_path: state directory must not be a symlink");
		rmSync(outsideState, { force: true, recursive: true });
		rmSync(stateLink, { force: true, recursive: true });

		const outside = mkdtempSync(join(repo, "outside-"));
		rmSync(symlinkRoot, { force: true, recursive: true });
		symlinkSync(outside, symlinkRoot, "dir");
		const symlinkEscapePath = join(symlinkRoot, "plan", "item-one.md");
		const symlinkEscape = run(repo, ["write-entry", entry.id, JSON.stringify({ ...entry, domain: { plan_item: { ...entry.domain!.plan_item!, brief_artifact_path: symlinkEscapePath } } })]);
		expect(symlinkEscape.status).toBe(2);
		expect(symlinkEscape.stderr).toContain("invalid domain.plan_item.brief_artifact_path: plan-briefs root must not be a symlink");
	});

	test("raw set rejects adding plan_item beside Linear issue domain", () => {
		const entry = sampleTrackedEntry();
		const plan = samplePlanEntry(repo).domain!.plan_item!;
		run(repo, ["init"]);
		expect(run(repo, ["write-entry", entry.id, JSON.stringify(entry)]).status).toBe(0);
		const r = run(repo, ["set", `.entries[${JSON.stringify(entry.id)}].domain.plan_item`, JSON.stringify(plan)]);
		expect(r.status).toBe(2);
		expect(r.stderr).toContain("invalid domain mutation");
		expect(r.stderr).toContain("mutually exclusive");
		const tracked = parseRunJson<Record<string, TrackedEntry>>(run(repo, ["tracked-entries"]));
		expect(tracked[entry.id]?.domain?.plan_item).toBeUndefined();
	});

	test("raw set rejects adding plan_item beside GitHub issue domain", () => {
		const github: TrackedEntry = {
			domain: { github_issue: { merge_commit: null, number: 77, pr_number: null, url: "https://github.com/OWNER/REPO/issues/77", worktree: "/repo/trees/issue-77" } },
			id: "77",
			kind: "issue",
			state: "waiting",
		};
		const plan = samplePlanEntry(repo).domain!.plan_item!;
		run(repo, ["init"]);
		expect(run(repo, ["write-entry", github.id, JSON.stringify(github)]).status).toBe(0);
		const r = run(repo, ["set", `.entries[${JSON.stringify(github.id)}].domain.plan_item`, JSON.stringify(plan)]);
		expect(r.status).toBe(2);
		expect(r.stderr).toContain("invalid domain mutation");
		expect(r.stderr).toContain("mutually exclusive");
		const tracked = parseRunJson<Record<string, TrackedEntry>>(run(repo, ["tracked-entries"]));
		expect(tracked[github.id]?.domain?.plan_item).toBeUndefined();
	});

	test("raw set rejects all three domain keys at once", () => {
		const entry = samplePlanEntry(repo);
		const allDomains = {
			github_issue: { merge_commit: null, number: 77, pr_number: null, url: "https://github.com/OWNER/REPO/issues/77", worktree: "/repo/trees/issue-77" },
			issue: sampleTrackedEntry().domain!.issue!,
			plan_item: entry.domain!.plan_item!,
		};
		run(repo, ["init"]);
		expect(run(repo, ["write-entry", entry.id, JSON.stringify(entry)]).status).toBe(0);
		const r = run(repo, ["set", `.entries[${JSON.stringify(entry.id)}].domain`, JSON.stringify(allDomains)]);
		expect(r.status).toBe(2);
		expect(r.stderr).toContain("invalid domain mutation");
		expect(r.stderr).toContain("domain.issue, domain.github_issue, domain.plan_item are mutually exclusive");
		const tracked = parseRunJson<Record<string, TrackedEntry>>(run(repo, ["tracked-entries"]));
		expect(tracked[entry.id]?.domain?.issue).toBeUndefined();
		expect(tracked[entry.id]?.domain?.github_issue).toBeUndefined();
		expect(tracked[entry.id]?.domain?.plan_item?.item_id).toBe("item-one");
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

	test("run create active list show and terminate expose durable run state", () => {
		const home = join(repo, "home");
		const created = parseRunJson<{ metadata: { run_id: string; terminated: boolean }; active: { run_id: string } }>(
			run(repo, ["run", "create", "--project-root", repo, "--tmux-session", SESSION], { HOME: home }),
		);
		expect(created.metadata.terminated).toBe(false);
		expect(created.active.run_id).toBe(created.metadata.run_id);

		const active = parseRunJson<{ active: { run_id: string }; metadata: { run_id: string } }>(
			run(repo, ["run", "active", "--project-root", repo], { HOME: home }),
		);
		expect(active.active.run_id).toBe(created.metadata.run_id);
		expect(active.metadata.run_id).toBe(created.metadata.run_id);

		const listed = parseRunJson<{ runs: Array<{ run_id: string; terminated: boolean }> }>(
			run(repo, ["run", "list", "--project-root", repo, "--json"], { HOME: home }),
		);
		expect(listed.runs.map((item) => item.run_id)).toContain(created.metadata.run_id);

		const shown = parseRunJson<{ metadata: { run_id: string }; state: { session_id: string; terminated: boolean } }>(
			run(repo, ["run", "show", created.metadata.run_id, "--project-root", repo], { HOME: home }),
		);
		expect(shown.metadata.run_id).toBe(created.metadata.run_id);
		expect(shown.state.session_id).toBe(SESSION);
		expect(shown.state.terminated).toBe(false);

		const terminated = parseRunJson<{ active_cleared: boolean; metadata: { terminated: boolean; run_id: string }; snapshot_path: string }>(
			run(repo, ["run", "terminate", created.metadata.run_id, "--project-root", repo], { HOME: home }),
		);
		expect(terminated.active_cleared).toBe(true);
		expect(terminated.metadata.terminated).toBe(true);
		expect(existsSync(terminated.snapshot_path)).toBe(true);

		const activeAfter = run(repo, ["run", "active", "--project-root", repo], { HOME: home });
		expect(activeAfter.status).toBe(0);
		expect(JSON.parse(activeAfter.stdout)).toBeNull();
	});

	test("run terminate rejects explicit summary-path without a non-empty value", () => {
		const home = join(repo, "home-summary-usage");
		const created = parseRunJson<{ metadata: { run_id: string } }>(
			run(repo, ["run", "create", "--project-root", repo, "--tmux-session", SESSION], { HOME: home }),
		);

		for (const args of [
			["run", "terminate", created.metadata.run_id, "--project-root", repo, "--summary-path"],
			["run", "terminate", created.metadata.run_id, "--project-root", repo, "--summary-path", ""],
			["run", "terminate", created.metadata.run_id, "--project-root", repo, "--summary-path="],
			["run", "terminate", created.metadata.run_id, "--project-root", repo, "--summary-path", "--tmux-session", SESSION],
		]) {
			const r = run(repo, args, { HOME: home });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("Usage: --summary-path requires a non-empty value");
		}

		const activeAfter = parseRunJson<{ metadata: { terminated: boolean; run_id: string } }>(
			run(repo, ["run", "active", "--project-root", repo], { HOME: home }),
		);
		expect(activeAfter.metadata.run_id).toBe(created.metadata.run_id);
		expect(activeAfter.metadata.terminated).toBe(false);
	});

	test("run import-legacy copies archives without deleting legacy files", () => {
		const home = join(repo, "home");
		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		const archive = join(stateDir, "flightdeck-state-PARITY-2026-05-19T000000Z.json.archive");
		const activity = join(stateDir, "flightdeck-activity-PARITY-2026-05-19T000000Z.jsonl.archive");
		writeFileSync(activity, '{"type":"session.completed"}\n', "utf8");
		writeFileSync(archive, JSON.stringify({
			activity_archive_path: activity,
			entries: { A: { id: "A", kind: "adhoc", state: "complete" } },
			session_id: SESSION,
			started_at: "2026-05-19T00:00:00Z",
			terminated: true,
			terminated_at: "2026-05-19T00:00:00Z",
		}), "utf8");

		const imported = parseRunJson<{ imported: Array<{ activity_path: string; imported_from: string; run_id: string }>; skipped: unknown[] }>(
			run(repo, ["run", "import-legacy", "--project-root", repo, "--state-dir", "tmp"], { HOME: home }),
		);
		expect(imported.imported).toHaveLength(1);
		expect(imported.skipped).toHaveLength(0);
		expect(imported.imported[0]?.imported_from).toBe(archive);
		expect(readFileSync(imported.imported[0]!.activity_path, "utf8")).toContain("session.completed");
		expect(existsSync(archive)).toBe(true);
		expect(existsSync(activity)).toBe(true);

		const repeated = parseRunJson<{ imported: unknown[]; skipped: unknown[] }>(
			run(repo, ["run", "import-legacy", "--project-root", repo, "--state-dir", "tmp"], { HOME: home }),
		);
		expect(repeated.imported).toHaveLength(0);
		expect(repeated.skipped).toHaveLength(1);
	});

	test("run subcommands work without injected global --session", () => {
		const home = join(repo, "home-direct");
		const created = parseRunJson<{ metadata: { run_id: string }; active: { run_id: string } }>(
			runDirect(repo, ["run", "create", "--project-root", repo, "--tmux-session", "DIRECT"], { HOME: home }),
		);
		expect(created.active.run_id).toBe(created.metadata.run_id);
		const active = parseRunJson<{ active: { run_id: string } }>(
			runDirect(repo, ["run", "active", "--project-root", repo], { HOME: home }),
		);
		expect(active.active.run_id).toBe(created.metadata.run_id);
		const listed = parseRunJson<{ runs: Array<{ run_id: string }> }>(
			runDirect(repo, ["run", "list", "--project-root", repo, "--json"], { HOME: home }),
		);
		expect(listed.runs.map((item) => item.run_id)).toContain(created.metadata.run_id);
		const shown = parseRunJson<{ metadata: { run_id: string }; state: { session_id: string } }>(
			runDirect(repo, ["run", "show", created.metadata.run_id, "--project-root", repo], { HOME: home }),
		);
		expect(shown.state.session_id).toBe("DIRECT");
		const terminated = parseRunJson<{ active_cleared: boolean }>(
			runDirect(repo, ["run", "terminate", created.metadata.run_id, "--project-root", repo], { HOME: home }),
		);
		expect(terminated.active_cleared).toBe(true);

		const stateDir = join(repo, "tmp");
		mkdirSync(stateDir, { recursive: true });
		const archive = join(stateDir, "flightdeck-state-DIRECT-2026-05-19T000000Z.json.archive");
		const activity = join(stateDir, "flightdeck-activity-DIRECT-2026-05-19T000000Z.jsonl.archive");
		writeFileSync(activity, '{"type":"session.completed"}\n', "utf8");
		writeFileSync(archive, JSON.stringify({ entries: {}, terminated: true }), "utf8");
		const imported = parseRunJson<{ imported: Array<{ run_id: string; tmux_session: string }>; skipped: unknown[] }>(
			runDirect(repo, ["run", "import-legacy", "--project-root", repo, "--state-dir", "tmp"], { HOME: home }),
		);
		expect(imported.imported.map((item) => item.tmux_session)).toContain("DIRECT");
		const importedRun = imported.imported.find((item) => item.tmux_session === "DIRECT")!;
		const importedShown = parseRunJson<{ state: { session_id: string } }>(
			runDirect(repo, ["run", "show", importedRun.run_id, "--project-root", repo], { HOME: home }),
		);
		expect(importedShown.state.session_id).toBe("DIRECT");
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

	test("archive terminates active durable run after session.completed and preserves compatibility archive", () => {
		const home = join(repo, "home-archive-durable");
		run(repo, ["init"], { HOME: home });
		const entry = { ...sampleTrackedEntry(), id: "archive-entry", kind: "adhoc", pane_id: "%77", state: "complete" };
		run(repo, ["write-entry", entry.id, JSON.stringify(entry)], { HOME: home });
		const summaryRel = "tmp/flightdeck-summary-PARITY-2026-05-20T000000Z.md";
		writeFileSync(join(repo, summaryRel), "# Durable archive summary\n", "utf8");
		run(repo, ["set", "summary_path", JSON.stringify(summaryRel)], { HOME: home });
		run(repo, ["activity", "append", JSON.stringify({ natural_key: "archive-entry:done", source: "flightdeck", summary: "entry done", type: "entry.completed" })], { HOME: home });
		const created = parseRunJson<{ metadata: { run_id: string }; paths: { activity_jsonl: string; snapshots_dir: string; summary_md: string } }>(
			run(repo, ["run", "create", "--project-root", repo, "--tmux-session", SESSION], { HOME: home }),
		);
		run(repo, ["set", "terminated", "true"], { HOME: home });
		run(repo, ["set", "terminated_at", '"2026-05-20T00:00:00Z"'], { HOME: home });

		const archiveEnv = { FLIGHTDECK_ACTIVITY_FILE: undefined, FLIGHTDECK_MANAGED: undefined, HOME: home };
		const archived = run(repo, ["archive"], archiveEnv);
		expect(archived.status).toBe(0);
		expect(JSON.parse(run(repo, ["run", "active", "--project-root", repo], { HOME: home }).stdout)).toBeNull();

		const shown = parseRunJson<{ metadata: { summary_path: string | null; terminated: boolean }; snapshots: string[]; state: { entries: Record<string, unknown>; terminated: boolean } }>(
			run(repo, ["run", "show", created.metadata.run_id, "--project-root", repo], { HOME: home }),
		);
		expect(shown.metadata.terminated).toBe(true);
		expect(shown.metadata.summary_path).toBe(created.paths.summary_md);
		expect(readFileSync(created.paths.summary_md, "utf8")).toBe("# Durable archive summary\n");
		expect(shown.state.terminated).toBe(true);
		expect(shown.state.entries["archive-entry"]).toBeTruthy();

		const activitySnapshot = readdirSync(created.paths.snapshots_dir).find((name) => name.endsWith(".activity.jsonl"));
		expect(activitySnapshot).toBeTruthy();
		const durableActivitySnapshot = readFileSync(join(created.paths.snapshots_dir, activitySnapshot!), "utf8");
		expect(durableActivitySnapshot).toContain("entry.completed");
		expect(durableActivitySnapshot).toContain("session.completed");
		expect(readFileSync(created.paths.activity_jsonl, "utf8")).toContain("session.completed");

		const compatibilityArchive = JSON.parse(readFileSync(archived.stdout.trim(), "utf8")) as { activity_archive_path?: string; entries?: Record<string, unknown> };
		expect(compatibilityArchive.entries?.["archive-entry"]).toBeTruthy();
		expect(compatibilityArchive.activity_archive_path).toMatch(/flightdeck-activity-PARITY-2026-05-20T000000Z\.jsonl\.archive$/);
		expect(readFileSync(compatibilityArchive.activity_archive_path!, "utf8")).toContain("session.completed");
	});

	test("archive aborts before durable termination when required session.completed append fails", () => {
		const home = join(repo, "home-archive-append-failure");
		run(repo, ["init"], { HOME: home });
		const created = parseRunJson<{ metadata: { run_id: string } }>(
			run(repo, ["run", "create", "--project-root", repo, "--tmux-session", SESSION], { HOME: home }),
		);
		const liveActivity = join(repo, "tmp", `flightdeck-activity-${SESSION}.jsonl`);
		rmSync(liveActivity, { force: true });
		mkdirSync(liveActivity, { recursive: true });

		const archived = run(repo, ["archive"], { FLIGHTDECK_ACTIVITY_FILE: undefined, FLIGHTDECK_MANAGED: undefined, HOME: home });
		expect(archived.status).not.toBe(0);
		expect(archived.stderr).toContain("failed to append session.completed before archive");
		expect(JSON.parse(run(repo, ["run", "active", "--project-root", repo], { HOME: home }).stdout).active.run_id).toBe(created.metadata.run_id);
		const shown = parseRunJson<{ metadata: { terminated: boolean } }>(
			run(repo, ["run", "show", created.metadata.run_id, "--project-root", repo], { HOME: home }),
		);
		expect(shown.metadata.terminated).toBe(false);
		expect(readdirSync(join(repo, "tmp")).filter((name) => name.endsWith(".archive"))).toEqual([]);
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
