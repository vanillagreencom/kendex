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

		test(`start records Pi discovery_error when bridge discovery fails (${useTs ? "ts registry" : "bash registry"})`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "pi-degraded",
				"--title", "Pi degraded",
				"--cwd", repo,
				"--harness", "pi",
				"--prompt", "say hi",
			], useTs, { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makeFailingPiBridgeShim(repo), PI_BRIDGE_DISCOVERY_TIMEOUT: "0" });
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed during start");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pi-degraded"].discovery_error).toBe("pi_bridge_discovery_timeout");
			expect(state.entries["pi-degraded"].adapter.pi_bridge_socket).toBeNull();
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
			expect(state.entries["pane-88"].discovery_error).toBe("pi_bridge_no_instance_for_pane_pid");
		});
	}
});
