// Parity test: TS run-loop daemon spawn / status / stop / ack /
// heartbeat round-trip. Requires a live tmux session for pane
// resolution; skips when TMUX is unset.
//
// Tests:
//   1. spawn + status round-trip + heartbeat updates
//   2. SIGTERM cleans up (no orphaned subscriber pid files; .pid +
//      .heartbeat removed; .log preserved)
//   3. ack returns drained events + clears WAKE_PENDING
//   4. atomic ack contract: event appended after busy-write is
//      delivered on the next ack

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { runLoop } from "../../src/daemon/loop.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-daemon");
const PANE_REGISTRY = resolve(HERE, "../../../../scripts/pane-registry");

const INSIDE_TMUX = !!process.env.TMUX_PANE;

function tmuxNewWindow(session: string, name: string): string {
	const r = spawnSync("tmux", ["new-window", "-d", "-t", session, "-n", name, "-P", "-F", "#{pane_id}"], { encoding: "utf8" });
	return (r.stdout ?? "").trim();
}
function tmuxKillPaneFor(paneId: string): void {
	spawnSync("tmux", ["kill-pane", "-t", paneId], { stdio: "ignore" });
}
function pidAlive(pid: number): boolean {
	if (!Number.isFinite(pid) || pid <= 0) return false;
	try { process.kill(pid, 0); return true; }
	catch (e) { return (e as NodeJS.ErrnoException).code === "EPERM"; }
}
function activeProcessGroupPids(pgid: number): number[] {
	if (!Number.isFinite(pgid) || pgid <= 0) return [];
	const r = spawnSync("ps", ["-eo", "pid=,pgid=,stat="], { encoding: "utf8" });
	if (r.status !== 0) return [];
	return (r.stdout ?? "").split("\n")
		.map((line) => line.trim().split(/\s+/, 3))
		.filter(([pid, group, stat]) => pid && group && stat && Number.parseInt(group, 10) === pgid && !stat.includes("Z"))
		.map(([pid]) => Number.parseInt(pid!, 10))
		.filter((pid) => Number.isFinite(pid) && pid > 0);
}
function sleep(ms: number): Promise<void> { return new Promise((res) => setTimeout(res, ms)); }

async function waitFor(predicate: () => boolean, timeoutMs = 5000): Promise<boolean> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return true;
		await sleep(100);
	}
	return predicate();
}

let stateDir = "";
let innerPaneId = "";
let extraPaneIds: string[] = [];
const SESSION = process.env.TMUX ? spawnSync("tmux", ["display-message", "-p", "#{session_id}"], { encoding: "utf8" }).stdout.trim() : "";
const SESSION_NAME = process.env.TMUX ? spawnSync("tmux", ["display-message", "-p", "#S"], { encoding: "utf8" }).stdout.trim() : "";
const SESSION_KEY = SESSION ? `s${SESSION.replace(/^\$/, "")}` : "";
const MASTER_PANE = process.env.TMUX_PANE ?? "";

beforeEach(() => {
	if (!INSIDE_TMUX) return;
	stateDir = mkdtempSync(join(tmpdir(), "fd-runloop-"));
	// Use a UNIQUE session key for state dir so we don't collide with
	// any running daemon for the real session. The daemon under test
	// runs against the real tmux session for pane resolution but
	// writes state to our isolated stateDir + a fake session key.
	innerPaneId = tmuxNewWindow(SESSION, `fd-runloop-test-${Date.now()}`);
});

afterEach(() => {
	for (const paneId of extraPaneIds) tmuxKillPaneFor(paneId);
	extraPaneIds = [];
	if (innerPaneId) { tmuxKillPaneFor(innerPaneId); innerPaneId = ""; }
	if (stateDir) { rmSync(stateDir, { recursive: true, force: true }); stateDir = ""; }
});

function runDaemon(action: string, extra: string[] = [], useTs = true): { status: number | null; stdout: string; stderr: string } {
	const env = daemonEnv(useTs);
	const r = spawnSync(SCRIPT, [action, "--session", SESSION_NAME, ...extra], { encoding: "utf8", env });
	return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function runDaemonIn(cwd: string, action: string, extra: string[] = [], extraEnv: Record<string, string> = {}): { status: number | null; stdout: string; stderr: string } {
	const env = { ...daemonEnv(true), ...extraEnv };
	const r = spawnSync(SCRIPT, [action, "--session", SESSION_NAME, ...extra], { cwd, encoding: "utf8", env });
	return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function runPaneRegistry(cwd: string, args: string[], extraEnv: Record<string, string> = {}): { status: number | null; stdout: string; stderr: string } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>), FLIGHTDECK_STATE_DIR: "tmp", ...extraEnv };
	const r = spawnSync(PANE_REGISTRY, args, { cwd, encoding: "utf8", env });
	return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function daemonEnv(useTs = true): Record<string, string> {
	const env: Record<string, string> = { ...(process.env as Record<string, string>), FD_STATE_DIR: stateDir, FLIGHTDECK_STATE_DIR: stateDir, FD_POLL_SEC: "1", FD_HEARTBEAT_TICKS: "2" };
	return env;
}

function runRegistry(args: string[], extraEnv: Record<string, string> = {}): { status: number | null; stdout: string; stderr: string } {
	const env = { ...daemonEnv(true), ...extraEnv };
	const r = spawnSync(PANE_REGISTRY, args, { encoding: "utf8", env });
	return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function registerPane(entryId: string, paneId: string): void {
	const r = runRegistry([
		"init-entry", entryId,
		"--title", entryId,
		"--kind", "adhoc",
		"--cwd", process.cwd(),
		"--window", "1",
		"--harness", "pi",
		"--pane-id", paneId,
	]);
	expect(r.status).toBe(0);
}

function lastStartLine(logText: string): string {
	return logText.split("\n").filter((line) => line.includes("[start]")).at(-1) ?? "";
}

describe("daemon run-loop (TS)", () => {
	if (!INSIDE_TMUX) {
		test.skip("requires tmux", () => undefined);
		return;
	}

	test("start refuses a stale master pane before entering the run loop", () => {
		for (const useTs of [true]) {
			const r = runDaemon("start", ["--master", "%999999", "--inner", innerPaneId, "--foreground"], useTs);
			expect(r.status).toBe(4);
			expect(r.stderr).toContain("error: master pane '%999999' does not exist; pass --master \"$TMUX_PANE\" or run 'tmux list-panes -a'");
			const pidFile = join(stateDir, `fd-daemon-${SESSION_KEY}.pid`);
			expect(existsSync(pidFile)).toBe(false);
		}
	});

	test("manual start refuses empty --inner outside handoff", () => {
		const r = runDaemon("start", ["--master", MASTER_PANE, "--inner", "", "--foreground"]);
		expect(r.status).toBe(2);
		expect(r.stderr).toContain("start needs --master and --inner");
	});

	test("startup validation errors emit daemon-exited startup-error details", () => {
		const stalePane = tmuxNewWindow(SESSION, `fd-startup-error-${Date.now()}`);
		tmuxKillPaneFor(stalePane);
		const eventsFile = join(stateDir, `fd-daemon-events-${SESSION_KEY}.jsonl`);
		const r = runDaemon("start", ["--master", MASTER_PANE, "--inner", stalePane, "--foreground"]);
		expect(r.status).toBe(2);
		expect(r.stderr).toContain(`Error: cannot resolve inner pane '${stalePane}'`);
		expect(existsSync(eventsFile)).toBe(true);
		const rows = readFileSync(eventsFile, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
		const event = rows.find((line) => line.event_type === "daemon-exited");
		expect(event).toMatchObject({ event_type: "daemon-exited", reason: "startup-error", tag: "daemon-exited" });
		expect(event.details).toMatchObject({ reason: "startup-error", error: `Error: cannot resolve inner pane '${stalePane}'`, exit_code: 2 });
	});

	test("default detached start rejects stale inner panes before spawning", () => {
		const stalePane = tmuxNewWindow(SESSION, `fd-detached-startup-error-${Date.now()}`);
		tmuxKillPaneFor(stalePane);
		const pidFile = join(stateDir, `fd-daemon-${SESSION_KEY}.pid`);
		const eventsFile = join(stateDir, `fd-daemon-events-${SESSION_KEY}.jsonl`);
		const r = runDaemon("start", ["--master", MASTER_PANE, "--inner", stalePane]);
		expect(r.status).toBe(2);
		expect(r.stderr).toContain(`Error: cannot resolve inner pane '${stalePane}'`);
		expect(r.stdout).not.toContain("daemon spawned pid=");
		expect(existsSync(pidFile)).toBe(false);
		expect(existsSync(eventsFile)).toBe(false);
	});

	test("daemon writes daemon-exited event when the master pane disappears", async () => {
		for (const useTs of [true]) {
			const masterPane = tmuxNewWindow(SESSION, `fd-master-gone-${Date.now()}`);
			try {
				const r = runDaemon("start", ["--master", masterPane, "--inner", innerPaneId], useTs);
				expect(r.status).toBe(0);
				tmuxKillPaneFor(masterPane);
				const eventsFile = join(stateDir, `fd-daemon-events-${SESSION_KEY}.jsonl`);
				const sawExit = await waitFor(() => existsSync(eventsFile) && readFileSync(eventsFile, "utf8").includes('"event_type":"daemon-exited"'));
				expect(sawExit).toBe(true);
				const drained = runDaemon("events", [], useTs);
				expect(drained.status).toBe(0);
				const lines = drained.stdout.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
				const event = lines.find((line) => line.event_type === "daemon-exited");
				expect(event).toMatchObject({ pane_id: masterPane, event_type: "daemon-exited", reason: "master-gone", master_id: masterPane, tag: "daemon-exited" });
				expect(typeof event.pid).toBe("number");
				expect(event.hash).toMatch(/^[0-9a-f]{12}$/);
			} finally {
				tmuxKillPaneFor(masterPane);
				runDaemon("stop", [], useTs);
			}
		}
	});

	test("daemon-exited emit failure is observable in stderr and daemon log", async () => {
		for (const useTs of [true]) {
			const masterPane = tmuxNewWindow(SESSION, `fd-emit-fail-${Date.now()}`);
			const logFile = join(stateDir, `fd-daemon-${SESSION_KEY}.log`);
			rmSync(logFile, { force: true });
			let stderr = "";
			const child = spawn(SCRIPT, ["start", "--session", SESSION_NAME, "--master", masterPane, "--inner", innerPaneId, "--foreground"], { env: daemonEnv(useTs), stdio: ["ignore", "ignore", "pipe"] });
			child.stderr.on("data", (b: Buffer) => { stderr += b.toString(); });
			try {
				const started = await waitFor(() => existsSync(logFile) && readFileSync(logFile, "utf8").includes("[start]"));
				expect(started).toBe(true);
				const exitPromise = new Promise<number | null>((resolveExit) => {
					const timer = setTimeout(() => resolveExit(null), 5000);
					child.on("exit", (code) => { clearTimeout(timer); resolveExit(code); });
				});
				chmodSync(stateDir, 0o500);
				tmuxKillPaneFor(masterPane);
				const exited = await exitPromise;
				expect(exited).not.toBeNull();
			} finally {
				chmodSync(stateDir, 0o700);
				tmuxKillPaneFor(masterPane);
				try { child.kill("SIGTERM"); } catch { /* */ }
			}
			expect(stderr).toContain("[daemon-exited-emit-failed]");
			expect(readFileSync(logFile, "utf8")).toContain("[daemon-exited-emit-failed]");
		}
	});

	test("spawn + status round-trip + heartbeat updates", async () => {
		const r = runDaemon("start", ["--master", MASTER_PANE, "--inner", innerPaneId]);
		expect(r.status).toBe(0);
		expect(r.stdout).toContain("daemon spawned pid=");

		const pidFile = join(stateDir, `fd-daemon-${SESSION_KEY}.pid`);
		const hbFile = join(stateDir, `fd-daemon-${SESSION_KEY}.heartbeat`);
		expect(existsSync(pidFile)).toBe(true);

		const pid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
		expect(pidAlive(pid)).toBe(true);

		// Heartbeat mtime updates each FD_POLL_SEC * FD_HEARTBEAT_TICKS
		// (round-4 #9 gates the touch by the same counter as the log
		// line). Default test env: FD_POLL_SEC=1, FD_HEARTBEAT_TICKS=2,
		// so expect an update within 3s.
		const m0 = statSync(hbFile).mtimeMs;
		await sleep(3000);
		const m1 = statSync(hbFile).mtimeMs;
		expect(m1).toBeGreaterThan(m0);

		const status = runDaemon("status");
		expect(status.status).toBe(0);
		expect(status.stdout).toMatch(/daemon=\d+ running/);

		const stop = runDaemon("stop");
		expect(stop.status).toBe(0);
		expect(stop.stdout).toContain("stopped daemon");

		// After stop: pid file removed.
		await sleep(200);
		expect(existsSync(pidFile)).toBe(false);
		expect(pidAlive(pid)).toBe(false);
	});

	test("reconcile refreshes tracked window names and daemon stays healthy", async () => {
		const repo = mkdtempSync(join(tmpdir(), "fd-runloop-registry-"));
		spawnSync("git", ["init", "-q", "-b", "main"], { cwd: repo });
		const statePath = join(repo, "tmp", `flightdeck-state-${SESSION_NAME}.json`);
		const logFile = join(stateDir, `fd-daemon-${SESSION_KEY}.log`);
		try {
			const paneTarget = spawnSync("tmux", ["display-message", "-p", "-t", innerPaneId, "#{session_name}:#{window_index}.#{pane_index}"], { encoding: "utf8" }).stdout.trim();
			const windowIndex = spawnSync("tmux", ["display-message", "-p", "-t", innerPaneId, "#{window_index}"], { encoding: "utf8" }).stdout.trim();
			const init = runPaneRegistry(repo, [
				"init-entry", "name-refresh",
				"--title", "Spawn title",
				"--kind", "adhoc",
				"--cwd", repo,
				"--window", windowIndex,
				"--harness", "shell",
				"--pane-id", innerPaneId,
				"--pane-target", paneTarget,
			]);
			if (init.status !== 0) throw new Error(`pane-registry init failed: status=${init.status} stdout=${init.stdout} stderr=${init.stderr}`);

			const renamed = `fd-name-refresh-${Date.now()}`;
			expect(spawnSync("tmux", ["rename-window", "-t", innerPaneId, renamed]).status).toBe(0);

			const env = { FD_RECONCILE_INTERVAL_SEC: "1", FLIGHTDECK_STATE_DIR: "tmp" };
			const started = runDaemonIn(repo, "start", ["--master", MASTER_PANE, "--inner", innerPaneId], env);
			expect(started.status).toBe(0);
			expect(started.stdout).toContain("daemon spawned pid=");

			const refreshed = await waitFor(() => {
				if (!existsSync(statePath) || !existsSync(logFile)) return false;
				const state = JSON.parse(readFileSync(statePath, "utf8"));
				const logged = readFileSync(logFile, "utf8").includes("[window-name-refresh]");
				return state.entries?.["name-refresh"]?.window_name_current === renamed && logged;
			}, 6000);
			expect(refreshed).toBe(true);

			const status = runDaemonIn(repo, "status", [], env);
			expect(status.status).toBe(0);
			expect(status.stdout).toMatch(/daemon=\d+ running/);
		} finally {
			runDaemonIn(repo, "stop", [], { FLIGHTDECK_STATE_DIR: "tmp" });
			rmSync(repo, { force: true, recursive: true });
		}
	}, 12000);

	test("stop cleans up subscriber pid files (no orphans)", async () => {
		const r = runDaemon("start", ["--master", MASTER_PANE, "--inner", innerPaneId]);
		expect(r.status).toBe(0);
		await sleep(300);
		runDaemon("stop");
		await sleep(200);
		// No subscriber pid files for our session_key should remain.
		const { readdirSync } = await import("node:fs");
		const entries = readdirSync(stateDir);
		const subFiles = entries.filter((e) => e.includes(`subscriber-${SESSION_KEY}-`));
		expect(subFiles).toEqual([]);
	});

	test("pi session mismatch quarantines same-batch rows and respawns without stale reattach", async () => {
		const masterPane = tmuxNewWindow(SESSION, `fd-pi-mismatch-master-${Date.now()}`);
		const testSessionKey = `${SESSION_KEY}-pimismatch-${Date.now()}`;
		const activityPath = join(stateDir, "activity.jsonl");
		const fakeDir = join(stateDir, "fake-bin");
		mkdirSync(fakeDir, { recursive: true });
		const streamCountFile = join(stateDir, "stream-count");
		const fakeSocket = join(stateDir, "pi.sock");
		const bridgeBin = join(fakeDir, "pi-bridge");
		const cwdJson = JSON.stringify(process.cwd());
		const socketJson = JSON.stringify(fakeSocket);
		writeFileSync(bridgeBin, `#!/usr/bin/env bash
count_file=${JSON.stringify(streamCountFile)}
case "\${1:-}" in
  list)
    printf '%s\n' '[{"pid":${process.pid},"cwd":${cwdJson},"sessionId":"pi-new","socketPath":${socketJson}}]'
    ;;
  state)
    printf '%s\n' '{"data":{"protocol":"pi-session-bridge.v1","sessionId":"pi-new","socketPath":${socketJson}}}'
    ;;
  questions)
    printf '{"success":true,"data":{"questions":[]}}\n'
    ;;
  stream)
    count=0
    [[ -f "$count_file" ]] && count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if (( count == 1 )); then
      printf '%s\n' '{"type":"bridge_hello","protocol":"pi-session-bridge.v1","state":{"sessionId":"pi-old","socketPath":${socketJson}}}'
      printf '{"type":"event","event":"question","data":{"action":"opened","requestId":"stale-q","request":{"id":"stale-q","header":"Wrong session","questions":[]}}}\n'
      sleep 30
    else
      printf '%s\n' '{"type":"bridge_hello","protocol":"pi-session-bridge.v1","state":{"sessionId":"pi-new","socketPath":${socketJson}}}'
      sleep 30
    fi
    ;;
esac
exit 0
`);
		chmodSync(bridgeBin, 0o755);
		const registryBin = join(fakeDir, "pane-registry");
		const rows = JSON.stringify([{ pane_id: innerPaneId, pane_target: innerPaneId, harness: "pi", kind: "workflow", cwd: process.cwd(), pi_bridge_pid: process.pid, pi_bridge_socket: fakeSocket, pi_session_id: "pi-new" }]);
		writeFileSync(registryBin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "list" ]]; then
  printf '%s\n' ${JSON.stringify(rows)}
  exit 0
fi
if [[ "\${1:-}" == "find-by-pane" ]]; then
  printf '{"id":"pi-entry","kind":"workflow"}\n'
  exit 0
fi
if [[ "\${1:-}" == "pi-bridge-args" ]]; then
  printf -- '--pid %s --socket %s\n' ${process.pid} ${JSON.stringify(fakeSocket)}
  exit 0
fi
exit 1
`);
		chmodSync(registryBin, 0o755);
		writeFileSync(join(stateDir, `fd-wake-events-${testSessionKey}.log`), [
			JSON.stringify({ ts: new Date().toISOString(), pane_id: innerPaneId, harness: "pi", event_type: "pi_session_connected", classifier_tag: "pi-session-connected", hash: "badc0ffee001", pi_session_id: "pi-old", expected_pi_session_id: "pi-new", pi_pid: String(process.pid), pi_socket: fakeSocket }),
			JSON.stringify({ ts: new Date().toISOString(), pane_id: innerPaneId, harness: "pi", event_type: "question", request_id: "stale-q", question: { id: "stale-q", header: "Wrong session", questions: [] }, classifier_tag: "pi-question", hash: "badc0ffee002" }),
		].join("\n") + "\n");

		const savedBridge = process.env.PI_BRIDGE_BIN;
		const savedStateDir = process.env.FD_STATE_DIR;
		process.env.PI_BRIDGE_BIN = bridgeBin;
		process.env.FD_STATE_DIR = stateDir;
		const loopPromise = runLoop({
			activity: { activityPath, sessionId: "pi-mismatch-test" },
			captureLines: 20,
			classifierBin: "",
			debugPane: "",
			defaultHarness: "pi",
			fromHandoff: false,
			graceSec: 0,
			heartbeatTicks: 60,
			innerHarnesses: ["pi"],
			innerTargets: [innerPaneId],
			masterHarness: "pi",
			masterTarget: masterPane,
			masterTurnTtl: 60,
			maxLifetime: 0,
			origArgs: [],
			paneRegistryBin: registryBin,
			pollSec: 0.1,
			scriptPath: SCRIPT,
			sessionId: SESSION,
			sessionKey: testSessionKey,
			sessionName: SESSION_NAME,
			stabilitySec: 999,
			stateDir,
			verbose: true,
			wakePendingTtl: 60,
		});
		try {
			const subLogFile = join(stateDir, `fd-daemon-${testSessionKey}.log.pi-sub-${innerPaneId.replace(/^%/, "")}`);
			const pidFile = join(stateDir, `fd-pi-subscriber-${testSessionKey}-${innerPaneId.replace(/^%/, "")}.pid`);
			const sawExpectedSessionArg = await waitFor(() => existsSync(subLogFile) && readFileSync(subLogFile, "utf8").includes("[pi-sub-start]") && readFileSync(subLogFile, "utf8").includes("expected_session=pi-new"), 3000);
			expect(sawExpectedSessionArg).toBe(true);
			const sawRespawn = await waitFor(() => {
				if (!existsSync(streamCountFile)) return false;
				return Number.parseInt(readFileSync(streamCountFile, "utf8").trim() || "0", 10) >= 2;
			}, 8000);
			expect(sawRespawn).toBe(true);
			const logFile = join(stateDir, `fd-daemon-${testSessionKey}.log`);
			const readSpawnPids = (): number[] => {
				if (!existsSync(logFile)) return [];
				return Array.from(readFileSync(logFile, "utf8").matchAll(/\[pi-subscriber-spawn\][^\n]*\spid=(\d+)/g))
					.map((m) => Number.parseInt(m[1]!, 10));
			};
			const sawTwoSpawnPids = await waitFor(() => readSpawnPids().length >= 2, 3000);
			expect(sawTwoSpawnPids).toBe(true);
			const spawnPids = readSpawnPids();
			const replacementPid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
			const oldPids = spawnPids.filter((pid) => pid !== replacementPid);
			expect(oldPids.length).toBeGreaterThan(0);
			expect(Number.isFinite(replacementPid) && replacementPid > 0).toBe(true);
			await sleep(5200);
			for (const oldPid of oldPids) expect(activeProcessGroupPids(oldPid)).toEqual([]);
			expect(readFileSync(pidFile, "utf8").trim()).toBe(String(replacementPid));
			expect(existsSync(subLogFile)).toBe(true);
			const sawMismatchLog = await waitFor(() => existsSync(logFile) && readFileSync(logFile, "utf8").includes("[pi-subscriber-mismatch]") && readFileSync(logFile, "utf8").includes("force-spawn requested"), 3000);
			expect(sawMismatchLog).toBe(true);
			const activity = readFileSync(activityPath, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
			expect(activity.some((row) => row.type === "subscriber.mismatch" && row.pane_id === innerPaneId)).toBe(true);
			const eventsFile = join(stateDir, `fd-daemon-events-${testSessionKey}.jsonl`);
			const eventText = existsSync(eventsFile) ? readFileSync(eventsFile, "utf8") : "";
			expect(eventText).not.toContain("stale-q");
		} finally {
			tmuxKillPaneFor(masterPane);
			const loopExited = await Promise.race([loopPromise.then(() => true), sleep(5000).then(() => false)]);
			expect(loopExited).toBe(true);
			const pidFile = join(stateDir, `fd-pi-subscriber-${testSessionKey}-${innerPaneId.replace(/^%/, "")}.pid`);
			if (existsSync(pidFile)) {
				const pid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
				if (pid) {
					try { process.kill(-pid, "SIGTERM"); } catch { /* */ }
					try { process.kill(pid, "SIGTERM"); } catch { /* */ }
				}
			}
			if (savedBridge === undefined) delete process.env.PI_BRIDGE_BIN;
			else process.env.PI_BRIDGE_BIN = savedBridge;
			if (savedStateDir === undefined) delete process.env.FD_STATE_DIR;
			else process.env.FD_STATE_DIR = savedStateDir;
		}
	}, 22000);

	test("pi mismatch force-respawn uses registry harness when default harness is not pi", async () => {
		const masterPane = tmuxNewWindow(SESSION, `fd-pi-harness-respawn-master-${Date.now()}`);
		const testSessionKey = `${SESSION_KEY}-piharness-${Date.now()}`;
		const activityPath = join(stateDir, "activity-harness.jsonl");
		const fakeDir = join(stateDir, "fake-bin-harness");
		mkdirSync(fakeDir, { recursive: true });
		const streamCountFile = join(stateDir, "stream-count-harness");
		const fakeSocket = join(stateDir, "pi-harness.sock");
		const bridgeBin = join(fakeDir, "pi-bridge");
		const cwdJson = JSON.stringify(process.cwd());
		const socketJson = JSON.stringify(fakeSocket);
		writeFileSync(bridgeBin, `#!/usr/bin/env bash
count_file=${JSON.stringify(streamCountFile)}
case "\${1:-}" in
  list)
    printf '%s\n' '[{"pid":${process.pid},"cwd":${cwdJson},"sessionId":"pi-new","socketPath":${socketJson}}]'
    ;;
  state)
    printf '%s\n' '{"data":{"protocol":"pi-session-bridge.v1","sessionId":"pi-new","socketPath":${socketJson}}}'
    ;;
  questions)
    printf '{"success":true,"data":{"questions":[]}}\n'
    ;;
  stream)
    count=0
    [[ -f "$count_file" ]] && count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    printf '%s\n' '{"type":"bridge_hello","protocol":"pi-session-bridge.v1","state":{"sessionId":"pi-new","socketPath":${socketJson}}}'
    sleep 30
    ;;
esac
exit 0
`);
		chmodSync(bridgeBin, 0o755);
		const registryBin = join(fakeDir, "pane-registry");
		const rows = JSON.stringify([{ pane_id: innerPaneId, pane_target: innerPaneId, harness: "pi", kind: "workflow", cwd: process.cwd(), pi_bridge_pid: process.pid, pi_bridge_socket: fakeSocket, pi_session_id: "pi-new" }]);
		writeFileSync(registryBin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "list" ]]; then
  printf '%s\n' ${JSON.stringify(rows)}
  exit 0
fi
if [[ "\${1:-}" == "find-by-pane" ]]; then
  printf '{"id":"pi-entry","kind":"workflow"}\n'
  exit 0
fi
if [[ "\${1:-}" == "pi-bridge-args" ]]; then
  printf -- '--pid %s --socket %s\n' ${process.pid} ${JSON.stringify(fakeSocket)}
  exit 0
fi
exit 1
`);
		chmodSync(registryBin, 0o755);
		writeFileSync(join(stateDir, `fd-wake-events-${testSessionKey}.log`), JSON.stringify({ ts: new Date().toISOString(), pane_id: innerPaneId, harness: "pi", event_type: "pi_session_connected", classifier_tag: "pi-session-connected", hash: "badc0ffee101", pi_session_id: "pi-old", expected_pi_session_id: "pi-new", pi_pid: String(process.pid), pi_socket: fakeSocket }) + "\n");

		const savedBridge = process.env.PI_BRIDGE_BIN;
		const savedStateDir = process.env.FD_STATE_DIR;
		process.env.PI_BRIDGE_BIN = bridgeBin;
		process.env.FD_STATE_DIR = stateDir;
		const loopPromise = runLoop({
			activity: { activityPath, sessionId: "pi-harness-respawn-test" },
			captureLines: 20,
			classifierBin: "",
			debugPane: "",
			defaultHarness: "opencode",
			fromHandoff: false,
			graceSec: 0,
			heartbeatTicks: 60,
			innerHarnesses: [""],
			innerTargets: [innerPaneId],
			masterHarness: "pi",
			masterTarget: masterPane,
			masterTurnTtl: 60,
			maxLifetime: 0,
			origArgs: [],
			paneRegistryBin: registryBin,
			pollSec: 0.1,
			scriptPath: SCRIPT,
			sessionId: SESSION,
			sessionKey: testSessionKey,
			sessionName: SESSION_NAME,
			stabilitySec: 999,
			stateDir,
			verbose: true,
			wakePendingTtl: 60,
		});
		try {
			const subLogFile = join(stateDir, `fd-daemon-${testSessionKey}.log.pi-sub-${innerPaneId.replace(/^%/, "")}`);
			const daemonLogFile = join(stateDir, `fd-daemon-${testSessionKey}.log`);
			const pidFile = join(stateDir, `fd-pi-subscriber-${testSessionKey}-${innerPaneId.replace(/^%/, "")}.pid`);
			const sawPiRespawn = await waitFor(() => existsSync(subLogFile) && readFileSync(subLogFile, "utf8").includes("[pi-sub-start]") && readFileSync(subLogFile, "utf8").includes("expected_session=pi-new"), 5000);
			expect(sawPiRespawn).toBe(true);
			expect(existsSync(pidFile)).toBe(true);
			const logText = existsSync(daemonLogFile) ? readFileSync(daemonLogFile, "utf8") : "";
			expect(logText).toContain("[pi-subscriber-spawn]");
			expect(logText).not.toContain("[oc-subscriber-spawn]");
			const streamed = await waitFor(() => existsSync(streamCountFile) && Number.parseInt(readFileSync(streamCountFile, "utf8").trim() || "0", 10) >= 1, 5000);
			expect(streamed).toBe(true);
			const activity = readFileSync(activityPath, "utf8").trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
			expect(activity.some((row) => row.type === "subscriber.mismatch" && row.pane_id === innerPaneId)).toBe(true);
		} finally {
			tmuxKillPaneFor(masterPane);
			const loopExited = await Promise.race([loopPromise.then(() => true), sleep(5000).then(() => false)]);
			expect(loopExited).toBe(true);
			const pidFile = join(stateDir, `fd-pi-subscriber-${testSessionKey}-${innerPaneId.replace(/^%/, "")}.pid`);
			if (existsSync(pidFile)) {
				const pid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
				if (pid) {
					try { process.kill(-pid, "SIGTERM"); } catch { /* */ }
				}
			}
			if (savedBridge === undefined) delete process.env.PI_BRIDGE_BIN;
			else process.env.PI_BRIDGE_BIN = savedBridge;
			if (savedStateDir === undefined) delete process.env.FD_STATE_DIR;
			else process.env.FD_STATE_DIR = savedStateDir;
		}
	}, 22000);

	test("PID lock held externally → start fails within 6.1s grace (round-4 #2)", async () => {
		// Pre-fix bug: withInprocFlock blocked on LOCK_EX so the daemon's
		// 30 × 200ms retry loop devolved into a single blocking call that
		// would only return when the holder released. Fix: tryAcquireLockFd
		// uses LOCK_EX | LOCK_NB so each attempt returns immediately.
		const pidLock = join(stateDir, `fd-daemon-${SESSION_KEY}.lock`);
		// Create the lock file first so flock can acquire it.
		writeFileSync(pidLock, "");
		const { spawn } = await import("node:child_process");
		const holder = spawn("flock", ["-n", pidLock, "sleep", "30"], { stdio: "ignore" });
		await sleep(200);
		try {
			const env = { ...(process.env as Record<string, string>), FD_STATE_DIR: stateDir } as Record<string, string>;
					const t0 = Date.now();
			const child = spawn(SCRIPT, ["start", "--session", SESSION_NAME, "--master", MASTER_PANE, "--inner", innerPaneId, "--foreground"], { env, stdio: ["ignore", "pipe", "pipe"] });
			let stderr = "";
			child.stderr!.on("data", (b: Buffer) => { stderr += b.toString(); });
			const exitCode = await new Promise<number>((res, rej) => {
				const timer = setTimeout(() => { child.kill("SIGKILL"); rej(new Error("daemon start did not exit within 8s")); }, 8000);
				child.on("exit", (code) => { clearTimeout(timer); res(code ?? -1); });
			});
			const dt = Date.now() - t0;
			expect(exitCode).not.toBe(0);
			expect(stderr).toMatch(/daemon already running.*retries/);
			// 30 retries × 200ms = 6000ms; allow up to 7s for jitter +
			// trampoline startup overhead.
			expect(dt).toBeLessThan(7000);
		} finally {
			holder.kill("SIGKILL");
		}
	}, 15000);

	test("tmux-window mode propagates env to the child window (round-4 #4)", async () => {
		// Regression: tmux new-window dispatch must explicitly pass
		// FD_STATE_DIR into the child env. tmux server doesn't inherit
		// caller env; without the explicit env wiring the child wrote
		// state to the default dir (not our isolated stateDir) and the
		// caller's dispatch timed out after 10s waiting for a pid file.
		const r = runDaemon("start", ["--master", MASTER_PANE, "--inner", innerPaneId, "--in-tmux-window"]);
		expect(r.status).toBe(0);
		expect(r.stdout).toContain("mode=tmux-window");
		// Child must have written its pid into OUR isolated stateDir,
		// proving FD_STATE_DIR was propagated through the tmux dispatch.
		const pidFile = join(stateDir, `fd-daemon-${SESSION_KEY}.pid`);
		expect(existsSync(pidFile)).toBe(true);
		const pid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
		expect(pidAlive(pid)).toBe(true);
		const logFile = join(stateDir, `fd-daemon-${SESSION_KEY}.log`);
		await sleep(500);
		expect(existsSync(logFile)).toBe(true);
		const foundWindow = runDaemon("find-window");
		expect(foundWindow.status).toBe(0);
		const windowName = spawnSync("tmux", ["display-message", "-p", "-t", foundWindow.stdout.trim(), "#{window_name}"], { encoding: "utf8" }).stdout.trim();
		expect(windowName).toBe(`[fd] daemon-${SESSION_KEY}`);
		runDaemon("stop");
		await sleep(300);
		// Kill the tmux daemon window if it's still around.
		spawnSync("tmux", ["kill-window", "-t", `[fd] daemon-${SESSION_KEY}`], { stdio: "ignore" });
	}, 15000);

	test("from-handoff startup warns and drops stale inner panes instead of exiting", async () => {
		const stalePane = tmuxNewWindow(SESSION, `fd-stale-handoff-${Date.now()}`);
		tmuxKillPaneFor(stalePane);
		const logFile = join(stateDir, `fd-daemon-${SESSION_KEY}.log`);
		const child = spawn(
			SCRIPT,
			["start", "--session", SESSION_NAME, "--master", MASTER_PANE, "--inner", `${stalePane},${innerPaneId}`, "--inner-harnesses", "pi,pi", "--foreground", "--from-handoff"],
			{ env: daemonEnv(true), stdio: ["ignore", "ignore", "pipe"] },
		);
		try {
			const started = await waitFor(() => existsSync(logFile) && readFileSync(logFile, "utf8").includes("[start]"));
			expect(started).toBe(true);
			expect(child.exitCode).toBeNull();
			const logText = readFileSync(logFile, "utf8");
			expect(logText).toContain(`[handoff-inner-stale] dropping stale handoff inner pane '${stalePane}' (cannot resolve)`);
			expect(logText).toContain(`inner_ids=${innerPaneId}`);
		} finally {
			try { child.kill("SIGTERM"); } catch { /* */ }
			runDaemon("stop");
			await sleep(200);
		}
	}, 10000);

	test("FD_MAX_LIFETIME successor preserves state across handoff (round-5 #1 + round-4 #3)", async () => {
		// Pre-fix bugs (round-4 #3): shell wrapper put log path in $@
		// → 'nohup tried to run log file as command'. successor's
		// origArgs missed the 'start' action. EXIT cleanup destroyed
		// PID_FILE/heartbeat/wake-pending/events.
		//
		// Round-5 #1: even after round-4 fixed the parent's EXIT path,
		// the successor's foregroundStart still ran an unconditional
		// fresh-start wipe that destroyed wake-pending / events /
		// wake-events.log seconds later. Fix: --from-handoff flag
		// threaded through maxLifetimeExec → CLI → foregroundStart,
		// gates the wipe.
		//
		// This test seeds all three state files BEFORE the rollover
		// and asserts they still exist with their seeded content
		// AFTER the handoff completes.
		const env = { ...(process.env as Record<string, string>), FD_STATE_DIR: stateDir, FLIGHTDECK_STATE_DIR: stateDir, FD_MAX_LIFETIME: "2", FD_POLL_SEC: "1", FD_HEARTBEAT_TICKS: "5" } as Record<string, string>;
		const r = spawnSync(SCRIPT, ["start", "--session", SESSION_NAME, "--master", MASTER_PANE, "--inner", innerPaneId], { encoding: "utf8", env });
		expect(r.status).toBe(0);
		const pidFile = join(stateDir, `fd-daemon-${SESSION_KEY}.pid`);
		const hbFile = join(stateDir, `fd-daemon-${SESSION_KEY}.heartbeat`);
		const logFile = join(stateDir, `fd-daemon-${SESSION_KEY}.log`);
		const wakePending = join(stateDir, `fd-wake-pending-${SESSION_KEY}`);
		const eventsFile = join(stateDir, `fd-daemon-events-${SESSION_KEY}.jsonl`);
		const wakeEventsLog = join(stateDir, `fd-wake-events-${SESSION_KEY}.log`);
		const initialPid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
		expect(initialPid).toBeGreaterThan(0);

		// Seed all three state files BEFORE the rollover. Use the real
		// innerPaneId so the successor's run-loop drain considers the
		// wake-events row alive (paneCache.alive check passes) and
		// appends to events.jsonl.
		const wakePendingPayload = JSON.stringify({ delivered_at_epoch: Math.floor(Date.now() / 1000), in_flight: [{ pane_id: innerPaneId, hash: "hSURVIVE", tag: "merge-now", is_bell: false }], _round5_sentinel: "WAKE-PENDING-SURVIVED" });
		const eventsRow = JSON.stringify({ ts: new Date().toISOString(), pane_id: innerPaneId, hash: "hSURVIVE", tag: "merge-now", reason: "stable", _round5_sentinel: "EVENTS-SURVIVED" });
		const wakeEventsRow = JSON.stringify({ ts: new Date().toISOString(), pane_id: innerPaneId, harness: "opencode", classifier_tag: "merge-now", hash: "hSURVIVE_WEL", _round5_sentinel: "WAKE-EVENTS-SURVIVED" });
		writeFileSync(wakePending, wakePendingPayload);
		writeFileSync(eventsFile, eventsRow + "\n");
		writeFileSync(wakeEventsLog, wakeEventsRow + "\n");

		// Wait past FD_MAX_LIFETIME so the successor fires.
		await sleep(3500);

		// PID file now points at the successor.
		expect(existsSync(pidFile)).toBe(true);
		expect(existsSync(hbFile)).toBe(true);
		const successorPid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
		expect(successorPid).toBeGreaterThan(0);
		expect(successorPid).not.toBe(initialPid);
		expect(pidAlive(successorPid)).toBe(true);

		// State files MUST survive the handoff. The pre-round-5 bug
		// wiped them in the successor's foregroundStart; this is the
		// regression test that catches it.
		//
		// wake-pending + events.jsonl are NOT auto-consumed by the
		// run loop (only by master's ack), so their seeded sentinel
		// text must persist verbatim.
		//
		// wake-events.log IS consumed by the run loop's drain on the
		// successor's first tick. We can't time-window a check before
		// the drain runs, so instead assert the drain saw our seeded
		// hash by checking that the new events.jsonl row appended by
		// the drain references the same sentinel hash 'hSURVIVE'. If
		// the wipe had run, the drain would have nothing to consume
		// and no hSURVIVE row from the wake-events drain would be
		// appended (only the original seeded events row).
		expect(existsSync(wakePending)).toBe(true);
		expect(readFileSync(wakePending, "utf8")).toContain("WAKE-PENDING-SURVIVED");
		expect(existsSync(eventsFile)).toBe(true);
		const eventsText = readFileSync(eventsFile, "utf8");
		expect(eventsText).toContain("EVENTS-SURVIVED");
		// Two distinct hashes should appear: the original seed
		// 'hSURVIVE' (reason="stable") AND the drain-produced row
		// 'hSURVIVE_WEL' (reason="adapter-event"). Without the wipe-
		// skip fix, the second hash would be missing because the
		// wake-events.log got wiped before the run loop could drain.
		expect(eventsText).toContain("hSURVIVE");
		expect(eventsText).toContain("hSURVIVE_WEL");

		// Log file should have the [max-lifetime] + [stop-handoff] +
		// [from-handoff] markers (parent and successor).
		const logText = readFileSync(logFile, "utf8");
		expect(logText).toMatch(/\[max-lifetime\]/);
		expect(logText).toMatch(/\[stop-handoff\]/);
		expect(logText).toMatch(/\[from-handoff\]/);

		runDaemon("stop");
		await sleep(300);
	}, 10000);

	test("FD_MAX_LIFETIME handoff re-queries live registry panes and drops stale inner panes", async () => {
		const paneB = tmuxNewWindow(SESSION, `fd-handoff-b-${Date.now()}`);
		const paneC = tmuxNewWindow(SESSION, `fd-handoff-c-${Date.now()}`);
		extraPaneIds.push(paneB, paneC);
		registerPane("handoff-a", innerPaneId);
		registerPane("handoff-b", paneB);
		registerPane("handoff-c", paneC);

		const env = { ...daemonEnv(true), FD_MAX_LIFETIME: "2", FD_POLL_SEC: "1", FD_HEARTBEAT_TICKS: "5" } as Record<string, string>;
		const innerCsv = [innerPaneId, paneB, paneC].join(",");
		const r = spawnSync(SCRIPT, ["start", "--session", SESSION_NAME, "--master", MASTER_PANE, "--inner", innerCsv, "--inner-harnesses", "pi,pi,pi"], { encoding: "utf8", env });
		expect(r.status).toBe(0);
		const pidFile = join(stateDir, `fd-daemon-${SESSION_KEY}.pid`);
		const logFile = join(stateDir, `fd-daemon-${SESSION_KEY}.log`);
		const initialPid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
		expect(initialPid).toBeGreaterThan(0);

		tmuxKillPaneFor(paneB);
		tmuxKillPaneFor(paneC);

		const successorStarted = await waitFor(() => {
			if (!existsSync(pidFile)) return false;
			const pid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
			return pid > 0 && pid !== initialPid && pidAlive(pid);
		}, 9000);
		expect(successorStarted).toBe(true);

		const successorPid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
		expect(successorPid).not.toBe(initialPid);
		expect(pidAlive(successorPid)).toBe(true);
		const successorLogged = await waitFor(() => lastStartLine(readFileSync(logFile, "utf8")).includes(`pid=${successorPid}`), 3000);
		expect(successorLogged).toBe(true);
		const logText = readFileSync(logFile, "utf8");
		expect(logText).toContain(`[handoff-inner-live] source=live panes=1 inner=${innerPaneId} harnesses=pi`);
		const successorStart = lastStartLine(logText);
		expect(successorStart).toContain(`inner_ids=${innerPaneId}`);
		expect(successorStart).not.toContain(paneB);
		expect(successorStart).not.toContain(paneC);
		expect(logText).not.toContain("[handoff-inner-stale]");
		expect(logText).not.toContain(`Error: cannot resolve inner pane '${paneB}'`);
		expect(logText).not.toContain(`Error: cannot resolve inner pane '${paneC}'`);

		runDaemon("stop");
		await sleep(300);
	}, 12000);

	test("FD_MAX_LIFETIME handoff allows confirmed zero live panes", async () => {
		const paneB = tmuxNewWindow(SESSION, `fd-handoff-zero-b-${Date.now()}`);
		const paneC = tmuxNewWindow(SESSION, `fd-handoff-zero-c-${Date.now()}`);
		extraPaneIds.push(paneB, paneC);
		registerPane("handoff-zero-a", innerPaneId);
		registerPane("handoff-zero-b", paneB);
		registerPane("handoff-zero-c", paneC);

		const env = { ...daemonEnv(true), FD_MAX_LIFETIME: "2", FD_POLL_SEC: "1", FD_HEARTBEAT_TICKS: "5" } as Record<string, string>;
		const innerCsv = [innerPaneId, paneB, paneC].join(",");
		const r = spawnSync(SCRIPT, ["start", "--session", SESSION_NAME, "--master", MASTER_PANE, "--inner", innerCsv, "--inner-harnesses", "pi,pi,pi"], { encoding: "utf8", env });
		expect(r.status).toBe(0);
		const pidFile = join(stateDir, `fd-daemon-${SESSION_KEY}.pid`);
		const logFile = join(stateDir, `fd-daemon-${SESSION_KEY}.log`);
		const initialPid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
		expect(initialPid).toBeGreaterThan(0);

		tmuxKillPaneFor(innerPaneId);
		tmuxKillPaneFor(paneB);
		tmuxKillPaneFor(paneC);

		const successorStarted = await waitFor(() => {
			if (!existsSync(pidFile)) return false;
			const pid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
			return pid > 0 && pid !== initialPid && pidAlive(pid);
		}, 9000);
		expect(successorStarted).toBe(true);
		const successorPid = Number.parseInt(readFileSync(pidFile, "utf8").trim(), 10);
		const successorLogged = await waitFor(() => lastStartLine(readFileSync(logFile, "utf8")).includes(`pid=${successorPid}`), 3000);
		expect(successorLogged).toBe(true);

		const logText = readFileSync(logFile, "utf8");
		expect(logText).toContain("[handoff-inner-live] source=live panes=0 inner=(empty) harnesses=(empty)");
		const successorStart = lastStartLine(logText);
		expect(successorStart).toContain("inner_ids=");
		expect(successorStart).not.toContain(innerPaneId);
		expect(successorStart).not.toContain(paneB);
		expect(successorStart).not.toContain(paneC);
		expect(logText).not.toContain("[handoff-inner-stale]");

		runDaemon("stop");
		await sleep(300);
	}, 12000);

	test("ack drains events + clears wake-pending atomically", async () => {
		const r = runDaemon("start", ["--master", MASTER_PANE, "--inner", innerPaneId]);
		expect(r.status).toBe(0);
		await sleep(300);

		// Seed an event and wake-pending. The daemon hasn't appended
		// to events file yet (no real wake fired), so we manually
		// inject the same shape it would produce.
		const eventsFile = join(stateDir, `fd-daemon-events-${SESSION_KEY}.jsonl`);
		const wakePending = join(stateDir, `fd-wake-pending-${SESSION_KEY}`);
		writeFileSync(eventsFile, JSON.stringify({ ts: new Date().toISOString(), pane_id: innerPaneId, hash: "h1", tag: "merge-now", reason: "stable" }) + "\n");
		writeFileSync(wakePending, JSON.stringify({ delivered_at_epoch: Math.floor(Date.now() / 1000), in_flight: [{ pane_id: innerPaneId, hash: "h1", tag: "merge-now", is_bell: false }] }));

		const ack = runDaemon("ack");
		expect(ack.status).toBe(0);
		expect(ack.stdout).toContain("\"merge-now\"");
		expect(existsSync(wakePending)).toBe(false);
		// Events file is removed by drain (snapshot + rm).
		expect(existsSync(eventsFile)).toBe(false);

		runDaemon("stop");
		await sleep(200);
	});

	// vstack#180: when the tracked entry lacks pi adapter metadata the
	// daemon used to emit one [pi-subscriber-bind-skip] per pane per tick
	// (default 5s), flooding the log to hundreds of lines per pane in 20
	// minutes and burying any other diagnostic. The fix throttles those
	// to one line per (pane,reason) per minute, emits a one-shot startup
	// warning that names the missing fields, and emits a single
	// [pi-subscriber-bind-stuck] warning after 12 consecutive skips so
	// the supervisor has a real signal instead of silence.
	test("pi bind-skip is throttled and surfaces missing fields without log flood", async () => {
		const masterPane = tmuxNewWindow(SESSION, `fd-bind-skip-master-${Date.now()}`);
		extraPaneIds.push(masterPane);
		const testSessionKey = `${SESSION_KEY}-bindskip-${Date.now()}`;
		const activityPath = join(stateDir, "activity-bindskip.jsonl");
		const fakeDir = join(stateDir, "fake-bindskip");
		mkdirSync(fakeDir, { recursive: true });
		const logFile = join(stateDir, `fd-daemon-${testSessionKey}.log`);

		// Registry returns the harness=pi entry but with NULL pi adapter
		// fields, reproducing the post-bug state.
		const registryBin = join(fakeDir, "pane-registry");
		const rows = JSON.stringify([{ pane_id: innerPaneId, pane_target: innerPaneId, harness: "pi", kind: "issue", cwd: process.cwd(), pi_bridge_pid: null, pi_bridge_socket: null, pi_session_id: null }]);
		writeFileSync(registryBin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "list" ]]; then
  printf '%s\n' ${JSON.stringify(rows)}
  exit 0
fi
if [[ "\${1:-}" == "find-by-pane" ]]; then
  printf '{"id":"pi-bindskip","kind":"issue"}\n'
  exit 0
fi
if [[ "\${1:-}" == "pi-bridge-args" ]]; then
  exit 0
fi
exit 1
`);
		chmodSync(registryBin, 0o755);

		const savedStateDir = process.env.FD_STATE_DIR;
		const savedStuck = process.env.FD_PI_BIND_SKIP_STUCK_THRESHOLD;
		const savedInterval = process.env.FD_PI_BIND_SKIP_LOG_INTERVAL_SEC;
		process.env.FD_STATE_DIR = stateDir;
		process.env.FD_PI_BIND_SKIP_STUCK_THRESHOLD = "2";
		process.env.FD_PI_BIND_SKIP_LOG_INTERVAL_SEC = "600";
		const loopPromise = runLoop({
			activity: { activityPath, sessionId: "bind-skip-test" },
			captureLines: 20,
			classifierBin: "",
			debugPane: "",
			defaultHarness: "pi",
			fromHandoff: false,
			graceSec: 0,
			heartbeatTicks: 600,
			innerHarnesses: ["pi"],
			innerTargets: [innerPaneId],
			masterHarness: "pi",
			masterTarget: masterPane,
			masterTurnTtl: 60,
			maxLifetime: 0,
			origArgs: [],
			paneRegistryBin: registryBin,
			pollSec: 0.1,
			scriptPath: SCRIPT,
			sessionId: SESSION,
			sessionKey: testSessionKey,
			sessionName: SESSION_NAME,
			stabilitySec: 999,
			stateDir,
			verbose: false,
			wakePendingTtl: 60,
		});
		try {
			// Wait until the startup probe and at least one bind-skip line are
			// in the daemon log. ~20 ticks at 100ms pollSec ≈ 2 seconds, well
			// inside the 60s throttle window — so we should still see only ONE
			// bind-skip line, plus the stuck warning after 12 consecutive
			// skips.
			const sawStartupWarn = await waitFor(() => existsSync(logFile) && readFileSync(logFile, "utf8").includes("[startup-binder-missing-fields]"), 3000);
			expect(sawStartupWarn).toBe(true);
			const sawBindSkip = await waitFor(() => existsSync(logFile) && readFileSync(logFile, "utf8").includes("[pi-subscriber-bind-skip]"), 3000);
			expect(sawBindSkip).toBe(true);
			const sawStuck = await waitFor(() => existsSync(logFile) && readFileSync(logFile, "utf8").includes("[pi-subscriber-bind-stuck]"), 5000);
			expect(sawStuck).toBe(true);

			// Now run another ~2 seconds and verify the bind-skip line count
			// stays at 1 (throttle holds for 60s) — proving the log isn't
			// flooded.
			await sleep(2000);
			const logText = readFileSync(logFile, "utf8");
			const skipLines = logText.split("\n").filter((l) => l.includes("[pi-subscriber-bind-skip]"));
			expect(skipLines.length).toBe(1);
			const stuckLines = logText.split("\n").filter((l) => l.includes("[pi-subscriber-bind-stuck]"));
			expect(stuckLines.length).toBe(1);
			expect(stuckLines[0]).toContain("missing=pi_bridge_pid,pi_bridge_socket,pi_session_id");
			expect(stuckLines[0]).toContain("reason=pi-bridge-bind-missing");
			const startupLines = logText.split("\n").filter((l) => l.includes("[startup-binder-missing-fields]"));
			expect(startupLines.length).toBe(1);
			expect(startupLines[0]).toContain("missing=pi_bridge_pid,pi_bridge_socket,pi_session_id");
		} finally {
			tmuxKillPaneFor(masterPane);
			const loopExited = await Promise.race([loopPromise.then(() => true), sleep(5000).then(() => false)]);
			expect(loopExited).toBe(true);
			if (savedStateDir === undefined) delete process.env.FD_STATE_DIR;
			else process.env.FD_STATE_DIR = savedStateDir;
			if (savedStuck === undefined) delete process.env.FD_PI_BIND_SKIP_STUCK_THRESHOLD;
			else process.env.FD_PI_BIND_SKIP_STUCK_THRESHOLD = savedStuck;
			if (savedInterval === undefined) delete process.env.FD_PI_BIND_SKIP_LOG_INTERVAL_SEC;
			else process.env.FD_PI_BIND_SKIP_LOG_INTERVAL_SEC = savedInterval;
		}
	}, 15000);
});
