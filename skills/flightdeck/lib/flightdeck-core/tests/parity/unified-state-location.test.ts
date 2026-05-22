// vstack#227 parity tests for the unified state-location contract:
//   * Live state, activity, and snapshots live under
//     `~/.vstack/flightdeck/projects/<id>/runs/<run-id>/`, never inside
//     `<project>/tmp/`.
//   * Pre-existing `<project>/tmp/flightdeck-state-<S>.json` (and its
//     activity sidecar) are migrated to `.migrated` on first contact
//     with the new helpers and not read again.

import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-state");
const SESSION = "UNIFIED";

function makeRepo(): string {
	const dir = mkdtempSync(join(tmpdir(), "fdunified-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
	});
	return dir;
}

function envFor(repo: string, extra: Record<string, string | undefined> = {}): Record<string, string> {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	env.FLIGHTDECK_OWNER_HARNESS = "pi";
	env.FLIGHTDECK_OWNER_PANE_ID = "%42";
	env.FLIGHTDECK_OWNER_PANE_TARGET = "UNIFIED:0.0";
	env.FLIGHTDECK_OWNER_CWD = "/tmp/unified-owner";
	env.FLIGHTDECK_OWNER_PID = "4242";
	env.FLIGHTDECK_OWNER_PI_SESSION_ID = "pi-unified";
	env.FLIGHTDECK_OWNER_PI_BRIDGE_SOCKET = "/tmp/pi-unified.sock";
	for (const [k, v] of Object.entries(extra)) {
		if (v === undefined) delete env[k];
		else env[k] = v;
	}
	return env;
}

function runState(repo: string, args: string[], extra: Record<string, string | undefined> = {}) {
	const r = spawnSync(SCRIPT, [args[0]!, "--session", SESSION, ...args.slice(1)], {
		cwd: repo, encoding: "utf8", env: envFor(repo, extra),
	});
	return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

describe("unified state location (vstack#227)", () => {
	test("fresh init writes state.json and activity.jsonl under ~/.vstack, never project tmp/", () => {
		const repo = makeRepo();
		try {
			const init = runState(repo, ["init"]);
			expect(init.status).toBe(0);
			const path = runState(repo, ["path"]).stdout.trim();
			expect(path).toContain(`.vstack-run-store/projects/`);
			expect(path).toMatch(/\/runs\/run-[^/]+\/state\.json$/);
			expect(existsSync(path)).toBe(true);
			const activity = join(dirname(path), "activity.jsonl");
			expect(existsSync(activity)).toBe(true);
			// Project tmp/ stays empty of flightdeck-* artifacts.
			const projectTmp = join(repo, "tmp");
			const projectArtifacts = existsSync(projectTmp)
				? readdirSync(projectTmp).filter((name) => name.startsWith("flightdeck-"))
				: [];
			expect(projectArtifacts).toEqual([]);
		} finally {
			rmSync(repo, { force: true, recursive: true });
		}
	});

	test("legacy <project>/tmp/flightdeck-state file is migrated to .migrated on first ensure", () => {
		const repo = makeRepo();
		try {
			// Seed the legacy layout: state + activity in project tmp/.
			const tmpDir = join(repo, "tmp");
			mkdirSync(tmpDir, { recursive: true });
			const legacyState = join(tmpDir, `flightdeck-state-${SESSION}.json`);
			const legacyActivity = join(tmpDir, `flightdeck-activity-${SESSION}.jsonl`);
			writeFileSync(legacyState, JSON.stringify({
				session_id: SESSION,
				entries: { "LEG-1": { id: "LEG-1", kind: "issue", harness: "pi", state: "complete" } },
				merge_queue: [],
			}), "utf8");
			writeFileSync(legacyActivity, `${JSON.stringify({ id: "ev1", type: "session.started" })}\n`, "utf8");
			// First ensure triggers migration.
			runState(repo, ["init"]);
			expect(existsSync(legacyState)).toBe(false);
			expect(existsSync(`${legacyState}.migrated`)).toBe(true);
			expect(existsSync(`${legacyActivity}.migrated`)).toBe(true);
			// New active run picked up the legacy entries.
			const tracked = JSON.parse(runState(repo, ["tracked-entries"]).stdout) as Record<string, unknown>;
			expect(Object.keys(tracked)).toContain("LEG-1");
		} finally {
			rmSync(repo, { force: true, recursive: true });
		}
	});

	test("createRunLocked migration runs under flock and preserves the latest legacy write", async () => {
		// vstack#227 round-2 P1 regression: the legacy migration shim
		// must hold the legacy state and activity locks before copying
		// + renaming. We simulate a concurrent legacy writer by taking
		// the legacy state lock first; createRunLocked-driven
		// `flightdeck-state init` must serialize behind that lock and
		// pick up the writer's last-write-wins payload.
		const repo = makeRepo();
		try {
			const tmpDir = join(repo, "tmp");
			mkdirSync(tmpDir, { recursive: true });
			const legacyState = join(tmpDir, `flightdeck-state-${SESSION}.json`);
			writeFileSync(legacyState, JSON.stringify({ session_id: SESSION, entries: { OLD: { id: "OLD", kind: "issue" } } }), "utf8");
			// Spawn the lock holder in the background. flock takes the
			// lock, sleeps ~300ms, writes the racing payload, then
			// exits (releasing the lock). This is a single shell
			// command per flock(1) idiom: `flock -x file -c '<cmd>'`.
			const racingPayload = JSON.stringify({ session_id: SESSION, entries: { OLD: { id: "OLD", kind: "issue" }, RACE: { id: "RACE", kind: "adhoc" } } });
			const holder = Bun.spawn([
				"flock",
				"-x",
				`${legacyState}.lock`,
				"bash",
				"-c",
				`sleep 0.3; printf '%s\n' "$1" > "$2"`,
				"_",
				racingPayload,
				legacyState,
			], { stderr: "pipe", stdout: "pipe" });
			// Brief delay so flock acquires the lock before init runs.
			await Bun.sleep(80);
			const init = runState(repo, ["init"]);
			expect(init.status).toBe(0);
			expect(await holder.exited).toBe(0);
			const tracked = JSON.parse(runState(repo, ["tracked-entries"]).stdout);
			expect(Object.keys(tracked).sort()).toEqual(["OLD", "RACE"]);
			expect(existsSync(`${legacyState}.migrated`)).toBe(true);
			expect(existsSync(legacyState)).toBe(false);
		} finally {
			rmSync(repo, { force: true, recursive: true });
		}
	});

	test("symlinked ancestor in FLIGHTDECK_RUN_STORE_ROOT is rejected (CWE-22/CWE-59)", async () => {
		const repo = makeRepo();
		const outside = mkdtempSync(join(tmpdir(), "fdunified-outside-"));
		try {
			// Create `<repo>/intermediate -> <outside>`, then point the
			// run-store root inside the symlinked path. The migration
			// shim must refuse before any mkdir/copy/rename touches
			// disk via the symlink.
			const fs = await import("node:fs");
			fs.symlinkSync(outside, join(repo, "intermediate"));
			const r = spawnSync(SCRIPT, ["init", "--session", SESSION], {
				cwd: repo, encoding: "utf8",
				env: envFor(repo, { FLIGHTDECK_RUN_STORE_ROOT: join(repo, "intermediate", "store") }),
			});
			expect(r.status).not.toBe(0);
			expect(r.stderr).toMatch(/ancestor .*intermediate.*is a symlink|CWE-22/);
			// The symlink target must not have been used as a store
			// dir: no `projects/` got created inside <outside>.
			const outsideContents = fs.readdirSync(outside);
			expect(outsideContents).toEqual([]);
		} finally {
			rmSync(repo, { force: true, recursive: true });
			rmSync(outside, { force: true, recursive: true });
		}
	});

	test("strict 0600 fail-closed on READ of state.json (no auto-chmod)", () => {
		// vstack#227 round-3 P2.1: a previously-trusted state.json
		// that's been chmod'd to 0644 must fail closed at read time
		// (CWE-732/CWE-276). The reader never silently auto-chmods.
		const repo = makeRepo();
		try {
			const init = runState(repo, ["init"]);
			expect(init.status).toBe(0);
			const path = runState(repo, ["path"]).stdout.trim();
			expect(path.length).toBeGreaterThan(0);
			// Widen the mode behind the run-store's back.
			chmodSync(path, 0o644);
			const tracked = runState(repo, ["tracked-entries"]);
			expect(tracked.status).not.toBe(0);
			expect(tracked.stderr).toMatch(/mode=644 expected 600|group\/other write/);
			expect(tracked.stderr).toContain("vstack flightdeck migrate-permissions --dry-run");
		} finally {
			rmSync(repo, { force: true, recursive: true });
		}
	});

	test("strict 0600 fail-closed on WRITE through a pre-existing 0644 state.json (no auto-chmod)", () => {
		// vstack#227 round-3 P2.1: a state.json with wider perms
		// must trip the writer too. ensureStoreFile() before the
		// `set` operation refuses the write; the helper does not
		// silently auto-chmod.
		const repo = makeRepo();
		try {
			const init = runState(repo, ["init"]);
			expect(init.status).toBe(0);
			const path = runState(repo, ["path"]).stdout.trim();
			chmodSync(path, 0o644);
			const r = runState(repo, ["set", "terminated", "true"]);
			expect(r.status).not.toBe(0);
			expect(r.stderr).toMatch(/mode=644 expected 600|group\/other write/);
			expect(r.stderr).toContain("vstack flightdeck migrate-permissions --dry-run");
		} finally {
			rmSync(repo, { force: true, recursive: true });
		}
	});

	test("archive writes a durable snapshot and clears the active pointer", () => {
		const repo = makeRepo();
		try {
			runState(repo, ["init"]);
			runState(repo, ["activity", "append", JSON.stringify({ natural_key: "start", source: "flightdeck", summary: "started", type: "session.started" })]);
			runState(repo, ["set", "terminated_at", '"2026-05-20T00:00:00Z"']);
			const archive = runState(repo, ["archive"]);
			expect(archive.status).toBe(0);
			const snapshot = archive.stdout.trim();
			expect(snapshot).toMatch(/\/snapshots\/2026-05-20T000000Z\.json$/);
			expect(existsSync(snapshot)).toBe(true);
			// Active pointer is cleared.
			const active = JSON.parse(runState(repo, ["run", "active", "--project-root", repo]).stdout);
			expect(active).toBeNull();
		} finally {
			rmSync(repo, { force: true, recursive: true });
		}
	});
});
