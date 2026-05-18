// Smoke tests for skills/flightdeck/scripts/open-terminal.
// Uses the tmux shim; no real windows or LLM processes are created.

import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/open-terminal");
const STATE_SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-state");
const SHIM_DIR = resolve(HERE, "./tmux-shim");

interface ShimPane {
	window_id: string;
	window_name: string;
	path: string;
	window_index: number;
	pane_index: number;
	sent_keys?: string[];
}

interface ShimState {
	session: string;
	panes: Record<string, ShimPane>;
	windows: Record<string, { name: string; index: number }>;
}

function makeRepo(prefix = "fdopen-"): string {
	const dir = mkdtempSync(join(tmpdir(), prefix));
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

function makeWorktreeShim(repo: string): string {
	const bin = join(repo, "worktree-shim");
	writeFileSync(bin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "create" ]]; then
  printf '%s\n' ${JSON.stringify(repo)}
  exit 0
fi
echo "unexpected worktree args: $*" >&2
exit 1
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeGhShim(repo: string): string {
	const bin = join(repo, "gh");
	writeFileSync(bin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "issue" && "\${2:-}" == "view" ]]; then
  issue="\${3:-120}"
  cat <<JSON
{"number":$issue,"title":"Test github issue","body":"Body for github issue $issue","url":"https://github.com/owner/repo/issues/$issue","labels":[]}
JSON
  exit 0
fi
if [[ "\${1:-}" == "repo" && "\${2:-}" == "view" ]]; then
  if [[ "$*" == *"--jq"* ]]; then
    printf 'owner/repo\n'
  else
    printf '{"nameWithOwner":"owner/repo"}\n'
  fi
  exit 0
fi
echo "unexpected gh args: $*" >&2
exit 1
`);
	chmodSync(bin, 0o755);
	return bin;
}

function makeFailingGhShim(repo: string, stderr = "simulated gh failure"): string {
	const bin = join(repo, "gh");
	writeFileSync(bin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "issue" && "\${2:-}" == "view" ]]; then
  printf '%s\n' ${JSON.stringify(stderr)} >&2
  exit 1
fi
echo "unexpected gh args: $*" >&2
exit 1
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

function runOpenTerminal(repo: string, shimState: string, args: string[], extraEnv: Record<string, string> = {}) {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.TMUX = "/tmp/tmux-test";
	env.TMUX_SHIM_STATE = shimState;
	env.TMUX_PARITY_SESSION = "test-session";
	env.PATH = `${repo}:${SHIM_DIR}:${env.PATH ?? ""}`;
	env.WORKTREE_CLI = makeWorktreeShim(repo);
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_DASHBOARD = "0";
	env.FLIGHTDECK_OPEN_TERMINAL_DISABLE_ADAPTERS = "1";
	Object.assign(env, extraEnv);
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function runState(repo: string, args: string[]) {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.FLIGHTDECK_STATE_DIR = "tmp";
	const r = spawnSync(STATE_SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function forbiddenSupervisorSubstrings(): string[] {
	return ["/skill:", "$flightdeck", "/flightdeck github start"];
}

const repos: string[] = [];

afterEach(() => {
	for (const repo of repos) if (existsSync(repo)) rmSync(repo, { recursive: true, force: true });
	repos.length = 0;
});

describe("open-terminal smoke", () => {
	test("opencode tmux fallback validates exact model and never passes top-level --variant", () => {
		const repo = makeRepo();
		repos.push(repo);
		makeOpencodeBinShim(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["cc-1", "--tmux", "--harness", "opencode", "--model", "openai/gpt-5.5", "--effort", "xhigh"]);
		expect(r.status).toBe(0);
		const pane = readShimState(shim).panes["%1"]!;
		expect(pane.window_name).toBe("CC-1");
		const launchLine = pane.sent_keys!.find((line) => line.includes("opencode"))!;
		expect(launchLine).toContain("--model");
		expect(launchLine).toContain("openai/gpt-5.5");
		expect(launchLine).toContain("--prompt");
		expect(launchLine).not.toContain("--variant");
		const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
		expect(state.entries["CC-1"].launch.model).toBe("openai/gpt-5.5");
		expect(state.entries["CC-1"].launch.effort).toBeNull();
		expect(state.entries["CC-1"].launch.resolved_model).toBe("openai/gpt-5.5");
		expect(state.entries["CC-1"].launch.resolved_effort).toBeNull();
		expect(state.entries["CC-1"].launch.reasoning_status).toBe("unsupported");
		expect(state.entries["CC-1"].launch.unsupported_reason).toContain("OpenCode top-level effort/variant");
	});

	test("opencode tmux fallback rejects prefix-only model match before tmux mutation", () => {
		const repo = makeRepo();
		repos.push(repo);
		makeOpencodeBinShim(repo, "openai/gpt-5.5-pro\n");
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["cc-2", "--tmux", "--harness", "opencode", "--model", "openai/gpt-5.5"]);
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("model not configured");
		expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		expect(existsSync(stateFile(repo))).toBe(false);
	});

	test("pi effort off omits --thinking and records unsupported effort metadata", () => {
		const repo = makeRepo();
		repos.push(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["cc-4", "--tmux", "--harness", "pi", "--model", "custom/pi", "--effort", "off"]);
		expect(r.status).toBe(0);
		const launchLine = readShimState(shim).panes["%1"]!.sent_keys!.find((line) => line.includes("pi"))!;
		expect(launchLine).toContain("--model");
		expect(launchLine).toContain("custom/pi");
		expect(launchLine).not.toContain("--thinking");
		const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
		expect(state.entries["CC-4"].launch.model).toBe("custom/pi");
		expect(state.entries["CC-4"].launch.effort).toBeNull();
		expect(state.entries["CC-4"].launch.requested_effort).toBe("off");
		expect(state.entries["CC-4"].launch.reasoning_status).toBe("unsupported");
	});

	test("codex minimal effort maps to model_reasoning_effort=low and metadata", () => {
		const repo = makeRepo();
		repos.push(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["cc-5", "--tmux", "--harness", "codex", "--model", "gpt-custom", "--effort", "minimal"]);
		expect(r.status).toBe(0);
		const launchLine = readShimState(shim).panes["%1"]!.sent_keys!.find((line) => line.includes("codex"))!;
		expect(launchLine).toContain("-m");
		expect(launchLine).toContain("gpt-custom");
		expect(launchLine).toContain("model_reasoning_effort=low");
		const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
		expect(state.entries["CC-5"].launch.model).toBe("gpt-custom");
		expect(state.entries["CC-5"].launch.effort).toBe("low");
		expect(state.entries["CC-5"].launch.requested_effort).toBe("minimal");
		expect(state.entries["CC-5"].launch.resolved_effort).toBe("low");
	});

	test("pi env launch overrides forward into argv and metadata", () => {
		const repo = makeRepo();
		repos.push(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["cc-6", "--tmux", "--harness", "pi"], { FLIGHTDECK_LAUNCH_MODEL: "env/pi", FLIGHTDECK_LAUNCH_EFFORT: "high" });
		expect(r.status).toBe(0);
		const launchLine = readShimState(shim).panes["%1"]!.sent_keys!.find((line) => line.includes("pi"))!;
		expect(launchLine).toContain("env/pi");
		expect(launchLine).toContain("--thinking");
		expect(launchLine).toContain("high");
		const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
		expect(state.entries["CC-6"].launch.model).toBe("env/pi");
		expect(state.entries["CC-6"].launch.effort).toBe("high");
		expect(state.entries["CC-6"].launch.requested_model).toBe("env/pi");
		expect(state.entries["CC-6"].launch.requested_effort).toBe("high");
	});

	test("claude minimal effort fails before worktree or tmux mutation", () => {
		const repo = makeRepo();
		repos.push(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["cc-3", "--tmux", "--harness", "claude", "--effort", "minimal"]);
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("invalid --effort for claude");
		expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		expect(existsSync(stateFile(repo))).toBe(false);
	});

	for (const harness of ["pi", "codex", "claude", "opencode"] as const) {
		test(`github tracker ${harness} launch uses self-contained prompt`, () => {
			const repo = makeRepo();
			repos.push(repo);
			makeGhShim(repo);
			if (harness === "opencode") makeOpencodeBinShim(repo);
			const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
			const r = runOpenTerminal(repo, shim, ["--tracker", "github", "--repo", "owner/repo", "120", "--tmux", "--harness", harness]);
			expect(r.status).toBe(0);
			const pane = readShimState(shim).panes["%1"]!;
			expect(pane.window_name).toBe("120");
			const launchLine = pane.sent_keys!.find((line) => line.includes(harness === "claude" ? "claude" : harness))!;
			expect(launchLine).toContain("Fix GitHub issue owner/repo#120");
			expect(launchLine).toContain("Print the PR URL as the LAST line");
			for (const forbidden of forbiddenSupervisorSubstrings()) expect(launchLine).not.toContain(forbidden);
			if (harness === "opencode") expect(launchLine).toContain("--prompt");

			const state = JSON.parse(readFileSync(stateFile(repo), "utf8"));
			const entry = state.entries["120"];
			expect(entry.domain.issue).toBeUndefined();
			expect(entry.domain.github_issue).toMatchObject({
				merge_commit: null,
				number: 120,
				pr_number: null,
				url: "https://github.com/owner/repo/issues/120",
				worktree: repo,
			});
		});
	}

	test("github tracker rejects Linear-style ids before tmux mutation", () => {
		const repo = makeRepo();
		repos.push(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["--tracker", "github", "CC-7", "--tmux", "--harness", "pi", "--repo", "owner/repo"]);
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("github tracker requires numeric issue IDs");
		expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		expect(existsSync(stateFile(repo))).toBe(false);
	});

	test("bare numeric without github tracker is treated as group id and does not spawn", () => {
		const repo = makeRepo();
		repos.push(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["120", "--tmux", "--harness", "pi"]);
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("no active group with id 120");
		expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		expect(existsSync(stateFile(repo))).toBe(false);
	});

	test("github tracker validates issue before creating worktree", () => {
		const repo = makeRepo();
		repos.push(repo);
		makeFailingGhShim(repo, "auth failed for owner/repo");
		const marker = join(repo, "worktree-called");
		const worktree = join(repo, "worktree-should-not-run");
		writeFileSync(worktree, `#!/usr/bin/env bash
touch ${JSON.stringify(marker)}
printf '%s\n' ${JSON.stringify(repo)}
`);
		chmodSync(worktree, 0o755);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["--tracker", "github", "--repo", "owner/repo", "404", "--tmux", "--harness", "pi"], { WORKTREE_CLI: worktree });
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("gh issue view 404 --repo owner/repo failed");
		expect(r.stderr).toContain("auth failed for owner/repo");
		expect(existsSync(marker)).toBe(false);
		expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		expect(existsSync(stateFile(repo))).toBe(false);
	});

	test("mixed Linear and GitHub domains round-trip through flightdeck-state", () => {
		const repo = makeRepo();
		repos.push(repo);
		expect(runState(repo, ["init", "--session", "mixed-domain"]).status).toBe(0);
		const linear = {
			id: "CC-120",
			kind: "issue",
			state: "waiting",
			domain: { issue: { id: "CC-120", worktree: "/repo/trees/cc-120", pr_number: 120, merge_commit: null } },
		};
		const github = {
			id: "120",
			kind: "issue",
			state: "waiting",
			domain: { github_issue: { number: 120, url: "https://github.com/owner/repo/issues/120", worktree: "/repo/trees/120", pr_number: null, merge_commit: null, scope_files_actual: 3 } },
		};
		expect(runState(repo, ["write-entry", "CC-120", JSON.stringify(linear), "--session", "mixed-domain"]).status).toBe(0);
		expect(runState(repo, ["write-entry", "120", JSON.stringify(github), "--session", "mixed-domain"]).status).toBe(0);
		const out = runState(repo, ["tracked-entries", "--session", "mixed-domain"]);
		expect(out.status).toBe(0);
		const entries = JSON.parse(out.stdout);
		expect(entries["CC-120"].domain.issue.id).toBe("CC-120");
		expect(entries["120"].domain.github_issue.number).toBe(120);
		expect(entries["120"].domain.issue).toBeUndefined();
	});

	test("flightdeck-state rejects unknown domain subkeys", () => {
		const repo = makeRepo();
		repos.push(repo);
		expect(runState(repo, ["init", "--session", "bad-domain"]).status).toBe(0);
		const bad = { id: "bad", kind: "adhoc", domain: { future_issue: { id: "bad" } } };
		const r = runState(repo, ["write-entry", "bad", JSON.stringify(bad), "--session", "bad-domain"]);
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("unknown domain key");
	});

	test("flightdeck-state rejects entries with both Linear and GitHub domains", () => {
		const repo = makeRepo();
		repos.push(repo);
		expect(runState(repo, ["init", "--session", "mixed-bad-domain"]).status).toBe(0);
		const bad = {
			id: "120",
			kind: "issue",
			domain: {
				issue: { id: "CC-120", worktree: "/repo/trees/cc-120", pr_number: 120, merge_commit: null },
				github_issue: { number: 120, url: "https://github.com/owner/repo/issues/120", worktree: "/repo/trees/120", pr_number: null, merge_commit: null },
			},
		};
		const r = runState(repo, ["write-entry", "120", JSON.stringify(bad), "--session", "mixed-bad-domain"]);
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("mutually exclusive");
	});

	test("github tracker native adapter routing is tracker-agnostic", () => {
		const source = readFileSync(SCRIPT, "utf8");
		expect(source).not.toMatch(/\$HARNESS" == "(opencode|claude|pi|codex)"[^\n]*\$TRACKER" != "github"/);
		expect(source).toContain('prompt="$(start_prompt_for_harness "$TRACKER" "$issue" pi)"');
		expect(source).toContain('prompt="$(start_prompt_for_harness "$TRACKER" "$issue" claude)"');
		expect(source).toContain('prompt="$(start_prompt_for_harness "$TRACKER" "$issue" opencode)"');
	});

	test("codex remote adapter receives tracker prompt instead of idle attach", () => {
		const source = readFileSync(SCRIPT, "utf8");
		expect(source).toContain('prompt="$(start_prompt_for_harness "$TRACKER" "$issue" codex)"');
		expect(source).toContain('cmd=$(shell_join "${FLIGHTDECK_PANE_ENV[@]}" "$cx_bin" "${launch_args[@]}" --remote "$ws_url" "$prompt")');
	});
});
