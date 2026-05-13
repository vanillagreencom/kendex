// Smoke tests for skills/flightdeck/scripts/flightdeck-session.
// Uses the tmux shim; no real windows or Pi processes are created.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-session");
const PANE_ENV_SCRIPT = resolve(HERE, "../../../../scripts/lib/pane-env.sh");
const SHIM_DIR = resolve(HERE, "./tmux-shim");

interface ShimPane {
	window_id: string;
	window_name: string;
	path: string;
	window_index: number;
	pane_index: number;
	pane_pid?: number;
	sent_keys?: string[];
}

interface ShimState {
	session: string;
	panes: Record<string, ShimPane>;
	windows: Record<string, { name: string; index: number }>;
}

function makeRepo(): string {
	const dir = mkdtempSync(join(tmpdir(), "fdsession-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--allow-empty", "-m", "init"], {
		env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
	});
	return dir;
}

function writeShimState(repo: string, state: ShimState): string {
	const path = join(repo, "shim-state.json");
	writeFileSync(path, JSON.stringify(state, null, 2));
	return path;
}

function readShimState(path: string): ShimState {
	return JSON.parse(readFileSync(path, "utf8"));
}

function stateFile(repo: string): string {
	return join(repo, "tmp", "flightdeck-state-test-session.json");
}

function run(repo: string, statePath: string, args: string[], useTs: boolean, extraEnv: Record<string, string> = {}): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.TMUX = "/tmp/tmux-test";
	env.TMUX_SHIM_STATE = statePath;
	env.TMUX_PARITY_SESSION = "test-session";
	env.PATH = `${SHIM_DIR}:${env.PATH ?? ""}`;
	env.FLIGHTDECK_STATE_DIR = "tmp";
	if (useTs) {
		env.FLIGHTDECK_USE_TS_PANE_REGISTRY = "1";
		env.FLIGHTDECK_USE_TS_FLIGHTDECK_STATE = "1";
	} else {
		env.FLIGHTDECK_USE_TS_PANE_REGISTRY = "0";
		env.FLIGHTDECK_USE_TS_FLIGHTDECK_STATE = "0";
	}
	delete env.FLIGHTDECK_USE_TS;
	Object.assign(env, extraEnv);
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function makePiBridgeShim(repo: string): string {
	const bin = join(repo, "pi-bridge-shim");
	writeFileSync(bin, `#!/usr/bin/env bash
case "$1" in
  list)
    echo '[{"pid":4242,"socketPath":"/tmp/pi-77.sock","sessionId":"pi-session-77","cwd":"/tmp/attach"}]'
    ;;
  state)
    echo '{"data":{"protocol":"pi-session-bridge.v1","socketPath":"/tmp/pi-77.sock","sessionId":"pi-session-77"}}'
    ;;
  *) echo '{}' ;;
esac
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeFailingPiBridgeShim(repo: string): string {
	const bin = join(repo, "pi-bridge-fail-shim");
	writeFileSync(bin, `#!/usr/bin/env bash
exit 1
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeHangingPiBridgeShim(repo: string): string {
	const bin = join(repo, "pi-bridge-hang-shim");
	writeFileSync(bin, `#!/usr/bin/env bash
sleep 10
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeStartListTimeoutPiBridgeShim(repo: string): string {
	const bin = join(repo, "pi-bridge-start-timeout-shim");
	const countFile = join(repo, "pi-bridge-start-timeout.count");
	writeFileSync(bin, `#!/usr/bin/env bash
count_file=${JSON.stringify(countFile)}
count=0
[[ -f "$count_file" ]] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s' "$count" > "$count_file"
if [[ "$1" == "list" && "$count" == "1" ]]; then
  echo '[]'
  exit 0
fi
sleep 10
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeSnapshotFailThenSuccessPiBridgeShim(repo: string): string {
	const bin = join(repo, "pi-bridge-snapshot-fail-shim");
	const countFile = join(repo, "pi-bridge-snapshot-fail.count");
	writeFileSync(bin, `#!/usr/bin/env bash
count_file=${JSON.stringify(countFile)}
count=0
[[ -f "$count_file" ]] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s' "$count" > "$count_file"
case "$1" in
  list)
    if [[ "$count" == "1" ]]; then
      exit 7
    fi
    printf '[{"pid":5151,"socketPath":"/tmp/pi-snapshot.sock","sessionId":"pi-snapshot-session","cwd":%s}]\\n' ${JSON.stringify(JSON.stringify(repo))}
    ;;
  state)
    echo '{"data":{"protocol":"pi-session-bridge.v1","socketPath":"/tmp/pi-snapshot.sock","sessionId":"pi-snapshot-session"}}'
    ;;
  *) echo '{}' ;;
esac
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makePiBinShim(repo: string): string {
	const bin = join(repo, "pi-shim");
	writeFileSync(bin, `#!/usr/bin/env bash
echo pi-shim "$@"
`);
	chmodSync(bin, 0o755);
	return bin;
}

let repos: string[] = [];

beforeEach(() => {
	repos = [];
});

afterEach(() => {
	for (const repo of repos) if (existsSync(repo)) rmSync(repo, { recursive: true, force: true });
});

describe("flightdeck-session smoke", () => {
	test("pane env string helpers shell-escape metacharacters", () => {
		const script = `
source ${JSON.stringify(PANE_ENV_SCRIPT)}
FLIGHTDECK_CHILD_PANE_ENV=(env "A=space value" "B=single'quote" 'C=\`ticks\`' 'D=$dollar')
quoted=$(flightdeck_child_pane_env_str)
eval "set -- $quoted"
printf '%s\n' "$#"
for arg in "$@"; do printf '<%s>\n' "$arg"; done
`;
		const r = spawnSync("bash", ["-lc", script], { encoding: "utf8" });
		expect(r.status).toBe(0);
		expect(r.stdout.trim().split("\n")).toEqual([
			"5",
			"<env>",
			"<A=space value>",
			"<B=single'quote>",
			"<C=`ticks`>",
			"<D=$dollar>",
		]);
	});

	for (const useTs of [false, true]) {
		test(`start creates tmux window and registers entry (${useTs ? "ts registry" : "bash registry"})`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "adhoc-start",
				"--title", "Scratch",
				"--kind", "adhoc",
				"--cwd", repo,
				"--harness", "pi",
				"--cmd", "printf ok",
			], useTs);
			expect(r.status).toBe(0);
			const shimState = readShimState(shim);
			const pane = shimState.panes["%1"]!;
			expect(pane.window_name).toBe("Scratch");
			expect(pane.sent_keys).toContain("clear Enter");
			const launchLine = pane.sent_keys!.find((line) => line.includes("printf ok"))!;
			expect(launchLine).toContain("FLIGHTDECK_MANAGED=1");
			expect(launchLine).toContain("FLIGHTDECK_CHILD_PANE=1");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["adhoc-start"].pane_id).toBe("%1");
			expect(state.entries["adhoc-start"].kind).toBe("adhoc");
			expect(state.entries["adhoc-start"].cwd).toBe(repo);
		});

		test(`start reports tmux new-window failure without registering entry (${useTs ? "ts registry" : "bash registry"})`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "fail-start",
				"--title", "Fail",
				"--cwd", repo,
				"--harness", "pi",
				"--cmd", "printf ok",
			], useTs, { TMUX_SHIM_FAIL_NEW_WINDOW: "1" });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("tmux new-window failed");
			expect(existsSync(stateFile(repo))).toBe(false);
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		});

		test(`start records Pi discovery_error when bridge discovery times out (${useTs ? "ts registry" : "bash registry"})`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const started = Date.now();
			const r = run(repo, shim, [
				"start",
				"--session-id", "pi-timeout",
				"--title", "Pi timeout",
				"--cwd", repo,
				"--harness", "pi",
				"--prompt", "say hi",
			], useTs, { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makeStartListTimeoutPiBridgeShim(repo), PI_BRIDGE_CALL_TIMEOUT_SEC: "1", PI_BRIDGE_DISCOVERY_TIMEOUT: "5" });
			expect(Date.now() - started).toBeLessThan(4000);
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed during start");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pi-timeout"].discovery_error).toBe("pi_bridge_timeout");
			expect(state.entries["pi-timeout"].adapter.pi_bridge_socket).toBeNull();
		});

		test(`start surfaces pre-launch snapshot failure (${useTs ? "ts registry" : "bash registry"})`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "pi-snapshot-failed",
				"--title", "Pi snapshot failed",
				"--cwd", repo,
				"--harness", "pi",
				"--prompt", "say hi",
			], useTs, { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makeSnapshotFailThenSuccessPiBridgeShim(repo), PI_BRIDGE_CALL_TIMEOUT_SEC: "1", PI_BRIDGE_DISCOVERY_TIMEOUT: "2" });
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("Warning: pre-launch pi snapshot failed");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pi-snapshot-failed"].discovery_error).toBe("pi_snapshot_failed");
			expect(state.entries["pi-snapshot-failed"].adapter.pi_bridge_socket).toBe("/tmp/pi-snapshot.sock");
		});

		test(`start --strict-discovery refuses pre-launch snapshot failure (${useTs ? "ts registry" : "bash registry"})`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "pi-strict-snapshot-failed",
				"--title", "Pi strict snapshot failed",
				"--cwd", repo,
				"--harness", "pi",
				"--prompt", "say hi",
				"--strict-discovery",
			], useTs, { PI_BRIDGE_BIN: makeFailingPiBridgeShim(repo) });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("Warning: pre-launch pi snapshot failed");
			expect(r.stderr).toContain("--strict-discovery refusing Pi launch");
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
			expect(existsSync(stateFile(repo))).toBe(false);
		});

		test(`attach records existing pi pane metadata (${useTs ? "ts registry" : "bash registry"})`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, {
				panes: {
					"%77": { pane_index: 0, pane_pid: 4242, path: "/tmp/attach", window_id: "@7", window_index: 7, window_name: "manual-pi" },
				},
				session: "test-session",
				windows: { "@7": { index: 7, name: "manual-pi" } },
			});
			const bridge = makePiBridgeShim(repo);
			const r = run(repo, shim, [
				"attach",
				"--pane", "%77",
				"--harness", "pi",
				"--title", "Manual Pi",
			], useTs, { PI_BRIDGE_BIN: bridge });
			expect(r.status).toBe(0);
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pi-session-77"].pane_id).toBe("%77");
			expect(state.entries["pi-session-77"].adapter.pi_bridge_pid).toBe(4242);
			expect(state.entries["pi-session-77"].adapter.pi_bridge_socket).toBe("/tmp/pi-77.sock");
			expect(state.entries["pi-session-77"].adapter.pi_session_id).toBe("pi-session-77");
		});

		test(`attach records Pi discovery_error when bridge metadata is unavailable (${useTs ? "ts registry" : "bash registry"})`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, {
				panes: {
					"%88": { pane_index: 0, pane_pid: 8888, path: "/tmp/attach-missing", window_id: "@8", window_index: 8, window_name: "manual-pi-missing" },
				},
				session: "test-session",
				windows: { "@8": { index: 8, name: "manual-pi-missing" } },
			});
			const r = run(repo, shim, [
				"attach",
				"--pane", "%88",
				"--harness", "pi",
				"--title", "Manual Missing Pi",
			], useTs, { PI_BRIDGE_BIN: makeFailingPiBridgeShim(repo) });
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed during attach");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pane-88"].pane_id).toBe("%88");
			expect(state.entries["pane-88"].discovery_error).toBe("pi_bridge_list_failed");
		});

		test(`attach records Pi discovery_error when bridge call times out (${useTs ? "ts registry" : "bash registry"})`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, {
				panes: {
					"%89": { pane_index: 0, pane_pid: 8989, path: "/tmp/attach-timeout", window_id: "@9", window_index: 9, window_name: "manual-pi-timeout" },
				},
				session: "test-session",
				windows: { "@9": { index: 9, name: "manual-pi-timeout" } },
			});
			const started = Date.now();
			const r = run(repo, shim, [
				"attach",
				"--pane", "%89",
				"--harness", "pi",
				"--title", "Manual Timeout Pi",
			], useTs, { PI_BRIDGE_BIN: makeHangingPiBridgeShim(repo), PI_BRIDGE_CALL_TIMEOUT_SEC: "1" });
			expect(Date.now() - started).toBeLessThan(4000);
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed during attach");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pane-89"].pane_id).toBe("%89");
			expect(state.entries["pane-89"].discovery_error).toBe("pi_bridge_timeout");
		});
	}
});
