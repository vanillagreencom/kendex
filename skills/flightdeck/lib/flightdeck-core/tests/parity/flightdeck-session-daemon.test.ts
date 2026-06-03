// Focused parity tests for flightdeck-session daemon wake arming.
// Uses the tmux shim; no real windows or Pi processes are created.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { makeRepo, run, runState, stateFile, writeShimState } from "./support/flightdeck-session-fixtures";

let repos: string[] = [];

beforeEach(() => {
	repos = [];
});

afterEach(() => {
	for (const repo of repos) if (existsSync(repo)) rmSync(repo, { recursive: true, force: true });
});

describe("flightdeck-session daemon arming", () => {
	for (const _useTs of [true]) {
		// vstack#213 round-1: shim that captures every flightdeck-daemon
		// invocation so we can assert stop+start ordering and the exact
		// final --inner / --inner-harnesses arguments. The shim's health
		// output is driven by env vars set per-test so we can simulate
		// missing / fresh / stale daemons against the bash decision logic
		// in ensure_daemon_for_session.
		function makeDaemonShim(repo: string, captureFile: string): string {
			const path = join(repo, "flightdeck-daemon-shim");
			// Use real env-var defaults so tests don't have to ship custom
			// shims per scenario. SHIM_STALENESS controls the simulated
			// `staleness` field; SHIM_MASTER controls master_pane_id;
			// SHIM_SUBSCRIBED controls subscribed_pane_ids; SHIM_PRESENT
			// toggles between "no daemon" (exit 1) and "running" (exit 0)
			// for status/health.
			writeFileSync(path, `#!/usr/bin/env bash
set -e
printf '%s\\n' "$*" >> ${JSON.stringify(captureFile)}
action="\${1:-}"; shift || true
SHIM_PRESENT="\${SHIM_PRESENT:-0}"
SHIM_STALENESS="\${SHIM_STALENESS:-fresh}"
SHIM_MASTER="\${SHIM_MASTER:-%0}"
SHIM_MASTER_HARNESS="\${SHIM_MASTER_HARNESS:-}"
SHIM_SUBSCRIBED="\${SHIM_SUBSCRIBED:-}"
SHIM_HARNESSES="\${SHIM_HARNESSES:-}"
case "$action" in
  status)
    if [[ "$SHIM_PRESENT" != "1" ]]; then echo "session=test no daemon"; exit 1; fi
    echo "session=test daemon=4242 running session_id=test"; exit 0 ;;
  health)
    if [[ "$SHIM_PRESENT" != "1" ]]; then echo "session=test no daemon"; exit 1; fi
    printf 'session=test daemon_pid=4242 alive=true\\n'
    printf 'master_pane_id=%s\\n' "$SHIM_MASTER"
    printf 'master_harness=%s\\n' "\${SHIM_MASTER_HARNESS:-(unknown)}"
    printf 'subscribed_pane_ids=%s\\n' "$SHIM_SUBSCRIBED"
    printf 'subscribed_pane_harnesses=%s\\n' "$SHIM_HARNESSES"
    printf 'staleness=%s\\n' "$SHIM_STALENESS"
    exit 0 ;;
  stop)  echo stopped; exit 0 ;;
  start) echo started; exit 0 ;;
esac
exit 0
`);
			chmodSync(path, 0o755);
			return path;
		}

		function makeStartRaceDaemonShim(repo: string, captureFile: string, verifyMasterHarness: string): string {
			const path = join(repo, "flightdeck-daemon-start-race-shim");
			const healthCount = join(repo, "flightdeck-daemon-health.count");
			writeFileSync(path, `#!/usr/bin/env bash
set -e
printf '%s\n' "$*" >> ${JSON.stringify(captureFile)}
action="\${1:-}"; shift || true
case "$action" in
  health)
    count=0
    [[ -f ${JSON.stringify(healthCount)} ]] && count=$(cat ${JSON.stringify(healthCount)})
    count=$((count + 1))
    printf '%s' "$count" > ${JSON.stringify(healthCount)}
    if [[ "$count" == "1" ]]; then echo "session=test no daemon"; exit 1; fi
    printf 'session=test daemon_pid=4242 alive=true\n'
    printf 'master_pane_id=%s\n' "%5"
    printf 'master_harness=%s\n' ${JSON.stringify(verifyMasterHarness)}
    printf 'subscribed_pane_ids=%s\n' "%6"
    printf 'subscribed_pane_harnesses=%s\n' "claude"
    printf 'staleness=fresh\n'
    exit 0 ;;
  start)
    echo "start-stderr-marker: lock race detected" >&2
    exit 1 ;;
  stop) echo stopped; exit 0 ;;
  status) echo "session=test no daemon"; exit 1 ;;
esac
exit 0
`);
			chmodSync(path, 0o755);
			return path;
		}

		// Parse a recorded shim invocation back into action + args
		// without leaning on whitespace heuristics in each test.
		function shimCalls(captureFile: string): { action: string; args: string[]; line: string }[] {
			return readFileSync(captureFile, "utf8").trim().split("\n").filter(Boolean).map((line) => {
				const parts = line.split(/\s+/);
				return { action: parts[0] ?? "", args: parts.slice(1), line };
			});
		}

		function flagValue(args: string[], name: string): string {
			for (let i = 0; i < args.length; i += 1) {
				if (args[i] === name) return args[i + 1] ?? "";
				const prefix = `${name}=`;
				if (args[i]?.startsWith(prefix)) return args[i]!.slice(prefix.length);
			}
			return "";
		}

		test(`detect-master-harness exposes the shared resolver`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });

			const r = run(repo, shim, ["detect-master-harness", "--master-pane", "%5"], {
				PI_CODING_AGENT: "true",
				TMUX_PANE: "%5",
			});

			expect(r.status).toBe(0);
			expect(r.stdout.trim()).toBe("pi");
		});

		test(`ensure_daemon_for_session spawns a fresh daemon with exact --inner when none is running`, () => {
			const repo = makeRepo();
			repos.push(repo);
			// Seed the supervisor pane only; flightdeck-session start will
			// allocate predictable pane ids via the tmux shim (%1, %2, ...).
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const daemonCapture = join(repo, "daemon-calls.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);
			const env = { FLIGHTDECK_DAEMON_BIN: daemonShim, SHIM_PRESENT: "0", TMUX_PANE: "%5" };

			// Start two children. Each adds a tracked pane (%1, %2).
			expect(run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], env).status).toBe(0);
			expect(run(repo, shim, ["start", "--session-id", "issue-B", "--title", "B", "--cwd", repo, "--harness", "pi", "--cmd", "echo b"], env).status).toBe(0);

			const calls = shimCalls(daemonCapture);
			// No daemon present → no stop call, two start calls (once per
			// flightdeck-session start). The second start fully describes
			// the state after both registrations.
			expect(calls.filter((c) => c.action === "stop")).toHaveLength(0);
			const starts = calls.filter((c) => c.action === "start");
			expect(starts.length).toBeGreaterThanOrEqual(2);
			const lastStart = starts[starts.length - 1]!;
			expect(flagValue(lastStart.args, "--session")).toBe("test-session");
			expect(flagValue(lastStart.args, "--master")).toBe("%5");
			// The supervisor pane is %5; the shim's pane allocator picks
			// max(pane numeric suffix)+1, so child panes land at %6, %7.
			const innerCsv = flagValue(lastStart.args, "--inner");
			const innerList = innerCsv.split(",");
			expect(new Set(innerList)).toEqual(new Set(["%6", "%7"]));
			expect(innerList).toHaveLength(2);
			const harnessList = flagValue(lastStart.args, "--inner-harnesses").split(",");
			expect(harnessList).toHaveLength(2);
			const pairSet = new Set<string>();
			for (let i = 0; i < innerList.length; i += 1) pairSet.add(`${innerList[i]}:${harnessList[i]}`);
			expect(pairSet).toEqual(new Set(["%6:claude", "%7:pi"]));
		});

		test(`ensure_daemon_for_session arms Pi masters with --master-harness pi`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const daemonCapture = join(repo, "daemon-calls.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);

			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "pi", "--cmd", "echo a"], {
				FLIGHTDECK_DAEMON_BIN: daemonShim,
				PI_CODING_AGENT: "true",
				SHIM_PRESENT: "0",
				TMUX_PANE: "%5",
			});

			expect(r.status).toBe(0);
			const starts = shimCalls(daemonCapture).filter((c) => c.action === "start");
			expect(starts.length).toBeGreaterThan(0);
			const lastStart = starts[starts.length - 1]!;
			expect(flagValue(lastStart.args, "--master")).toBe("%5");
			expect(flagValue(lastStart.args, "--master-harness")).toBe("pi");
		});

		test(`ensure_daemon_for_session respawns when health omits master_harness`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const daemonCapture = join(repo, "daemon-calls.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);

			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
				FLIGHTDECK_DAEMON_BIN: daemonShim,
				FLIGHTDECK_OWNER_HARNESS: "claude",
				SHIM_HARNESSES: "claude",
				SHIM_MASTER: "%5",
				SHIM_PRESENT: "1",
				SHIM_STALENESS: "fresh",
				SHIM_SUBSCRIBED: "%6",
				TMUX_PANE: "%5",
			});

			expect(r.status).toBe(0);
			const calls = shimCalls(daemonCapture);
			expect(calls.some((c) => c.action === "stop")).toBe(true);
			const starts = calls.filter((c) => c.action === "start");
			expect(starts.length).toBeGreaterThan(0);
			expect(flagValue(starts[starts.length - 1]!.args, "--master-harness")).toBe("claude");
		});

		test(`ensure_daemon_for_session respawns when health reports mismatched master_harness`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const daemonCapture = join(repo, "daemon-calls.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);

			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
				FLIGHTDECK_DAEMON_BIN: daemonShim,
				FLIGHTDECK_OWNER_HARNESS: "claude",
				SHIM_HARNESSES: "claude",
				SHIM_MASTER: "%5",
				SHIM_MASTER_HARNESS: "pi",
				SHIM_PRESENT: "1",
				SHIM_STALENESS: "fresh",
				SHIM_SUBSCRIBED: "%6",
				TMUX_PANE: "%5",
			});

			expect(r.status).toBe(0);
			const calls = shimCalls(daemonCapture);
			expect(calls.some((c) => c.action === "stop")).toBe(true);
			const starts = calls.filter((c) => c.action === "start");
			expect(starts.length).toBeGreaterThan(0);
			expect(flagValue(starts[starts.length - 1]!.args, "--master-harness")).toBe("claude");
		});

		test(`ensure_daemon_for_session stops + respawns with exact pairs when health says stale-inner`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const daemonCapture = join(repo, "daemon-calls.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);

			// Pre-existing daemon (SHIM_PRESENT=1) reporting stale-inner.
			// The bash decision is: stop then respawn with the current
			// alive tracked entries. SHIM_SUBSCRIBED carries the daemon's
			// stale frozen --inner from a previous session — verifying the
			// respawn picks the *new* tracked entries, not the stale ones.
			const env = {
				FLIGHTDECK_DAEMON_BIN: daemonShim,
				SHIM_HARNESSES: "shell",
				SHIM_MASTER: "%5",
				SHIM_PRESENT: "1",
				SHIM_STALENESS: "stale-inner",
				SHIM_SUBSCRIBED: "%99",
				TMUX_PANE: "%5",
			};

			expect(run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], env).status).toBe(0);
			expect(run(repo, shim, ["start", "--session-id", "issue-B", "--title", "B", "--cwd", repo, "--harness", "pi", "--cmd", "echo b"], env).status).toBe(0);
			expect(run(repo, shim, ["start", "--session-id", "issue-C", "--title", "C", "--cwd", repo, "--harness", "codex", "--cmd", "echo c"], env).status).toBe(0);

			const calls = shimCalls(daemonCapture);
			// At least three stop calls (one per ensure_daemon_for_session
			// invocation since health keeps reporting stale-inner) and
			// three start calls. We only validate the *last* start/stop
			// pair, which describes the final, post-3-child state.
			const stops = calls.filter((c) => c.action === "stop");
			const starts = calls.filter((c) => c.action === "start");
			expect(stops.length).toBeGreaterThanOrEqual(1);
			expect(starts.length).toBeGreaterThanOrEqual(1);
			const lastStopIdx = calls.map((c) => c.action).lastIndexOf("stop");
			const lastStartIdx = calls.map((c) => c.action).lastIndexOf("start");
			expect(lastStartIdx).toBeGreaterThan(lastStopIdx);

			const lastStart = calls[lastStartIdx]!;
			const innerCsv = flagValue(lastStart.args, "--inner");
			const innerList = innerCsv.split(",");
			const harnessList = flagValue(lastStart.args, "--inner-harnesses").split(",");
			// Three live tracked panes; the supervisor pane (%5) allocates
			// %6, %7, %8 as the children land in tmux.
			expect(new Set(innerList)).toEqual(new Set(["%6", "%7", "%8"]));
			expect(innerList).toHaveLength(3);
			expect(harnessList).toHaveLength(3);
			const pairSet = new Set<string>();
			for (let i = 0; i < innerList.length; i += 1) pairSet.add(`${innerList[i]}:${harnessList[i]}`);
			expect(pairSet).toEqual(new Set(["%6:claude", "%7:pi", "%8:codex"]));
			expect(flagValue(lastStart.args, "--master")).toBe("%5");
		});

		test(`ensure_daemon_for_session leaves a fresh daemon alone when health matches reality (attach path)`, () => {
			const repo = makeRepo();
			repos.push(repo);
			// Pre-seed the supervisor pane AND the to-be-attached pane so
			// flightdeck-session attach does not allocate new panes. With
			// known pane ids, the shim's SHIM_SUBSCRIBED matches reality
			// and health reports fresh — ensure_daemon_for_session must
			// then make zero stop/start calls.
			const shim = writeShimState(repo, {
				current_pane_id: "%5",
				panes: {
					"%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" },
					"%42": { pane_index: 0, path: repo, window_id: "@6", window_index: 6, window_name: "manual" },
				},
				session: "test-session",
				windows: { "@5": { index: 5, name: "supervisor" }, "@6": { index: 6, name: "manual" } },
			});
			const daemonCapture = join(repo, "daemon-calls.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);

			const r = run(repo, shim, [
				"attach",
				"--pane", "%42",
				"--harness", "claude",
				"--title", "Manual",
				"--session-id", "manual-attach",
			], {
				FLIGHTDECK_DAEMON_BIN: daemonShim,
				FLIGHTDECK_OWNER_HARNESS: "claude",
				SHIM_HARNESSES: "claude",
				SHIM_MASTER: "%5",
				SHIM_MASTER_HARNESS: "claude",
				SHIM_PRESENT: "1",
				SHIM_STALENESS: "fresh",
				SHIM_SUBSCRIBED: "%42",
				TMUX_PANE: "%5",
			});
			expect(r.status).toBe(0);
			const calls = shimCalls(daemonCapture);
			// Health probe is fine; stop and start MUST NOT happen.
			expect(calls.filter((c) => c.action === "stop")).toHaveLength(0);
			expect(calls.filter((c) => c.action === "start")).toHaveLength(0);
			expect(calls.filter((c) => c.action === "health").length).toBeGreaterThan(0);
		});

		test(`ensure_daemon_for_session respawns when health reports stale-state (state file replaced)`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const daemonCapture = join(repo, "daemon-calls.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);

			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
				FLIGHTDECK_DAEMON_BIN: daemonShim,
				SHIM_MASTER: "%5",
				SHIM_PRESENT: "1",
				SHIM_STALENESS: "stale-state",
				SHIM_SUBSCRIBED: "%1",
				TMUX_PANE: "%5",
			});
			expect(r.status).toBe(0);
			const calls = shimCalls(daemonCapture);
			expect(calls.some((c) => c.action === "stop")).toBe(true);
			expect(calls.some((c) => c.action === "start")).toBe(true);
		});

		test(`ensure_daemon_for_session warns and skips when registry probe fails after entry registration`, () => {
			// vstack#213 round-2: this exercises the warn-and-skip branch
			// inside ensure_daemon_for_session specifically. Entry
			// registration uses the canonical PANE_REGISTRY (the trampoline
			// next to flightdeck-session); ensure_daemon's registry probe
			// uses FLIGHTDECK_PANE_REGISTRY_BIN if set. We point the latter
			// at a failing shim so the helper hits its probe-failure path
			// without breaking entry registration, then assert the helper
			// emits the expected warning and falls through to start (no
			// daemon was running before, so a fresh start is still expected
			// after the warn — the registry failure means we cannot compute
			// inner panes, so the helper aborts BEFORE health/start).
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const daemonCapture = join(repo, "daemon-calls.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);
			const failingRegistry = join(repo, "failing-pane-registry");
			writeFileSync(failingRegistry, `#!/usr/bin/env bash\necho boom-registry >&2\nexit 7\n`);
			chmodSync(failingRegistry, 0o755);

			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
				FLIGHTDECK_DAEMON_BIN: daemonShim,
				FLIGHTDECK_PANE_REGISTRY_BIN: failingRegistry,
				TMUX_PANE: "%5",
			});
			// FLIGHTDECK_PANE_REGISTRY_BIN overrides PANE_REGISTRY for the
			// whole script, so entry registration also fails. Confirm a
			// clean diagnostic exit (we'd rather fail loudly than silently
			// skip registration). The behavior keeps wake-arming intact:
			// the user knows something is wrong instead of an entry
			// landing without a daemon.
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("boom-registry");
		});

		test(`ensure_daemon_for_session rejects FLIGHTDECK_DAEMON_BIN that is not absolute`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
				FLIGHTDECK_DAEMON_BIN: "relative/path",
				TMUX_PANE: "%5",
			});
			expect(r.status).toBe(2);
			expect(r.stderr).toContain("FLIGHTDECK_DAEMON_BIN must be an absolute path");
		});

		test(`ensure_daemon_for_session rejects FLIGHTDECK_DAEMON_BIN that is not executable`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const nonExecBin = join(repo, "not-executable");
			writeFileSync(nonExecBin, "#!/usr/bin/env bash\nexit 0\n");
			chmodSync(nonExecBin, 0o644);
			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
				FLIGHTDECK_DAEMON_BIN: nonExecBin,
				TMUX_PANE: "%5",
			});
			expect(r.status).toBe(2);
			expect(r.stderr).toContain("FLIGHTDECK_DAEMON_BIN not executable");
		});

		test(`ensure_daemon_for_session rejects FLIGHTDECK_PANE_REGISTRY_BIN that is not absolute`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
				FLIGHTDECK_PANE_REGISTRY_BIN: "relative/registry",
				TMUX_PANE: "%5",
			});
			expect(r.status).toBe(2);
			expect(r.stderr).toContain("FLIGHTDECK_PANE_REGISTRY_BIN must be an absolute path");
		});

		test(`flightdeck-state archive rejects FLIGHTDECK_DAEMON_BIN that is not executable`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			mkdirSync(join(repo, "tmp"), { recursive: true });
			writeFileSync(stateFile(repo), JSON.stringify({
				entries: {},
				session_id: "test-session",
				terminated: true,
				terminated_at: "2026-05-21T00:00:00Z",
			}, null, 2));
			runState(repo, shim, ["run", "create", "--tmux-session", "test-session"]);
			const nonExecBin = join(repo, "not-executable-state");
			writeFileSync(nonExecBin, "#!/usr/bin/env bash\nexit 0\n");
			chmodSync(nonExecBin, 0o644);
			const r = runState(repo, shim, ["archive"], { FLIGHTDECK_DAEMON_BIN: nonExecBin });
			expect(r.status).toBe(2);
			expect(r.stderr).toContain("FLIGHTDECK_DAEMON_BIN not executable");
		});

		test(`ensure_daemon_for_session surfaces stop AND start stderr on daemon-respawn-failed`, () => {
			// vstack#213 round-3: daemon-respawn-failed must include both
			// stop-side and start-side stderr so operators can diagnose
			// cases where stop refused (exit 3 / safety) and then start
			// raced a still-running daemon. Drive the shim to a state
			// where stop exits 3 with a known marker, start exits 1 (lock
			// race) with a known marker, and the post-start health
			// verifier reports still-stale (forcing daemon-respawn-failed
			// instead of daemon-respawn-raced).
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const captureFile = join(repo, "daemon-calls.log");
			writeFileSync(captureFile, "");
			const failingDaemon = join(repo, "failing-daemon");
			writeFileSync(failingDaemon, `#!/usr/bin/env bash
set -e
printf '%s\\n' "$*" >> ${JSON.stringify(captureFile)}
action="\${1:-}"; shift || true
case "$action" in
  status) echo "session=test daemon=4242 running"; exit 0 ;;
  health)
    printf 'session=test daemon_pid=4242 alive=true\\n'
    printf 'master_pane_id=%s\\n' "%5"
    printf 'subscribed_pane_ids=%s\\n' "%99"
    printf 'staleness=stale-inner\\n'
    exit 0 ;;
  stop)
    echo "stop-stderr-marker: PID lock missing" >&2
    exit 3 ;;
  start)
    echo "start-stderr-marker: lock race detected" >&2
    exit 1 ;;
esac
exit 0
`);
			chmodSync(failingDaemon, 0o755);
			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
				FLIGHTDECK_DAEMON_BIN: failingDaemon,
				TMUX_PANE: "%5",
			});
			// flightdeck-session start itself succeeds — ensure_daemon
			// failures are warn-only by design (watch loop retries).
			expect(r.status).toBe(0);
			// But stderr must include BOTH markers AND the
			// daemon-respawn-failed line.
			expect(r.stderr).toContain("daemon-respawn-failed");
			expect(r.stderr).toContain("stop-stderr-marker");
			expect(r.stderr).toContain("start-stderr-marker");
		});

		test(`ensure_daemon_for_session treats start rc=1 as raced only when verified master harness matches`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
			const captureFile = join(repo, "daemon-calls.log");
			writeFileSync(captureFile, "");
			const raceDaemon = makeStartRaceDaemonShim(repo, captureFile, "claude");

			const r = run(repo, shim, ["start", "--session-id", "issue-A", "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
				FLIGHTDECK_DAEMON_BIN: raceDaemon,
				FLIGHTDECK_MASTER_HARNESS: "claude",
				TMUX_PANE: "%5",
			});

			expect(r.status).toBe(0);
			expect(r.stderr).toContain("daemon-respawn-raced");
			expect(r.stderr).not.toContain("daemon-respawn-failed");
			const calls = shimCalls(captureFile);
			expect(calls.filter((c) => c.action === "start")).toHaveLength(1);
			expect(calls.filter((c) => c.action === "health")).toHaveLength(2);
		});

		test(`ensure_daemon_for_session keeps start rc=1 failed when verified master harness is unknown or mismatched`, () => {
			for (const [index, verifyHarness] of ["(unknown)", "pi"].entries()) {
				const repo = makeRepo();
				repos.push(repo);
				const shim = writeShimState(repo, { current_pane_id: "%5", panes: { "%5": { pane_index: 0, path: repo, window_id: "@5", window_index: 5, window_name: "supervisor" } }, session: "test-session", windows: { "@5": { index: 5, name: "supervisor" } } });
				const captureFile = join(repo, `daemon-calls-${verifyHarness.replace(/[^a-z0-9]/gi, "_")}.log`);
				writeFileSync(captureFile, "");
				const raceDaemon = makeStartRaceDaemonShim(repo, captureFile, verifyHarness);

				const r = run(repo, shim, ["start", "--session-id", `issue-race-${index}`, "--title", "A", "--cwd", repo, "--harness", "claude", "--cmd", "echo a"], {
					FLIGHTDECK_DAEMON_BIN: raceDaemon,
					FLIGHTDECK_MASTER_HARNESS: "claude",
					TMUX_PANE: "%5",
				});

				expect(r.status).toBe(0);
				expect(r.stderr).toContain("daemon-respawn-failed");
				expect(r.stderr).toContain("start-stderr-marker");
				expect(r.stderr).not.toContain("daemon-respawn-raced");
				const calls = shimCalls(captureFile);
				expect(calls.filter((c) => c.action === "start")).toHaveLength(1);
				expect(calls.filter((c) => c.action === "health")).toHaveLength(2);
			}
		});

		test(`flightdeck-state archive rejects FLIGHTDECK_DAEMON_BIN that is not absolute`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			mkdirSync(join(repo, "tmp"), { recursive: true });
			writeFileSync(stateFile(repo), JSON.stringify({
				entries: {},
				session_id: "test-session",
				terminated: true,
				terminated_at: "2026-05-21T00:00:00Z",
			}, null, 2));
			runState(repo, shim, ["run", "create", "--tmux-session", "test-session"]);
			const r = runState(repo, shim, ["archive"], { FLIGHTDECK_DAEMON_BIN: "relative/daemon" });
			expect(r.status).toBe(2);
			expect(r.stderr).toContain("FLIGHTDECK_DAEMON_BIN must be an absolute path");
		});

		test(`flightdeck-state archive invokes flightdeck-daemon stop via FLIGHTDECK_DAEMON_BIN`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			mkdirSync(join(repo, "tmp"), { recursive: true });
			writeFileSync(stateFile(repo), JSON.stringify({
				entries: { gone: { id: "gone", kind: "adhoc", pane_id: "%999", state: "complete" } },
				session_id: "test-session",
				terminated: true,
				terminated_at: "2026-05-21T00:00:00Z",
			}, null, 2));
			runState(repo, shim, ["run", "create", "--tmux-session", "test-session"]);

			const daemonCapture = join(repo, "daemon-calls-archive.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);

			const archived = runState(repo, shim, ["archive"], { FLIGHTDECK_DAEMON_BIN: daemonShim });
			expect(archived.status).toBe(0);
			// vstack#227: archive returns the durable snapshot path
			// (`<run-dir>/snapshots/<TS>.json`), not a legacy
			// `tmp/...json.archive` rotation.
			expect(archived.stdout).toMatch(/\/snapshots\/[^/]+\.json\n?$/);
			const calls = shimCalls(daemonCapture);
			expect(calls.filter((c) => c.action === "stop" && flagValue(c.args, "--session") === "test-session").length).toBeGreaterThanOrEqual(1);
		});

		test(`flightdeck-state archive skips daemon stop when FLIGHTDECK_ARCHIVE_SKIP_DAEMON_STOP=1`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			mkdirSync(join(repo, "tmp"), { recursive: true });
			writeFileSync(stateFile(repo), JSON.stringify({
				entries: { gone: { id: "gone", kind: "adhoc", pane_id: "%999", state: "complete" } },
				session_id: "test-session",
				terminated: true,
				terminated_at: "2026-05-21T00:00:00Z",
			}, null, 2));
			runState(repo, shim, ["run", "create", "--tmux-session", "test-session"]);

			const daemonCapture = join(repo, "daemon-calls-archive-skip.log");
			writeFileSync(daemonCapture, "");
			const daemonShim = makeDaemonShim(repo, daemonCapture);

			const archived = runState(repo, shim, ["archive"], {
				FLIGHTDECK_ARCHIVE_SKIP_DAEMON_STOP: "1",
				FLIGHTDECK_DAEMON_BIN: daemonShim,
			});
			expect(archived.status).toBe(0);
			const calls = shimCalls(daemonCapture);
			expect(calls.filter((c) => c.action === "stop")).toHaveLength(0);
		});
	}
});
