// Smoke tests for skills/flightdeck/scripts/flightdeck-session.
// Uses the tmux shim; no real windows or Pi processes are created.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
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
	windows: Record<string, { name: string; index: number; automatic_rename?: string }>;
	current_pane_id?: string;
	current_window_id?: string;
}

function makeRepo(): string {
	const dir = mkdtempSync(join(tmpdir(), "fdsession-"));
	spawnSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	spawnSync("git", ["-C", dir, "commit", "-q", "--no-gpg-sign", "--allow-empty", "-m", "init"], {
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

// vstack#227: state lives in the active run dir; resolve via the CLI.
function stateFile(repo: string): string {
	const flightdeckState = resolve(HERE, "../../../../scripts/flightdeck-state");
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.HOME = join(repo, "home");
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	const r = spawnSync(flightdeckState, ["path", "--session", "test-session"], { cwd: repo, encoding: "utf8", env });
	if (r.status !== 0) {
		throw new Error(`flightdeck-state path failed: ${r.stderr}`);
	}
	return (r.stdout ?? "").trim();
}

function run(repo: string, statePath: string, args: string[], extraEnv: Record<string, string> = {}): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.HOME = join(repo, "home");
	env.TMUX = "/tmp/tmux-test";
	env.TMUX_SHIM_STATE = statePath;
	env.TMUX_PARITY_SESSION = "test-session";
	env.PATH = `${SHIM_DIR}:${env.PATH ?? ""}`;
	env.FLIGHTDECK_STATE_DIR = "tmp";
	// vstack#227: per-test run-store isolation.
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	env.FLIGHTDECK_DASHBOARD = "0";
	Object.assign(env, extraEnv);
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function runState(repo: string, statePath: string, args: string[], extraEnv: Record<string, string> = {}): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.HOME = join(repo, "home");
	env.TMUX = "/tmp/tmux-test";
	env.TMUX_SHIM_STATE = statePath;
	env.TMUX_PARITY_SESSION = "test-session";
	env.PATH = `${SHIM_DIR}:${env.PATH ?? ""}`;
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	env.FLIGHTDECK_DASHBOARD = "0";
	Object.assign(env, extraEnv);
	const r = spawnSync(resolve(HERE, "../../../../scripts/flightdeck-state"), args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function makeDashboardShim(repo: string, captureFile: string): string {
	const bin = join(repo, "flightdeck-dashboard-shim");
	writeFileSync(bin, `#!/usr/bin/env bash
printf '%s\n' "$@" >> ${JSON.stringify(captureFile)}
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeFailingDashboardShim(repo: string): string {
	const bin = join(repo, "flightdeck-dashboard-fail-shim");
	writeFileSync(bin, `#!/usr/bin/env bash
echo dashboard boom >&2
exit 17
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeDashboardStateShim(repo: string, captureFile: string, dashboardWindowId = "@2"): string {
	const bin = join(repo, "flightdeck-dashboard-state-shim");
	const flightdeckState = resolve(HERE, "../../../../scripts/flightdeck-state");
	// vstack#227: dashboard shim writes the dashboard entry through
	// `flightdeck-state path` so the file lands in the active run dir
	// instead of the legacy <project>/tmp/.
	writeFileSync(bin, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> ${JSON.stringify(captureFile)}
state_file=$(${JSON.stringify(flightdeckState)} path --session test-session 2>/dev/null || true)
if [[ -n "$state_file" ]]; then
  cat > "$state_file" <<'JSON'
{
  "session_id": "test-session",
  "entries": {
    "flightdeck-dashboard": {
      "id": "flightdeck-dashboard",
      "title": "flightdeck",
      "kind": "workflow",
      "state": "waiting",
      "harness": "shell",
      "pane_id": "%2",
      "window_id": "${dashboardWindowId}"
    }
  }
}
JSON
fi
`);
	chmodSync(bin, 0o755);
	return bin;
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

function makePromptLaunchPiBridgeShim(repo: string): string {
	const bin = join(repo, "pi-bridge-prompt-launch-shim");
	const countFile = join(repo, "pi-bridge-prompt-launch.count");
	writeFileSync(bin, `#!/usr/bin/env bash
count_file=${JSON.stringify(countFile)}
count=0
[[ -f "$count_file" ]] && count=$(cat "$count_file")
count=$((count + 1))
printf '%s' "$count" > "$count_file"
case "$1" in
  list)
    if [[ "$count" == "1" ]]; then
      echo '[]'
    else
      printf '[{"pid":6161,"socketPath":"/tmp/pi-prompt.sock","sessionId":"pi-prompt-session","cwd":%s}]\\n' ${JSON.stringify(JSON.stringify(repo))}
    fi
    ;;
  state)
    echo '{"data":{"protocol":"pi-session-bridge.v1","socketPath":"/tmp/pi-prompt.sock","sessionId":"pi-prompt-session"}}'
    ;;
  *) echo '{}' ;;
esac
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeAfterWindowRejectingDashboardStateShim(repo: string, captureFile: string, dashboardWindowId = "@2"): string {
	const bin = join(repo, "flightdeck-dashboard-after-window-reject-shim");
	const flightdeckState = resolve(HERE, "../../../../scripts/flightdeck-state");
	writeFileSync(bin, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> ${JSON.stringify(captureFile)}
for arg in "$@"; do
  if [[ "$arg" == "--after-window-id" ]]; then
    echo "error: unexpected argument '--after-window-id' found" >&2
    exit 2
  fi
done
state_file=$(${JSON.stringify(flightdeckState)} path --session test-session 2>/dev/null || true)
if [[ -n "$state_file" ]]; then
  cat > "$state_file" <<'JSON'
{
  "session_id": "test-session",
  "entries": {
    "flightdeck-dashboard": {
      "id": "flightdeck-dashboard",
      "title": "flightdeck",
      "kind": "workflow",
      "state": "waiting",
      "harness": "shell",
      "pane_id": "%2",
      "window_id": "${dashboardWindowId}"
    }
  }
}
JSON
fi
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makePiBinShim(repo: string): string {
	const bin = join(repo, "pi-shim");
	writeFileSync(bin, `#!/usr/bin/env bash
if [[ -n "\${PI_PROMPT_CAPTURE:-}" ]]; then
  last="\${@: -1}"
  printf '%s' "$last" > "$PI_PROMPT_CAPTURE"
fi
if [[ -n "\${PI_EXPECT_PROMPT_FILE:-}" && ! -e "$PI_EXPECT_PROMPT_FILE" ]]; then
  echo prompt-file-gone-before-pi
fi
echo pi-shim "$@"
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeClaudeBinShim(repo: string): string {
	const bin = join(repo, "claude");
	writeFileSync(bin, `#!/usr/bin/env bash
echo claude-shim "$@"
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeCodexBinShim(repo: string): string {
	const bin = join(repo, "codex");
	writeFileSync(bin, `#!/usr/bin/env bash
echo codex-shim "$@"
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeOpencodeBinShim(repo: string, models = "openai/gpt-5.5\n"): string {
	const bin = join(repo, "opencode");
	writeFileSync(bin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "models" ]]; then
  cat <<'MODELS'
${models}MODELS
  exit 0
fi
echo opencode "$@"
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeFailingMktempShim(repo: string): string {
	const dir = join(repo, "mktemp-fail-bin");
	mkdirSync(dir, { recursive: true });
	const bin = join(dir, "mktemp");
	writeFileSync(bin, `#!/usr/bin/env bash
echo 'mktemp forced failure' >&2
exit 1
`);
	chmodSync(bin, 0o755);
	return dir;
}

function extractPromptTempfile(launchLine: string): string {
	const unescaped = launchLine.replace(/\\/g, "");
	const match = unescaped.match(/\S*\/flightdeck\/prompt-[^\s;)]+\.txt/);
	expect(match).not.toBeNull();
	return match![0];
}

function promptFiles(runtimeDir: string): string[] {
	const dir = join(runtimeDir, "flightdeck");
	if (!existsSync(dir)) return [];
	return readdirSync(dir).filter((name) => name.startsWith("prompt-"));
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

	for (const useTs of [true]) {
		test(`help documents model and effort flags`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, ["--help"]);
			expect(r.status).toBe(2);
			expect(r.stderr).toContain("--model <id>");
			expect(r.stderr).toContain("--effort <level>|--thinking <level>");
		});

		test(`start after terminated same-tmux run creates a fresh durable run`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });

			const first = run(repo, shim, [
				"start",
				"--session-id", "first-entry",
				"--title", "First entry",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "echo first",
			]);
			expect(first.status).toBe(0);
			const firstActive = JSON.parse(runState(repo, shim, ["run", "active"]).stdout);
			const firstRunId = firstActive.active.run_id;
			expect(firstRunId).toMatch(/^run-/);

			expect(runState(repo, shim, ["set", "terminated", "true"]).status).toBe(0);
			expect(runState(repo, shim, ["set", "terminated_at", '"2026-05-19T00:00:00Z"']).status).toBe(0);
			const archived = runState(repo, shim, ["archive"]);
			expect(archived.status).toBe(0);
			// vstack#227: archive writes a durable run snapshot path
			// (`<run-dir>/snapshots/<TS>.json`) instead of rotating a
			// project-tmp `.json.archive` file.
			expect(archived.stdout.trim()).toMatch(/\/snapshots\/2026-05-19T000000Z\.json$/);
			expect(JSON.parse(runState(repo, shim, ["run", "active"]).stdout)).toBeNull();

			const second = run(repo, shim, [
				"start",
				"--session-id", "second-entry",
				"--title", "Second entry",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "echo second",
			]);
			expect(second.status).toBe(0);
			const secondActive = JSON.parse(runState(repo, shim, ["run", "active"]).stdout);
			expect(secondActive.active.run_id).toMatch(/^run-/);
			expect(secondActive.active.run_id).not.toBe(firstRunId);

			const liveState = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(Object.keys(liveState.entries)).toEqual(["second-entry"]);
			const firstRun = JSON.parse(runState(repo, shim, ["run", "show", firstRunId]).stdout);
			expect(firstRun.metadata.terminated).toBe(true);
			expect(firstRun.state.entries["first-entry"].id).toBe("first-entry");
		});

		test(`dashboard self start auto-creates active run so dashboard entry lands in it (vstack#227)`, () => {
			// vstack#227 redesign: the dashboard's pane-registry writes
			// now flow through `flightdeck-state` → `statePath()` →
			// auto-ensured active run. The `--no-active-run` flag still
			// keeps the bash launcher's `ensure_active_run_for_session`
			// from explicitly creating one, but the helper CLIs
			// nonetheless materialize a run on first write so the
			// dashboard's tracked entry ends up in the same active run
			// that user lanes (linear/github) join. The dual-storage
			// duplication is the bug we set out to eliminate; this test
			// pins the new contract.
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });

			const started = run(repo, shim, [
				"start",
				"--session-id", "flightdeck-dashboard",
				"--title", "flightdeck",
				"--cwd", repo,
				"--harness", "shell",
				"--kind", "workflow",
				"--cmd", "echo dashboard",
				"--no-active-run",
			]);
			expect(started.status).toBe(0);
			const active = JSON.parse(runState(repo, shim, ["run", "active"]).stdout);
			expect(active).not.toBeNull();
			const liveState = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(liveState.entries["flightdeck-dashboard"].id).toBe("flightdeck-dashboard");
		});

		test(`start migrates legacy state then registers the new entry (vstack#227)`, () => {
			// vstack#227 redesign: `archive_stale_state_if_needed`
			// (bash) is a no-op now. Legacy `<project>/tmp/flightdeck-
			// state-<S>.json` is folded into the active run by the
			// run-store's migration shim and the legacy file is
			// renamed `.migrated`. The migration is faithful (it
			// preserves whatever the legacy file held); cleanup of
			// stale tracked entries happens later via reconciliation.
			// This test pins both the migration rename and the new
			// entry's registration in the same active run.
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			mkdirSync(join(repo, "tmp"), { recursive: true });
			writeFileSync(join(repo, "tmp", "flightdeck-state-test-session.json"), JSON.stringify({
				entries: { stale: { id: "stale", kind: "adhoc", pane_id: "%404", state: "waiting" } },
				session_id: "test-session",
				terminated: false,
			}, null, 2));

			const started = run(repo, shim, [
				"start",
				"--session-id", "replacement-entry",
				"--title", "Replacement entry",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "echo replacement",
			]);
			expect(started.status).toBe(0);
			const liveState = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(Object.keys(liveState.entries).sort()).toEqual(["replacement-entry", "stale"]);
			// Legacy state has been renamed `.migrated`.
			expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json.migrated"))).toBe(true);
			expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
		});

		test(`start fails closed when tmux liveness probe is unreliable (vstack#227)`, () => {
			// vstack#227: the run-store's stale check (inside
			// `state run ensure --checkStale`) throws "cannot verify
			// active Flightdeck run liveness" when tmux list-panes -a
			// returns an error AND the active run has recorded panes.
			// flightdeck-session start surfaces that failure instead of
			// archiving silently.
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const created = JSON.parse(runState(repo, shim, ["run", "create", "--tmux-session", "test-session"]).stdout);
			// Record a pane on the active run so the staleness check has
			// something to probe against.
			runState(repo, shim, ["write-entry", "maybe_live", JSON.stringify({
				id: "maybe_live",
				kind: "adhoc",
				pane_id: "%maybe",
				state: "waiting",
				title: "Maybe live",
				harness: "shell",
			})]);

			const started = run(repo, shim, [
				"start",
				"--session-id", "replacement-entry",
				"--title", "Replacement entry",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "echo replacement",
			], { TMUX_SHIM_FAIL_LIST_PANES_A: "1" });
			expect(started.status).not.toBe(0);
			expect(started.stderr).toContain("cannot verify active Flightdeck run liveness");
			const shown = JSON.parse(runState(repo, shim, ["run", "show", created.metadata.run_id]).stdout);
			expect(shown.metadata.terminated).toBe(false);
			expect(JSON.parse(runState(repo, shim, ["run", "active"]).stdout).active.run_id).toBe(created.metadata.run_id);
		});

		test(`start fails closed when active-run metadata is missing (vstack#227)`, () => {
			// vstack#227: archive_stale_state_if_needed is a no-op shim
			// now. The replacement guard lives in
			// `ensureActiveRun()` — if metadata.json for the active run
			// is missing, the helper throws with the recovery hint and
			// flightdeck-session start exits non-zero without mutating
			// state.
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const created = JSON.parse(runState(repo, shim, ["run", "create", "--tmux-session", "test-session"]).stdout);
			const activePath = join(repo, ".vstack-run-store", "projects", created.project.project_id, "active-run.json");
			const activeBefore = readFileSync(activePath, "utf8");
			rmSync(created.paths.metadata_json, { force: true });

			const started = run(repo, shim, [
				"start",
				"--session-id", "replacement-entry",
				"--title", "Replacement entry",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "echo replacement",
			]);
			expect(started.status).not.toBe(0);
			expect(started.stderr).toContain("active Flightdeck run metadata is missing");
			expect(readFileSync(activePath, "utf8")).toBe(activeBefore);
			expect(Object.keys(readShimState(shim).panes)).toEqual([]);
		});

		test(`start --prompt launches Pi through a tempfile without ANSI-C shell quoting`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const runtimeDir = join(repo, "runtime");
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const prompt = "line1\nline2 don't stop\n\n";
			const r = run(repo, shim, [
				"start",
				"--session-id", "fish-prompt",
				"--title", "Fish prompt",
				"--cwd", repo,
				"--harness", "pi",
				"--prompt", prompt,
			], { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makePromptLaunchPiBridgeShim(repo), XDG_RUNTIME_DIR: runtimeDir });
			expect(r.status).toBe(0);
			const shimState = readShimState(shim);
			const launchLine = shimState.panes["%1"]!.sent_keys!.find((line) => line.includes("bash") && line.includes("pi-shim"))!;
			expect(launchLine).toContain("bash");
			expect(launchLine).toContain("--model");
			expect(launchLine).toContain("openai-codex/gpt-5.5");
			expect(launchLine).toContain("--thinking");
			expect(launchLine).toContain("xhigh");
			expect(launchLine).not.toContain("$'");
			expect(launchLine).not.toContain(prompt);
			const promptFile = extractPromptTempfile(launchLine);
			expect(existsSync(promptFile)).toBe(true);
			expect(readFileSync(promptFile, "utf8")).toBe(prompt);

			const captureFile = join(repo, "captured-prompt.txt");
			const fishPath = spawnSync("bash", ["-lc", "command -v fish || true"], { encoding: "utf8" }).stdout.trim();
			const consumed = fishPath
				? spawnSync(fishPath, ["-c", launchLine], { encoding: "utf8", env: { ...process.env, PI_PROMPT_CAPTURE: captureFile, PI_EXPECT_PROMPT_FILE: promptFile } })
				: spawnSync("bash", ["-lc", launchLine], { encoding: "utf8", env: { ...process.env, PI_PROMPT_CAPTURE: captureFile, PI_EXPECT_PROMPT_FILE: promptFile } });
			expect(consumed.status).toBe(0);
			expect(consumed.stdout).toContain("prompt-file-gone-before-pi");
			expect(readFileSync(captureFile, "utf8")).toBe(prompt);
			expect(existsSync(promptFile)).toBe(false);
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["fish-prompt"].launch.model).toBe("openai-codex/gpt-5.5");
			expect(state.entries["fish-prompt"].launch.effort).toBe("xhigh");
			expect(state.entries["fish-prompt"].launch.model_source).toBe("auto");
			expect(state.entries["fish-prompt"].launch.effort_source).toBe("auto");
			expect(state.entries["fish-prompt"].launch.reasoning_status).toBe("configured");
			expect(state.entries["fish-prompt"].launch.argv).toContain("--thinking");
		});

		test(`start --prompt records explicit Pi model and thinking metadata`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const runtimeDir = join(repo, "runtime-explicit");
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "pi-explicit",
				"--title", "Pi explicit",
				"--cwd", repo,
				"--harness", "pi",
				"--model", "custom/pi:model",
				"--thinking", "high",
				"--prompt", "say hi",
			], { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makePromptLaunchPiBridgeShim(repo), XDG_RUNTIME_DIR: runtimeDir });
			expect(r.status).toBe(0);
			const launchLine = readShimState(shim).panes["%1"]!.sent_keys!.find((line) => line.includes("bash") && line.includes("pi-shim"))!;
			expect(launchLine).toContain("custom/pi:model");
			expect(launchLine).toContain("--thinking");
			expect(launchLine).toContain("high");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pi-explicit"].launch.model).toBe("custom/pi:model");
			expect(state.entries["pi-explicit"].launch.effort).toBe("high");
			expect(state.entries["pi-explicit"].launch.requested_model).toBe("custom/pi:model");
			expect(state.entries["pi-explicit"].launch.requested_effort).toBe("high");
			expect(state.entries["pi-explicit"].launch.resolved_model).toBe("custom/pi:model");
			expect(state.entries["pi-explicit"].launch.resolved_effort).toBe("high");
			expect(state.entries["pi-explicit"].launch.model_source).toBe("explicit");
			expect(state.entries["pi-explicit"].launch.effort_source).toBe("explicit");
		});

		test(`start --prompt launches Claude with model and effort metadata`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const claude = makeClaudeBinShim(repo);
			const r = run(repo, shim, [
				"start",
				"--session-id", "claude-prompt",
				"--title", "Claude prompt",
				"--cwd", repo,
				"--harness", "claude",
				"--model", "opus[1m]",
				"--effort", "max",
				"--prompt", "say hi",
			], { PATH: `${repo}:${SHIM_DIR}:${process.env.PATH ?? ""}` });
			expect(r.status).toBe(0);
			const launchLine = readShimState(shim).panes["%1"]!.sent_keys!.find((line) => line.includes(claude))!;
			expect(launchLine).toContain("--model");
			expect(launchLine).toContain("opus");
			expect(launchLine).toContain("--effort");
			expect(launchLine).toContain("max");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["claude-prompt"].launch.model).toBe("opus[1m]");
			expect(state.entries["claude-prompt"].launch.effort).toBe("max");
			expect(state.entries["claude-prompt"].launch.resolved_effort).toBe("max");
			expect(state.entries["claude-prompt"].launch.argv).toContain("--effort");
		});

		test(`start --prompt launches Codex with -m and model_reasoning_effort metadata`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const codex = makeCodexBinShim(repo);
			const r = run(repo, shim, [
				"start",
				"--session-id", "codex-prompt",
				"--title", "Codex prompt",
				"--cwd", repo,
				"--harness", "codex",
				"--model", "gpt-5.5",
				"--effort", "max",
				"--prompt", "say hi",
			], { PATH: `${repo}:${SHIM_DIR}:${process.env.PATH ?? ""}` });
			expect(r.status).toBe(0);
			const launchLine = readShimState(shim).panes["%1"]!.sent_keys!.find((line) => line.includes(codex))!;
			expect(launchLine).toContain("-m");
			expect(launchLine).toContain("gpt-5.5");
			expect(launchLine).toContain("model_reasoning_effort=xhigh");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["codex-prompt"].launch.model).toBe("gpt-5.5");
			expect(state.entries["codex-prompt"].launch.effort).toBe("xhigh");
			expect(state.entries["codex-prompt"].launch.requested_effort).toBe("max");
			expect(state.entries["codex-prompt"].launch.resolved_effort).toBe("xhigh");
			expect(state.entries["codex-prompt"].launch.argv).toContain("-m");
		});

		test(`start --prompt validates OpenCode model and records unsupported effort without variant`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const runtimeDir = join(repo, "runtime-opencode");
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const opencode = makeOpencodeBinShim(repo);
			const r = run(repo, shim, [
				"start",
				"--session-id", "oc-prompt",
				"--title", "OpenCode prompt",
				"--cwd", repo,
				"--harness", "opencode",
				"--model", "openai/gpt-5.5",
				"--effort", "max",
				"--prompt", "say hi",
			], { PATH: `${repo}:${SHIM_DIR}:${process.env.PATH ?? ""}`, XDG_RUNTIME_DIR: runtimeDir });
			expect(r.status).toBe(0);
			expect(opencode).toBe(join(repo, "opencode"));
			const launchLine = readShimState(shim).panes["%1"]!.sent_keys!.find((line) => line.includes("bash") && line.includes("opencode"))!;
			expect(launchLine).toContain("--model");
			expect(launchLine).toContain("openai/gpt-5.5");
			expect(launchLine).not.toContain("--variant");
			expect(launchLine).toContain("--prompt");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["oc-prompt"].launch.model).toBe("openai/gpt-5.5");
			expect(state.entries["oc-prompt"].launch.effort).toBeNull();
			expect(state.entries["oc-prompt"].launch.requested_effort).toBe("max");
			expect(state.entries["oc-prompt"].launch.resolved_model).toBe("openai/gpt-5.5");
			expect(state.entries["oc-prompt"].launch.resolved_effort).toBeNull();
			expect(state.entries["oc-prompt"].launch.reasoning_status).toBe("unsupported");
			expect(state.entries["oc-prompt"].launch.unsupported_reason).toContain("OpenCode top-level effort/variant");
			expect(state.entries["oc-prompt"].launch.argv).not.toContain("--variant");
		});

		test(`start --prompt requires exact OpenCode model match before tmux mutation`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			makeOpencodeBinShim(repo, "openai/gpt-5.5-pro\n");
			const r = run(repo, shim, [
				"start",
				"--session-id", "oc-prefix-invalid",
				"--title", "OpenCode prefix invalid",
				"--cwd", repo,
				"--harness", "opencode",
				"--model", "openai/gpt-5.5",
				"--prompt", "say hi",
			], { PATH: `${repo}:${SHIM_DIR}:${process.env.PATH ?? ""}` });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("opencode model is not configured");
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
			// vstack#227: a failed pre-launch validation triggers the
			// active-run rollback trap (`active_run_rollback_on_exit`),
			// which terminates the durable run that
			// `ensure_active_run_for_session` created moments earlier.
			// The legacy `<repo>/tmp/flightdeck-state-<session>.json`
			// also stays absent because we never write to it.
			expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
			const activePointer = JSON.parse(runState(repo, shim, ["run", "active"]).stdout ?? "null");
			expect(activePointer).toBeNull();
		});

		test(`start --prompt rejects unconfigured OpenCode model before tmux mutation`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const runtimeDir = join(repo, "runtime-opencode-invalid");
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			makeOpencodeBinShim(repo, "anthropic/claude-sonnet\n");
			const r = run(repo, shim, [
				"start",
				"--session-id", "oc-invalid",
				"--title", "OpenCode invalid",
				"--cwd", repo,
				"--harness", "opencode",
				"--model", "openai/gpt-5.5",
				"--prompt", "say hi",
			], { PATH: `${repo}:${SHIM_DIR}:${process.env.PATH ?? ""}`, XDG_RUNTIME_DIR: runtimeDir });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("opencode model is not configured");
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
			// vstack#227: a failed pre-launch validation triggers the
			// active-run rollback trap (`active_run_rollback_on_exit`),
			// which terminates the durable run that
			// `ensure_active_run_for_session` created moments earlier.
			// The legacy `<repo>/tmp/flightdeck-state-<session>.json`
			// also stays absent because we never write to it.
			expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
			const activePointer = JSON.parse(runState(repo, shim, ["run", "active"]).stdout ?? "null");
			expect(activePointer).toBeNull();
		});

		test(`start --prompt rejects Claude minimal/off effort before tmux mutation`, () => {
			const repo = makeRepo();
			repos.push(repo);
			let lastShim = "";
			for (const effort of ["minimal", "off"]) {
				const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
				lastShim = shim;
				const r = run(repo, shim, [
					"start",
					"--session-id", `claude-${effort}`,
					"--title", `Claude ${effort}`,
					"--cwd", repo,
					"--harness", "claude",
					"--effort", effort,
					"--prompt", "say hi",
				]);
				expect(r.status).not.toBe(0);
				expect(r.stderr).toContain("invalid --effort for claude");
				expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
			}
			// vstack#227: a failed pre-launch validation triggers the
			// active-run rollback trap (`active_run_rollback_on_exit`),
			// which terminates the durable run that
			// `ensure_active_run_for_session` created moments earlier.
			// The legacy `<repo>/tmp/flightdeck-state-<session>.json`
			// also stays absent because we never write to it.
			expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
			const activePointer = JSON.parse(runState(repo, lastShim, ["run", "active"]).stdout ?? "null");
			expect(activePointer).toBeNull();
		});

		test(`start --prompt rejects unsupported shell harness before tmux mutation`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "shell-prompt",
				"--title", "Shell prompt",
				"--cwd", repo,
				"--harness", "shell",
				"--prompt", "say hi",
			]);
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("--prompt launch does not support --harness shell");
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
			// vstack#227: a failed pre-launch validation triggers the
			// active-run rollback trap (`active_run_rollback_on_exit`),
			// which terminates the durable run that
			// `ensure_active_run_for_session` created moments earlier.
			// The legacy `<repo>/tmp/flightdeck-state-<session>.json`
			// also stays absent because we never write to it.
			expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
			const activePointer = JSON.parse(runState(repo, shim, ["run", "active"]).stdout ?? "null");
			expect(activePointer).toBeNull();
		});

		test(`start creates tmux window and registers entry`, () => {
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
			]);
			expect(r.status).toBe(0);
			const shimState = readShimState(shim);
			const pane = shimState.panes["%1"]!;
			expect(pane.window_name).toBe("Scratch");
			expect(shimState.windows["@1"]!.automatic_rename).toBeUndefined();
			expect(pane.sent_keys).toContain("clear Enter");
			const launchLine = pane.sent_keys!.find((line) => line.includes("printf ok"))!;
			expect(launchLine).toContain("FLIGHTDECK_MANAGED=1");
			expect(launchLine).toContain("FLIGHTDECK_CHILD_PANE=1");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["adhoc-start"].pane_id).toBe("%1");
			expect(state.entries["adhoc-start"].kind).toBe("adhoc");
			expect(state.entries["adhoc-start"].cwd).toBe(repo);
			expect(state.entries["adhoc-start"].launch.reasoning_status).toBe("unsupported");
			expect(state.entries["adhoc-start"].launch.unsupported_reason).toContain("custom --cmd");
		});

		test(`start disables tmux automatic rename when opted in`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "no-auto-rename",
				"--title", "Sticky title",
				"--kind", "adhoc",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "printf ok",
			], { FLIGHTDECK_DISABLE_AUTO_RENAME: "1" });
			expect(r.status).toBe(0);
			const shimState = readShimState(shim);
			expect(shimState.windows["@1"]!.automatic_rename).toBe("off");
		});

		test(`start persists requested cwd when tmux reports stale pane cwd`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const requested = join(repo, "requested-cwd");
			mkdirSync(requested, { recursive: true });
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(
				repo,
				shim,
				[
					"start",
					"--session-id", "stale-cwd",
					"--title", "Stale cwd",
					"--kind", "workflow",
					"--cwd", requested,
					"--harness", "pi",
					"--cmd", "printf ok",
				],
				{ TMUX_SHIM_NEW_WINDOW_REPORT_CWD: "/home/method" },
			);
			expect(r.status).toBe(0);
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["stale-cwd"].cwd).toBe(requested);
		});

		test(`start records model/effort overrides as not applicable for non-LLM shell cmd`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "shell-non-llm",
				"--title", "Shell non LLM",
				"--cwd", repo,
				"--harness", "shell",
				"--model", "ignored/model",
				"--effort", "high",
				"--cmd", "printf ok",
			]);
			expect(r.status).toBe(0);
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["shell-non-llm"].launch.model).toBeNull();
			expect(state.entries["shell-non-llm"].launch.effort).toBeNull();
			expect(state.entries["shell-non-llm"].launch.requested_model).toBe("ignored/model");
			expect(state.entries["shell-non-llm"].launch.requested_effort).toBe("high");
			expect(state.entries["shell-non-llm"].launch.resolved_model).toBeNull();
			expect(state.entries["shell-non-llm"].launch.resolved_effort).toBeNull();
			expect(state.entries["shell-non-llm"].launch.reasoning_status).toBe("not-applicable");
		});

		test(`start launches dashboard hook and dashboard entry does not recurse`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const capture = join(repo, "dashboard-calls.txt");
			const dashboard = makeDashboardShim(repo, capture);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "needs-dashboard",
				"--title", "Needs dashboard",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "printf ok",
			], { FLIGHTDECK_DASHBOARD: "1", FLIGHTDECK_DASHBOARD_BIN: dashboard });
			expect(r.status).toBe(0);
			expect(readFileSync(capture, "utf8").trim()).toBe("launch");

			const dashboardShim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const dashboardEntry = run(repo, dashboardShim, [
				"start",
				"--session-id", "flightdeck-dashboard",
				"--title", "flightdeck",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "printf dashboard",
			], { FLIGHTDECK_DASHBOARD: "1", FLIGHTDECK_DASHBOARD_BIN: dashboard });
			expect(dashboardEntry.status).toBe(0);
			expect(readFileSync(capture, "utf8").trim()).toBe("launch");
		});

		test(`start orders dashboard after current window and child after dashboard`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const dashboardCapture = join(repo, "dashboard-order-calls.txt");
			const tmuxLog = join(repo, "tmux-order.log");
			const dashboard = makeDashboardStateShim(repo, dashboardCapture, "@2");
			const shim = writeShimState(repo, {
				current_pane_id: "%1",
				current_window_id: "@1",
				panes: { "%1": { pane_index: 0, path: repo, window_id: "@1", window_index: 1, window_name: "master" } },
				session: "test-session",
				windows: { "@1": { index: 1, name: "master" } },
			});

			const r = run(repo, shim, [
				"start",
				"--session-id", "ordered-child",
				"--title", "Ordered child",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "printf ok",
			], { FLIGHTDECK_DASHBOARD: "1", FLIGHTDECK_DASHBOARD_BIN: dashboard, TMUX_SHIM_CALL_LOG: tmuxLog });

			expect(r.status).toBe(0);
			expect(readFileSync(dashboardCapture, "utf8")).toContain("--after-window-id\n@1");
			expect(readFileSync(tmuxLog, "utf8")).toContain("new-window\t-a -t @2");
		});

		test(`start retries dashboard launch without after-window-id when dashboard CLI rejects it`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const dashboardCapture = join(repo, "dashboard-after-window-retry-calls.txt");
			const tmuxLog = join(repo, "tmux-after-window-retry.log");
			const dashboard = makeAfterWindowRejectingDashboardStateShim(repo, dashboardCapture, "@2");
			const shim = writeShimState(repo, {
				current_pane_id: "%1",
				current_window_id: "@1",
				panes: { "%1": { pane_index: 0, path: repo, window_id: "@1", window_index: 1, window_name: "master" } },
				session: "test-session",
				windows: { "@1": { index: 1, name: "master" } },
			});

			const r = run(repo, shim, [
				"start",
				"--session-id", "old-dashboard-child",
				"--title", "Old dashboard child",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "printf ok",
			], { FLIGHTDECK_DASHBOARD: "1", FLIGHTDECK_DASHBOARD_BIN: dashboard, TMUX_SHIM_CALL_LOG: tmuxLog });

			expect(r.status).toBe(0);
			expect(r.stderr).toContain("does not support --after-window-id; retrying without window positioning");
			const calls = readFileSync(dashboardCapture, "utf8");
			expect(calls).toContain("--after-window-id\n@1");
			expect(calls.trim().split("\n").filter((line) => line === "launch")).toHaveLength(2);
			expect(readFileSync(tmuxLog, "utf8")).toContain("new-window\t-a -t @2");
		});

		test(`start honors explicit --after-window-id before dashboard then child after dashboard`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const dashboardCapture = join(repo, "dashboard-explicit-order-calls.txt");
			const tmuxLog = join(repo, "tmux-explicit-order.log");
			const dashboard = makeDashboardStateShim(repo, dashboardCapture, "@8");
			const shim = writeShimState(repo, {
				panes: { "%7": { pane_index: 0, path: repo, window_id: "@7", window_index: 7, window_name: "anchor" } },
				session: "test-session",
				windows: { "@7": { index: 7, name: "anchor" } },
			});

			const r = run(repo, shim, [
				"start",
				"--session-id", "ordered-explicit-child",
				"--title", "Ordered explicit child",
				"--cwd", repo,
				"--harness", "shell",
				"--after-window-id", "@7",
				"--cmd", "printf ok",
			], { FLIGHTDECK_DASHBOARD: "1", FLIGHTDECK_DASHBOARD_BIN: dashboard, TMUX_SHIM_CALL_LOG: tmuxLog });

			expect(r.status).toBe(0);
			expect(readFileSync(dashboardCapture, "utf8")).toContain("--after-window-id\n@7");
			expect(readFileSync(tmuxLog, "utf8")).toContain("new-window\t-a -t @8");
		});

		test(`attach launches dashboard hook`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const capture = join(repo, "dashboard-attach-calls.txt");
			const dashboard = makeDashboardShim(repo, capture);
			const shim = writeShimState(repo, {
				panes: {
					"%66": { pane_index: 0, path: "/tmp/manual", window_id: "@6", window_index: 6, window_name: "manual" },
				},
				session: "test-session",
				windows: { "@6": { index: 6, name: "manual" } },
			});
			const r = run(repo, shim, [
				"attach",
				"--pane", "%66",
				"--harness", "shell",
				"--title", "Manual Shell",
			], { FLIGHTDECK_DASHBOARD: "1", FLIGHTDECK_DASHBOARD_BIN: dashboard });
			expect(r.status).toBe(0);
			expect(readFileSync(capture, "utf8").trim()).toBe("launch");
		});

		test(`start reports tmux new-window failure without registering entry`, () => {
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
			], { TMUX_SHIM_FAIL_NEW_WINDOW: "1" });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("tmux new-window failed (rc=1");
			expect(r.stderr).toContain("title=Fail");
			expect(r.stderr).toContain("shim: new-window refused");
			// vstack#227: a failed pre-launch validation triggers the
			// active-run rollback trap (`active_run_rollback_on_exit`),
			// which terminates the durable run that
			// `ensure_active_run_for_session` created moments earlier.
			// The legacy `<repo>/tmp/flightdeck-state-<session>.json`
			// also stays absent because we never write to it.
			expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
			const activePointer = JSON.parse(runState(repo, shim, ["run", "active"]).stdout ?? "null");
			expect(activePointer).toBeNull();
			expect(JSON.parse(runState(repo, shim, ["run", "active"]).stdout)).toBeNull();
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		});

		test(`start failure preserves intentionally reused active run`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const first = run(repo, shim, [
				"start",
				"--session-id", "first-reused-run-entry",
				"--title", "First reused run entry",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "echo first",
			]);
			expect(first.status).toBe(0);
			const activeBefore = JSON.parse(runState(repo, shim, ["run", "active"]).stdout);

			const second = run(repo, shim, [
				"start",
				"--session-id", "failed-reused-run-entry",
				"--title", "Failed reused run entry",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "echo second",
			], { TMUX_SHIM_FAIL_NEW_WINDOW: "1" });
			expect(second.status).not.toBe(0);
			const activeAfter = JSON.parse(runState(repo, shim, ["run", "active"]).stdout);
			expect(activeAfter.active.run_id).toBe(activeBefore.active.run_id);
			expect(activeAfter.metadata.terminated).toBe(false);
		});

		test(`start --prompt cleans tempfile when tmux new-window fails`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const runtimeDir = join(repo, "runtime-cleanup");
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "fail-prompt-start",
				"--title", "Fail prompt",
				"--cwd", repo,
				"--harness", "pi",
				"--prompt", "cleanup me",
			], { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makeFailingPiBridgeShim(repo), XDG_RUNTIME_DIR: runtimeDir, TMUX_SHIM_FAIL_NEW_WINDOW: "1" });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("tmux new-window failed (rc=1");
			expect(r.stderr).toContain("title=Fail prompt");
			expect(r.stderr).toContain("shim: new-window refused");
			expect(promptFiles(runtimeDir)).toEqual([]);
			expect(JSON.parse(runState(repo, shim, ["run", "active"]).stdout)).toBeNull();
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		});

		test(`start warns and continues when dashboard launch fails`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "warn-dashboard-child",
				"--title", "Warn dashboard child",
				"--cwd", repo,
				"--harness", "shell",
				"--cmd", "printf ok",
			], {
				FLIGHTDECK_DASHBOARD: "1",
				FLIGHTDECK_DASHBOARD_BIN: makeFailingDashboardShim(repo),
			});
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("dashboard boom");
			expect(r.stderr).toContain("dashboard launch failed before launching warn-dashboard-child (rc=17); continuing without dashboard");
			expect(JSON.parse(runState(repo, shim, ["run", "active"]).stdout)).not.toBeNull();
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(1);
			expect(existsSync(stateFile(repo))).toBe(true);
		});

		test(`start --prompt surfaces mkdir failure before tmux mutation`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const runtimeFile = join(repo, "runtime-file");
			writeFileSync(runtimeFile, "not a dir");
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "mkdir-fails",
				"--title", "mkdir fails",
				"--cwd", repo,
				"--harness", "pi",
				"--prompt", "mkdir fail",
			], { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makeFailingPiBridgeShim(repo), XDG_RUNTIME_DIR: runtimeFile });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("failed to create Pi prompt temp dir");
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		});

		test(`start --prompt surfaces mktemp failure before tmux mutation`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const runtimeDir = join(repo, "runtime-mktemp-fails");
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const failingMktempDir = makeFailingMktempShim(repo);
			const r = run(repo, shim, [
				"start",
				"--session-id", "mktemp-fails",
				"--title", "mktemp fails",
				"--cwd", repo,
				"--harness", "pi",
				"--prompt", "mktemp fail",
			], { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makeFailingPiBridgeShim(repo), XDG_RUNTIME_DIR: runtimeDir, PATH: `${failingMktempDir}:${SHIM_DIR}:${process.env.PATH ?? ""}` });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("failed to create Pi prompt temp file");
			expect(promptFiles(runtimeDir)).toEqual([]);
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		});

		test(`start --prompt surfaces write failure and removes tempfile`, () => {
			const repo = makeRepo();
			repos.push(repo);
			const runtimeDir = join(repo, "runtime-write-fails");
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = run(repo, shim, [
				"start",
				"--session-id", "write-fails",
				"--title", "write fails",
				"--cwd", repo,
				"--harness", "pi",
				"--prompt", "force-write-fail",
			], {
				PI_BIN: makePiBinShim(repo),
				PI_BRIDGE_BIN: makeFailingPiBridgeShim(repo),
				XDG_RUNTIME_DIR: runtimeDir,
				"BASH_FUNC_printf%%": '() { if [[ "$1" == "%s" && "${2:-}" == *force-write-fail* ]]; then return 1; fi; builtin printf "$@"; }',
			});
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("failed to write Pi prompt temp file");
			expect(promptFiles(runtimeDir)).toEqual([]);
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		});

		test(`start records Pi discovery_error when bridge discovery times out`, () => {
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
			], { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makeStartListTimeoutPiBridgeShim(repo), PI_BRIDGE_CALL_TIMEOUT_SEC: "1", PI_BRIDGE_DISCOVERY_TIMEOUT: "5" });
			expect(Date.now() - started).toBeLessThan(4000);
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed during start");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pi-timeout"].discovery_error).toBe("pi_bridge_timeout");
			expect(state.entries["pi-timeout"].adapter.pi_bridge_socket).toBeNull();
		});

		test(`start surfaces pre-launch snapshot failure`, () => {
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
			], { PI_BIN: makePiBinShim(repo), PI_BRIDGE_BIN: makeSnapshotFailThenSuccessPiBridgeShim(repo), PI_BRIDGE_CALL_TIMEOUT_SEC: "1", PI_BRIDGE_DISCOVERY_TIMEOUT: "2" });
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("Warning: pre-launch pi snapshot failed");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pi-snapshot-failed"].discovery_error).toBe("pi_snapshot_failed");
			expect(state.entries["pi-snapshot-failed"].adapter.pi_bridge_socket).toBe("/tmp/pi-snapshot.sock");
		});

		test(`start --strict-discovery refuses pre-launch snapshot failure`, () => {
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
			], { PI_BRIDGE_BIN: makeFailingPiBridgeShim(repo) });
			expect(r.status).not.toBe(0);
			expect(r.stderr).toContain("Warning: pre-launch pi snapshot failed");
			expect(r.stderr).toContain("--strict-discovery refusing Pi launch");
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
			// vstack#227: a failed pre-launch validation triggers the
			// active-run rollback trap (`active_run_rollback_on_exit`),
			// which terminates the durable run that
			// `ensure_active_run_for_session` created moments earlier.
			// The legacy `<repo>/tmp/flightdeck-state-<session>.json`
			// also stays absent because we never write to it.
			expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
			const activePointer = JSON.parse(runState(repo, shim, ["run", "active"]).stdout ?? "null");
			expect(activePointer).toBeNull();
		});

		test(`attach records existing pi pane metadata`, () => {
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
			], { PI_BRIDGE_BIN: bridge });
			expect(r.status).toBe(0);
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pi-session-77"].pane_id).toBe("%77");
			expect(state.entries["pi-session-77"].adapter.pi_bridge_pid).toBe(4242);
			expect(state.entries["pi-session-77"].adapter.pi_bridge_socket).toBe("/tmp/pi-77.sock");
			expect(state.entries["pi-session-77"].adapter.pi_session_id).toBe("pi-session-77");
		});

		test(`attach records Pi discovery_error when bridge metadata is unavailable`, () => {
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
			], { PI_BRIDGE_BIN: makeFailingPiBridgeShim(repo) });
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed during attach");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pane-88"].pane_id).toBe("%88");
			expect(state.entries["pane-88"].discovery_error).toBe("pi_bridge_list_failed");
		});

		test(`attach records Pi discovery_error when bridge call times out`, () => {
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
			], { PI_BRIDGE_BIN: makeHangingPiBridgeShim(repo), PI_BRIDGE_CALL_TIMEOUT_SEC: "1" });
			expect(Date.now() - started).toBeLessThan(4000);
			expect(r.status).toBe(0);
			expect(r.stderr).toContain("Warning: pi-bridge metadata discovery failed during attach");
			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			expect(state.entries["pane-89"].pane_id).toBe("%89");
			expect(state.entries["pane-89"].discovery_error).toBe("pi_bridge_timeout");
		});

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
				SHIM_HARNESSES: "claude",
				SHIM_MASTER: "%5",
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
