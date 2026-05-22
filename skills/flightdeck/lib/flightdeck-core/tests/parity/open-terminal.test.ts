// Smoke tests for skills/flightdeck/scripts/open-terminal.
// Uses the tmux shim; no real windows or LLM processes are created.

import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = resolve(HERE, "../../../../scripts/open-terminal");
const STATE_SCRIPT = resolve(HERE, "../../../../scripts/flightdeck-state");
const PANE_REGISTRY_SCRIPT = resolve(HERE, "../../../../scripts/pane-registry");
const CHANNEL_SERVER_DIR = resolve(HERE, "../../../claude-channel-server");
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
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	const r = spawnSync(STATE_SCRIPT, ["path", "--session", "test-session"], { cwd: repo, encoding: "utf8", env });
	if (r.status !== 0) throw new Error(`flightdeck-state path failed: ${r.stderr}`);
	return (r.stdout ?? "").trim();
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

function makeGhShim(repo: string, body = "Body for github issue"): string {
	const bin = join(repo, "gh");
	writeFileSync(bin, `#!/usr/bin/env bash
if [[ "\${1:-}" == "issue" && "\${2:-}" == "view" ]]; then
  issue="\${3:-120}"
  cat <<JSON
{"number":$issue,"title":"Test github issue","body":${JSON.stringify(body)},"url":"https://github.com/owner/repo/issues/$issue","labels":[]}
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
	// vstack#227: per-test run-store isolation.
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	env.FLIGHTDECK_DASHBOARD = "0";
	env.FLIGHTDECK_OPEN_TERMINAL_DISABLE_ADAPTERS = "1";
	Object.assign(env, extraEnv);
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

// vstack#216 (pre-PR round-2): open-terminal driver with adapters ON.
// The default `runOpenTerminal` sets FLIGHTDECK_OPEN_TERMINAL_DISABLE_ADAPTERS=1
// to short-circuit per-harness native adapter spawn paths so the test
// only exercises argv/state plumbing. The cc-channels acceptance test
// needs the real `spawn_cc_channel_tmux` to run — so we leave that
// kill-switch unset, prepend a fake-claude-bin directory to PATH,
// pin a sandboxed HOME so cc_transcript_path lands inside the repo,
// and route FD_STATE_DIR to a per-test dir so the daemon's
// spawn-metadata files don't leak across runs.
function runOpenTerminalChannelsOn(repo: string, shimState: string, fakeBin: string, fakeHome: string, fdStateDir: string, args: string[]) {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.TMUX = "/tmp/tmux-test";
	env.TMUX_SHIM_STATE = shimState;
	env.TMUX_PARITY_SESSION = "test-session";
	env.PATH = `${fakeBin}:${repo}:${SHIM_DIR}:${env.PATH ?? ""}`;
	env.HOME = fakeHome;
	env.WORKTREE_CLI = makeWorktreeShim(repo);
	env.FLIGHTDECK_STATE_DIR = "tmp";
	// vstack#227: per-test run-store isolation.
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
	env.FLIGHTDECK_DASHBOARD = "0";
	env.FD_STATE_DIR = fdStateDir;
	// vstack#216: pin the claude bin to our fake so resolve_claude_bin
	// doesn't pick up /usr/bin/claude (which would talk to real auth in
	// the sandboxed HOME and fail). Production users leave this unset.
	env.FLIGHTDECK_CLAUDE_BIN = join(fakeBin, "claude");
	// channels opt-in is implicit via `--tracker github --harness claude`
	// per the open-terminal default added in this branch, but pass it
	// explicitly here too so the test stays honest if that default ever
	// changes.
	env.FLIGHTDECK_CLAUDE_CHANNELS = "1";
	const r = spawnSync(SCRIPT, args, { cwd: repo, encoding: "utf8", env });
	return { status: r.status, stderr: r.stderr ?? "", stdout: r.stdout ?? "" };
}

function runState(repo: string, args: string[]) {
	const env: Record<string, string> = { ...(process.env as Record<string, string>) };
	env.FLIGHTDECK_STATE_DIR = "tmp";
	env.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
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
		// vstack#227: assert the legacy file is absent. The active run
		// may have been auto-created but no entries got registered, so
		// we look at the registry side instead.
		expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
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
		// vstack#227: assert legacy file absence — active run may
		// have been auto-created by the helper CLI but the entry was
		// never registered. The legacy `<repo>/tmp/` location stays
		// clean.
		expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
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
			expect(launchLine).toContain("Read tmp/brief.md and execute");
			// vstack#180+: child brief now drives the final-line contract through
			// the supervisor-handshake instructions in tmp/brief.md, so the
			// launch-line pointer no longer hardcodes "Print the PR URL".
			expect(launchLine).toContain("Follow its supervisor-handshake instructions");
			expect(launchLine).toContain("Print only what the brief tells you to print as the LAST line");
			expect(launchLine).not.toContain("Fix GitHub issue owner/repo#120");
			for (const forbidden of forbiddenSupervisorSubstrings()) expect(launchLine).not.toContain(forbidden);
			if (harness === "opencode") expect(launchLine).toContain("--prompt");
			if (harness === "pi") {
				expect(launchLine).not.toContain("$'");
				const fishPath = spawnSync("bash", ["-lc", "command -v fish || true"], { encoding: "utf8" }).stdout.trim();
				if (fishPath) {
					const parsed = spawnSync(fishPath, ["-n", "-c", launchLine], { encoding: "utf8" });
					expect(parsed.status).toBe(0);
				}
			}
			const brief = readFileSync(join(repo, "tmp", "brief.md"), "utf8");
			expect(brief).toContain("Fix GitHub issue owner/repo#120");
			expect(brief).toContain("Body for github issue");
			// vstack#182: default brief drives the supervisor-handshake pre-PR
			// review loop. Verify the brief asks the child to push without
			// opening a PR, emits the PRE-PR-REVIEW-READY sentinel, and waits
			// for tmp/pre-pr-approved.md / tmp/pre-pr-review/round-<N>.md.
			expect(brief).toContain("Do NOT open a PR yet.");
			expect(brief).toContain("PRE-PR-REVIEW-READY: tmp/ready-for-review.txt");
			expect(brief).toContain("tmp/pre-pr-approved.md");
			expect(brief).toContain("tmp/pre-pr-review/round-<N>.md");
			expect(brief).toContain("<<<ISSUE_BODY_BEGIN>>>");
			expect(brief).toContain("<<<ISSUE_BODY_END>>>");
			for (const forbidden of forbiddenSupervisorSubstrings()) expect(brief).not.toContain(forbidden);

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

	// vstack#216 (pre-PR round-2): end-to-end acceptance for the
	// github-tracker Claude path. The lower-level pane-registry
	// hydrate-claude tests prove the hydration *function* works; this
	// test proves the open-terminal *flow* actually invokes it (the bug
	// caused by #216 was that the spawn-file write order kept cc_* null
	// even though hydrate-claude existed as a library function). Drives
	// the actual spawn path with adapters ENABLED, fakes the `claude`
	// binary so resolve_claude_bin/version/auth all succeed, ensures
	// the channel-server bootstrap is a no-op via a pre-existing
	// node_modules dir, and asserts (a) entry.adapter.cc_url /
	// cc_session_uuid / cc_transcript / cc_channel_token become non-null
	// on the registered entry and (b) `pane-registry cc-channel-args`
	// returns `--url ... --transcript ...` (with a live transcript file
	// + fake /healthz on the allocated port so the freshness gate
	// passes — what the daemon's binder requires).
	test("github tracker claude end-to-end populates cc_* adapter fields and cc-channel-args returns --url --transcript", async () => {
		const repo = makeRepo();
		repos.push(repo);

		// Stage a fake `claude` binary that satisfies cc_verify_claude_version
		// (>= 2.1.80) and cc_verify_claude_auth (output mentions claude.ai).
		// Path is prepended in runOpenTerminal so it overrides the real
		// `claude` on the host without us touching /usr/bin.
		const fakeBin = join(repo, "bin");
		mkdirSync(fakeBin, { recursive: true });
		const fakeClaude = join(fakeBin, "claude");
		writeFileSync(fakeClaude, `#!/usr/bin/env bash
case "\${1:-}" in
  --version) echo "2.1.999 (Claude Code)"; exit 0 ;;
  auth) echo '{"loggedIn":true,"authMethod":"claude.ai"}'; exit 0 ;;
esac
# Mimic a short-lived claude invocation; open_tmux only writes the
# command into the tmux shim's sent_keys array and never waits.
exit 0
`);
		chmodSync(fakeClaude, 0o755);

		makeGhShim(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });

		// The channel-server bootstrap exits 0 when node_modules/ is
		// already present; otherwise it runs `bun install` which would
		// mutate the real lib/ dir. Ensure the dir exists so we never
		// trigger that path. Path is gitignored.
		const nodeModules = join(CHANNEL_SERVER_DIR, "node_modules");
		const createdNodeModules = !existsSync(nodeModules);
		if (createdNodeModules) mkdirSync(nodeModules, { recursive: true });

		// Sandbox the home dir so cc_transcript_path lands inside the
		// test repo. open-terminal's spawn_cc_channel_tmux computes the
		// transcript path as `$HOME/.claude/projects/<encoded-cwd>/<uuid>.jsonl`
		// — we want that under the test repo so the test cleans up
		// after itself, but we still need the real auth flow to be
		// bypassed by our fake claude binary above (which it is, since
		// we prepend `bin/` to PATH).
		const fakeHome = join(repo, "home");
		mkdirSync(join(fakeHome, ".claude", "projects"), { recursive: true });

		const fdStateDir = join(repo, "tmp", "fd-state");
		mkdirSync(fdStateDir, { recursive: true });

		try {
			const r = runOpenTerminalChannelsOn(repo, shim, fakeBin, fakeHome, fdStateDir, [
				"--tracker", "github", "--repo", "owner/repo", "216", "--tmux", "--harness", "claude",
			]);
			expect(r.status).toBe(0);
			// The cc-channel spawn path always logs `cc-channel: port=...`
			// on success. If the path fell through to legacy spawn we'd
			// see `cc-channel-unavailable:` on stderr instead.
			expect(r.stdout + r.stderr).toContain("cc-channel: port=");

			// State file lives at <repo>/tmp/flightdeck-state-test-session.json.
			const stateFilePath = stateFile(repo);
			expect(existsSync(stateFilePath)).toBe(true);
			const state = JSON.parse(readFileSync(stateFilePath, "utf8"));
			const entry = state.entries["216"];
			expect(entry).toBeTruthy();
			expect(entry.harness).toBe("claude");
			expect(entry.adapter).toBeTruthy();
			expect(typeof entry.adapter.cc_url).toBe("string");
			expect(entry.adapter.cc_url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);
			expect(typeof entry.adapter.cc_session_uuid).toBe("string");
			expect(entry.adapter.cc_session_uuid).toMatch(/^[0-9a-f-]{36}$/);
			expect(typeof entry.adapter.cc_transcript).toBe("string");
			expect(entry.adapter.cc_transcript.length).toBeGreaterThan(0);
			expect(typeof entry.adapter.cc_port).toBe("number");
			expect(entry.adapter.cc_port).toBeGreaterThan(0);
			expect(typeof entry.adapter.cc_channel_token).toBe("string");
			expect(entry.adapter.cc_channel_token.length).toBeGreaterThanOrEqual(32);

			// Spawn file mirrors the entry; required for the daemon's
			// rebuild-from-disk path and for late hydrate-claude calls.
			const spawnFile = join(fdStateDir, "cc-spawn-216.json");
			expect(existsSync(spawnFile)).toBe(true);
			const spawnRec = JSON.parse(readFileSync(spawnFile, "utf8"));
			expect(spawnRec.url).toBe(entry.adapter.cc_url);
			expect(spawnRec.transcript).toBe(entry.adapter.cc_transcript);
			expect(spawnRec.channel_token).toBe(entry.adapter.cc_channel_token);
			expect(Number(spawnRec.port)).toBe(entry.adapter.cc_port);
			// Defense in depth: spawn file holding the bearer token is
			// readable only by the owner.
			expect(statSync(spawnFile).mode & 0o077).toBe(0);

			// Acceptance criterion #1 final check: `pane-registry cc-channel-args
			// <N>` returns the flags the daemon's binder requires. The
			// freshness gate inside the command requires (a) the
			// transcript file to be a regular file, (b) the recorded URL
			// to respond to `/healthz` with `ok health`. We satisfy both
			// here by writing the transcript file and running a tiny
			// python http server on the allocated port. python3 is
			// already a flightdeck dep.
			mkdirSync(dirname(entry.adapter.cc_transcript), { recursive: true });
			writeFileSync(entry.adapter.cc_transcript, "");
			const pyScript = `import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","text/plain"); self.end_headers(); self.wfile.write(b"ok health\\n")
    def log_message(self, *a, **k): pass
srv = http.server.HTTPServer(("127.0.0.1", ${entry.adapter.cc_port}), H)
sys.stdout.write("ready\\n"); sys.stdout.flush()
try: srv.serve_forever()
except KeyboardInterrupt: pass`;
			const healthChild = spawn("python3", ["-c", pyScript], { stdio: ["ignore", "pipe", "pipe"] });
			try {
				await new Promise<void>((resolveReady, rejectReady) => {
					const t = setTimeout(() => rejectReady(new Error("python /healthz server didn't start in time")), 5000);
					healthChild.stdout!.on("data", (b: Buffer) => {
						if (b.toString().includes("ready")) { clearTimeout(t); resolveReady(); }
					});
					healthChild.on("error", (e) => { clearTimeout(t); rejectReady(e); });
				});

				const argsEnv: Record<string, string> = { ...(process.env as Record<string, string>) };
				argsEnv.FD_STATE_DIR = fdStateDir;
				argsEnv.FLIGHTDECK_STATE_DIR = "tmp";
				// vstack#227: per-test run-store isolation so the
				// pane-registry subprocess resolves the same active run
				// the open-terminal driver wrote to.
				argsEnv.FLIGHTDECK_RUN_STORE_ROOT = join(repo, ".vstack-run-store");
				argsEnv.FD_ADAPTER_FRESHNESS_TTL = "0";
				argsEnv.TMUX_PARITY_SESSION = "test-session";
				argsEnv.TMUX_SHIM_STATE = shim;
				argsEnv.PATH = `${fakeBin}:${SHIM_DIR}:${argsEnv.PATH ?? ""}`;
				const args = spawnSync(PANE_REGISTRY_SCRIPT, ["cc-channel-args", "216"], { cwd: repo, encoding: "utf8", env: argsEnv });
				expect(args.status).toBe(0);
				const out = (args.stdout ?? "").trim();
				expect(out).toContain(`--url ${entry.adapter.cc_url}`);
				expect(out).toContain(`--transcript ${entry.adapter.cc_transcript}`);
				expect(out).toContain(`--channel-token ${entry.adapter.cc_channel_token}`);
			} finally {
				healthChild.kill("SIGTERM");
			}
		} finally {
			// Clean up node_modules only when we created it (don't
			// disturb an existing dev environment that already had it).
			if (createdNodeModules) {
				rmSync(nodeModules, { force: true, recursive: true });
			}
		}
	}, 30000);

	test("github tracker materializes control bytes into brief file, not tmux launch line", () => {
		const repo = makeRepo();
		repos.push(repo);
		makeGhShim(repo, "control body before \u0003 after\nsecond line");
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["--tracker", "github", "--repo", "owner/repo", "120", "--tmux", "--harness", "pi"]);
		expect(r.status).toBe(0);
		const launchLine = readShimState(shim).panes["%1"]!.sent_keys!.find((line) => line.includes("pi"))!;
		expect(launchLine).toContain("Read tmp/brief.md and execute");
		expect(launchLine).not.toContain("\u0003");
		expect(launchLine).not.toContain("control body before");
		const brief = readFileSync(join(repo, "tmp", "brief.md"), "utf8");
		expect(brief).toContain("control body before \u0003 after");
		expect(brief).toContain("second line");
	});

	test("github tracker rejects Linear-style ids before tmux mutation", () => {
		const repo = makeRepo();
		repos.push(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["--tracker", "github", "CC-7", "--tmux", "--harness", "pi", "--repo", "owner/repo"]);
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("github tracker requires numeric issue IDs");
		expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		// vstack#227: assert legacy file absence — active run may
		// have been auto-created by the helper CLI but the entry was
		// never registered. The legacy `<repo>/tmp/` location stays
		// clean.
		expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
	});

	test("bare numeric without github tracker is treated as group id and does not spawn", () => {
		const repo = makeRepo();
		repos.push(repo);
		const shim = writeShimState(repo, { panes: {}, session: "test-session", windows: {} });
		const r = runOpenTerminal(repo, shim, ["120", "--tmux", "--harness", "pi"]);
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("no active group with id 120");
		expect(Object.keys(readShimState(shim).panes)).toHaveLength(0);
		// vstack#227: assert legacy file absence — active run may
		// have been auto-created by the helper CLI but the entry was
		// never registered. The legacy `<repo>/tmp/` location stays
		// clean.
		expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
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
		// vstack#227: assert legacy file absence — active run may
		// have been auto-created by the helper CLI but the entry was
		// never registered. The legacy `<repo>/tmp/` location stays
		// clean.
		expect(existsSync(join(repo, "tmp", "flightdeck-state-test-session.json"))).toBe(false);
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
