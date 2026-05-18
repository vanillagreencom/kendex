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

function run(repo: string, statePath: string, args: string[], extraEnv: Record<string, string> = {}): { stdout: string; stderr: string; status: number | null } {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.TMUX = "/tmp/tmux-test";
	env.TMUX_SHIM_STATE = statePath;
	env.TMUX_PARITY_SESSION = "test-session";
	env.PATH = `${SHIM_DIR}:${env.PATH ?? ""}`;
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_DASHBOARD = "0";
	Object.assign(env, extraEnv);
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env });
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
			expect(existsSync(stateFile(repo))).toBe(false);
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
			expect(existsSync(stateFile(repo))).toBe(false);
		});

		test(`start --prompt rejects Claude minimal/off effort before tmux mutation`, () => {
			const repo = makeRepo();
			repos.push(repo);
			for (const effort of ["minimal", "off"]) {
				const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
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
			expect(existsSync(stateFile(repo))).toBe(false);
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
			expect(existsSync(stateFile(repo))).toBe(false);
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
			expect(r.stderr).toContain("tmux new-window failed");
			expect(existsSync(stateFile(repo))).toBe(false);
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
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
			expect(r.stderr).toContain("tmux new-window failed");
			expect(promptFiles(runtimeDir)).toEqual([]);
			expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
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
			expect(existsSync(stateFile(repo))).toBe(false);
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
	}
});
